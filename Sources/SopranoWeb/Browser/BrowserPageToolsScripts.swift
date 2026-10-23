import WebKit

/// Page scripts for printing and the context menu.
enum BrowserPageToolsScripts {
    /// `window.print()` is a no-op in WKWebView without WebKit's private UI
    /// delegate, so the page's global posts a `print` request instead. Page
    /// world: it patches a page global; the controller treats the message as
    /// untrusted and shows at most one print sheet at a time.
    static let printOverride = BrowserPageScript(
        source: """
        (() => {
          const handler = window.webkit && window.webkit.messageHandlers
            && window.webkit.messageHandlers.sopranoWeb;
          if (!handler) { return; }
          const post = handler.postMessage.bind(handler);
          Object.defineProperty(window, "print", {
            configurable: true,
            writable: true,
            value: function print() { post({ type: "print" }); }
          });
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true,
        world: .page
    )

    /// Records what is under the pointer on right-click. The `contextmenu`
    /// event fires in the web process before WebKit sends the menu to the UI
    /// process, and both travel the same connection, so the message lands
    /// before `willOpenMenu(_:with:)`.
    static let contextMenuCapture = BrowserPageScript(
        source: """
        (() => {
          const handler = window.webkit && window.webkit.messageHandlers
            && window.webkit.messageHandlers.sopranoWeb;
          if (!handler) { return; }
          const absolute = (value) => {
            if (!value) { return ""; }
            try { return new URL(value, document.baseURI).href; } catch (_) { return ""; }
          };
          const selectedText = () => {
            const active = document.activeElement;
            if (active && (active.tagName === "TEXTAREA"
                || (active.tagName === "INPUT" && active.type !== "password"))) {
              try {
                const start = active.selectionStart, end = active.selectionEnd;
                if (typeof start === "number" && end > start) {
                  return active.value.substring(start, end);
                }
              } catch (_) {}
            }
            const selection = window.getSelection();
            return selection ? selection.toString() : "";
          };
          window.addEventListener("contextmenu", (event) => {
            const element = event.target instanceof Element ? event.target
              : (event.target && event.target.parentElement) || null;
            let link = "", image = "";
            if (element) {
              const anchor = element.closest("a[href], area[href], a[*|href]");
              if (anchor) {
                const href = anchor.href;
                link = typeof href === "string" ? href
                  : absolute(href && href.baseVal);
              }
              const img = element.closest("img");
              if (img) { image = absolute(img.currentSrc || img.src); }
            }
            handler.postMessage({
              type: "contextMenu",
              link: link,
              image: image,
              selection: selectedText().slice(0, 1000)
            });
          }, true);
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false,
        world: .isolated
    )
}
