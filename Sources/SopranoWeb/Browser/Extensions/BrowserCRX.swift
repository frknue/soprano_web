import CryptoKit
import Foundation
import Security

/// Chrome extension ids: 32 letters `a`…`p`, the first 16 bytes of a
/// SHA-256 written one nibble per letter.
enum BrowserExtensionID {
    static func isValid(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { $0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "p") }
    }

    /// The id the first 16 bytes of `bytes` spell.
    static func letters<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        var result = ""
        result.reserveCapacity(32)
        for byte in bytes.prefix(16) {
            result.unicodeScalars.append(Unicode.Scalar(UInt8(ascii: "a") + (byte >> 4)))
            result.unicodeScalars.append(Unicode.Scalar(UInt8(ascii: "a") + (byte & 0x0f)))
        }
        return result
    }

    /// The id a public key (X.509 SubjectPublicKeyInfo DER) proves.
    static func id(ofPublicKey key: Data) -> String {
        letters(SHA256.hash(data: key))
    }

    /// An unpacked folder's id: its manifest's `key` (base64 SPKI) when it
    /// has one, as Chrome does, else a hash of the folder's path.
    static func id(forUnpackedManifest manifest: [String: Any], folder: URL) -> String {
        if let key = manifest["key"] as? String,
           let data = Data(base64Encoded: key.filter { !$0.isWhitespace })
        {
            return id(ofPublicKey: data)
        }
        return letters(SHA256.hash(data: Data(folder.standardizedFileURL.path.utf8)))
    }
}

/// A CRX3 package (Chromium `components/crx_file/crx3.proto`):
/// `"Cr24"`, version 3, the header length, the `CrxFileHeader` protobuf,
/// then the ZIP. `verify` checks it the way Chrome checks a Web Store
/// install (`CRX3_WITH_PUBLISHER_PROOF`).
struct BrowserCRX3: Sendable {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case notCRX
        case unsupportedVersion(UInt32)
        case headerTooLarge(Int)
        case truncated
        case malformedHeader(String)
        case zipMarkerInHeader
        case missingSignedData
        case badCrxID
        case idMismatch(expected: String, found: String)
        case missingDeveloperProof
        case missingPublisherProof
        case badSignature(String)
        case unsupportedKey(String)

