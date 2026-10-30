import Foundation

/// `browser boost …` in the app, after `BrowserCommandRequest.parseBoost`
/// checked the arguments and replaced a `css`/`js` source with its text.
@MainActor
enum BrowserBoostCommands {
    static func perform(_ arguments: [String], in store: BrowserBoostStore) -> Result<String, Error> {
        guard let action = arguments.first else { return .success(list(store)) }
        if action == "list" {
            return .success(list(store))
        }
        guard arguments.count >= 2, let host = BrowserBoost.key(arguments[1]) else {
            return .failure(BrowserAutomationError.invalidArguments(BrowserCommandRequest.boostUsage))
        }
        let missing = BrowserAutomationError.invalidArguments("No Boost for \(host). Use `boost list` to list them.")
        switch action {
        case "show":
            guard let boost = store.boost(host: host) else { return .failure(missing) }
            return .success(show(boost))
        case "enable", "disable":
            guard store.boost(host: host) != nil else { return .failure(missing) }
            store.update(host: host) { $0.isEnabled = action == "enable" }
            return .success("\(host) \(action)d")
        case "remove":
            return store.remove(host: host) ? .success("\(host) removed") : .failure(missing)
        case "css", "js":
            guard arguments.count == 3 else {
                return .failure(BrowserAutomationError.invalidArguments(BrowserCommandRequest.boostUsage))
            }
            let text = arguments[2]
            store.update(host: host) { boost in
                if action == "css" { boost.css = text } else { boost.js = text }
            }
            let note = action == "js" ? " (runs from the next page load)" : ""
            return .success("\(host) \(action): \(text.utf8.count) bytes\(note)")
        case "zap":
            guard arguments.count == 3 else {
                return .failure(BrowserAutomationError.invalidArguments(BrowserCommandRequest.boostUsage))
            }
            store.zap(arguments[2], host: host)
            return .success("\(host) zap: \(arguments[2])")
        default:
            return .failure(BrowserAutomationError.invalidArguments(BrowserCommandRequest.boostUsage))
        }
    }

    /// One line per Boost: host, on/off, sizes and the name.
    static func list(_ store: BrowserBoostStore) -> String {
        guard !store.boosts.isEmpty else { return "No Boosts." }
        return store.boosts.map { boost in
            "\(boost.host)\t\(boost.isEnabled ? "on" : "off")\tcss \(boost.css.utf8.count)B, "
                + "js \(boost.js.utf8.count)B, zaps \(boost.zaps.count)\t\(boost.name)"
        }.joined(separator: "\n")
    }

    static func show(_ boost: BrowserBoost) -> String {
        var lines = [
            "host: \(boost.host)",
            "name: \(boost.name)",
            "enabled: \(boost.isEnabled ? "yes" : "no")",
        ]
        lines += boost.zaps.map { "zap: \($0)" }
        lines.append("css:")
        lines.append(boost.css)
        lines.append("js:")
        lines.append(boost.js)
        return lines.joined(separator: "\n")
    }
}
