import AppKit

/// A local error page shown when a navigation fails. Reload (⌘R) retries the
/// address; the page itself is never added to history.
enum BrowserErrorPage {
    static func html(theme: AppTheme, url: String, message: String) -> String {
        let colors = theme.colors
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <title>Can’t Open Page</title>
        <style>
          :root {
            --bg: \(BrowserStartPage.hex(colors.bgBase));
            --panel: \(BrowserStartPage.hex(colors.bgRaised));
            --text: \(BrowserStartPage.hex(colors.textPrimary));
            --muted: \(BrowserStartPage.hex(colors.textMuted));
            --border: \(BrowserStartPage.hex(colors.borderSubtle));
            --accent: \(BrowserStartPage.hex(colors.accent));
          }
          * { box-sizing: border-box; }
          html, body { height: 100%; }
          body {
            margin: 0;
            background: var(--bg);
            color: var(--text);
            font: 13px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
          }
          main { max-width: 560px; margin: 0 auto; padding: 96px 32px; }
          h1 { font: 400 26px/1.15 ui-serif, "New York", Georgia, serif; margin: 0 0 12px; }
          p { margin: 0 0 10px; }
          .url {
            display: inline-block;
            max-width: 100%;
            padding: 4px 8px;
            border: 1px solid var(--border);
            border-radius: 6px;
            background: var(--panel);
            color: var(--muted);
            font: 11px/1.4 ui-monospace, "SF Mono", Menlo, monospace;
            overflow-wrap: anywhere;
          }
          .message { color: var(--muted); }
          .hint { color: var(--muted); margin-top: 22px; }
          .hint b { color: var(--text); font-weight: 500; }
        </style>
        </head>
        <body>
        <main>
          <h1>Can’t open this page</h1>
          <p><span class="url">\(BrowserStartPage.escape(url.isEmpty ? "about:blank" : url))</span></p>
          <p class="message">\(BrowserStartPage.escape(message))</p>
          <p class="hint">Check the address and your connection, then press <b>⌘R</b> to try again.</p>
        </main>
        </body>
        </html>
        """
    }
}
