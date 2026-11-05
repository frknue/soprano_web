import AppKit

/// Every Agent chat as a page in a tab, like Aside's chats page:
/// `soprano-web://chats`, served by the `soprano-web` scheme handler; the
/// address's fragment names the chat shown (`soprano-web://chats#<id>`; none: a
/// new chat). A rail lists the chats (search, Pinned / Today / Yesterday /
/// Previous 7 Days / Older, the working ones marked); the rest shows the
/// chat as the Agent panel does (`transcriptHTML`, the same Markdown
/// blocks, `BrowserAgentMarkdown`) with Rename, Pin, Open in Panel and
/// Delete, and a composer that sends to it (a message from here carries no
/// tab; the chat's `browser` commands act on this page's window). The page
/// posts `{type: "agentChats", action, …}` on the `sopranoWeb` channel
/// (`Message`); the app accepts them only from this page's main frame
/// (`acceptsMessage`) and answers with the whole state
/// (`window.__sopranoChats.apply(state)`).
enum BrowserAgentChatsPage {
    static let host = "chats"
    static let url = URL(string: "\(BrowserStartPageSchemeHandler.scheme)://\(host)")!
    static let messageType = "agentChats"

    static func isChats(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == BrowserStartPageSchemeHandler.scheme && url?.host?.lowercased() == host
    }

    static func acceptsMessage(frameURL: URL?, isMainFrame: Bool) -> Bool {
        isMainFrame && isChats(frameURL)
    }

    /// The page showing chat `id`; nil: a new chat.
    static func url(for id: UUID?) -> URL {
        guard let id else { return url }
        return URL(string: "\(url.absoluteString)#\(id.uuidString)") ?? url
    }

    /// The chat a chats page's address names.
    static func chatID(in url: URL?) -> UUID? {
        guard isChats(url), let fragment = url?.fragment, !fragment.isEmpty else { return nil }
        return UUID(uuidString: fragment)
    }

    // MARK: Messages

    enum Message: Equatable {
        /// The page loaded or came back on screen, showing the chat its
        /// address names: send the state.
        case ready(UUID?)
        /// The page shows another chat (or a new one: nil).
        case select(UUID?)
        /// A message for the chat; nil: a new chat.
        case send(chat: UUID?, text: String)
        case stop(UUID)
        case rename(UUID, String)
        case pin(UUID, Bool)
        case delete(UUID)
        /// A run's answer onto the pasteboard.
        case copy(chat: UUID, run: Int)
        case openInPanel(UUID)

        /// The longest message the page may send.
        static let textLimit = 100_000

        init?(_ body: [String: Any]) {
            let id = (body["id"] as? String).flatMap(UUID.init(uuidString:))
            switch body["action"] as? String {
            case "ready":
                self = .ready(id)
            case "select":
                self = .select(id)
            case "send":
                guard let text = body["text"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      text.count <= Self.textLimit
                else { return nil }
                self = .send(chat: id, text: text)
            case "stop":
                guard let id else { return nil }
                self = .stop(id)
            case "rename":
                guard let id, let title = body["title"] as? String else { return nil }
                self = .rename(id, title)
            case "pin":
                guard let id, let pinned = body["pinned"] as? Bool else { return nil }
                self = .pin(id, pinned)
            case "delete":
                guard let id else { return nil }
                self = .delete(id)
            case "copy":
                guard let id, let run = body["run"] as? Int else { return nil }
                self = .copy(chat: id, run: run)
            case "openInPanel":
                guard let id else { return nil }
                self = .openInPanel(id)
            default:
                return nil
            }
        }
    }

    // MARK: State

    /// What `window.__sopranoChats.apply` renders: the chats by group,
    /// the chat shown (its transcript as HTML), the model chip and the
    /// theme. `available` is false in a private window (no Agent there).
    @MainActor
    static func state(
        records: [BrowserAgentChatRecord],
        working: Set<UUID>,
        selected: BrowserAgentConversation?,
        model: String,
        theme: AppTheme,
        available: Bool,
        now: Date = Date()
    ) -> [String: Any] {
        let groups = BrowserAgentChatGroups.groups(records, now: now).map { group -> [String: Any] in
            [
                "title": group.title,
                "chats": group.records.map { record -> [String: Any] in
                    [
                        "id": record.id.uuidString,
                        "title": record.title,
                        "time": listTime(record.updated, now: now),
                        "pinned": record.pinned,
                        "working": working.contains(record.id),
                    ]
                },
            ]
        }
        var state: [String: Any] = [
            "available": available,
            "model": model,
            "groups": groups,
            "theme": themeState(theme),
            "selected": NSNull(),
        ]
        if let selected, let id = selected.chatID {
            let record = records.first { $0.id == id }
            state["selected"] = [
                "id": id.uuidString,
                "title": record?.title ?? "Chat",
                "pinned": record?.pinned ?? false,
                "working": selected.transcript.isWorking,
                "busy": selected.transcript.isWorking || selected.isBusy,
                "html": transcriptHTML(selected.transcript),
            ] as [String: Any]
        }
        return state
    }

