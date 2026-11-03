import CommonCrypto
import CryptoKit
import Foundation
import Security
import SQLite3

/// A cookie read from a Chromium browser, decrypted.
struct BrowserImportedCookie: Sendable, Equatable {
    /// Chromium's `host_key`: `.example.com` for a domain cookie,
    /// `example.com` for a host-only one.
    var domain: String
    var path: String
    var name: String
    var value: String
    /// Nil: a session cookie.
    var expires: Date?
    var isSecure: Bool
    var isHTTPOnly: Bool
    /// Chromium's `samesite`: -1 unspecified, 0 none, 1 lax, 2 strict.
    var sameSite: Int

    /// The cookie WebKit stores; nil when Foundation refuses its fields.
    var httpCookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: domain,
            .path: path.isEmpty ? "/" : path,
            .name: name,
            .value: value,
        ]
        if let expires {
            properties[.expires] = expires
        } else {
            properties[.discard] = "TRUE"
        }
        if isSecure { properties[.secure] = "TRUE" }
        if isHTTPOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        switch sameSite {
        case 1: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax.rawValue
        case 2: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict.rawValue
        default: break
        }
        return HTTPCookie(properties: properties)
    }
}

/// Reads a Chromium `Cookies` database (Chrome, Aside, Brave, …) without
/// writing to it: opened `immutable`, like History. Values are encrypted
/// with a key derived from the browser's "Safe Storage" keychain password
/// (`BrowserChromiumCookieCrypto`). Partitioned cookies (CHIPS: a
/// `top_frame_site_key`) and expired ones are left out. Blocking; run it
/// off the main thread.
struct BrowserChromiumCookieReader: Sendable {
    struct Read: Sendable, Equatable {
        var cookies: [BrowserImportedCookie]
        /// Rows that didn't decrypt (another key, a damaged value).
        var undecryptable: Int
    }

    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// A profile's cookie database: `Network/Cookies` (newer Chrome), else
    /// `Cookies`.
    static func file(inProfile directory: URL) -> URL? {
        for path in ["Network/Cookies", "Cookies"] {
            let url = directory.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// The cookies `read` would return (before decryption).
    func count(now: Date = Date()) throws -> Int {
        try withDatabase { db in
            let statement = try prepare(db, "SELECT count(*) FROM cookies WHERE \(try filter(db))")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, BrowserChromiumTime.microseconds(now))
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw BrowserImportError.unreadable(fileURL, Self.message(db, sqlite3_errcode(db)))
            }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    /// Every unexpired, unpartitioned cookie, decrypted with `key`
    /// (`BrowserChromiumCookieCrypto.key(password:)`).
    func read(key: Data, now: Date = Date()) throws -> Read {
        try withDatabase { db in
            let version = metaVersion(db)
            let sql = """
                SELECT host_key, name, value, encrypted_value, path, expires_utc,
                       is_secure, is_httponly, is_persistent, has_expires, samesite
                FROM cookies WHERE \(try filter(db))
                ORDER BY host_key, name
                """
            let statement = try prepare(db, sql)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, BrowserChromiumTime.microseconds(now))
            var result = Read(cookies: [], undecryptable: 0)
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else {
                    throw BrowserImportError.unreadable(fileURL, Self.message(db, step))
                }
                let host = Self.text(statement, 0)
                let encrypted = Self.blob(statement, 3)
                let value: String?
                if encrypted.isEmpty {
                    value = Self.text(statement, 2)
                } else {
                    value = BrowserChromiumCookieCrypto.decrypt(encrypted, key: key, hostKey: host, version: version)
                }
                guard let value else {
                    result.undecryptable += 1
                    continue
                }
                let persistent = sqlite3_column_int64(statement, 8) != 0 && sqlite3_column_int64(statement, 9) != 0
                result.cookies.append(BrowserImportedCookie(
                    domain: host,
                    path: Self.text(statement, 4),
                    name: Self.text(statement, 1),
                    value: value,
                    expires: persistent ? BrowserChromiumTime.date(microseconds: sqlite3_column_int64(statement, 5)) : nil,
                    isSecure: sqlite3_column_int64(statement, 6) != 0,
                    isHTTPOnly: sqlite3_column_int64(statement, 7) != 0,
                    sameSite: Int(sqlite3_column_int64(statement, 10))
                ))
            }
            return result
        }
    }

