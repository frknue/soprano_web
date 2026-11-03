@testable import SopranoWeb
import AppKit
import CommonCrypto
import CryptoKit
import SQLite3
import Testing

/// A Chromium `Cookies` database as Chromium writes it on macOS: `v10` +
/// AES-128-CBC under the PBKDF2 key of a "Safe Storage" password, from
/// meta version 24 with the SHA-256 of `host_key` before the value. The
/// key is the known PBKDF2-HMAC-SHA1 vector, not derived by the app.
enum ChromiumCookieFixture {
    static let password = "test-password"
    /// PBKDF2-HMAC-SHA1("test-password", "saltysalt", 1003, 16), from Python's
    /// `hashlib.pbkdf2_hmac`.
    static let keyHex = "c0ffe4c25f07f62bfc6ab011d9efa54e"

    struct Row {
        var host: String
        var name: String
        var value: String
        var path = "/"
        /// Nil: a session cookie.
        var expires: Date?
        var secure = false
        var httpOnly = false
        var sameSite = -1
        var partition = ""
        var encrypted = true
    }

    static var key: [UInt8] {
        stride(from: 0, to: keyHex.count, by: 2).map { offset in
            let start = keyHex.index(keyHex.startIndex, offsetBy: offset)
            return UInt8(keyHex[start..<keyHex.index(start, offsetBy: 2)], radix: 16)!
        }
    }

    static func encrypt(_ value: String, host: String, version: Int) -> [UInt8] {
        var plain = [UInt8]()
        if version >= 24 { plain += SHA256.hash(data: Data(host.utf8)) }
        plain += Array(value.utf8)
        var output = [UInt8](repeating: 0, count: plain.count + kCCBlockSizeAES128)
        var moved = 0
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        let key = key
        let status = CCCrypt(
            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
            key, key.count, iv, plain, plain.count, &output, output.count, &moved
        )
        precondition(status == kCCSuccess)
        return Array("v10".utf8) + output[0..<moved]
    }

    static func write(_ rows: [Row], version: Int = 24, to url: URL) throws {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        let schema = """
            CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
            INSERT INTO meta VALUES ('version', '\(version)');
            CREATE TABLE cookies(creation_utc INTEGER NOT NULL, host_key TEXT NOT NULL, top_frame_site_key TEXT NOT NULL,
              name TEXT NOT NULL, value TEXT NOT NULL, encrypted_value BLOB NOT NULL, path TEXT NOT NULL,
              expires_utc INTEGER NOT NULL, is_secure INTEGER NOT NULL, is_httponly INTEGER NOT NULL,
              last_access_utc INTEGER NOT NULL, has_expires INTEGER NOT NULL, is_persistent INTEGER NOT NULL,
              priority INTEGER NOT NULL, samesite INTEGER NOT NULL, source_scheme INTEGER NOT NULL,
              source_port INTEGER NOT NULL, last_update_utc INTEGER NOT NULL, source_type INTEGER NOT NULL,
              has_cross_site_ancestor INTEGER NOT NULL);
            """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        let insert = """
            INSERT INTO cookies VALUES (0, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, 1, ?, 2, 443, 0, 0, 0)
            """
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for row in rows {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, insert, -1, &statement, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
            defer { sqlite3_finalize(statement) }
            let blob = row.encrypted ? encrypt(row.value, host: row.host, version: version) : []
            sqlite3_bind_text(statement, 1, row.host, -1, transient)
            sqlite3_bind_text(statement, 2, row.partition, -1, transient)
            sqlite3_bind_text(statement, 3, row.name, -1, transient)
            sqlite3_bind_text(statement, 4, row.encrypted ? "" : row.value, -1, transient)
            sqlite3_bind_blob(statement, 5, blob, Int32(blob.count), transient)
            sqlite3_bind_text(statement, 6, row.path, -1, transient)
            sqlite3_bind_int64(statement, 7, row.expires.map(BrowserChromiumTime.microseconds) ?? 0)
            sqlite3_bind_int(statement, 8, row.secure ? 1 : 0)
            sqlite3_bind_int(statement, 9, row.httpOnly ? 1 : 0)
            sqlite3_bind_int(statement, 10, row.expires == nil ? 0 : 1)
            sqlite3_bind_int(statement, 11, row.expires == nil ? 0 : 1)
            sqlite3_bind_int(statement, 12, Int32(row.sameSite))
            guard sqlite3_step(statement) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
        }
    }
}

