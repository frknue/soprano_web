import AppKit
import WebKit

/// Settings flags for `SopranoWeb snapshot`. `--settings` opens the
/// Settings tab (`BrowserWindowManager.showSettings`) and the capture
/// shows it like any page; `--click-element <css>` clicks its controls
/// (`[data-switch=restoreSession]`, `[data-open=searchEngines]`, …), which
/// post their messages as a real click does.
extension SnapshotCommand {
    /// `--settings-search <text>`: types `text` into the search box.
    static func searchSettings(_ text: String, controller: BrowserWindowController) {
        guard let webView = controller.selectedTab?.webView,
              let data = try? JSONSerialization.data(withJSONObject: [text]),
              let literal = String(data: data, encoding: .utf8)
        else { return }
        webView.evaluateJavaScript("""
        (() => {
          const search = document.getElementById("search");
          if (!search) return;
          search.value = \(literal)[0];
          search.dispatchEvent(new Event("input"));
        })()
        """) { _, _ in }
    }

    /// `--print-settings`: one `settings-page:` JSON line read from the
    /// selected tab's page (each switch, menu and fact as rendered, the
    /// rows and sections search leaves, the sidebar's current section),
    /// one `settings:` line of `settings.json`'s values, one
    /// `settings-sheets:` line with the sheets the page asked for and
    /// `settings-recorder: on|off` (the New Little Arc shortcut recorder).
    static func printSettings(controller: BrowserWindowController, manager: BrowserWindowManager) {
        if let webView = controller.selectedTab?.webView {
            var finished = false
            webView.evaluateJavaScript("""
            (() => {
              if (!window.__sopranoSettings) return null;
              const all = (selector) => Array.from(document.querySelectorAll(selector));
              const label = (row) => row.querySelector(".label")?.textContent ?? "";
              return JSON.stringify({
                address: location.href,
                title: document.title,
                switches: Object.fromEntries(all("[data-switch]").map((e) => [e.dataset.switch, e.getAttribute("aria-checked") === "true"])),
                menus: Object.fromEntries(all("select[data-key]").map((e) => [e.dataset.key, e.selectedOptions[0]?.textContent ?? ""])),
                texts: Object.fromEntries(all("[data-text]").map((e) => [e.dataset.text, e.textContent])),
                homepage: document.getElementById("homepage").value,
                neverTranslate: all("#neverTranslate .chip").map((e) => e.dataset.code),
                sections: all("section:not([hidden])").map((e) => e.id),
                rows: all(".row:not([hidden])").map(label),
                current: document.querySelector("nav a.current")?.dataset.nav ?? null,
                noResults: !document.querySelector(".noresults").hidden,
              });
            })()
            """) { result, error in
                if let text = result as? String {
                    print("settings-page: \(text)")
                } else {
                    print("settings-page: none (\(error?.localizedDescription ?? "not the Settings page"))")
                }
                finished = true
            }
            let deadline = Date().addingTimeInterval(5)
            while !finished, Date() < deadline {
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
        }
        if let data = try? JSONEncoder().encode(manager.settingsStore.settings),
           let text = String(data: data, encoding: .utf8)
        {
            print("settings: \(text)")
        }
        print("settings-sheets: \(manager.settingsSheetRequests.map(\.rawValue).joined(separator: ","))")
        print("settings-recorder: \(manager.shortcutRecorder == nil ? "off" : "on")")
    }
}
