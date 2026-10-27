@testable import SopranoWeb
import AppKit
import Testing

/// History's bulk import: duplicates (same address and time) are skipped,
/// so an import runs twice without adding anything; batches can be
/// cancelled; frecency is refreshed.
struct BrowserHistoryImportTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func visits(_ count: Int) -> [BrowserHistoryImport] {
        (0..<count).map { index in
            BrowserHistoryImport(
                url: "https://page\(index % 4).example/",
                title: "Page \(index % 4)",
                visitedAt: start.addingTimeInterval(Double(index) * 90),
                kind: index == 0 ? .typed : .link
            )
        }
    }

    @Test func importingTheSameVisitsTwiceAddsThemOnce() throws {
        let database = try BrowserHistoryDatabase(path: ":memory:")
        let first = try database.importNewVisits(visits(10))
        #expect(first.added == 10)
        #expect(first.skipped == 0)
        let second = try database.importNewVisits(visits(12))
        #expect(second.added == 2)
        #expect(second.skipped == 10)
        #expect(try database.visitCount(matching: "") == 12)
        #expect(try database.pageCount() == 4)
        // Repeats inside one batch count once too.
        let repeated = try database.importNewVisits(visits(1) + visits(1))
        #expect(repeated.added == 0)
        #expect(repeated.skipped == 2)
    }

    private struct ReadFailure: Error {}

    @Test func aReadErrorKeepsWhatWasAddedWithTheErrorAndRefreshesFrecency() throws {
        let database = try BrowserHistoryDatabase(path: ":memory:")
        let all = visits(20)
        let count = try BrowserHistoryStore.importBatches(
            into: database,
            read: { body in
                try body(Array(all.prefix(10)))
                throw ReadFailure()
            },
            cancellation: BrowserImportCancellation(),
            now: start.addingTimeInterval(3_600)
        ) { _ in }
        #expect(count.added == 10)
        #expect(count.cancelled == false)
        #expect(count.failure != nil)
        #expect(try database.recentPages(limit: 4).allSatisfy { $0.frecency > 0 })
    }

    @Test func batchesStopWhenCancelledAndKeepWhatWasAdded() throws {
        let database = try BrowserHistoryDatabase(path: ":memory:")
        let cancellation = BrowserImportCancellation()
        let all = visits(30)
        var handled: [Int] = []
        let count = try BrowserHistoryStore.importBatches(
            into: database,
            read: { body in
                for start in stride(from: 0, to: all.count, by: 10) {
                    try body(Array(all[start..<start + 10]))
                    if start == 10 { cancellation.cancel() }
                }
            },
            cancellation: cancellation,
            now: start.addingTimeInterval(3_600)
        ) { handled.append($0) }
        #expect(count == BrowserHistoryImportCount(added: 20, skipped: 0, cancelled: true))
        #expect(handled == [10, 20])
        #expect(try database.visitCount(matching: "") == 20)
        // Frecency was refreshed for what was added.
        #expect(try database.recentPages(limit: 4).allSatisfy { $0.frecency > 0 })
    }

    @MainActor
    @Test func theStoreImportsOffTheMainThreadAndNotifies() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SopranoWebHistoryImport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = BrowserHistoryStore(directory: folder)
        var notified = 0
        let observation = store.changes.observe { notified += 1 }
        let all = visits(7)
        let read: @Sendable (_ body: ([BrowserHistoryImport]) throws -> Void) throws -> Void = { body in
            try body(Array(all.prefix(4)))
            try body(Array(all.suffix(3)))
        }
        func run() async -> BrowserHistoryImportCount? {
            await withCheckedContinuation { continuation in
                store.importInBackground(
                    batchesFrom: read,
                    cancellation: BrowserImportCancellation(),
                    progress: { _ in },
                    completion: { continuation.resume(returning: try? $0.get()) }
                )
            }
        }
        #expect(await run() == BrowserHistoryImportCount(added: 7, skipped: 0))
        #expect(await run() == BrowserHistoryImportCount(added: 0, skipped: 7))
        #expect(store.visitCount() == 7)
        #expect(notified == 1)
        observation.cancel()
    }
}
