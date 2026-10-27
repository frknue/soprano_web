import AppKit

/// One `<link rel=icon>` the page declared, as the favicon script reports it.
struct BrowserFaviconCandidate: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case raster
        case ico
        case svg
    }

    let url: URL
    let kind: Kind
    /// Largest declared edge in pixels; nil when `sizes` is absent, `any`
    /// or unparseable.
    let size: Int?

    init(url: URL, kind: Kind, size: Int?) {
        self.url = url
        self.kind = kind
        self.size = size
    }

    /// Reads one reported entry (`href`, `rel`, `sizes`, `type`); nil for
    /// mask icons and schemes the store cannot fetch.
    init?(href: String, rel: String, sizes: String?, type: String?, base: URL?) {
        let rels = rel.lowercased().split(whereSeparator: \.isWhitespace)
        guard rels.contains(where: { $0 == "icon" || $0.hasPrefix("apple-touch-icon") }),
              !rels.contains("mask-icon"),
              let url = URL(string: href.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: base)?
                .absoluteURL,
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "data"].contains(scheme)
        else { return nil }

        let mime = (type ?? "").lowercased()
        let path = scheme == "data" ? "" : url.path.lowercased()
        let dataType = scheme == "data" ? Self.dataMIME(url.absoluteString) : ""
        let kind: Kind
        if mime.contains("svg") || dataType.contains("svg") || path.hasSuffix(".svg") {
            kind = .svg
        } else if mime.contains("icon") || dataType.contains("icon") || path.hasSuffix(".ico") {
            kind = .ico
        } else {
            kind = .raster
        }

        var size = Self.largestSize(sizes)
        // apple-touch-icon without `sizes` is 180 px by convention.
        if size == nil, kind == .raster, rels.contains(where: { $0.hasPrefix("apple-touch-icon") }) {
            size = 180
        }
        self.init(url: url, kind: kind, size: size)
    }

    private static func largestSize(_ sizes: String?) -> Int? {
        guard let sizes else { return nil }
        let edges = sizes.lowercased().split(whereSeparator: \.isWhitespace).compactMap { token -> Int? in
            let parts = token.split(separator: "x")
            guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]),
                  width > 0, height > 0
            else { return nil }
            return max(width, height)
        }
        return edges.max()
    }

    private static func dataMIME(_ string: String) -> String {
        let body = string.dropFirst("data:".count)
        return String(body.prefix { $0 != ";" && $0 != "," }).lowercased()
    }
}

/// Picks which icons to try for a page, best first.
enum BrowserFaviconSelection {
    /// The pixel edge tab icons render at (16 pt on a 2x display).
    static let targetPixels = 32

    /// Order: rasters of at least 32 px (smallest first, they scale down
    /// cleanly), ICO files (they carry several sizes), rasters without a
    /// declared size, SVG, then smaller rasters (largest first). The site's
    /// `/favicon.ico` closes the list when the page did not declare it.
    static func orderedSources(_ candidates: [BrowserFaviconCandidate], pageURL: URL) -> [URL] {
        func rank(_ candidate: BrowserFaviconCandidate) -> (Int, Int) {
            switch candidate.kind {
            case .raster:
                if let size = candidate.size {
                    return size >= targetPixels ? (0, size) : (4, -size)
                }
                return (2, 0)
            case .ico:
                return (1, 0)
            case .svg:
                return (3, 0)
            }
        }
        let sorted = candidates.enumerated().sorted { lhs, rhs in
            let left = rank(lhs.element)
            let right = rank(rhs.element)
            if left != right {
                return left < right
            }
            return lhs.offset < rhs.offset
        }
        var urls: [URL] = []
        for candidate in sorted.map(\.element) where !urls.contains(candidate.url) {
            urls.append(candidate.url)
        }
        if let fallback = fallbackURL(for: pageURL), !urls.contains(fallback) {
            urls.append(fallback)
        }
        return urls
    }

