//
//  InstallAppDialog.swift
//  SideStore
//
//  Created by Magesh K on 8/2/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import UIKit
import UniformTypeIdentifiers
import CryptoKit
import SideSign
private import KeychainAccess

public enum AppImportSourceMode: String, CaseIterable, Identifiable, Sendable {
    case prompt = "prompt"
    case files  = "files"
    case url    = "url"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .prompt:
            return "Prompt User"
        case .files:
            #if !os(tvOS)
            return "Files App"
            #else
            return "Web Upload"
            #endif
        case .url:
            return "URL"
        }
    }
}

@MainActor
public enum InstallAppDialog {
    
    public static func presentSourceSelection(
        from presentingVC: UIViewController,
        barButtonItem: UIBarButtonItem? = nil,
        mode: AppImportSourceMode = UserDefaults.standard.appImportSourceMode,
        onChooseFiles: @escaping () -> Void,
        onConfirm: @escaping (URL) -> Void
    ) {
        switch mode {
        case .prompt:
            #if !os(tvOS)
            let alertController = UIAlertController(
                title: NSLocalizedString("Install App", comment: ""),
                message: nil,
                preferredStyle: .actionSheet
            )
            if let popover = alertController.popoverPresentationController {
                popover.barButtonItem = barButtonItem
            }
            alertController.addAction(UIAlertAction(title: NSLocalizedString("Choose from Files", comment: ""), style: .default) { _ in
                onChooseFiles()
            })
            #else
            let alertController = UIAlertController(
                title: NSLocalizedString("Install App", comment: ""),
                message: NSLocalizedString("Choose an installation method:", comment: ""),
                preferredStyle: .alert
            )
            alertController.addAction(UIAlertAction(title: NSLocalizedString("Upload via Web", comment: ""), style: .default) { _ in
                onChooseFiles()
            })
            #endif
            
            #if !os(tvOS)
            if LiveContainerInbox.isAvailable {
                alertController.addAction(UIAlertAction(title: "Отправить файл в LiveContainer", style: .default) { _ in
                    LiveContainerInbox.shared.pick(from: presentingVC)
                })
            }
            #endif
            
            #if !os(tvOS)
            if LiveContainerInbox.isAvailable {
                alertController.addAction(UIAlertAction(title: "Обновить приложение из ZIP", style: .default) { _ in
                    AppUpdater.shared.pickZip(from: presentingVC, install: onConfirm)
                })
                alertController.addAction(UIAlertAction(title: "Обновить из GitHub Actions", style: .default) { _ in
                    AppUpdater.shared.askGitHub(from: presentingVC, install: onConfirm)
                })
            }
            #endif
            
            alertController.addAction(UIAlertAction(title: NSLocalizedString("Install from URL", comment: ""), style: .default) { _ in
                self.presentURLInputDialog(from: presentingVC, onConfirm: onConfirm)
            })
            alertController.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
            
            presentingVC.present(alertController, animated: true)

        case .files:
            onChooseFiles()

        case .url:
            self.presentURLInputDialog(from: presentingVC, onConfirm: onConfirm)
        }
    }
    
    private static func presentURLInputDialog(
        from presentingVC: UIViewController,
        onConfirm: @escaping (URL) -> Void
    ) {
        let alert = UIAlertController(
            title: NSLocalizedString("Install from URL", comment: ""),
            message: NSLocalizedString("Enter the URL of the .ipa file to install.", comment: ""),
            preferredStyle: .alert
        )
        
        alert.addTextField { textField in
            textField.placeholder = "https://example.com/app.ipa"
            textField.keyboardType = .URL
            textField.autocapitalizationType = .none
            textField.autocorrectionType = .no
            textField.clearButtonMode = .whileEditing
        }
        
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        alert.addAction(UIAlertAction(title: NSLocalizedString("Continue", comment: ""), style: .default) { _ in
            guard let text = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let url = URL(string: text),
                  let scheme = url.scheme?.lowercased(),
                  (scheme == "http" || scheme == "https") else {
                let errorAlert = UIAlertController(
                    title: NSLocalizedString("Invalid URL", comment: ""),
                    message: NSLocalizedString("Please enter a valid HTTP or HTTPS URL.", comment: ""),
                    preferredStyle: .alert
                )
                errorAlert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
                presentingVC.present(errorAlert, animated: true)
                return
            }
            
            self.present(ipaURL: url, from: presentingVC) {
                onConfirm(url)
            }
        })
        
        presentingVC.present(alert, animated: true)
    }
    
