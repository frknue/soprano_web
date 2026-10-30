# P1 / P2 research — WKWebExtension runtime, CRX3, 1Password stand-ins

Read-only research, 2026-10-27, branch `feat/stage-4`. SDK: `/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk` (headers + `WebKit.swiftmodule/arm64e-apple-macos.swiftinterface`). Everything is `API_AVAILABLE(macos(15.4))`, so the macOS 26 floor needs no `#available` checks. Every class and protocol is `WK_SWIFT_UI_ACTOR` (main actor).

## 0. Corrections to `docs/STAGE-4-PLAN.md`

1. **P2's native-messaging selector name is wrong.** The plan says `webExtensionController(_:sendMessage:to:for:replyHandler:)`. The SDK name is `webExtensionController(_:sendMessage:toApplicationWithIdentifier:for:replyHandler:)`. Its async form is `webExtensionController(_:sendMessage:toApplicationWithIdentifier:for:) async throws -> Any?`. ObjC selector: `webExtensionController:sendMessage:toApplicationWithIdentifier:forExtensionContext:replyHandler:`.
2. **P1's CRX3 signed message is missing a length field.** The plan says `"CRX3 SignedData\0"` + header + ZIP. The real message is `"CRX3 SignedData\0"` (16 bytes, NUL included) + **`UInt32` little-endian length of `signed_header_data`** + `signed_header_data` + ZIP. The signed part is `signed_header_data` (protobuf field 10000), not the whole header. See §4.
3. **Chrome checks every proof.** Chrome requires *all* proofs to verify. For store installs (`CRX3_WITH_PUBLISHER_PROOF`) it also requires a proof by the **Chrome Web Store publisher key** (ECDSA P-256). Checking "ECDSA/RSA" alone is not enough. DDG implements the full rule; Search only checks the developer RSA proof.

## 1. SDK API surface (Swift names as imported)

Notation: `ObjC selector` → Swift. "async" means the Swift-concurrency form the importer synthesizes from a trailing completion handler. Search, an MIT WebKit browser used as prior art (§3a), implements the async forms, and both forms satisfy the ObjC protocol requirement.

### WKWebExtension (`WKWebExtension.h`)
- `init(appExtensionBundle: Bundle) async throws` and `init(resourceBaseURL: URL) async throws`. These are Swift overlays (NS_REFINED_FOR_SWIFT, swiftinterface:84-87). `resourceBaseURL` takes a **directory or a ZIP** containing `manifest.json`.
- Properties: `errors: [Error]`, `manifest: [String: Any]`, `manifestVersion: Double`, `supportsManifestVersion(_:)`, `defaultLocale`, `displayName`, `displayShortName`, `displayVersion`, `displayDescription`, `displayActionLabel`, `version` (all `String?`).
- Icons: `icon(for: CGSize) -> NSImage?` (ObjC `iconForSize:`), `actionIcon(for: CGSize) -> NSImage?`.
- Permissions: `requestedPermissions` / `optionalPermissions: Set<WKWebExtension.Permission>`, `requestedPermissionMatchPatterns` / `optionalPermissionMatchPatterns` / `allRequestedMatchPatterns: Set<WKWebExtension.MatchPattern>`.
- Flags: `hasBackgroundContent`, `hasPersistentBackgroundContent`, `hasInjectedContent`, `hasOptionsPage`, `hasOverrideNewTabPage`, `hasCommands`, `hasContentModificationRules`.
- Errors: `WKWebExtension.Error` cases `.unknown=1, .resourceNotFound, .invalidResourceCodeSignature, .invalidManifest, .unsupportedManifestVersion, .invalidManifestEntry, .invalidDeclarativeNetRequestEntry, .invalidBackgroundPersistence, .invalidArchive`. Domain: `WKWebExtension.errorDomain`.

### WKWebExtensionController (`WKWebExtensionController.h`)
- Init: `init()` (default configuration) and `init(configuration: WKWebExtensionController.Configuration)`. The configuration is copied at init.
- `weak var delegate: (any WKWebExtensionControllerDelegate)?`, `configuration` (a copy).
- `load(_ context: WKWebExtensionContext) throws` and `unload(_:) throws` (ObjC `loadExtensionContext:error:`).
- `extensionContext(for: WKWebExtension) -> WKWebExtensionContext?` and `extensionContext(for: URL) -> WKWebExtensionContext?`.
- `extensions: Set<WKWebExtension>`, `extensionContexts: Set<WKWebExtensionContext>`.
- Data: `class var allExtensionDataTypes: Set<WKWebExtension.DataType>`.
  - `fetchDataRecords(ofTypes:completionHandler:)`, async `dataRecords(ofTypes:) -> [WKWebExtension.DataRecord]`.
  - `fetchDataRecord(ofTypes:for:completionHandler:)`, async `dataRecord(ofTypes:for:) -> WKWebExtension.DataRecord?`.
  - `removeData(ofTypes:from:completionHandler:)`.
- Events for all loaded extensions. `WKWebExtensionContext` has the same set, aimed at one extension.
  - `didOpenWindow(_:)`, `didCloseWindow(_:)`, `didFocusWindow(_: (any WKWebExtensionWindow)?)`.
  - `didOpenTab(_:)`.
  - `didCloseTab(_ closedTab: any WKWebExtensionTab, windowIsClosing: Bool = false)` (overlay).
  - `didActivateTab(_ activatedTab: any WKWebExtensionTab, previousActiveTab: (any WKWebExtensionTab)? = nil)` (overlay).
  - `didSelectTabs(_: [any WKWebExtensionTab])`, `didDeselectTabs(_:)`.
  - `didMoveTab(_ movedTab: any WKWebExtensionTab, from index: Int, in oldWindow: (any WKWebExtensionWindow)? = nil)` (overlay, swiftinterface:91-99).
  - `didReplaceTab(_:with:)`, `didChangeTabProperties(_: WKWebExtension.TabChangedProperties, for: any WKWebExtensionTab)`.
