import AppKit

/// Search engine setup for `SopranoWeb snapshot`, applied before the first
/// window opens:
///
/// - `--search-engine "<name>|<keyword>|<URL with %s>"` (repeatable): a
///   custom engine, saved the way Settings ▸ Search engine ▸ Manage… saves
///   one (`search-engine: refused …` with the reason when it can't be).
/// - `--search-engine-keyword <name|id>=<keyword>` (repeatable): a built-in
///   engine's keyword (built-ins have none by default).
/// - `--default-search-engine <keyword|name|id>`: Settings ▸ Search engine.
/// - `--search-engines-sheet`: capture Settings ▸ Search engine ▸ Manage…
///   instead of a window.
///
/// With any of them the run prints `search-engines:`, every engine as
/// `name [keyword] template`, `*` before the default.
struct SnapshotSearchEngineOptions {
    var engines: [BrowserSearchEngine] = []
    /// Built-in name or id, keyword.
    var builtInKeywords: [(engine: String, keyword: String)] = []
    var defaultEngine: String?
    var showsSheet = false

    static let usage = """
                               [--search-engine "<name>|<keyword>|<url with %s>"]...
                               [--search-engine-keyword <name|id>=<keyword>]...
                               [--default-search-engine <keyword|name>] [--search-engines-sheet]
    """

    /// True when `option` is one of these flags (its value read).
    static func parse(
        _ option: String,
        value: () throws -> String,
        into options: inout SnapshotSearchEngineOptions
    ) throws -> Bool {
        switch option {
        case "--search-engine":
            let raw = try value()
            let parts = raw.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else {
                throw SnapshotCommand.OptionError.unknownOption("--search-engine \(raw)")
            }
            options.engines.append(BrowserSearchEngine(
                id: .makeCustom(),
                name: parts[0].trimmingCharacters(in: .whitespaces),
                keyword: BrowserSearchEngine.normalizedKeyword(parts[1]),
                template: parts[2].trimmingCharacters(in: .whitespaces)
            ))
        case "--search-engine-keyword":
            let raw = try value()
            let parts = raw.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else {
                throw SnapshotCommand.OptionError.unknownOption("--search-engine-keyword \(raw)")
            }
            options.builtInKeywords.append((parts[0], parts[1]))
        case "--default-search-engine":
            options.defaultEngine = try value()
        case "--search-engines-sheet":
            options.showsSheet = true
        default:
            return false
        }
        return true
    }

    private var isUsed: Bool {
        !engines.isEmpty || !builtInKeywords.isEmpty || defaultEngine != nil || showsSheet
    }

    /// Settings the flags change, before any window reads them.
    @MainActor
    func apply(to settings: BrowserSettingsStore) {
        guard isUsed else { return }
        for (name, keyword) in builtInKeywords {
            guard var engine = BrowserSearchEngine.builtIn.first(where: {
                $0.id.rawValue == name || $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) else {
                print("search-engine: no built-in engine \(name)")
                continue
            }
            engine.keyword = keyword
            var saved = false
            settings.update { saved = $0.searchEngines.save(engine) }
            if !saved {
                print("search-engine: refused keyword \(keyword) for \(engine.name)")
            }
        }
        for engine in engines {
            let problem = settings.settings.searchEngines.problem(
                name: engine.name,
                keyword: engine.keyword,
                template: engine.template
            )
            if let problem {
                print("search-engine: refused \(engine.name): \(problem.message)")
            } else {
                settings.update { _ = $0.searchEngines.save(engine) }
            }
        }
        if let defaultEngine {
            let engines = settings.settings.searchEngines
            let match = engines.engine(forKeyword: defaultEngine)
                ?? engines.all.first { $0.name.caseInsensitiveCompare(defaultEngine) == .orderedSame }
                ?? engines.engine(id: BrowserSearchEngineID(rawValue: defaultEngine))
            if let match {
                settings.update { $0.searchEngines.setDefault(match.id) }
            } else {
                print("search-engine: no engine \(defaultEngine)")
            }
        }
        let engines = settings.settings.searchEngines
        let lines = engines.all.map { engine in
            "\(engine.id == engines.defaultID ? "*" : "")\(engine.name) [\(engine.keyword)] \(engine.template)"
        }
        print("search-engines: \(lines.joined(separator: " | "))")
    }

    /// Settings ▸ Search engine ▸ Manage…, built offscreen for the capture.
    @MainActor
    func makeSheet(settingsStore: BrowserSettingsStore, theme: AppTheme) -> BrowserSearchEnginesSheet? {
        showsSheet ? BrowserSearchEnginesSheet(settingsStore: settingsStore, theme: theme) : nil
    }
}
