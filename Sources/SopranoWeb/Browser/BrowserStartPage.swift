import AppKit

/// The local start page. It is plain HTML so it follows the Folio palette and
/// can show the user's bookmarks and recent pages without a web request. A
/// private window's start page says so and shows no recent pages.
enum BrowserStartPage {
    /// Pages in the Recent list.
    static let recentLimit = 6

    static func html(
        theme: AppTheme,
        settings: BrowserSettings,
        bookmarks: [BrowserBookmark],
        history: [BrowserHistoryPage],
        kind: BrowserWindowKind = .normal
    ) -> String {
        let colors = theme.colors
        let bookmarksHTML: String
        if bookmarks.isEmpty {
            bookmarksHTML = """
            <p class="empty">Bookmark a page with ⌘D and it shows up here.</p>
            """
        } else {
            bookmarksHTML = """
            <div class="grid">
            \(bookmarks.prefix(8).map { bookmark in
                """
                <a class="card" href="\(escape(bookmark.url))">
                  <div class="title">\(escape(bookmark.displayTitle))</div>
                  <div class="host">\(escape(host(of: bookmark.url)))</div>
                </a>
                """
            }.joined(separator: "\n"))
            </div>
            """
        }

        let recentSection: String
        if !kind.suggestsHistory {
            recentSection = ""
        } else if history.isEmpty {
            recentSection = """
            <section>
              <h2>Recent</h2>
              <p class="empty">Pages you visit appear here.</p>
            </section>
            """
        } else {
            recentSection = """
            <section>
              <h2>Recent</h2>
              <div class="recent">
              \(history.prefix(BrowserStartPage.recentLimit).map { entry in
                  """
                  <a href="\(escape(entry.url))">
                    <span class="title">\(escape(entry.displayTitle))</span>
                    <span class="host">\(escape(host(of: entry.url)))</span>
                  </a>
                  """
              }.joined(separator: "\n"))
              </div>
            </section>
            """
        }

        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <meta http-equiv="Content-Security-Policy"
              content="default-src 'none'; style-src 'unsafe-inline'; form-action https:; base-uri 'none';">
        <title>New Tab</title>
        <style>
          :root {
            --bg: \(hex(colors.bgBase));
            --panel: \(hex(colors.bgRaised));
            --raised: \(hex(colors.bgOverlay));
            --text: \(hex(colors.textPrimary));
            --muted: \(hex(colors.textMuted));
            --border: \(hex(colors.borderSubtle));
            --accent: \(hex(colors.accent));
          }
          * { box-sizing: border-box; }
          html, body { height: 100%; }
          body {
            margin: 0;
            background: var(--bg);
            color: var(--text);
            font: 13px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
            -webkit-font-smoothing: antialiased;
          }
          main { max-width: 760px; margin: 0 auto; padding: 84px 32px 56px; }
          .eyebrow {
            color: var(--muted);
            font: 600 11px/1 -apple-system, BlinkMacSystemFont, sans-serif;
            letter-spacing: 0.08em;
            text-transform: uppercase;
            margin-bottom: 14px;
          }
          h1 {
            font: 400 34px/1.1 ui-serif, "New York", Georgia, serif;
            letter-spacing: -0.01em;
            margin: 0 0 8px;
          }
          .sub { color: var(--muted); margin: 0 0 30px; font-size: 13px; }
          form { display: flex; gap: 8px; }
          input[type=search] {
            flex: 1;
            height: 40px;
            border: 1px solid var(--border);
            background: var(--panel);
            color: var(--text);
            border-radius: 8px;
            padding: 0 14px;
            font-size: 14px;
            outline: none;
          }
          input[type=search]:focus {
            border-color: var(--accent);
            box-shadow: 0 0 0 1px var(--accent);
          }
          button {
            height: 40px;
            padding: 0 18px;
            border-radius: 8px;
            border: 0;
            background: var(--text);
            color: var(--bg);
            font: 500 13px -apple-system, BlinkMacSystemFont, sans-serif;
            cursor: pointer;
          }
          section { margin-top: 42px; }
          h2 {
            font: 600 11px/1 -apple-system, BlinkMacSystemFont, sans-serif;
            letter-spacing: 0.08em;
            text-transform: uppercase;
            color: var(--muted);
            margin: 0 0 12px;
          }
          .grid {
            display: grid;
            grid-template-columns: repeat(4, minmax(0, 1fr));
            gap: 8px;
          }
          a.card {
            display: block;
            padding: 12px;
            border: 1px solid var(--border);
            border-radius: 8px;
            background: var(--panel);
            color: var(--text);
            text-decoration: none;
            min-width: 0;
          }
          a.card:hover { background: var(--raised); }
          .title {
            display: block;
            font-weight: 500;
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
          }
          .host {
            display: block;
            color: var(--muted);
            font-size: 11px;
            margin-top: 4px;
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
          }
          .recent a {
            display: flex;
            align-items: baseline;
            justify-content: space-between;
            gap: 16px;
            padding: 10px 2px;
            border-bottom: 1px solid var(--border);
            color: var(--text);
            text-decoration: none;
          }
          .recent a:hover .title { color: var(--accent); }
          .recent .title { flex: 1; min-width: 0; }
          .recent .host { margin: 0; max-width: 220px; }
          .empty { color: var(--muted); font-style: italic; margin: 0; }
          footer {
            margin-top: 44px;
            color: var(--muted);
            font-size: 11px;
            display: flex;
            gap: 16px;
          }
          @media (max-width: 680px) {
            .grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
            main { padding: 56px 20px 40px; }
          }
        </style>
        </head>
        <body>
        <main>
          <div class="eyebrow">\(kind.isPrivate ? "Private window" : "Soprano family")</div>
          <h1>Soprano Web</h1>
          <p class="sub">\(kind.isPrivate
              ? "Pages you open here stay out of History. Cookies and site data go when the window closes."
              : "Search the web, or enter an address above.")</p>
          <form action="\(escape(settings.searchEngine.searchFormURL))" method="get">
            <input type="search" name="q" placeholder="Search with \(escape(settings.searchEngine.name))">
            <button type="submit">Search</button>
          </form>
          <section>
            <h2>Bookmarks</h2>
            \(bookmarksHTML)
          </section>
          \(recentSection)
          <footer>
            <span>⌘L Address</span>
            <span>⌘T New tab</span>
            <span>⌘D Bookmark</span>
          </footer>
        </main>
        </body>
        </html>
        """
    }

    private static func host(of value: String) -> String {
        URL(string: value)?.host ?? value
    }

    static func hex(_ color: NSColor) -> String {
        guard let color = color.usingColorSpace(.sRGB) else { return "#000000" }
        let red = Int((color.redComponent * 255).rounded())
        let green = Int((color.greenComponent * 255).rounded())
        let blue = Int((color.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", red, green, blue)
    }

    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
