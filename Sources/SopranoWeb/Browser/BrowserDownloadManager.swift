import AppKit
import WebKit

/// Every `WKDownload` in the app: the delegate WebKit reports to, the map
/// from downloads to list rows and the progress timer. Windows hand it new
/// downloads (`adopt`); a download outlives the window that started it and
/// every window's Downloads sidebar shows the one `store`.
@MainActor
final class BrowserDownloadManager: NSObject {
    let store: BrowserDownloadStore
    private let settingsStore: BrowserSettingsStore
    /// The window for the "Ask where to save" panel when the starting
    /// window is gone: the key (or most recently active) browser window.
    var fallbackWindow: () -> NSWindow? = { nil }

    private var downloadsByRecord: [UUID: WKDownload] = [:]
    private var recordsByDownload: [ObjectIdentifier: UUID] = [:]
    private var destinationsByDownload: [ObjectIdentifier: URL] = [:]
    private var startingWindows: [ObjectIdentifier: WeakWindow] = [:]
    private var progressTimer: Timer?

    private struct WeakWindow {
        weak var window: NSWindow?
    }

    init(store: BrowserDownloadStore, settingsStore: BrowserSettingsStore) {
        self.store = store
        self.settingsStore = settingsStore
    }

    var hasActiveDownloads: Bool {
        !downloadsByRecord.isEmpty
    }

    /// Takes over a download WebKit just created in `window`.
    func adopt(_ download: WKDownload, from window: NSWindow?) {
        download.delegate = self
        startingWindows[ObjectIdentifier(download)] = WeakWindow(window: window)
    }

    /// Downloads `request` with `webView`'s data store.
    func start(_ request: URLRequest, in webView: WKWebView) {
        let window = webView.window
        webView.startDownload(using: request) { [weak self] download in
            self?.adopt(download, from: window)
        }
    }

    /// Cancel keeps WebKit's resume data so the row can Resume later.
    func cancel(id: UUID) {
        guard let download = downloadsByRecord[id] else {
            store.cancel(id: id)
            return
        }
        store.cancel(id: id)
        download.cancel { [weak self] resumeData in
            guard let self else { return }
            if let resumeData {
                self.store.attachResumeData(id: id, data: resumeData)
            }
            self.forget(download, recordID: id)
        }
    }

    /// Continues a stopped download from its saved resume data, or starts it
    /// over when there is none.
    func resume(id: UUID, in webView: WKWebView) {
        guard let data = store.resumeData(id: id) else {
            retry(id: id, in: webView)
            return
        }
        let destination = store.records.first { $0.id == id }?.path.map(URL.init(fileURLWithPath:))
        store.restart(id: id)
        let window = webView.window
        webView.resumeDownload(fromResumeData: data) { [weak self] download in
            guard let self else { return }
            self.adopt(download, from: window)
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
    func retry(id: UUID, in webView: WKWebView) {
        guard let record = store.records.first(where: { $0.id == id }),
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
        store.restart(id: id)
        let window = webView.window
        webView.startDownload(using: URLRequest(url: url)) { [weak self] download in
            guard let self else { return }
            self.adopt(download, from: window)
            self.recordsByDownload[ObjectIdentifier(download)] = id
            self.downloadsByRecord[id] = download
            self.startProgressTimer()
        }
    }

    /// Quit: stops every active download with resume data and records it as
    /// interrupted, then calls `completion` once (at most after `timeout`).
    func interruptForQuit(timeout: TimeInterval = 3, completion: @escaping @MainActor () -> Void) {
        let active = downloadsByRecord
        guard !active.isEmpty else {
            completion()
            return
        }
        let barrier = BrowserDownloadQuitBarrier(pending: Set(active.keys), completion: completion)
        for (id, download) in active {
            store.interrupt(id: id, resumeData: nil)
            download.cancel { [weak self] resumeData in
                if let resumeData {
                    self?.store.attachResumeData(id: id, data: resumeData)
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
            store.setDestination(id: existing, path: destination.path)
        } else {
            recordID = store.begin(
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
        startingWindows.removeValue(forKey: key)
        if downloadsByRecord[recordID] === download {
            downloadsByRecord.removeValue(forKey: recordID)
        }
        stopProgressTimerIfIdle()
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
            store.updateProgress(id: recordID, fraction: download.progress.fractionCompleted)
            if store.records.contains(where: { $0.id == recordID && $0.state == .inProgress }) {
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

extension BrowserDownloadManager: WKDownloadDelegate {
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

        // The panel attaches to the window that started the download, or
        // to the key window when that one has closed.
        let window = startingWindows[key]?.window.flatMap { $0.isVisible ? $0 : nil } ?? fallbackWindow()
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
                if let self, let recordID = self.recordsByDownload.removeValue(forKey: key) {
                    self.downloadsByRecord.removeValue(forKey: recordID)
                    self.store.cancel(id: recordID)
                    self.stopProgressTimerIfIdle()
                }
                self?.startingWindows.removeValue(forKey: key)
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
            startingWindows[key] = nil
            return
        }
        let path = destinationsByDownload[key]?.path
            ?? store.records.first { $0.id == recordID }?.path
            ?? ""
        store.finish(id: recordID, path: path)
        forget(download, recordID: recordID)
    }

    func download(
        _ download: WKDownload,
        didFailWithError error: Error,
        resumeData: Data?
    ) {
        let key = ObjectIdentifier(download)
        guard let recordID = recordsByDownload[key] else {
            startingWindows[key] = nil
            return
        }
        if store.records.first(where: { $0.id == recordID })?.state.isStopped == true {
            // We stopped it (Cancel or quit); keep whatever resume data comes.
            if let resumeData {
                store.attachResumeData(id: recordID, data: resumeData)
            }
        } else {
            store.fail(id: recordID, message: error.localizedDescription, resumeData: resumeData)
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
