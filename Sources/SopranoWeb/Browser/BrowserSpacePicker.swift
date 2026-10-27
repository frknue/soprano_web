import AppKit

/// The Space picker of Settings ▸ Websites and Website Data: a button
/// naming the Space shown, with a menu of every Space (icon and name).
/// What the sheets read is the Space's data, so the selection is the
/// Space's profile id. Hidden while only one Space exists; when the shown
/// Space is deleted it switches to the Default Space (and lets go of the
/// deleted Space's stores).
@MainActor
final class BrowserSpacePicker: NSObject {
    let button: ChromeButton
    private let spaces: BrowserSpaceStore
    /// The profile of the Space shown.
    private(set) var selectedID: UUID
    /// The shown Space changed (picked, or deleted): its profile id.
    var onChange: ((UUID) -> Void)?
    private var observation: BrowserObservation?

    /// `selected`: the profile of the Space to show first.
    init(spaces: BrowserSpaceStore, selected: UUID, theme: AppTheme) {
        self.spaces = spaces
        selectedID = spaces.space(ofProfile: selected) == nil ? BrowserProfile.defaultID : selected
        button = ChromeButton(title: "", theme: theme, kind: .standard)
        super.init()
        button.target = self
        button.action = #selector(pressed)
        observation = spaces.changes.observe { [weak self] in self?.spacesChanged() }
        refresh()
    }

    /// The Space shown.
    var selectedSpace: BrowserSpace? {
        spaces.space(ofProfile: selectedID)
    }

    /// The shown Space's name, as the button and the harness show it.
    var selectedName: String {
        selectedSpace.map(Self.title(of:)) ?? BrowserSpace.defaultName
    }

    func apply(theme: AppTheme) {
        button.apply(theme: theme)
    }

    private func spacesChanged() {
        let gone = spaces.space(ofProfile: selectedID) == nil
        if gone {
            selectedID = BrowserProfile.defaultID
        }
        refresh()
        if gone {
            onChange?(selectedID)
        }
    }

    private func refresh() {
        button.title = "Space: \(selectedName)"
        button.isHidden = spaces.spaces.count < 2
    }

    /// A Space's emoji and name (an SF Symbol shows as the menu item's
    /// image).
    private static func title(of space: BrowserSpace) -> String {
        if case let .emoji(emoji) = space.icon {
            return "\(emoji) \(space.displayName)"
        }
        return space.displayName
    }

    @objc private func pressed() {
        let menu = NSMenu()
        for space in spaces.spaces {
            let item = NSMenuItem(title: Self.title(of: space), action: #selector(chose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = space.profileID
            item.state = space.profileID == selectedID ? .on : .off
            if case let .symbol(name) = space.icon {
                item.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func chose(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        select(id)
    }

    /// Shows the Space whose profile is `id`, as the menu would (the
    /// harness).
    func select(_ id: UUID) {
        guard id != selectedID, spaces.space(ofProfile: id) != nil else { return }
        selectedID = id
        refresh()
        onChange?(id)
    }
}