    /// The run `run`'s answer as Copy puts it on the pasteboard.
    static func answer(of run: Int, in transcript: BrowserAgentTranscript) -> String? {
        for case let .run(found) in transcript.blocks where found.id == run && !found.answer.isEmpty {
            return found.answer.map(\.text).joined(separator: "\n\n")
        }
        return nil
    }

    /// "09:13" today, "Yesterday", "Mon" this week, else "3 Nov".
    @MainActor
    static func listTime(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days <= 0 { return BrowserAgentRenderer.timeFormatter.string(from: date) }
        if days == 1 { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(days < 7 ? "EEE" : "d MMM")
        return formatter.string(from: date)
    }

    /// The Settings page's colors plus the tool marks' green and red.
    static func themeState(_ theme: AppTheme) -> [String: Any] {
        var state = BrowserSettingsWebPage.themeState(theme)
        var colors = state["colors"] as? [String: String] ?? [:]
        colors["success"] = BrowserStartPage.hex(theme.colors.success)
        colors["danger"] = BrowserStartPage.hex(theme.colors.danger)
        state["colors"] = colors
        return state
    }

    static func applyScript(_ state: [String: Any]) -> String {
        "window.__sopranoChats && window.__sopranoChats.apply(\(BrowserSettingsWebPage.literal(state)));"
    }

    // MARK: Transcript

    /// The chat as the Agent panel lays it out: a time over a message after
    /// a pause, each message in a bubble under its tab's card, each run as
    /// "Worked for 16s" (its steps inside, `<details data-run>`) over its
    /// answer and a footer with Copy and the time; "Thinking…" while
    /// nothing came back yet.
    @MainActor
    static func transcriptHTML(_ transcript: BrowserAgentTranscript) -> String {
        var html = ""
        let blocks = transcript.blocks
        var lastDate: Date?
        for (index, block) in blocks.enumerated() {
            switch block {
            case let .user(entry):
                if lastDate.map({ entry.date.timeIntervalSince($0) >= BrowserAgentPanelView.stampPause }) ?? true {
                    html += "<div class=\"stamp\">\(escape(BrowserAgentRenderer.stampFormatter.string(from: entry.date)))</div>"
                }
                html += "<div class=\"message\">"
                if let page = entry.page {
                    let title = page.title.isEmpty ? page.url : page.title
                    let host = URL(string: page.url)?.host() ?? page.url
                    html += "<a class=\"card\" href=\"\(escape(webAddress(page.url) ?? ""))\" target=\"_blank\">"
                        + "<span class=\"card-title\">\(escape(title))</span><span class=\"card-host\">\(escape(host))</span></a>"
                }
                html += "<div class=\"bubble\">\(escape(entry.text))</div></div>"
                lastDate = entry.date
            case let .note(entry):
                html += "<p class=\"note\">\(escape(entry.text))</p>"
                lastDate = entry.date
            case let .run(run):
                let live = transcript.isWorking && index == blocks.count - 1
                html += "<div class=\"run\">"
                if !run.steps.isEmpty || live {
                    let label: String
                    if live {
                        let tool = run.steps.last { $0.kind == .tool && $0.toolState == .running }
                        label = "\(tool?.detail ?? transcript.activity ?? "Working")…"
                    } else {
                        label = run.duration.map { "Worked for \(BrowserAgentRenderer.duration($0))" } ?? "Worked"
                    }
                    let labelClass = live ? "runlabel live" : "runlabel"
                    if run.steps.isEmpty {
                        html += "<div class=\"\(labelClass)\">\(escape(label))</div>"
                    } else {
                        html += "<details class=\"steps\" data-run=\"\(run.id)\"><summary class=\"\(labelClass)\">\(escape(label))</summary><div class=\"steplist\">"
                        for step in run.steps {
                            html += step.kind == .tool ? toolHTML(step) : "<div class=\"steptext\">\(markdownHTML(step.text))</div>"
                        }
                        html += "</div></details>"
                    }
                }
                for entry in run.answer {
                    html += "<div class=\"answer\">\(markdownHTML(entry.text))</div>"
                }
                if !live, !run.answer.isEmpty {
                    html += "<div class=\"footer\"><button class=\"copy\" data-copy=\"\(run.id)\" title=\"Copy\" aria-label=\"Copy\">"
                        + copyIcon + "</button><span>\(escape(BrowserAgentRenderer.timeFormatter.string(from: run.end)))</span></div>"
                }
                html += "</div>"
                lastDate = run.end
            }
        }
        // Sent, and nothing back yet.
        if transcript.isWorking, blocks.last.map({ if case .run = $0 { false } else { true } }) ?? true {
            html += "<div class=\"run\"><div class=\"runlabel live\">\(escape(transcript.activity ?? "Working"))…</div></div>"
        }
        return html
    }

    private static func toolHTML(_ entry: BrowserAgentTranscript.Entry) -> String {
        let (mark, state) = switch entry.toolState {
        case .running: ("◦", "running")
        case .done: ("✓", "done")
        case .failed: ("✕", "failed")
        }
        var html = "<div class=\"tool \(state)\"><span class=\"mark\">\(mark)</span><div class=\"toolbody\">"
        if let intent = entry.detail {
            html += "<div class=\"intent\">\(escape(intent))</div>"
        }
        html += "<code class=\"command\">\(escape(entry.text))</code>"
        if entry.toolState == .failed, let failure = entry.failure {
            html += "<pre class=\"failure\">\(escape(failure))</pre>"
        }
        return html + "</div></div>"
    }

    /// Markdown as HTML, block by block as the panel shows it; every text
    /// escaped, only web and mail links kept (opening in a new tab).
    static func markdownHTML(_ text: String) -> String {
        var html = ""
        for block in BrowserAgentMarkdown.blocks(text) {
            let gap = block.afterGap ? " class=\"gap\"" : ""
            switch block.content {
            case let .paragraph(line):
                html += "<p\(gap)>\(inlineHTML(line))</p>"
            case let .heading(level, line):
                let tag = level <= 2 ? "h3" : "h4"
                html += "<\(tag)>\(inlineHTML(line))</\(tag)>"
            case let .item(depth, number, line):
                let marker = number.map { "\(escape($0))." } ?? "•"
                let kind = number == nil ? "bullet" : "number"
                html += "<div class=\"item \(kind)\(block.afterGap ? " gap" : "")\" style=\"--depth: \(depth)\">"
                    + "<span class=\"marker\">\(marker)</span><span>\(inlineHTML(line))</span></div>"
            case let .quote(line):
                html += "<blockquote\(gap)>\(inlineHTML(line))</blockquote>"
            case let .code(lines):
                html += "<pre class=\"code\"><code>\(escape(lines.joined(separator: "\n")))</code></pre>"
            case let .tableRow(row):
                html += "<div class=\"tablerow\(block.afterGap ? " gap" : "")\">\(escape(row))</div>"
            }
        }
        return html
    }

    static func inlineHTML(_ line: String) -> String {
        BrowserAgentMarkdown.spans(line).map { span in
            var piece = escape(span.text)
            if span.code { piece = "<code>\(piece)</code>" }
            if span.bold { piece = "<strong>\(piece)</strong>" }
            if span.italic { piece = "<em>\(piece)</em>" }
            if span.strikethrough { piece = "<del>\(piece)</del>" }
            if let link = span.link {
                piece = "<a href=\"\(escape(link.absoluteString))\" target=\"_blank\" rel=\"noopener\">\(piece)</a>"
            }
            return piece
        }.joined()
    }

    /// `address` when it is a web page's (a card links only there).
    private static func webAddress(_ address: String) -> String? {
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return address
    }

    static func escape(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": output += "&amp;"
            case "<": output += "&lt;"
            case ">": output += "&gt;"
            case "\"": output += "&quot;"
            case "'": output += "&#39;"
            default: output.append(character)
            }
        }
        return output
    }

