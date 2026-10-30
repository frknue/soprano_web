import WebKit

/// The user scripts and live calls of Boosts. A Boost's CSS and JavaScript
/// run in `world`, which has no `sopranoWeb` handler (it is not a
/// `BrowserPageScript.World`), so user code can never post as ours. User
/// scripts can't be limited to a host, so every script starts with
/// `hostGuard`.
@MainActor
enum BrowserBoostScripts {
    /// Every Boost user script starts with this, so the state script swap
    /// can find and replace them.
    nonisolated static let marker = "/* soprano-web:boost */"

    static let world = WKContentWorld.world(name: "SopranoWebBoost")

    /// The Boost world's global holding the page's Boost sheet (a
    /// constructed `CSSStyleSheet` in `document.adoptedStyleSheets`; page
    /// scripts can't see it).
    nonisolated static let sheetGlobal = "__sopranoWebBoostSheet"

    /// JavaScript that returns from the enclosing function unless the page's
    /// host has Boost key `host` (`BrowserBoost.key`). It declares nothing,
    /// so a Boost's own top-level `const h` or `let host` can't collide
    /// with it.
    nonisolated static func hostGuard(_ host: String) -> String {
        "if ((function (h) { h = String(h).toLowerCase().replace(/\\.+$/, \"\"); "
            + "return h.indexOf(\"www.\") === 0 && h.length > 4 ? h.slice(4) : h; })(location.hostname)"
            + " !== \(literal(host))) return;"
    }

    /// The rule that hides a zapped selector.
    nonisolated static func hidingRule(_ selector: String) -> String {
        "\(selector) { display: none !important; }"
    }

    /// Sets the Boost stylesheet of a page of `host` to `css` plus one
    /// hiding rule per zap (takes it out of the document when both are
    /// empty). A constructed sheet in `document.adoptedStyleSheets`, not a
    /// `<style>`: a page's CSP `style-src` blocks an added `<style>` (even
    /// from an isolated world) but not a constructed sheet; a document has
    /// `adoptedStyleSheets` from the start, before any root element; and
    /// adopted sheets cascade after the page's own, so a Boost wins ties.
    /// Each zap goes in through `insertRule`, which refuses a selector that
    /// isn't one rule, so a bad zap drops only itself. `replaceSync` drops
    /// `@import` (constructed sheets don't allow it).
    nonisolated static func styleSource(host: String, css: String, zaps: [String] = []) -> String {
        """
        \(marker)
        (function () {
          \(hostGuard(host))
          var css = \(literal(css));
          var rules = \(literal(zaps.map(hidingRule)));
          var sheet = window.\(sheetGlobal);
          var empty = !css && rules.length === 0;
          if (!sheet) {
            if (empty) return;
            sheet = new CSSStyleSheet();
            window.\(sheetGlobal) = sheet;
          }
          sheet.replaceSync(css);
          rules.forEach(function (rule) {
            try { sheet.insertRule(rule, sheet.cssRules.length); } catch (e) {}
          });
          var sheets = Array.from(document.adoptedStyleSheets);
          var index = sheets.indexOf(sheet);
          if (!empty && index < 0) {
            document.adoptedStyleSheets = sheets.concat([sheet]);
          } else if (empty && index >= 0) {
            sheets.splice(index, 1);
            document.adoptedStyleSheets = sheets;
          }
          // A page that assigns `document.adoptedStyleSheets` without the
          // old ones (`= [own]`) drops the sheet: put it back at
          // DOMContentLoaded, load and pageshow while it has rules.
          if (!window.\(sheetGlobal)Ensure) {
            window.\(sheetGlobal)Ensure = true;
            var ensure = function () {
              var current = window.\(sheetGlobal);
              if (!current || !current.cssRules.length) return;
              var list = Array.from(document.adoptedStyleSheets);
              if (list.indexOf(current) < 0) document.adoptedStyleSheets = list.concat([current]);
            };
            document.addEventListener('DOMContentLoaded', ensure);
            window.addEventListener('load', ensure);
            window.addEventListener('pageshow', ensure);
          }
        })();
        """
    }

    /// The Boost's JavaScript, run once per document of `host`.
    nonisolated static func scriptSource(host: String, js: String) -> String {
        """
        \(marker)
        (function () {
          \(hostGuard(host))
        \(js)
        })();
        """
    }

