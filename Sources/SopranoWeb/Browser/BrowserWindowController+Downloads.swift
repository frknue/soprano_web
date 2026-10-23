import AppKit
import WebKit

extension BrowserWindowController: WKDownloadDelegate {
    // MARK: - Downloads

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor @Sendable (URL?) -> Void
    ) {
        let key = ObjectIdentifier(download)
        if let destination = destinationsByDownload[key] {
            // A resumed download continues into its partial file.
            completionHandler(destination)
            return
        }
        let directory = settingsStore.settings.downloadDirectoryURL
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = sanitizedFilename(suggestedFilename)
        let address = download.originalRequest?.url?.absoluteString ?? response.url?.absoluteString ?? ""

        guard settingsStore.settings.askDownloadLocation, let window else {
            let destination = uniqueDestination(in: directory, filename: filename)
            track(download, address: address, destination: destination)
            completionHandler(destination)
            return
        }

        let panel = NSSavePanel()
        panel.directoryURL = directory
        panel.nameFieldStringValue = filename
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let destination = panel.url else {
                // Declining the panel cancels the download; a retried record
                // stays in the list as cancelled.
                if let recordID = self?.recordsByDownload.removeValue(forKey: key) {
                    self?.downloadsByRecord.removeValue(forKey: recordID)
                    self?.downloads.cancel(id: recordID)
                    self?.stopProgressTimerIfIdle()
                }
                completionHandler(nil)
                return
            }
            // The panel already asked to replace an existing file; WebKit
            // refuses to write over one.
            try? FileManager.default.removeItem(at: destination)
            self.track(download, address: address, destination: destination)
            completionHandler(destination)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        guard let recordID = recordsByDownload[key] else {
            recordsByDownload[key] = nil
            destinationsByDownload[key] = nil
            return
        }
        let path = destinationsByDownload[key]?.path
            ?? downloads.records.first { $0.id == recordID }?.path
            ?? ""
        downloads.finish(id: recordID, path: path)
        forget(download, recordID: recordID)
    }

    func download(
        _ download: WKDownload,
        didFailWithError error: Error,
        resumeData: Data?
    ) {
        let key = ObjectIdentifier(download)
        guard let recordID = recordsByDownload[key] else { return }
        if downloads.records.first(where: { $0.id == recordID })?.state.isStopped == true {
            // We stopped it (Cancel or quit); keep whatever resume data comes.
            if let resumeData {
                downloads.attachResumeData(id: recordID, data: resumeData)
            }
        } else {
            downloads.fail(id: recordID, message: error.localizedDescription, resumeData: resumeData)
        }
        forget(download, recordID: recordID)
    }

    func download(
        _ download: WKDownload,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        decisionHandler: @escaping @MainActor @Sendable (WKDownload.RedirectPolicy) -> Void
    ) {
        decisionHandler(.allow)
    }
}

extension BrowserWindowController {
    var hasActiveDownloads: Bool {
        !downloadsByRecord.isEmpty
    }

    /// Starts a download of `request` in the selected tab's web view.
    func startDownload(_ request: URLRequest) {
        downloadWebView().startDownload(using: request) { [weak self] download in
            download.delegate = self
        }
    }

    /// Cancel keeps WebKit's resume data so the row can Resume later.
    func cancelDownload(id: UUID) {
        guard let download = downloadsByRecord[id] else {
            downloads.cancel(id: id)
            return
        }
        downloads.cancel(id: id)
        download.cancel { [weak self] resumeData in
            guard let self else { return }
            if let resumeData {
                self.downloads.attachResumeData(id: id, data: resumeData)
            }
            self.forget(download, recordID: id)
        }
    }

    /// Continues a stopped download from its saved resume data.
    func resumeDownload(id: UUID) {
        guard let data = downloads.resumeData(id: id) else {
            retryDownload(id: id)
            return
        }
        let destination = downloads.records.first { $0.id == id }?.path.map(URL.init(fileURLWithPath:))
        downloads.restart(id: id)
        downloadWebView().resumeDownload(fromResumeData: data) { [weak self] download in
            guard let self else { return }
            download.delegate = self
            let key = ObjectIdentifier(download)
            self.recordsByDownload[key] = id
            if let destination {
                self.destinationsByDownload[key] = destination
            }
            self.downloadsByRecord[id] = download
            self.startProgressTimer()
        }
    }