    /// `<scheme>://<host>[:port]/favicon.ico` for http(s) pages.
    static func fallbackURL(for pageURL: URL) -> URL? {
        guard key(for: pageURL) != nil,
              var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: true)
        else { return nil }
        components.path = "/favicon.ico"
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url
    }

    /// The cache key: the lowercased host, plus the port when it is not the
    /// scheme's default. Nil for anything but http(s).
    static func key(for url: URL?) -> String? {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              var host = url.host?.lowercased()
        else { return nil }
        while host.hasSuffix(".") {
            host.removeLast()
        }
        guard !host.isEmpty else { return nil }
        if let port = url.port, port != (scheme == "https" ? 443 : 80) {
            host += ":\(port)"
        }
        return host
    }

    /// A file name for `key` that is safe on disk.
    static func fileName(for key: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")
        return String(key.lowercased().map { allowed.contains($0) ? $0 : "_" }) + ".png"
    }
}

/// Favicons: each page gets the icon its own `<link rel=icon>` list resolves
/// to, and the last icon per host is kept as a fallback (in memory and as
/// 32 px PNGs in `<support>/Favicons/`) for rows and tabs that have not
/// reported yet. Icons are fetched with an ephemeral, cookie-less session,
/// so a favicon request never carries or sets site cookies. A private
/// window uses an in-memory store (`init(inMemoryOver:)`) that reads the
/// cached icons and writes no files.
@MainActor
final class BrowserFaviconStore {
    /// Where icons are cached as files; nil for an in-memory store.
    let directory: URL?
    /// Notified after a new icon lands in the cache.
    let changes = BrowserObservers<Void>()

    private let session: URLSession
    /// The cache an in-memory store falls back to for hosts it has no icon
    /// of its own for.
    private let base: BrowserFaviconStore?
    private var images: [String: NSImage] = [:]
    private var missing: Set<String> = []
    /// The icon each reported source list resolved to this launch (nil when
    /// every source failed), so two pages on one host keep their own icons
    /// and the same page does not refetch on every navigation.
    private var resolvedIcons: [[URL]: NSImage?] = [:]
    private var inFlight: [[URL]: [(NSImage?) -> Void]] = [:]

    nonisolated static let maximumBytes = 1_048_576

