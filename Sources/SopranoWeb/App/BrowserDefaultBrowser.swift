import AppKit

/// Settings ▸ Default browser: reads the app macOS opens `https` links with
/// and asks macOS to switch http and https to this app (the system shows its
/// own confirmation).
@MainActor
enum BrowserDefaultBrowser {
    /// The application that opens `https` URLs today.
    static func currentHandler(workspace: NSWorkspace = .shared) -> URL? {
        guard let probe = URL(string: "https://example.com") else { return nil }
        return workspace.urlForApplication(toOpen: probe)
    }

    static func displayName(of application: URL?) -> String {
        guard let application else { return "None" }
        let name = FileManager.default.displayName(atPath: application.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// True when `handler` is the bundle `app` (same bundle identifier).
    static func isDefault(handler: URL?, app: Bundle = .main) -> Bool {
        guard let handler, let identifier = app.bundleIdentifier else { return false }
        return Bundle(url: handler)?.bundleIdentifier == identifier
    }

    /// Only a packaged `.app` can be the default browser.
    static func canBecomeDefault(app: Bundle = .main) -> Bool {
        app.bundleIdentifier != nil && app.bundleURL.pathExtension == "app"
    }

    /// Asks macOS to open http and https with `app`. `completion` runs after
    /// the user answered the system prompt.
    static func makeDefault(app: Bundle = .main, completion: @escaping @MainActor (Error?) -> Void) {
        let url = app.bundleURL
        Task { @MainActor in
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: url, toOpenURLsWithScheme: "http")
                try await NSWorkspace.shared.setDefaultApplication(at: url, toOpenURLsWithScheme: "https")
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }
}
