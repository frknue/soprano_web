import AppKit
import Carbon

/// 'SWeb': the signature of Soprano Web's Carbon hotkey.
private let globalHotKeySignature: OSType = 0x5357_6562
private let globalHotKeyID: UInt32 = 1

/// Settings ▸ Keyboard shortcuts ▸ "New Little Arc from any app": one
/// global shortcut through Carbon's `RegisterEventHotKey` (no Accessibility
/// permission; fires whichever app is in front). Soprano Mix's
/// `CarbonPanelHotkey` over `BrowserShortcut`.
///
/// Named keys register their key code as is. Character keys resolve to a
/// key code on the current layout at registration, so the registration is
/// redone when the selected input source changes.
///
/// The event handler's user data is a retained reference to this object,
/// released never: it lives for the whole process, like the handler.
@MainActor
final class BrowserGlobalHotKey {
    private var shortcut: BrowserShortcut?
    private var action: (@MainActor () -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerInstalled = false
    private var inputSourceObserver: NSObjectProtocol?
    /// Settings is recording a new shortcut: nothing is registered, so
    /// the current combination reaches the recorder.
    private var isSuspended = false

    init() {}

    /// Registers `shortcut` (nil: none) for `action`, replacing the last
    /// one. False when the system refused it (another app holds it), no
    /// key on the current or the ASCII-capable layout types its character,
    /// or registration is suspended (`suspend`).
    @discardableResult
    func register(_ shortcut: BrowserShortcut?, action: @escaping @MainActor () -> Void) -> Bool {
        unregisterCurrent()
        self.shortcut = shortcut
        self.action = action
        guard shortcut != nil else { return true }
        installHandlerIfNeeded()
        observeInputSourceIfNeeded()
        return !isSuspended && registerCurrent()
    }

    /// Whether a shortcut is registered now.
    var isRegistered: Bool { hotKeyRef != nil }

    /// While Settings records a shortcut: the registered one lets go.
    func suspend() {
        isSuspended = true
        unregisterCurrent()
    }

    /// Recording ended: the shortcut registers again.
    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        _ = registerCurrent()
    }

    // MARK: - Pure helpers

    /// Carbon modifier flags (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`).
    static func carbonModifiers(_ modifiers: BrowserShortcut.Modifiers) -> UInt32 {
        var mask: UInt32 = 0
        if modifiers.contains(.command) { mask |= UInt32(cmdKey) }
        if modifiers.contains(.option) { mask |= UInt32(optionKey) }
        if modifiers.contains(.control) { mask |= UInt32(controlKey) }
        if modifiers.contains(.shift) { mask |= UInt32(shiftKey) }
        return mask
    }

    /// The key code of a named key (`tab`, `f5`, `left`…): its lowest code
    /// (Return, not keypad Enter); nil for a character key.
    static func keyCode(forNamed key: String) -> UInt16? {
        (UInt16(0) ..< 128).first { BrowserShortcut.namedKey(keyCode: $0) == key }
    }

    // MARK: - Registration

    private func registerCurrent() -> Bool {
        unregisterCurrent()
        guard let shortcut else { return true }
        guard let keyCode = Self.keyCode(forNamed: shortcut.key)
            ?? shortcut.key.first.flatMap(Self.keyCode(forCharacter:))
        else { return false }
        let hotKeyID = EventHotKeyID(signature: globalHotKeySignature, id: globalHotKeyID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode), Self.carbonModifiers(shortcut.modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else { return false }
        hotKeyRef = ref
        return true
    }

    private func unregisterCurrent() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    fileprivate func pressed(id: UInt32) {
        guard id == globalHotKeyID, hotKeyRef != nil else { return }
        action?()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passRetained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), globalHotKeyHandler, 1, &eventType, userData, nil)
        if status == noErr {
            handlerInstalled = true
        } else {
            Unmanaged<BrowserGlobalHotKey>.fromOpaque(userData).release()
        }
    }

    private func observeInputSourceIfNeeded() {
        guard inputSourceObserver == nil else { return }
        inputSourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.shortcut != nil, !self.isSuspended else { return }
                _ = self.registerCurrent()
            }
        }
    }

    // MARK: - Keyboard layout

    /// The key code that types `character` (lowercased) with no modifiers:
    /// on the current layout, else on the ASCII-capable one (Russian,
    /// Greek or Hebrew have no key for "n"; menu key equivalents fall back
    /// the same way). Nil when neither has one.
    private static func keyCode(forCharacter character: Character) -> UInt16? {
        let keyboardType = UInt32(LMGetKbdType())
        let layouts = layoutData().map { data in
            { (code: UInt16) -> Character? in
                data.withUnsafeBytes { buffer -> Character? in
                    guard let pointer = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                        return nil
                    }
                    return translate(code, layout: pointer, keyboardType: keyboardType)
                }
            }
        }
        return keyCode(forCharacter: character, layouts: layouts)
    }

    /// The lowest code 0…127 whose character on the first layout that has
    /// one is `character` (lowercased), so "1" is the number row's key, not
    /// the keypad's. Each layout maps a key code to what it types.
    nonisolated static func keyCode(forCharacter character: Character, layouts: [(UInt16) -> Character?]) -> UInt16? {
        let wanted = String(character).lowercased()
        for layout in layouts {
            if let code = (UInt16(0) ..< 128).first(where: { layout($0).map { String($0).lowercased() } == wanted }) {
                return code
            }
        }
        return nil
    }

    /// The 'uchr' data of the current keyboard layout, then of the
    /// ASCII-capable layout (input methods without one, some CJK input
    /// sources, type through it).
    private static func layoutData() -> [Data] {
        let sources = [
            TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
        ]
        return sources.compactMap { source in
            guard let source, let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
                return nil
            }
            return Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        }
    }

    /// What `keyCode` types with no modifiers, dead keys shown as their own
    /// character. Control characters and whitespace are nil.
    private static func translate(
        _ keyCode: UInt16,
        layout: UnsafePointer<UCKeyboardLayout>,
        keyboardType: UInt32
    ) -> Character? {
        var deadKeyState: UInt32 = 0
        var length = 0
        var units = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
            layout,
            keyCode,
            UInt16(kUCKeyActionDisplay),
            0,
            keyboardType,
            OptionBits(kUCKeyTranslateNoDeadKeysMask),
            &deadKeyState,
            units.count,
            &length,
            &units
        )
        guard status == noErr, length > 0 else { return nil }
        let text = String(decoding: units.prefix(length), as: UTF16.self)
        guard text.count == 1, let character = text.first,
              !character.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
              !character.isWhitespace else {
            return nil
        }
        return character
    }
}

