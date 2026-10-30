import Foundation

/// Reads Chromium's `Bookmarks` JSON (Chrome, Brave, Edge, Vivaldi,
/// Chromium) and finds Chromium profiles.
enum BrowserChromeBookmarksReader {
    /// `browser`'s user-data folder under `home`, when it exists.
    static func userDataDirectory(of browser: BrowserImportSourceKind, home: URL) -> URL? {
        guard let path = browser.chromiumFolder else { return nil }
        let url = home.appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(path, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return url
    }

    /// The folder exists but listing it is refused (macOS privacy
    /// protection for another app's data).
    static func isUnreadable(_ folder: URL) -> Bool {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            return false
        } catch let error as CocoaError {
            return error.code == .fileReadNoPermission
        } catch {
            return false
        }
    }

    /// The roots that hold bookmarks, in Chrome's order, with the name
    /// used when the file stores none.
    private static let roots: [(key: String, name: String)] = [
        ("bookmark_bar", "Bookmarks Bar"),
        ("other", "Other Bookmarks"),
        ("synced", "Mobile Bookmarks"),
    ]

    /// Every non-empty root (bookmarks bar, other, mobile) as a folder named
    /// as Chrome names it. Nodes that are neither a URL nor a folder, and
    /// URLs without a value, are skipped.
    static func read(fileURL: URL) throws -> [BrowserImportedNode] {
        guard let data = FileManager.default.contents(atPath: fileURL.path) else {
            throw BrowserImportError.missingFile(fileURL)
        }
        guard let nodes = nodes(from: data) else {
            throw BrowserImportError.unreadable(fileURL, "not a Chrome Bookmarks file")
        }
        return nodes
    }

    /// `nil` when `data` is not a JSON object with `roots`.
    static func nodes(from data: Data) -> [BrowserImportedNode]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rootsObject = object["roots"] as? [String: Any]
        else { return nil }
        return roots.compactMap { (root: (key: String, name: String)) -> BrowserImportedNode? in
            guard let json = rootsObject[root.key] as? [String: Any] else { return nil }
            let children = (json["children"] as? [Any] ?? []).compactMap(node)
            guard !children.isEmpty else { return nil }
            let name = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? root.name
            return .folder(BrowserImportedFolder(name: name, addedAt: date(json["date_added"]), children: children))
        }
    }

    /// The profiles in a Chromium user-data folder (Chrome's, Arc's
    /// `User Data`), named from `Local State`'s `profile.info_cache`, in
    /// `profile.profiles_order` (else Default first, then by folder name).
    /// Only profiles whose folder exists are returned; without a readable
    /// `Local State` the `Default` and `Profile N` folders are listed under
    /// their folder names.
    static func profiles(userDataDirectory: URL) -> [BrowserImportedProfile] {
        let fileManager = FileManager.default
        func folder(_ key: String) -> URL? {
            var isDirectory: ObjCBool = false
            let url = userDataDirectory.appendingPathComponent(key, isDirectory: true)
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return nil
            }
            return url
        }

        var names: [String: String] = [:]
        var order: [String] = []
        let localState = userDataDirectory.appendingPathComponent("Local State")
        if let data = fileManager.contents(atPath: localState.path),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let profile = object["profile"] as? [String: Any] {
            for (key, value) in profile["info_cache"] as? [String: Any] ?? [:] {
                let name = (value as? [String: Any])?["name"] as? String
                names[key] = name.flatMap { $0.isEmpty ? nil : $0 } ?? key
            }
            order = (profile["profiles_order"] as? [String] ?? []).filter { names[$0] != nil }
        }
        if names.isEmpty {
            let entries = (try? fileManager.contentsOfDirectory(atPath: userDataDirectory.path)) ?? []
            for entry in entries where entry == BrowserImportedProfile.defaultKey || entry.hasPrefix("Profile ") {
                names[entry] = entry
            }
        }
        let rest = names.keys.filter { !order.contains($0) }.sorted { lhs, rhs in
            if lhs == BrowserImportedProfile.defaultKey { return rhs != lhs }
            if rhs == BrowserImportedProfile.defaultKey { return false }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        return (order + rest).compactMap { key in
            guard let directory = folder(key) else { return nil }
            return BrowserImportedProfile(key: key, displayName: names[key] ?? key, directory: directory)
        }
    }

    // MARK: Private

    private static func node(_ any: Any) -> BrowserImportedNode? {
        guard let json = any as? [String: Any] else { return nil }
        let name = json["name"] as? String ?? ""
        switch json["type"] as? String ?? "" {
        case "url":
            guard let url = json["url"] as? String, !url.isEmpty else { return nil }
            return .link(BrowserImportedLink(url: url, title: name, addedAt: date(json["date_added"])))
        case "folder":
            let children = (json["children"] as? [Any] ?? []).compactMap(node)
            return .folder(BrowserImportedFolder(name: name, addedAt: date(json["date_added"]), children: children))
        default:
            return nil
        }
    }

    /// Chrome writes `date_added` as a decimal string of microseconds since 1601.
    private static func date(_ any: Any?) -> Date? {
        let microseconds: Int64?
        switch any {
        case let string as String: microseconds = Int64(string)
        case let number as NSNumber: microseconds = number.int64Value
        default: microseconds = nil
        }
        guard let microseconds, microseconds > 0 else { return nil }
        return BrowserChromiumTime.date(microseconds: microseconds)
    }
}
