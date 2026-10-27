/// The script `BrowserExtensionShims` puts first in an extension's
/// background and pages: the Chrome APIs WebKit lacks or gets wrong, each a
/// stand-in that runs only when the extension's manifest asks for it
/// (`__SOPRANO_STAND_INS__`). A missing API is filled only where WebKit
/// leaves it undefined, so the day WebKit implements a member, WebKit's is
/// used. Calls go to the app as
/// `runtime.sendNativeMessage("soprano", { api, args })`
/// (`BrowserExtensionNativeHost`); the app's events (a notification
/// clicked) come back over the background's native port `soprano.events`,
/// and a worker's WebSockets run over `soprano.socket` ports
/// (`BrowserExtensionSocket`). Content scripts get nothing: on a web page
/// the script returns at once.
enum BrowserExtensionShimScript {
    static let source = #"""
    (() => {
      "use strict";
      const root = globalThis;
      const has = (object, key) => { try { return object != null && object[key] !== undefined; } catch (e) { return false; } };
      const api = has(root, "chrome") ? root.chrome : (has(root, "browser") ? root.browser : null);
      if (!api || !has(api, "runtime") || !has(api.runtime, "id") || root.__sopranoShim) return;
      // A content script on a web page: Chrome gives those none of these APIs.
      if (typeof location !== "undefined" && !/^(chrome|webkit)-extension:$/.test(location.protocol)) return;
      Object.defineProperty(root, "__sopranoShim", { value: true });

      const standIns = new Set(__SOPRANO_STAND_INS__);
      const chromeVersion = "__SOPRANO_CHROME_VERSION__";
      const application = "__SOPRANO_APPLICATION__";
      const eventsPort = "__SOPRANO_EVENTS_PORT__";
      const socketPort = "__SOPRANO_SOCKET_PORT__";
      const runtime = api.runtime;
      const namespaces = [...new Set([root.chrome, root.browser].filter((n) => n && typeof n === "object"))];
      const worker = typeof ServiceWorkerGlobalScope !== "undefined" && root instanceof ServiceWorkerGlobalScope;
      const background = worker || (typeof document !== "undefined" && (
        location.pathname === "/_generated_background_page.html" ||
        (() => { try { return api.extension.getBackgroundPage() === root; } catch (e) { return false; } })()
      ));

      const define = (target, key, value) => {
        try { Object.defineProperty(target, key, { value, configurable: true, writable: true, enumerable: true }); return true; }
        catch (e) { try { target[key] = value; return true; } catch (e2) { return false; } }
      };
      // WebKit may hand out a fresh namespace object on each lookup; one that
      // carries members of ours is pinned on `chrome`/`browser` so they stay.
      const runtimes = [];
      for (const ns of namespaces) {
        if (!has(ns, "runtime")) continue;
        const own = ns.runtime;
        define(ns, "runtime", own);
        if (!runtimes.includes(own)) runtimes.push(own);
      }
      const fill = (name, members) => {
        for (const ns of namespaces) {
          let target = has(ns, name) ? ns[name] : null;
          if (!target || (typeof target !== "object" && typeof target !== "function")) { target = {}; }
          define(ns, name, target);
          for (const [key, value] of Object.entries(members)) {
            if (!has(target, key)) define(target, key, value);
          }
        }
      };

      // Chrome's event objects, fired by the shim itself.
      const fire = new WeakMap();
      const event = () => {
        const listeners = [];
        const target = {
          addListener(listener) { if (typeof listener === "function" && !listeners.includes(listener)) listeners.push(listener); },
          removeListener(listener) { const i = listeners.indexOf(listener); if (i >= 0) listeners.splice(i, 1); },
          hasListener(listener) { return listeners.includes(listener); },
          hasListeners() { return listeners.length > 0; },
        };
        fire.set(target, (...args) => {
          for (const listener of [...listeners]) {
            try { listener(...args); } catch (error) { setTimeout(() => { throw error; }); }
          }
        });
        return target;
      };
      const dispatch = (target, ...args) => { const f = fire.get(target); if (f) f(...args); };

      // One call to the app; the reply is `{ value }` or `{ error }`.
      const native = (name, args) => {
        let message;
        try { message = { api: name, args: JSON.parse(JSON.stringify(args === undefined ? [] : args)) }; }
        catch (error) { return Promise.reject(error); }
        return Promise.resolve(runtime.sendNativeMessage(application, message)).then((reply) => {
          if (reply && typeof reply.error === "string") throw new Error(reply.error);
          return reply ? reply.value : undefined;
        });
      };
      // Chrome's APIs take a callback last (an error then sits in
      // `runtime.lastError`), or return a promise without one.
      const settle = (promise, callback) => {
        if (typeof callback !== "function") return promise;
        promise.then((value) => callback(value), (error) => {
          const lastError = { message: String((error && error.message) || error) };
          for (const own of runtimes) define(own, "lastError", lastError);
          try { callback(); } finally { for (const own of runtimes) { try { delete own.lastError; } catch (e) {} } }
        });
        return undefined;
      };
      const lastCallback = (args) => (args.length && typeof args[args.length - 1] === "function" ? args.pop() : null);

      // Events the app sends (`{ event, args }`) to the background.
      const nativeEvents = new Map();

      if (standIns.has("notifications")) {
        const onClicked = event(), onClosed = event(), onButtonClicked = event();
        nativeEvents.set("notifications.onClicked", onClicked);
        nativeEvents.set("notifications.onClosed", onClosed);
        nativeEvents.set("notifications.onButtonClicked", onButtonClicked);
        const options = (value) => (value && typeof value === "object" ? value : {});
        fill("notifications", {
          create(...args) {
            const callback = lastCallback(args);
            const named = typeof args[0] === "string" || (args[0] == null && args.length > 1);
            const id = named ? (args[0] || "") : "";
            return settle(native("notifications.create", [id, options(named ? args[1] : args[0])]), callback);
          },
          update: (id, value, callback) => settle(native("notifications.update", [String(id), options(value)]), callback),
          clear: (id, callback) => settle(native("notifications.clear", [String(id)]), callback),
          getAll: (callback) => settle(native("notifications.getAll", []), callback),
          getPermissionLevel: (callback) => settle(native("notifications.getPermissionLevel", []), callback),
          onClicked, onClosed, onButtonClicked,
          onPermissionLevelChanged: event(),
          onShowSettings: event(),
          TemplateType: { BASIC: "basic", IMAGE: "image", LIST: "list", PROGRESS: "progress" },
          PermissionLevel: { GRANTED: "granted", DENIED: "denied" },
        });
      }

      if (standIns.has("webNavigation")) {
        // A tab a page opened (a link with a target, ⌘-click, window.open)
        // is created with its opener: the app records it, WebKit reports it
        // as `openerTabId`, and that is Chrome's onCreatedNavigationTarget.
        const onCreatedNavigationTarget = event();
        const add = onCreatedNavigationTarget.addListener;
        let watching = false;
        onCreatedNavigationTarget.addListener = (listener) => {
          add(listener);
          if (watching || !has(api, "tabs") || !has(api.tabs, "onCreated")) return;
          watching = true;
          api.tabs.onCreated.addListener((tab) => {
            if (!tab || typeof tab.openerTabId !== "number" || tab.openerTabId < 0) return;
            dispatch(onCreatedNavigationTarget, {
              sourceTabId: tab.openerTabId, sourceProcessId: -1, sourceFrameId: 0,
              tabId: tab.id, url: tab.pendingUrl || tab.url || "", timestamp: Date.now(),
            });
          });
        };
        fill("webNavigation", {
          onCreatedNavigationTarget,
          onHistoryStateUpdated: event(),
          onReferenceFragmentUpdated: event(),
          onTabReplaced: event(),
        });
      }

      if (standIns.has("storage.managed") && has(api, "storage")) {
        // No policy sets anything here: an empty, read-only area.
        const readOnly = (...args) => settle(Promise.reject(new Error("storage.managed is read-only.")), lastCallback(args));
        fill("storage", {
          managed: {
            get: (...args) => settle(Promise.resolve({}), lastCallback(args)),
            getBytesInUse: (...args) => settle(Promise.resolve(0), lastCallback(args)),
            set: readOnly, remove: readOnly, clear: readOnly, setAccessLevel: readOnly,
            onChanged: event(),
          },
        });
      }

      if (standIns.has("userAgent") && typeof navigator !== "undefined" && !/ Chrome\//.test(navigator.userAgent)) {
        // The extension states a minimum Chrome version and reads it from
        // the user agent: its own pages and worker see Chrome's (web pages
        // keep the browser's).
        const platform = (navigator.userAgent.match(/\(([^)]*)\)/) || [])[1] || "Macintosh; Intel Mac OS X 10_15_7";
        const agent = "Mozilla/5.0 (" + platform + ") AppleWebKit/537.36 (KHTML, like Gecko) Chrome/" + chromeVersion + " Safari/537.36";
        const major = chromeVersion.split(".")[0];
        const brands = [{ brand: "Chromium", version: major }, { brand: "Google Chrome", version: major }, { brand: "Not.A/Brand", version: "99" }];
        const low = { brands, mobile: false, platform: "macOS" };
        const high = {
          architecture: "arm", bitness: "64", model: "", platformVersion: "26.0.0", wow64: false,
          fullVersionList: brands.map((b) => ({ brand: b.brand, version: b.version === major ? chromeVersion : b.version + ".0.0.0" })),
          uaFullVersion: chromeVersion,
        };
        const data = Object.assign({}, low, {
          getHighEntropyValues: (hints) => Promise.resolve(Object.assign({}, low,
            ...(Array.isArray(hints) ? hints : []).filter((h) => h in high).map((h) => ({ [h]: high[h] })))),
          toJSON: () => low,
        });
        const proto = worker && typeof WorkerNavigator !== "undefined" ? WorkerNavigator.prototype
          : (typeof Navigator !== "undefined" ? Navigator.prototype : null);
        if (proto) {
          for (const [key, value] of [["userAgent", agent], ["appVersion", agent.replace(/^Mozilla\//, "")], ["vendor", "Google Inc."], ["userAgentData", data]]) {
            try { Object.defineProperty(proto, key, { get: () => value, configurable: true }); } catch (e) {}
          }
        }
      }

      if (standIns.has("permissions")) {
        // WebKit refuses an origin with a port ("http://127.0.0.1:8080/*"),
        // which Chrome takes; a pattern without a port covers every port.
        const portless = (value) => {
          if (!value || typeof value !== "object" || !Array.isArray(value.origins)) return value;
          return Object.assign({}, value, {
            origins: value.origins.map((o) => (typeof o === "string" ? o.replace(/^([a-z*-]+:\/\/[^/:]*):(?:\d+|\*)(?=\/)/i, "$1") : o)),
          });
        };
        for (const ns of namespaces) {
          if (!has(ns, "permissions")) continue;
          const permissions = ns.permissions;
          define(ns, "permissions", permissions);
          for (const name of ["contains", "request", "remove"]) {
            const original = permissions[name];
            if (typeof original !== "function") continue;
            define(permissions, name, function (value, ...rest) { return original.call(permissions, portless(value), ...rest); });
          }
        }
      }

      if (standIns.has("wasm") && typeof WebAssembly === "object" && typeof Response === "function") {
        // WebKit serves the extension's .wasm files as
        // application/octet-stream, which streaming compilation refuses.
        const retyped = (source) => Promise.resolve(source).then((response) => {
          if (!(response instanceof Response) || !response.ok || /^application\/wasm\b/i.test(response.headers.get("content-type") || "")) return response;
          let url; try { url = new URL(response.url); } catch (e) { return response; }
          if (url.origin !== location.origin || !/\.wasm$/i.test(url.pathname)) return response;
          return new Response(response.body, { status: response.status, statusText: response.statusText, headers: { "content-type": "application/wasm" } });
        });
        for (const name of ["instantiateStreaming", "compileStreaming"]) {
          const original = WebAssembly[name];
          if (typeof original !== "function") continue;
          define(WebAssembly, name, (source, ...rest) => retyped(source).then((response) => original.call(WebAssembly, response, ...rest)));
        }
      }

      if (standIns.has("clients") && typeof BroadcastChannel === "function") {
        // clients.matchAll() in WebKit's extension worker lists none of the
        // extension's open pages; Chrome lists its popup and its tabs, and
        // extensions check it before telling the popup anything (1Password's
        // stays on "connecting"). The app knows which are open; a message
        // posted to one reaches it over a channel the pages listen on.
        const channel = new BroadcastChannel("soprano-clients");
        if (worker && has(root, "clients") && typeof root.clients.matchAll === "function") {
          const matchAll = root.clients.matchAll.bind(root.clients);
          const client = (page, index) => ({
            id: "soprano-" + index + "-" + page.url, url: page.url, type: "window", frameType: "top-level",
            visibilityState: page.visible ? "visible" : "hidden", focused: !!page.focused,
            postMessage(data) { try { channel.postMessage({ to: page.url, data }); } catch (e) {} },
            focus() { return Promise.resolve(this); },
            navigate() { return Promise.resolve(null); },
          });
          define(root.clients, "matchAll", async (options) => {
            const found = [...await matchAll(options)];
            const type = (options && options.type) || "window";
            if (type !== "window" && type !== "all") return found;
            let pages = [];
            try { pages = (await native("clients.pages", [])) || []; } catch (e) {}
            const listed = new Set(found.map((c) => c.url));
            return found.concat(pages.filter((p) => p && typeof p.url === "string" && !listed.has(p.url)).map(client));
          });
        } else if (!background && typeof navigator !== "undefined" && navigator.serviceWorker) {
          channel.onmessage = ({ data }) => {
            if (!data || data.to !== location.href) return;
            try { navigator.serviceWorker.dispatchEvent(new MessageEvent("message", { data: data.data, origin: location.origin })); } catch (e) {}
          };
        }
      }

      if (standIns.has("webSocket") && worker && typeof runtime.connectNative === "function") {
        // A WebSocket made in WebKit's extension worker never returns from
        // its constructor: the worker and every page of the extension
        // freeze (1Password opens one when sign-in succeeds). The app makes
        // the socket (BrowserExtensionSocket) and its frames cross a native
        // port.
        const connectNative = runtime.connectNative.bind(runtime);
        const encode = (bytes) => { let s = ""; for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000)); return btoa(s); };
        const decode = (text) => { const s = atob(text), bytes = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) bytes[i] = s.charCodeAt(i); return bytes.buffer; };
        const states = { CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3 };
        class WebSocket extends EventTarget {
          #port = null; #state = 0; #queue = Promise.resolve(); #origin = "";
          constructor(url, protocols) {
            super();
            let parsed;
            try { parsed = new URL(url, location.href); } catch (e) { throw new DOMException("The URL '" + url + "' is invalid.", "SyntaxError"); }
            if (parsed.protocol === "http:") parsed.protocol = "ws:";
            if (parsed.protocol === "https:") parsed.protocol = "wss:";
            if (!/^wss?:$/.test(parsed.protocol) || parsed.hash) throw new DOMException("The URL '" + url + "' is invalid.", "SyntaxError");
            const list = protocols === undefined ? [] : (Array.isArray(protocols) ? protocols : [protocols]).map(String);
            Object.defineProperty(this, "url", { value: parsed.href, enumerable: true });
            this.#origin = parsed.origin;
            this.protocol = ""; this.extensions = ""; this.binaryType = "blob"; this.bufferedAmount = 0;
            this.onopen = null; this.onmessage = null; this.onerror = null; this.onclose = null;
            this.#connect({ open: parsed.href, protocols: list, userAgent: navigator.userAgent });
          }
          // What a worker posts on a port it just opened can be lost, so
          // the opening is said again until the app answers.
          #connect(hello) {
            const port = connectNative(socketPort);
            this.#port = port;
            let answered = false, tries = 0;
            const again = () => {
              if (answered || this.#state === 3) return;
              if (tries++ >= 20) { this.#fire("error"); this.#closed(1006, "", false); return; }
              try { port.postMessage(hello); } catch (e) {}
              setTimeout(again, 100 * Math.min(tries, 5));
            };
            port.onMessage.addListener((message) => { answered = true; this.#take(message); });
            port.onDisconnect.addListener(() => { if (this.#state !== 3) { this.#fire("error"); this.#closed(1006, "", false); } });
            again();
          }
          get readyState() { return this.#state; }
          #fire(type, init) {
            let event;
            if (type === "message") event = new MessageEvent("message", init);
            else if (type === "close" && typeof CloseEvent === "function") event = new CloseEvent("close", init);
            else { event = new Event(type); if (init) for (const k in init) Object.defineProperty(event, k, { value: init[k] }); }
            const handler = this["on" + type];
            if (typeof handler === "function") { try { handler.call(this, event); } catch (e) { setTimeout(() => { throw e; }); } }
            this.dispatchEvent(event);
          }
          #closed(code, reason, wasClean) {
            this.#state = 3;
            try { this.#port.disconnect(); } catch (e) {}
            this.#fire("close", { code, reason, wasClean });
          }
          #take(m) {
            if (!m || typeof m !== "object" || this.#state === 3) return;
            if ("opened" in m) { if (this.#state !== 0) return; this.protocol = String(m.opened || ""); this.#state = 1; this.#fire("open"); }
            else if ("text" in m) this.#fire("message", { data: String(m.text), origin: this.#origin });
            else if ("binary" in m) {
              const buffer = decode(String(m.binary));
              this.#fire("message", { data: this.binaryType === "arraybuffer" ? buffer : new Blob([buffer]), origin: this.#origin });
            }
            else if ("failed" in m) this.#fire("error");
            else if ("closed" in m) this.#closed(Number(m.closed) || 1006, String(m.reason || ""), !!m.clean);
          }
          send(data) {
            if (this.#state === 0) throw new DOMException("WebSocket is still in CONNECTING state.", "InvalidStateError");
            if (this.#state !== 1) return;
            const post = (message) => { try { this.#port.postMessage(message); } catch (e) {} };
            if (typeof data === "string") { this.#queue = this.#queue.then(() => post({ send: data })); return; }
            const bytes = data instanceof ArrayBuffer ? Promise.resolve(new Uint8Array(data))
              : ArrayBuffer.isView(data) ? Promise.resolve(new Uint8Array(data.buffer, data.byteOffset, data.byteLength))
              : data instanceof Blob ? data.arrayBuffer().then((b) => new Uint8Array(b))
              : null;
            this.#queue = this.#queue.then(() => bytes).then((b) => (b ? post({ sendBinary: encode(b) }) : post({ send: String(data) })));
          }
          close(code, reason) {
            if (code !== undefined && code !== 1000 && !(code >= 3000 && code <= 4999)) {
              throw new DOMException("The close code must be either 1000, or between 3000 and 4999. " + code + " is neither.", "InvalidAccessError");
            }
            if (this.#state >= 2) return;
            this.#state = 2;
            const message = { close: code === undefined ? 1000 : code, reason: reason === undefined ? "" : String(reason) };
            this.#queue = this.#queue.then(() => { try { this.#port.postMessage(message); } catch (e) {} });
          }
        }
        for (const [k, v] of Object.entries(states)) {
          Object.defineProperty(WebSocket, k, { value: v });
          Object.defineProperty(WebSocket.prototype, k, { value: v });
        }
        define(root, "WebSocket", WebSocket);
      }

      // The background listens for the app's events on a native port.
      if (background && nativeEvents.size && typeof runtime.connectNative === "function") {
        try {
          const port = runtime.connectNative(eventsPort);
          port.onMessage.addListener((message) => {
            if (!message || typeof message.event !== "string") return;
            const target = nativeEvents.get(message.event);
            if (target) dispatch(target, ...(Array.isArray(message.args) ? message.args : []));
          });
        } catch (e) {}
      }
    })();
    """#
}
