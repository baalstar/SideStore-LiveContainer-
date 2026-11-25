//
//  ResignAppOperation.swift
//  AltStore
//
//  Created by Riley Testut on 6/7/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

@preconcurrency import UIKit
import Foundation
import SideSign
#if os(iOS) && !targetEnvironment(simulator)
import CSISign
#endif

final class ResignAppOperation: BasePipelineOperation<InstallAppOperationContext, ALTApplication>, @unchecked Sendable {
    
    override func execute(parentProgress: Progress?) async throws -> ALTApplication {
        let startTime = CFAbsoluteTimeGetCurrent()
        debugLog("[ResignAppOperation] execute() started")
        defer {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            debugLog("[ResignAppOperation] execute() took: \(String(format: "%.3fs", elapsed))")
        }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        
        let team = try await AuthManager.shared.getAuthenticatedTeam()
#if os(iOS) && !targetEnvironment(simulator)
        if IsideloadEngine.handles(self.context) {
            do {
                return try await self.signWithIsideload(team: team)
            } catch {
                DiagnosticLog.error("isideload engine", error)
                throw error
            }
        }
#endif
        guard
            let appBundle = self.context.targetAppBundle,
            let profiles = self.context.provisioningProfiles,
            let certificate = self.context.targetSigningCertificate
        else {
            throw OperationError.invalidParameters("ResignAppOperation.main: " +
                                                   "self.context.targetAppBundle or " +
                                                   "self.context.provisioningProfiles or " +
                                                   "self.context.targetSigningCertificate is nil")
        }
        
        debugLog("[ResignAppOperation] Resigning app \(self.context.bundleIdentifier)...")
        
        self.setProgress(5)
        
        let effectiveBundleId = self.context.targetBundleIdentifier
        let appBundleURL = try await self.prepareAppBundle(for: appBundle, profiles: profiles, appexBundleIds: context.appexBundleIds ?? [:])
        
        self.setProgress(40)
        
        let resignedAppURL = try await self.resignAppBundle(at: appBundleURL, team: team, certificate: certificate, profiles: Array(profiles.values))
        guard let resignedAppBundle = ALTApplication(fileURL: resignedAppURL) else {
            throw OperationError.invalidApp(reason: "Could not load resigned app bundle at '\(resignedAppURL.lastPathComponent)'")
        }
        
        self.debugLog("[ResignAppOperation] Resigned app \(self.context.bundleIdentifier) to \(resignedAppBundle.bundleIdentifier).")
        self.setProgress(100)
        
        return resignedAppBundle
    }

    
#if os(iOS) && !targetEnvironment(simulator)
    /// App ID, app group, profile and signature, all done by isideload.
    private func signWithIsideload(team: ALTTeam) async throws -> ALTApplication {
        guard let app = context.targetAppBundle,
              let certificate = context.targetSigningCertificate,
              let appleID = Keychain.shared.appleIDEmailAddress,
              let password = Keychain.shared.appleIDPassword else {
            throw OperationError.invalidParameters("isideload needs an app, a signing certificate and a saved Apple ID. Sign in again.")
        }
        let url = context.temporaryDirectory.appendingPathComponent("App.app")
        if app.fileURL.path != url.path {
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.copyItem(at: app.fileURL, to: url)
        }
        // SideStore's own keys: isideload doesn't know about them.
        let finalID = "\(context.targetBundleIdentifier).\(team.identifier)"
        let plistURL = url.appendingPathComponent("Info.plist")
        var info = try InfoPlistParser(plistURL: plistURL).rawDictionary as [String: Any]
        var urlTypes = info[Bundle.Info.urlTypes] as? [[String: Any]] ?? []
        urlTypes.removeAll { ($0["CFBundleURLSchemes"] as? [String])?.contains { $0.hasPrefix("sidestore-") } ?? false }
        urlTypes.append(["CFBundleTypeRole": "Editor", "CFBundleURLName": finalID,
                         "CFBundleURLSchemes": [InstalledApp.openAppURL(targetBundleIdentifier: finalID).scheme!]])
        info[Bundle.Info.urlTypes] = urlTypes
        var utis = info[Bundle.Info.exportedUTIs] as? [[String: Any]] ?? []
        utis.append(["UTTypeConformsTo": [String](), "UTTypeDescription": "AltStore Installed App",
                     "UTTypeIconFiles": [String](),
                     "UTTypeIdentifier": InstalledApp.installedAppUTI(forBundleIdentifier: finalID),
                     "UTTypeTagSpecification": [String: Any]()])
        info[Bundle.Info.exportedUTIs] = utis
        try InfoPlistParser(dictionary: info).write(to: plistURL)

        DiagnosticLog.write("sign", "start app=\(finalID) team=\(team.identifier) type=\(team.type) extensions=\(app.appExtensions.map { $0.bundleIdentifier }) anisette=\(UserDefaults.standard.menuAnisetteURL)")
        self.setProgress(10)
        let signedURL = try await IsideloadEngine.sign(
            appURL: url, appleID: appleID, password: password, teamID: team.identifier,
            privateKey: certificate.privateKey, anisetteURL: UserDefaults.standard.menuAnisetteURL)

        let profile = try ALTProvisioningProfile(data: Data(contentsOf: signedURL.appendingPathComponent("embedded.mobileprovision")))
        DiagnosticLog.write("sign", "profile id=\(profile.bundleIdentifier) expected=\(finalID) expires=\(profile.expirationDate) profileCerts=\(profile.certificates.map { $0.serialNumber }) expectedCert=\(certificate.serialNumber) entitlementKeys=\(profile.entitlements.keys.sorted())")
        guard profile.bundleIdentifier == finalID,
              profile.certificates.contains(where: { $0.serialNumber == certificate.serialNumber }) else {
            throw OperationError.invalidApp(reason: "isideload used a different App ID or certificate than SideStore expects.")
        }
        context.provisioningProfiles = [context.targetBundleIdentifier: profile]
        guard let signed = ALTApplication(fileURL: signedURL) else {
            throw OperationError.invalidApp(reason: "Could not load the signed app.")
        }
        self.setProgress(100)
        return signed
    }
#endif