- Hook-up: `WKWebViewConfiguration.webExtensionController: WKWebExtensionController?` (`WKWebViewConfiguration.h:122`). It must be set **before** the `WKWebView` is created.

### WKWebExtensionController.Configuration (`WKWebExtensionControllerConfiguration.h`, NSSecureCoding/NSCopying)
- `.default()`: persistent, in a common location. `.nonPersistent()`. `init(identifier: UUID)`: persistent, in its own location (ObjC `configurationWithIdentifier:`).
- `isPersistent`, `identifier: UUID?`.
- `webViewConfiguration: WKWebViewConfiguration!` (null_resettable): the base for every extension page (background, popup, options).
- `defaultWebsiteDataStore: WKWebsiteDataStore!` (null_resettable, defaults to `.default()`). Extensions can still reach other stores, including non-persistent ones, of open tabs.

### WKWebExtensionContext (`WKWebExtensionContext.h`)
- Create: `init(for: WKWebExtension)` (also `contextForExtension:`). Read: `webExtension`, `weak webExtensionController`, `isLoaded`, `errors: [Error]`.
- Settable **only before load**:
  - `baseURL: URL`: default `webkit-extension://<uuid>/`; only scheme and host are used. A custom scheme must be registered with `WKWebExtension.MatchPattern.registerCustomURLScheme(_:)`.
  - `uniqueIdentifier: String`: `runtime.id`.
  - `unsupportedAPIs: Set<String>!`, e.g. `"browser.windows.create"`; these become `undefined`.
- Debug: `isInspectable: Bool`, `inspectionName: String?`.
- `webViewConfiguration: WKWebViewConfiguration?`: a copy for web views that show this extension's URLs. The app **must** use it, and must swap a tab's web view when navigating to or from an extension URL; navigations across that boundary fail or are cancelled. `nil` when not loaded in a controller.
- `optionsPageURL`, `overrideNewTabPageURL: URL?`.
- Saving and restoring permissions (the app persists these):
  - `grantedPermissions` / `deniedPermissions: [WKWebExtension.Permission: Date]`.
  - `grantedPermissionMatchPatterns` / `deniedPermissionMatchPatterns: [WKWebExtension.MatchPattern: Date]`.
  - `hasRequestedOptionalAccessToAllHosts: Bool`, `hasAccessToPrivateData: Bool`.
- Current state: `currentPermissions`, `currentPermissionMatchPatterns`, `hasAccessToAllURLs`, `hasAccessToAllHosts`, `hasInjectedContent`, `hasInjectedContent(for: URL)`, `hasContentModificationRules`.
- Checks:
  - `hasPermission(_:)`, `hasPermission(_:in: (any WKWebExtensionTab)?)`.
  - `hasAccess(to: URL)`, `hasAccess(to:in:)`.
  - `permissionStatus(for: Permission | URL | MatchPattern [, in: tab])` returns `WKWebExtensionContext.PermissionStatus`: `.deniedExplicitly=-3, .deniedImplicitly, .requestedImplicitly, .unknown=0, .requestedExplicitly, .grantedImplicitly, .grantedExplicitly=3`.
- Setting: `setPermissionStatus(_:for: Permission | URL | MatchPattern [, expirationDate: Date?])`. Only `.deniedExplicitly`, `.unknown` and `.grantedExplicitly` are allowed.
- Notifications:
  - `WKWebExtensionContext.errorsDidUpdateNotification`.
  - `.permissionsWereGrantedNotification` / `…Denied…` / `grantedPermissionsWereRemoved…` / `deniedPermissionsWereRemoved…`.
  - The same four for `…MatchPatterns…`.
  - userInfo keys: `WKWebExtensionContext.NotificationUserInfoKey.permissions` and `.matchPatterns`.
- `loadBackgroundContent(completionHandler: (Error?) -> Void)`. Background otherwise loads on demand.
- Action: `action(for: (any WKWebExtensionTab)?) -> WKWebExtension.Action?` (`nil` gives the default action) and `performAction(for:)`. `performAction` marks a user gesture and either fires `action.onClicked` or asks the delegate to present the popup.
- Commands: `commands: [WKWebExtension.Command]`, `performCommand(_:)`, `performCommand(for: NSEvent) -> Bool`, `command(for: NSEvent) -> WKWebExtension.Command?`.
- Menus: `menuItems(for: any WKWebExtensionTab) -> [NSMenuItem]`. Fetch it immediately before showing a menu.
- Gestures: `userGesturePerformed(in:)`, `hasActiveUserGesture(in:)`, `clearUserGesture(in:)`.
- State it tracks: `openWindows: [any WKWebExtensionWindow]`, `weak focusedWindow`, `openTabs: Set<…>`, plus the same `did…` event methods as the controller.
- Errors: `WKWebExtensionContext.Error` cases `.unknown=1, .alreadyLoaded, .notLoaded, .baseURLAlreadyInUse, .noBackgroundContent, .backgroundContentFailedToLoad`.

### WKWebExtensionControllerDelegate (all `@optional`; Swift names; **add every ObjC selector to `BrowserDelegateSelectorTests`**)

