import Foundation

// MARK: - Downloads

enum BrowserDownloadState: String, Codable, Equatable, Sendable {
    case inProgress
    case completed
    case failed
    case cancelled
    /// Stopped by quitting (or a crash) while downloading.
    case interrupted

    var label: String {
        switch self {
        case .inProgress: "Downloading…"
        case .completed: "Downloaded"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .interrupted: "Interrupted"
        }
    }

    /// Stopped before finishing: Retry starts it again, Resume continues it
    /// when resume data was kept.
    var isStopped: Bool {
        self == .failed || self == .cancelled || self == .interrupted
    }
}

struct BrowserDownloadRecord: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var url: String
    var filename: String
    var path: String?
    var startedAt: Date
    var finishedAt: Date?
    var state: BrowserDownloadState
    var errorMessage: String?
    /// `WKDownload.progress.fractionCompleted`, kept in memory while active and
    /// recorded as 1 on finish.
    var fractionCompleted: Double
    /// File name of the saved `WKDownload` resume data in the store's
    /// resume-data directory (in memory for a private record); nil when the
    /// download cannot be resumed.
    var resumeDataFile: String?
    /// The profile (a Space's data) of the tab the download started in;
    /// Resume and Retry use its data context. Rows saved before rows had
    /// one are Default's.
    var profileID: UUID
    /// The private window's data context the download started in. Such a
    /// record is listed while that window is open and never saved.
    var privateContextID: UUID?
    /// Bytes so far, the file's size (nil while the server hasn't said) and
    /// the recent speed (nil until two samples apart): in memory only,
    /// while it downloads, for "12 MB of 45 MB · 2 min left".
    var receivedBytes: Int64 = 0
    var expectedBytes: Int64?
    var bytesPerSecond: Double?

    init(
        id: UUID = UUID(),
        url: String,
        filename: String,
        path: String? = nil,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        state: BrowserDownloadState = .inProgress,
        errorMessage: String? = nil,
        fractionCompleted: Double = 0,
        resumeDataFile: String? = nil,
        profileID: UUID = BrowserProfile.defaultID,
        privateContextID: UUID? = nil
    ) {
        self.id = id
        self.url = url
        self.filename = filename
        self.path = path
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.state = state
        self.errorMessage = errorMessage
        self.fractionCompleted = fractionCompleted
        self.resumeDataFile = resumeDataFile
        self.profileID = profileID
        self.privateContextID = privateContextID
    }

    private enum CodingKeys: String, CodingKey {
        case id, url, filename, path, startedAt, finishedAt, state, errorMessage, fractionCompleted, resumeDataFile
        case profileID
    }

    /// A missing or unreadable `profileID` is Default's.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        url = try c.decode(String.self, forKey: .url)
        filename = try c.decode(String.self, forKey: .filename)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        state = try c.decode(BrowserDownloadState.self, forKey: .state)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        fractionCompleted = try c.decode(Double.self, forKey: .fractionCompleted)
        resumeDataFile = try c.decodeIfPresent(String.self, forKey: .resumeDataFile)
        profileID = ((try? c.decodeIfPresent(UUID.self, forKey: .profileID)) ?? nil) ?? BrowserProfile.defaultID
        privateContextID = nil
    }

    var canResume: Bool {
        state.isStopped && resumeDataFile != nil
    }

    var canRetry: Bool {
        guard state.isStopped, let scheme = URL(string: url)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}

/// The Downloads list, saved to `downloads.json` with resume data in
/// `DownloadResumeData/`. Records from a private window
/// (`privateContextID`) are listed in that window and kept in memory, resume
/// data included, until `forgetPrivateContext` drops them.
@MainActor
final class BrowserDownloadStore {
    private(set) var records: [BrowserDownloadRecord]
    let url: URL
    /// Holds one `<record id>.resume` file per resumable download.
    let resumeDataDirectory: URL
    let changes = BrowserObservers<Void>()
    /// Private records' resume data, by `resumeDataFile` name.
    private var privateResumeData: [String: Data] = [:]
    /// The speed and last notice of each download in progress.
    private var rates: [UUID: BrowserDownloadRate] = [:]
    private var lastNotified: [UUID: Date] = [:]