    private func prepareAppBundle(for targetAppBundle: ALTApplication, profiles: [String: ALTProvisioningProfile], appexBundleIds: [String: String]) async throws -> URL {

        let bundleIdentifier = context.targetBundleIdentifier
        let finalBundleIdentifier: String
        if let profile = context.useMainProfile ? profiles.values.first : profiles[bundleIdentifier] {
            finalBundleIdentifier = profile.bundleIdentifier
        } else {
            finalBundleIdentifier = bundleIdentifier
        }
        
        // Use customized bundle ID if applicable
        let openURL = InstalledApp.openAppURL(targetBundleIdentifier: finalBundleIdentifier)
        let fileURL = targetAppBundle.fileURL

        let appBundleURL = self.context.temporaryDirectory.appendingPathComponent("App.app")
        if fileURL.path != appBundleURL.path {
            if FileManager.default.fileExists(atPath: appBundleURL.path) {
                try FileManager.default.removeItem(at: appBundleURL)
            }
            try FileManager.default.copyItem(at: fileURL, to: appBundleURL)
        }
        
        guard let appBundle = ALTApplication(fileURL: appBundleURL) else {
            throw OperationError.missingAppBundle(reason: "Could not load bundle at '\(appBundleURL.lastPathComponent)'")
        }
        let infoDictionary = appBundle.infoPlist
        
        // replace scheme targets to match the bundle suffix so multiple instances can be correctly routed for helper apps like SideBackup
        var allURLSchemes = infoDictionary[Bundle.Info.urlTypes] as? [[String: Any]] ?? []
        allURLSchemes.removeAll { urlType in
            guard let schemes = urlType["CFBundleURLSchemes"] as? [String] else { return false }
            return schemes.contains { $0.hasPrefix("sidestore-") }
        }
        
        let altstoreURLScheme = ["CFBundleTypeRole": "Editor",
                                 "CFBundleURLName": finalBundleIdentifier,
                                 "CFBundleURLSchemes": [openURL.scheme!]] as [String : Any]
        allURLSchemes.append(altstoreURLScheme)
        
        var additionalValues: [String: Any] = [Bundle.Info.urlTypes: allURLSchemes]

        if targetAppBundle.isAltStoreApp {
            if let activeCert = CertificateManager.shared.activeCertificate {
                additionalValues[Bundle.Info.certificateID] = activeCert.serialNumber
                let certURL = appBundle.fileURL.appendingPathComponent("ALTCertificate.p12")
                try activeCert.p12Data.write(to: certURL, options: .atomic)
            } else {
                self.verboseLog("[ResignAppOperation] No activeCertificate found in CertificateManager. Embedded certificate + certificate identifier in app bundle will not be updated.")
            }
        }
        
        // Prepare app
        try self.prepare(appBundle, bundleID: bundleIdentifier, additionalInfoDictionaryValues: additionalValues, profiles: profiles, appexBundleIds: appexBundleIds)
        try self.removeMissingAppExtensionReferences(from: appBundle)
        
        for appExtension in appBundle.appExtensions {
            let updatedAppExBundleId = appExtension.bundleIdentifier.replacingOccurrences(of: targetAppBundle.bundleIdentifier, with: bundleIdentifier)
            var extensionIds = appexBundleIds
            if context.useMainProfile, let mainProfile = profiles.values.first,
               appExtension.bundleIdentifier.hasPrefix(targetAppBundle.bundleIdentifier + ".") {
                let suffix = appExtension.bundleIdentifier.dropFirst(targetAppBundle.bundleIdentifier.count)
                extensionIds[updatedAppExBundleId] = mainProfile.bundleIdentifier + suffix
            }
            try self.prepare(appExtension, bundleID: updatedAppExBundleId, profiles: profiles, appexBundleIds: extensionIds)
        }
        
        return appBundleURL
    }
    
