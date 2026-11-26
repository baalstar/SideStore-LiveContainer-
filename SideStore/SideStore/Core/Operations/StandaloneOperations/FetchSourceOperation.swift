//
//  FetchSourceOperation.swift
//  AltStore
//
//  Created by Riley Testut on 7/30/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import Foundation
import CoreData
import SemanticVersion
import SideSign

final class FetchSourceOperation: BaseStandaloneOperation<StandaloneOperationContext, Source>, @unchecked Sendable {
    let sourceURL: URL
    
    // Non-nil when updating an existing source.
    @Managed
    private var source: Source?
    
    private let session: URLSession
    private weak var dataTask: URLSessionDataTask?

    
    private lazy var dateFormatter: ISO8601DateFormatter = {
        let dateFormatter = ISO8601DateFormatter()
        return dateFormatter
    }()
    
    init(sourceURL: URL, context: StandaloneOperationContext) throws {
        self.sourceURL = sourceURL
        self.session = URLSession.shared
        try super.init(context: context)
    }
    
    init(source: Source, context: StandaloneOperationContext) throws {
        self.sourceURL = source.sourceURL
        self.session = URLSession.shared
        try super.init(context: context)
        context.dbBackgroundContext.performAndWait {
            self.source = context.dbBackgroundContext.object(with: source.objectID) as? Source
        }
    }
    
    override func cancel() {
        super.cancel()
        
        self.dataTask?.cancel()
    }
    
    override func execute(parentProgress: Progress?) async throws -> Source {
        let startTime = CFAbsoluteTimeGetCurrent()
        debugLog("[FetchSourceOperation] execute() started")
        defer {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            debugLog("[FetchSourceOperation] execute() took: \(String(format: "%.3fs", elapsed))")
        }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        
        let dbContext = self.context.dbBackgroundContext
        
        if let source = self.source {
            // Check if source is blocked before fetching it.
            let sourceObjectID = source.objectID
            try dbContext.performAndWait {
                try self.verifyExistingSource(sourceObjectID)
            }
        }
        
        var request = URLRequest(url: self.sourceURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData     // don't use local caching
        request.timeoutInterval = AppConstants.Sources.fetchTimeout

        let (data, response): (Data, URLResponse)
        if let repo = GitHubSource.repository(from: self.sourceURL) {
            data = try await GitHubSource.sourceJSON(for: repo)
            response = HTTPURLResponse(url: self.sourceURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        } else {
            (data, response) = try await self.fetchSourceData(with: request)
        }
        
        let childContext = DatabaseManager.shared.persistentContainer.newBackgroundContext(parent: dbContext)
        childContext.mergePolicy = NSOverwriteMergePolicy
        
        let identifier = try await childContext.perform {
            let identifier = try self.performDecodeAndSave(data: data, response: response, childContext: childContext)
            try childContext.save()
            return identifier
        }
        
        let fetchedSource = try dbContext.performAndWait {
            if let source = Source.first(satisfying: NSPredicate(format: "%K == %@", #keyPath(Source.identifier), identifier), in: dbContext) {
                return source
            } else {
                throw OperationError.noSources
            }
        }
        self.setProgress(100)
        return fetchedSource
    }
    
    private func fetchSourceData(with request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let dataTask = self.session.dataTask(with: request) { (data, response, error) in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data, let response = response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: OperationError.invalidResponse(reason: "\(URLError(.badServerResponse).localizedDescription): Server returned no data or response."))
                }
            }
            dataTask.resume()
            self.dataTask = dataTask
        }
    }
    
    private func verifyExistingSource(_ sourceObjectID: NSManagedObjectID) throws {
        let source = self.context.dbBackgroundContext.object(with: sourceObjectID) as! Source
        try self.verifySourceNotBlocked(source, response: nil)
    }
    
