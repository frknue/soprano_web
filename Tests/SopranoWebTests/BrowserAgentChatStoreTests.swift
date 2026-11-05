@testable import SopranoWeb
import AppKit
import Testing

@MainActor
struct BrowserAgentChatStoreTests {
    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SopranoWebChats-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func chatsListNewestChangeFirstAndSurviveARelaunch() throws {
        let support = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: support) }
        let store = BrowserAgentChatStore(supportDirectory: support)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let first = store.create(firstMessage: "\n  What is this page about?  \nMore", at: start)
        let second = store.create(firstMessage: "Fill the form", at: start + 10)
        #expect(first.title == "What is this page about?")
        #expect(store.records.map(\.id) == [second.id, first.id])
        store.touch(first.id, at: start + 20)
        #expect(store.records.map(\.id) == [first.id, second.id])
        // An older time never moves a chat back.
        store.touch(first.id, at: start)
        #expect(store.record(first.id)?.updated == start + 20)
        #expect(store.rename(second.id, to: "  Form  "))
        #expect(!store.rename(second.id, to: "   "))
        #expect(!store.rename(UUID(), to: "Nothing"))
        store.setPinned(second.id, true)

        let relaunched = BrowserAgentChatStore(supportDirectory: support)
        #expect(relaunched.records == store.records)
        #expect(relaunched.record(second.id)?.title == "Form")
        #expect(relaunched.record(second.id)?.pinned == true)
    }

    @Test func deletingAChatDiscardsItsFolder() throws {
        let support = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: support) }
        let store = BrowserAgentChatStore(supportDirectory: support)
        var discarded: [URL] = []
        store.discard = { discarded.append($0) }
        let chat = store.create(firstMessage: "Hi")
        let folder = store.directory(for: chat.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("2026-11-05T08-00-00-000Z_s.jsonl"))
        #expect(store.sessionFile(for: chat.id)?.lastPathComponent == "2026-11-05T08-00-00-000Z_s.jsonl")
        #expect(store.delete(chat.id))
        #expect(store.records.isEmpty)
        #expect(discarded == [folder])
        #expect(!store.delete(chat.id))
    }

    @Test func aDamagedListKeepsWhatItCanAndTheUnreadableFileStays() throws {
        let support = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: support) }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let url = support.appendingPathComponent("agent-chats.json")
        let id = UUID()
        try Data("""
        {"version": 1, "entries": [
          {"id": "\(id.uuidString)", "title": 7, "updated": "2026-11-05T08:00:00Z"},
          {"title": "no id"},
          {"id": "\(id.uuidString)", "title": "duplicate"}
        ]}
        """.utf8).write(to: url)
        let store = BrowserAgentChatStore(supportDirectory: support)
        #expect(store.records.count == 1)
        #expect(store.record(id)?.title == "")
        #expect(store.record(id)?.created == store.record(id)?.updated)

        try Data("not json".utf8).write(to: url)
        let damaged = BrowserAgentChatStore(supportDirectory: support)
        #expect(damaged.records.isEmpty)
        #expect(try Data(contentsOf: damaged.corruptURL) == Data("not json".utf8))
    }

    @Test func titlesAreTheFirstLineCut() {
        #expect(BrowserAgentChatStore.title(for: "   \n") == "New chat")
        let long = String(repeating: "a", count: 200)
        let title = BrowserAgentChatStore.title(for: long)
        #expect(title.count == BrowserAgentChatStore.longestTitle)
        #expect(title.hasSuffix("…"))
    }

    @Test func groupsArePinnedThenByDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 9)))
        func record(_ title: String, daysAgo: Int, hour: Int = 8, pinned: Bool = false) throws -> BrowserAgentChatRecord {
            var components = calendar.dateComponents([.year, .month, .day], from: now)
            components.day = (components.day ?? 0) - daysAgo
            components.hour = hour
            let date = try #require(calendar.date(from: components))
            return BrowserAgentChatRecord(title: title, created: date, pinned: pinned)
        }
        let records = [
            try record("this morning", daysAgo: 0, hour: 0),
            try record("pinned old", daysAgo: 40, pinned: true),
            try record("late yesterday", daysAgo: 1, hour: 23),
            try record("a week ago", daysAgo: 7),
            try record("eight days ago", daysAgo: 8),
        ]
        let groups = BrowserAgentChatGroups.groups(records, now: now, calendar: calendar)
        #expect(groups.map(\.title) == ["Pinned", "Today", "Yesterday", "Previous 7 Days", "Older"])
        #expect(groups.map { $0.records.map(\.title) } == [
            ["pinned old"], ["this morning"], ["late yesterday"], ["a week ago"], ["eight days ago"],
        ])
        #expect(BrowserAgentChatGroups.groups([], now: now, calendar: calendar).isEmpty)
    }
}