        var description: String {
            switch self {
            case .notCRX: "not a CRX package"
            case let .unsupportedVersion(version): "CRX version \(version) is not supported (only CRX3)"
            case let .headerTooLarge(size): "the CRX header is too large (\(size) bytes)"
            case .truncated: "the CRX package is truncated"
            case let .malformedHeader(reason): "the CRX header is malformed: \(reason)"
            case .zipMarkerInHeader: "the CRX header contains ZIP markers"
            case .missingSignedData: "the CRX header has no signed data"
            case .badCrxID: "the CRX header's extension id is not 16 bytes"
            case let .idMismatch(expected, found): "the package is extension \(found), not \(expected)"
            case .missingDeveloperProof: "no signature proves the extension id"
            case .missingPublisherProof: "the Chrome Web Store's signature is missing"
            case let .badSignature(kind): "a \(kind) signature does not verify"
            case let .unsupportedKey(kind): "a \(kind) public key can't be read"
            }
        }
    }

    struct Proof: Equatable, Sendable {
        /// X.509 SubjectPublicKeyInfo, DER.
        var publicKey: Data
        var signature: Data
    }

    /// SHA-256 of the Chrome Web Store's publisher key (`ecdsa_2017_public`,
    /// Chromium `crx_verifier.cc` `kPublisherKeyHash`).
    static let webStorePublisherKeyHash = Data([
        0x61, 0xf7, 0xf2, 0xa6, 0xbf, 0xcf, 0x74, 0xcd, 0x0b, 0xc1, 0xfe, 0x24, 0x97, 0xcc, 0x9b, 0x04,
        0x25, 0x4c, 0x65, 0x8f, 0x79, 0xf2, 0x14, 0x53, 0x92, 0x86, 0x7e, 0xa8, 0x36, 0x63, 0x67, 0xcf,
    ])
    static let magic = Data("Cr24".utf8)
    /// Every proof signs this prefix, the signed header's length (LE32),
    /// the signed header and the archive.
    static let signaturePrefix = Data("CRX3 SignedData\u{0}".utf8)
    static let maxHeaderSize = 4 << 20

    var rsaProofs: [Proof]
    var ecdsaProofs: [Proof]
    /// The serialized `SignedData` (header field 10000).
    var signedHeaderData: Data
    /// `SignedData.crx_id`: 16 bytes.
    var crxID: Data
    /// The ZIP after the header.
    var archive: Data

    /// The extension id the header declares.
    var declaredID: String { BrowserExtensionID.letters(crxID) }

    static func parse(_ data: Data) throws(Failure) -> BrowserCRX3 {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, Data(bytes[0..<4]) == magic else { throw .notCRX }
        let version = littleEndian32(bytes, at: 4)
        guard version == 3 else { throw .unsupportedVersion(version) }
        let headerSize = Int(littleEndian32(bytes, at: 8))
        guard headerSize <= maxHeaderSize else { throw .headerTooLarge(headerSize) }
        guard bytes.count - 12 >= headerSize else { throw .truncated }
        let header = Array(bytes[12..<(12 + headerSize)])
        // Chromium refuses a header a ZIP reader could mistake for the
        // archive's end (EOCD, ZIP64 EOCD locator).
        if contains(header, [0x50, 0x4b, 0x05, 0x06]) || contains(header, [0x50, 0x4b, 0x06, 0x07]) {
            throw .zipMarkerInHeader
        }

        var rsaFields: [[UInt8]] = []
        var ecdsaFields: [[UInt8]] = []
        var signedFields: [[UInt8]] = []
        var reader = ProtobufReader(header)
        do {
            while let (field, wireType) = try reader.nextField() {
                switch (field, wireType) {
                case (2, 2): rsaFields.append(try reader.bytes())
                case (3, 2): ecdsaFields.append(try reader.bytes())
                case (10000, 2): signedFields.append(try reader.bytes())
                default: try reader.skip(wireType)
                }
            }
        } catch {
            throw .malformedHeader("\(error)")
        }
        guard signedFields.count <= 1 else { throw .malformedHeader("signed data twice") }
        guard let signedBytes = signedFields.first else { throw .missingSignedData }
        let signed = Data(signedBytes)
        let rsa = try rsaFields.map { (fields) throws(Failure) in try proof(fields) }
        let ecdsa = try ecdsaFields.map { (fields) throws(Failure) in try proof(fields) }

        var crxIDs: [[UInt8]] = []
        var signedReader = ProtobufReader(signedBytes)
        do {
            while let (field, wireType) = try signedReader.nextField() {
                if field == 1, wireType == 2 {
                    crxIDs.append(try signedReader.bytes())
                } else {
                    try signedReader.skip(wireType)
                }
            }
        } catch {
            throw .malformedHeader("\(error)")
        }
        guard crxIDs.count <= 1 else { throw .malformedHeader("crx_id twice") }
        guard let crxBytes = crxIDs.first, crxBytes.count == 16 else { throw .badCrxID }
        let crxID = Data(crxBytes)
        return BrowserCRX3(
            rsaProofs: rsa,
            ecdsaProofs: ecdsa,
            signedHeaderData: signed,
            crxID: crxID,
            archive: Data(bytes[(12 + headerSize)...])
        )
    }

    /// What every proof signs.
    var signedMessage: Data {
        var message = Self.signaturePrefix
        let count = UInt32(signedHeaderData.count)
        message.append(contentsOf: [UInt8(count & 0xff), UInt8(count >> 8 & 0xff), UInt8(count >> 16 & 0xff), UInt8(count >> 24)])
        message.append(signedHeaderData)
        message.append(archive)
        return message
    }

    /// Chrome's rule: the header names `expectedID` (when given), every
    /// RSA and ECDSA proof verifies over `signedMessage`, one proof's key
    /// hashes to the id (the developer's), and with `publisherKeyHashes`
    /// one proof's key hashes to one of them (the Web Store's). Returns
    /// the archive.
    func verify(expectedID: String?, publisherKeyHashes: Set<Data>?) throws(Failure) -> Data {
        if let expectedID, expectedID != declaredID {
            throw .idMismatch(expected: expectedID, found: declaredID)
        }
        let message = signedMessage
        var provesID = false
        var hasPublisher = false
        for proof in rsaProofs {
            try Self.verifyRSA(proof, message: message)
            let hash = Data(SHA256.hash(data: proof.publicKey))
            provesID = provesID || hash.prefix(16) == crxID
            hasPublisher = hasPublisher || publisherKeyHashes?.contains(hash) == true
        }
        for proof in ecdsaProofs {
            try Self.verifyECDSA(proof, message: message)
            let hash = Data(SHA256.hash(data: proof.publicKey))
            provesID = provesID || hash.prefix(16) == crxID
            hasPublisher = hasPublisher || publisherKeyHashes?.contains(hash) == true
        }
        guard provesID else { throw .missingDeveloperProof }
        if publisherKeyHashes != nil, !hasPublisher { throw .missingPublisherProof }
        return archive
    }

    private static func verifyRSA(_ proof: Proof, message: Data) throws(Failure) {
        guard let pkcs1 = DERReader.rsaPublicKey(fromSPKI: proof.publicKey) else { throw .unsupportedKey("RSA") }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, nil) else {
            throw .unsupportedKey("RSA")
        }
        guard SecKeyVerifySignature(
            key,
            .rsaSignatureMessagePKCS1v15SHA256,
            message as CFData,
            proof.signature as CFData,
            nil
        ) else { throw .badSignature("RSA") }
    }

    private static func verifyECDSA(_ proof: Proof, message: Data) throws(Failure) {
        guard let key = try? P256.Signing.PublicKey(derRepresentation: proof.publicKey) else {
            throw .unsupportedKey("ECDSA")
        }
        guard let signature = try? P256.Signing.ECDSASignature(derRepresentation: proof.signature),
              key.isValidSignature(signature, for: message)
        else { throw .badSignature("ECDSA") }
    }

    private static func proof(_ bytes: [UInt8]) throws(Failure) -> Proof {
        var reader = ProtobufReader(bytes)
        var key: Data?
        var signature: Data?
        do {
            while let (field, wireType) = try reader.nextField() {
                switch (field, wireType) {
                case (1, 2): key = Data(try reader.bytes())
                case (2, 2): signature = Data(try reader.bytes())
                default: try reader.skip(wireType)
                }
            }
        } catch {
            throw .malformedHeader("\(error)")
        }
        guard let key, let signature, !key.isEmpty, !signature.isEmpty else {
            throw .malformedHeader("a proof without key or signature")
        }
        return Proof(publicKey: key, signature: signature)
    }

    private static func littleEndian32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] {
            if Array(haystack[start..<(start + needle.count)]) == needle { return true }
        }
        return false
    }
}