| ObjC selector | Swift (completion form / async form) |
|---|---|
| `webExtensionController:openWindowsForExtensionContext:` | `webExtensionController(_:openWindowsFor:) -> [any WKWebExtensionWindow]`. The first entry must be the focused window. |
| `webExtensionController:focusedWindowForExtensionContext:` | `webExtensionController(_:focusedWindowFor:) -> (any WKWebExtensionWindow)?` |
| `webExtensionController:openNewWindowUsingConfiguration:forExtensionContext:completionHandler:` | `(_:openNewWindowUsing:for:completionHandler:)` / `(_:openNewWindowUsing:for:) async throws -> (any WKWebExtensionWindow)?` |
| `webExtensionController:openNewTabUsingConfiguration:forExtensionContext:completionHandler:` | `(_:openNewTabUsing:for:completionHandler:)` / `(_:openNewTabUsing:for:) async throws -> (any WKWebExtensionTab)?` |
| `webExtensionController:openOptionsPageForExtensionContext:completionHandler:` | `(_:openOptionsPageFor:completionHandler:)` / `async throws`. If not implemented, the options page opens through openNewTab. |
| `webExtensionController:promptForPermissions:inTab:forExtensionContext:completionHandler:` | `(_:promptForPermissions:in:for:completionHandler:)` / `async -> (Set<WKWebExtension.Permission>, Date?)` |
| `webExtensionController:promptForPermissionToAccessURLs:inTab:forExtensionContext:completionHandler:` | `(_:promptForPermissionToAccess:in:for:completionHandler:)` / `async -> (Set<URL>, Date?)` |
| `webExtensionController:promptForPermissionMatchPatterns:inTab:forExtensionContext:completionHandler:` | `(_:promptForPermissionMatchPatterns:in:for:completionHandler:)` / `async -> (Set<WKWebExtension.MatchPattern>, Date?)` |
| `webExtensionController:didUpdateAction:forExtensionContext:` | `webExtensionController(_:didUpdate:forExtensionContext:)`. Note the label is `forExtensionContext:`, not `for:`. |
| `webExtensionController:presentPopupForAction:forExtensionContext:completionHandler:` | `(_:presentActionPopup:for:completionHandler:)` / `(_:presentActionPopup:for:) async throws` |
| `webExtensionController:sendMessage:toApplicationWithIdentifier:forExtensionContext:replyHandler:` | `(_:sendMessage:toApplicationWithIdentifier:for:replyHandler:)` / `async throws -> Any?` (WK_SWIFT_ASYNC(5)). The reply must be JSON-serializable. |
| `webExtensionController:connectUsingMessagePort:forExtensionContext:completionHandler:` | `(_:connectUsing:for:completionHandler:)` / `async throws`. The app must keep a strong reference to the port; releasing it disconnects. |

Permission prompts: if the delegate method is missing or never calls back, WebKit treats the request as denied. An expiration date of `nil` means no expiry.

### WKWebExtensionTab protocol (`WKWebExtensionTab.h`, all `@optional`, `NSObjectProtocol`)
Every method takes `for context: WKWebExtensionContext`. Completion handlers are `(Error?) -> Void` unless noted.
- Structure: `window(for:) -> (any WKWebExtensionWindow)?`, `indexInWindow(for:) -> Int` (`NSNotFound` if none), `parentTab(for:)`, `setParentTab(_:for:completionHandler:)`.
- **`webView(for:) -> WKWebView?`**: the web view's configuration must carry the *same* controller, or WebKit treats it as `nil` and injection is lost.
- Pinned: `isPinned(for:)`, `setPinned(_:for:completionHandler:)`.
- Reader: `isReaderModeAvailable(for:)`, `isReaderModeActive(for:)`, `setReaderModeActive(_:for:completionHandler:)`.
- Audio: `isPlayingAudio(for:)`, `isMuted(for:)`, `setMuted(_:for:completionHandler:)`.
- Size and zoom: `size(for:) -> CGSize`, `zoomFactor(for:) -> Double`, `setZoomFactor(_:for:completionHandler:)`.
- Page state:
  - `title(for:)`, `url(for:)`, `pendingURL(for:)`, `isLoadingComplete(for:)`.
  - `detectWebpageLocale(for:completionHandler: (Locale?, Error?))`.
  - `takeSnapshot(using: WKSnapshotConfiguration, for:completionHandler: (NSImage?, Error?))`; async name `snapshot(using:for:)`.
- Navigation: `loadURL(_:for:completionHandler:)`, `reload(fromOrigin:for:completionHandler:)`, `goBack(for:completionHandler:)`, `goForward(for:completionHandler:)`.
- Selection and lifetime: `activate(for:completionHandler:)`, `isSelected(for:)`, `setSelected(_:for:completionHandler:)`, `duplicate(using: WKWebExtension.TabConfiguration, for:completionHandler: ((any WKWebExtensionTab)?, Error?))`, `close(for:completionHandler:)`.
- Access: `shouldGrantPermissionsOnUserGesture(for:) -> Bool` (activeTab), `shouldBypassPermissions(for:) -> Bool`.
- Defaults when not implemented: title, URL, loading, size and zoom are read from `webView(for:)`; load, reload, back and forward act on that web view; everything else does nothing.
- `WKWebExtension.TabChangedProperties` (OptionSet): `.loading, .muted, .pinned, .playingAudio, .readerMode, .size, .title, .URL, .zoomFactor`. Swift spellings follow the importer [INFERENCE: `.URL` may import as `.URL`].

### WKWebExtensionWindow protocol (`WKWebExtensionWindow.h`, all `@optional`)
- Tabs: `tabs(for:) -> [any WKWebExtensionTab]`, `activeTab(for:) -> (any WKWebExtensionTab)?`.
- Type: `windowType(for:) -> WKWebExtension.WindowType` (`.normal`, `.popup`).
- State: `windowState(for:) -> WKWebExtension.WindowState` (`.normal, .minimized, .maximized, .fullscreen`) and `setWindowState(_:for:completionHandler:)`. The setter is only called if the getter exists.
- **`isPrivate(for:) -> Bool`**: cached for the window's lifetime.
- Frames: `screenFrame(for:) -> CGRect`, `frame(for:) -> CGRect` (screen coordinates), `setFrame(_:for:completionHandler:)`. On macOS the setter needs both getters.
- `focus(for:completionHandler:)`, `close(for:completionHandler:)`.

