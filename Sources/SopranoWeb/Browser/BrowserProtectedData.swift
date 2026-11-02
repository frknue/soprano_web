import Foundation

/// The installed app's own data and its backups, which the harness and
/// `data-check` never open: the daily driver's support folder (stores write
/// their files back) and `Soprano Web Backups` (files there are hard links
/// shared by several backups, so a write would change every one of them).
/// Agents work on copies (`scripts/data-guard.py`).
enum BrowserProtectedData {
    static var folders: [URL] {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return [
            support.appendingPathComponent("Soprano Web", isDirectory: true),
            support.appendingPathComponent("Soprano Web Backups", isDirectory: true),
        ]
    }

    /// `url` is one of those folders or inside one. Paths compare without
    /// case (APFS's default) after links and `..` are resolved.
    static func contains(_ url: URL) -> Bool {
        let path = normalized(url)
        return folders.map(normalized).contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Links under `folder` that lead out of it: a store opening one would
    /// read and write wherever it points, not the copy.
    static func escapingLinks(in folder: URL) -> [String] {
        let root = normalized(folder)
        guard let walker = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else { return [] }
        var found: [String] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true else { continue }
            let target = normalized(url)
            if target != root, !target.hasPrefix(root + "/") {
                found.append(url.path)
            }
        }
        return found
    }

    private static func normalized(_ url: URL) -> String {
        var path = url.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