    init(url: URL = BrowserFiles.supportDirectory().appendingPathComponent("downloads.json")) {
        self.url = url
        let resumeDataDirectory = url.deletingLastPathComponent()
            .appendingPathComponent("DownloadResumeData", isDirectory: true)
        self.resumeDataDirectory = resumeDataDirectory
        let saved = JSONFile.read(JSONList<BrowserDownloadRecord>.self, at: url)?.entries ?? []
        // A record still in progress on disk outlived its app (quit or crash).
        self.records = saved.map { record in
            var record = record
            if record.state == .inProgress {
                record.state = .interrupted
            }
            if let file = record.resumeDataFile,
               !FileManager.default.fileExists(atPath: resumeDataDirectory.appendingPathComponent(file).path)
            {
                record.resumeDataFile = nil
            }
            return record
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    /// A new row for a download that just got its destination, from a tab
    /// of profile `profileID`; a private window passes its context id and
    /// the row is never saved.
    func begin(
        url address: String,
        filename: String,
        path: String? = nil,
        profileID: UUID = BrowserProfile.defaultID,
        privateContextID: UUID? = nil
    ) -> BrowserDownloadRecord {
        let record = BrowserDownloadRecord(
            url: address,
            filename: filename,
            path: path,
            profileID: profileID,
            privateContextID: privateContextID
        )
        records.insert(record, at: 0)
        changes.notify()
        persist(after: record)
        return record
    }

    /// WebKit's progress, sampled by the manager's timer: the fraction, the
    /// bytes so far and the file's size (nil or ≤ 0 while unknown). The
    /// speed follows the bytes (`BrowserDownloadRate`). Observers hear a
    /// move of half a percent or a new size at once, new bytes or a new
    /// speed (a stall slowing it, then clearing it) at most once a second.
    func updateProgress(
        id: UUID,
        fraction: Double,
        receivedBytes: Int64 = 0,
        expectedBytes: Int64? = nil,
        at now: Date = Date()
    ) {
        guard let index = records.firstIndex(where: { $0.id == id }),
              records[index].state == .inProgress
        else { return }
        let value = min(1, max(0, fraction))
        let expected = expectedBytes.flatMap { $0 > 0 ? $0 : nil }
        let received = max(0, receivedBytes)
        var rate = rates[id] ?? BrowserDownloadRate()
        rate.sample(bytes: received, at: now)
        rates[id] = rate
        let old = records[index]
        let secondPassed = now.timeIntervalSince(lastNotified[id] ?? .distantPast) >= 1
        let changed = abs(old.fractionCompleted - value) >= 0.005
            || old.expectedBytes != expected
            || (secondPassed && (old.receivedBytes != received || old.bytesPerSecond != rate.bytesPerSecond))
        guard changed else { return }
        records[index].fractionCompleted = value
        records[index].receivedBytes = received
        records[index].expectedBytes = expected
        records[index].bytesPerSecond = rate.bytesPerSecond
        lastNotified[id] = now
        changes.notify()
    }

    /// Sets the destination chosen once the response arrived (Retry reuses
    /// its record and may land on a new file name).
    func setDestination(id: UUID, path: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].path = path
        records[index].filename = URL(fileURLWithPath: path).lastPathComponent
        changes.notify()
        persist(after: records[index])
    }

    func finish(id: UUID, path: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].path = path
        records[index].state = .completed
        records[index].fractionCompleted = 1
        records[index].finishedAt = Date()
        records[index].errorMessage = nil
        discardResumeData(at: index)
        forgetProgress(id)
        let record = records[index]
        let pruned = prune()
        changes.notify()
        persist(after: pruned ? nil : record)
    }

    func fail(id: UUID, message: String, resumeData: Data? = nil) {
        stop(id: id, state: .failed, message: message, resumeData: resumeData)
    }

    func cancel(id: UUID, resumeData: Data? = nil) {
        stop(id: id, state: .cancelled, message: nil, resumeData: resumeData)
    }

    /// Quit stopped the download; it shows as interrupted after relaunch.
    func interrupt(id: UUID, resumeData: Data?) {
        stop(id: id, state: .interrupted, message: nil, resumeData: resumeData)
    }

    /// Keeps resume data that arrives after the record already stopped
    /// (`WKDownload.cancel` reports it asynchronously).
    func attachResumeData(id: UUID, data: Data) {
        guard let index = records.firstIndex(where: { $0.id == id }),
              records[index].state.isStopped
        else { return }
        saveResumeData(data, at: index)
        changes.notify()
        persist(after: records[index])
    }

    /// The saved resume data of a stopped download.
    func resumeData(id: UUID) -> Data? {
        guard let record = records.first(where: { $0.id == id }),
              record.canResume,
              let file = record.resumeDataFile
        else { return nil }
        if record.privateContextID != nil {
            return privateResumeData[file]
        }
        return try? Data(contentsOf: resumeDataDirectory.appendingPathComponent(file))
    }