### WKWebExtension.TabConfiguration / WindowConfiguration (read-only, app may ignore)
- Tab: `window: (any WKWebExtensionWindow)?`, `index: Int`, `parentTab`, `url: URL?` (`nil` = start page), `shouldBeActive`, `shouldAddToSelection`, `shouldBePinned`, `shouldBeMuted`, `shouldReaderModeBeActive`.
- Window: `windowType`, `windowState`, `frame: CGRect` (NaN components = unspecified), `tabURLs: [URL]`, `tabs: [any WKWebExtensionTab]`, `shouldBeFocused`, `shouldBePrivate`.

### WKWebExtension.Action (`WKWebExtensionAction.h`)
- Read: `weak webExtensionContext`, `weak associatedTab` (`nil` = default action), `icon(for: CGSize) -> NSImage?`, `label: String`, `badgeText: String` (empty = no badge), `isEnabled`.
- `hasUnreadBadgeText: Bool` (settable).
- `inspectionName`.
- `menuItems: [NSMenuItem]`: for the button's own context menu.
- Popup: `presentsPopup: Bool`, `popupPopover: NSPopover?` (macOS, self-sizing), `popupWebView: WKWebView?` (preloads on first access), `closePopup()`.

### WKWebExtension.Command (`WKWebExtensionCommand.h`)
- `weak webExtensionContext`, `id: String` (ObjC `identifier`), `title: String`.
- Settable, and the app persists them: `activationKey: String?`, `modifierFlags: NSEvent.ModifierFlags`.
- `menuItem: NSMenuItem`: selecting it performs the command.

### WKWebExtension.MessagePort (`WKWebExtensionMessagePort.h`)
- `applicationIdentifier: String?`.
- `messageHandler: ((Any?, Error?) -> Void)?`, `disconnectHandler: ((Error?) -> Void)?`, `isDisconnected`.
- `sendMessage(_: Any?, completionHandler: ((Error?) -> Void)?)`, `disconnect()`, `disconnect(throwing: Error?)`.
- Errors: `WKWebExtensionMessagePort.Error` cases `.unknown, .notConnected, .messageInvalid`.

### WKWebExtension.MatchPattern (`WKWebExtensionMatchPattern.h`, NSSecureCoding/NSCopying, Hashable via NSObject)
- `class func registerCustomURLScheme(_:)`.
- Constructors: `allURLsMatchPattern()`, `allHostsAndSchemesMatchPattern()`, `init(string:) throws`, `init(scheme:host:path:) throws`. Also the failable factories `matchPatternWithString:` and `matchPatternWithScheme:host:path:`.
- Read: `string`, `scheme`, `host`, `path`, `matchesAllURLs`, `matchesAllHosts`.
- Matching: `matches(_: URL?)`, `matches(_: URL?, options:)`, `matches(_: MatchPattern?)`, `matches(_: MatchPattern?, options:)`.
- `Options`: `.ignoreSchemes, .ignorePaths, .matchBidirectionally`.
- `Error` cases: `.invalidScheme, .invalidHost, .invalidPath`.

### WKWebExtension.Permission (typed extensible String enum)
`.activeTab, .alarms, .clipboardWrite, .contextMenus, .cookies, .declarativeNetRequest, .declarativeNetRequestFeedback, .declarativeNetRequestWithHostAccess, .menus, .nativeMessaging, .scripting, .storage, .tabs, .unlimitedStorage, .webNavigation, .webRequest`.

There is **no** `notifications`, `offscreen`, `userScripts`, `sessions`, `bookmarks`, `history` or `downloads`. Arbitrary strings can still be constructed with `WKWebExtension.Permission(rawValue:)`.

### WKWebExtension.DataRecord / DataType
- DataRecord: `displayName`, `uniqueIdentifier`, `containedDataTypes`, `errors`, `totalSizeInBytes`, `sizeInBytes(ofTypes:)`.
- DataType: `.local, .session, .synchronized`.
- `DataRecord.Error` cases: `.localStorageFailed, .sessionStorageFailed, .synchronizedStorageFailed`.

## 2. Soprano Web anchors (where P1 plugs in)

**Web view creation and the controller hook**
- `Sources/SopranoWeb/Browser/BrowserWindowManager.swift:629-643` `makeTabConfiguration(for:)`. This is the single place every tab's `WKWebViewConfiguration` is built: data store, autoplay, preferences, `applicationNameForUserAgent = BrowserUserAgent.applicationName`, start-page scheme. **Set `configuration.webExtensionController` here.**
  - Use the controller for every context.
  - A private context still needs the controller so extensions with `hasAccessToPrivateData` can see it. WebKit hides private tabs from the others through `isPrivate(for:)` on the window.
- `BrowserWindowController+Tabs.swift:63-97` `makeWebView(context:configuration:)`.
  - Takes `configuration ?? manager.makeTabConfiguration(for:)` (64).
  - **Replaces `configuration.userContentController` with a fresh one per web view** (75-85). That gives private web views their own UCC, as WebKit requires.
  - Creates `BrowserWebView(frame:configuration:)` (87).
  - Content blocker at 94.
- `+Tabs.swift:47-57` `makeTab(context:configuration:)`. The `configuration` parameter is the seam for extension pages: pass `extensionContext.webViewConfiguration` for an options page or extension URL opened in a tab.
- `+Tabs.swift:109-128` `replaceWebView(of:)`, used by sleep. It goes through `makeWebView`, so the hook covers it.
- Pop-ups: `+UIDelegate.swift:6-10` → `+Links.swift:112-143` `makeTab(context: opener?.dataContext ?? dataContext, configuration: configuration)`. WebKit's opener configuration carries `webExtensionController` [INFERENCE: WebKit copies it with the opener config].
- Data contexts: `BrowserDataContext.swift:7` `BrowserWindowKind`, `:55-61` (`websiteDataStore`), `:94-101` `makePrivate(over:)` (`.nonPersistent()` store).
  - Per Space: `BrowserWindowManager+Profiles.swift:18-29` (`WKWebsiteDataStore(forIdentifier: profileID)`).
  - Default profile = `WKWebsiteDataStore.default()` (`BrowserProfiles.swift:34,80-84`). This equals the controller configuration's default `defaultWebsiteDataStore`.