    private static let copyIcon = """
    <svg viewBox="0 0 16 16" aria-hidden="true"><path d="M5.5 5.5h7v8h-7zM3.5 10.5v-8h7"/></svg>
    """

    // MARK: Page

    static func html(state: [String: Any]) -> String {
        """
        <!doctype html>
        <html lang="en" translate="no">
        <head>
        <meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <meta http-equiv="Content-Security-Policy"
              content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; base-uri 'none'; form-action 'none';">
        <title>Chats</title>
        <style>\(css)</style>
        </head>
        <body>
        <aside>
          <div class="railhead">
            <h1>Chats</h1>
            <button class="iconbtn" data-command="new" title="New chat" aria-label="New chat"><svg viewBox="0 0 16 16" aria-hidden="true"><path d="M8.5 2.5h-5v10h10v-5M7 9l1-3 5-5 2 2-5 5z"/></svg></button>
          </div>
          <label class="search">
            <svg viewBox="0 0 16 16" aria-hidden="true"><path d="M11 11l4 4M7 12.5a5.5 5.5 0 1 1 0-11 5.5 5.5 0 0 1 0 11z"/></svg>
            <input id="search" type="search" placeholder="Search chats" autocomplete="off" spellcheck="false">
          </label>
          <nav id="list"></nav>
          <p class="none" id="nochats" hidden>No chats yet.</p>
          <p class="none" id="nomatch" hidden>No chats match.</p>
        </aside>
        <main>
          <header id="header" hidden>
            <button id="title" class="title" title="Rename"></button>
            <input id="rename" class="rename" hidden maxlength="\(BrowserAgentChatStore.longestTitle)" spellcheck="false">
            <div class="actions">
              <button class="btn" data-command="pin" id="pin">Pin</button>
              <button class="btn" data-command="openInPanel">Open in Panel</button>
              <button class="btn danger" data-command="delete" id="delete">Delete</button>
            </div>
          </header>
          <div id="scroller">
            <div id="transcript"></div>
            <div id="empty" class="empty" hidden>
              <h2>New chat</h2>
              <p>Ask the agent anything, or have it browse, click and fill in this window.</p>
              <p id="notice" class="notice" hidden></p>
            </div>
            <div id="unavailable" class="empty" hidden>
              <h2>No Agent here</h2>
              <p>Private windows keep their pages away from the agent. Open Chats in a normal window.</p>
            </div>
          </div>
          <form id="composer" class="composer" autocomplete="off">
            <textarea id="message" rows="1" placeholder="Ask the agent…" aria-label="Message"></textarea>
            <div class="composerbar">
              <span class="model" id="model"></span>
              <button class="send" id="send" type="submit" aria-label="Send"><svg viewBox="0 0 16 16" aria-hidden="true"><path d="M8 13V3M3.5 7.5L8 3l4.5 4.5"/></svg></button>
            </div>
          </form>
        </main>
        <script id="state" type="application/json">\(BrowserSettingsWebPage.literal(state))</script>
        <script>\(script)</script>
        </body>
        </html>
        """
    }

