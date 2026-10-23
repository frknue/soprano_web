import WebKit

/// Page scripts for audio detection, per-tab mute and the web notification
/// shim. The static scripts are in `BrowserPageScripts.all`; the per-tab
/// state they read (mute flag, remembered notification decisions) is a
/// small "state" script that the controller replaces when the state
/// changes, so each new document starts with the current state.
@MainActor
enum BrowserPermissionScripts {
    /// Every state script starts with this line; the controller swaps
    /// exactly these scripts and keeps all others in order.
    static let stateMarker = "/* soprano-web:state */"

    // MARK: Audio

    /// Isolated world, every frame. Reports whether the frame plays audible
    /// media: `mediaFrame {frame}` once per document, then debounced
    /// `mediaState {frame, audible, gone}` on changes and on `pagehide`.
    /// Under a tab mute an element that was audible before still counts, so
    /// the tab keeps showing that it plays.
    static let mediaReporter = BrowserPageScript(
        source: """
        (() => {
          const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.sopranoWeb;
          if (!handler) return;
          const frame = Array.from(crypto.getRandomValues(new Uint8Array(12)), (b) => b.toString(16).padStart(2, '0')).join('');
          const post = (message) => { try { handler.postMessage(message); } catch (_) {} };
          const wasAudible = new WeakSet();
          let reported = false;
          let timer = 0;
          const audible = () => {
            let any = false;
            for (const element of document.querySelectorAll('audio, video')) {
              if (element.paused || element.ended || element.volume === 0) continue;
              if (!element.muted) {
                wasAudible.add(element);
                any = true;
              } else if (globalThis.__sopranoMediaMuted === true && wasAudible.has(element)) {
                any = true;
              }
            }
            return any;
          };
          const report = () => {
            const value = audible();
            if (value === reported) return;
            reported = value;
            post({ type: 'mediaState', frame, audible: value, gone: false });
          };
          const schedule = () => {
            clearTimeout(timer);
            timer = setTimeout(report, 200);
          };
          for (const name of ['play', 'playing', 'pause', 'ended', 'volumechange', 'emptied']) {
            document.addEventListener(name, schedule, true);
          }
          window.addEventListener('pagehide', () => {
            clearTimeout(timer);
            reported = false;
            post({ type: 'mediaState', frame, audible: false, gone: true });
          });
          window.addEventListener('pageshow', (event) => {
            if (!event.persisted) return;
            post({ type: 'mediaFrame', frame });
            schedule();
          });
          globalThis.__sopranoMediaSync = schedule;
          post({ type: 'mediaFrame', frame });
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false,
        world: .isolated
    )

    /// Page world, every frame. While the tab is muted, mutes every media
    /// element that plays or unmutes itself, including detached
    /// `new Audio()` elements started through `play()`, and restores only
    /// the ones it muted when the tab is unmuted.
    static let mediaMute = BrowserPageScript(
        source: """
        (() => {
          const Media = window.HTMLMediaElement;
          if (!Media || window.__sopranoMedia) return;
          let muted = false;
          const ours = new WeakSet();
          let tracked = [];
          const track = (element) => {
            if (tracked.some((ref) => ref.deref() === element)) return;
            tracked = tracked.filter((ref) => ref.deref() !== undefined);
            tracked.push(new WeakRef(element));
          };
          const silence = (element) => {
            if (element.muted) return;
            element.muted = true;
            ours.add(element);
          };
          const originalPlay = Media.prototype.play;
          Media.prototype.play = function play() {
            if (this instanceof Media) {
              track(this);
              if (muted) silence(this);
            }
            return originalPlay.apply(this, arguments);
          };
          const onEvent = (event) => {
            const element = event.target;
            if (!(element instanceof Media)) return;
            track(element);
            if (muted) silence(element);
          };
          document.addEventListener('play', onEvent, true);
          document.addEventListener('volumechange', onEvent, true);
          const elements = () => {
            const all = new Set(document.querySelectorAll('audio, video'));
            for (const ref of tracked) {
              const element = ref.deref();
              if (element) all.add(element);
            }
            return all;
          };
          Object.defineProperty(window, '__sopranoMedia', {
            value: Object.freeze({
              setMuted(value) {
                muted = value === true;
                for (const element of elements()) {
                  if (muted) {
                    silence(element);
                  } else if (ours.has(element)) {
                    ours.delete(element);
                    element.muted = false;
                  }
                }
              },
            }),
          });
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false,
        world: .page
    )

    /// Sets the tab mute in one frame's isolated world, then re-reports.
    static func isolatedMuteSource(_ muted: Bool) -> String {
        "globalThis.__sopranoMediaMuted = \(muted); if (globalThis.__sopranoMediaSync) globalThis.__sopranoMediaSync();"
    }

    /// Sets the tab mute in one frame's page world.
    static func pageMuteSource(_ muted: Bool) -> String {
        "if (window.__sopranoMedia) window.__sopranoMedia.setMuted(\(muted));"
    }

    // MARK: Notifications

    /// Page world, main frame. Replaces WebKit's auto-denying `Notification`
    /// with one backed by the app: `permission` comes from the state script
    /// at document start, `requestPermission` (callback and promise) posts
    /// `notificationRequest {id}` and resolves through `resolve(id, state)`,
    /// `new Notification` posts `notificationShow {doc, id, title, body, tag,
    /// silent}` and gets `show`/`error` through `shown(doc, id, ok)` and
    /// `click` through `click(doc, id)`. `ServiceWorkerRegistration
    /// .showNotification` and `navigator.permissions.query` for
    /// `notifications` use the same state while the page is open.
    static let notifications = BrowserPageScript(
        source: """
        (() => {
          const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.sopranoWeb;
          if (!handler || window.__sopranoNotifications) return;
          const post = (message) => handler.postMessage(message);
          const host = location.protocol === 'file:' ? 'file' : location.hostname.toLowerCase().replace(/\\.+$/, '');
          const doc = Array.from(crypto.getRandomValues(new Uint8Array(8)), (b) => b.toString(16).padStart(2, '0')).join('');
          const states = ['granted', 'denied', 'default'];
          let permission = 'default';
          let nextID = 1;
          const pending = new Map();
          const open = new Map();
          const internals = new WeakMap();
          const text = (value, limit) => (value === undefined || value === null ? '' : String(value)).slice(0, limit);
          const fire = (notification, name) => {
            const event = new Event(name, { cancelable: name === 'click' });
            notification.dispatchEvent(event);
            const callback = notification['on' + name];
            if (typeof callback === 'function') {
              try { callback.call(notification, event); } catch (error) { setTimeout(() => { throw error; }); }
            }
          };
          class Notification extends EventTarget {
            constructor(title, options) {
              if (arguments.length === 0) {
                throw new TypeError("Failed to construct 'Notification': 1 argument required, but only 0 present.");
              }
              super();
              const o = options || {};
              const data = {
                id: nextID++,
                title: text(title, 512),
                body: text(o.body, 2048),
                tag: text(o.tag, 256),
                icon: text(o.icon, 2048),
                lang: text(o.lang, 64),
                dir: o.dir === 'ltr' || o.dir === 'rtl' ? o.dir : 'auto',
                data: o.data === undefined ? null : o.data,
                silent: o.silent === true,
                requireInteraction: o.requireInteraction === true,
              };
              internals.set(this, data);
              this.onclick = null;
              this.onshow = null;
              this.onerror = null;
              this.onclose = null;
              if (permission !== 'granted') {
                setTimeout(() => fire(this, 'error'));
                return;
              }
              if (data.tag) {
                for (const [id, other] of open) {
                  if (internals.get(other).tag === data.tag) open.delete(id);
                }
              }
              open.set(data.id, this);
              post({ type: 'notificationShow', doc, id: data.id, title: data.title, body: data.body, tag: data.tag, silent: data.silent });
            }
            get title() { return internals.get(this).title; }
            get body() { return internals.get(this).body; }
            get tag() { return internals.get(this).tag; }
            get icon() { return internals.get(this).icon; }
            get lang() { return internals.get(this).lang; }
            get dir() { return internals.get(this).dir; }
            get data() { return internals.get(this).data; }
            get silent() { return internals.get(this).silent; }
            get requireInteraction() { return internals.get(this).requireInteraction; }
            close() {
              const data = internals.get(this);
              if (!data || !open.delete(data.id)) return;
              post({ type: 'notificationClose', doc, id: data.id, tag: data.tag });
              setTimeout(() => fire(this, 'close'));
            }
            static get permission() { return permission; }
            static get maxActions() { return 0; }
            static requestPermission(callback) {
              return new Promise((resolve) => {
                const done = (state) => {
                  if (typeof callback === 'function') {
                    try { callback(state); } catch (error) { setTimeout(() => { throw error; }); }
                  }
                  resolve(state);
                };
                if (permission !== 'default') {
                  done(permission);
                  return;
                }
                const id = nextID++;
                pending.set(id, done);
                post({ type: 'notificationRequest', id });
              });
            }
          }
          const registration = window.ServiceWorkerRegistration;
          if (registration && registration.prototype) {
            registration.prototype.showNotification = function showNotification(title, options) {
              if (permission !== 'granted') {
                return Promise.reject(new TypeError('No notification permission has been granted for this origin.'));
              }
              const o = options || {};
              post({ type: 'notificationShow', doc, id: nextID++, title: text(title, 512), body: text(o.body, 2048), tag: text(o.tag, 256), silent: o.silent === true });
              return Promise.resolve();
            };
            registration.prototype.getNotifications = function getNotifications() {
              return Promise.resolve([]);
            };
          }
          const permissions = navigator.permissions;
          if (permissions && typeof permissions.query === 'function') {
            const query = permissions.query.bind(permissions);
            permissions.query = function (descriptor) {
              if (!descriptor || descriptor.name !== 'notifications') return query(descriptor);
              const status = new EventTarget();
              Object.defineProperties(status, {
                name: { value: 'notifications' },
                state: { get: () => (permission === 'default' ? 'prompt' : permission) },
                onchange: { value: null, writable: true },
              });
              return Promise.resolve(status);
            };
          }
          Object.defineProperty(window, '__sopranoNotifications', {
            value: Object.freeze({
              configure(remembered, asking) {
                const state = remembered[host];
                permission = states.includes(state) ? state : (asking ? 'default' : 'denied');
              },
              setPermission(state) {
                if (states.includes(state)) permission = state;
              },
              resolve(id, state) {
                if (states.includes(state)) permission = state;
                const done = pending.get(id);
                pending.delete(id);
                if (done) done(permission);
              },
              shown(token, id, ok) {
                const notification = token === doc ? open.get(id) : undefined;
                if (!notification) return;
                if (!ok) open.delete(id);
                fire(notification, ok ? 'show' : 'error');
              },
              click(token, id) {
                const notification = token === doc ? open.get(id) : undefined;
                if (!notification) return false;
                fire(notification, 'click');
                return true;
              },
            }),
          });
          Object.defineProperty(window, 'Notification', { value: Notification, writable: true, configurable: true });
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true,
        world: .page
    )

    /// Calls one method of the page's notification API with JSON arguments.
    static func notificationCall(_ method: String, _ arguments: [Any]) -> String {
        let json = (try? JSONSerialization.data(withJSONObject: arguments, options: [.fragmentsAllowed]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return "(() => { const api = window.__sopranoNotifications; return api ? api.\(method)(...\(json)) : false; })()"
    }

    // MARK: State

    /// The per-tab state scripts, added after every static script so they
    /// run after the scripts they configure.
    static func stateScripts(
        muted: Bool,
        notificationStates: [String: String],
        askingAllowed: Bool
    ) -> [WKUserScript] {
        var scripts = [
            WKUserScript(
                source: stateMarker + "\n" + notificationCall("configure", [notificationStates, askingAllowed]),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .page
            ),
        ]
        if muted {
            scripts.append(WKUserScript(
                source: stateMarker + "\n" + isolatedMuteSource(true),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: BrowserPageScripts.isolatedWorld
            ))
            scripts.append(WKUserScript(
                source: stateMarker + "\n" + pageMuteSource(true),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: .page
            ))
        }
        return scripts
    }
}
