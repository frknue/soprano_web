import WebKit

/// Settings ▸ "Put inactive tabs to sleep".
enum BrowserTabSleepAfter: String, Codable, CaseIterable, Sendable {
    case never
    case fifteenMinutes
    case oneHour
    case fourHours

    var name: String {
        switch self {
        case .never: "Never"
        case .fifteenMinutes: "After 15 minutes"
        case .oneHour: "After 1 hour"
        case .fourHours: "After 4 hours"
        }
    }

    /// How long a tab stays unselected before it sleeps; nil never.
    var interval: TimeInterval? {
        switch self {
        case .never: nil
        case .fifteenMinutes: 15 * 60
        case .oneHour: 60 * 60
        case .fourHours: 4 * 60 * 60
        }
    }
}

/// The system's memory pressure levels that put tabs to sleep early.
enum BrowserMemoryPressure: String, Sendable {
    case warning
    case critical

    /// Tabs unselected at least this long sleep at this level.
    var idleThreshold: TimeInterval {
        switch self {
        case .warning: 30 * 60
        case .critical: 5 * 60
        }
    }
}

/// Why a tab stays awake.
enum BrowserTabSleepExemption: String, Equatable, Sendable {
    /// The selected tab of its window.
    case selected
    /// Nothing to release: already asleep, or restored and never loaded.
    case notLoaded
    case playingAudio
    /// Camera, microphone or screen capture.
    case capturing
    case loading
    /// An open dialog, sheet, sign-in or permission prompt.
    case prompt
    /// `beforeunload` listeners or edited form fields.
    case unsavedInput
    /// A pop-up window, or a tab with a pop-up window open.
    case popup
    /// Tab menu ▸ Keep This Site Awake.
    case keptAwake
}

/// What the sleep policy reads from one tab.
struct BrowserTabSleepCandidate: Equatable, Sendable {
    var isSelected = false
    var isLoaded = true
    var isPlayingAudio = false
    var isCapturing = false
    var isLoading = false
    var hasOpenPrompt = false
    var hasUnsavedInput = false
    var isPopup = false
    var isKeptAwake = false
    /// When the tab was last selected or deselected.
    var lastActive: Date
}

/// Which tabs fall asleep: unselected for the idle threshold and not
/// exempt.
enum BrowserTabSleepPolicy {
    /// The first reason `candidate` stays awake whatever its idle time; nil
    /// when it may sleep.
    static func exemption(for candidate: BrowserTabSleepCandidate) -> BrowserTabSleepExemption? {
        if candidate.isSelected { return .selected }
        if !candidate.isLoaded { return .notLoaded }
        if candidate.isPopup { return .popup }
        if candidate.isPlayingAudio { return .playingAudio }
        if candidate.isCapturing { return .capturing }
        if candidate.isLoading { return .loading }
        if candidate.hasOpenPrompt { return .prompt }
        if candidate.hasUnsavedInput { return .unsavedInput }
        if candidate.isKeptAwake { return .keptAwake }
        return nil
    }

    /// How long a tab must be idle to sleep: the setting (or the harness's
    /// override), shortened by memory pressure. Nil when nothing sleeps
    /// (Settings ▸ Never also holds under memory pressure).
    static func idleThreshold(
        setting: BrowserTabSleepAfter,
        override: TimeInterval? = nil,
        pressure: BrowserMemoryPressure? = nil
    ) -> TimeInterval? {
        guard let interval = override ?? setting.interval else { return nil }
        guard let pressure else { return interval }
        return min(interval, pressure.idleThreshold)
    }

    static func shouldSleep(
        _ candidate: BrowserTabSleepCandidate,
        now: Date,
        idleThreshold: TimeInterval
    ) -> Bool {
        exemption(for: candidate) == nil && now.timeIntervalSince(candidate.lastActive) >= idleThreshold
    }
}

/// A sleeping tab: when it fell asleep and what its page looked like (JPEG,
/// in memory only, shown while it wakes).
struct BrowserTabSleepState {
    let sleptAt: Date
    let snapshot: Data?
}