    private static let css = """
    :root {
      --bg: #1c1b19; --panel: #232220; --raised: #2a2926; --overlay: #33312d; --text: #ece7dd;
      --muted: #a29d93; --border: #3a3834; --border-strong: #4a4742; --accent: #d9a35b;
      --ink: #ece7dd; --ink-label: #2a2926; --success: #8fb573; --danger: #d9705b;
    }
    * { box-sizing: border-box; }
    html, body { height: 100%; }
    body {
      margin: 0; display: flex; overflow: hidden;
      background: var(--bg); color: var(--text);
      font: 14px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
      -webkit-font-smoothing: antialiased;
    }
    svg { width: 16px; height: 16px; flex: none; fill: none; stroke: currentColor; stroke-width: 1.3; stroke-linecap: round; stroke-linejoin: round; }
    button { font: inherit; color: inherit; }
    aside {
      width: 272px; flex: none; display: flex; flex-direction: column; padding: 22px 10px 12px;
      border-right: 1px solid var(--border); background: var(--panel);
    }
    .railhead { display: flex; align-items: center; justify-content: space-between; margin: 0 6px 14px 10px; }
    h1 { font: 400 26px/1.1 ui-serif, "New York", Georgia, serif; letter-spacing: -0.01em; margin: 0; }
    .iconbtn { width: 28px; height: 28px; display: grid; place-items: center; border: 0; border-radius: 6px; background: none; color: var(--muted); }
    .iconbtn:hover { background: var(--overlay); color: var(--text); }
    .search {
      display: flex; align-items: center; gap: 8px; height: 32px; padding: 0 10px; margin: 0 4px 10px;
      background: var(--bg); border: 1px solid var(--border); border-radius: 8px; color: var(--muted);
    }
    .search:focus-within { border-color: var(--accent); box-shadow: 0 0 0 1px var(--accent); }
    .search input { flex: 1; min-width: 0; border: 0; outline: 0; background: transparent; color: var(--text); font: inherit; font-size: 13px; }
    nav { flex: 1; overflow: auto; }
    .group { margin: 12px 10px 4px; color: var(--muted); font-size: 11px; font-weight: 600; letter-spacing: 0.02em; }
    .chat {
      display: flex; align-items: center; gap: 8px; width: 100%; height: 32px; padding: 0 10px; border: 0; border-radius: 6px;
      background: none; text-align: left; font-size: 13px;
    }
    .chat:hover { background: var(--overlay); }
    .chat.current { background: var(--raised); box-shadow: inset 0 0 0 1px var(--border); }
    .chat .name { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .chat .time { color: var(--muted); font-size: 11px; flex: none; }
    .chat .dot { width: 6px; height: 6px; border-radius: 3px; background: var(--accent); flex: none; }
    .none { color: var(--muted); margin: 16px 12px; font-size: 13px; }
    main { flex: 1; min-width: 0; display: flex; flex-direction: column; }
    header { display: flex; align-items: center; gap: 12px; padding: 14px 24px; border-bottom: 1px solid var(--border); }
    header[hidden] { display: none; }
    .title {
      flex: 1; min-width: 0; border: 0; background: none; padding: 4px 6px; border-radius: 6px; text-align: left;
      font-size: 15px; font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
    }
    .title:hover { background: var(--overlay); }
    .title[hidden] { display: none; }
    .rename { flex: 1; min-width: 0; height: 30px; padding: 0 8px; border: 1px solid var(--accent); border-radius: 6px; background: var(--panel); color: var(--text); font: inherit; font-size: 15px; font-weight: 600; outline: 0; }
    .rename[hidden] { display: none; }
    .actions { display: flex; gap: 8px; flex: none; }
    .btn {
      height: 28px; padding: 0 12px; border: 1px solid var(--border-strong); border-radius: 6px;
      background: var(--panel); font-size: 12.5px; white-space: nowrap;
    }
    .btn:hover { background: var(--overlay); }
    .btn.on { background: var(--raised); box-shadow: inset 0 0 0 1px var(--ink); }
    .btn.danger.armed { background: var(--danger); border-color: var(--danger); color: var(--ink-label); }
    #scroller { flex: 1; overflow: auto; }
    #transcript { max-width: 760px; margin: 0 auto; padding: 18px 28px 28px; }
    .empty { max-width: 760px; margin: 18vh auto 0; padding: 0 28px; text-align: center; color: var(--muted); }
    .empty[hidden] { display: none; }
    .empty h2 { font: 400 24px/1.2 ui-serif, "New York", Georgia, serif; color: var(--text); margin: 0 0 8px; }
    .notice { color: var(--danger); margin-top: 14px; }
    .notice[hidden] { display: none; }
    .stamp { text-align: center; color: var(--muted); font-size: 11.5px; margin: 20px 0 12px; }
    .message { display: flex; flex-direction: column; align-items: flex-end; gap: 8px; margin-top: 20px; }
    .card {
      display: flex; flex-direction: column; max-width: 70%; padding: 8px 12px; border: 1px solid var(--border);
      border-radius: 10px; background: var(--panel); color: inherit; text-decoration: none;
    }
    .card:hover { background: var(--overlay); }
    .card-title { font-size: 13px; font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .card-host { font-size: 11.5px; color: var(--muted); }
    .bubble { max-width: 75%; padding: 9px 14px; border-radius: 14px; background: var(--raised); white-space: pre-wrap; overflow-wrap: anywhere; }
    .note { color: var(--muted); font-style: italic; margin: 14px 0 0; }
    .run { margin-top: 20px; }
    .runlabel { color: var(--muted); font-size: 12.5px; }
    .runlabel.live { animation: pulse 1.4s ease-in-out infinite; }
    @keyframes pulse { 50% { opacity: 0.45; } }
    details.steps summary { cursor: default; list-style: none; display: inline-flex; align-items: center; gap: 4px; }
    details.steps summary::-webkit-details-marker { display: none; }
    details.steps summary::after { content: "›"; font-size: 14px; transition: transform 120ms ease; }
    details.steps[open] summary::after { transform: rotate(90deg); }
    .steplist { margin: 8px 0 14px; padding-left: 2px; display: flex; flex-direction: column; gap: 8px; }
    .tool { display: flex; gap: 6px; font-size: 12.5px; color: var(--muted); }
    .tool .mark { width: 14px; flex: none; }
    .tool.done .mark { color: var(--success); }
    .tool.failed .mark { color: var(--danger); }
    .toolbody { min-width: 0; }
    .command { font: 11.5px ui-monospace, "SF Mono", Menlo, monospace; overflow-wrap: anywhere; }
    .failure { margin: 2px 0 0; color: var(--danger); font: 11.5px ui-monospace, "SF Mono", Menlo, monospace; white-space: pre-wrap; }
    .steptext { color: var(--muted); font-size: 13px; }
    .answer { margin-top: 10px; overflow-wrap: anywhere; }
    .answer > :first-child, .steptext > :first-child { margin-top: 0; }
    p { margin: 10px 0 0; }
    p + p:not(.gap) { margin-top: 2px; }
    h3 { font-size: 16px; font-weight: 600; margin: 16px 0 0; }
    h4 { font-size: 14px; font-weight: 600; margin: 16px 0 0; }
    .item { display: flex; gap: 6px; margin: 5px 0 0 calc(var(--depth) * 18px); }
    .item:not(.item + .item), .item.gap { margin-top: 10px; }
    .item .marker { color: var(--muted); min-width: 12px; flex: none; }
    .item.number .marker { min-width: 18px; }
    blockquote { margin: 10px 0 0; padding-left: 12px; color: var(--muted); font-style: italic; border-left: 2px solid var(--border-strong); }
    pre.code { margin: 10px 0 0; padding: 10px 12px; border: 1px solid var(--border); border-radius: 10px; background: var(--raised); overflow: auto; }
    pre.code code { font: 12px/1.5 ui-monospace, "SF Mono", Menlo, monospace; }
    .tablerow { font: 12px ui-monospace, "SF Mono", Menlo, monospace; white-space: pre-wrap; }
    .tablerow:not(.tablerow + .tablerow), .tablerow.gap { margin-top: 10px; }
    code { font: 0.92em ui-monospace, "SF Mono", Menlo, monospace; }
    a { color: inherit; }
    .footer { display: flex; align-items: center; gap: 14px; margin-top: 12px; color: var(--muted); font-size: 11.5px; }
    .copy { border: 0; background: none; padding: 2px; border-radius: 4px; color: var(--muted); display: grid; place-items: center; }
    .copy:hover { color: var(--text); background: var(--overlay); }
    .composer {
      max-width: 760px; width: calc(100% - 56px); margin: 0 auto 18px; padding: 12px 12px 8px 14px;
      border: 1px solid var(--border-strong); border-radius: 14px; background: var(--panel);
    }
    .composer:focus-within { border-color: var(--accent); }
    .composer[hidden] { display: none; }
    textarea {
      width: 100%; max-height: 200px; border: 0; outline: 0; resize: none; background: transparent; color: var(--text);
      font: inherit; line-height: 1.45;
    }
    textarea::placeholder { color: var(--muted); }
    .composerbar { display: flex; align-items: center; justify-content: flex-end; gap: 10px; margin-top: 6px; }
    .model { color: var(--muted); font-size: 12px; }
    .send {
      width: 28px; height: 28px; border-radius: 14px; border: 0; display: grid; place-items: center;
      background: var(--ink); color: var(--ink-label);
    }
    .send:disabled { opacity: 0.35; }
    .send.stop svg { stroke-width: 0; fill: currentColor; }
    button:focus-visible, .chat:focus-visible { outline: 0; box-shadow: 0 0 0 2px var(--accent); }
    @media (max-width: 760px) { aside { display: none; } }
    """

