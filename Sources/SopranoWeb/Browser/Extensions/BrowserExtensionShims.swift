import CryptoKit
import Foundation

/// Native stand-ins for the Chrome APIs WebKit lacks, put into an installed
/// extension's copy. Each stand-in is a section of
/// `BrowserExtensionShimScript` and names what in a manifest asks for it;
/// an extension that asks for none is left as it came.
///
/// For one that does, after the package's CRX3 signatures were checked
/// (`BrowserExtensions.unpackVerified`) or the folder was copied, and again
/// at every load when the shim changed:
/// - `soprano-shim.js` is written into the package with its stand-ins;
/// - the background imports it first: a module worker through
///   `import "/soprano-shim.js";`, a classic worker through
///   `importScripts("/soprano-shim.js");` (after a "use strict" prologue),
///   background scripts with it as their first script;
/// - every HTML page loads it first in its `<head>` (popup, options and
///   the frames an extension shows in pages);
/// - `nativeMessaging` is added to the manifest when missing (the shim talks
///   to the app through it; what was added is kept in `.soprano-added`).
///
/// `.soprano-shim` stamps the shim's version and stand-ins, so a package
/// that already carries this shim is not rewritten. Applying again first
/// takes the previous shim out, so the result is the same however often it
/// runs; an update replaces the package and gets it again.
enum BrowserExtensionShims {
    /// The application id of the shim's native messages.
    static let application = "soprano"
    /// The native port the background hears the app's events on.
    static let eventsPort = "soprano.events"
    /// The native port each WebSocket of a worker runs over.
    static let socketPort = "soprano.socket"
    static let file = "soprano-shim.js"
    static let stampFile = ".soprano-shim"
    static let addedFile = ".soprano-added"
    static let moduleLine = "import \"/\(file)\";"
    static let classicLine = "importScripts(\"/\(file)\");"
    static let htmlTag = "<script src=\"/\(file)\"></script>"

    /// What in a manifest asks for a stand-in.
    enum Trigger: Equatable, Sendable {
        /// A permission in `permissions` or `optional_permissions`.
        case permission(String)
        /// A value at this key path (`["storage", "managed_schema"]`).
        case key([String])
        /// A string at this key path (or in the object there) containing
        /// the text.
        case text([String], String)
    }

    struct StandIn: Equatable, Sendable {
        /// The section of the script (`standIns.has(name)` there).
        let name: String
        /// Any one of them applies the stand-in.
        let triggers: [Trigger]
    }

    /// Every stand-in, each added for the failure that demanded it (see
    /// `docs/STATUS.md`, Stage 4 P2).
    static let standIns: [StandIn] = [
        // `chrome.notifications` is undefined in WebKit; 1Password's
        // background reads `chrome.notifications.onClicked` as it starts.
        StandIn(name: "notifications", triggers: [.permission("notifications")]),
        // `webNavigation.onCreatedNavigationTarget` (and the history-state
        // events) are undefined in WebKit.
        StandIn(name: "webNavigation", triggers: [.permission("webNavigation")]),
        // WebKit has no `storage.managed`; an extension with a managed
        // schema reads its policies there.
        StandIn(name: "storage.managed", triggers: [.key(["storage", "managed_schema"])]),
        // An extension that states a minimum Chrome version reads Chrome's
        // version from the user agent (1Password opens its unlock popup
        // only from Chrome 149).
        StandIn(name: "userAgent", triggers: [.key(["minimum_chrome_version"])]),
        // WebKit throws on an origin with a port in `permissions.contains`
        // (1Password checks the page's origin before filling).
        StandIn(name: "permissions", triggers: [.key(["host_permissions"]), .key(["optional_host_permissions"])]),
        // WebKit serves `.wasm` as application/octet-stream, so streaming
        // compilation fails (1Password's core loads slower, after a warning).
        StandIn(name: "wasm", triggers: [.text(["content_security_policy"], "wasm-unsafe-eval")]),
        // `clients.matchAll()` lists no open extension page in WebKit's
        // worker (1Password's popup would stay on "connecting").
        StandIn(name: "clients", triggers: [.key(["background", "service_worker"])]),
        // A worker's `new WebSocket` never returns in WebKit and freezes the
        // extension (1Password opens one when sign-in succeeds).
        StandIn(name: "webSocket", triggers: [.key(["background", "service_worker"])]),
    ]

