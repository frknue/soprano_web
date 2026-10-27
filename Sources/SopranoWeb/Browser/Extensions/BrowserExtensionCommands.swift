import Foundation
import WebKit

/// The `browser` CLI's `extensions` and `extension …` commands, so an agent
/// can install, list and switch extensions and read their errors.
@MainActor
enum BrowserExtensionCommands {
    /// One line per installed extension:
    /// `<id>\t<name>\t<version>\t<state>\t<private>\t<site access>\t<source>\terrors <n>`.
    static func list(_ extensions: BrowserExtensions) -> String {
        guard !extensions.records.isEmpty else { return "No extensions installed." }
        return extensions.records.map { line(for: $0, in: extensions) }.joined(separator: "\n")
    }

    static func line(for record: BrowserExtensionRecord, in extensions: BrowserExtensions) -> String {
        let source = switch record.source {
        case .webStore: "webstore"
        case let .folder(path): "folder \(path)"
        }
        let sites = record.siteAccess == .specificSites ? " \(record.allowedSites.joined(separator: ","))" : ""
        return [
            record.id,
            record.name,
            record.version,
            state(of: record, in: extensions),
            record.allowsPrivate ? "private" : "-",
            record.siteAccess.rawValue + sites,
            source,
            "errors \(errors(of: record.id, in: extensions).count)",
        ].joined(separator: "\t")
    }

    static func state(of record: BrowserExtensionRecord, in extensions: BrowserExtensions) -> String {
        if extensions.busy.contains(record.id) { return "installing" }
        if !record.isEnabled { return "off" }
        return extensions.context(id: record.id) == nil ? "not running" : "on"
    }

    /// What WebKit reported for the extension (its package and its
    /// running context), and why it isn't loaded.
    static func errors(of id: String, in extensions: BrowserExtensions) -> [String] {
        var messages: [String] = []
        if let error = extensions.loadErrors[id] { messages.append(error) }
        if let error = extensions.backgroundErrors[id] { messages.append("Background: \(error)") }
        if let context = extensions.context(id: id) {
            for error in context.webExtension.errors + context.errors {
                let message = (error as NSError).localizedDescription
                if !messages.contains(message) { messages.append(message) }
            }
        }
        return messages
    }

    static func perform(
        _ arguments: [String],
        in extensions: BrowserExtensions,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let action = arguments.first ?? ""
        let id = arguments.dropFirst().first ?? ""
        Task { @MainActor in
            do {
                switch action {
                case "install":
                    let record = try await extensions.install(id)
                    completion(.success("installed " + line(for: extensions.store.record(id: record.id) ?? record, in: extensions)))
                case "enable", "disable":
                    try await extensions.setEnabled(id, action == "enable")
                    guard let record = extensions.store.record(id: id) else { throw BrowserExtensions.InstallError.notInstalled(id) }
                    completion(.success(line(for: record, in: extensions)))
                case "remove":
                    let name = extensions.store.record(id: id)?.name ?? id
                    try await extensions.remove(id)
                    completion(.success("removed \(id) \(name)"))
                case "errors":
                    guard extensions.store.record(id: id) != nil else { throw BrowserExtensions.InstallError.notInstalled(id) }
                    let messages = errors(of: id, in: extensions)
                    completion(.success(messages.isEmpty ? "No errors." : messages.joined(separator: "\n")))
                case "update":
                    let updated = await extensions.checkForUpdates(force: true)
                    completion(.success(updated.isEmpty ? "Everything is up to date." : "updated \(updated.joined(separator: " "))"))
                case "action":
                    let screenshot = arguments.count > 2 ? arguments[2] : nil
                    completion(.success(try await clickAction(id, screenshot: screenshot, in: extensions)))
                default:
                    throw BrowserAutomationError.invalidArguments(BrowserCommandRequest.extensionUsage)
                }
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// `extension action <id> [png]`: clicks the extension's toolbar button
    /// in the window commands use. A popup that opens is waited for (its
    /// page loaded, 2 s to build) and reported with its address, size and
    /// text; the PNG is its capture.
    static func clickAction(_ id: String, screenshot: String?, in extensions: BrowserExtensions) async throws -> String {
        guard extensions.store.record(id: id) != nil else { throw BrowserExtensions.InstallError.notInstalled(id) }
        guard extensions.context(id: id) != nil else { throw BrowserAutomationError.unavailable("\(id) is not running.") }
        guard let window = extensions.manager?.keyController ?? extensions.manager?.activeController else {
            throw BrowserAutomationError.unavailable("No window is open.")
        }
        extensions.closePopup()
        window.performExtensionAction(id)
        try await Task.sleep(for: .seconds(1))
        guard let popup = extensions.popup, popup.extensionID == id else {
            return "action ran (no popup)"
        }
        for _ in 0..<50 where popup.webView.isLoading {
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .seconds(2))
        popup.fitToContent()
        try await Task.sleep(for: .milliseconds(300))
        let text = (try? await popup.webView.evaluateJavaScript("document.body ? document.body.innerText : ''") as? String) ?? ""
        let size = popup.popover.contentSize
        var lines = ["popup \(popup.webView.url?.absoluteString ?? popup.url.absoluteString) \(Int(size.width))x\(Int(size.height)) shown \(popup.popover.isShown)"]
        if let screenshot {
            let image = try await popup.webView.takeSnapshot(configuration: nil)
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else { throw BrowserAutomationError.screenshot("WebKit could not encode the screenshot") }
            try png.write(to: URL(fileURLWithPath: screenshot), options: .atomic)
            lines.append("screenshot \(screenshot)")
        }
        lines.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
        return lines.joined(separator: "\n")
    }
}