    /// The user scripts of every enabled Boost.
    static func userScripts(_ boosts: [BrowserBoost]) -> [WKUserScript] {
        boosts.filter(\.isEnabled).flatMap { boost -> [WKUserScript] in
            var scripts: [WKUserScript] = []
            if boost.hasStyle {
                scripts.append(WKUserScript(
                    source: styleSource(host: boost.host, css: boost.css, zaps: boost.zaps),
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true,
                    in: world
                ))
            }
            if !boost.js.isEmpty {
                scripts.append(WKUserScript(
                    source: scriptSource(host: boost.host, js: boost.js),
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true,
                    in: world
                ))
            }
            return scripts
        }
    }

    // MARK: Zap mode

    /// Starts Zap mode in the trusted isolated world: the element under the
    /// pointer gets an outline, a click hides it and posts `zapPick` with
    /// its ancestor path (`BrowserZapSelector.Node`s, element first, up to
    /// `<body>`), Esc posts `zapEnd`.
    static let zapStart = """
    (function () {
      if (window.__sopranoWebZap) return;
      var post = function (body) { window.webkit.messageHandlers.sopranoWeb.postMessage(body); };
      var box = document.createElement("div");
      box.style.cssText = "position:fixed;pointer-events:none;z-index:2147483647;"
        + "outline:2px solid #e5484d;background:rgba(229,72,77,0.15);border-radius:2px;display:none";
      document.documentElement.appendChild(box);
      var target = null;
      function pickable(el) { return el && el !== box && el !== document.body && el !== document.documentElement; }
      function move(event) {
        var el = document.elementFromPoint(event.clientX, event.clientY);
        target = pickable(el) ? el : null;
        if (!target) { box.style.display = "none"; return; }
        var r = target.getBoundingClientRect();
        box.style.display = "block";
        box.style.left = r.left + "px"; box.style.top = r.top + "px";
        box.style.width = r.width + "px"; box.style.height = r.height + "px";
      }
      function path(el) {
        var nodes = [];
        for (; el && el !== document.body && el !== document.documentElement; el = el.parentElement) {
          var parent = el.parentElement, index = 1, count = 1;
          if (parent) {
            var same = Array.prototype.filter.call(parent.children, function (c) { return c.tagName === el.tagName; });
            index = same.indexOf(el) + 1; count = same.length;
          }
          nodes.push({ tag: el.tagName.toLowerCase(), id: el.id || "",
                       classes: Array.prototype.slice.call(el.classList), index: index, count: count });
        }
        return nodes;
      }
      function click(event) {
        event.preventDefault(); event.stopPropagation(); event.stopImmediatePropagation();
        if (!target) return;
        post({ type: "zapPick", path: path(target) });
        target.style.setProperty("display", "none", "important");
        box.style.display = "none"; target = null;
      }
      function swallow(event) { event.preventDefault(); event.stopPropagation(); event.stopImmediatePropagation(); }
      function key(event) {
        if (event.key !== "Escape") return;
        swallow(event); stop(); post({ type: "zapEnd" });
      }
      // On `window` in the capture phase, the first a page can listen at,
      // so page handlers (menus opening on pointerdown) never see a zap.
      var swallowed = ["mousedown", "mouseup", "pointerdown", "pointerup", "dblclick", "auxclick", "contextmenu"];
      function stop() {
        window.removeEventListener("mousemove", move, true);
        window.removeEventListener("click", click, true);
        window.removeEventListener("keydown", key, true);
        swallowed.forEach(function (type) { window.removeEventListener(type, swallow, true); });
        box.remove(); delete window.__sopranoWebZap;
      }
      window.addEventListener("mousemove", move, true);
      window.addEventListener("click", click, true);
      window.addEventListener("keydown", key, true);
      swallowed.forEach(function (type) { window.addEventListener(type, swallow, true); });
      window.__sopranoWebZap = stop;
    })();
    """

    /// Ends Zap mode without a message.
    static let zapStop = "if (window.__sopranoWebZap) window.__sopranoWebZap();"