    public static func present(
        ipaURL: URL,
        from presentingViewController: UIViewController? = nil,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        let message: String
        if ipaURL.isFileURL {
            let appName = ipaURL.deletingPathExtension().lastPathComponent
            message = String(format: NSLocalizedString("Do you want to continue? This will install \"%@\".", comment: ""), appName)
        } else {
            message = String(format: NSLocalizedString("Do you want to continue? This will download and install from:\n%@", comment: ""), ipaURL.absoluteString)
        }
        
        self.presentConfirmation(
            message: message,
            from: presentingViewController,
            onConfirm: onConfirm,
            onCancel: onCancel
        )
    }
    
    public static func present(
        storeApp: StoreApp,
        from presentingViewController: UIViewController? = nil,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        let message = String(format: NSLocalizedString("Do you want to continue? This will install \"%@\".", comment: ""), storeApp.name)
        var extraAction: UIAlertAction?
        #if !os(tvOS)
        let version = storeApp.latestSupportedVersion
        if LiveContainerInbox.isAvailable, let url = version?.downloadURL ?? storeApp.downloadURL {
            let name = storeApp.name, sha256 = version?.sha256
            extraAction = UIAlertAction(title: "Install in LiveContainer", style: .default) { _ in
                // The normal install doesn't start; callers get the cancel path.
                onCancel()
                let presenter = presentingViewController ?? UIApplication.shared.topViewController()
                guard let presenter else { return }
                LiveContainerInbox.shared.download(url, name: name, sha256: sha256, from: presenter)
            }
        }
        #endif
        self.presentConfirmation(
            message: message,
            from: presentingViewController,
            extraAction: extraAction,
            onConfirm: onConfirm,
            onCancel: onCancel
        )
    }

    public static func present(
        installedApp: InstalledApp,
        from presentingViewController: UIViewController? = nil,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        let message = String(format: NSLocalizedString("Do you want to continue? This will reinstall \"%@\".", comment: ""), installedApp.name)
        self.presentConfirmation(
            message: message,
            from: presentingViewController,
            onConfirm: onConfirm,
            onCancel: onCancel
        )
    }
    
    private static func presentConfirmation(
        message: String,
        from presentingViewController: UIViewController?,
        extraAction: UIAlertAction? = nil,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        guard UserDefaults.standard.isInstallConfirmationEnabled || extraAction != nil else {
            onConfirm()
            return
        }
        
        let rootVC = presentingViewController ?? UIApplication.shared.topViewController()
        guard let presentingVC = rootVC else {
            onCancel()
            return
        }
        
        let alert = UIAlertController(
            title: NSLocalizedString("Install App", comment: ""),
            message: message,
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: NSLocalizedString("Install", comment: ""), style: .default) { _ in
            onConfirm()
        })
        if let extraAction { alert.addAction(extraAction) }
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel) { _ in
            onCancel()
        })
        
        presentingVC.present(alert, animated: true)
    }
}

#if !os(tvOS)
/// Hands an IPA to the host LiveContainer through a folder it checks on launch.
/// The file is not signed or installed by SideStore.
final class LiveContainerInbox: NSObject, UIDocumentPickerDelegate {
    static let shared = LiveContainerInbox()
    static var isAvailable: Bool { getenv("LC_HOME_PATH") != nil }
    private weak var presenter: UIViewController?

