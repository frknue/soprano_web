import AppKit
import WebKit

/// What the selected tab captures, and the controls the indicator menu
/// offers for it.
struct BrowserCaptureStatus: Equatable, Sendable {
    enum Device: Equatable, Sendable {
        case off
        case active
        case muted

        init(_ state: WKMediaCaptureState) {
            switch state {
            case .active: self = .active
            case .muted: self = .muted
            case .none: self = .off
            @unknown default: self = .off
            }
        }
    }

    enum Action: Equatable, Sendable {
        case stopCamera
        case muteMicrophone
        case unmuteMicrophone
        case stopAll
    }

    struct Item: Equatable, Sendable {
        let title: String
        let action: Action
    }

    var camera: Device = .off
    var microphone: Device = .off

    var isVisible: Bool {
        camera != .off || microphone != .off
    }

    var isLive: Bool {
        camera == .active || microphone == .active
    }

    var symbolName: String {
        switch (camera, microphone) {
        case (.active, _): "video.fill"
        case (.muted, _): "video.slash.fill"
        case (.off, .muted): "mic.slash.fill"
        default: "mic.fill"
        }
    }

    var description: String {
        switch (camera != .off, microphone != .off) {
        case (true, true): microphone == .muted
            ? "This tab is using the camera; the microphone is muted"
            : "This tab is using the camera and microphone"
        case (true, false): "This tab is using the camera"
        case (false, true): microphone == .muted
            ? "This tab's microphone is muted"
            : "This tab is using the microphone"
        case (false, false): ""
        }
    }

    /// Menu entries; `nil` marks a separator.
    var menuItems: [Item?] {
        var items: [Item?] = []
        if camera != .off {
            items.append(Item(title: "Stop Camera", action: .stopCamera))
        }
        if microphone == .active {
            items.append(Item(title: "Mute Microphone", action: .muteMicrophone))
        } else if microphone == .muted {
            items.append(Item(title: "Unmute Microphone", action: .unmuteMicrophone))
        }
        if microphone != .off {
            items.append(nil)
            items.append(Item(
                title: camera != .off ? "Stop Camera and Microphone" : "Stop Microphone",
                action: .stopAll
            ))
        }
        return items
    }
}

/// The camera/microphone in-use mark next to the address field. Clicking it
/// opens the stop/mute menu for the selected tab.
@MainActor
final class BrowserCaptureIndicator: NSButton {
    var onAction: ((BrowserCaptureStatus.Action) -> Void)?

    private(set) var status = BrowserCaptureStatus()
    private var theme: AppTheme
    private var widthConstraint: NSLayoutConstraint!

    init(theme: AppTheme) {
        self.theme = theme
        super.init(frame: .zero)
        title = ""
        isBordered = false
        imagePosition = .imageOnly
        wantsLayer = true
        layer?.cornerRadius = Chrome.Radius.control
        target = self
        action = #selector(pressed)
        translatesAutoresizingMaskIntoConstraints = false
        widthConstraint = widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            widthConstraint,
            heightAnchor.constraint(equalToConstant: Chrome.iconButtonSize),
        ])
        update(status)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        update(status)
    }

    func update(_ status: BrowserCaptureStatus) {
        self.status = status
        isHidden = !status.isVisible
        widthConstraint.constant = status.isVisible ? Chrome.iconButtonSize : 0
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        image = NSImage(
            systemSymbolName: status.symbolName,
            accessibilityDescription: status.description
        )?.withSymbolConfiguration(configuration)
        setAccessibilityLabel(status.description)
        toolTip = status.description
        contentTintColor = status.isLive ? theme.colors.danger : theme.colors.textMuted
        layer?.backgroundColor = theme.colors.raised.cgColor
        layer?.borderWidth = Chrome.hairline
        layer?.borderColor = theme.colors.borderSubtle.cgColor
    }

    @objc private func pressed() {
        let menu = NSMenu()
        for entry in status.menuItems {
            guard let entry else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: entry.title, action: #selector(itemSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ActionBox(entry.action)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }

    @objc private func itemSelected(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ActionBox else { return }
        onAction?(box.action)
    }

    private final class ActionBox: NSObject {
        let action: BrowserCaptureStatus.Action

        init(_ action: BrowserCaptureStatus.Action) {
            self.action = action
        }
    }
}
