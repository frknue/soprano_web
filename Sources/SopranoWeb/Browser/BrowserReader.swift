import AppKit

/// The article Readability found, as the Reader shows it.
struct BrowserReaderArticle: Equatable, Sendable {
    var title: String
    var byline: String
    var siteName: String
    /// Characters of article text.
    var length: Int

    init(title: String, byline: String = "", siteName: String = "", length: Int = 0) {
        self.title = title
        self.byline = byline
        self.siteName = siteName
        self.length = length
    }

    /// From the enter script's result; nil without an article.
    init?(result: Any?) {
        guard let body = result as? [String: Any], body["active"] as? Bool == true else { return nil }
        self.init(
            title: body["title"] as? String ?? "",
            byline: body["byline"] as? String ?? "",
            siteName: body["siteName"] as? String ?? "",
            length: (body["length"] as? NSNumber)?.intValue ?? 0
        )
    }
}

/// One tab's Reader: whether its page has an article (the page-info
/// report's `isProbablyReaderable`) and the article while the Reader shows
/// it. A new document starts over (`pageCommitted`).
struct BrowserTabReader: Equatable {
    var isReaderable = false
    /// Set while the page shows the Reader.
    private(set) var article: BrowserReaderArticle?

    var isActive: Bool { article != nil }
    /// ⇧⌘R can run: an article to show, or the Reader to leave.
    var isAvailable: Bool { isReaderable || isActive }

    mutating func entered(_ article: BrowserReaderArticle) {
        self.article = article
        isReaderable = true
    }

    mutating func left() {
        article = nil
    }

    mutating func pageCommitted() {
        self = BrowserTabReader()
    }
}

