@testable import SopranoWeb
import AppKit
import CryptoKit
import Security

/// Generated extension packages for the CRX3 and archive tests: a ZIP
/// writer (stored or deflated) that can produce hostile entries and
/// archives, a CRX3 writer with RSA and ECDSA proofs, and throwaway keys.
enum ExtensionTestFixtures {
    struct ZipEntry {
        var path: String
        var data: Data
        /// The Unix mode kept in the external attributes.
        var mode: UInt32 = 0o100644
        var encrypted = false
        /// 0 stored, 8 deflated (`data` is compressed when written).
        var method: UInt16 = 0
        /// The uncompressed size both headers declare, when it isn't the
        /// true one.
        var declaredSize: UInt32?
        /// The "made by" host: 3 Unix, 0 MS-DOS.
        var host: UInt8 = 3
        /// The name the local header gives, when it isn't `path`.
        var localPath: String?

        static func file(_ path: String, _ text: String) -> ZipEntry {
            ZipEntry(path: path, data: Data(text.utf8))
        }

        static func deflated(_ path: String, _ data: Data) -> ZipEntry {
            ZipEntry(path: path, data: data, method: 8)
        }

        static func directory(_ path: String) -> ZipEntry {
            ZipEntry(path: path, data: Data(), mode: 0o040755)
        }

        static func symlink(_ path: String, to target: String) -> ZipEntry {
            ZipEntry(path: path, data: Data(target.utf8), mode: 0o120777)
        }
    }

    static let manifest = #"{"manifest_version": 3, "name": "Fixture", "version": "1.0"}"#

    /// A ZIP with `entries` written as given and `comment` after its end
    /// record.
    static func zip(_ entries: [ZipEntry], comment: Data = Data()) -> Data {
        let (body, records) = localRecords(entries)
        let directory = records.reduce(Data(), +)
        return body + directory + endRecord(count: entries.count, directory: directory, at: body.count, comment: comment)
    }

    /// A ZIP of `entries` whose end record's comment hides a second,
    /// complete central directory and end record that list only the
    /// entries at `paths`: a reader that takes the last end record sees
    /// just those.
    static func decoyZip(_ entries: [ZipEntry], listing paths: Set<String>) -> Data {
        let (body, records) = localRecords(entries)
        let directory = records.reduce(Data(), +)
        let listed = Swift.zip(entries, records).filter { paths.contains($0.0.path) }
        let decoy = listed.map { $0.1 }.reduce(Data(), +)
        let decoyStart = body.count + directory.count + 22
        let hidden = decoy + endRecord(count: listed.count, directory: decoy, at: decoyStart, comment: Data())
        return body + directory + endRecord(count: entries.count, directory: directory, at: body.count, comment: hidden)
    }

    /// The local headers and data of `entries`, and each entry's central
    /// directory record.
    private static func localRecords(_ entries: [ZipEntry]) -> (body: Data, records: [Data]) {
        var body = Data()
        var records: [Data] = []
        for entry in entries {
            let name = Data(entry.path.utf8)
            let localName = Data((entry.localPath ?? entry.path).utf8)
            let payload = if entry.method == 8 {
                try! (entry.data as NSData).compressed(using: .zlib) as Data
            } else {
                entry.data
            }
            let crc = crc32(entry.data)
            let size = entry.declaredSize ?? UInt32(entry.data.count)
            let offset = UInt32(body.count)
            let flags: UInt16 = 0x0800 | (entry.encrypted ? 1 : 0)
            body.append(le32(0x0403_4b50))
            body.append(le16(20))
            body.append(le16(flags))
            body.append(le16(entry.method))
            body.append(le16(0))
            body.append(le16(0x21))
            body.append(le32(crc))
            body.append(le32(UInt32(payload.count)))
            body.append(le32(size))
            body.append(le16(UInt16(localName.count)))
            body.append(le16(0))
            body.append(localName)
            body.append(payload)

            var record = Data()
            record.append(le32(0x0201_4b50))
            record.append(le16(UInt16(entry.host) << 8 | 20))
            record.append(le16(20))
            record.append(le16(flags))
            record.append(le16(entry.method))
            record.append(le16(0))
            record.append(le16(0x21))
            record.append(le32(crc))
            record.append(le32(UInt32(payload.count)))
            record.append(le32(size))
            record.append(le16(UInt16(name.count)))
            record.append(le16(0))
            record.append(le16(0))
            record.append(le16(0))
            record.append(le16(0))
            record.append(le32(entry.mode << 16))
            record.append(le32(offset))
            record.append(name)
            records.append(record)
        }
        return (body, records)
    }

