@testable import SopranoWeb
import AppKit
import Testing

/// The line under a download in progress and the speed it is built on.
struct BrowserDownloadProgressTests {
    private func record(
        received: Int64 = 0,
        expected: Int64? = nil,
        rate: Double? = nil,
        fraction: Double = 0
    ) -> BrowserDownloadRecord {
        var record = BrowserDownloadRecord(url: "https://example.com/a.bin", filename: "a.bin", fractionCompleted: fraction)
        record.receivedBytes = received
        record.expectedBytes = expected
        record.bytesPerSecond = rate
        return record
    }

    @Test func sizeOfTheWholeAndTimeLeft() {
        let size = BrowserDownloadProgressText.size
        #expect(
            BrowserDownloadProgressText.detail(record(received: 200_000_000, expected: 450_000_000, rate: 1_000_000))
                == "\(size(200_000_000)) of \(size(450_000_000)) · 5 min left"
        )
        // No speed yet: the sizes alone.
        #expect(
            BrowserDownloadProgressText.detail(record(received: 1_000, expected: 2_000))
                == "\(size(1_000)) of \(size(2_000))"
        )
    }

    @Test func withoutASizeTheSpeedInstead() {
        let size = BrowserDownloadProgressText.size
        #expect(BrowserDownloadProgressText.detail(record(received: 5_000_000, rate: 2_000_000))
            == "\(size(5_000_000)) · \(size(2_000_000))/s")
        #expect(BrowserDownloadProgressText.detail(record(received: 5_000_000)) == size(5_000_000))
    }

    @Test func beforeAnyBytesThePercentageOrStarting() {
        #expect(BrowserDownloadProgressText.detail(record()) == "Starting…")
        #expect(BrowserDownloadProgressText.detail(record(fraction: 0.42)) == "Downloading… 42%")
    }

    @Test func timeLeftRoundsUp() {
        #expect(BrowserDownloadProgressText.timeLeft(0.4) == "5 s left")
        #expect(BrowserDownloadProgressText.timeLeft(11) == "15 s left")
        #expect(BrowserDownloadProgressText.timeLeft(59.5) == "1 min left")
        #expect(BrowserDownloadProgressText.timeLeft(61) == "2 min left")
        #expect(BrowserDownloadProgressText.timeLeft(3_600) == "1 h left")
        #expect(BrowserDownloadProgressText.timeLeft(3_900) == "1 h 5 min left")
    }

    @Test func theSpeedIsARunningAverageOfSamplesHalfASecondApart() {
        var rate = BrowserDownloadRate()
        let start = Date()
        rate.sample(bytes: 0, at: start)
        #expect(rate.bytesPerSecond == nil)
        // Too soon: ignored, not a burst.
        rate.sample(bytes: 5_000_000, at: start.addingTimeInterval(0.1))
        #expect(rate.bytesPerSecond == nil)
        rate.sample(bytes: 1_000_000, at: start.addingTimeInterval(1))
        #expect(rate.bytesPerSecond == 1_000_000)
        // A stall pulls it down by the newest sample's weight only.
        rate.sample(bytes: 1_000_000, at: start.addingTimeInterval(2))
        #expect(rate.bytesPerSecond.map { abs($0 - 700_000) < 0.001 } == true)
    }
}