    func pick(from viewController: UIViewController) {
        presenter = viewController
        let types = ["ipa", "tipa"].compactMap { UTType(filenameExtension: $0) }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = self
        viewController.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let source = urls.first else { return }
        // The picker is still dismissing at this point.
        let message = deliver(source, as: source.lastPathComponent)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let presenter = self?.presenter else { return }
            self?.show(message, from: presenter)
        }
    }

    @MainActor
    func download(_ url: URL, name: String, sha256: String?, from viewController: UIViewController) {
        let waiting = UIAlertController(title: "LiveContainer", message: "Скачивается «\(name)»…", preferredStyle: .alert)
        let task = Task { @MainActor in
            let message: String
            do {
                let (file, response) = try await URLSession.shared.download(from: url)
                defer { try? FileManager.default.removeItem(at: file) }
                try Task.checkCancellation()
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    throw Self.fail("Сервер ответил \(http.statusCode).")
                }
                if let sha256 {
                    let data = try Data(contentsOf: file, options: .mappedIfSafe)
                    let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    guard actual == sha256.lowercased() else { throw Self.fail("Контрольная сумма не совпала.") }
                }
                let safeName = name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "_")
                message = self.deliver(file, as: safeName + ".ipa")
            } catch {
                if Task.isCancelled { return }
                DiagnosticLog.error("LiveContainer download", error)
                message = "Не удалось скачать: \(error.localizedDescription)"
            }
            waiting.dismiss(animated: true) { self.show(message, from: viewController) }
        }
        waiting.addAction(UIAlertAction(title: "Отмена", style: .cancel) { _ in
            task.cancel()
        })
        viewController.present(waiting, animated: true)
    }

    private static func fail(_ text: String) -> Error {
        NSError(domain: "SideStore.LiveContainerInbox", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }

    private func deliver(_ source: URL, as fileName: String) -> String {
        do {
            let files = FileManager.default
            let inbox = files.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("LCInbox")
            try files.createDirectory(at: inbox, withIntermediateDirectories: true)
            let target = inbox.appendingPathComponent(fileName)
            // Copy under another extension so a partial file is never picked up.
            let partial = target.appendingPathExtension("part")
            try? files.removeItem(at: partial)
            try files.copyItem(at: source, to: partial)
            try? files.removeItem(at: target)
            try files.moveItem(at: partial, to: target)
            return "Полностью закройте LiveContainer, откройте снова и перейдите на вкладку приложений. Установка начнётся там."
        } catch {
            DiagnosticLog.error("LiveContainer inbox", error)
            return "Не удалось передать файл: \(error.localizedDescription)"
        }
    }

    private func show(_ message: String, from presenter: UIViewController) {
        let alert = UIAlertController(title: "LiveContainer", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presenter.present(alert, animated: true)
    }
}
#endif

#if !os(tvOS)
/// Updates LiveContainer+SideStore: takes the IPA out of a build ZIP and gives
/// it to SideStore's normal installer, which can install over itself.
@MainActor
final class AppUpdater: NSObject, UIDocumentPickerDelegate {
    static let shared = AppUpdater()
    private weak var presenter: UIViewController?
    private var install: ((URL) -> Void)?
    private var busy = false
    private let keychain = KeychainAccess.Keychain(service: "SideStore.updater")

    func pickZip(from viewController: UIViewController, install: @escaping (URL) -> Void) {
        presenter = viewController
        self.install = install
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.zip], asCopy: true)
        picker.delegate = self
        viewController.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let zip = urls.first else { return }
        // Let the picker finish dismissing before presenting alerts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            self.run { try await self.prepare(zip) }
        }
    }

    func askGitHub(from viewController: UIViewController, install: @escaping (URL) -> Void) {
        presenter = viewController
        self.install = install
        let alert = UIAlertController(title: "GitHub Actions",
                                      message: "Репозиторий (автор/имя) и токен только с правом Actions: Read. Пустое поле токена оставит сохранённый.",
                                      preferredStyle: .alert)
        alert.addTextField {
            $0.placeholder = "автор/репозиторий"
            $0.text = UserDefaults.standard.string(forKey: "AppUpdater.repository")
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
        }
        alert.addTextField {
            $0.placeholder = "github_pat_…"
            $0.isSecureTextEntry = true
        }
        alert.addAction(UIAlertAction(title: "Скачать", style: .default) { [weak alert] _ in
            let repository = alert?.textFields?[0].text?.trimmingCharacters(in: .whitespaces) ?? ""
            let typed = alert?.textFields?[1].text?.trimmingCharacters(in: .whitespaces) ?? ""
            if !typed.isEmpty { self.keychain["token"] = typed }
            UserDefaults.standard.set(repository, forKey: "AppUpdater.repository")
            self.run { try await self.downloadAndPrepare(repository) }
        })
        alert.addAction(UIAlertAction(title: "Забыть токен", style: .destructive) { _ in self.keychain["token"] = nil })
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        viewController.present(alert, animated: true)
    }

    private func run(_ work: @escaping () async throws -> (URL, String)) {
        guard !busy, let presenter else { return }
        busy = true
        let waiting = UIAlertController(title: "Обновление", message: "Скачивание и проверка. Не сворачивайте приложение.", preferredStyle: .alert)
        presenter.present(waiting, animated: true) {
            Task { @MainActor in
                let result: Result<(URL, String), Error>
                do { result = .success(try await work()) } catch { result = .failure(error) }
                self.busy = false
                waiting.dismiss(animated: true) { self.finish(result) }
            }
        }
    }

    private func finish(_ result: Result<(URL, String), Error>) {
        let alert: UIAlertController
        switch result {
        case .success(let (ipa, version)):
            alert = UIAlertController(title: "Установить обновление?",
                                      message: "\(version)\nЕсли спросят о расширениях, оставьте их. Приложение может закрыться во время установки.",
                                      preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Установить", style: .default) { _ in self.install?(ipa) })
            alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        case .failure(let error):
            DiagnosticLog.error("AppUpdater", error)
            alert = UIAlertController(title: "Не удалось обновить", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
        }
        presenter?.present(alert, animated: true)
    }

    private func fail(_ text: String) -> Error {
        NSError(domain: "SideStore.AppUpdater", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }

    /// Returns the IPA and a description, or throws if installing it would not update this app.
    private func prepare(_ zip: URL) async throws -> (URL, String) {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("AppUpdater")
        try? files.removeItem(at: root)
        let unpacked = root.appendingPathComponent("zip")
        let check = root.appendingPathComponent("check")
        try files.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try files.createDirectory(at: check, withIntermediateDirectories: true)
        try files.unzipArchive(at: zip, to: unpacked)
        let found = (files.enumerator(at: unpacked, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension.lowercased() == "ipa" }
        guard found.count == 1, let ipa = found.first else {
            throw fail("В ZIP должен быть ровно один .ipa. Это должен быть артефакт сборки, а не diagnostics.")
        }
        let appURL = try files.unzipAppBundle(at: ipa, toDirectory: check)
        defer { try? files.removeItem(at: check) }
        guard let app = ALTApplication(fileURL: appURL),
              files.fileExists(atPath: appURL.appendingPathComponent("Frameworks/SideStoreApp.framework").path),
              files.fileExists(atPath: appURL.appendingPathComponent("PlugIns/LiveProcess.appex").path) else {
            throw fail("Это не сборка LiveContainer+SideStore с LiveProcess.")
        }
        let team = try await AuthManager.shared.getAuthenticatedTeam()
        let current = InstalledApp.fetchAltStore(in: DatabaseManager.shared.viewContext)?.resignedBundleIdentifier
        let incoming = "\(app.bundleIdentifier).\(team.identifier)"
        guard current == incoming else {
            DiagnosticLog.write("updater", "id mismatch current=\(current ?? "nil") incoming=\(incoming)")
            throw fail("Остановлено: bundle ID не совпал (сейчас \(current ?? "неизвестен"), будет \(incoming)). Могла бы появиться вторая копия.")
        }
        return (ipa, "Версия \(app.version) (\(app.buildVersion))")
    }

    private struct ArtifactList: Decodable { let artifacts: [Artifact] }
    private struct Artifact: Decodable {
        struct Run: Decodable {
            let repository_id, head_repository_id: Int?
            let head_branch, head_sha: String?
        }
        let name, created_at: String
        let expired: Bool
        let archive_download_url: URL
        let workflow_run: Run?
    }

    private func downloadAndPrepare(_ repository: String) async throws -> (URL, String) {
        let parts = repository.split(separator: "/")
        guard parts.count == 2, let token = keychain["token"],
              let list = URL(string: "https://api.github.com/repos/\(parts[0])/\(parts[1])/actions/artifacts?per_page=100") else {
            throw fail("Укажите репозиторий как автор/имя и токен.")
        }
        func request(_ url: URL) -> URLRequest {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        }
        func verify(_ response: URLResponse) throws {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw fail("GitHub ответил \(status). Проверьте репозиторий, токен и срок хранения артефакта.") }
        }
        let (body, response) = try await URLSession.shared.data(for: request(list))
        try verify(response)
        // Skip artifacts built from a fork's code.
        let candidates = try JSONDecoder().decode(ArtifactList.self, from: body).artifacts.filter {
            !$0.expired && $0.name.lowercased().contains("livecontainer")
                && $0.workflow_run?.repository_id != nil
                && $0.workflow_run?.repository_id == $0.workflow_run?.head_repository_id
        }
        guard let artifact = candidates.max(by: { $0.created_at < $1.created_at }) else {
            throw fail("Нет действующего артефакта с LiveContainer в названии.")
        }
        let (file, download) = try await URLSession.shared.download(for: request(artifact.archive_download_url),
                                                                    delegate: DropAuthorizationOnRedirect())
        defer { try? FileManager.default.removeItem(at: file) }
        try verify(download)
        let (ipa, version) = try await prepare(file)
        let run = artifact.workflow_run
        return (ipa, "\(version)\nСобрано: \(artifact.created_at)\nВетка: \(run?.head_branch ?? "?"), коммит \(run?.head_sha?.prefix(7) ?? "?")")
    }
}

/// GitHub redirects artifact downloads to storage on another host; the token must not follow.
private final class DropAuthorizationOnRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var redirected = request
        if request.url?.host != "api.github.com" { redirected.setValue(nil, forHTTPHeaderField: "Authorization") }
        completionHandler(redirected)
    }
}
#endif