/// Which chords may become the global New Little Arc shortcut, and what
/// Settings' recorder does with a key press. A global hotkey fires in
/// every app, so it must never take a chord the system, text editing or
/// one of Soprano's own commands uses.
enum BrowserGlobalShortcut {
    /// The default chord, and the one a stored chord that is taken falls
    /// back to (`BrowserSettings` decoding).
    static let fallback = "opt+cmd+n"

    /// Chords other apps and the system rely on that may be missing from
    /// the keymap (a user can remap ⌘C away in Soprano, not in every app).
    static let systemChords: Set<BrowserShortcut> = Set([
        "cmd+a", "cmd+c", "cmd+v", "cmd+x", "cmd+z", "shift+cmd+z", "cmd+q", "cmd+w", "cmd+h", "opt+cmd+h",
        "cmd+m", "cmd+s", "cmd+p", "cmd+f", "cmd+n", "cmd+t", "cmd+o", "cmd+,", "cmd+tab", "shift+cmd+tab",
        "cmd+space", "ctrl+space", "opt+cmd+space", "ctrl+cmd+space", "opt+cmd+escape", "ctrl+cmd+q",
        "ctrl+cmd+f", "opt+cmd+d", "shift+cmd+3", "shift+cmd+4", "shift+cmd+5",
    ].compactMap(BrowserShortcut.init))

    /// `shortcut` is assignable and taken by nothing: no reserved chord,
    /// no system chord, no command of `keymap` but New Little Arc.
    static func isAcceptable(_ shortcut: BrowserShortcut, keymap: BrowserKeymap) -> Bool {
        guard shortcut.isAssignable,
              BrowserShortcut.reservedOwner(of: shortcut) == nil,
              !systemChords.contains(shortcut)
        else { return false }
        let command = keymap.command(for: shortcut)
        return command == nil || command == .newLittleArc
    }

    /// Who holds `shortcut` against command `id` in Settings ▸ Keyboard
    /// shortcuts: the global New Little Arc hotkey while it is on (it
    /// fires before any menu, so no other command may take its chord);
    /// nil when nothing does.
    static func owner(of shortcut: BrowserShortcut, for id: BrowserCommandID, settings: BrowserSettings) -> String? {
        guard settings.globalLittleArcEnabled, id != .newLittleArc,
              BrowserShortcut(settings.globalLittleArcShortcut) == shortcut
        else { return nil }
        return "Little Arc anywhere"
    }

    enum RecorderAnswer: Equatable {
        /// Not for the recorder (another window): the key goes on.
        case pass
        /// Esc: recording ends, nothing changes.
        case cancel
        /// Not acceptable: a beep, the key is swallowed.
        case refuse
        case accept(BrowserShortcut)
    }

    /// What Settings' recorder does with a key-down: only its own window's
    /// keys are its business.
    static func recorderAnswer(
        keyCode: UInt16,
        shortcut: BrowserShortcut?,
        inRecorderWindow: Bool,
        keymap: BrowserKeymap
    ) -> RecorderAnswer {
        guard inRecorderWindow else { return .pass }
        if keyCode == 53 { return .cancel }
        guard let shortcut, isAcceptable(shortcut, keymap: keymap) else { return .refuse }
        return .accept(shortcut)
    }
}

/// The Carbon event handler. Carbon dispatches application-target events on
/// the main thread; only the hotkey id and the object's address cross into
/// the main actor.
private func globalHotKeyHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == globalHotKeySignature else { return OSStatus(eventNotHandledErr) }
    let address = Int(bitPattern: userData)
    let id = hotKeyID.id
    MainActor.assumeIsolated {
        guard let pointer = UnsafeRawPointer(bitPattern: address) else { return }
        Unmanaged<BrowserGlobalHotKey>.fromOpaque(pointer).takeUnretainedValue().pressed(id: id)
    }
    return noErr
}