/// Chromium cookies decrypted as Chromium encrypts them: the key, the
/// host digest from meta version 24, plain values, expired and partitioned
/// rows left out, a wrong key counted, and the `HTTPCookie` WebKit gets.
struct BrowserChromiumCookieReaderTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SopranoWebCookies-\(UUID().uuidString)", isDirectory: true)
    }

    private var rows: [ChromiumCookieFixture.Row] {
        [
            .init(host: ".example.com", name: "sid", value: "s3cr3t=ü", expires: now.addingTimeInterval(86_400),
                  secure: true, httpOnly: true, sameSite: 1),
            .init(host: "app.example.com", name: "session", value: "abc"),
            .init(host: "plain.example", name: "old", value: "clear", expires: now.addingTimeInterval(60), encrypted: false),
            .init(host: ".expired.example", name: "gone", value: "x", expires: now.addingTimeInterval(-60)),
            .init(host: ".embed.example", name: "chips", value: "y", expires: now.addingTimeInterval(60),
                  partition: "https://top.example"),
        ]
    }

    @Test func theKeyIsChromiumsPBKDF2OfTheSafeStoragePassword() {
        #expect([UInt8](BrowserChromiumCookieCrypto.key(password: ChromiumCookieFixture.password)) == ChromiumCookieFixture.key)
    }

    @Test func readsUnexpiredUnpartitionedCookiesDecrypted() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Cookies")
        try ChromiumCookieFixture.write(rows, to: file)
        #expect(BrowserChromiumCookieReader.file(inProfile: directory) == file)

        let reader = BrowserChromiumCookieReader(fileURL: file)
        #expect(try reader.count(now: now) == 3)
        let read = try reader.read(key: BrowserChromiumCookieCrypto.key(password: ChromiumCookieFixture.password), now: now)
        #expect(read.undecryptable == 0)
        // Ordered by host: ".example.com", "app.example.com", "plain.example".
        #expect(read.cookies.map(\.name) == ["sid", "session", "old"])
        let sid = try #require(read.cookies.first)
        #expect(sid.value == "s3cr3t=ü")
        #expect(sid.expires.map { abs($0.timeIntervalSince(now.addingTimeInterval(86_400))) < 0.001 } == true)
        #expect(read.cookies[1].expires == nil)
        #expect(read.cookies[2].value == "clear")
    }

    @Test func aWrongKeyLeavesEncryptedValuesOut() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Network/Cookies")
        try ChromiumCookieFixture.write(rows, to: file)
        #expect(BrowserChromiumCookieReader.file(inProfile: directory) == file)
        let read = try BrowserChromiumCookieReader(fileURL: file).read(key: BrowserChromiumCookieCrypto.key(password: "other"), now: now)
        #expect(read.undecryptable == 2)
        #expect(read.cookies.map(\.name) == ["old"])
    }

    @Test func databasesBeforeVersion24HaveNoHostDigest() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Cookies")
        try ChromiumCookieFixture.write([rows[1]], version: 23, to: file)
        let read = try BrowserChromiumCookieReader(fileURL: file).read(key: Data(ChromiumCookieFixture.key), now: now)
        #expect(read.cookies.map(\.value) == ["abc"])
        // A value without the digest in a version 24 database is refused.
        let blob = Data(ChromiumCookieFixture.encrypt("abc", host: "a.example", version: 23))
        #expect(BrowserChromiumCookieCrypto.decrypt(blob, key: Data(ChromiumCookieFixture.key), hostKey: "a.example", version: 24) == nil)
    }

    @Test func cookiesKeepTheirAttributesInWebKitsForm() throws {
        let persistent = BrowserImportedCookie(
            domain: ".example.com", path: "/app", name: "sid", value: "v", expires: now,
            isSecure: true, isHTTPOnly: true, sameSite: 2
        )
        let cookie = try #require(persistent.httpCookie)
        #expect(cookie.domain == ".example.com")
        #expect(cookie.path == "/app")
        #expect(cookie.isSecure)
        #expect(cookie.isHTTPOnly)
        #expect(cookie.sameSitePolicy == .sameSiteStrict)
        #expect(cookie.expiresDate == now)
        #expect(!cookie.isSessionOnly)

        let session = BrowserImportedCookie(
            domain: "app.example.com", path: "", name: "s", value: "1", expires: nil,
            isSecure: false, isHTTPOnly: false, sameSite: -1
        )
        let sessionCookie = try #require(session.httpCookie)
        #expect(sessionCookie.isSessionOnly)
        #expect(sessionCookie.path == "/")
        #expect(sessionCookie.sameSitePolicy == nil)
    }
}