- Manager-owned services to copy for `BrowserExtensions`:
  - `BrowserWindowManager.swift:89` (`tabSleeper`), `:92` (`contentBlocker`), `:167-171` (its init with a `<support>/ContentBlocking/` directory).
  - `supportDirectory` is used the same way for `<support>/Extensions/`.
- `Package.swift`: `swift-tools-version: 6.2`, `.macOS(.v26)`, **no package dependencies** (P0 is done). So no ZIPFoundation: unzip with `/usr/bin/ditto -x -k` as Search does, or hand-parse the central directory for the traversal check.

**Tab and window lifecycle (for `didOpen…`, `didClose…`, `didActivate…`, `didChangeTabProperties`)**
- Window open: `BrowserWindowManager.swift:423-454` `makeWindow`.
- Window close: `:389-410` `windowClosing` and `BrowserWindowController+Session.swift:226` `windowWillClose`.
- Focus: `+Session.swift:237` `windowDidBecomeKey` → `manager.windowBecameActive` (`BrowserWindowManager.swift:322-324`).
- Private windows: `:369-376` `newPrivateWindow`. Normal windows: `:353-366` `newWindow`.
- Tabs:
  - `+Tabs.swift:181-221` `attachTab` (open, or move into a window).
  - `:244-286` `detachTab` and `:289-337` `detachTabs` (close, or move out).
  - `:339-363` `bindTab` and `:365-380` `unbindTab`. `unbindTab` calls `removeAllScriptMessageHandlers()`.
  - `:384` `tearDown`.
  - `:401-440` `observe(_:)` has the KVO on `title`, `url` and `isLoading` → `.title`, `.URL` and `.loading` property changes.
  - `:464`, `:475` `selectTab` (activate).
  - `:559` `closeTab(id:archive:)`.
- Moves between windows: `BrowserWindowManager+TabMove.swift` (`moveTab…`, `openPopupWindow` at :150).
- Models: `BrowserTab` (`BrowserTab.swift:57`, `replaceWebView` :147) and `BrowserWindowController` (`BrowserWindowController.swift:9`). Both are Swift classes. Search wraps each in a small `NSObject` adapter conforming to `WKWebExtensionTab` / `WKWebExtensionWindow`, kept in a dictionary by tab id.
  - Required behavior: one tab list per window across all Spaces.

**Toolbar (action buttons)**
- `BrowserToolbarView.swift:7`. Trailing controls are declared at :31-35 and built at :81-105 (`ChromeIconButton(symbolName:accessibilityLabel:pointSize:…)`).
- Layout is a right-to-left chain:
  - `sidebarButton` trailing −10 (:179) → `downloadsButton` (:181) → `bookmarkButton` (:183).
  - `captureIndicator` trails `bookmarkButton` (:57-60 `captureTrailingToButtons`).
  - `addressFrame` trails `captureIndicator` (:191).
- An extension button stack goes between `captureIndicator` and `bookmarkButton` by re-pointing `captureTrailingToButtons`.
- `setCompact(_:)` (:352) hides buttons in pop-up windows.
- `addressAccessories` (:26) is the in-field accessory stack.

**Settings**
- `App/SettingsWindowController.swift`. Sheet pattern: a `ChromeButton(title: "Manage…")` (:44-48, :92-103) runs an `@objc …Pressed` that does `window.beginSheet(sheetWindow)` and keeps the sheet in a property while it is shown (:33-36, :491-514).
- Other sheets: `App/BrowserSearchEnginesSheet.swift`, `BrowserShortcutsSheet.swift`, `BrowserLinkRoutingSheet.swift`, `BrowserWebsitesSheet.swift`.
- `BrowserSettingsPage` enum (`Browser/BrowserCommandBar.swift:13-38`): add `.extensions` for the Command Bar's settings rows.

**Command registry and Command Bar**
- `Browser/BrowserCommands.swift`:
  - `:5-38` `BrowserCommandID` is a **static `CaseIterable` String enum**, and `settings.json` shortcuts are keyed by it.
  - `:45-58` `BrowserCommandContext`, `:75-105` `BrowserAppCommand`, `:217` `static let all`.
  - Extension commands are dynamic, so they cannot be enum cases. They need a dynamic row kind next to the registry: menu items and Command Bar rows built from `context.commands`, with keys from `WKWebExtension.Command.activationKey`/`modifierFlags` plus the extension's saved values.
- `App/MainMenu.swift:22` `install`, `:38` `buildMenu`, `:121-193` registry-driven items, `runCommand:` via the identifier.
- Command Bar:
  - `BrowserCommandBar.swift:42-79` `BrowserCommandBarRow` (`Kind`, `Target` at :56-70: add a `.extensionCommand` / `.extension` target).
  - `:87-…` `BrowserCommandBarInput`.
  - `BrowserWindowController+CommandBar.swift:67-110` `commandBarInput` (gathers sources) and `:142-148` (runs targets).
- Key routing for extension shortcuts:
  - `BrowserWebView.swift:29-32` → `+Shortcuts.swift:188` `routePageShortcut`.
  - `BrowserTab.swift:225` (`BrowserWindow.performKeyEquivalent`).
  - Call sites for `context.performCommand(for: event)` / `command(for:)`.

**Web-view context menu**
- `BrowserWebView.swift:17-21` `willOpenMenu(_:with:)` → `BrowserWindowController+PageTools.swift:192-218` `prepareContextMenu`.
- That rebuilds the menu from `BrowserContextMenu.transform` (`BrowserContextMenu.swift:79-131`). Its `default:` branch **keeps unknown items**, so items WebKit inserts survive.
- To add extension items, append `context.menuItems(for: tabAdapter)` for each loaded context after the transform. First check with `snapshot --context-menu` whether WebKit already inserts them on macOS [INFERENCE: unknown; verify].

