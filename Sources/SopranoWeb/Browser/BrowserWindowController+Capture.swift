import AppKit
import ImageIO
import WebKit

/// What a capture produced: the PNG, the file it was saved to (nil when
/// saving failed; the pasteboard still has it) and the reason it wasn't.
struct BrowserCaptureResult {
    var image: BrowserCaptureImage
    var fileURL: URL?
    var saveError: String?
}

/// Capture (⇧⌘2, `/capture`): an overlay over the page the user looks at
/// (`pageTab`: the Peek's, the focused pane's) — a drag captures an area,
/// a click the visible page, "Full Page" the whole document, Esc cancels.
/// The PNG goes onto the pasteboard and into the download folder
/// (`BrowserCaptureFile`), and a toast shows it. Private windows capture
/// the same way: it is the user's own explicit action.
extension BrowserWindowController {
    /// The page the user looks at can be captured (a crashed page can't).
    var canCapture: Bool {
        guard let tab = pageTab else { return false }
        return tab.lifecycle.crashView == nil
    }

    /// ⇧⌘2: opens the overlay, or closes an open one.
    func toggleCaptureOverlay() {
        if captureOverlay != nil {
            closeCaptureOverlay()
            return
        }
        guard canCapture, let tab = pageTab, let window else {
            NSSound.beep()
            return
        }
        let overlay = BrowserCaptureOverlay(tabID: tab.id, theme: theme)
        webArea.addSubview(overlay, positioned: .above, relativeTo: nil)
        let webView = tab.webView
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: webView.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: webView.bottomAnchor),
        ])
        overlay.onChoice = { [weak self, weak overlay] choice in
            guard let self, let overlay, overlay === self.captureOverlay else { return }
            self.closeCaptureOverlay()
            guard choice != .cancel, let tab = self.windowTab(id: overlay.tabID) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.capture(choice, of: tab)
                } catch {
                    self.showVimiumToast("Couldn’t capture the page: \(error.localizedDescription)")
                }
            }
        }
        captureOverlay = overlay
        window.makeFirstResponder(overlay)
    }

    /// Closes the overlay; when it had the keyboard, the page the user
    /// now looks at (`pageTab`) gets it — not the overlay's tab, which may
    /// have just left the screen (a CLI selection, a Space switch).
    func closeCaptureOverlay() {
        guard let overlay = captureOverlay else { return }
        captureOverlay = nil
        let hadFocus = window?.firstResponder === overlay
        overlay.removeFromSuperview()
        if hadFocus {
            focusPage()
        }
    }

    /// Closes the overlay when the page under it is no longer the one the
    /// user looks at (another tab, pane or Space; a Peek opened or closed).
    func updateCaptureOverlay() {
        guard let overlay = captureOverlay else { return }
        if pageTab?.id != overlay.tabID || !canCapture {
            closeCaptureOverlay()
        }
    }

    /// Captures `choice` of `tab`'s page, saves and copies it and shows the
    /// toast.
    @discardableResult
    func capture(_ choice: BrowserCaptureOverlay.Choice, of tab: BrowserTab) async throws -> BrowserCaptureResult {
        let webView = tab.webView
        let scale = BrowserCaptureRenderer.scale(of: webView)
        let image: BrowserCaptureImage
        switch choice {
        case .area(let rect): image = try await BrowserCaptureRenderer.snapshot(of: webView, rect: rect, scale: scale)
        case .visible, .cancel: image = try await BrowserCaptureRenderer.snapshot(of: webView, rect: nil, scale: scale)
        case .fullPage: image = try await BrowserCaptureRenderer.fullPage(of: webView, scale: scale)
        }
        let result = await deliverCapture(image, date: Date())
        let thumbnailPixels = Int(BrowserCaptureToast.thumbnailHeight * 2 * 3)
        let thumbnail = await Task.detached(priority: .userInitiated) {
            Self.thumbnail(of: image.png, maxPixels: thumbnailPixels)
        }.value
        showCaptureToast(result, thumbnail: thumbnail)
        return result
    }

    /// The pasteboard first (it can't fail for want of a folder), then a
    /// unique file in the download folder, written off the main actor
    /// (`BrowserCaptureFile.save`: whole or not at all, never replacing).
    func deliverCapture(_ image: BrowserCaptureImage, date: Date) async -> BrowserCaptureResult {
        let pasteboard = manager.pasteboard
        pasteboard.clearContents()
        pasteboard.setData(image.png, forType: .png)
        let directory = manager.settingsStore.settings.downloadDirectoryURL
        let png = image.png
        let saved = await Task.detached(priority: .userInitiated) {
            Result { try BrowserCaptureFile.save(png, in: directory, date: date) }
        }.value
        switch saved {
        case .success(let url):
            return BrowserCaptureResult(image: image, fileURL: url)
        case .failure(let error):
            return BrowserCaptureResult(image: image, fileURL: nil, saveError: error.localizedDescription)
        }
    }

    func showCaptureToast(_ result: BrowserCaptureResult, thumbnail: CGImage?) {
        captureToast?.removeFromSuperview()
        let note = result.image.isCut ? "cut at \(result.image.pixelHeight) px" : nil
        let toast = BrowserCaptureToast(
            fileURL: result.fileURL,
            fallbackName: result.saveError.map { "Couldn’t save: \($0)" } ?? "",
            thumbnail: thumbnail.map { NSImage(cgImage: $0, size: .zero) },
            note: note,
            theme: theme
        )
        toast.onReveal = { url in NSWorkspace.shared.activateFileViewerSelecting([url]) }
        webArea.addSubview(toast, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            toast.trailingAnchor.constraint(equalTo: webArea.trailingAnchor, constant: -16),
            toast.bottomAnchor.constraint(equalTo: webArea.bottomAnchor, constant: -16),
            toast.leadingAnchor.constraint(greaterThanOrEqualTo: webArea.leadingAnchor, constant: 16),
        ])
        captureToast = toast
        Task { @MainActor [weak toast] in
            try? await Task.sleep(nanoseconds: UInt64(BrowserCaptureToast.lifetime * 1_000_000_000))
            toast?.removeFromSuperview()
        }
    }

    /// A small decode of `png` for the toast (ImageIO never decodes a tall
    /// full page whole for it).
    nonisolated static func thumbnail(of png: Data, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    }
}