    nonisolated static func literal(_ value: String) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    nonisolated static func literal(_ values: [String]) -> String {
        "[" + values.map(literal).joined(separator: ", ") + "]"
    }
}

/// Builds the selector Zap mode records for a clicked element from its
/// ancestor path: the nearest ancestor with a stable id anchors it,
/// otherwise `body`; each step is the tag, up to two stable classes, and
/// `:nth-of-type` when siblings share the tag. Generated-looking ids and
/// classes (digit runs, state classes) are left out so the selector
/// survives reloads.
enum BrowserZapSelector {
    struct Node: Equatable, Sendable {
        var tag: String
        var id: String = ""
        var classes: [String] = []
        /// 1-based position among siblings with the same tag.
        var index: Int = 1
        /// Siblings with the same tag, the element included.
        var count: Int = 1

        init(tag: String, id: String = "", classes: [String] = [], index: Int = 1, count: Int = 1) {
            self.tag = tag
            self.id = id
            self.classes = classes
            self.index = index
            self.count = count
        }

        init?(_ body: [String: Any]) {
            guard let tag = body["tag"] as? String, isIdentifier(tag) else { return nil }
            self.tag = tag.lowercased()
            id = body["id"] as? String ?? ""
            classes = body["classes"] as? [String] ?? []
            index = (body["index"] as? NSNumber)?.intValue ?? 1
            count = (body["count"] as? NSNumber)?.intValue ?? 1
        }
    }

    /// Nil for an empty path.
    static func selector(for path: [Node]) -> String? {
        guard !path.isEmpty else { return nil }
        var steps: [String] = []
        for node in path {
            if isStable(node.id) {
                steps.append("#" + escape(node.id))
                return steps.reversed().joined(separator: " > ")
            }
            var step = escape(node.tag)
            for name in node.classes.filter(isStableClass).prefix(2) {
                step += "." + escape(name)
            }
            if node.count > 1 {
                step += ":nth-of-type(\(max(node.index, 1)))"
            }
            steps.append(step)
        }
        return (["body"] + steps.reversed()).joined(separator: " > ")
    }

    static func isStable(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && !id.contains(":") && !hasDigitRun(id) && !id.contains(where: \.isWhitespace)
    }

    private static let stateClasses = ["is-", "has-", "js-", "hover", "active", "focus", "open", "selected", "visible", "hidden"]

    static func isStableClass(_ name: String) -> Bool {
        guard isStable(name), name.count <= 32 else { return false }
        let lower = name.lowercased()
        return !stateClasses.contains { lower.hasPrefix($0) } && name.allSatisfy { $0.isLetter || $0 == "-" || $0 == "_" }
    }

    private static func hasDigitRun(_ value: String) -> Bool {
        var run = 0
        for character in value {
            run = character.isNumber ? run + 1 : 0
            if run >= 3 { return true }
        }
        return false
    }

    /// A tag name as the page reports it: ASCII letters, digits, `-`, and
    /// the `_` and `.` custom element names may use.
    private static func isIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".")
        }
    }

    /// CSS identifier escaping, as `CSS.escape` does it: an ASCII digit
    /// first (or second, after `-`) becomes `\3X `, a lone `-` is escaped,
    /// control characters become hex escapes, ASCII other than letters,
    /// digits, `-` and `_` gets a backslash, and everything from U+0080 on
    /// stays as it is.
    static func escape(_ value: String) -> String {
        let scalars = Array(value.unicodeScalars)
        var result = ""
        for (offset, scalar) in scalars.enumerated() {
            let isDigit = ("0"..."9").contains(scalar)
            if scalar.value == 0 {
                result += "\u{FFFD}"
            } else if (0x01...0x1F).contains(scalar.value) || scalar.value == 0x7F {
                result += "\\" + String(scalar.value, radix: 16) + " "
            } else if isDigit, offset == 0 || (offset == 1 && scalars[0] == "-") {
                result += "\\3\(Character(scalar)) "
            } else if offset == 0, scalar == "-", scalars.count == 1 {
                result += "\\-"
            } else if scalar.value >= 0x80 || isDigit || scalar == "-" || scalar == "_"
                || ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
            {
                result.unicodeScalars.append(scalar)
            } else {
                result += "\\" + String(Character(scalar))
            }
        }
        return result
    }
}