    private func performDecodeAndSave(data: Data, response: URLResponse, childContext: NSManagedObjectContext) throws -> String {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom({ (decoder) -> Date in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            
            // Full ISO8601 Format.
            self.dateFormatter.formatOptions = [.withFullDate, .withFullTime, .withTimeZone]
            if let date = self.dateFormatter.date(from: text) {
                return date
            }
            
            // Just date portion of ISO8601.
            self.dateFormatter.formatOptions = [.withFullDate]
            if let date = self.dateFormatter.date(from: text) {
                return date
            }
            
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Date is in invalid format.")
        })
        
        decoder.managedObjectContext = childContext
        decoder.sourceURL = self.sourceURL
        
        decoder.allowsJSON5 = true
        
        let source: Source
        
        do {
            source = try decoder.decode(Source.self, from: data)
        } catch let error as DecodingError {
            let debugDescription: String
            let codingPath: [CodingKey]
            switch error {
            case .typeMismatch(let type, let context):
                debugDescription = "Type mismatch for type \(type). \(context.debugDescription)"
                codingPath = context.codingPath
            case .valueNotFound(let type, let context):
                debugDescription = "Value of type \(type) not found. \(context.debugDescription)"
                codingPath = context.codingPath
            case .keyNotFound(let key, let context):
                debugDescription = "Key '\(key.stringValue)' not found. \(context.debugDescription)"
                codingPath = context.codingPath + [key]
            case .dataCorrupted(let context):
                debugDescription = "Data corrupted. \(context.debugDescription)"
                codingPath = context.codingPath
            @unknown default:
                debugDescription = error.localizedDescription
                codingPath = []
            }
            
            let pathDescription = codingPath.map { $0.intValue?.description ?? $0.stringValue }.joined(separator: " > ")
            let detailedMessage = "Decoding failed: \(debugDescription) at path: \(pathDescription)"
            
            throw NSError(domain: "io.sidestore.SideStore.DecodingError", code: 0, userInfo: [
                NSLocalizedDescriptionKey: detailedMessage,
                NSDebugDescriptionErrorKey: detailedMessage
            ])
        }
        
        let identifier = source.identifier
        
        try self.verify(source, response: response)
        
        return identifier
    }
    
    private func verify(_ source: Source, response: URLResponse) throws {
        try self.verifySourceNotBlocked(source, response: response)
        
        var bundleIDs = Set<String>()
        var duplicateApps = [StoreApp]()
        
        for app in source.apps {
            if bundleIDs.contains(app.bundleIdentifier) {
                duplicateApps.append(app)
                continue
            }
            bundleIDs.insert(app.bundleIdentifier)
            
            var versions = Set<String>()
            var duplicateVersions = [AppVersion]()
            for version in app.versions {
                if versions.contains(version.versionID) {
                    duplicateVersions.append(version)
                    continue
                }
                versions.insert(version.versionID)
            }
            
            for version in duplicateVersions {
                debugLog("[FetchSourceOperation]: Warning: Skipping duplicate version '\(version.version)' for app '\(app.name)' (\(app.bundleIdentifier)).")
                version.managedObjectContext?.delete(version)
            }
            
            for permission in app.permissions where permission.type == .privacy {
                // Privacy permissions MUST have a usage description.
                guard permission.usageDescription != nil else { throw SourceError.missingPermissionUsageDescription(for: permission.permission, app: app, source: source) }
            }
            
            for screenshot in app.screenshots(for: .ipad) {
                // All iPad screenshots MUST have an explicit size.
                guard screenshot.size != nil else { throw SourceError.missingScreenshotSize(for: screenshot, source: source) }
            }
            
            #if MARKETPLACE
            guard app.marketplaceID != nil else { throw SourceError.marketplaceRequired(source: source) }
            #else
            guard app.marketplaceID == nil else { throw SourceError.marketplaceNotSupported(source: source) }
            #endif
        }
        
        for app in duplicateApps {
            debugLog("[FetchSourceOperation]: Warning: Skipping duplicate app '\(app.name)' (\(app.bundleIdentifier)) in source '\(source.name)'.")
            app.managedObjectContext?.delete(app)
        }
        
        let incomingSourceID = source.identifier
        if let previousSourceID = self.$source.identifier,
           incomingSourceID != previousSourceID {
//            if let version = BuildInfo().marketing_version,
//               SemanticVersion(version)! <= SemanticVersion("0.6.1")!
//            {
//                // delete the source, so that incoming will be saved.
//                self.source?.managedObjectContext?.delete(self.source!)
//            }
//            else
//            {
                throw SourceError.changedID(source.identifier, previousID: self.$source.identifier ?? "nil", source: source)
//            }
        }
    }
    
    private func verifySourceNotBlocked(_ source: Source, response: URLResponse?) throws {
        guard let blockedSources = UserDefaults.standard.blockedSources else { return }
        
        for blockedSource in blockedSources {
            guard
                source.identifier != blockedSource.identifier,
                source.sourceURL.absoluteString.lowercased() != blockedSource.sourceURL?.absoluteString.lowercased()
            else { throw SourceError.blocked(source, bundleIDs: blockedSource.bundleIDs, existingSource: self.source) }
            
            if let responseURL = response?.url {
                // responseURL may differ from source.sourceURL (e.g. due to redirects), so double-check it's also not blocked.
                guard responseURL.absoluteString.lowercased() != blockedSource.sourceURL?.absoluteString.lowercased() else {
                    throw SourceError.blocked(source, bundleIDs: blockedSource.bundleIDs, existingSource: self.source)
                }
            }
        }
    }
}

/// Turns https://github.com/owner/repo into a source built from the newest
/// release that has .ipa assets. SideStore needs the bundle ID, version and
/// permissions, so each new asset is downloaded once and its facts are cached.
enum GitHubSource {
    struct Repository { let owner: String; let name: String }