    private static let script = """
    (() => {
      "use strict";
      const post = (message) => {
        const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.sopranoWeb;
        if (handler) handler.postMessage(Object.assign({ type: "agentChats" }, message));
      };
      const byId = (id) => document.getElementById(id);
      let state = JSON.parse(byId("state").textContent);
      const hashID = () => location.hash.length > 1 ? decodeURIComponent(location.hash.slice(1)) : null;
      // Runs whose steps are open, per chat; kept across updates.
      const openRuns = new Map();
      let shownID = undefined;
      let confirmTimer = null;

      const sendIcon = '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M8 13V3M3.5 7.5L8 3l4.5 4.5"/></svg>';
      const stopIcon = '<svg viewBox="0 0 16 16" aria-hidden="true"><rect x="4.5" y="4.5" width="7" height="7" rx="1"/></svg>';

      function renderList() {
        const list = byId("list");
        const words = byId("search").value.toLocaleLowerCase().split(/\\s+/).filter(Boolean);
        const current = state.selected ? state.selected.id : null;
        let total = 0, shown = 0;
        const nodes = [];
        for (const group of state.groups) {
          const chats = group.chats.filter((chat) => {
            total += 1;
            const title = chat.title.toLocaleLowerCase();
            return words.every((word) => title.includes(word));
          });
          if (!chats.length) continue;
          const heading = document.createElement("div");
          heading.className = "group";
          heading.textContent = group.title;
          nodes.push(heading);
          for (const chat of chats) {
            shown += 1;
            const row = document.createElement("button");
            row.className = "chat" + (chat.id === current ? " current" : "");
            row.dataset.chat = chat.id;
            row.title = chat.title;
            if (chat.working) {
              const dot = document.createElement("span");
              dot.className = "dot";
              dot.title = "Working";
              row.append(dot);
            }
            const name = document.createElement("span");
            name.className = "name";
            name.textContent = chat.title;
            const time = document.createElement("span");
            time.className = "time";
            time.textContent = chat.time;
            row.append(name, time);
            nodes.push(row);
          }
        }
        list.replaceChildren(...nodes);
        byId("nochats").hidden = total > 0;
        byId("nomatch").hidden = total === 0 || shown > 0;
      }

      function renderChat() {
        const selected = state.selected;
        const header = byId("header");
        const transcript = byId("transcript");
        const scroller = byId("scroller");
        const atBottom = scroller.scrollTop + scroller.clientHeight >= scroller.scrollHeight - 24;
        const changedChat = shownID !== (selected ? selected.id : null);
        byId("unavailable").hidden = state.available;
        byId("composer").hidden = !state.available;
        byId("empty").hidden = !state.available || Boolean(selected);
        header.hidden = !selected;
        if (selected) {
          if (byId("rename").hidden) byId("title").textContent = selected.title;
          const pin = byId("pin");
          pin.textContent = selected.pinned ? "Unpin" : "Pin";
          pin.classList.toggle("on", selected.pinned);
          transcript.innerHTML = selected.html;
          const open = openRuns.get(selected.id) || new Set();
          for (const details of transcript.querySelectorAll("details[data-run]")) {
            details.open = open.has(details.dataset.run);
            details.addEventListener("toggle", () => {
              const runs = openRuns.get(selected.id) || new Set();
              if (details.open) runs.add(details.dataset.run); else runs.delete(details.dataset.run);
              openRuns.set(selected.id, runs);
            });
          }
          document.title = selected.title;
        } else {
          transcript.replaceChildren();
          document.title = "Chats";
        }
        if (changedChat) disarmDelete();
        shownID = selected ? selected.id : null;
        if (changedChat || atBottom || (selected && selected.working)) scroller.scrollTop = scroller.scrollHeight;
        byId("model").textContent = state.model;
        byId("message").placeholder = selected ? "Reply…" : "Ask the agent…";
        updateSend();
      }

      function updateSend() {
        const typed = byId("message").value.trim().length > 0;
        const busy = Boolean(state.selected && state.selected.busy);
        const send = byId("send");
        const stops = busy && !typed;
        send.classList.toggle("stop", stops);
        send.innerHTML = stops ? stopIcon : sendIcon;
        send.setAttribute("aria-label", stops ? "Stop" : "Send");
        send.disabled = !typed && !stops;
      }

      const apply = (next) => {
        state = next;
        const root = document.documentElement;
        for (const [name, value] of Object.entries(next.theme.colors)) root.style.setProperty("--" + name, value);
        root.style.colorScheme = next.theme.scheme;
        const id = next.selected ? next.selected.id : null;
        // A new chat got its id with its first message: the address names it.
        if (id && id !== hashID()) history.replaceState(null, "", "#" + id);
        if (!id && hashID() && !next.groups.some((group) => group.chats.some((chat) => chat.id === hashID()))) {
          history.replaceState(null, "", location.pathname);
        }
        renderList();
        renderChat();
        // A first message that never reached omp: why, and the text back;
        // the notice stays until the user sends or picks a chat.
        if (next.notice) showNotice(next.notice);
        const message = byId("message");
        if (next.draft && !message.value) {
          message.value = next.draft;
          message.dispatchEvent(new Event("input"));
        }
      };
      window.__sopranoChats = { apply };

      function showNotice(text) {
        const notice = byId("notice");
        notice.textContent = text;
        notice.hidden = !text;
      }
      function select(id) {
        showNotice("");
        if (id) location.hash = id;
        else if (location.hash) location.hash = "";
        else post({ action: "select", id: null });
        byId("message").focus();
      }
      window.addEventListener("hashchange", () => post({ action: "select", id: hashID() }));

      function disarmDelete() {
        clearTimeout(confirmTimer);
        const button = byId("delete");
        button.classList.remove("armed");
        button.textContent = "Delete";
      }

      document.addEventListener("click", (event) => {
        const target = event.target.closest("button");
        if (!target) return;
        const selected = state.selected;
        if (target.dataset.chat) {
          select(target.dataset.chat);
        } else if (target.dataset.copy && selected) {
          post({ action: "copy", id: selected.id, run: Number(target.dataset.copy) });
          target.classList.add("copied");
          target.title = "Copied";
          setTimeout(() => { target.classList.remove("copied"); target.title = "Copy"; }, 1500);
        } else if (target.dataset.command === "new") {
          select(null);
        } else if (target.id === "title" && selected) {
          const field = byId("rename");
          field.value = selected.title;
          target.hidden = true;
          field.hidden = false;
          field.focus();
          field.select();
        } else if (target.dataset.command === "pin" && selected) {
          post({ action: "pin", id: selected.id, pinned: !selected.pinned });
        } else if (target.dataset.command === "openInPanel" && selected) {
          post({ action: "openInPanel", id: selected.id });
        } else if (target.dataset.command === "delete" && selected) {
          if (target.classList.contains("armed")) {
            disarmDelete();
            post({ action: "delete", id: selected.id });
          } else {
            target.classList.add("armed");
            target.textContent = "Delete Chat?";
            confirmTimer = setTimeout(disarmDelete, 4000);
          }
        }
      });

      const rename = byId("rename");
      const finishRename = (commit) => {
        if (rename.hidden) return;
        const selected = state.selected;
        rename.hidden = true;
        byId("title").hidden = false;
        if (commit && selected && rename.value.trim() && rename.value.trim() !== selected.title) {
          byId("title").textContent = rename.value.trim();
          post({ action: "rename", id: selected.id, title: rename.value });
        }
      };
      rename.addEventListener("keydown", (event) => {
        if (event.key === "Enter") { event.preventDefault(); finishRename(true); }
        if (event.key === "Escape") { event.preventDefault(); finishRename(false); }
      });
      rename.addEventListener("blur", () => finishRename(true));

      const message = byId("message");
      const grow = () => {
        message.style.height = "auto";
        message.style.height = Math.min(message.scrollHeight, 200) + "px";
      };
      message.addEventListener("input", () => { grow(); updateSend(); });
      const submit = () => {
        const text = message.value;
        const selected = state.selected;
        if (!text.trim()) {
          if (selected && selected.busy) post({ action: "stop", id: selected.id });
          return;
        }
        showNotice("");
        post({ action: "send", id: selected ? selected.id : null, text });
        message.value = "";
        grow();
        updateSend();
      };
      message.addEventListener("keydown", (event) => {
        if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
          event.preventDefault();
          submit();
        }
      });
      byId("composer").addEventListener("submit", (event) => { event.preventDefault(); submit(); });

      const search = byId("search");
      search.addEventListener("input", renderList);
      search.addEventListener("keydown", (event) => {
        if (event.key === "Escape" && search.value) { search.value = ""; renderList(); }
      });

      apply(state);
      post({ action: "ready", id: hashID() });
      document.addEventListener("visibilitychange", () => { if (!document.hidden) post({ action: "ready", id: hashID() }); });
      message.focus();
    })();
    """
}
