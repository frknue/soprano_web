@testable import SopranoWeb
import AppKit
import Testing

@MainActor
struct BrowserDownloadStoreTests {
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SopranoWebTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func downloadStillRunningAtQuitOrCrashReloadsAsInterrupted() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("downloads.json")
        let store = BrowserDownloadStore(url: url)
        let finished = store.begin(url: "https://example.com/file.zip", filename: "file.zip")
        store.finish(id: finished.id, path: "/tmp/file.zip")
        let running = store.begin(url: "https://example.com/other.zip", filename: "other.zip", path: "/tmp/other.zip")

        let reloaded = BrowserDownloadStore(url: url)
        #expect(reloaded.records.count == 2)
        let interrupted = reloaded.records.first { $0.id == running.id }
        #expect(interrupted?.state == .interrupted)
        #expect(interrupted?.path == "/tmp/other.zip")
        #expect(interrupted?.canRetry == true)
        #expect(interrupted?.canResume == false)
        #expect(reloaded.records.first { $0.id == finished.id }?.state == .completed)
    }

    @Test func quitKeepsResumeDataAcrossRelaunch() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("downloads.json")
        let store = BrowserDownloadStore(url: url)
        let record = store.begin(url: "https://example.com/big.iso", filename: "big.iso")
        store.updateProgress(id: record.id, fraction: 0.4)
        let data = Data("resume-bytes".utf8)
        store.interrupt(id: record.id, resumeData: data)

        let reloaded = BrowserDownloadStore(url: url)
        #expect(reloaded.records[0].state == .interrupted)
        #expect(reloaded.records[0].canResume)
        #expect(reloaded.resumeData(id: record.id) == data)
    }

    @Test func cancelKeepsResumeDataThatArrivesLater() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("downloads.json")
        let store = BrowserDownloadStore(url: url)
        let record = store.begin(url: "https://example.com/big.iso", filename: "big.iso")
        store.cancel(id: record.id)
        #expect(store.records[0].state == .cancelled)
        #expect(!store.records[0].canResume)
        #expect(store.records[0].canRetry)

        store.attachResumeData(id: record.id, data: Data("later".utf8))
        #expect(BrowserDownloadStore(url: url).resumeData(id: record.id) == Data("later".utf8))
    }

    @Test func failureWithResumeDataCanResumeAndWithoutCanOnlyRetry() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserDownloadStore(url: directory.appendingPathComponent("downloads.json"))
        let resumable = store.begin(url: "https://example.com/a.bin", filename: "a.bin")
        store.fail(id: resumable.id, message: "The network connection was lost.", resumeData: Data([1, 2, 3]))
        let lost = store.begin(url: "https://example.com/b.bin", filename: "b.bin")
        store.fail(id: lost.id, message: "No route to host")

        let records = Dictionary(uniqueKeysWithValues: store.records.map { ($0.id, $0) })
        #expect(records[resumable.id]?.state == .failed)
        #expect(records[resumable.id]?.errorMessage == "The network connection was lost.")
        #expect(records[resumable.id]?.canResume == true)
        #expect(records[lost.id]?.canResume == false)
        #expect(records[lost.id]?.canRetry == true)
    }

    @Test func resumingConsumesTheDataAndFinishingClearsTheError() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserDownloadStore(url: directory.appendingPathComponent("downloads.json"))
        let record = store.begin(url: "https://example.com/a.bin", filename: "a.bin")
        store.fail(id: record.id, message: "Lost", resumeData: Data([1]))
        let file = store.resumeDataDirectory.appendingPathComponent(store.records[0].resumeDataFile ?? "")
        #expect(FileManager.default.fileExists(atPath: file.path))

        store.restart(id: record.id)
        #expect(store.records[0].state == .inProgress)
        #expect(store.records[0].errorMessage == nil)
        #expect(store.records[0].resumeDataFile == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        store.finish(id: record.id, path: "/tmp/a.bin")
        #expect(store.records[0].state == .completed)
        #expect(!store.records[0].canRetry)
    }

    @Test func removingARecordDeletesItsResumeData() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserDownloadStore(url: directory.appendingPathComponent("downloads.json"))
        let record = store.begin(url: "https://example.com/a.bin", filename: "a.bin")
        store.cancel(id: record.id, resumeData: Data([1]))
        let file = store.resumeDataDirectory.appendingPathComponent(store.records[0].resumeDataFile ?? "")
        store.clearFinished()
        #expect(store.records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func missingResumeFileMeansRetryOnly() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("downloads.json")
        let store = BrowserDownloadStore(url: url)
        let record = store.begin(url: "https://example.com/a.bin", filename: "a.bin")
        store.cancel(id: record.id, resumeData: Data([1]))
        try FileManager.default.removeItem(at: store.resumeDataDirectory)

        let reloaded = BrowserDownloadStore(url: url)
        #expect(reloaded.records[0].canResume == false)
        #expect(reloaded.records[0].canRetry)
    }

    @Test func retryNeedsAWebAddress() {
        let record = BrowserDownloadRecord(url: "blob:https://example.com/1", filename: "x", state: .failed)
        #expect(!record.canRetry)
        let active = BrowserDownloadRecord(url: "https://example.com/x", filename: "x", state: .inProgress)
        #expect(!active.canRetry)
    }

    @Test func bytesAndSpeedFollowWebKitsProgressAndStayOutOfTheFile() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("downloads.json")
        let store = BrowserDownloadStore(url: url)
        let record = store.begin(url: "https://example.com/big.iso", filename: "big.iso")
        let start = Date()
        var notices = 0
        let observation = store.changes.observe { notices += 1 }
        defer { observation.cancel() }

        store.updateProgress(id: record.id, fraction: 0.1, receivedBytes: 10_000_000, expectedBytes: 100_000_000, at: start)
        #expect(store.records[0].receivedBytes == 10_000_000)
        #expect(store.records[0].expectedBytes == 100_000_000)
        // One sample has no speed yet.
        #expect(store.records[0].bytesPerSecond == nil)

        // Under half a second later with the fraction barely moved: no
        // notice, and too soon to count for the speed.
        let before = notices
        store.updateProgress(id: record.id, fraction: 0.102, receivedBytes: 10_200_000, expectedBytes: 100_000_000, at: start.addingTimeInterval(0.3))
        #expect(notices == before)

        store.updateProgress(id: record.id, fraction: 0.12, receivedBytes: 12_000_000, expectedBytes: 100_000_000, at: start.addingTimeInterval(2))
        #expect(store.records[0].bytesPerSecond.map { abs($0 - 1_000_000) < 1 } == true)

        // An unknown size (WebKit's -1) is none.
        store.updateProgress(id: record.id, fraction: 0, receivedBytes: 13_000_000, expectedBytes: -1, at: start.addingTimeInterval(4))
        #expect(store.records[0].expectedBytes == nil)

        store.finish(id: record.id, path: "/tmp/big.iso")
        let saved = try? String(contentsOf: url, encoding: .utf8)
        #expect(saved?.contains("receivedBytes") == false)
        #expect(saved?.contains("bytesPerSecond") == false)
    }

    @Test func aStalledDownloadLosesItsTimeLeft() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserDownloadStore(url: directory.appendingPathComponent("downloads.json"))
        let record = store.begin(url: "https://example.com/big.iso", filename: "big.iso")
        let start = Date()
        store.updateProgress(id: record.id, fraction: 0.10, receivedBytes: 10_000_000, expectedBytes: 100_000_000, at: start)
        store.updateProgress(id: record.id, fraction: 0.11, receivedBytes: 11_000_000, expectedBytes: 100_000_000, at: start.addingTimeInterval(1))
        #expect(store.records[0].bytesPerSecond.map { abs($0 - 1_000_000) < 1 } == true)
        var notices = 0
        let observation = store.changes.observe { notices += 1 }
        defer { observation.cancel() }

        // The same bytes for a few seconds: the speed shown falls with it.
        for second in 2...3 {
            store.updateProgress(id: record.id, fraction: 0.11, receivedBytes: 11_000_000, expectedBytes: 100_000_000,
                                 at: start.addingTimeInterval(Double(second)))
        }
        #expect(notices >= 1)
        #expect((store.records[0].bytesPerSecond ?? 0) < 1_000_000)
        // Nothing for 5 s: stalled, no speed and so no time left.
        for second in 4...7 {
            store.updateProgress(id: record.id, fraction: 0.11, receivedBytes: 11_000_000, expectedBytes: 100_000_000,
                                 at: start.addingTimeInterval(Double(second)))
        }
        #expect(store.records[0].bytesPerSecond == nil)
        #expect(!BrowserDownloadProgressText.detail(store.records[0]).contains("left"))

        // Bytes again: a speed from the new ones, not averaged with the
        // stall.
        store.updateProgress(id: record.id, fraction: 0.12, receivedBytes: 12_000_000, expectedBytes: 100_000_000, at: start.addingTimeInterval(8))
        #expect(store.records[0].bytesPerSecond.map { abs($0 - 1_000_000) < 1 } == true)
    }

    @Test func aRestartedDownloadMeasuresItsSpeedAfresh() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserDownloadStore(url: directory.appendingPathComponent("downloads.json"))
        let record = store.begin(url: "https://example.com/big.iso", filename: "big.iso")
        let start = Date()
        store.updateProgress(id: record.id, fraction: 0.1, receivedBytes: 10_000_000, expectedBytes: 100_000_000, at: start)
        store.updateProgress(id: record.id, fraction: 0.2, receivedBytes: 20_000_000, expectedBytes: 100_000_000, at: start.addingTimeInterval(1))
        store.cancel(id: record.id)
        store.restart(id: record.id)
        // Until WebKit reports again, nothing of the old run shows.
        #expect(store.records[0].receivedBytes == 0)
        #expect(store.records[0].expectedBytes == nil)
        #expect(store.records[0].bytesPerSecond == nil)
        // The first sample after Resume sets a baseline only: the 10 s
        // gap with the old bytes counts for nothing.
        store.updateProgress(id: record.id, fraction: 0.3, receivedBytes: 30_000_000, expectedBytes: 100_000_000, at: start.addingTimeInterval(11))
        store.updateProgress(id: record.id, fraction: 0.4, receivedBytes: 32_000_000, expectedBytes: 100_000_000, at: start.addingTimeInterval(12))
        #expect(store.records[0].bytesPerSecond.map { abs($0 - 2_000_000) < 1 } == true)
    }
}
