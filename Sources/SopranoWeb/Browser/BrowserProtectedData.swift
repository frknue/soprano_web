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

    private static func normalized(_ url: URL) -> String {
        var path = url.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
