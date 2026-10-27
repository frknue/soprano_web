import Foundation

/// Unpacking an extension's ZIP safely. The central directory is read and
/// checked before anything touches the disk (no symlinks, no absolute,
/// `..`, `.`, empty or backslash components, no duplicates after case and
/// Unicode folding, bounded counts and sizes, no encryption, no ZIP64),
/// `/usr/bin/ditto` extracts into a scratch folder, and the result is
/// walked again: any symlink or path that resolves outside the folder
/// refuses the whole package. Nothing here runs on the main actor.
enum BrowserExtensionArchive {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case notZIP
        case zip64
        case truncated
        case tooManyEntries(Int)
        case tooLarge(UInt64)
        case encrypted(String)
        case symlink(String)
        case unsafePath(String)
        case duplicate(String)
        case missingManifest
        case manifestTooLarge
        case badManifest(String)
        case extractionFailed(String)
        case escapes(String)

        var description: String {
            switch self {
            case .notZIP: "the package is not a ZIP archive"
            case .zip64: "ZIP64 archives are not supported"
            case .truncated: "the ZIP archive is truncated"
            case let .tooManyEntries(count): "the archive has too many entries (\(count))"
            case let .tooLarge(size): "the archive unpacks to too many bytes (\(size))"
            case let .encrypted(path): "\(path) is encrypted"
            case let .symlink(path): "\(path) is a symbolic link"
            case let .unsafePath(path): "the path “\(path)” is not allowed"
            case let .duplicate(path): "\(path) appears twice"
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
        var uncompressedSize: UInt64
    }

    static let maxEntries = 20_000
    static let maxUncompressedSize: UInt64 = 256 << 20
    static let maxManifestSize: UInt64 = 1 << 20

    // MARK: Central directory

    /// Every entry of the ZIP's central directory.
    static func entries(of data: Data) throws(Failure) -> [Entry] {
        let bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw .notZIP }
        // The end-of-central-directory record sits in the last 64 KiB + 22.
        var eocd: Int?
        var index = bytes.count - 22
        let floor = max(0, bytes.count - 22 - 0xffff)
        while index >= floor {
            if bytes[index] == 0x50, bytes[index + 1] == 0x4b, bytes[index + 2] == 0x05, bytes[index + 3] == 0x06 {
                eocd = index
                break
            }
            index -= 1
        }
        guard let eocd else { throw .notZIP }
        let total = Int(u16(bytes, eocd + 10))
        let size = Int(u32(bytes, eocd + 12))
        let start = Int(u32(bytes, eocd + 16))
        if total == 0xffff || size == 0xffff_ffff || start == 0xffff_ffff { throw .zip64 }
        guard total <= maxEntries else { throw .tooManyEntries(total) }
        guard start + size <= eocd else { throw .truncated }

        var entries: [Entry] = []
        entries.reserveCapacity(total)
        var offset = start
        for _ in 0..<total {
            guard offset + 46 <= bytes.count, u32(bytes, offset) == 0x0201_4b50 else { throw .truncated }
            let madeBy = u16(bytes, offset + 4)
            let flags = u16(bytes, offset + 8)
            let uncompressed = u32(bytes, offset + 24)
            let nameLength = Int(u16(bytes, offset + 28))
            let extraLength = Int(u16(bytes, offset + 30))
            let commentLength = Int(u16(bytes, offset + 32))
            let external = u32(bytes, offset + 38)
            let nameStart = offset + 46
            guard nameStart + nameLength + extraLength + commentLength <= bytes.count else { throw .truncated }
            if uncompressed == 0xffff_ffff { throw .zip64 }
            let nameBytes = bytes[nameStart..<(nameStart + nameLength)]
            let name = String(decoding: nameBytes, as: UTF8.self)
            // Unix (3) or macOS (19) hosts keep the file mode in the high
            // half of the external attributes.
            let host = madeBy >> 8
            let mode = (host == 3 || host == 19) ? external >> 16 : 0
            entries.append(Entry(
                path: name,
                isDirectory: name.hasSuffix("/"),
                isSymlink: mode & 0o170000 == 0o120000,
                isEncrypted: flags & 1 != 0,
                uncompressedSize: UInt64(uncompressed)
            ))
            offset = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// The checks every entry passes before extraction.
    static func validate(_ entries: [Entry]) throws(Failure) {
        guard entries.count <= maxEntries else { throw .tooManyEntries(entries.count) }
        var seen: Set<String> = []
        var total: UInt64 = 0
        var manifest: Entry?
        for entry in entries {
            if entry.isSymlink { throw .symlink(entry.path) }
            if entry.isEncrypted { throw .encrypted(entry.path) }
            try checkPath(entry.path, isDirectory: entry.isDirectory)
            let key = entry.path.precomposedStringWithCanonicalMapping.lowercased()
            let folded = entry.isDirectory ? String(key.dropLast()) : key
            guard seen.insert(folded).inserted else { throw .duplicate(entry.path) }
            total += entry.uncompressedSize
            guard total <= maxUncompressedSize else { throw .tooLarge(total) }
            if entry.path == "manifest.json" { manifest = entry }
        }
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
    /// Returns the manifest.
    @discardableResult
    static func extract(_ archive: Data, to destination: URL) throws(Failure) -> [String: Any] {
        try validate(try entries(of: archive))
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("soprano-web-extension-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let zip = scratch.appendingPathComponent("package.zip")
        let unpacked = scratch.appendingPathComponent("unpacked", isDirectory: true)
        do {
            try fileManager.createDirectory(at: unpacked, withIntermediateDirectories: true)
            try archive.write(to: zip)
        } catch {
            throw .extractionFailed(error.localizedDescription)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", "--norsrc", "--noextattr", "--noqtn", zip.path, unpacked.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw .extractionFailed(error.localizedDescription)
        }
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw .extractionFailed(String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
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

    /// Every item under `root` is a plain file or folder inside it.
    static func checkTree(_ root: URL) throws(Failure) {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
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
        guard offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}

extension BrowserExtensionArchive.Failure: LocalizedError {
    var errorDescription: String? { description }
}
