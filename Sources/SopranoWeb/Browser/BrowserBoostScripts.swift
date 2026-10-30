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

    /// The attribute of the one `<style>` a Boost adds.
    nonisolated static let styleAttribute = "data-soprano-web-boost"

    /// JavaScript that returns from the enclosing function unless the page's
    /// host has Boost key `host` (`BrowserBoost.key`).
    nonisolated static func hostGuard(_ host: String) -> String {
        "var h = location.hostname.toLowerCase().replace(/\\.+$/, \"\"); "
            + "if (h.indexOf(\"www.\") === 0 && h.length > 4) h = h.slice(4); "
            + "if (h !== \(literal(host))) return;"
    }

    /// Sets the Boost `<style>` of a page of `host` to `css` (removes it
    /// when empty). At document start the element to hold it may not
    /// exist yet, so it waits for one.
    nonisolated static func styleSource(host: String, css: String) -> String {
        """
        \(marker)
        (function () {
          \(hostGuard(host))
          var css = \(literal(css));
          function apply() {
            var root = document.head || document.documentElement;
            if (!root) return false;
            var style = document.querySelector("style[\(styleAttribute)]");
            if (!css) { if (style) style.remove(); return true; }
            if (!style) {
              style = document.createElement("style");
              style.setAttribute("\(styleAttribute)", "");
            }
            if (style.textContent !== css) style.textContent = css;
            if (style.parentNode !== root) root.appendChild(style);
            return true;
          }
          if (apply()) return;
          var observer = new MutationObserver(function () { if (apply()) observer.disconnect(); });
          observer.observe(document, { childList: true, subtree: true });
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
            let stylesheet = boost.stylesheet
            if !stylesheet.isEmpty {
                scripts.append(WKUserScript(
                    source: styleSource(host: boost.host, css: stylesheet),
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
      function swallow(event) { event.preventDefault(); event.stopPropagation(); }
      function key(event) {
        if (event.key !== "Escape") return;
        swallow(event); stop(); post({ type: "zapEnd" });
      }
      function stop() {
        document.removeEventListener("mousemove", move, true);
        document.removeEventListener("click", click, true);
        document.removeEventListener("mousedown", swallow, true);
        document.removeEventListener("mouseup", swallow, true);
        document.removeEventListener("keydown", key, true);
        box.remove(); delete window.__sopranoWebZap;
      }
      document.addEventListener("mousemove", move, true);
      document.addEventListener("click", click, true);
      document.addEventListener("mousedown", swallow, true);
      document.addEventListener("mouseup", swallow, true);
      document.addEventListener("keydown", key, true);
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
            var step = node.tag
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

    private static func isIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// CSS identifier escaping (`CSS.escape` for the characters ids and
    /// classes use).
    static func escape(_ value: String) -> String {
        var result = ""
        for (offset, scalar) in value.unicodeScalars.enumerated() {
            let character = Character(scalar)
            if offset == 0, character.isNumber {
                result += "\\3\(character) "
            } else if character.isLetter || character.isNumber || character == "-" || character == "_" || scalar.value > 0x7F {
                result.unicodeScalars.append(scalar)
            } else {
                result += "\\" + String(character)
            }
        }
        return result
    }
}