    private func prepare(_ appBundle: ALTApplication, bundleID identifier: String?, additionalInfoDictionaryValues: [String: Any] = [:], profiles: [String: ALTProvisioningProfile], appexBundleIds: [String: String]) throws {
        guard let identifier else {
            throw OperationError.invalidParameters("Bundle is missing bundle identifier.")
        }
        guard let profile = context.useMainProfile ? profiles.values.first : profiles[identifier] else {
            throw OperationError.missingProvisioningProfile(reason: "No provisioning profile found for identifier '\(identifier)'.")
        }
        guard var parser = try? InfoPlistParser(plistURL: appBundle.infoPlistURL) else {
            throw OperationError.missingInfoPlist(reason: "Could not read Info.plist for bundle '\(identifier)'.")
        }
        var infoDictionary = parser.rawDictionary as [String: Any]
        
        let newBundleID = appexBundleIds[identifier] ?? profile.bundleIdentifier
        infoDictionary[kCFBundleIdentifierKey as String] = newBundleID

        // Fix-up BGTaskScheduler identifiers so they stay under the new bundle ID.
        // Otherwise bg register() and submit() both succeed and the handler is never
        // called, with no error surfaced to the app.
        if identifier != newBundleID, let taskIDs = infoDictionary["BGTaskSchedulerPermittedIdentifiers"] as? [String] {
            let taskIDs = self.rewrittenTaskSchedulerIdentifiers(taskIDs, from: identifier, to: newBundleID)
            infoDictionary["BGTaskSchedulerPermittedIdentifiers"] = taskIDs
        }

        infoDictionary.removeValue(forKey: "DTXcode")
        infoDictionary.removeValue(forKey: "DTXcodeBuild")

        for (key, value) in additionalInfoDictionaryValues {
            infoDictionary[key] = value
        }

        if let customPlist = context.customInfoPlistByBundleID[identifier] {
            for (key, value) in customPlist {
                if key == (kCFBundleIdentifierKey as String) || key == "CFBundleIdentifier" {
                    continue
                }
                infoDictionary[key] = value
            }
        }

        if let appGroups = profile.entitlements[.appGroups] as? [String] {
            // To keep file providers working, remap the NSExtensionFileProviderDocumentGroup, if there is one.
            if var extensionInfo = infoDictionary["NSExtension"] as? [String: Any],
                let appGroup = extensionInfo["NSExtensionFileProviderDocumentGroup"] as? String,
                let localAppGroup = appGroups.filter({ $0.contains(appGroup) }).min(by: { $0.count < $1.count }) {
                extensionInfo["NSExtensionFileProviderDocumentGroup"] = localAppGroup
                infoDictionary["NSExtension"] = extensionInfo
            }
        }
        
        // Add app-specific exported UTI so we can check later if this app (extension) is installed or not.
        let installedAppUTI = ["UTTypeConformsTo": [],
                               "UTTypeDescription": "AltStore Installed App",
                               "UTTypeIconFiles": [],
                               "UTTypeIdentifier": InstalledApp.installedAppUTI(forBundleIdentifier: profile.bundleIdentifier),
                               "UTTypeTagSpecification": [:]] as [String : Any]
        
        var exportedUTIs = infoDictionary[Bundle.Info.exportedUTIs] as? [[String: Any]] ?? []
        exportedUTIs.append(installedAppUTI)
        infoDictionary[Bundle.Info.exportedUTIs] = exportedUTIs
        
        try InfoPlistParser(dictionary: infoDictionary).write(to: appBundle.infoPlistURL)
        
        // Remove _CodeSignature folder (if it exists) because it will be added when resigning and it may have files that aren't overwritten when resigning
        // These files might be the cause of some ApplicationVerificationFailed errors
        let codeSignatureURL = appBundle.fileURL.appendingPathComponent("_CodeSignature")
        if FileManager.default.fileExists(atPath: codeSignatureURL.path) {
            try FileManager.default.removeItem(at: codeSignatureURL)
            self.verboseLog("[ResignAppOperation] Removed _CodeSignature folder at \(codeSignatureURL.path)")
        }
    }
    