**Tests**
- `Tests/SopranoWebTests/BrowserDelegateSelectorTests.swift:9-38` checks selectors with `class_getInstanceMethod`. Add the 12 controller-delegate selectors from §1 and the tab/window selectors the adapters implement.

## 3. Prior art

### 3a. driceroland/Search (MIT): https://github.com/driceroland/Search
- **`Sources/Search/Crx.swift`**:
  - id parsing: 32 chars `[a-p]`; store URL `https://chromewebstore.google.com/detail/[slug/]<id>` or legacy `https://chrome.google.com/webstore/detail/[slug/]<id>`; https only, no userinfo.
  - Download URL (§4).
  - `verifiedZip(_:id:)`:
    - Checks `Cr24` and version 3.
    - Reads header field 10000 → `SignedData.crx_id` and requires `letters(crx_id) == id`.
    - Builds the signed message (prefix + LE32 length + signed header + zip).
    - Accepts if **one RSA proof** (field 2) whose `SHA256(SPKI)[0..<16]` → letters == id verifies with `SecKeyVerifySignature(.rsaSignatureMessagePKCS1v15SHA256)`. The key is imported with `SecItemImport(.formatOpenSSL)`.
    - Does **not** check the ECDSA or publisher proofs.
  - `unpack`: `/usr/bin/ditto -x -k` into scratch, requires `manifest.json`, **refuses any symlink**, then moves into place.
  - Unpacked id: `letters(SHA256(realpath(folder))[0..<16])`. The manifest `key` is ignored.
  - `chromeVersion = "156.0.0.0"` is sent as `prodversion` and also faked into extension UAs. 1Password opens its unlock popup only from Chrome ≥149 (Search #685).
- **`Sources/Search/Extensions.swift`**, the delegate side:
  - One `WKWebExtensionController(configuration: .default())`, `defaultWebsiteDataStore` set (:155-188).
  - `Extensions.attach(configuration)` sets `webExtensionController` on every page view at birth (:57-60): "it can't be given one later".
  - **Same `applicationNameForUserAgent` as the tabs** on the controller's `webViewConfiguration` (:168-174). A differing UA makes WebKit stop extension workers and never restart them.
  - Registers the custom scheme `chrome-extension` and sets `context.baseURL = chrome-extension://<id>/` and `uniqueIdentifier = <id>` for a stable origin, so storage survives relaunches (:156, :512-519).
  - Install = consent: grants every `requestedPermissions` entry, `.nativeMessaging`, and `.declarativeNetRequestWithHostAccess` when DNR is requested (:523-535). Then grants sites and denies `chrome-extension://*/*` and `file://` patterns ("fence", :1205-1228).
  - `hasAccessToPrivateData` from a per-extension setting, unless the manifest has `incognito: "not_allowed"` (:1234-1244).
  - Tabs and windows: NSObject adapters (`ExtensionTab`, `ExtensionWindow`) over Swift models. Private tabs are hidden unless allowed (:302-304, :1816-1818).
  - Delegate (:1541-1768): `openWindowsFor` / `focusedWindowFor`, `openNewTabUsing` / `openNewWindowUsing` (refuses javascript: and file:, refuses private), `openOptionsPageFor`, the three prompt methods, `didUpdate` (bumps a counter for the toolbar), `presentActionPopup`, `sendMessage`, `connectUsing`.
  - `sendMessage`: `applicationIdentifier == nil || == "search"` → `ExtensionShims.answer`. Anything else goes to Chrome-style native hosts (`ExtensionNative.swift`), and only if the manifest itself asked for `nativeMessaging`.
  - Extension keystrokes: `context.command(for: event)` / `performCommand(for:)` (:1527-1533).
  - Errors: observes `WKWebExtensionContext.errorsDidUpdateNotification` per context (:820-824). This is the P2 "read the background errors" loop.
  - Uninstall: `controller.dataRecords(ofTypes: allExtensionDataTypes)` filtered by `uniqueIdentifier`, then `removeData` (:925-927).
- **`Sources/Search/ExtensionPopup.swift`**: Search does **not** use `action.popupPopover`. "For some extensions messages from WebKit's popup never reach the worker". Its `presentActionPopup` takes `action.popupWebView?.url`, calls `action.closePopup()`, and loads that URL in its own `WKWebView` built from `context.webViewConfiguration` inside its own `NSPopover`. The popover is sized 25-800 × ≤600 to content, and `window.close()` closes it.
- **`Sources/Search/ExtensionShims.swift`**, the chrome.* stand-ins:
  - At install, `prepare(folder)` (runs after the signature check):
    - Writes `search-shim.js` into the package.
    - Adds `nativeMessaging` (and `scripting` for `userScripts`) to `manifest.permissions` and records the additions in `.search-added`.
    - **Prepends the shim to the classic `background.service_worker` file** between marker comments, or adds `import "/search-shim.js"` for `type: "module"`.
    - Inserts the shim first in `background.scripts`, in every `content_scripts[].js`, and as `<script src="/search-shim.js">` in every shipped `.html` `<head>`.
    - Refuses paths outside the folder or symlinks.
    - A `.search-shim` stamp file avoids redoing the work.
  - The JS defines missing namespaces with `fill(name, members)`. Each call is `runtime.sendNativeMessage("search", {api, args})` and resolves to `reply.value` or rejects on `reply.error` (≈line 542-546).
  - Native side: `static func answer(_ message: Any, from: WKWebExtensionContext, owner:) async throws -> Any?` (≈3800). It is one `switch api` over strings such as `"notifications.create"` (→ `UNUserNotificationCenter`, id `"<extId>.<key>"`, ≈4247-4268), `"management.getSelf"`, `"runtime.getContexts"`, `"tabs.*"`, `"permissions.*"`, `"identity.launchWebAuthFlow"` and others.
  - Pure-JS stand-ins with no native call:
    - `storage.managed = { get: resolve({}), getBytesInUse: resolve(0), onChanged: event() }` (≈2266-2269).
    - `webNavigation.onCreatedNavigationTarget / onHistoryStateUpdated / onReferenceFragmentUpdated / onTabReplaced = event()` (≈2340-2344). These are inert event objects with `addListener` / `removeListener` / `hasListener`.
  - 1Password-specific fixes Search documents:
    - (a) **`clients.matchAll()` returns nothing in WebKit workers**, so 1Password's popup sticks on "connecting to the app". Search adds the open extension pages and a channel to them (≈603-616).
    - (b) **A worker `WebSocket` deadlocks WebKit's extension worker**, and 1Password opens one when sign-in succeeds. Search proxies sockets through a native port (`connectNative("search.socket")` → `ExtensionSocket.swift`, ≈711-715).
    - (c) `navigator.userAgent` / `userAgentData` are faked to Chrome only inside extension pages and workers (≈906-930), with no UA change on the WebKit configuration.
    - (d) The 1Password sign-in banner frame receives `runtime` messages (≈1610-1614).
  - Search also drops DNR rules that combine `regexFilter` with `requestDomains`. WebKit ignores `requestDomains` there and applies the rule everywhere, which blanked pages with uBO Lite's strict blocking (#709) (`dropMisreadRules`, ≈200+).

### 3b. duckduckgo/apple-browsers (Apache-2.0): `SharedPackages/WebExtensions/Sources/WebExtensions/ChromeWebStore/`
- `ChromeWebStorePackageVerifier.swift` (https://github.com/duckduckgo/apple-browsers/blob/main/SharedPackages/WebExtensions/Sources/WebExtensions/ChromeWebStore/ChromeWebStorePackageVerifier.swift):
  - Header: magic and version 3; header size ≤1 MiB and ≤ the remaining bytes.
  - Strict protobuf walk with varint bounds; fields 10000 and SignedData.1 must occur exactly once; `crx_id` must be 16 bytes and → letters == the requested id.
  - Signed data: `"CRX3 SignedData\0"` + LE32(len) + signed header + archive.
  - **Every** proof in fields 2 (RSA) and 3 (ECDSA) must verify, as in Chromium's `CRX3_WITH_PUBLISHER_PROOF`:
    - RSA: the SPKI is unwrapped to PKCS#1 by hand (checks the rsaEncryption OID `2a864886f70d010101` + NULL), then `SecKeyCreateWithData` + `.rsaSignatureMessagePKCS1v15SHA256`.
    - ECDSA: `P256.Signing.PublicKey(derRepresentation:)` + `ECDSASignature(derRepresentation:)`.
  - It requires both a developer proof (`SHA256(key)[0..<16] == crx_id`) and a publisher proof (`SHA256(key) == kPublisherKeyHash`).
  - `validateArchive` (needs ZIPFoundation, unavailable here) enforces these rules, which are worth copying:
    - No symlinks, no absolute, `\`, NUL, `.` or `..` path components, no empty directory components.
    - Case- and Unicode-normalized duplicate paths are refused.
    - At most 20,000 entries and 256 MiB uncompressed; `manifest.json` ≤1 MiB.
    - CRC is checked.
    - Manifest: MV2 or MV3, has `name`, no `app` or `theme`.
- `ChromeWebStoreDownloader.swift`: ephemeral `URLSession` download. Redirects and the final URL are only allowed to `https://clients2.google.com` or `https://clients2.googleusercontent.com` (port 443, no userinfo). HTTP 200 is required.
- `ChromeWebStoreCatalog.swift:36-75` `ChromeWebStoreURL`: the same download URL as Search with `prodversion=154.0.0.0`, `isValidExtensionID` (32 × `a…p`), and `isAllowedDownloadDestination`.

## 4. CRX3 format (Chromium `components/crx_file/crx3.proto`, `crx_verifier.cc` HEAD)

```
[4]  "Cr24"
[4]  uint32 LE version = 3
[4]  uint32 LE N = header length
[N]  CrxFileHeader (protobuf)
[..] ZIP archive (rest of file)

message CrxFileHeader {
  repeated AsymmetricKeyProof sha256_with_rsa   = 2;   // key = X.509 SubjectPublicKeyInfo DER; sig = RSA PKCS#1 v1.5 SHA-256 (the proto comment says "PSS"; the verifier uses RSA_PKCS1_SHA256)
  repeated AsymmetricKeyProof sha256_with_ecdsa = 3;   // key = SPKI DER, P-256; sig = DER ECDSA SHA-256
  optional bytes verified_contents = 4;                // gzipped verified_contents.json (optional)
  optional bytes signed_header_data = 10000;           // serialized SignedData
}
message AsymmetricKeyProof { optional bytes public_key = 1; optional bytes signature = 2; }
message SignedData { optional bytes crx_id = 1; }      // exactly 16 raw bytes
```
- **Signed message** for every proof: `"CRX3 SignedData\x00"` (16 bytes) ‖ `LE32(len(signed_header_data))` ‖ `signed_header_data` ‖ `archive`.
- **Extension id**: `crx_id` = first 16 bytes of `SHA-256(developer public key SPKI DER)`. Written as 32 chars, each nibble mapped 0-15 → `a`-`p`.
  - The id-proving key is the proof whose `SHA256(public_key)[0..<16] == crx_id`.
  - Chrome requires such a proof (`public_key_bytes` non-empty) **and** that every proof verifies.
- **Store publisher proof**: required for Web Store installs. `SHA-256(publisher SPKI)` = `61f7f2a6bfcf74cd0bc1fe2497cc9b04254c658f79f2145392867ea8366367cf` (`kPublisherKeyHash`, "ecdsa_2017_public").
- Chromium also rejects a header containing the ZIP tokens `PK\x05\x06` (EOCD) or `PK\x06\x07` (EOCD64 locator), plus `PK\x06\x06` behind a feature flag. Mirroring this is cheap and keeps the ZIP parser from being confused.
- **Download URL** (Search and DDG):
  `https://clients2.google.com/service/update2/crx?response=redirect&prodversion=<Chrome ver, e.g. 156.0.0.0>&acceptformat=crx3&x=id%3D<id>%26installsource%3Dondemand%26uc`
  - This 302-redirects to `https://clients2.googleusercontent.com/crx/blobs/…`.
  - A low or missing `prodversion` gives an empty response or 204, and min-version extensions are refused.
- **Daily update check** (same endpoint, protocol v2 XML; undocumented, from community sources):
  `…/crx?response=updatecheck&prodversion=<ver>&acceptformat=crx3&x=id%3D<id>%26v%3D<installed>%26uc`
  - The answer is `<gupdate><app appid=… status="ok"><updatecheck status="ok|noupdate" version="…" codebase="https://clients2.googleusercontent.com/…crx" hash_sha256="…"/></app></gupdate>`.
  - Several `x=` parameters can be batched in one request.
- Store page URL forms: `https://chromewebstore.google.com/detail/<slug>/<id>` (or without the slug) and legacy `https://chrome.google.com/webstore/detail/<slug>/<id>`.
- Proof-target ids [INFERENCE, check against the store]:
  - uBlock Origin Lite `ddkjiahejlhfcafbddmgiahcphecmpfh`
  - Wappalyzer `gppongmhjkpfnbhagpmjfkannfbllamg`
  - 1Password `aeblfdkhhhdcdjpifhhbdiojplfjncoa`

## 5. Implementation notes for P1 / P2 (derived)
- **One controller.** Use `WKWebExtensionController(configuration: .default())`. In the harness use `.init(identifier: <temp UUID>)` or `.nonPersistent()` so tests never touch real extension storage; the dev app already has its own WebKit container.
  - Set `configuration.webViewConfiguration.applicationNameForUserAgent = BrowserUserAgent.applicationName` (Search's worker-restart lesson).
  - Set `defaultWebsiteDataStore = .default()` (the Default Space's store).
- **Stable ids.** Before `load`, set `context.uniqueIdentifier = <crx id>` and `baseURL` to a registered custom scheme host = id: `registerCustomURLScheme("chrome-extension")` once at startup. Otherwise WebKit's random `webkit-extension://<uuid>` origin loses extension storage on every launch.
- **Persist per extension** in `extensions.json`: `grantedPermissions`, `grantedPermissionMatchPatterns`, `deniedPermissions`, `deniedPermissionMatchPatterns` (`MatchPattern.string`), `hasAccessToPrivateData`, `hasRequestedOptionalAccessToAllHosts`, command keys. Restore them before `load`.
- **Settings → per-site access** maps to `setPermissionStatus(.grantedExplicitly | .deniedExplicitly | .unknown, for: URL or MatchPattern)`.
- **Private windows.** `makePrivate(over:)` already supplies a non-persistent store and a per-web-view UCC. The window adapter returns `isPrivate(for:) == kind.isPrivate`. `hasAccessToPrivateData` decides visibility.
- **Extension URLs in tabs** (options page, `tabs.create` with an extension URL) must be created with `context.webViewConfiguration`. For a tab that navigates across the boundary, swap the web view (`replaceWebView` pattern).
- **Popups.** Present `action.popupPopover` from the toolbar button in `presentActionPopup` first. If an extension's popup cannot reach its worker (Search's finding), switch to Search's own-popover approach.
  - Refresh button icon, badge and enabled state in `didUpdate:forExtensionContext:`.
  - A click calls `context.performAction(for: tabAdapter)`.
- **Context menus.** Append `context.menuItems(for:)` per loaded context in `prepareContextMenu`.
- **Errors.** Observe `errorsDidUpdateNotification` and `context.errors` for P2's "read the background errors" loop. Set `isInspectable = true` in debug builds.
- **P2 route.**
  - On install, after the CRX check, write `soprano-shim.js` into the installed copy and prepend it to `background.service_worker`: classic workers get the text, module workers an `import`.
  - Add `nativeMessaging` to the manifest, or grant `.nativeMessaging` on the context.
  - Answer with `webExtensionController(_:sendMessage:toApplicationWithIdentifier:for:)` when the identifier is the app's own name.
  - First targets for 1Password 8.12 (ARC-PARITY load test, `docs/ARC-PARITY.md:191-211`):
    - `chrome.notifications` → `UNUserNotificationCenter`. Native: `create`, `clear`, `getAll`, `getPermissionLevel` (`"granted"`), `update`, and `onClicked` / `onClosed` / `onButtonClicked` events.
    - `webNavigation.onCreatedNavigationTarget` → an inert event in JS.
    - `storage.managed` → an empty area in JS.
  - Expected next failures (Search documents them for 1Password): `clients.matchAll()` returning no pages (popup stuck on "connecting"), the worker `WebSocket` deadlock on sign-in, a UA check needing Chrome ≥149 for the unlock popup, and runtime messages to the sign-in banner frame.
- **Archive safety without ZIPFoundation.**
  - Option 1: before extracting, read the ZIP central directory (EOCD → CD entries) and refuse absolute paths, `..`, backslashes, NUL, symlink modes (external attributes `0xA000`), duplicates, and count/size limits. Then `ditto -x -k`.
  - Option 2: afterwards, walk the result and refuse symlinks or any `realpath` outside the target, as Search does.
  - Option 3: hand `WKWebExtension(resourceBaseURL:)` the ZIP directly. Not possible here, because P2 must patch files.
