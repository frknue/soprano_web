import Compression
import Foundation

/// Unpacking an extension's ZIP safely, in process, from the same bytes
/// the checks read. The end-of-central-directory record must end the
/// file and be the only one that does; the central directory is read and
/// checked before anything touches the disk (no symlinks whatever host
/// made the archive, no absolute, `..`, `.`, empty or backslash
/// components, no duplicates after case and Unicode folding, no file
/// that is also a folder, bounded counts and sizes, no encryption, no
/// ZIP64, stored or deflated only), and every entry's local header must
/// repeat what the central directory says about it, with its data in a
/// range of its own. Entries are then written one by one into a scratch
/// folder through descriptors that never follow a link and never replace
/// a file, each inflated against its declared size and CRC-32 under a cap
/// for the whole archive; stored modes are ignored (files 0644, folders
/// 0755). The result is walked again: any symlink or path that resolves
/// outside the folder refuses the whole package. Nothing here runs on the
/// main actor.
enum BrowserExtensionArchive {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case notZIP
        case ambiguous
        case zip64
        case truncated
        case tooManyEntries(Int)
        case tooLarge(UInt64)
        case encrypted(String)
        case unsupportedMethod(String)
        case badLocalHeader(String)
        case overlap(String)
        case symlink(String)
        case unsafePath(String)
        case duplicate(String)
        case clash(String)
        case corrupt(String)
        case missingManifest
        case manifestTooLarge
        case badManifest(String)
        case extractionFailed(String)
        case escapes(String)

