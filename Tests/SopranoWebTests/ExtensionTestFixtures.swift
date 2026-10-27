@testable import SopranoWeb
import AppKit
import CryptoKit
import Security

/// Generated extension packages for the CRX3 and archive tests: a stored
/// (uncompressed) ZIP writer that can produce hostile entries, a CRX3
/// writer with RSA and ECDSA proofs, and throwaway keys.
enum ExtensionTestFixtures {
    struct ZipEntry {
        var path: String
        var data: Data
        /// The Unix mode kept in the external attributes.
        var mode: UInt32 = 0o100644
        var encrypted = false

        static func file(_ path: String, _ text: String) -> ZipEntry {
            ZipEntry(path: path, data: Data(text.utf8))
        }

        static func directory(_ path: String) -> ZipEntry {
            ZipEntry(path: path, data: Data(), mode: 0o040755)
        }

        static func symlink(_ path: String, to target: String) -> ZipEntry {
            ZipEntry(path: path, data: Data(target.utf8), mode: 0o120777)
        }
    }

    static let manifest = #"{"manifest_version": 3, "name": "Fixture", "version": "1.0"}"#

    /// A ZIP with `entries` stored as given.
    static func zip(_ entries: [ZipEntry]) -> Data {
        var body = Data()
        var directory = Data()
        for entry in entries {
            let name = Data(entry.path.utf8)
            let crc = crc32(entry.data)
            let offset = UInt32(body.count)
            let flags: UInt16 = 0x0800 | (entry.encrypted ? 1 : 0)
            body.append(le32(0x0403_4b50))
            body.append(le16(20))
            body.append(le16(flags))
            body.append(le16(0))
            body.append(le16(0))
            body.append(le16(0x21))
            body.append(le32(crc))
            body.append(le32(UInt32(entry.data.count)))
            body.append(le32(UInt32(entry.data.count)))
            body.append(le16(UInt16(name.count)))
            body.append(le16(0))
            body.append(name)
            body.append(entry.data)

            directory.append(le32(0x0201_4b50))
            directory.append(le16(3 << 8 | 20))
            directory.append(le16(20))
            directory.append(le16(flags))
            directory.append(le16(0))
            directory.append(le16(0))
            directory.append(le16(0x21))
            directory.append(le32(crc))
            directory.append(le32(UInt32(entry.data.count)))
            directory.append(le32(UInt32(entry.data.count)))
            directory.append(le16(UInt16(name.count)))
            directory.append(le16(0))
            directory.append(le16(0))
            directory.append(le16(0))
            directory.append(le16(0))
            directory.append(le32(entry.mode << 16))
            directory.append(le32(offset))
            directory.append(name)
        }
        var zip = body
        let directoryOffset = UInt32(zip.count)
        zip.append(directory)
        zip.append(le32(0x0605_4b50))
        zip.append(le16(0))
        zip.append(le16(0))
        zip.append(le16(UInt16(entries.count)))
        zip.append(le16(UInt16(entries.count)))
        zip.append(le32(UInt32(directory.count)))
        zip.append(le32(directoryOffset))
        zip.append(le16(0))
        return zip
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