    /// Downloads the record's original URL again from the start, into the
    /// same list row.
    func retryDownload(id: UUID) {
        guard let record = downloads.records.first(where: { $0.id == id }),
              record.canRetry,
              let url = URL(string: record.url)
        else {
            NSSound.beep()
            return
        }
        if let path = record.path {
            // A partial file from the stopped attempt; the retry starts over.
            try? FileManager.default.removeItem(atPath: path)
        }
        downloads.restart(id: id)
        downloadWebView().startDownload(using: URLRequest(url: url)) { [weak self] download in
            guard let self else { return }
            download.delegate = self
            self.recordsByDownload[ObjectIdentifier(download)] = id
            self.downloadsByRecord[id] = download
            self.startProgressTimer()
        }
    }

    /// Quit: stops every active download with resume data and records it as
    /// interrupted, then calls `completion` once (at most after `timeout`).
    func interruptDownloadsForQuit(timeout: TimeInterval = 3, completion: @escaping @MainActor () -> Void) {
        let active = downloadsByRecord
        guard !active.isEmpty else {
            completion()
            return
        }
        let barrier = BrowserDownloadQuitBarrier(pending: Set(active.keys), completion: completion)
        for (id, download) in active {
            downloads.interrupt(id: id, resumeData: nil)
            download.cancel { [weak self] resumeData in
                if let resumeData {
                    self?.downloads.attachResumeData(id: id, data: resumeData)
                }
                self?.forget(download, recordID: id)
                barrier.settle(id)
            }
        }
        Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { _ in
            MainActor.assumeIsolated { barrier.finish() }
        }
    }

    /// Maps a new download to its record: a retried download already has
    /// one, a fresh download gets a new row.
    private func track(_ download: WKDownload, address: String, destination: URL) {
        let key = ObjectIdentifier(download)
        let recordID: UUID
        if let existing = recordsByDownload[key] {
            recordID = existing
            downloads.setDestination(id: existing, path: destination.path)
        } else {
            recordID = downloads.begin(
                url: address,
                filename: destination.lastPathComponent,
                path: destination.path
            ).id
            recordsByDownload[key] = recordID
        }
        destinationsByDownload[key] = destination
        downloadsByRecord[recordID] = download
        startProgressTimer()
    }

    private func forget(_ download: WKDownload, recordID: UUID) {
        let key = ObjectIdentifier(download)
        recordsByDownload.removeValue(forKey: key)
        destinationsByDownload.removeValue(forKey: key)
        if downloadsByRecord[recordID] === download {
            downloadsByRecord.removeValue(forKey: recordID)
        }
        stopProgressTimerIfIdle()
    }

    /// Downloads need a web view of this window's data store; any tab works.
    private func downloadWebView() -> WKWebView {
        if let tab = selectedTab ?? tabs.first {
            return tab.webView
        }
        return newTab(url: nil, focusAddress: false).webView
    }

    private func startProgressTimer() {
        guard progressTimer == nil else { return }
        let timer = Timer(
            timeInterval: 0.25,
            target: self,
            selector: #selector(progressTimerFired(_:)),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func stopProgressTimerIfIdle() {
        guard downloadsByRecord.isEmpty else { return }
        progressTimer?.invalidate()
        progressTimer = nil
    }

    @objc private func progressTimerFired(_ timer: Timer) {
        var hasActiveRecord = false
        for (recordID, download) in downloadsByRecord {
            downloads.updateProgress(id: recordID, fraction: download.progress.fractionCompleted)
            if downloads.records.contains(where: { $0.id == recordID && $0.state == .inProgress }) {
                hasActiveRecord = true
            }
        }
        if !hasActiveRecord {
            stopProgressTimerIfIdle()
        }
    }

    private func sanitizedFilename(_ value: String) -> String {
        let name = URL(fileURLWithPath: value).lastPathComponent
        return name.isEmpty ? "Download" : name
    }

    private func uniqueDestination(in directory: URL, filename: String) -> URL {
        let candidate = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var index = 1
        while true {
            let name = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            let next = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: next.path) {
                return next
            }
            index += 1
        }
    }
}

/// Calls the quit completion once, after every download settled or the
/// timeout fired.
@MainActor
private final class BrowserDownloadQuitBarrier {
    private var pending: Set<UUID>
    private var completion: (@MainActor () -> Void)?

    init(pending: Set<UUID>, completion: @escaping @MainActor () -> Void) {
        self.pending = pending
        self.completion = completion
    }

    func settle(_ id: UUID) {
        pending.remove(id)
        if pending.isEmpty {
            finish()
        }
    }

    func finish() {
        let completion = completion
        self.completion = nil
        completion?()
    }
}