    init(
        directory: URL = BrowserFiles.supportDirectory().appendingPathComponent("Favicons", isDirectory: true)
    ) {
        self.directory = directory
        self.base = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: configuration)
    }

    /// A store whose new icons stay in memory, over `base`'s cache: lookups
    /// fall back to `base`, nothing is written to disk and `base` never sees
    /// the icons resolved here. Fetches use `base`'s cookie-less session.
    init(inMemoryOver base: BrowserFaviconStore) {
        self.directory = nil
        self.base = base
        self.session = base.session
    }

    /// The cached icon for the URL's host, from memory or disk.
    func image(for url: URL?) -> NSImage? {
        guard let key = BrowserFaviconSelection.key(for: url) else { return nil }
        return image(forKey: key)
    }

    /// The cached icon for an address string (history and bookmark rows).
    func image(forAddress address: String) -> NSImage? {
        image(for: URL(string: address))
    }

    /// Fetches the best icon among `candidates` (then `/favicon.ico`) for
    /// the page and caches it as its host's icon. `completion` gets the
    /// page's own icon, or the host's cached one when every source failed.
    func resolve(
        pageURL: URL,
        candidates: [BrowserFaviconCandidate],
        completion: @escaping (NSImage?) -> Void
    ) {
        guard let key = BrowserFaviconSelection.key(for: pageURL) else {
            completion(nil)
            return
        }
        let sources = BrowserFaviconSelection.orderedSources(candidates, pageURL: pageURL)
        if let resolved = resolvedIcons[sources] {
            completion(resolved ?? image(forKey: key))
            return
        }
        if inFlight[sources] != nil {
            inFlight[sources]?.append(completion)
            return
        }
        inFlight[sources] = [completion]
        let session = session
        Task { @MainActor [weak self] in
            var result: (NSImage, Data)?
            for source in sources {
                guard let data = await Self.download(source, session: session),
                      let rendered = Self.render(data)
                else { continue }
                result = rendered
                break
            }
            self?.finish(key: key, sources: sources, result: result)
        }
    }

    /// An importer's icons (`page address`, image file): each becomes its
    /// host's cached icon unless the host has one already. Returns how
    /// many were added; `changes` fire once.
    @discardableResult
    func importIcons(_ icons: [(address: String, file: URL)]) -> Int {
        var added = 0
        for icon in icons {
            guard let key = BrowserFaviconSelection.key(for: URL(string: icon.address)),
                  image(forKey: key) == nil,
                  let data = FileManager.default.contents(atPath: icon.file.path),
                  data.count <= Self.maximumBytes,
                  let (image, png) = Self.render(data)
            else { continue }
            images[key] = image
            missing.remove(key)
            if let directory {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? png.write(to: directory.appendingPathComponent(BrowserFaviconSelection.fileName(for: key)), options: .atomic)
            }
            added += 1
        }
        if added > 0 { changes.notify() }
        return added
    }

    private func finish(key: String, sources: [URL], result: (NSImage, Data)?) {
        let completions = inFlight.removeValue(forKey: sources) ?? []
        resolvedIcons.updateValue(result?.0, forKey: sources)
        if let (image, png) = result {
            images[key] = image
            missing.remove(key)
            if let directory {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? png.write(to: directory.appendingPathComponent(BrowserFaviconSelection.fileName(for: key)), options: .atomic)
            }
            changes.notify()
        }
        let icon = result?.0 ?? image(forKey: key)
        for completion in completions {
            completion(icon)
        }
    }

    private func image(forKey key: String) -> NSImage? {
        if let image = images[key] {
            return image
        }
        guard let directory else { return base?.image(forKey: key) }
        guard !missing.contains(key) else { return nil }
        let file = directory.appendingPathComponent(BrowserFaviconSelection.fileName(for: key))
        guard let image = NSImage(contentsOf: file), image.isValid else {
            missing.insert(key)
            return nil
        }
        image.size = Self.pointSize
        images[key] = image
        return image
    }

    private static let pointSize = NSSize(width: 16, height: 16)

    /// The response body when it is a 2xx image no larger than
    /// `maximumBytes`; nil otherwise.
    private nonisolated static func download(_ url: URL, session: URLSession) async -> Data? {
        if url.scheme?.lowercased() == "data" {
            guard url.absoluteString.utf8.count <= maximumBytes * 2,
                  let (data, _) = try? await session.data(from: url),
                  !data.isEmpty, data.count <= maximumBytes
            else { return nil }
            return data
        }
        var request = URLRequest(url: url)
        request.setValue("image/avif,image/webp,image/png,image/svg+xml,image/*;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  http.expectedContentLength <= Int64(maximumBytes),
                  !(http.mimeType ?? "").lowercased().hasPrefix("text/html")
            else {
                bytes.task.cancel()
                return nil
            }
            var data = Data()
            data.reserveCapacity(max(0, Int(http.expectedContentLength)))
            for try await byte in bytes {
                data.append(byte)
                if data.count > maximumBytes {
                    bytes.task.cancel()
                    return nil
                }
            }
            return data.isEmpty ? nil : data
        } catch {
            return nil
        }
    }

    /// Decodes `data` (any format NSImage reads: PNG, ICO, SVG, …) and
    /// draws it aspect-fit into a 32 px square. Returns the 16 pt image and
    /// its PNG.
    static func render(_ data: Data) -> (NSImage, Data)? {
        guard let source = NSImage(data: data), source.isValid,
              source.size.width > 0, source.size.height > 0
        else { return nil }
        let pixels = BrowserFaviconSelection.targetPixels
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)

        let edge = CGFloat(pixels)
        let scale = min(edge / source.size.width, edge / source.size.height)
        let drawn = NSSize(width: source.size.width * scale, height: source.size.height * scale)
        let rect = NSRect(
            x: (edge - drawn.width) / 2,
            y: (edge - drawn.height) / 2,
            width: drawn.width,
            height: drawn.height
        )
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        rep.size = pointSize
        let image = NSImage(size: pointSize)
        image.addRepresentation(rep)
        return (image, png)
    }
}