    /// Resume or Retry restarted the record. The resume data is consumed:
    /// WebKit hands over fresh data if the download stops again.
    func restart(id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].state = .inProgress
        records[index].finishedAt = nil
        records[index].errorMessage = nil
        discardResumeData(at: index)
        // A resumed download measures its speed afresh.
        forgetProgress(id)
        changes.notify()
        persist(after: records[index])
    }

    func remove(id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        discardResumeData(at: index)
        forgetProgress(id)
        let record = records.remove(at: index)
        changes.notify()
        persist(after: record)
    }

    func clearFinished() {
        removeFinished { _ in true }
    }

    /// Removes the list entries of downloads started at or after `date`
    /// (Clear Browsing Data); active downloads stay.
    func removeFinished(startedSince date: Date) {
        removeFinished { $0.startedAt >= date }
    }

    /// The last window of a private context closed: its rows and their
    /// resume data go. A download still running finishes its file but no
    /// longer shows in the list.
    func forgetPrivateContext(_ id: UUID) {
        let count = records.count
        for record in records where record.privateContextID == id {
            if let file = record.resumeDataFile {
                privateResumeData[file] = nil
            }
        }
        records.removeAll { $0.privateContextID == id }
        if records.count != count {
            changes.notify()
        }
    }

    /// The rows a window lists: saved downloads, plus its own private ones
    /// when `privateContextID` is set.
    func matching(_ query: String, privateContextID: UUID? = nil) -> [BrowserDownloadRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return records.filter {
            ($0.privateContextID == nil || $0.privateContextID == privateContextID)
                && (needle.isEmpty || $0.filename.lowercased().contains(needle) || $0.url.lowercased().contains(needle))
        }
    }

    private func forgetProgress(_ id: UUID) {
        rates[id] = nil
        lastNotified[id] = nil
    }

    private func stop(id: UUID, state: BrowserDownloadState, message: String?, resumeData: Data?) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].state = state
        records[index].finishedAt = Date()
        records[index].errorMessage = message
        forgetProgress(id)
        if let resumeData {
            saveResumeData(resumeData, at: index)
        }
        let record = records[index]
        let pruned = prune()
        changes.notify()
        persist(after: pruned ? nil : record)
    }

    private func removeFinished(where shouldRemove: (BrowserDownloadRecord) -> Bool) {
        let removed = records.indices.filter {
            records[$0].state != .inProgress && shouldRemove(records[$0])
        }
        guard !removed.isEmpty else { return }
        for index in removed {
            discardResumeData(at: index)
        }
        let ids = Set(removed.map { records[$0].id })
        records.removeAll { ids.contains($0.id) }
        changes.notify()
        persist()
    }

    private func saveResumeData(_ data: Data, at index: Int) {
        let file = "\(records[index].id.uuidString).resume"
        if records[index].privateContextID != nil {
            privateResumeData[file] = data
            records[index].resumeDataFile = file
            return
        }
        do {
            try FileManager.default.createDirectory(at: resumeDataDirectory, withIntermediateDirectories: true)
            try data.write(to: resumeDataDirectory.appendingPathComponent(file), options: .atomic)
            records[index].resumeDataFile = file
        } catch {
            records[index].resumeDataFile = nil
        }
    }

    private func discardResumeData(at index: Int) {
        guard let file = records[index].resumeDataFile else { return }
        if records[index].privateContextID != nil {
            privateResumeData[file] = nil
        } else {
            try? FileManager.default.removeItem(at: resumeDataDirectory.appendingPathComponent(file))
        }
        records[index].resumeDataFile = nil
    }

    /// Keeps the 200 newest finished rows; true when it removed any.
    private func prune() -> Bool {
        let finished = records.filter { $0.state != .inProgress }
        guard finished.count > 200 else { return false }
        let keep = Set(finished.sorted { $0.startedAt > $1.startedAt }.prefix(200).map(\.id))
        for index in records.indices where records[index].state != .inProgress && !keep.contains(records[index].id) {
            discardResumeData(at: index)
        }
        records.removeAll { $0.state != .inProgress && !keep.contains($0.id) }
        return true
    }

    /// Writes the saved rows. A change to a private row alone (`record`)
    /// writes nothing; private rows are never part of the file.
    private func persist(after record: BrowserDownloadRecord? = nil) {
        guard record?.privateContextID == nil else { return }
        try? JSONFile.write(JSONList(records.filter { $0.privateContextID == nil }), to: url)
    }
}
