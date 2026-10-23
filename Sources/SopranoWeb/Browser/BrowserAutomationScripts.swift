import Foundation

/// The JavaScript behind `soprano-web browser`. The refs and command names
/// match Soprano's browser pane, so an agent that already drives a Soprano
/// browser can drive this app the same way.
enum BrowserAutomationScripts {
    static func printableJavaScriptValue(_ value: Any?) -> String {
        guard let value else { return "null" }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(
               withJSONObject: value,
               options: [.prettyPrinted, .sortedKeys]
           ),
           let json = String(data: data, encoding: .utf8)
        {
            return json
        }
        return String(describing: value)
    }

    static func literal(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8)
        else {
            return "\"\""
        }
        return literal
    }

    private static func resolverPrelude(selector: String) -> String {
        """
        const selector = \(literal(selector));
        const resolve = (value) => {
          if (value.startsWith('@')) {
            return window.__sopranoElementRefs?.[value.slice(1)] || null;
          }
          try { return document.querySelector(value); } catch (_) { return null; }
        };
        const element = resolve(selector);
        if (!element) return {ok: false, error: `Element not found: ${selector}`};
        """
    }

    static func elementActionScript(command: String, selector: String) -> String {
        let action: String
        switch command {
        case "click":
            action = "element.click();"
        case "dblclick":
            action = """
            element.dispatchEvent(new MouseEvent('dblclick', {bubbles: true, cancelable: true, view: window}));
            """
        case "focus":
            action = "element.focus();"
        case "hover":
            action = """
            element.dispatchEvent(new MouseEvent('mouseover', {bubbles: true, view: window}));
            element.dispatchEvent(new MouseEvent('mouseenter', {bubbles: false, view: window}));
            """
        case "check":
            action = """
            if (!('checked' in element)) return {ok: false, error: 'Element is not checkable'};
            element.checked = true;
            element.dispatchEvent(new Event('input', {bubbles: true}));
            element.dispatchEvent(new Event('change', {bubbles: true}));
            """
        case "uncheck":
            action = """
            if (!('checked' in element)) return {ok: false, error: 'Element is not checkable'};
            element.checked = false;
            element.dispatchEvent(new Event('input', {bubbles: true}));
            element.dispatchEvent(new Event('change', {bubbles: true}));
            """
        case "scroll-into-view":
            action = "element.scrollIntoView({block: 'center', inline: 'center'});"
        default:
            action = ""
        }

        return """
        (() => {
          \(resolverPrelude(selector: selector))
          element.scrollIntoView({block: 'center', inline: 'center'});
          \(action)
          return {ok: true, output: \(literal("\(command) \(selector)"))};
        })()
        """
    }

    static func textActionScript(command: String, selector: String, text: String) -> String {
        let assignment = command == "fill"
            ? "element.value = text;"
            : "element.value = String(element.value || '') + text;"
        return """
        (() => {
          \(resolverPrelude(selector: selector))
          const text = \(literal(text));
          element.focus();
          if (element.isContentEditable) {
            element.textContent = \(command == "fill" ? "text" : "String(element.textContent || '') + text");
          } else if ('value' in element) {
            \(assignment)
          } else {
            return {ok: false, error: 'Element is not editable'};
          }
          element.dispatchEvent(new InputEvent('input', {bubbles: true, inputType: 'insertText', data: text}));
          element.dispatchEvent(new Event('change', {bubbles: true}));
          return {ok: true, output: \(literal("\(command) \(selector)"))};
        })()
        """
    }

    static func keyPressScript(key: String) -> String {
        """
        (() => {
          const element = document.activeElement || document.body;
          const key = \(literal(key));
          const aliases = {Enter: 'Enter', Escape: 'Escape', Tab: 'Tab', Space: ' '};
          const resolved = aliases[key] || key;
          element.dispatchEvent(new KeyboardEvent('keydown', {key: resolved, bubbles: true, cancelable: true}));
          if (resolved === 'Enter') {
            if (element.form?.requestSubmit) element.form.requestSubmit();
            else if (element.click) element.click();
          } else if (resolved.length === 1 && 'value' in element) {
            element.value = String(element.value || '') + resolved;
            element.dispatchEvent(new InputEvent('input', {bubbles: true, data: resolved}));
          }
          element.dispatchEvent(new KeyboardEvent('keyup', {key: resolved, bubbles: true, cancelable: true}));
          return {ok: true, output: `pressed ${key}`};
        })()
        """
    }

    static func getScript(kind: String, selector: String, attribute: String?) -> String {
        let expression: String
        switch kind {
        case "text":
            expression = "element.innerText ?? element.textContent ?? ''"
        case "html":
            expression = "element.outerHTML"
        case "value":
            expression = "element.value ?? ''"
        case "attr":
            expression = "element.getAttribute(\(literal(attribute ?? ""))) ?? ''"
        case "count":
            return """
            (() => {
              const selector = \(literal(selector));
              if (selector.startsWith('@')) {
                return {ok: true, output: window.__sopranoElementRefs?.[selector.slice(1)] ? '1' : '0'};
              }
              try {
                return {ok: true, output: String(document.querySelectorAll(selector).length)};
              } catch (_) {
                return {ok: false, error: `Invalid selector: ${selector}`};
              }
            })()
            """
        default:
            return "({ok: false, error: \(literal("Unsupported getter: \(kind)"))})"
        }

        return """
        (() => {
          \(resolverPrelude(selector: selector))
          return {ok: true, output: String(\(expression))};
        })()
        """
    }

    static func stateScript(kind: String, selector: String) -> String {
        let expression: String
        switch kind {
        case "visible":
            expression = """
            (() => {
              const style = getComputedStyle(element);
              const rect = element.getBoundingClientRect();
              return style.visibility !== 'hidden' && style.display !== 'none' &&
                rect.width > 0 && rect.height > 0;
            })()
            """
        case "enabled":
            expression = "!element.disabled && element.getAttribute('aria-disabled') !== 'true'"
        case "checked":
            expression = "Boolean(element.checked || element.getAttribute('aria-checked') === 'true')"
        default:
            return "({ok: false, error: \(literal("Unsupported state check: \(kind)"))})"
        }
        return """
        (() => {
          \(resolverPrelude(selector: selector))
          return {ok: true, output: String(Boolean(\(expression)))};
        })()
        """
    }

    static func snapshotScript(interactiveOnly: Bool) -> String {
        """
        (() => {
          window.__sopranoElementRefs = {};
          let nextRef = 1;
          const interactiveOnly = \(interactiveOnly ? "true" : "false");
          const implicitRoles = {
            A: 'link', BUTTON: 'button', INPUT: 'textbox', SELECT: 'combobox',
            TEXTAREA: 'textbox', IMG: 'img', H1: 'heading', H2: 'heading',
            H3: 'heading', H4: 'heading', H5: 'heading', H6: 'heading',
            LI: 'listitem', OPTION: 'option', SUMMARY: 'button'
          };
          const interactiveRoles = new Set([
            'button', 'link', 'textbox', 'searchbox', 'combobox', 'checkbox',
            'radio', 'slider', 'spinbutton', 'switch', 'tab', 'menuitem', 'option'
          ]);
          const visible = (element) => {
            const style = getComputedStyle(element);
            const rect = element.getBoundingClientRect();
            return style.visibility !== 'hidden' && style.display !== 'none' &&
              rect.width > 0 && rect.height > 0;
          };
          const roleFor = (element) => {
            const explicit = element.getAttribute('role');
            if (explicit) return explicit;
            if (element.tagName === 'INPUT') {
              const type = (element.getAttribute('type') || 'text').toLowerCase();
              if (type === 'checkbox') return 'checkbox';
              if (type === 'radio') return 'radio';
              if (['button', 'submit', 'reset'].includes(type)) return 'button';
              if (type === 'range') return 'slider';
              if (type === 'search') return 'searchbox';
            }
            return implicitRoles[element.tagName] || '';
          };
          const nameFor = (element) => {
            const labelledBy = element.getAttribute('aria-labelledby');
            if (labelledBy) {
              const text = labelledBy.split(/\\s+/).map((id) =>
                document.getElementById(id)?.innerText || ''
              ).join(' ').trim();
              if (text) return text;
            }
            const aria = element.getAttribute('aria-label');
            if (aria) return aria.trim();
            if (element.labels?.length) {
              const text = Array.from(element.labels).map((label) => label.innerText).join(' ').trim();
              if (text) return text;
            }
            return (
              element.getAttribute('alt') ||
              element.getAttribute('title') ||
              element.getAttribute('placeholder') ||
              element.value ||
              element.innerText ||
              element.textContent ||
              ''
            ).replace(/\\s+/g, ' ').trim().slice(0, 160);
          };
          const lines = [];
          for (const element of document.querySelectorAll('*')) {
            if (!visible(element)) continue;
            const role = roleFor(element);
            if (!role) continue;
            const interactive = interactiveRoles.has(role) ||
              element.matches('a[href],button,input,select,textarea,[tabindex]:not([tabindex="-1"])');
            if (interactiveOnly && !interactive) continue;
            const name = nameFor(element).replaceAll('"', '\\\\"');
            let suffix = '';
            if (interactive) {
              const ref = `e${nextRef++}`;
              window.__sopranoElementRefs[ref] = element;
              suffix += ` [ref=${ref}]`;
            }
            if (role === 'heading' && /^H[1-6]$/.test(element.tagName)) {
              suffix += ` [level=${element.tagName.slice(1)}]`;
            }
            if (element.disabled || element.getAttribute('aria-disabled') === 'true') {
              suffix += ' [disabled]';
            }
            if (element.checked || element.getAttribute('aria-checked') === 'true') {
              suffix += ' [checked]';
            }
            lines.push(`- ${role}${name ? ` "${name}"` : ''}${suffix}`);
          }
          return lines.length ? lines.join('\\n') : '(no accessible elements)';
        })()
        """
    }
}
