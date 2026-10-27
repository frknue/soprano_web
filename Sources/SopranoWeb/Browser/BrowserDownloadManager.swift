import AppKit
import WebKit

/// Every `WKDownload` in the app: the delegate WebKit reports to, the map
/// from downloads to list rows and the progress timer. Windows hand it new
/// downloads (`adopt`); a download outlives the window that started it and
/// every window's Downloads sidebar shows the one `store`. A row remembers
/// the profile of the tab that started it, and Resume and Retry run in that
/// profile's data context, whatever Space the clicked window shows. A
/// download from a private window carries that window's data context id, so
/// its row is listed only there and never saved.
@MainActor
final class BrowserDownloadManager: NSObject {
    let store: BrowserDownloadStore
    private let settingsStore: BrowserSettingsStore
    /// The window for the "Ask where to save" panel when the starting
    /// window is gone: the key (or most recently active) browser window.
    var fallbackWindow: () -> NSWindow? = { nil }
    /// The normal data context of a profile (`BrowserWindowManager.context(for:)`):
    /// where a saved row resumes and retries.
    var profileContext: (UUID) -> BrowserDataContext? = { _ in nil }

    private var downloadsByRecord: [UUID: WKDownload] = [:]
    private var recordsByDownload: [ObjectIdentifier: UUID] = [:]
    private var destinationsByDownload: [ObjectIdentifier: URL] = [:]
    private var startingWindows: [ObjectIdentifier: WeakWindow] = [:]
    /// Where a new download's row comes from: the tab's profile, and its
    /// private context for a private window's download.
    private var origins: [ObjectIdentifier: Origin] = [:]
    /// The download-only web view a resumed or retried download started
    /// from, kept until the download ends.
    private var downloadWebViews: [ObjectIdentifier: WKWebView] = [:]
    private var progressTimer: Timer?

    private struct WeakWindow {
        weak var window: NSWindow?
    }

    private struct Origin {
        let profileID: UUID
        let privateContextID: UUID?
    }

    init(store: BrowserDownloadStore, settingsStore: BrowserSettingsStore) {
        self.store = store
        self.settingsStore = settingsStore
    }

    var hasActiveDownloads: Bool {
        !downloadsByRecord.isEmpty
    }

    /// Takes over a download WebKit just created in `window` for a tab of
    /// `context`: its row remembers the context's profile, and a private
    /// context's id.
    func adopt(_ download: WKDownload, from window: NSWindow?, context: BrowserDataContext) {
        download.delegate = self
        let key = ObjectIdentifier(download)
        startingWindows[key] = WeakWindow(window: window)
        origins[key] = Origin(profileID: context.profileID, privateContextID: context.downloadContextID)
    }

    /// Downloads `request` with `webView`'s data store; `context` is the
    /// data context of `webView`'s tab.
    func start(_ request: URLRequest, in webView: WKWebView, context: BrowserDataContext) {
        let window = webView.window
        webView.startDownload(using: request) { [weak self] download in
            self?.adopt(download, from: window, context: context)
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

    /// The data context a stopped row continues in: a private row's own
    /// window's (`windowContext`; another window has no such row), else
    /// the normal context of the profile the download started in — never
    /// the current Space's.
    func dataContext(for record: BrowserDownloadRecord, windowContext: BrowserDataContext) -> BrowserDataContext? {
        if let privateContextID = record.privateContextID {
            return windowContext.downloadContextID == privateContextID ? windowContext : nil
        }
        return profileContext(record.profileID)
    }

    /// What a resumed or retried download runs in: `context`'s data store
    /// and the app's user agent, no page.
    static func downloadConfiguration(for context: BrowserDataContext) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = context.websiteDataStore
        configuration.applicationNameForUserAgent = BrowserUserAgent.applicationName
        return configuration
    }

    /// Continues a stopped download from its saved resume data, or starts it
    /// over when there is none, in the data context it started in
    /// (`dataContext(for:windowContext:)`). `window` is the clicked window,
    /// for the "Ask where to save" panel.
    func resume(id: UUID, from window: NSWindow?, windowContext: BrowserDataContext) {
        guard let data = store.resumeData(id: id) else {
            retry(id: id, from: window, windowContext: windowContext)
            return
        }
        guard let record = store.records.first(where: { $0.id == id }),
              let context = dataContext(for: record, windowContext: windowContext)
        else {
            NSSound.beep()
            return
        }
        let destination = record.path.map(URL.init(fileURLWithPath:))
        store.restart(id: id)
        let webView = WKWebView(frame: .zero, configuration: Self.downloadConfiguration(for: context))
        webView.resumeDownload(fromResumeData: data) { [weak self] download in
            guard let self else { return }
            // The row already exists, private or not.
            self.adopt(download, from: window, context: context)
            let key = ObjectIdentifier(download)
            self.downloadWebViews[key] = webView
            self.recordsByDownload[key] = id
            if let destination {
                self.destinationsByDownload[key] = destination
            }
            self.downloadsByRecord[id] = download
            self.startProgressTimer()
        }
    }

    /// Downloads the record's original URL again from the start, into the
    /// same list row, in the data context it started in.
    func retry(id: UUID, from window: NSWindow?, windowContext: BrowserDataContext) {
        guard let record = store.records.first(where: { $0.id == id }),
              record.canRetry,
              let url = URL(string: record.url),
              let context = dataContext(for: record, windowContext: windowContext)
        else {
            NSSound.beep()
            return
        }
        if let path = record.path {
            // A partial file from the stopped attempt; the retry starts over.
            try? FileManager.default.removeItem(atPath: path)
        }
        store.restart(id: id)
        let webView = WKWebView(frame: .zero, configuration: Self.downloadConfiguration(for: context))
        webView.startDownload(using: URLRequest(url: url)) { [weak self] download in
            guard let self else { return }
            self.adopt(download, from: window, context: context)
            let key = ObjectIdentifier(download)
            self.downloadWebViews[key] = webView
            self.recordsByDownload[key] = id
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
            let origin = origins[key]
            recordID = store.begin(
                url: address,
                filename: destination.lastPathComponent,
                path: destination.path,
                profileID: origin?.profileID ?? BrowserProfile.defaultID,
                privateContextID: origin?.privateContextID
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
        dropStartState(key)
        if downloadsByRecord[recordID] === download {
            downloadsByRecord.removeValue(forKey: recordID)
        }
        stopProgressTimerIfIdle()
    }

    /// What `adopt` and Resume/Retry kept for a download until it has a row
    /// or ends.
    private func dropStartState(_ key: ObjectIdentifier) {
        startingWindows.removeValue(forKey: key)
        origins.removeValue(forKey: key)
        downloadWebViews.removeValue(forKey: key)
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
                self?.dropStartState(key)
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
            dropStartState(key)
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
            dropStartState(key)
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
