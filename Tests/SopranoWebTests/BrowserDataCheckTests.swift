@testable import SopranoWeb
import AppKit
import Testing

/// `data-check`, what the install guard compares between the installed
/// build and a new one: it must count what the stores hold, report files a
/// store moved aside, and never touch anything outside the given paths.
@MainActor
struct BrowserDataCheckTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-web-data-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func countsWhatTheStoresHold() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let settingsURL = root.appendingPathComponent("settings.json")
        BrowserSettingsStore(url: settingsURL).update { $0.homepage = "https://example.com" }

        let profiles = BrowserProfileStore(url: support.appendingPathComponent("profiles.json"))
        let spaces = BrowserSpaceStore(url: support.appendingPathComponent("spaces.json"), profiles: profiles.profiles)
        let space = try #require(spaces.defaultSpace)
        _ = spaces.addPin(url: "https://swift.org/", title: "Swift", inSpace: space.id)
        _ = spaces.addFavorite(url: "https://webkit.org/", title: "WebKit", ofProfile: space.profileID)
        BrowserSessionStore(url: support.appendingPathComponent("session.json")).save(BrowserSession(
            windows: [BrowserWindowState(tabs: [
                BrowserTabState(url: "https://a.example/", title: "A"),
                BrowserTabState(url: "https://b.example/", title: "B"),
            ])],
            savedAt: Date()
        ))
        _ = BrowserArchiveStore(url: support.appendingPathComponent("archive.json"))
            .archive(url: "https://old.example/", title: "Old", spaceID: space.id, profileID: space.profileID, at: Date(), reason: .manual)
        BrowserHistoryStore(directory: support).record(url: "https://a.example/", title: "A", at: Date(), kind: .link)

        let summary = BrowserDataCheck.summary(support: support, settingsURL: settingsURL)
        let settings = try #require(summary["settings"] as? [String: Any])
        #expect(settings["readable"] as? Bool == true)
        #expect((settings["values"] as? [String: Any])?["homepage"] as? String == "https://example.com")
        let checkedSpaces = try #require(summary["spaces"] as? [[String: Any]])
        #expect(checkedSpaces.first?["pins"] as? [String] == ["https://swift.org/"])
        #expect(checkedSpaces.first?["favorites"] as? [String] == ["https://webkit.org/"])
        let session = try #require(summary["session"] as? [String: Any])
        #expect(session["tabs"] as? [[String]] == [["https://a.example/", "https://b.example/"]])
        #expect(summary["archive"] as? Int == 1)
        let history = try #require(summary["history"] as? [String: [String: Any]])
        #expect(history[BrowserProfile.defaultID.uuidString]?["visits"] as? Int == 1)
        #expect(summary["movedAside"] as? [String] == [])
    }

    /// A saved chat counts by what its session file shows, not only by its
    /// row in the list: a reader that loses the conversation fails the
    /// install guard (`data-guard.py` counts the same from the raw file).
    @Test func countsWhatSavedChatsHold() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("support", isDirectory: true)
        let chats = BrowserAgentChatStore(supportDirectory: support)
        let chat = chats.create(firstMessage: "First")
        chats.create(firstMessage: "Never answered")
        let directory = chats.directory(for: chat.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"title","v":1,"title":""}"#,
            #"{"type":"session","version":3,"id":"s"}"#,
            #"{"type":"message","id":"u1","parentId":null,"message":{"role":"user","content":"First","timestamp":1}}"#,
            #"{"type":"message","id":"e1","parentId":"u1","message":{"role":"assistant","content":[],"stopReason":"error","retryRecovery":{},"timestamp":2}}"#,
            #"{"type":"message","id":"a1","parentId":"e1","message":{"role":"assistant","content":[{"type":"text","text":"One."}],"stopReason":"stop","timestamp":3}}"#,
            #"{"type":"message","id":"u2","parentId":"a1","message":{"role":"user","content":"Abandoned","timestamp":4}}"#,
            #"{"type":"message","id":"u3","parentId":"a1","message":{"role":"user","content":"Second","timestamp":5}}"#,
            #"{"type":"message","id":"x1","parentId":"u3","message":{"role":"user","content":"Advice","attribution":"agent","timestamp":6}}"#,
            #"{"type":"message","id":"a2","parentId":"x1","message":{"role":"assistant","content":[{"type":"text","text":"Two."}],"stopReason":"stop","timestamp":7}}"#,
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: directory.appendingPathComponent("2026-11-05T08-00-00-000Z_s.jsonl"))

        let summary = BrowserDataCheck.summary(support: support, settingsURL: root.appendingPathComponent("settings.json"))
        #expect(summary["agentChats"] as? Int == 2)
        #expect(summary["agentChatMessages"] as? Int == 2)
        #expect(summary["agentChatAnswers"] as? Int == 2)
    }

    @Test func reportsAFileAStoreMovedAside() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: support.appendingPathComponent("spaces.json"))
        try Data("{\"version\": ".utf8).write(to: root.appendingPathComponent("settings.json"))

        let summary = BrowserDataCheck.summary(support: support, settingsURL: root.appendingPathComponent("settings.json"))
        #expect(summary["movedAside"] as? [String] == ["/spaces.json.corrupt"])
        #expect((summary["settings"] as? [String: Any])?["readable"] as? Bool == false)
    }
}
