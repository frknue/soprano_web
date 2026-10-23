import Foundation

/// JavaScript evaluated on demand by a Vimium controller. Hints and visual
/// mode live in the page so they track the rendered layout; the native side
/// owns the mode state and receives only the hint strings.
enum VimiumPageScripts {
    static let focusMessageName = "sopranoVimiumFocus"

    static let focusObserver = """
    (() => {
      const editable = (el) => {
        if (!el) return false;
        if (el.isContentEditable) return true;
        const tag = el.tagName;
        if (tag === 'TEXTAREA') return !el.disabled && !el.readOnly;
        if (tag === 'SELECT') return !el.disabled;
        if (tag !== 'INPUT') return false;
        if (el.disabled || el.readOnly) return false;
        const type = (el.type || 'text').toLowerCase();
        return !['button', 'checkbox', 'color', 'file', 'hidden', 'image', 'radio',
                 'range', 'reset', 'submit'].includes(type);
      };
      const post = () => {
        try {
          window.webkit.messageHandlers.\(focusMessageName).postMessage(
            editable(document.activeElement)
          );
        } catch (_) {}
      };
      document.addEventListener('focusin', post, true);
      document.addEventListener('focusout', () => setTimeout(post, 0), true);
      post();
    })();
    """

    static func literal(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return text
    }

    static func scroll(dx: Double, dy: Double) -> String {
        "window.scrollBy(\(dx), \(dy));"
    }

    static func scrollPage(direction: Int) -> String {
        "window.scrollBy(0, window.innerHeight * 0.5 * \(direction));"
    }

    static func scrollToTop() -> String {
        "window.scrollTo(0, 0);"
    }

    static func scrollToBottom() -> String {
        "window.scrollTo(0, document.scrollingElement.scrollHeight);"
    }

    static func scrollToLeft() -> String {
        "window.scrollTo(0, window.scrollY);"
    }

    static func scrollToRight() -> String {
        "window.scrollTo(document.scrollingElement.scrollWidth, window.scrollY);"
    }

    static func scrollTo(x: Double, y: Double) -> String {
        "window.scrollTo(\(x), \(y));"
    }

    static func hints(hrefOnly: Bool) -> String {
        let selector = hrefOnly
            ? "'a[href], area[href]'"
            : "'a[href], button, input, select, textarea, summary, [role=\"button\"], [role=\"link\"], [onclick], [tabindex]:not([tabindex=\"-1\"])'"
        return """
        (() => {
          if (window.__sopranoHintsEnd) window.__sopranoHintsEnd();
          const root = document.createElement('div');
          root.id = '__soprano_hint_root';
          document.documentElement.appendChild(root);
          const elements = Array.from(document.querySelectorAll(\(selector))).filter((element) => {
            const rect = element.getBoundingClientRect();
            const style = getComputedStyle(element);
            return rect.width > 0 && rect.height > 0 &&
              style.visibility !== 'hidden' && style.display !== 'none' &&
              rect.bottom > 0 && rect.right > 0 &&
              rect.top < window.innerHeight && rect.left < window.innerWidth;
          });
          const alphabet = 'sadfjklewcmpgh';
          let length = 1;
          while (Math.pow(alphabet.length, length) < elements.length) length += 1;
          const hints = [];
          const map = {};
          for (let index = 0; index < elements.length; index += 1) {
            let value = index;
            let hint = '';
            for (let position = 0; position < length; position += 1) {
              hint = alphabet[value % alphabet.length] + hint;
              value = Math.floor(value / alphabet.length);
            }
            hints.push(hint);
            map[hint] = elements[index];
            const rect = elements[index].getBoundingClientRect();
            const badge = document.createElement('div');
            badge.textContent = hint;
            badge.dataset.hint = hint;
            Object.assign(badge.style, {
              position: 'fixed',
              left: `${rect.left}px`,
              top: `${rect.top}px`,
              zIndex: '2147483647',
              background: '#ffd76e',
              color: '#1b1b1b',
              font: '600 11px/1.2 ui-monospace, SFMono-Regular, Menlo, monospace',
              padding: '2px 4px',
              border: '1px solid #a67c00',
              borderRadius: '3px',
              boxShadow: '0 1px 3px rgba(0,0,0,.45)',
              pointerEvents: 'none',
            });
            root.appendChild(badge);
          }
          window.__sopranoHintMap = map;
          window.__sopranoHintRoot = root;
          window.__sopranoHintsEnd = () => {
            root.remove();
            delete window.__sopranoHintMap;
            delete window.__sopranoHintRoot;
            delete window.__sopranoHintsEnd;
          };
          return hints;
        })()
        """
    }

