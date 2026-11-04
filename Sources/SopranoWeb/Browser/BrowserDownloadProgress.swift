import Foundation

/// A download's recent speed from the bytes WebKit reports: each sample at
/// least half a second after the last one moves a running average (30 %
/// the newest), so a burst or a stall shifts the time left gradually. No
/// new bytes for `stallInterval` is a stall: no speed (so no time left)
/// until bytes come again, and then a speed from those alone.
struct BrowserDownloadRate: Sendable {
    private(set) var bytesPerSecond: Double?
    private var lastBytes: Int64?
    private var lastAt: Date?
    private var lastGrowthAt: Date?

    static let minimumInterval: TimeInterval = 0.5
    static let newestWeight = 0.3
    static let stallInterval: TimeInterval = 5

    mutating func sample(bytes: Int64, at now: Date) {
        guard let lastBytes, let lastAt else {
            self.lastBytes = bytes
            self.lastAt = now
            lastGrowthAt = now
            return
        }
        let elapsed = now.timeIntervalSince(lastAt)
        guard elapsed >= Self.minimumInterval else { return }
        let delta = max(0, bytes - lastBytes)
        self.lastBytes = bytes
        self.lastAt = now
        if delta > 0 {
            let instant = Double(delta) / elapsed
            bytesPerSecond = bytesPerSecond.map { $0 * (1 - Self.newestWeight) + instant * Self.newestWeight } ?? instant
            lastGrowthAt = now
        } else if now.timeIntervalSince(lastGrowthAt ?? now) >= Self.stallInterval {
            bytesPerSecond = nil
        } else if let rate = bytesPerSecond {
            bytesPerSecond = rate * (1 - Self.newestWeight)
        }
    }
}

/// The line under a download in progress, as in Arc's sidebar: its size so
/// far against the whole and the time left ("12.3 MB of 45 MB · 2 min
/// left"), or the size so far and the speed while the server gave no size.
/// Before WebKit reports bytes: the percentage, else "Starting…".
enum BrowserDownloadProgressText {
    static func detail(_ record: BrowserDownloadRecord) -> String {
        guard record.receivedBytes > 0 else {
            let percent = Int((record.fractionCompleted * 100).rounded())
            return percent > 0 ? "Downloading… \(percent)%" : "Starting…"
        }
        let received = size(record.receivedBytes)
        guard let expected = record.expectedBytes else {
            guard let rate = record.bytesPerSecond, rate > 0 else { return received }
            return "\(received) · \(size(Int64(rate)))/s"
        }
        var text = "\(received) of \(size(expected))"
        if let rate = record.bytesPerSecond, rate > 0, expected > record.receivedBytes {
            text += " · " + timeLeft(Double(expected - record.receivedBytes) / rate)
        }
        return text
    }

    /// "5 s left" (in fives under a minute), "2 min left", "1 h 5 min left".
    static func timeLeft(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        if total < 60 {
            return "\(max(5, Int((Double(total) / 5).rounded(.up)) * 5)) s left"
        }
        let minutes = Int((Double(total) / 60).rounded(.up))
        if minutes < 60 {
            return "\(minutes) min left"
        }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h left" : "\(hours) h \(rest) min left"
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
