import AppKit

/// `SopranoWeb data-check <support folder> <settings.json>`: reads every
/// store the way the app does at launch and prints one JSON summary of
/// what it sees (settings, profiles, Spaces with their pins and
/// favorites, the session's windows and tabs, Archive, History per
/// profile, site decisions, extensions, link rules, Boosts, downloads),
/// plus the files reading them moved aside or added (`*.corrupt`,
/// `*.unreadable`, `*.migrated`). `scripts/data-guard.py` runs it with the
/// installed build and the new one on copies of the user's data before an
/// install: the new build must see everything the installed one sees.
///
/// Only the two paths given are touched (stores may write their files
/// back, so they must be copies); nothing reads `UserDefaults`, WebKit or
/// the app's own folders.
@MainActor
enum BrowserDataCheck {
    /// Found in the binary by `data-guard.py` before it runs an installed
    /// build: one without it would start the app instead.
    static let marker = "soprano-web-data-check/1"

    static func run(arguments: [String]) -> Int32 {
        guard arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: SopranoWeb data-check <support folder> <settings.json>\n".utf8))
            return 2
        }
        let support = URL(fileURLWithPath: arguments[0], isDirectory: true)
        let settings = URL(fileURLWithPath: arguments[1])
        // Stores write their files back: never the real data or a backup.
        guard !BrowserProtectedData.contains(support), !BrowserProtectedData.contains(settings) else {
            FileHandle.standardError.write(Data("data-check: give it copies, not the installed app's data or a backup\n".utf8))
            return 2
        }
        let leaving = BrowserProtectedData.escapingLinks(in: support)
        guard leaving.isEmpty else {
            FileHandle.standardError.write(Data("data-check: links lead out of the copy: \(leaving.joined(separator: ", "))\n".utf8))
            return 2
        }
        let report = summary(support: support, settingsURL: settings)
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]),
              let text = String(data: data, encoding: .utf8)
        else { return 1 }
        print(text)
        return 0
    }

    static func summary(support: URL, settingsURL: URL) -> [String: Any] {
        let before = asideFiles(support: support, settingsURL: settingsURL)
        var report: [String: Any] = ["marker": marker]

        let settingsExists = FileManager.default.fileExists(atPath: settingsURL.path)
        let decodedSettings = JSONFile.read(BrowserSettings.self, at: settingsURL)
        report["settings"] = [
            "exists": settingsExists,
            "readable": !settingsExists || decodedSettings != nil,
            "values": encoded(decodedSettings ?? .default),
        ]

        let profiles = BrowserProfileStore(url: support.appendingPathComponent("profiles.json"))
        report["profiles"] = profiles.profiles.map {
            // Which WebKit data store holds the profile's logins and site
            // data: a build that changes it loses them on first launch.
            ["id": $0.id.uuidString, "name": $0.name, "dataStore": $0.dataStoreIdentifier?.uuidString ?? "default"]
        }

        let spaces = BrowserSpaceStore(url: support.appendingPathComponent("spaces.json"), profiles: profiles.profiles)
        report["spaces"] = spaces.spaces.map { space -> [String: Any] in
            [
                "id": space.id.uuidString,
                "name": space.name,
                "profile": space.profileID.uuidString,
                "pins": space.pinned.root.allPins.map(\.url),
                "favorites": spaces.favorites(ofProfile: space.profileID).map(\.url),
            ]
        }

        let session = BrowserSessionStore(url: support.appendingPathComponent("session.json"))
        let sessionExists = FileManager.default.fileExists(atPath: session.url.path)
        let loaded = session.load()
        report["session"] = [
            "exists": sessionExists,
            "readable": !sessionExists || loaded != nil,
            "windows": loaded?.windows.count ?? 0,
            "tabs": loaded?.windows.map { $0.tabs.map { $0.url ?? "" } } ?? [],
            "recentlyClosed": loaded?.recentlyClosed.count ?? 0,
        ]

        let archive = BrowserArchiveStore(url: support.appendingPathComponent("archive.json"))
        report["archive"] = archive.entries.count

        var history: [String: Any] = [:]
        var permissions: [String: Any] = [:]
        for profile in profiles.profiles {
            let directory = profile.directory(in: support)
            let key = profile.id.uuidString
            let store = BrowserHistoryStore(directory: directory)
            history[key] = ["persistent": store.isPersistent, "pages": store.pageCount(), "visits": store.visitCount()]
            let sites = BrowserSitePermissionStore(url: directory.appendingPathComponent("site-permissions.json"))
            permissions[key] = sites.sites.count
        }
        report["history"] = history
        report["sitePermissions"] = permissions

        let extensions = BrowserExtensionStore(supportDirectory: support)
        report["extensions"] = extensions.records.map {
            ["id": $0.id, "name": $0.name, "version": $0.version, "enabled": $0.isEnabled]
        }
        // Where WebKit keeps the extensions' own storage (1Password's
        // sign-in): the controller, and the scheme of each base URL.
        report["webExtensionStorage"] = [
            "controller": BrowserExtensions.controllerIdentifier.uuidString,
            "scheme": BrowserExtensions.scheme,
        ]
        report["linkRouting"] = BrowserLinkRoutingStore(url: support.appendingPathComponent("link-routing.json")).rules.count
        report["boosts"] = BrowserBoostStore(url: support.appendingPathComponent("boosts.json")).boosts.count
        report["downloads"] = BrowserDownloadStore(url: support.appendingPathComponent("downloads.json")).records.count

        let after = asideFiles(support: support, settingsURL: settingsURL)
        report["movedAside"] = after.filter { !before.contains($0) }
        return report
    }

    /// Settings as `settings.json` would hold them.
    private static func encoded(_ settings: BrowserSettings) -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(settings),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return [:] }
        return object
    }

    /// Files a store keeps when it can't read or migrates one: anywhere in
    /// the support folder (relative to it), and beside `settings.json`.
    private static func asideFiles(support: URL, settingsURL: URL) -> [String] {
        func isAside(_ name: String) -> Bool {
            name.hasSuffix(".corrupt") || name.hasSuffix(".unreadable") || name.hasSuffix(".migrated")
        }
        let root = support.resolvingSymlinksInPath().path
        var found: [String] = []
        if let walker = FileManager.default.enumerator(at: support.resolvingSymlinksInPath(), includingPropertiesForKeys: nil) {
            for case let url as URL in walker where isAside(url.lastPathComponent) {
                let path = url.resolvingSymlinksInPath().path
                found.append(path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path)
            }
        }
        let settingsFolder = settingsURL.deletingLastPathComponent()
        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: settingsFolder.path)) ?? []
        found += siblings.filter { $0.hasPrefix(settingsURL.lastPathComponent) && isAside($0) }.map { "settings/\($0)" }
        return found.sorted()
    }
}