        var description: String {
            switch self {
            case .notZIP: "the package is not a ZIP archive"
            case .ambiguous: "the ZIP archive has more than one end record"
            case .zip64: "ZIP64 archives are not supported"
            case .truncated: "the ZIP archive is truncated"
            case let .tooManyEntries(count): "the archive has too many entries (\(count))"
            case let .tooLarge(size): "the archive unpacks to too many bytes (\(size))"
            case let .encrypted(path): "\(path) is encrypted"
            case let .unsupportedMethod(path): "\(path) is compressed in a way this app can't unpack"
            case let .badLocalHeader(path): "the local header of \(path) disagrees with the central directory"
            case let .overlap(path): "\(path) shares bytes with another entry"
            case let .symlink(path): "\(path) is a symbolic link"
            case let .unsafePath(path): "the path “\(path)” is not allowed"
            case let .duplicate(path): "\(path) appears twice"
            case let .clash(path): "\(path) is both a file and a folder"
            case let .corrupt(path): "\(path) does not match its recorded size or checksum"
            case .missingManifest: "the package has no manifest.json"
            case .manifestTooLarge: "manifest.json is too large"
            case let .badManifest(reason): "manifest.json is not usable: \(reason)"
            case let .extractionFailed(reason): "the archive could not be unpacked: \(reason)"
            case let .escapes(path): "\(path) points outside the extension folder"
            }
        }
    }

    struct Entry: Equatable, Sendable {
        var path: String
        var isDirectory: Bool
        var isSymlink: Bool
        var isEncrypted: Bool
        /// 0 stored, 8 deflated; anything else is refused.
        var method: UInt16
        var crc: UInt32
        var compressedSize: UInt64
        var uncompressedSize: UInt64
        /// Where the entry's local header starts.
        var localOffset: Int
        /// Where its (compressed) data starts, after the local header.
        var dataOffset: Int
    }

    static let maxEntries = 20_000
    static let maxUncompressedSize: UInt64 = 256 << 20
    static let maxManifestSize: UInt64 = 1 << 20

    // MARK: Central directory

    /// Every entry of the ZIP's central directory, each checked against
    /// its local header.
    static func entries(of data: Data) throws(Failure) -> [Entry] {
        let bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw .notZIP }
        // The end-of-central-directory record sits in the last 64 KiB + 22
        // and its comment runs exactly to the end of the file. A second
        // record that also does (a decoy hidden in the real one's comment)
        // makes the archive mean different things to different readers.
        var eocd: Int?
        var index = bytes.count - 22
        let floor = max(0, bytes.count - 22 - 0xffff)
        while index >= floor {
            if u32(bytes, index) == 0x0605_4b50, index + 22 + Int(u16(bytes, index + 20)) == bytes.count {
                guard eocd == nil else { throw .ambiguous }
                eocd = index
            }
            index -= 1
        }
        guard let eocd else { throw .notZIP }
        let onDisk = Int(u16(bytes, eocd + 8))
        let total = Int(u16(bytes, eocd + 10))
        let size = Int(u32(bytes, eocd + 12))
        let start = Int(u32(bytes, eocd + 16))
        if onDisk == 0xffff || total == 0xffff || size == 0xffff_ffff || start == 0xffff_ffff { throw .zip64 }
        // One disk only.
        guard u16(bytes, eocd + 4) == 0, u16(bytes, eocd + 6) == 0, onDisk == total else { throw .notZIP }
        guard total <= maxEntries else { throw .tooManyEntries(total) }
        guard start + size == eocd else { throw .truncated }

        var entries: [Entry] = []
        entries.reserveCapacity(total)
        var offset = start
        for _ in 0..<total {
            guard offset + 46 <= eocd, u32(bytes, offset) == 0x0201_4b50 else { throw .truncated }
            let flags = u16(bytes, offset + 8)
            let method = u16(bytes, offset + 10)
            let crc = u32(bytes, offset + 16)
            let compressed = u32(bytes, offset + 20)
            let uncompressed = u32(bytes, offset + 24)
            let nameLength = Int(u16(bytes, offset + 28))
            let extraLength = Int(u16(bytes, offset + 30))
            let commentLength = Int(u16(bytes, offset + 32))
            let disk = u16(bytes, offset + 34)
            let external = u32(bytes, offset + 38)
            let local = Int(u32(bytes, offset + 42))
            let nameStart = offset + 46
            let next = nameStart + nameLength + extraLength + commentLength
            guard next <= eocd else { throw .truncated }
            if compressed == 0xffff_ffff || uncompressed == 0xffff_ffff || local == 0xffff_ffff || disk == 0xffff {
                throw .zip64
            }
            guard disk == 0 else { throw .notZIP }
            let name = bytes[nameStart..<(nameStart + nameLength)]
            let path = String(decoding: name, as: UTF8.self)

            // The local header must repeat the central record; with bit 3
            // (sizes in a trailing data descriptor) its CRC and sizes may
            // be zero instead.
            guard local + 30 <= start, u32(bytes, local) == 0x0403_4b50 else { throw .badLocalHeader(path) }
            let localNameLength = Int(u16(bytes, local + 26))
            let localExtraLength = Int(u16(bytes, local + 28))
            let dataStart = local + 30 + localNameLength + localExtraLength
            let deferred = flags & 0x8 != 0
            let localCRC = u32(bytes, local + 14)
            let localCompressed = u32(bytes, local + 18)
            let localUncompressed = u32(bytes, local + 22)
            guard localNameLength == nameLength,
                  dataStart + Int(compressed) <= start,
                  bytes[(local + 30)..<(local + 30 + nameLength)].elementsEqual(name),
                  u16(bytes, local + 6) == flags,
                  u16(bytes, local + 8) == method,
                  localCRC == crc || (deferred && localCRC == 0),
                  localCompressed == compressed || (deferred && localCompressed == 0),
                  localUncompressed == uncompressed || (deferred && localUncompressed == 0)
            else { throw .badLocalHeader(path) }

            entries.append(Entry(
                path: path,
                isDirectory: path.hasSuffix("/"),
                // The mode in the high half of the external attributes is
                // read by Unix tools whatever host the archive claims.
                isSymlink: (external >> 16) & 0o170000 == 0o120000,
                // Bit 0 encrypted, bit 6 strong encryption, bit 13 a
                // masked (encrypted) central directory.
                isEncrypted: flags & (1 | 1 << 6 | 1 << 13) != 0,
                method: method,
                crc: crc,
                compressedSize: UInt64(compressed),
                uncompressedSize: UInt64(uncompressed),
                localOffset: local,
                dataOffset: dataStart
            ))
            offset = next
        }
        guard offset == eocd else { throw .truncated }

        // Each entry's local header and data are its own bytes.
        var claimed = 0
        for entry in entries.sorted(by: { $0.localOffset < $1.localOffset }) {
            guard entry.localOffset >= claimed else { throw .overlap(entry.path) }
            claimed = entry.dataOffset + Int(entry.compressedSize)
        }
        return entries
    }

    /// The checks every entry passes before extraction; `limit` caps the
    /// declared unpacked size of the whole archive.
    static func validate(_ entries: [Entry], limit: UInt64 = maxUncompressedSize) throws(Failure) {
        guard entries.count <= maxEntries else { throw .tooManyEntries(entries.count) }
        var seen: Set<String> = []
        // Every folder, listed or implied by a deeper path, and every
        // file, all folded like the duplicate check.
        var folders: Set<String> = []
        var files: [(key: String, path: String)] = []
        var total: UInt64 = 0
        var manifest: Entry?
        for entry in entries {
            if entry.isSymlink { throw .symlink(entry.path) }
            if entry.isEncrypted { throw .encrypted(entry.path) }
            guard entry.method == 0 || entry.method == 8 else { throw .unsupportedMethod(entry.path) }
            try checkPath(entry.path, isDirectory: entry.isDirectory)
            let key = entry.path.precomposedStringWithCanonicalMapping.lowercased()
            let folded = entry.isDirectory ? String(key.dropLast()) : key
            guard seen.insert(folded).inserted else { throw .duplicate(entry.path) }
            if entry.isDirectory {
                folders.insert(folded)
            } else {
                files.append((folded, entry.path))
            }
            // A parent already present had its own parents added with it.
            var parent = Substring(folded)
            while let slash = parent.lastIndex(of: "/") {
                parent = parent[..<slash]
                guard folders.insert(String(parent)).inserted else { break }
            }
            total += entry.uncompressedSize
            guard total <= limit else { throw .tooLarge(total) }
            if entry.path == "manifest.json" { manifest = entry }
        }
        for file in files where folders.contains(file.key) { throw .clash(file.path) }
        guard let manifest else { throw .missingManifest }
        guard manifest.uncompressedSize <= maxManifestSize else { throw .manifestTooLarge }
    }

    static func checkPath(_ path: String, isDirectory: Bool) throws(Failure) {
        let trimmed = isDirectory ? String(path.dropLast()) : path
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.contains("\\"),
              !trimmed.contains("\u{0}"),
              !trimmed.utf8.contains(where: { $0 < 0x20 })
        else { throw .unsafePath(path) }
        // A colon is a slash to the Finder and a drive to Windows tools.
        for component in trimmed.split(separator: "/", omittingEmptySubsequences: false) {
            guard !component.isEmpty, component != ".", component != "..", !component.contains(":")
            else { throw .unsafePath(path) }
        }
    }

    // MARK: Manifest

    /// A Chrome extension manifest this app installs: manifest version 2
    /// or 3, a name, neither a hosted app nor a theme.
    static func checkManifest(at folder: URL) throws(Failure) -> [String: Any] {
        let url = folder.appendingPathComponent("manifest.json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else { throw .missingManifest }
        guard size.uint64Value <= maxManifestSize else { throw .manifestTooLarge }
        guard let data = try? Data(contentsOf: url) else { throw .missingManifest }
        return try checkManifest(data)
    }

    static func checkManifest(_ data: Data) throws(Failure) -> [String: Any] {
        // Chrome accepts a UTF-8 byte-order mark.
        let body = data.starts(with: [0xef, 0xbb, 0xbf]) ? data.dropFirst(3) : data
        guard let object = try? JSONSerialization.jsonObject(with: Data(body)),
              let manifest = object as? [String: Any]
        else { throw .badManifest("not a JSON object") }
        guard let version = manifest["manifest_version"] as? Int, version == 2 || version == 3 else {
            throw .badManifest("manifest_version must be 2 or 3")
        }
        guard let name = manifest["name"] as? String, !name.isEmpty else { throw .badManifest("no name") }
        if manifest["app"] != nil { throw .badManifest("apps are not extensions") }
        if manifest["theme"] != nil { throw .badManifest("themes are not extensions") }
        return manifest
    }

    // MARK: Extraction

    /// Checks `archive` and unpacks it into a new folder `destination`
    /// (which must not exist yet), then re-checks what landed there.
    /// `limit` caps the bytes the whole archive unpacks to. Returns the
    /// manifest; on failure nothing is left at `destination`.
    @discardableResult
    static func extract(
        _ archive: Data,
        to destination: URL,
        limit: UInt64 = maxUncompressedSize
    ) throws(Failure) -> [String: Any] {
        let listed = try entries(of: archive)
        try validate(listed, limit: limit)
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("soprano-web-extension-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let unpacked = scratch.appendingPathComponent("unpacked", isDirectory: true)
        do {
            try fileManager.createDirectory(at: unpacked, withIntermediateDirectories: true)
        } catch {
            throw .extractionFailed(error.localizedDescription)
        }
        try unpack(listed, from: archive, into: unpacked, limit: limit)
        try checkTree(unpacked)
        let manifest = try checkManifest(at: unpacked)
        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: unpacked, to: destination)
        } catch {
            throw .extractionFailed(error.localizedDescription)
        }
        return manifest
    }

    /// Writes every (validated) entry under `folder` straight from
    /// `archive`, counting the unpacked bytes of all entries against
    /// `limit`.
    private static func unpack(_ entries: [Entry], from archive: Data, into folder: URL, limit: UInt64) throws(Failure) {
        let root = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw .extractionFailed(systemError()) }
        defer { close(root) }
        var failure: Failure?
        archive.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var total: UInt64 = 0
            do throws(Failure) {
                for entry in entries {
                    try unpack(entry, from: bytes, under: root, total: &total, limit: limit)
                }
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
    }

    /// Creates `entry` below the folder `root`: each parent folder is made
    /// (or reused) and opened without following a link, and the file is
    /// created fresh, never opened if something is already there.
    private static func unpack(
        _ entry: Entry,
        from archive: UnsafeRawBufferPointer,
        under root: Int32,
        total: inout UInt64,
        limit: UInt64
    ) throws(Failure) {
        var components = entry.path.split(separator: "/").map(String.init)
        let name = entry.isDirectory ? nil : components.popLast()
        var folder = root
        var opened: [Int32] = []
        defer { for descriptor in opened { close(descriptor) } }
        for component in components {
            guard mkdirat(folder, component, 0o755) == 0 || errno == EEXIST else {
                throw .extractionFailed("\(entry.path): \(systemError())")
            }
            let next = openat(folder, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw .extractionFailed("\(entry.path): \(systemError())") }
            opened.append(next)
            folder = next
        }
        guard let name else { return }
        let file = openat(folder, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard file >= 0 else { throw .extractionFailed("\(entry.path): \(systemError())") }
        defer { close(file) }
        let payload = UnsafeRawBufferPointer(
            rebasing: archive[entry.dataOffset..<(entry.dataOffset + Int(entry.compressedSize))]
        )
        var sink = Sink(
            file: file,
            path: entry.path,
            size: entry.uncompressedSize,
            checksum: entry.crc,
            limit: limit,
            total: total
        )
        if entry.method == 8 {
            try inflate(payload, into: &sink)
        } else {
            try sink.take(payload)
        }
        total = sink.total
        try sink.finish()
    }

    /// Raw DEFLATE (`COMPRESSION_ZLIB`), streamed through a fixed buffer so
    /// an entry that inflates past its declared size stops at once.
    private static func inflate(_ input: UnsafeRawBufferPointer, into sink: inout Sink) throws(Failure) {
        // A deflate stream is never empty.
        guard let source = input.baseAddress, !input.isEmpty else { throw .corrupt(sink.path) }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw .extractionFailed("the decompressor could not start")
        }
        defer { compression_stream_destroy(stream) }
        let capacity = 64 << 10
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        stream.pointee.src_ptr = source.assumingMemoryBound(to: UInt8.self)
        stream.pointee.src_size = input.count
        while true {
            let remaining = stream.pointee.src_size
            stream.pointee.dst_ptr = buffer
            stream.pointee.dst_size = capacity
            let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            let produced = capacity - stream.pointee.dst_size
            if produced > 0 { try sink.take(UnsafeRawBufferPointer(start: buffer, count: produced)) }
            switch status {
            case COMPRESSION_STATUS_END:
                return
            case COMPRESSION_STATUS_OK where produced > 0 || stream.pointee.src_size < remaining:
                continue
            default:
                // A broken stream, or one that ends before its end block.
                throw .corrupt(sink.path)
            }
        }
    }

    /// One file being written: its bytes must come to exactly the declared
    /// size and CRC-32, and the archive's running total stays under the
    /// cap.
    private struct Sink {
        let file: Int32
        let path: String
        let size: UInt64
        let checksum: UInt32
        let limit: UInt64
        var total: UInt64
        var written: UInt64 = 0
        var crc: UInt32 = 0

        mutating func take(_ chunk: UnsafeRawBufferPointer) throws(Failure) {
            let count = UInt64(chunk.count)
            guard count <= size - written else { throw .corrupt(path) }
            total += count
            guard total <= limit else { throw .tooLarge(total) }
            written += count
            crc = BrowserExtensionArchive.crc32(chunk, continuing: crc)
            var rest = chunk
            while !rest.isEmpty {
                let result = write(file, rest.baseAddress, rest.count)
                if result < 0 {
                    if errno == EINTR { continue }
                    throw .extractionFailed("\(path): \(BrowserExtensionArchive.systemError())")
                }
                rest = UnsafeRawBufferPointer(rebasing: rest[result...])
            }
        }

        func finish() throws(Failure) {
            guard written == size, crc == checksum else { throw .corrupt(path) }
        }
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 != 0 ? 0xedb8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    /// The ZIP CRC-32 of `bytes`, continuing from the CRC of what came
    /// before them (0 for none).
    static func crc32(_ bytes: UnsafeRawBufferPointer, continuing crc: UInt32 = 0) -> UInt32 {
        crcTable.withUnsafeBufferPointer { table in
            var value = ~crc
            for byte in bytes {
                value = table[Int((value ^ UInt32(byte)) & 0xff)] ^ (value >> 8)
            }
            return ~value
        }
    }

    private static func systemError() -> String {
        String(cString: strerror(errno))
    }

    /// Every item under `root` is a plain file or folder inside it. A
    /// folder that can't be listed fails the check.
    static func checkTree(_ root: URL) throws(Failure) {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
        var unreadable: String?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { url, error in
                unreadable = "\(url.lastPathComponent): \(error.localizedDescription)"
                return false
            }
        ) else {
            throw .extractionFailed("the folder can't be read")
        }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let relative = url.path.hasPrefix(root.path + "/")
                ? String(url.path.dropFirst(root.path.count + 1))
                : url.lastPathComponent
            if values?.isSymbolicLink == true { throw .symlink(relative) }
            guard values?.isRegularFile == true || values?.isDirectory == true else { throw .unsafePath(relative) }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved.hasPrefix(base + "/") else { throw .escapes(relative) }
        }
        if let unreadable { throw .extractionFailed(unreadable) }
    }

    /// Copies an unpacked extension folder into a new folder
    /// `destination`, refusing symlinks and anything that isn't a plain
    /// file or folder. Returns the manifest.
    @discardableResult
    static func copyFolder(_ source: URL, to destination: URL) throws(Failure) -> [String: Any] {
        _ = try checkManifest(at: source)
        try checkTree(source)
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("soprano-web-extension-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: scratch) }
        do {
            try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: scratch.appendingPathComponent("copy", isDirectory: true))
        } catch {
            throw .extractionFailed(error.localizedDescription)
        }
        let copy = scratch.appendingPathComponent("copy", isDirectory: true)
        try checkTree(copy)
        let manifest = try checkManifest(at: copy)
        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: copy, to: destination)
        } catch {
            throw .extractionFailed(error.localizedDescription)
        }
        return manifest
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}

extension BrowserExtensionArchive.Failure: LocalizedError {
    var errorDescription: String? { description }
}
