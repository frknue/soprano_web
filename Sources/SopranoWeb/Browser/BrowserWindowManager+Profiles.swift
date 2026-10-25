import AppKit
import WebKit

/// Profiles: one data context per profile, made on first use, and deleting
/// a profile with its windows and data.
extension BrowserWindowManager {
    /// How often, and how far apart, deleting a profile tries to remove its
    /// data store: WebKit refuses while a web view of it is still alive.
    static let dataStoreRemovalAttempts = 20
    static let dataStoreRemovalDelay: TimeInterval = 0.25

    /// The normal context of profile `profileID`: Default's for Default or
    /// a profile that no longer exists, else the profile's own (its
    /// `WKWebsiteDataStore(forIdentifier:)`, History and site decisions in
    /// `<support>/Profiles/<id>/`), made the first time it is asked for and
    /// shared by every window of the profile.
    func context(for profileID: UUID) -> BrowserDataContext {
        guard profileID != BrowserProfile.defaultID, let profile = profiles.profile(id: profileID) else {
            return defaultContext
        }
        if let context = profileContexts[profileID] {
            return context
        }
        let directory = profile.directory(in: supportDirectory)
        let context = BrowserDataContext(
            kind: .normal,
            profileID: profileID,
            websiteDataStore: WKWebsiteDataStore(forIdentifier: profileID),
            history: history(for: profile),
            sitePermissions: BrowserSitePermissionStore(
                url: directory.appendingPathComponent("site-permissions.json")
            ),
            faviconStore: faviconStore,
            connectionSecurity: BrowserConnectionSecurity()
        )
        profileContexts[profileID] = context
        return context
    }

    /// The profile's History (`<its folder>/History.sqlite`), opened on
    /// first use.
    func history(for profile: BrowserProfile) -> BrowserHistoryStore {
        if let store = historyStores[profile.id] {
            return store
        }
        let store = BrowserHistoryStore(directory: profile.directory(in: supportDirectory))
        historyStores[profile.id] = store
        return store
    }

    /// The profile a window belongs to (Default while its own is being
    /// deleted).
    func profile(of controller: BrowserWindowController) -> BrowserProfile {
        profiles.profile(id: controller.profileID) ?? .defaultProfile
    }

    /// What a window shows next to its tabs: "Private", its profile when
    /// more than one exists, or both.
    func windowMark(for controller: BrowserWindowController) -> BrowserWindowMark {
        BrowserWindowMark(kind: controller.kind, profile: profiles.hasSeveral ? profile(of: controller) : nil)
    }

    /// Settings ▸ Profiles ▸ Delete (after the confirmation): closes every
    /// window of the profile, private ones opened over it included,
    /// without putting them on Recently Closed; drops its Recently Closed
    /// entries; removes it from `profiles.json`; then, once its web views
    /// are released, removes its data store
    /// (`WKWebsiteDataStore.remove(forIdentifier:)`) and deletes its folder.
    /// `completion` gets the data store removal's error, if it never
    /// succeeded. Default can't be deleted.
    func deleteProfile(_ id: UUID, completion: (@MainActor (Error?) -> Void)? = nil) {
        guard id != BrowserProfile.defaultID, let profile = profiles.profile(id: id) else {
            completion?(nil)
            return
        }
        for controller in controllers where controller.profileID == id {
            closeWindow(controller, remember: false)
        }
        recentlyClosed.removeAll { $0.profileID == id }
        // Everything still holding the profile's stores (Settings sheets,
        // chrome) lets go when the list changes.
        profiles.remove(id: id)
        profileContexts[id] = nil
        historyStores[id] = nil
        scheduleSessionSave()
        let folder = profile.directory(in: supportDirectory)
        Task { @MainActor in
            let error = await Self.removeDataStore(identifier: id)
            if let error {
                FileHandle.standardError.write(
                    Data("Profile data store removal failed: \(error.localizedDescription)\n".utf8)
                )
            }
            try? FileManager.default.removeItem(at: folder)
            completion?(error)
        }
    }

    /// Removes a deleted profile's data store, retrying while WebKit still
    /// counts it in use (closed windows release their web views once AppKit
    /// has finished closing them). Returns the last error, nil on success.
    private static func removeDataStore(identifier: UUID) async -> Error? {
        var lastError: Error?
        for _ in 0..<dataStoreRemovalAttempts {
            try? await Task.sleep(for: .seconds(dataStoreRemovalDelay))
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: identifier)
                return nil
            } catch {
                lastError = error
            }
        }
        return lastError
    }
}
