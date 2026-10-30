import Foundation

/// `browser live-folders` and `browser [--window n] live-folder
/// add|refresh`.
@MainActor
enum BrowserLiveFolderCommands {
    /// Every live folder of every Space: Space, name, source and state,
    /// then its pull requests (`#n title <url>`) indented.
    static func list(_ manager: BrowserWindowManager) -> String {
        var lines: [String] = []
        for space in manager.spaces.spaces {
            for (id, source) in space.pinned.liveFolders() {
                let name = space.pinned.folder(id: id)?.displayName ?? ""
                let state = manager.liveFolders.state(of: id)
                lines.append("\(space.displayName)\t\(name)\t\(source.summary)\t\(stateText(state))")
                for item in state?.items ?? [] {
                    lines.append("  #\(item.number) \(item.title) <\(item.url)>\(item.isDraft ? " (draft)" : "")")
                }
            }
        }
        return lines.isEmpty ? "No live folders." : lines.joined(separator: "\n")
    }

    static func stateText(_ state: BrowserLiveFolderState?) -> String {
        guard let state else { return "unknown" }
        if let error = state.error { return "error: \(error.message)" }
        if state.isLoading, state.fetchedAt == nil { return "loading" }
        guard state.fetchedAt != nil else { return "not fetched" }
        return "\(state.items.count) pull request\(state.items.count == 1 ? "" : "s")\(state.isLoading ? ", refreshing" : "")"
    }

    /// `add <owner/repo|link|query>` in `target`'s Space (fetched before
    /// the answer), `refresh` (every folder, waited for).
    static func perform(
        _ arguments: [String],
        in target: BrowserWindowController,
        manager: BrowserWindowManager,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let usage = BrowserAutomationError.invalidArguments(BrowserCommandRequest.liveFolderUsage)
        switch arguments.first {
        case "add":
            guard let source = BrowserLiveFolderSource.parse(arguments.dropFirst().joined(separator: " ")) else {
                completion(.failure(usage))
                return
            }
            guard let spaceID = target.pinSpaceID,
                  let folder = manager.spaces.addLiveFolder(name: source.defaultName, source: source, inSpace: spaceID)
            else {
                completion(.failure(BrowserAutomationError.unavailable("The window has no Space to add a live folder to.")))
                return
            }
            manager.pinUIState.setExpanded(true, folder: folder.id)
            manager.liveFolders.refresh(folder.id)
            target.updateRail()
            Task { @MainActor in
                await manager.liveFolders.waitForFetches()
                completion(.success("\(folder.displayName)\t\(stateText(manager.liveFolders.state(of: folder.id)))"))
            }
        case "refresh":
            guard arguments.count == 1 else {
                completion(.failure(usage))
                return
            }
            manager.liveFolders.refreshAll()
            Task { @MainActor in
                await manager.liveFolders.waitForFetches()
                completion(.success(list(manager)))
            }
        default:
            completion(.failure(usage))
        }
    }
}