    private func resignAppBundle(at fileURL: URL, team: ALTTeam, certificate: ALTCertificate, profiles: [ALTProvisioningProfile]) async throws -> URL {
        let signer = ALTSigner(team: team, certificate: certificate)
        try await signer.signApp(at: fileURL, provisioningProfiles: profiles, progress: nil)
        return fileURL
    }
    
    private func removeMissingAppExtensionReferences(from appBundle: ALTApplication) throws {
        // If app extensions have been removed from an app (either by AltStore or the developer),
        // we must remove all references to them from SC_Info/Manifest.plist (if it exists).
        
        let scInfoURL = appBundle.fileURL.appendingPathComponent("SC_Info")
        let manifestPlistURL = scInfoURL.appendingPathComponent("Manifest.plist")
        
        guard let manifestPlist = try? InfoPlistParser(plistURL: manifestPlistURL),
              let sinfReplicationPaths = manifestPlist.rawDictionary["SinfReplicationPaths"] as? [String] else { return }
        
        // Remove references to missing files.
        let filteredReplicationPaths = sinfReplicationPaths.filter { path in
            guard let fileURL = URL(string: path, relativeTo: appBundle.fileURL) else { return false }
            
            let fileExists = FileManager.default.fileExists(atPath: fileURL.path)
            return fileExists
        }
        
        var updatedManifest = manifestPlist.rawDictionary
        updatedManifest["SinfReplicationPaths"] = filteredReplicationPaths
        
        // Save updated Manifest.plist to disk.
        try InfoPlistParser(dictionary: updatedManifest).write(to: manifestPlistURL)
    }

    private func rewrittenTaskSchedulerIdentifiers(_ taskIDs: [String], from originalBundleID: String, to newBundleID: String) -> [String] {
        var seen = Set<String>()
        var rewrittenTaskIDs = [String]()
        for taskID in taskIDs {
            let rewritten: String
            if taskID == newBundleID || taskID.hasPrefix(newBundleID + ".") {
                rewritten = taskID
            } else if taskID == originalBundleID || taskID.hasPrefix(originalBundleID + ".") {
                rewritten = newBundleID + taskID.dropFirst(originalBundleID.count)
            } else {
                rewritten = taskID
            }
            if seen.insert(rewritten).inserted {
                rewrittenTaskIDs.append(rewritten)
            }
        }
        return rewrittenTaskIDs
    }
}

#if os(iOS) && !targetEnvironment(simulator)
enum IsideloadEngine {
    /// Plain install and re-sign only. Custom IDs, plists, entitlements,
    /// override profiles and SideBackup flows stay on the SideSign path,
    /// because isideload has no input for them.
    static func handles(_ context: InstallAppOperationContext) -> Bool {
        let steps = context.pipelineSteps.map { $0.step }
        return steps.contains(.resignApp) && !steps.contains(.stageBackupApp)
            && context.customBundleIdentifier == nil
            && context.customInfoPlistByBundleID.isEmpty
            && context.customEntitlementsByBundleID.isEmpty
            && context.additionalEntitlements.isEmpty
            && context.overrideProvisioningProfile == nil
            && context.appendTeamID
    }

