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
                default:
                    throw BrowserAutomationError.invalidArguments(BrowserCommandRequest.extensionUsage)
                }
            } catch {
                completion(.failure(error))
            }
        }
    }
}
