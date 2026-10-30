import AppKit
import ImageIO

/// Snapshot flags for Capture (⇧⌘2), run in order on the captured window's
/// page (`pageTab`: the Peek's, the focused pane's) after the other flags:
/// - `--capture-area x,y,w,h` captures that area (the page's points, from
///   its top left), `--capture-visible` the visible page, `--capture-full`
///   the full page; each saves, copies and shows the toast as the overlay
///   would, and prints one `capture:` JSON line (file, its pixel size read
///   back from the PNG, the pasteboard's PNG bytes, the toast).
/// - `--capture-drag x,y,w,h` opens the overlay and drags that rect into it
///   with mouse events (the overlay's own path), then prints the same line.
/// - `--capture-overlay [x,y,w,h]` opens the overlay (with that selection
///   drawn) and leaves it open for the PNG.
struct SnapshotCaptureOptions {
    static let flags: Set<String> = [
        "--capture-area", "--capture-visible", "--capture-full", "--capture-drag", "--capture-overlay",
    ]
    static let usage = """
                               [--capture-area x,y,w,h] [--capture-visible] [--capture-full]
                               [--capture-drag x,y,w,h] [--capture-overlay [x,y,w,h]]
    """

    enum Action {
        case capture(BrowserCaptureOverlay.Choice)
        case drag(CGRect)
        case overlay(CGRect?)
    }

    var actions: [Action] = []

    static func rect(_ text: String) -> CGRect? {
        let parts = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4, parts[2] > 0, parts[3] > 0 else { return nil }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    mutating func parse(
        _ flag: String,
        value: () throws -> String,
        peek: () -> String?,
        skip: () -> Void
    ) throws {
        func rectValue() throws -> CGRect {
            let text = try value()
            guard let rect = Self.rect(text) else { throw SnapshotCommand.OptionError.unknownOption("\(flag) \(text)") }
            return rect
        }
        switch flag {
        case "--capture-area": actions.append(.capture(.area(try rectValue())))
        case "--capture-visible": actions.append(.capture(.visible))
        case "--capture-full": actions.append(.capture(.fullPage))
        case "--capture-drag": actions.append(.drag(try rectValue()))
        default:
            if let next = peek(), let rect = Self.rect(next) {
                skip()
                actions.append(.overlay(rect))
            } else {
                actions.append(.overlay(nil))
            }
        }
    }

    @MainActor
    func run(controller: BrowserWindowController, wait: (TimeInterval) -> Void) {
        for action in actions {
            guard let tab = controller.pageTab else {
                print("capture: no page")
                return
            }
            switch action {
            case .capture(let choice):
                var outcome: Result<BrowserCaptureResult, Error>?
                Task { @MainActor in
                    do {
                        outcome = .success(try await controller.capture(choice, of: tab))
                    } catch {
                        outcome = .failure(error)
                    }
                }
                let deadline = Date().addingTimeInterval(60)
                while outcome == nil, Date() < deadline {
                    wait(0.05)
                }
                report(choice, outcome, controller: controller)
            case .drag(let rect):
                controller.toggleCaptureOverlay()
                guard let overlay = controller.captureOverlay, let window = controller.window else {
                    print("capture: overlay not shown")
                    continue
                }
                overlay.superview?.layoutSubtreeIfNeeded()
                let previous = controller.captureToast
                let points = [rect.origin, CGPoint(x: rect.midX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.maxY)]
                for (index, point) in points.enumerated() {
                    let type: NSEvent.EventType = index == 0 ? .leftMouseDown : index == 1 ? .leftMouseDragged : .leftMouseUp
                    guard let event = NSEvent.mouseEvent(
                        with: type,
                        location: overlay.convert(point, to: nil),
                        modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber,
                        context: nil,
                        eventNumber: 0,
                        clickCount: 1,
                        pressure: 1
                    ) else { continue }
                    switch type {
                    case .leftMouseDown: overlay.mouseDown(with: event)
                    case .leftMouseDragged: overlay.mouseDragged(with: event)
                    default: overlay.mouseUp(with: event)
                    }
                }
                let deadline = Date().addingTimeInterval(60)
                while controller.captureToast === previous, Date() < deadline {
                    wait(0.05)
                }
                print("capture: overlay closed \(controller.captureOverlay == nil ? "yes" : "no")")
                report(nil, nil, controller: controller)
            case .overlay(let selection):
                controller.toggleCaptureOverlay()
                controller.captureOverlay?.superview?.layoutSubtreeIfNeeded()
                controller.captureOverlay?.select(selection)
                wait(0.2)
                let overlay = controller.captureOverlay
                print("capture-overlay: \(overlay == nil ? "not shown" : "over tab \(tab.id == overlay?.tabID ? "pageTab" : "other"), frame \(overlay.map { NSStringFromRect($0.frame) } ?? ""), first responder \(controller.window?.firstResponder === overlay ? "yes" : "no")")")
            }
        }
    }

    /// One `capture:` line: the choice, the file and its real pixel size,
    /// the pasteboard's PNG and the toast's text.
    @MainActor
    private func report(
        _ choice: BrowserCaptureOverlay.Choice?,
        _ outcome: Result<BrowserCaptureResult, Error>?,
        controller: BrowserWindowController
    ) {
        if case .failure(let error) = outcome {
            print("capture: failed \(error.localizedDescription)")
            return
        }
        let toast = controller.captureToast
        let fileURL = (try? outcome?.get())?.fileURL ?? toast?.fileURL
        var line: [String: Any] = [
            "choice": choice.map { "\($0)" } ?? "drag",
            "toast": toast.map { [$0.titleLabel.stringValue, $0.detailLabel.stringValue] } ?? [],
            "toastShown": toast?.superview != nil,
            "pasteboardPNGBytes": controller.manager.pasteboard.data(forType: .png)?.count ?? 0,
        ]
        if let result = try? outcome?.get() {
            line["pixelWidth"] = result.image.pixelWidth
            line["pixelHeight"] = result.image.pixelHeight
            line["isCut"] = result.image.isCut
            line["saveError"] = result.saveError
        }
        if let fileURL, fileURL.path != "/" {
            line["file"] = fileURL.path
            if let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            {
                line["fileWidth"] = properties[kCGImagePropertyPixelWidth]
                line["fileHeight"] = properties[kCGImagePropertyPixelHeight]
            }
        }
        line["scale"] = controller.window?.backingScaleFactor
        let data = (try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])) ?? Data()
        print("capture: \(String(data: data, encoding: .utf8) ?? "{}")")
    }
}