    static func describe(_ c: InstallAppOperationContext) -> String {
        "isideload=\(handles(c)) steps=\(c.pipelineSteps.map { "\($0.step)" }) customID=\(c.customBundleIdentifier != nil) customPlists=\(c.customInfoPlistByBundleID.count) customEntitlements=\(c.customEntitlementsByBundleID.count) extraEntitlements=\(c.additionalEntitlements.count) overrideProfile=\(c.overrideProvisioningProfile != nil) appendTeamID=\(c.appendTeamID)"
    }

    // One signing at a time: the isideload storage is shared.
    private static let queue = DispatchQueue(label: "SideStore.isideload")

    static func sign(appURL: URL, appleID: String, password: String, teamID: String,
                     privateKey: Data, anisetteURL: String) async throws -> URL {
        let storage = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("isideload", isDirectory: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    try signBlocking(appURL: appURL, appleID: appleID, password: password, teamID: teamID,
                                     privateKey: privateKey, anisetteURL: anisetteURL, storage: storage.path)
                })
            }
        }
    }

    private static func signBlocking(appURL: URL, appleID: String, password: String, teamID: String,
                                     privateKey: Data, anisetteURL: String, storage: String) throws -> URL {
        _ = DiagnosticLog.startRustLog
        DiagnosticLog.write("sign", "adopting certificate key, bytes=\(privateKey.count)")
        let adopted = privateKey.withUnsafeBytes {
            si_adopt_key(storage, appleID, $0.bindMemory(to: UInt8.self).baseAddress, $0.count)
        }
        // Without SideStore's key isideload would ask Apple for a new certificate.
        guard adopted == 0 else { throw failure("Couldn't hand the certificate key to isideload.", nil) }

        DiagnosticLog.write("sign", "sign-in begins")
        var session: OpaquePointer?
        var summary: UnsafeMutablePointer<CChar>?
        var error: UnsafeMutablePointer<CChar>?
        let status = si_apple_signin(appleID, password, anisetteURL, "SideStore", storage, 1, teamID,
                                     { _, request, buffer, length in
                                         guard let request, let buffer else { return 0 }
                                         return TwoFactorPrompt.answer(String(cString: request), buffer, length)
                                     }, nil, nil, &session, &summary, &error)
        defer {
            si_string_free(summary)
            si_string_free(error)
            if let session { si_sign_session_free(session) }
        }
        guard status == 0, let session else { throw failure("isideload sign-in failed", error) }
        guard let summary, String(cString: summary).contains(teamID) else {
            throw failure("isideload picked a different developer team.", nil)
        }
        DiagnosticLog.write("sign", "sign-in ok, signing begins")
        var output: UnsafeMutablePointer<CChar>?
        var signError: UnsafeMutablePointer<CChar>?
        defer { si_string_free(output); si_string_free(signError) }
        // 2 = Increased Memory Limit when possible; 1 = use an app group.
        guard si_sign_ipa(session, appURL.path, nil, nil, nil, 2, 1, &output, &signError) == 0, let output else {
            throw failure("isideload signing failed", signError)
        }
        return URL(fileURLWithPath: String(cString: output), isDirectory: true)
    }

    private static func failure(_ text: String, _ detail: UnsafeMutablePointer<CChar>?) -> Error {
        let reason = detail.map { "\(text): \(String(cString: $0))" } ?? text
        return OperationError.invalidApp(reason: reason)
    }
}