    /// An end-of-central-directory record for `count` entries in
    /// `directory`, which starts at `offset`.
    private static func endRecord(count: Int, directory: Data, at offset: Int, comment: Data) -> Data {
        var record = Data()
        record.append(le32(0x0605_4b50))
        record.append(le16(0))
        record.append(le16(0))
        record.append(le16(UInt16(count)))
        record.append(le16(UInt16(count)))
        record.append(le32(UInt32(directory.count)))
        record.append(le32(UInt32(offset)))
        record.append(le16(UInt16(comment.count)))
        record.append(comment)
        return record
    }

    static var validZip: Data {
        zip([
            .file("manifest.json", manifest),
            .directory("js/"),
            .file("js/background.js", "console.log('hi')"),
        ])
    }

    // MARK: Keys

    struct RSAKey {
        let privateKey: SecKey
        /// SubjectPublicKeyInfo DER.
        let publicKey: Data

        func sign(_ message: Data) -> Data {
            SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, nil)! as Data
        }
    }

    static func makeRSAKey() -> RSAKey {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        let key = SecKeyCreateRandomKey(attributes as CFDictionary, nil)!
        let pkcs1 = SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(key)!, nil)! as Data
        // SEQUENCE { SEQUENCE { rsaEncryption, NULL }, BIT STRING { 0, RSAPublicKey } }
        let algorithm = der(0x30, Data(DERReader.rsaEncryption) + Data([0x05, 0x00]))
        let spki = der(0x30, algorithm + der(0x03, Data([0]) + pkcs1))
        return RSAKey(privateKey: key, publicKey: spki)
    }

    // MARK: CRX3

    struct Proof {
        var key: Data
        var sign: (Data) -> Data
    }

    static func rsaProof(_ key: RSAKey) -> Proof {
        Proof(key: key.publicKey, sign: key.sign)
    }

    static func ecdsaProof(_ key: P256.Signing.PrivateKey) -> Proof {
        Proof(key: key.publicKey.derRepresentation) { message in
            try! key.signature(for: message).derRepresentation
        }
    }

    /// A CRX3 of `archive` declaring `crxID` (16 bytes), signed by every
    /// proof over Chrome's signed message.
    static func crx(archive: Data, crxID: Data, rsa: [Proof], ecdsa: [Proof]) -> Data {
        let signedData = field(1, crxID)
        var message = Data("CRX3 SignedData\u{0}".utf8)
        message.append(le32(UInt32(signedData.count)))
        message.append(signedData)
        message.append(archive)
        var header = Data()
        for proof in rsa {
            header.append(field(2, field(1, proof.key) + field(2, proof.sign(message))))
        }
        for proof in ecdsa {
            header.append(field(3, field(1, proof.key) + field(2, proof.sign(message))))
        }
        header.append(field(10000, signedData))
        var crx = Data("Cr24".utf8)
        crx.append(le32(3))
        crx.append(le32(UInt32(header.count)))
        crx.append(header)
        crx.append(archive)
        return crx
    }

    /// The first 16 bytes of SHA-256 of `key`: the id it proves.
    static func crxID(of key: Data) -> Data {
        Data(SHA256.hash(data: key)).prefix(16)
    }

    static func hash(_ key: Data) -> Data {
        Data(SHA256.hash(data: key))
    }

    // MARK: Encoding

    private static func field(_ number: UInt64, _ bytes: Data) -> Data {
        varint(number << 3 | 2) + varint(UInt64(bytes.count)) + bytes
    }

    private static func varint(_ value: UInt64) -> Data {
        var value = value
        var bytes = Data()
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        return bytes
    }

    private static func der(_ tag: UInt8, _ content: Data) -> Data {
        var result = Data([tag])
        let count = content.count
        if count < 0x80 {
            result.append(UInt8(count))
        } else if count < 0x100 {
            result.append(contentsOf: [0x81, UInt8(count)])
        } else {
            result.append(contentsOf: [0x82, UInt8(count >> 8), UInt8(count & 0xff)])
        }
        return result + content
    }

    static func le16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xff), UInt8(value >> 8)])
    }

    static func le32(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xff), UInt8(value >> 8 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 24)])
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = crc & 1 != 0 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1
            }
        }
        return ~crc
    }

    /// A fresh temporary folder (not created).
    static func temporaryURL(_ name: String = "fixture") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-web-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }
}
