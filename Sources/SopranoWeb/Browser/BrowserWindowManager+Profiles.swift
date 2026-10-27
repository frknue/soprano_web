import AppKit
import WebKit

/// Spaces and their data: one data context per Space's profile, made on
/// first use; creating a Space with its profile and deleting a Space with
/// its windows and data.
extension BrowserWindowManager {
    /// How often, and how far apart, deleting a profile tries to remove its
    /// data store: WebKit refuses while a web view of it is still alive.
    static let dataStoreRemovalAttempts = 20
    static let dataStoreRemovalDelay: TimeInterval = 0.25

    /// The normal context of profile `profileID` (a Space's data):
    /// Default's for Default or a profile that no longer exists, else the
    /// profile's own (its `WKWebsiteDataStore(forIdentifier:)`, History and
    /// site decisions in `<support>/Profiles/<id>/`), made the first time
    /// it is asked for and shared by every window showing its Space.
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

    /// The Space a window's data belongs to: its current Space, a private
    /// or pop-up window's the one it was opened over.
    func space(of controller: BrowserWindowController) -> BrowserSpace? {
        controller.currentSpaceID.flatMap(spaces.space(id:)) ?? spaces.space(ofProfile: controller.profileID)
    }

    /// What a window shows next to its tabs: its Space (icon, name and
    /// color) when more than one Space exists, "Private" (with that Space
    /// when there are several) in a private window.
    func windowMark(for controller: BrowserWindowController) -> BrowserWindowMark {
        BrowserWindowMark(kind: controller.kind, space: spaces.spaces.count > 1 ? space(of: controller) : nil)
    }

    /// The switcher's "+": a Space with a profile of its own (no cookies,
    /// History or Archive yet), named and colored as asked.
    @discardableResult
    func createSpace(name: String, icon: BrowserSpaceIcon, color: BrowserProfileColor) -> BrowserSpace? {
        spaces.createSpace(name: name, icon: icon, color: color, profiles: profiles)
    }

    /// Every Space but the Default one (the default data store's) can be
    /// deleted.
    func canDeleteSpace(_ id: UUID) -> Bool {
        guard let space = spaces.space(id: id) else { return false }
        return space.profileID != BrowserProfile.defaultID
    }

    /// Delete Space (after the confirmation): deletes the Space's profile
    /// and with it every piece of its data (`deleteProfile`). Refused (and
    /// `completion` gets nil) for the Default Space.
    func deleteSpace(_ id: UUID, completion: (@MainActor (Error?) -> Void)? = nil) {
        guard canDeleteSpace(id), let space = spaces.space(id: id) else {
            completion?(nil)
            return
        }
        deleteProfile(space.profileID, completion: completion)
    }

    /// The windows deleting profile `id` closes: its private and pop-up
    /// windows, and every normal window holding only its Space's tabs.
    func windowsClosing(onDeleteOf id: UUID) -> [BrowserWindowController] {
        controllers.filter { controller in
            controller.hasSpaces
                ? !controller.tabs.isEmpty && controller.tabs.allSatisfy { $0.dataContext.profileID == id }
                : controller.profileID == id
        }
    }

    /// Every open tab of profile `id`, in any window, private windows over
    /// it included: what deleting its Space closes.
    func openTabCount(ofProfile id: UUID) -> Int {
        controllers.reduce(0) { count, controller in
            count + controller.tabs.count { $0.dataContext.profileID == id }
        }
    }

    /// Deletes a Space's profile with every piece of its data: closes its
    /// tabs in every window (a window on its Space shows another Space
    /// first; `windowsClosing(onDeleteOf:)` close whole) and its private
    /// windows, none onto Recently Closed; drops its Recently Closed tabs
    /// and its Archive; deletes its Space and Favorites; removes it from
    /// `profiles.json`; then, once its web views are released, removes its
    /// data store (`WKWebsiteDataStore.remove(forIdentifier:)`) and deletes
    /// its folder (History, site decisions). `completion` gets the data
    /// store removal's error, if it never succeeded. Default can't be
    /// deleted.
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
        recentlyClosed.removeEntries(ofProfile: id, spaces: Set(spaces.space(ofProfile: id).map { [$0.id] } ?? []))
        archive.removeEntries(ofProfile: id)
        spaces.deleteSpace(ofProfile: id)
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
                    Data("Space data store removal failed: \(error.localizedDescription)\n".utf8)
                )
            }
            try? FileManager.default.removeItem(at: folder)
            completion?(error)
        }
    }

    /// Removes a kept profile's data store (the harness keeps the Spaces
    /// of a `--support-dir` run but no WebKit store): its tabs close, its
    /// context goes, then the store is removed once released.
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