/// The page script that keeps a tab awake while leaving it would lose
/// something.
@MainActor
enum BrowserTabSleepScripts {
    /// Page world, every frame. Reports `sleepGuard {frame, unsaved,
    /// capturing}` when it changes: `unsaved` while the page has
    /// `beforeunload` listeners (or an `onbeforeunload` handler) or the user
    /// edited a field (until the form is submitted or reset), `capturing`
    /// while a `getDisplayMedia` track is live. On `pagehide` the frame
    /// reports itself gone. The page can forge these messages; the worst it
    /// can do is keep its own tab awake.
    static let sleepGuard = BrowserPageScript(
        source: """
        (() => {
          const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.sopranoWeb;
          if (!handler || window.__sopranoSleepGuard) return;
          Object.defineProperty(window, '__sopranoSleepGuard', { value: true });
          const frame = Array.from(crypto.getRandomValues(new Uint8Array(12)), (b) => b.toString(16).padStart(2, '0')).join('');
          const post = (message) => { try { handler.postMessage(message); } catch (_) {} };
          const listeners = new Set();
          const captures = new Set();
          let edited = false;
          let reported = { unsaved: false, capturing: false };
          const report = () => {
            const unsaved = edited || listeners.size > 0 || typeof window.onbeforeunload === 'function';
            let capturing = false;
            for (const track of captures) {
              if (track.readyState === 'live') capturing = true; else captures.delete(track);
            }
            if (unsaved === reported.unsaved && capturing === reported.capturing) return;
            reported = { unsaved, capturing };
            post({ type: 'sleepGuard', frame, unsaved, capturing });
          };
          const schedule = () => { Promise.resolve().then(report); };
          const target = window.EventTarget && EventTarget.prototype;
          if (target) {
            const add = target.addEventListener;
            const remove = target.removeEventListener;
            target.addEventListener = function addEventListener(type, listener) {
              if (this === window && type === 'beforeunload' && listener) { listeners.add(listener); schedule(); }
              return add.apply(this, arguments);
            };
            target.removeEventListener = function removeEventListener(type, listener) {
              if (this === window && type === 'beforeunload') { listeners.delete(listener); schedule(); }
              return remove.apply(this, arguments);
            };
          }
          const editable = (element) => element instanceof HTMLTextAreaElement
            || element instanceof HTMLSelectElement
            || (element instanceof HTMLInputElement && !['button', 'submit', 'reset', 'image', 'hidden'].includes(element.type))
            || (element instanceof HTMLElement && element.isContentEditable);
          document.addEventListener('input', (event) => {
            if (!event.isTrusted || !editable(event.target)) return;
            edited = true;
            report();
          }, true);
          for (const name of ['submit', 'reset']) {
            document.addEventListener(name, () => { edited = false; schedule(); }, true);
          }
          const devices = window.MediaDevices && MediaDevices.prototype;
          if (devices && devices.getDisplayMedia) {
            const getDisplayMedia = devices.getDisplayMedia;
            devices.getDisplayMedia = function () {
              return getDisplayMedia.apply(this, arguments).then((stream) => {
                for (const track of stream.getTracks()) {
                  captures.add(track);
                  track.addEventListener('ended', report);
                }
                report();
                return stream;
              });
            };
            const stop = MediaStreamTrack.prototype.stop;
            MediaStreamTrack.prototype.stop = function () {
              const result = stop.apply(this, arguments);
              if (captures.has(this)) schedule();
              return result;
            };
          }
          document.addEventListener('DOMContentLoaded', report);
          window.addEventListener('load', report);
          window.addEventListener('pagehide', () => {
            reported = { unsaved: false, capturing: false };
            post({ type: 'sleepGuard', frame, unsaved: false, capturing: false });
          });
          window.addEventListener('pageshow', (event) => { if (event.persisted) report(); });
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false,
        world: .page
    )
}