    static func filterHints(_ typed: String) -> String {
        """
        (() => {
          const typed = \(literal(typed));
          for (const badge of document.querySelectorAll('#__soprano_hint_root [data-hint]')) {
            badge.style.display = badge.dataset.hint.startsWith(typed) ? 'block' : 'none';
          }
        })()
        """
    }

    static func hintHref(_ hint: String) -> String {
        """
        (() => {
          const element = window.__sopranoHintMap?.[\(literal(hint))];
          if (!element) return '';
          return element.href || element.getAttribute('href') || '';
        })()
        """
    }

    static func hintClick(_ hint: String) -> String {
        """
        (() => {
          const element = window.__sopranoHintMap?.[\(literal(hint))];
          if (!element) return '';
          element.focus?.();
          element.click();
          return element.href || element.getAttribute('href') || '';
        })()
        """
    }

    static func removeHint(_ hint: String) -> String {
        """
        (() => {
          const hint = \(literal(hint));
          const badge = document.querySelector(
            `#__soprano_hint_root [data-hint="${CSS.escape(hint)}"]`
          );
          if (badge) badge.remove();
          if (window.__sopranoHintMap) delete window.__sopranoHintMap[hint];
          return String(Object.keys(window.__sopranoHintMap || {}).length);
        })()
        """
    }

    static func endHints() -> String {
        "window.__sopranoHintsEnd?.();"
    }

    static func startVisual(line: Bool) -> String {
        """
        (() => {
          const selection = window.getSelection();
          if (!selection.rangeCount) {
            const range = document.caretRangeFromPoint(
              window.innerWidth / 2,
              window.innerHeight / 2
            );
            if (range) {
              selection.removeAllRanges();
              selection.addRange(range);
            }
          }
          selection.collapseToStart();
          window.__sopranoVisual = true;
          return selection.toString();
        })()
        """
    }

    static func modifyVisual(alter: String, direction: String, granularity: String) -> String {
        """
        (() => {
          const selection = window.getSelection();
          selection.modify(\(literal(alter)), \(literal(direction)), \(literal(granularity)));
          return selection.toString();
        })()
        """
    }

    static func visualText() -> String {
        "window.getSelection().toString();"
    }

    static func clearVisual() -> String {
        "window.getSelection().removeAllRanges();"
    }

    static func selectedText() -> String {
        "window.getSelection().toString();"
    }

    static func focusInput() -> String {
        """
        (() => {
          const elements = Array.from(document.querySelectorAll(
            'input, textarea, select, [contenteditable="true"]'
          )).filter((element) => {
            const rect = element.getBoundingClientRect();
            const style = getComputedStyle(element);
            return rect.width > 0 && rect.height > 0 &&
              style.visibility !== 'hidden' && style.display !== 'none' &&
              !element.disabled;
          });
          if (!elements.length) return false;
          elements[0].focus();
          return true;
        })()
        """
    }

    static func nextLink(forward: Bool) -> String {
        let words = forward
            ? "[ 'next', 'more', 'older', '>', '›', '»', '→' ]"
            : "[ 'prev', 'previous', 'back', 'newer', '<', '‹', '«', '←' ]"
        return """
        (() => {
          const words = \(words);
          const links = Array.from(document.querySelectorAll('a[href]'));
          const target = links.find((link) => {
            const text = (link.textContent || '').trim().toLowerCase();
            const rel = (link.getAttribute('rel') || '').toLowerCase();
            return words.some((word) => text === word || rel === word);
          });
          if (!target) return false;
          target.click();
          return true;
        })()
        """
    }

    static func mute() -> String {
        """
        (() => {
          window.__sopranoMuted = !window.__sopranoMuted;
          document.querySelectorAll('audio, video').forEach((media) => {
            media.muted = window.__sopranoMuted;
          });
          return window.__sopranoMuted;
        })()
        """
    }

    static func scrollPosition() -> String {
        """
        JSON.stringify({
          x: window.scrollX,
          y: window.scrollY,
          url: location.href
        })
        """
    }

    static func source() -> String {
        "document.documentElement.outerHTML"
    }
}
