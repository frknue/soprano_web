@testable import SopranoWeb
import AppKit
import CryptoKit
import Testing

/// CRX3 parsing and Chrome's store-install verification over generated
/// packages: a developer RSA key whose hash is the id, and a stand-in
/// publisher ECDSA key (the real one is Google's).
struct BrowserCRXTests {
    private typealias F = ExtensionTestFixtures

    private struct Package {
        var developer: F.RSAKey
        var publisher: P256.Signing.PrivateKey
        var archive: Data

        var id: String { BrowserExtensionID.id(ofPublicKey: developer.publicKey) }
        var publisherHash: Data { F.hash(publisher.publicKey.derRepresentation) }

        func crx(archive: Data? = nil, withPublisher: Bool = true, crxID: Data? = nil) -> Data {
            F.crx(
                archive: archive ?? self.archive,
                crxID: crxID ?? F.crxID(of: developer.publicKey),
                rsa: [F.rsaProof(developer)],
                ecdsa: withPublisher ? [F.ecdsaProof(publisher)] : []
            )
        }
    }

    private func package() -> Package {
        Package(developer: F.makeRSAKey(), publisher: P256.Signing.PrivateKey(), archive: F.validZip)
    }

    @Test func idsAreSixteenHashBytesAsLettersAToP() {
        #expect(BrowserExtensionID.letters([0x00, 0x1f, 0xff] + Array(repeating: 0, count: 13)) == "aabppp" + String(repeating: "a", count: 26))
        #expect(BrowserExtensionID.isValid("ddkjiahejlhfcafbddmgiahcphecmpfh"))
        #expect(!BrowserExtensionID.isValid("ddkjiahejlhfcafbddmgiahcphecmpfq"))
        #expect(!BrowserExtensionID.isValid("DDKJIAHEJLHFCAFBDDMGIAHCPHECMPFH"))
        #expect(!BrowserExtensionID.isValid("ddkjiahejlhfcafbddmgiahcphecmpf"))
    }

    @Test func aValidStorePackageVerifiesAndYieldsItsZip() throws {
        let package = package()
        let crx = try BrowserCRX3.parse(package.crx())
        #expect(crx.declaredID == package.id)
        #expect(crx.rsaProofs.count == 1 && crx.ecdsaProofs.count == 1)
        let archive = try crx.verify(expectedID: package.id, publisherKeyHashes: [package.publisherHash])
        #expect(archive == package.archive)
        #expect(try BrowserExtensionArchive.entries(of: archive).map(\.path).contains("manifest.json"))
    }

    @Test func aTamperedZipFailsEveryProof() throws {
        let package = package()
        var bytes = [UInt8](package.crx())
        bytes[bytes.count - 30] ^= 0x01
        let crx = try BrowserCRX3.parse(Data(bytes))
        #expect(throws: BrowserCRX3.Failure.badSignature("RSA")) {
            try crx.verify(expectedID: package.id, publisherKeyHashes: [package.publisherHash])
        }
    }

    @Test func aStoreInstallNeedsThePublisherProof() throws {
        let package = package()
        let unsigned = try BrowserCRX3.parse(package.crx(withPublisher: false))
        #expect(throws: BrowserCRX3.Failure.missingPublisherProof) {
            try unsigned.verify(expectedID: package.id, publisherKeyHashes: [package.publisherHash])
        }
        // Without the store's rule (an unpacked developer build) the
        // developer proof is enough.
        #expect(try unsigned.verify(expectedID: package.id, publisherKeyHashes: nil) == package.archive)
        // Only the Chrome Web Store's own key counts as the publisher.
        let signed = try BrowserCRX3.parse(package.crx())
        #expect(throws: BrowserCRX3.Failure.missingPublisherProof) {
            try signed.verify(expectedID: package.id, publisherKeyHashes: [BrowserCRX3.webStorePublisherKeyHash])
        }
    }

    @Test func thePackageMustBeTheRequestedExtension() throws {
        let package = package()
        let crx = try BrowserCRX3.parse(package.crx())
        let other = String(repeating: "b", count: 32)
        #expect(throws: BrowserCRX3.Failure.idMismatch(expected: other, found: package.id)) {
            try crx.verify(expectedID: other, publisherKeyHashes: [package.publisherHash])
        }
    }

    @Test func theDeclaredIDMustBeProvedByAKey() throws {
        let package = package()
        // Signed correctly, but the id claims a key that signed nothing.
        let claimed = Data(repeating: 0x11, count: 16)
        let crx = try BrowserCRX3.parse(package.crx(crxID: claimed))
        #expect(throws: BrowserCRX3.Failure.missingDeveloperProof) {
            try crx.verify(expectedID: nil, publisherKeyHashes: [package.publisherHash])
        }
    }

    @Test func aProofByAnUnrelatedKeyFailsTheWholePackage() throws {
        let package = package()
        let stranger = P256.Signing.PrivateKey()
        let forged = F.Proof(key: stranger.publicKey.derRepresentation) { _ in
            try! stranger.signature(for: Data("something else".utf8)).derRepresentation
        }
        let data = F.crx(
            archive: package.archive,
            crxID: F.crxID(of: package.developer.publicKey),
            rsa: [F.rsaProof(package.developer)],
            ecdsa: [F.ecdsaProof(package.publisher), forged]
        )
        #expect(throws: BrowserCRX3.Failure.badSignature("ECDSA")) {
            try BrowserCRX3.parse(data).verify(expectedID: package.id, publisherKeyHashes: [package.publisherHash])
        }
    }

    @Test func malformedPackagesAreRefusedBeforeVerification() {
        #expect(throws: BrowserCRX3.Failure.notCRX) { try BrowserCRX3.parse(Data("PK\u{3}\u{4}notacrx".utf8)) }
        var version2 = Data("Cr24".utf8)
        version2.append(ExtensionTestFixtures.le32(2))
        version2.append(ExtensionTestFixtures.le32(0))
        #expect(throws: BrowserCRX3.Failure.unsupportedVersion(2)) { try BrowserCRX3.parse(version2) }
        var truncated = Data("Cr24".utf8)
        truncated.append(ExtensionTestFixtures.le32(3))
        truncated.append(ExtensionTestFixtures.le32(500))
        #expect(throws: BrowserCRX3.Failure.truncated) { try BrowserCRX3.parse(truncated) }
        // A header holding a ZIP end-of-directory marker.
        var marked = Data("Cr24".utf8)
        marked.append(ExtensionTestFixtures.le32(3))
        marked.append(ExtensionTestFixtures.le32(6))
        marked.append(Data([0x22, 0x04, 0x50, 0x4b, 0x05, 0x06]))
        #expect(throws: BrowserCRX3.Failure.zipMarkerInHeader) { try BrowserCRX3.parse(marked) }
        // No signed data.
        var unsigned = Data("Cr24".utf8)
        unsigned.append(ExtensionTestFixtures.le32(3))
        unsigned.append(ExtensionTestFixtures.le32(0))
        #expect(throws: BrowserCRX3.Failure.missingSignedData) { try BrowserCRX3.parse(unsigned) }
    }

    @Test func protobufLengthsMustStayInsideTheHeader() {
        var reader = ProtobufReader([0x0a, 0x05, 0x01])
        #expect(throws: ProtobufReader.Failure.self) {
            while let (_, wireType) = try reader.nextField() { try reader.skip(wireType) }
        }
        var groups = ProtobufReader([0x0b])
        #expect(throws: ProtobufReader.Failure.unsupportedWireType(3)) {
            while let (_, wireType) = try groups.nextField() { try groups.skip(wireType) }
        }
    }
}
