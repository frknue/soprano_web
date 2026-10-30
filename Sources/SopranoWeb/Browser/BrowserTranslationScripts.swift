import WebKit

/// Translate's isolated-world scripts (`callAsyncJavaScript` bodies). The
/// page's text nodes keep their elements and only change `nodeValue`, so
/// the layout stays; `__sopranoTranslation` keeps each node's original
/// text for "Show Original".
@MainActor
enum BrowserTranslationScripts {
    /// The most text nodes one page translates.
    static let maxNodes = 6000

    /// Collects the rendered text nodes not collected yet (skipping code,
    /// form fields, editable regions, `translate="no"` and `.notranslate`)
    /// and returns `{start, texts}`: each node's text without its leading
    /// and trailing white space, numbered from `start`.
    static let collectSource = """
        const state = globalThis.__sopranoTranslation || (globalThis.__sopranoTranslation = { nodes: [], originals: [], edges: [], translated: [] });
        const start = state.nodes.length;
        const texts = [];
        const root = document.body;
        if (!root) return { start, texts };
        const known = new Set(state.nodes);
        const skipped = /^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE|TEXTAREA|INPUT|SELECT|OPTION|CODE|PRE|KBD|SAMP|VAR|SVG|MATH|CANVAS|IFRAME)$/;
        const shown = new Map();
        const visible = (element) => {
          let value = shown.get(element);
          if (value === undefined) {
            value = element.checkVisibility
              ? element.checkVisibility({ visibilityProperty: true })
              : element.getClientRects().length > 0;
            shown.set(element, value);
          }
          return value;
        };
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
          acceptNode(node) {
            if (node.nodeType === Node.ELEMENT_NODE) {
              if (skipped.test(node.tagName.toUpperCase()) || node.isContentEditable
                  || node.getAttribute('translate') === 'no' || node.classList.contains('notranslate')) {
                return NodeFilter.FILTER_REJECT;
              }
              return NodeFilter.FILTER_SKIP;
            }
            if (known.has(node) || !/\\p{L}/u.test(node.nodeValue)) return NodeFilter.FILTER_SKIP;
            return node.parentElement && visible(node.parentElement) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP;
          }
        });
        let node;
        while ((node = walker.nextNode()) && state.nodes.length < limit) {
          const value = node.nodeValue;
          const match = /^(\\s*)([\\s\\S]*?)(\\s*)$/.exec(value);
          state.nodes.push(node);
          state.originals.push(value);
          state.edges.push([match[1], match[3]]);
          texts.push(match[2]);
        }
        return { start, texts };
        """

    /// Writes `texts` into the nodes numbered from `start` (their white
    /// space kept), skipping a node the page changed since; returns how
    /// many it wrote.
    static let applySource = """
        const state = globalThis.__sopranoTranslation;
        if (!state) return 0;
        let applied = 0;
        texts.forEach((text, offset) => {
          const index = start + offset;
          const node = state.nodes[index];
          if (!node || typeof text !== 'string' || node.nodeValue !== state.originals[index]) return;
          const value = state.edges[index][0] + text + state.edges[index][1];
          node.nodeValue = value;
          state.translated[index] = value;
          applied += 1;
        });
        return applied;
        """

    /// Puts the original text back into every node still showing its
    /// translation and forgets the nodes; returns how many it restored.
    static let restoreSource = """
        const state = globalThis.__sopranoTranslation;
        if (!state) return 0;
        let restored = 0;
        state.nodes.forEach((node, index) => {
          const value = state.translated[index];
          if (value !== undefined && node.nodeValue === value) {
            node.nodeValue = state.originals[index];
            restored += 1;
          }
        });
        globalThis.__sopranoTranslation = null;
        return restored;
        """

    static func collect(in webView: WKWebView) async throws -> (start: Int, texts: [String]) {
        let result = try await webView.callAsyncJavaScript(
            collectSource,
            arguments: ["limit": maxNodes],
            in: nil,
            contentWorld: BrowserPageScripts.isolatedWorld
        )
        let body = result as? [String: Any]
        return ((body?["start"] as? NSNumber)?.intValue ?? 0, body?["texts"] as? [String] ?? [])
    }

    @discardableResult
    static func apply(_ texts: [String], from start: Int, in webView: WKWebView) async throws -> Int {
        let result = try await webView.callAsyncJavaScript(
            applySource,
            arguments: ["start": start, "texts": texts],
            in: nil,
            contentWorld: BrowserPageScripts.isolatedWorld
        )
        return (result as? NSNumber)?.intValue ?? 0
    }

    @discardableResult
    static func restore(in webView: WKWebView) async throws -> Int {
        let result = try await webView.callAsyncJavaScript(
            restoreSource,
            arguments: [:],
            in: nil,
            contentWorld: BrowserPageScripts.isolatedWorld
        )
        return (result as? NSNumber)?.intValue ?? 0
    }
}
