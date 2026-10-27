import AppKit
import WebKit

/// One permission request waiting for the user: what the extension asks
/// for, in words, and who to answer.
struct BrowserExtensionPermissionPrompt {
    var extensionName: String
    var icon: NSImage?
    var lines: [String]
    /// The question above the list; nil: “<name>” wants to:
    var header: String?
    var allowTitle = "Allow"
    var denyTitle = "Don’t Allow"
    /// The window of the tab that asked; nil: the active window.
    var windowID: UUID?
    var resolve: @MainActor (Bool) -> Void

    /// The lines for `permissions` and the sites of `patterns` (all
    /// websites, or each host), sorted, without repeats.
    @MainActor
    static func describe(permissions: [WKWebExtension.Permission], patterns: [WKWebExtension.MatchPattern]) -> [String] {
        let sites = patterns.map { pattern in
            pattern.matchesAllHosts || pattern.matchesAllURLs
                ? "Read and change your data on all websites"
                : "Read and change your data on \(pattern.host ?? pattern.string)"
        }
        return Array(Set(permissions.map { describe($0) } + sites)).sorted()
    }

    /// Chrome's wording for a permission.
    static func describe(_ permission: WKWebExtension.Permission) -> String {
        switch permission {
        case .tabs, .webNavigation: "Read your browsing history"
        case .cookies: "Read and change cookies"
        case .clipboardWrite: "Modify data you copy and paste"
        case .nativeMessaging: "Communicate with cooperating native applications"
        case .declarativeNetRequest, .declarativeNetRequestWithHostAccess: "Block content on any page"
        case .declarativeNetRequestFeedback: "Read blocked content on any page"
        case .webRequest: "Observe your network requests"
        case .scripting: "Change the pages you visit"
        case .contextMenus, .menus: "Add items to context menus"
        case .storage, .unlimitedStorage: "Store data"
        case .alarms: "Run scheduled tasks"
        case .activeTab: "Access the page you click it on"
        default: "Use “\(permission.rawValue)”"
        }
    }
}

/// The Folio sheet that asks for an extension's runtime permission
/// request (`permissions.request`, a URL or site), what an update newly
/// asks for, or (Settings ▸ Extensions) an install: "Allow" or "Don't
/// Allow". A request's answer is remembered (granted or denied explicitly,
/// saved with the extension), so the same request never asks twice.
@MainActor
final class BrowserExtensionPermissionSheet: NSWindowController {
    private let rootView = NSView()
    private let iconView = NSImageView()
    private let header: NSTextField
    private let list: NSTextField
    private let allowButton: ChromeButton
    private let denyButton: ChromeButton
    private let onAnswer: (Bool) -> Void

    init(prompt: BrowserExtensionPermissionPrompt, theme: AppTheme, onAnswer: @escaping (Bool) -> Void) {
        self.onAnswer = onAnswer
        header = NSTextField(wrappingLabelWithString: prompt.header ?? "“\(prompt.extensionName)” wants to:")
        list = NSTextField(wrappingLabelWithString: prompt.lines.map { "•  \($0)" }.joined(separator: "\n"))
        allowButton = ChromeButton(title: prompt.allowTitle, theme: theme, kind: .ink, keycap: "↵")
        denyButton = ChromeButton(title: prompt.denyTitle, theme: theme, kind: .standard, keycap: "esc")
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.title = "Extension Permission"
        window.isReleasedWhenClosed = false
        window.contentView = rootView
        window.backgroundColor = theme.colors.bgBase
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = theme.colors.bgBase.cgColor

        iconView.image = prompt.icon ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        header.font = ChromeFont.headline
        header.textColor = theme.colors.textPrimary
        header.preferredMaxLayoutWidth = 320
        list.font = ChromeFont.label
        list.textColor = theme.colors.textPrimary
        list.preferredMaxLayoutWidth = 320
        allowButton.target = self
        allowButton.action = #selector(allowPressed)
        allowButton.keyEquivalent = "\r"
        denyButton.target = self
        denyButton.action = #selector(denyPressed)
        denyButton.keyEquivalent = "\u{1b}"
        for view in [iconView, header, list, allowButton, denyButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            rootView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 22),
            iconView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 24),
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),
            header.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 22),
            header.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 14),
            header.trailingAnchor.constraint(lessThanOrEqualTo: rootView.trailingAnchor, constant: -24),
            list.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            list.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            list.trailingAnchor.constraint(lessThanOrEqualTo: rootView.trailingAnchor, constant: -24),
            allowButton.topAnchor.constraint(greaterThanOrEqualTo: list.bottomAnchor, constant: 22),
            allowButton.topAnchor.constraint(greaterThanOrEqualTo: iconView.bottomAnchor, constant: 22),
            allowButton.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -24),
            allowButton.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -18),
            allowButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 92),
            denyButton.centerYAnchor.constraint(equalTo: allowButton.centerYAnchor),
            denyButton.trailingAnchor.constraint(equalTo: allowButton.leadingAnchor, constant: -10),
            denyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 92),
        ])
        rootView.layoutSubtreeIfNeeded()
        window.setContentSize(rootView.fittingSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func allowPressed() {
        finish(true)
    }

    @objc private func denyPressed() {
        finish(false)
    }

    private func finish(_ allowed: Bool) {
        guard let window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.close()
        }
        onAnswer(allowed)
    }
}

extension BrowserExtensions {
    /// Queues a permission question; the sheet shows on the asking tab's
    /// window (else the active one), one question at a time. Without a
    /// window the request is denied.
    func prompt(
        _ context: WKWebExtensionContext,
        tab: (any WKWebExtensionTab)?,
        lines: [String],
        header: String? = nil,
        resolve: @escaping @MainActor (Bool) -> Void
    ) {
        let windowID = (tab as? BrowserExtensionTab).flatMap { manager?.tab(id: $0.tabID)?.window.id }
        pendingPrompts.append(BrowserExtensionPermissionPrompt(
            extensionName: context.webExtension.displayName ?? "An extension",
            icon: context.webExtension.icon(for: CGSize(width: 32, height: 32)),
            lines: lines,
            header: header,
            windowID: windowID,
            resolve: resolve
        ))
        showNextPrompt()
    }

    private func showNextPrompt() {
        guard promptSheet == nil, !pendingPrompts.isEmpty else { return }
        let prompt = pendingPrompts.removeFirst()
        let host = prompt.windowID.flatMap { id in manager?.controllers.first { $0.id == id } }
            ?? manager?.activeController
        guard let host, let parent = host.window else {
            prompt.resolve(false)
            showNextPrompt()
            return
        }
        let sheet = BrowserExtensionPermissionSheet(prompt: prompt, theme: host.theme) { [weak self] allowed in
            self?.promptSheet = nil
            prompt.resolve(allowed)
            self?.showNextPrompt()
        }
        promptSheet = sheet
        guard let window = sheet.window else { return }
        parent.beginSheet(window)
    }
}