    /// The stand-ins `manifest` asks for, in table order.
    static func standIns(for manifest: [String: Any]) -> [String] {
        let permissions = Set(
            ((manifest["permissions"] as? [Any] ?? []) + (manifest["optional_permissions"] as? [Any] ?? []))
                .compactMap { $0 as? String }
        )
        return standIns.filter { standIn in
            standIn.triggers.contains { trigger in
                switch trigger {
                case let .permission(name): permissions.contains(name)
                case let .key(path): value(at: path, in: manifest) != nil
                case let .text(path, text): strings(in: value(at: path, in: manifest)).contains { $0.contains(text) }
                }
            }
        }.map(\.name)
    }

    private static func value(at path: [String], in object: [String: Any]) -> Any? {
        var current: Any? = object
        for key in path {
            guard let dictionary = current as? [String: Any] else { return nil }
            current = dictionary[key]
        }
        return current is NSNull ? nil : current
    }

    /// The strings in a manifest value (itself, or an object's values).
    private static func strings(in value: Any?) -> [String] {
        switch value {
        case let string as String: [string]
        case let object as [String: Any]: object.values.flatMap { strings(in: $0) }
        case let list as [Any]: list.flatMap { strings(in: $0) }
        default: []
        }
    }

    /// The script as an extension with `standIns` gets it.
    static func script(standIns: [String]) -> String {
        let list = (try? JSONSerialization.data(withJSONObject: standIns)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return BrowserExtensionShimScript.source
            .replacingOccurrences(of: "__SOPRANO_STAND_INS__", with: list)
            .replacingOccurrences(of: "__SOPRANO_CHROME_VERSION__", with: BrowserWebStore.chromeVersion)
            .replacingOccurrences(of: "__SOPRANO_APPLICATION__", with: application)
            .replacingOccurrences(of: "__SOPRANO_EVENTS_PORT__", with: eventsPort)
            .replacingOccurrences(of: "__SOPRANO_SOCKET_PORT__", with: socketPort)
    }

    /// What `.soprano-shim` holds for `standIns`: the script's hash and the
    /// stand-ins, so a changed shim or manifest prepares the package again.
    static func stamp(standIns: [String]) -> String {
        let digest = SHA256.hash(data: Data(script(standIns: standIns).utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined() + " " + standIns.joined(separator: ",")
    }

    enum Failure: Error, CustomStringConvertible {
        case unreadableManifest
        case outside(String)

        var description: String {
            switch self {
            case .unreadableManifest: "the manifest can't be read"
            case let .outside(path): "\(path) is not a file inside the package"
            }
        }
    }

    /// Puts the shim into the package at `folder`, or takes it out when the
    /// manifest asks for no stand-in. `fresh`: a package just unpacked or
    /// copied in, where any `.soprano-*` file came with the package and is
    /// not ours. Returns the stand-ins the package now carries.
    @discardableResult
    static func prepare(_ folder: URL, fresh: Bool) throws -> [String] {
        let fileManager = FileManager.default
        let stampURL = folder.appendingPathComponent(stampFile)
        let addedURL = folder.appendingPathComponent(addedFile)
        if fresh {
            try? fileManager.removeItem(at: stampURL)
            try? fileManager.removeItem(at: addedURL)
        }
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard let original = try? BrowserExtensionArchive.checkManifest(at: folder) else { throw Failure.unreadableManifest }
        var manifest = original
        let names = standIns(for: manifest)
        let previous = try? String(contentsOf: stampURL, encoding: .utf8)
        if names.isEmpty, previous == nil { return [] }
        if let previous, previous == stamp(standIns: names) { return names }

        // Take out what an earlier shim put in.
        var added = (try? JSONSerialization.jsonObject(with: Data(contentsOf: addedURL))) as? [String] ?? []
        if previous != nil {
            if var permissions = manifest["permissions"] as? [Any] {
                permissions.removeAll { ($0 as? String).map(added.contains) ?? false }
                manifest["permissions"] = permissions
            }
            added = []
        }
        var background = manifest["background"] as? [String: Any]
        if var scripts = background?["scripts"] as? [Any] {
            scripts.removeAll { ($0 as? String).map(isShimPath) ?? false }
            background?["scripts"] = scripts
        }
        let worker = (background?["service_worker"] as? String).map { try? inside($0, of: folder) } ?? nil
        var workerSource = try worker.map { url -> String in
            guard let text = readText(url) else { throw Failure.outside(url.lastPathComponent) }
            return removeWorkerLine(from: text)
        }
        let pages = htmlPages(in: folder)
        var pageSources = pages.compactMap { url in
            readText(url).map { (url, removeTag(from: $0)) }
        }

        if names.isEmpty {
            try? fileManager.removeItem(at: folder.appendingPathComponent(file))
        } else {
            try Data(script(standIns: names).utf8).write(to: folder.appendingPathComponent(file), options: .atomic)
            var permissions = manifest["permissions"] as? [Any] ?? []
            if !permissions.contains(where: { ($0 as? String) == "nativeMessaging" }) {
                permissions.append("nativeMessaging")
                added.append("nativeMessaging")
            }
            manifest["permissions"] = permissions
            if var scripts = background?["scripts"] as? [Any] {
                scripts.insert(file, at: 0)
                background?["scripts"] = scripts
            }
            if let source = workerSource {
                let module = (background?["type"] as? String) == "module"
                workerSource = addWorkerLine(to: source, module: module)
            }
            pageSources = pageSources.map { ($0.0, addTag(to: $0.1)) }
        }
        if let background { manifest["background"] = background }

        if let worker, let workerSource {
            try writeText(workerSource, to: worker)
        }
        for (url, source) in pageSources {
            try writeText(source, to: url)
        }
        if !NSDictionary(dictionary: manifest).isEqual(to: original) {
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: manifestURL, options: .atomic)
        }
        if names.isEmpty {
            try? fileManager.removeItem(at: stampURL)
            try? fileManager.removeItem(at: addedURL)
        } else {
            try JSONSerialization.data(withJSONObject: added).write(to: addedURL, options: .atomic)
            try Data(stamp(standIns: names).utf8).write(to: stampURL, options: .atomic)
        }
        return names
    }

    // MARK: - Worker

    private static func isShimPath(_ path: String) -> Bool {
        path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == file
    }

    /// The worker's text without the shim's first line.
    static func removeWorkerLine(from source: String) -> String {
        var lines = source.components(separatedBy: "\n")
        lines.removeAll { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed == moduleLine || trimmed == classicLine
        }
        return lines.joined(separator: "\n")
    }

    /// The worker with the shim first: a module imports it (imports run
    /// before the module's own code); a classic worker loads it after its
    /// directive prologue, so a leading "use strict" still applies.
    static func addWorkerLine(to source: String, module: Bool) -> String {
        var text = source
        var prefix = ""
        if text.hasPrefix("\u{FEFF}") {
            prefix = "\u{FEFF}"
            text.removeFirst()
        }
        if module {
            return prefix + moduleLine + "\n" + text
        }
        let prologue = directivePrologueEnd(in: text)
        let head = String(text[..<prologue])
        let rest = String(text[prologue...])
        return prefix + head + (head.isEmpty || head.hasSuffix("\n") ? "" : "\n") + classicLine + "\n" + rest
    }

    /// A UTF-8 file's text with its byte-order mark kept as U+FEFF
    /// (Foundation's decoding drops it, and a rewrite would lose it).
    private static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let mark = data.starts(with: [0xEF, 0xBB, 0xBF])
        guard let text = String(data: data.dropFirst(mark ? 3 : 0), encoding: .utf8) else { return nil }
        return (mark ? "\u{FEFF}" : "") + text
    }

    private static func writeText(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// Where a leading `"use strict";` line (or several) ends: a statement
    /// put before it would turn the directive into a plain expression.
    private static func directivePrologueEnd(in text: String) -> String.Index {
        let pattern = #"^(?:[ \t\r\n]*(['"])use strict\1[ \t]*;?[ \t]*(?:\r?\n|$))+"#
        return text.range(of: pattern, options: .regularExpression)?.upperBound ?? text.startIndex
    }

    // MARK: - Pages

    private static func htmlPages(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return [] }
        var pages: [URL] = []
        for case let url as URL in walker {
            guard ["html", "htm"].contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, values.isSymbolicLink != true
            else { continue }
            pages.append(url)
        }
        return pages.sorted { $0.path < $1.path }
    }

    static func removeTag(from html: String) -> String {
        html.replacingOccurrences(of: htmlTag, with: "")
    }

    /// The page with the shim's tag first in its `<head>` (after `<html>`,
    /// else the doctype, else at the start when it has no head).
    static func addTag(to html: String) -> String {
        var html = html
        for pattern in ["<head(\\s[^>]*)?>", "<html(\\s[^>]*)?>", "<!doctype[^>]*>"] {
            if let range = html.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                html.insert(contentsOf: htmlTag, at: range.upperBound)
                return html
            }
        }
        return htmlTag + html
    }

    /// A path the manifest names, inside the package and not a link.
    static func inside(_ path: String, of folder: URL) throws -> URL {
        let base = folder.standardizedFileURL.resolvingSymlinksInPath()
        let url = base.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).standardizedFileURL
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard url.path.hasPrefix(base.path + "/"), values?.isRegularFile == true, values?.isSymbolicLink != true,
              url.resolvingSymlinksInPath().path.hasPrefix(base.path + "/")
        else { throw Failure.outside(path) }
        return url
    }
}
