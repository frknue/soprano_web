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
        let directory = settingsStore.settings.downloadDirectoryURL
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = sanitizedFilename(suggestedFilename)
        let destination = uniqueDestination(in: directory, filename: filename)
        let record = downloads.begin(
            url: download.originalRequest?.url?.absoluteString ?? response.url?.absoluteString ?? "",
            filename: destination.lastPathComponent
        )
        recordsByDownload[key] = record.id
        destinationsByDownload[key] = destination
        downloadsByRecord[record.id] = download
        startProgressTimer()
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        guard let recordID = recordsByDownload[key] else {
            recordsByDownload[key] = nil
            destinationsByDownload[key] = nil
            return
        }
        let path = destinationsByDownload[key]?.path ?? ""
        downloads.finish(id: recordID, path: path)
        downloadsByRecord.removeValue(forKey: recordID)
        recordsByDownload.removeValue(forKey: key)
        destinationsByDownload.removeValue(forKey: key)
        stopProgressTimerIfIdle()
    }

    func download(
        _ download: WKDownload,
        didFailWithError error: Error,
        resumeData: Data?
    ) {
        let key = ObjectIdentifier(download)
        guard let recordID = recordsByDownload[key] else { return }
        downloads.fail(id: recordID, message: error.localizedDescription)
        downloadsByRecord.removeValue(forKey: recordID)
        recordsByDownload.removeValue(forKey: key)
        destinationsByDownload.removeValue(forKey: key)
        stopProgressTimerIfIdle()
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
    func cancelDownload(id: UUID) {
        downloadsByRecord[id]?.cancel { _ in }
        downloadsByRecord.removeValue(forKey: id)
        downloads.cancel(id: id)
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