/// Readability.js 0.6.0 (Apache-2.0, `Resources/Readability` with its
/// LICENSE and NOTICE) and the Reader's isolated-world scripts. The Reader
/// swaps the page's root element for its own (`__sopranoReader` keeps the
/// page's), so leaving it restores the page as it was, without a reload.
@MainActor
enum BrowserReaderScripts {
    /// The vendored files, read once from the resource bundle.
    nonisolated static func resource(_ name: String) -> String? {
        guard let url = AppResources.bundle.url(forResource: name, withExtension: "js", subdirectory: "Readability")
            ?? AppResources.bundle.url(forResource: name, withExtension: "js")
        else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static let readability: String? = resource("Readability")
    static let readerable: String? = resource("Readability-readerable")

    /// Posts `pageInfo {readerable, lang, sample}` once the document is
    /// parsed and again after `load` when it changed: whether Readability
    /// would find an article (`isProbablyReaderable`), `<html lang>` and
    /// up to 3,000 characters of the page's text for the language guess.
    /// Main frame only; quiet while the Reader shows.
    static let pageInfo = BrowserPageScript(
        source: """
        (() => {
          const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.sopranoWeb;
          if (!handler || globalThis.__sopranoPageInfo) return;
          \(readerable ?? "function isProbablyReaderable() { return false; }")
          let last = '';
          const skipped = /^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE|CODE|PRE|TEXTAREA|SVG)$/;
          const sample = () => {
            const root = document.body;
            if (!root) return '';
            const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
              acceptNode(node) {
                if (node.nodeType === Node.ELEMENT_NODE) {
                  return skipped.test(node.tagName.toUpperCase()) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_SKIP;
                }
                return /\\p{L}/u.test(node.nodeValue) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP;
              }
            });
            let text = '';
            let node;
            while ((node = walker.nextNode()) && text.length < 3000) text += node.nodeValue.trim() + ' ';
            return text.slice(0, 3000);
          };
          // `force` posts an unchanged report again (a page back from the
          // back-forward cache, whose tab state started over).
          const report = (force) => {
            const reader = globalThis.__sopranoReader;
            if (reader && reader.active) return;
            let readerable = false;
            try { readerable = isProbablyReaderable(document); } catch (_) {}
            const message = { type: 'pageInfo', readerable, lang: document.documentElement.lang || '', sample: sample() };
            const key = JSON.stringify(message);
            if (!force && key === last) return;
            last = key;
            try { handler.postMessage(message); } catch (_) {}
          };
          globalThis.__sopranoPageInfo = report;
          if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => report(), { once: true });
          else report();
          window.addEventListener('load', () => setTimeout(() => report(), 300), { once: true });
        })();
        """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true,
        world: .isolated
    )

    /// `callAsyncJavaScript` body with `css`: parses a copy of the page
    /// with Readability and shows the article in the Reader's root
    /// (`{active, title, byline, siteName, length}`), or returns
    /// `{active: false, reason}` (`noArticle`, `noReadability`, an error).
    /// Fewer than 140 characters of text (`isProbablyReaderable`'s own
    /// minimum) is no article. The article's nodes are the page's own,
    /// cleaned of scripts, event handler attributes and `javascript:` links.
    static let enterSource = """
        const state = globalThis.__sopranoReader || (globalThis.__sopranoReader = { active: false });
        const summary = () => Object.assign({ active: true }, state.article);
        if (state.active) return summary();
        if (typeof Readability !== 'function') return { active: false, reason: 'noReadability' };
        let article = null;
        try {
          article = new Readability(document.cloneNode(true), { serializer: (element) => element }).parse();
        } catch (error) {
          return { active: false, reason: String(error) };
        }
        if (!article || !article.content || (article.textContent || '').trim().length < 140) return { active: false, reason: 'noArticle' };
        const content = document.importNode(article.content, true);
        for (const element of content.querySelectorAll('script, style, link, meta, base, noscript, template, object, embed')) element.remove();
        for (const element of [content, ...content.querySelectorAll('*')]) {
          for (const attribute of Array.from(element.attributes)) {
            const name = attribute.name.toLowerCase();
            const value = attribute.value.trim().toLowerCase();
            if (name.startsWith('on') || ((name === 'href' || name === 'src' || name === 'action' || name === 'formaction') && value.startsWith('javascript:'))) {
              element.removeAttribute(attribute.name);
            }
          }
        }
        const make = (tag, className, text) => {
          const element = document.createElement(tag);
          if (className) element.className = className;
          if (text) element.textContent = text;
          return element;
        };
        const root = make('html', 'soprano-reader');
        const lang = article.lang || document.documentElement.lang;
        if (lang) root.lang = lang;
        if (article.dir) root.dir = article.dir;
        const head = make('head');
        head.append(make('title', '', document.title));
        const body = make('body');
        const main = make('main', 'soprano-reader-article');
        const header = make('header', 'soprano-reader-header');
        const site = (article.siteName || location.hostname.replace(/^www\\./, '')).trim();
        if (site) header.append(make('p', 'soprano-reader-site', site));
        const title = (article.title || document.title || '').trim();
        if (title) header.append(make('h1', 'soprano-reader-title', title));
        const byline = (article.byline || '').trim();
        if (byline) header.append(make('p', 'soprano-reader-byline', byline));
        const text = make('div', 'soprano-reader-content');
        text.append(content);
        main.append(header, text);
        body.append(main);
        root.append(head, body);
        const sheet = new CSSStyleSheet();
        sheet.replaceSync(css);
        state.article = { title, byline, siteName: site, length: article.length || 0 };
        state.original = document.documentElement;
        state.sheets = Array.from(document.adoptedStyleSheets);
        state.scroll = [window.scrollX, window.scrollY];
        state.sheet = sheet;
        state.root = root;
        document.replaceChild(root, state.original);
        document.adoptedStyleSheets = [sheet];
        window.scrollTo(0, 0);
        state.active = true;
        return summary();
        """

    /// Puts the page's own root back where it was scrolled; `false` when
    /// the Reader wasn't showing.
    static let leaveSource = """
        const state = globalThis.__sopranoReader;
        if (!state || !state.active) return false;
        if (document.documentElement === state.root) document.replaceChild(state.original, state.root);
        document.adoptedStyleSheets = state.sheets || [];
        window.scrollTo(state.scroll[0], state.scroll[1]);
        Object.assign(state, { active: false, original: null, root: null, sheet: null, sheets: null });
        return true;
        """

    /// Restyles a showing Reader (`css`) after the theme changed.
    static let themeSource = """
        const state = globalThis.__sopranoReader;
        if (!state || !state.active || !state.sheet) return false;
        state.sheet.replaceSync(css);
        return true;
        """

    /// Run at every main-frame commit: a page back from the back-forward
    /// cache comes back as itself (Reader left, translation restored) and
    /// reports its page info again, since its tab state started over. A
    /// new document has none of this yet and nothing happens.
    static let commitSource = """
        (() => { \(leaveSource) })();
        (() => { \(BrowserTranslationScripts.restoreSource) })();
        if (globalThis.__sopranoPageInfo) globalThis.__sopranoPageInfo(true);
        true;
        """

    /// The Reader's style sheet in `theme`'s Folio tokens: New York text
    /// on the page color, SF Pro for the site and byline, the accent only
    /// for keyboard focus.
    static func css(theme: AppTheme) -> String {
        let colors = theme.colors
        let scheme = colors.appearance == .dark ? "dark" : "light"
        let hex = BrowserStartPage.hex
        return """
        :root { color-scheme: \(scheme); --bg: \(hex(colors.bgBase)); --raised: \(hex(colors.bgRaised));
          --text: \(hex(colors.textPrimary)); --muted: \(hex(colors.textMuted)); --border: \(hex(colors.borderSubtle));
          --border-strong: \(hex(colors.borderStrong)); --accent: \(hex(colors.accent)); background: var(--bg); }
        body { margin: 0; background: var(--bg); color: var(--text); font: 20px/1.6 ui-serif, "New York", Georgia, serif;
          -webkit-font-smoothing: antialiased; text-rendering: optimizeLegibility; }
        .soprano-reader-article { max-width: 680px; margin: 0 auto; padding: 64px 32px 112px; }
        .soprano-reader-header { margin: 0 0 36px; padding: 0 0 24px; border-bottom: 1px solid var(--border); }
        .soprano-reader-site { margin: 0 0 14px; color: var(--muted);
          font: 500 12px/1.4 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; letter-spacing: .06em; text-transform: uppercase; }
        .soprano-reader-title { margin: 0; font: 400 34px/1.15 ui-serif, "New York", Georgia, serif; letter-spacing: -.01em; }
        .soprano-reader-byline { margin: 14px 0 0; color: var(--muted); font: 13px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; }
        .soprano-reader-content h1, .soprano-reader-content h2, .soprano-reader-content h3, .soprano-reader-content h4 {
          font-weight: 500; line-height: 1.25; margin: 1.6em 0 .5em; }
        .soprano-reader-content h1 { font-size: 28px; } .soprano-reader-content h2 { font-size: 26px; }
        .soprano-reader-content h3 { font-size: 22px; } .soprano-reader-content h4 { font-size: 20px; }
        .soprano-reader-content p, .soprano-reader-content ul, .soprano-reader-content ol { margin: 0 0 1em; }
        .soprano-reader-content img, .soprano-reader-content video, .soprano-reader-content iframe,
        .soprano-reader-content svg, .soprano-reader-content canvas { max-width: 100%; height: auto; }
        .soprano-reader-content img { display: block; margin: 1.4em auto; border-radius: 6px; }
        .soprano-reader-content figure { margin: 1.6em 0; }
        .soprano-reader-content figcaption { margin-top: 8px; color: var(--muted);
          font: 13px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; }
        .soprano-reader-content a { color: inherit; text-decoration: underline; text-decoration-color: var(--border-strong);
          text-decoration-thickness: 1px; text-underline-offset: 3px; }
        .soprano-reader-content a:hover { text-decoration-color: var(--text); }
        a:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; border-radius: 2px; }
        .soprano-reader-content blockquote { margin: 1.4em 0; padding: 0 0 0 20px; border-left: 2px solid var(--border-strong); color: var(--muted); }
        .soprano-reader-content pre, .soprano-reader-content code { font: 15px/1.5 ui-monospace, "SF Mono", Menlo, monospace; }
        .soprano-reader-content pre { background: var(--raised); border: 1px solid var(--border); border-radius: 6px;
          padding: 14px 16px; overflow-x: auto; }
        .soprano-reader-content hr { border: 0; border-top: 1px solid var(--border); margin: 2em 0; }
        .soprano-reader-content table { border-collapse: collapse; margin: 1.4em 0; font-size: 16px; }
        .soprano-reader-content th, .soprano-reader-content td { border: 1px solid var(--border); padding: 6px 10px; text-align: left; }
        ::selection { background: var(--border-strong); }
        """
    }
}