/// A strict protobuf wire-format reader: bounded varints, lengths that
/// stay inside the buffer, no groups.
struct ProtobufReader {
    enum Failure: Error, Equatable {
        case truncated
        case badVarint
        case unsupportedWireType(UInt8)
    }

    private let buffer: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) {
        buffer = bytes
    }

    /// The next field's number and wire type; nil at the end.
    mutating func nextField() throws(Failure) -> (UInt64, UInt8)? {
        guard offset < buffer.count else { return nil }
        let key = try varint()
        let field = key >> 3
        guard field > 0 else { throw .badVarint }
        return (field, UInt8(key & 7))
    }

    mutating func varint() throws(Failure) -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, to: 70, by: 7) {
            guard offset < buffer.count else { throw .truncated }
            let byte = buffer[offset]
            offset += 1
            guard shift < 63 || byte <= 1 else { throw .badVarint }
            value |= UInt64(byte & 0x7f) << UInt64(shift)
            if byte & 0x80 == 0 { return value }
        }
        throw .badVarint
    }

    mutating func bytes() throws(Failure) -> [UInt8] {
        let length = try varint()
        guard length <= UInt64(buffer.count - offset) else { throw .truncated }
        let end = offset + Int(length)
        defer { offset = end }
        return Array(buffer[offset..<end])
    }

    mutating func skip(_ wireType: UInt8) throws(Failure) {
        switch wireType {
        case 0: _ = try varint()
        case 1: try advance(8)
        case 2: _ = try bytes()
        case 5: try advance(4)
        default: throw .unsupportedWireType(wireType)
        }
    }

    private mutating func advance(_ count: Int) throws(Failure) {
        guard buffer.count - offset >= count else { throw .truncated }
        offset += count
    }
}

/// Just enough DER to take the PKCS#1 `RSAPublicKey` out of an RSA
/// SubjectPublicKeyInfo (what `SecKeyCreateWithData` takes).
enum DERReader {
    /// `1.2.840.113549.1.1.1` rsaEncryption.
    static let rsaEncryption: [UInt8] = [0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01]

    static func rsaPublicKey(fromSPKI spki: Data) -> Data? {
        let bytes = [UInt8](spki)
        var offset = 0
        guard let outer = element(bytes, &offset, tag: 0x30), offset == bytes.count else { return nil }
        var inner = 0
        guard let algorithm = element(outer, &inner, tag: 0x30),
              algorithm.starts(with: rsaEncryption),
              let bitString = element(outer, &inner, tag: 0x03),
              inner == outer.count,
              bitString.first == 0
        else { return nil }
        return Data(bitString.dropFirst())
    }

    /// The contents of the element at `offset` when its tag is `tag`;
    /// `offset` moves past it.
    private static func element(_ bytes: [UInt8], _ offset: inout Int, tag: UInt8) -> [UInt8]? {
        guard offset + 2 <= bytes.count, bytes[offset] == tag else { return nil }
        var cursor = offset + 1
        var length = Int(bytes[cursor])
        cursor += 1
        if length & 0x80 != 0 {
            let count = length & 0x7f
            guard (1...4).contains(count), cursor + count <= bytes.count else { return nil }
            length = 0
            for byte in bytes[cursor..<(cursor + count)] {
                length = length << 8 | Int(byte)
            }
            cursor += count
        }
        guard length >= 0, cursor + length <= bytes.count else { return nil }
        offset = cursor + length
        return Array(bytes[cursor..<(cursor + length)])
    }
}

extension BrowserCRX3.Failure: LocalizedError {
    var errorDescription: String? { description }
}