/// Blocks the signing queue (never the main thread) until the user answers.
private enum TwoFactorPrompt {
    static func answer(_ json: String, _ buffer: UnsafeMutablePointer<CChar>, _ length: Int) -> Int32 {
        let request = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        DiagnosticLog.write("2fa", "method=\(request["method"] ?? "?") numbers=\((request["numbers"] as? [Any])?.count ?? 0) lastError=\(request["lastError"] ?? "-")")
        let done = DispatchSemaphore(value: 0)
        var reply: [String: Any]?
        func finish(_ value: [String: Any]?) { reply = value; done.signal() }
        DispatchQueue.main.async {
            let window = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }.first { $0.isKeyWindow }
            var top = window?.rootViewController
            while let next = top?.presentedViewController { top = next }
            // Background refresh has no UI: cancel instead of hanging.
            guard let top, UIApplication.shared.applicationState == .active else { return finish(nil) }
            let alert = UIAlertController(title: "Apple ID: код подтверждения",
                                          message: request["lastError"] as? String, preferredStyle: .alert)
            alert.addTextField { $0.keyboardType = .numberPad; $0.textContentType = .oneTimeCode }
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
                finish(["action": "code", "code": alert?.textFields?.first?.text ?? ""])
            })
            for number in request["numbers"] as? [[String: Any]] ?? [] {
                guard let id = number["id"] as? Int else { continue }
                alert.addAction(UIAlertAction(title: "SMS: \(number["number"] as? String ?? "")", style: .default) { _ in
                    finish(["action": "sms", "id": id])
                })
            }
            alert.addAction(UIAlertAction(title: "Отправить на устройства", style: .default) { _ in finish(["action": "devices"]) })
            alert.addAction(UIAlertAction(title: "Отмена", style: .cancel) { _ in finish(nil) })
            top.present(alert, animated: true)
        }
        done.wait()
        guard let reply, let data = try? JSONSerialization.data(withJSONObject: reply),
              data.count < length else { return 0 }
        data.withUnsafeBytes { memcpy(buffer, $0.baseAddress!, data.count) }
        buffer[data.count] = 0
        return 1
    }
}
#endif

/// Redacted diagnostics for bug reports: Documents/diagnostics.log (+ .old).
enum DiagnosticLog {
    private static let queue = DispatchQueue(label: "SideStore.diagnostics")
    private static let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("diagnostics.log")
    private static let rules: [(String, String)] = [
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "<email>"),
        (#"(?i)((?:password|passwd|token|secret|cookie|authorization|adi_pb|machine_?id|serial_?number|x-apple-[a-z-]*(?:md|token)[a-z-]*)["']?\s*[:=]\s*)("[^"]*"|[^\s,;}]+)"#, "$1<redacted>"),
        (#"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}\b|\b[0-9a-fA-F]{40}\b"#, "<udid-or-hash>"),
        (#"[A-Za-z0-9+/_=-]*(?=[A-Za-z+_=-]*[0-9])[A-Za-z0-9+_=-]{48,}"#, "<blob>"),
        (#"\+\d[\d ()•*-]{6,}\d"#, "<phone>"),
    ]

    static func redact(_ text: String) -> String {
        rules.reduce(text) {
            $0.replacingOccurrences(of: $1.0, with: $1.1, options: .regularExpression)
        }
    }

    static func write(_ tag: String, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(tag)] \(redact(message))\n"
        print(line, terminator: "")
        queue.async {
            let files = FileManager.default
            let size = (try? files.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size > 2_000_000 {
                let old = url.appendingPathExtension("old")
                try? files.removeItem(at: old)
                try? files.moveItem(at: url, to: old)
            }
            if !files.fileExists(atPath: url.path) { files.createFile(atPath: url.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }

    static func error(_ context: String, _ error: Error) {
        var parts: [String] = []
        var current: NSError? = error as NSError
        // Follow the chain: the outer error often hides the real cause.
        while let e = current, parts.count < 6 {
            parts.append("\(e.domain) \(e.code): \(e.localizedDescription) | \(e.localizedFailureReason ?? "-")")
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        write("ERROR", "\(context) | type=\(type(of: error)) | \(String(reflecting: error)) | " + parts.joined(separator: " <- "))
    }

    static var environment: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "os=\(ProcessInfo.processInfo.operatingSystemVersionString) app=\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?")) bundle=\(Bundle.main.bundleIdentifier ?? "?")"
    }

#if os(iOS) && !targetEnvironment(simulator)
    /// Runs once: routes the Rust core's log lines and panics here.
    static let startRustLog: Void = {
        setenv("RUST_BACKTRACE", "1", 1)
        _ = si_log_init({ _, message in
            if let message { DiagnosticLog.write("rust", String(cString: message)) }
        }, nil)
    }()
#endif
}