    private struct Release: Decodable {
        let draft, prerelease: Bool
        let published_at: String?
        let body: String?
        let assets: [Asset]
    }
    private struct Asset: Decodable {
        let id, size: Int
        let name, updated_at: String
        let browser_download_url: URL
    }

    static func repository(from url: URL) -> Repository? {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard ["github.com", "www.github.com"].contains(url.host?.lowercased() ?? ""), parts.count == 2 else { return nil }
        return Repository(owner: parts[0], name: parts[1].replacingOccurrences(of: ".git", with: "", options: [.anchored, .backwards]))
    }

    private static func fail(_ text: String) -> Error {
        NSError(domain: "SideStore.GitHubSource", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }

    static func sourceJSON(for repo: Repository) async throws -> Data {
        guard let api = URL(string: "https://api.github.com/repos/\(repo.owner)/\(repo.name)/releases?per_page=20") else {
            throw fail("Неверный адрес репозитория.")
        }
        var request = URLRequest(url: api, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (body, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw fail(status == 403 || status == 429 ? "GitHub ограничил число запросов. Попробуйте позже."
                       : "GitHub ответил \(status). Нужен публичный репозиторий.")
        }
        func ipas(_ release: Release) -> [Asset] {
            release.assets.filter { $0.name.lowercased().hasSuffix(".ipa") }
        }
        let releases = try JSONDecoder().decode([Release].self, from: body)
        guard let release = releases.first(where: { !$0.draft && !$0.prerelease && !ipas($0).isEmpty }) else {
            throw fail("В последних релизах (кроме черновиков и pre-release) нет .ipa.")
        }

        var apps: [[String: Any]] = []
        var seen = Set<String>()
        var lastError: Error?
        for asset in ipas(release).prefix(3) {
            do {
                let facts = try await inspect(asset)
                guard let bundleID = facts["bundleID"] as? String, seen.insert(bundleID).inserted else { continue }
                var version: [String: Any] = [
                    "version": facts["version"] as? String ?? "1.0",
                    "date": release.published_at ?? asset.updated_at,
                    "localizedDescription": release.body ?? "",
                    "downloadURL": asset.browser_download_url.absoluteString,
                    "size": asset.size,
                ]
                if let build = facts["build"] as? String, !build.isEmpty { version["buildVersion"] = build }
                apps.append([
                    "name": facts["name"] as? String ?? repo.name,
                    "bundleIdentifier": bundleID,
                    "developerName": repo.owner,
                    "localizedDescription": "Из GitHub: \(repo.owner)/\(repo.name), файл \(asset.name)",
                    "iconURL": "https://github.com/\(repo.owner).png",
                    "versions": [version],
                    "appPermissions": ["entitlements": facts["entitlements"] ?? [String](),
                                       "privacy": facts["privacy"] ?? [String: String]()],
                ])
            } catch {
                DiagnosticLog.error("GitHub asset \(asset.name)", error)
                lastError = error
            }
        }
        guard !apps.isEmpty else { throw lastError ?? fail("Не удалось прочитать IPA.") }
        return try JSONSerialization.data(withJSONObject: [
            "name": repo.name, "subtitle": "GitHub: \(repo.owner)",
            "iconURL": "https://github.com/\(repo.owner).png",
            "websiteURL": "https://github.com/\(repo.owner)/\(repo.name)",
            "apps": apps, "news": [Any](),
        ])
    }

    private static func inspect(_ asset: Asset) async throws -> [String: Any] {
        let key = "GitHubSource.\(asset.id).\(asset.updated_at)"
        if let cached = UserDefaults.standard.dictionary(forKey: key) { return cached }
        let (file, response) = try await URLSession.shared.download(from: asset.browser_download_url)
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: file); try? files.removeItem(at: folder) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw fail("Не удалось скачать \(asset.name).") }
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let appURL = try files.unzipAppBundle(at: file, toDirectory: folder)
        guard let app = ALTApplication(fileURL: appURL) else { throw fail("\(asset.name): не приложение iOS.") }
        let bundles = [app] + Array(app.appExtensions)
        let entitlements = Set(bundles.flatMap { $0.entitlements.keys.map { "\($0)" } })
        var privacy: [String: String] = [:]
        for bundle in bundles {
            for (name, value) in bundle.infoPlist where "\(name)".hasSuffix("UsageDescription") {
                privacy["\(name)"] = value as? String ?? "-"
            }
        }
        let facts: [String: Any] = ["bundleID": app.bundleIdentifier, "name": app.name,
                                    "version": app.version, "build": app.buildVersion,
                                    "entitlements": Array(entitlements), "privacy": privacy]
        UserDefaults.standard.set(facts, forKey: key)
        return facts
    }
}
