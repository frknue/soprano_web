import AppKit

/// The profile picker of Settings ▸ Websites and Website Data: a button
/// naming the profile shown, with a menu of every profile. Hidden while
/// only one profile exists; when the shown profile is deleted it switches
/// to Default (and lets go of the deleted profile's stores).
@MainActor
final class BrowserProfilePicker: NSObject {
    let button: ChromeButton
    private let profiles: BrowserProfileStore
    private(set) var selectedID: UUID
    /// The shown profile changed (picked, or its profile was deleted).
    var onChange: ((UUID) -> Void)?
    private var observation: BrowserObservation?

    init(profiles: BrowserProfileStore, selected: UUID, theme: AppTheme) {
        self.profiles = profiles
        selectedID = profiles.resolvedID(selected)
        button = ChromeButton(title: "", theme: theme, kind: .standard)
        super.init()
        button.target = self
        button.action = #selector(pressed)
        observation = profiles.changes.observe { [weak self] in self?.profilesChanged() }
        refresh()
    }

    var selectedProfile: BrowserProfile {
        profiles.profile(id: selectedID) ?? .defaultProfile
    }

    func apply(theme: AppTheme) {
        button.apply(theme: theme)
    }

    private func profilesChanged() {
        let resolved = profiles.resolvedID(selectedID)
        let changed = resolved != selectedID
        selectedID = resolved
        refresh()
        if changed {
            onChange?(resolved)
        }
    }

    private func refresh() {
        button.title = "Profile: \(selectedProfile.name)"
        button.isHidden = !profiles.hasSeveral
    }

    @objc private func pressed() {
        let menu = NSMenu()
        for profile in profiles.profiles {
            let item = NSMenuItem(title: profile.name, action: #selector(chose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile.id
            item.state = profile.id == selectedID ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func chose(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, id != selectedID else { return }
        selectedID = id
        refresh()
        onChange?(id)
    }

    /// Picks `id` as the menu would (the harness).
    func select(_ id: UUID) {
        let resolved = profiles.resolvedID(id)
        guard resolved != selectedID else { return }
        selectedID = resolved
        refresh()
        onChange?(resolved)
    }
}
