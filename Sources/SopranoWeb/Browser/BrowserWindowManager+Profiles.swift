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

    /// The profile of a window's current Space (Default while its own is
    /// being deleted).
    func profile(of controller: BrowserWindowController) -> BrowserProfile {
        profiles.profile(id: controller.profileID) ?? .defaultProfile
    }

    /// What a window shows next to its tabs: "Private" (with its profile
    /// when more than one exists), or its current Space (icon, name and
    /// color) when more than one Space exists.
    func windowMark(for controller: BrowserWindowController) -> BrowserWindowMark {
        let profile = profiles.hasSeveral ? profile(of: controller) : nil
        if let space = controller.currentSpaceID.flatMap(spaces.space(id:)), spaces.spaces.count > 1 {
            return BrowserWindowMark(space: space, profile: profile)
        }
        return BrowserWindowMark(kind: controller.kind, profile: profile)
    }

    /// The windows deleting profile `id` closes: its private and pop-up
    /// windows, and every normal window holding only the profile's tabs.
    func windowsClosing(onDeleteOf id: UUID) -> [BrowserWindowController] {
        controllers.filter { controller in
            controller.hasSpaces
                ? !controller.tabs.isEmpty && controller.tabs.allSatisfy { $0.dataContext.profileID == id }
                : controller.profileID == id
        }
    }

    /// Every open tab of profile `id`, in any window or Space, private
    /// windows over it included: what deleting it closes.
    func openTabCount(ofProfile id: UUID) -> Int {
        controllers.reduce(0) { count, controller in
            count + controller.tabs.count { $0.dataContext.profileID == id }
        }
    }

    /// Settings ▸ Profiles ▸ Delete (after the confirmation): closes the
    /// profile's tabs in every window (a window on one of its Spaces shows
    /// another Space first; `windowsClosing(onDeleteOf:)` close whole) and
    /// its private windows, none onto Recently Closed; drops its Recently
    /// Closed tabs and its Archive; deletes its Spaces and favorites;
    /// removes it from `profiles.json`; then, once its web views are
    /// released, removes its data store
    /// (`WKWebsiteDataStore.remove(forIdentifier:)`) and deletes its
    /// folder. `completion` gets the data store removal's error, if it
    /// never succeeded. Default can't be deleted.
    func deleteProfile(_ id: UUID, completion: (@MainActor (Error?) -> Void)? = nil) {
        guard id != BrowserProfile.defaultID, let profile = profiles.profile(id: id) else {
            completion?(nil)
            return
        }
        let closing = windowsClosing(onDeleteOf: id)
        for controller in closing {
            closeWindow(controller, remember: false)
        }
        for controller in controllers where !closing.contains(where: { $0 === controller }) {
            controller.closeTabs(ofProfile: id)
        }
        recentlyClosed.removeEntries(ofProfile: id, spaces: Set(spaces.spaces(ofProfile: id).map(\.id)))
        archive.removeEntries(ofProfile: id)
        spaces.deleteSpaces(ofProfile: id)
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

    /// Removes a kept profile's data store (the harness keeps an import's
    /// profiles in `--support-dir` but no WebKit store): its tabs close,
    /// its context goes, then the store is removed once released.
    func releaseDataStore(ofProfile id: UUID, completion: @escaping @MainActor (Error?) -> Void) {
        for controller in controllers {
            controller.closeTabs(ofProfile: id)
        }
        profileContexts[id] = nil
        Task { @MainActor in
            completion(await Self.removeDataStore(identifier: id))
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
