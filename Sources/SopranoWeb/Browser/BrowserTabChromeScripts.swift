import WebKit

/// Isolated-world scripts behind tab chrome: favicon discovery and the
/// link-hover status. Both post through `BrowserPageScripts.messageName`.
@MainActor
enum BrowserTabChromeScripts {
    /// Reports `{type: "favicons", icons: [{href, rel, sizes, type}]}` once
    /// the document is parsed, and again when the head's icon links change
    /// (sites that swap icons for unread counts or themes).
    static let favicons = BrowserPageScript(
        source: """
        (() => {
          if (window.__sopranoFavicons) { return; }
          window.__sopranoFavicons = true;
          let last = null;
          let timer = null;
          const collect = () => Array.from(document.querySelectorAll('link[rel][href]'))
            .filter((link) => /(^|\\s)(icon|apple-touch-icon(-precomposed)?)(\\s|$)/i.test(link.rel))
            .slice(0, 32)
            .map((link) => ({
              href: link.href,
              rel: link.rel || '',
              sizes: link.getAttribute('sizes') || '',
              type: link.getAttribute('type') || ''
            }));
          const report = () => {
            timer = null;
            const icons = collect();
            const key = JSON.stringify(icons);
            if (key === last) { return; }
            last = key;
            window.webkit.messageHandlers.\(BrowserPageScripts.messageName).postMessage({ type: 'favicons', icons });
          };
          const schedule = () => {
            if (timer === null) { timer = setTimeout(report, 300); }
          };
          report();
          const target = document.head || document.documentElement;
          if (target) {
            new MutationObserver(schedule).observe(target, {
              childList: true,
              subtree: true,
              attributes: true,
              attributeFilter: ['href', 'rel', 'sizes', 'type']
            });
          }
        })();
        """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true,
        world: .isolated
    )

    /// Reports `{type: "linkHover", url}` for the link under the pointer or
    /// with keyboard focus, at most every 80 ms; an empty `url` clears it.
    static let linkHover = BrowserPageScript(
        source: """
        (() => {
          if (window.__sopranoLinkHover) { return; }
          window.__sopranoLinkHover = true;
          const post = (url) => window.webkit.messageHandlers.\(BrowserPageScripts.messageName)
            .postMessage({ type: 'linkHover', url });
          let sent = '';
          let pending = '';
          let lastSentAt = 0;
          let timer = null;
          const flush = () => {
            timer = null;
            if (pending === sent) { return; }
            sent = pending;
            lastSentAt = Date.now();
            post(sent);
          };
          const send = (url) => {
            pending = url;
            if (timer !== null) { return; }
            timer = setTimeout(flush, Math.max(0, 80 - (Date.now() - lastSentAt)));
          };
          const linkOf = (node) => {
            const element = node && node.nodeType === 1 ? node : (node && node.parentElement);
            return element && element.closest ? element.closest('a[href], area[href]') : null;
          };
          const hrefOf = (link) => {
            if (!link) { return ''; }
            if (typeof link.href === 'string') { return link.href; }
            const raw = link.href && link.href.baseVal;
            try { return raw ? new URL(raw, document.baseURI).href : ''; } catch (_) { return ''; }
          };
          document.addEventListener('mouseover', (event) => send(hrefOf(linkOf(event.target))), true);
          document.addEventListener('mouseout', (event) => { if (!event.relatedTarget) { send(''); } }, true);
          document.addEventListener('focusin', (event) => {
            const link = linkOf(event.target);
            if (link) { send(hrefOf(link)); }
          }, true);
          document.addEventListener('focusout', (event) => { if (linkOf(event.target)) { send(''); } }, true);
          window.addEventListener('pagehide', () => {
            pending = '';
            if (sent !== '') { sent = ''; post(''); }
          });
        })();
        """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true,
        world: .isolated
    )
}