    // MARK: Private

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw BrowserImportError.missingFile(fileURL)
        }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        let code = sqlite3_open_v2(BrowserChromiumHistoryReader.immutableURI(for: fileURL), &db, flags, nil)
        defer { sqlite3_close_v2(db) }
        guard code == SQLITE_OK, let db else {
            throw BrowserImportError.unreadable(fileURL, Self.message(db, code))
        }
        return try body(db)
    }

    /// Unexpired (`?1`: now in Chromium time) and, where the schema has
    /// partitions, unpartitioned.
    private func filter(_ db: OpaquePointer) throws -> String {
        let columns = try columnNames(db)
        let unexpired = "(is_persistent = 0 OR expires_utc > ?1)"
        return columns.contains("top_frame_site_key") ? "top_frame_site_key = '' AND \(unexpired)" : unexpired
    }

    private func columnNames(_ db: OpaquePointer) throws -> Set<String> {
        let statement = try prepare(db, "SELECT name FROM pragma_table_info('cookies')")
        defer { sqlite3_finalize(statement) }
        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            names.insert(Self.text(statement, 0))
        }
        return names
    }

    /// `meta.version`: from 24 on, each decrypted value starts with the
    /// SHA-256 of its `host_key`.
    private func metaVersion(_ db: OpaquePointer) -> Int {
        guard let statement = try? prepare(db, "SELECT value FROM meta WHERE key = 'version'") else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(Self.text(statement, 0)) ?? 0
    }

    private func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw BrowserImportError.unreadable(fileURL, Self.message(db, code))
        }
        return statement
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    private static func blob(_ statement: OpaquePointer, _ column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let pointer = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: pointer, count: count)
    }

    private static func message(_ db: OpaquePointer?, _ code: Int32) -> String {
        if let db, let message = sqlite3_errmsg(db) { return "SQLite \(code): \(String(cString: message))" }
        return "SQLite \(code): \(String(cString: sqlite3_errstr(code)))"
    }
}

/// Chromium's cookie encryption on macOS: `v10` + AES-128-CBC (IV of 16
/// spaces, PKCS#7) under PBKDF2-HMAC-SHA1(password, "saltysalt", 1003
/// rounds, 16 bytes), the password being the browser's "Safe Storage"
/// keychain item.
enum BrowserChromiumCookieCrypto {
    static let salt = Array("saltysalt".utf8)
    static let rounds: UInt32 = 1003
    static let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)

    static func key(password: String) -> Data {
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let passwordBytes = Array(password.utf8)
        let status = passwordBytes.withUnsafeBufferPointer { passwordBuffer in
            passwordBuffer.withMemoryRebound(to: CChar.self) { password in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    password.baseAddress, password.count,
                    salt, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), rounds,
                    &key, key.count
                )
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 with fixed valid parameters failed: \(status)")
        return Data(key)
    }

    /// The value of a `v10` blob; nil when it isn't one, doesn't decrypt
    /// with `key`, lacks the host digest from `version` 24 on, or isn't
    /// UTF-8.
    static func decrypt(_ blob: Data, key: Data, hostKey: String, version: Int) -> String? {
        let bytes = [UInt8](blob)
        guard bytes.count > 3, bytes[0..<3] == [0x76, 0x31, 0x30] else { return nil }
        guard var plain = crypt(CCOperation(kCCDecrypt), Array(bytes[3...]), key: [UInt8](key)) else { return nil }
        if version >= 24 {
            let digest = [UInt8](SHA256.hash(data: Data(hostKey.utf8)))
            guard plain.count >= digest.count, Array(plain[0..<digest.count]) == digest else { return nil }
            plain.removeFirst(digest.count)
        }
        return String(bytes: plain, encoding: .utf8)
    }

    /// AES-128-CBC with Chromium's IV and PKCS#7 padding.
    static func crypt(_ operation: CCOperation, _ input: [UInt8], key: [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(
            operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
            key, key.count, iv,
            input, input.count,
            &output, output.count, &moved
        )
        guard status == kCCSuccess else { return nil }
        return Array(output[0..<moved])
    }
}

/// A Chromium browser's "Safe Storage" password from the login keychain.
/// Reading another app's item makes macOS ask the user (Allow, Always
/// Allow, Deny), so this runs only when an import with cookies starts, and
/// off the main thread: the call blocks until the user answers.
enum BrowserChromiumSafeStorage {
    static func password(service: String) throws -> String {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
                throw BrowserImportError.keychain("The keychain item “\(service)” holds no password")
            }
            return password
        case errSecItemNotFound:
            throw BrowserImportError.keychain("The login keychain has no “\(service)” item")
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            throw BrowserImportError.keychain("macOS didn't give Soprano Web “\(service)” (the keychain prompt was denied)")
        default:
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            throw BrowserImportError.keychain("Reading “\(service)” from the keychain failed: \(message)")
        }
    }
}
