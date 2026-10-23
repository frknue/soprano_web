import AppKit

/// The local page shown instead of a site whose TLS connection failed. Its
/// buttons post `certificateInterstitial` messages with the interstitial's
/// token; the page itself is never added to history.
@MainActor
enum BrowserCertificateInterstitialPage {
    static let messageType = "certificateInterstitial"

    enum Action: String {
        case goBack
        case showCertificate
        case visitWebsite
    }

    static func html(
        theme: AppTheme,
        interstitial: BrowserCertificateInterstitial
    ) -> String {
        let colors = theme.colors
        let host = BrowserStartPage.escape(interstitial.host)
        let url = BrowserStartPage.escape(interstitial.failedURL.absoluteString)
        let explanation = BrowserStartPage.escape(interstitial.problem.explanation(host: interstitial.host))
        let certificateButton = interstitial.trust == nil ? "" : """
            <button id="show-certificate" type="button" onclick="send('\(Action.showCertificate.rawValue)')">Show Certificate</button>
        """
        let details: String
        if interstitial.allowsException {
            details = """
            <details id="details">
              <summary>Details</summary>
              <p>Someone could be pretending to be \(host) to read what you send, such as passwords or payment details. Visit the site only if you know why its certificate isn’t trusted, for example a device on your own network.</p>
              <p>The exception lasts until Soprano Web quits and covers only this certificate.</p>
              <button id="visit-website" type="button" onclick="send('\(Action.visitWebsite.rawValue)')">Visit Website</button>
            </details>
            """
        } else {
            details = ""
        }
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <title>This Connection Is Not Private</title>
        <style>
          :root {
            --bg: \(BrowserStartPage.hex(colors.bgBase));
            --panel: \(BrowserStartPage.hex(colors.bgRaised));
            --text: \(BrowserStartPage.hex(colors.textPrimary));
            --muted: \(BrowserStartPage.hex(colors.textMuted));
            --border: \(BrowserStartPage.hex(colors.borderSubtle));
            --accent: \(BrowserStartPage.hex(colors.accent));
            --ink: \(BrowserStartPage.hex(colors.inkButtonFill));
            --ink-label: \(BrowserStartPage.hex(colors.inkButtonLabel));
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
          .reason { color: var(--text); }
          .actions { display: flex; gap: 8px; margin: 22px 0 18px; }
          button {
            height: 28px;
            padding: 0 12px;
            border: 1px solid var(--border);
            border-radius: 6px;
            background: var(--panel);
            color: var(--text);
            font: 12px -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
            cursor: default;
          }
          button.primary { background: var(--ink); border-color: var(--ink); color: var(--ink-label); }
          button:focus-visible, summary:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
          details { color: var(--muted); border-top: 1px solid var(--border); padding-top: 12px; }
          summary { cursor: default; color: var(--text); margin-bottom: 8px; }
          details button { margin-top: 4px; }
        </style>
        </head>
        <body>
        <main>
          <h1>This connection is not private</h1>
          <p><span class="url">\(url)</span></p>
          <p class="reason">\(explanation)</p>
          <div class="actions">
            <button id="go-back" class="primary" type="button" onclick="send('\(Action.goBack.rawValue)')">Go Back</button>
            \(certificateButton)
          </div>
          \(details)
        </main>
        <script>
          function send(action) {
            window.webkit.messageHandlers.\(BrowserPageScripts.messageName).postMessage({
              type: "\(messageType)",
              action: action,
              token: "\(interstitial.token)"
            });
          }
          document.getElementById("go-back").focus();
        </script>
        </body>
        </html>
        """
    }
}
