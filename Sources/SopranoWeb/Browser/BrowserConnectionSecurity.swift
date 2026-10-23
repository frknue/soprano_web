import AppKit
import CryptoKit
import Security

/// How `webView(_:didReceive:completionHandler:)` answers one challenge,
/// decided by the protection space's authentication method alone.
enum BrowserChallengeRoute: Equatable {
    /// HTTP Basic, Digest or NTLM: ask for a user name and password.
    case credentials
    /// The server asks for a certificate that identifies the user.
    case clientCertificate
    /// The server's certificate: WebKit's default evaluation unless the user
    /// excepted that host and certificate.
    case serverTrust
    case defaultHandling

    init(authenticationMethod: String) {
        switch authenticationMethod {
        case NSURLAuthenticationMethodHTTPBasic,
             NSURLAuthenticationMethodHTTPDigest,
             NSURLAuthenticationMethodNTLM:
            self = .credentials
        case NSURLAuthenticationMethodClientCertificate:
            self = .clientCertificate
        case NSURLAuthenticationMethodServerTrust:
            self = .serverTrust
        default:
            self = .defaultHandling
        }
    }
}

/// Why a TLS connection failed, in words a user can act on. Derived from the
/// `NSURLErrorDomain` code, refined by the Secure Transport code CFNetwork
/// adds as `_kCFStreamErrorCodeKey` and by whether the leaf signed itself.
enum BrowserCertificateProblem: Equatable {
    case expired
    case notYetValid
    case wrongHost
    case selfSigned
    case unknownIssuer
    case untrusted
    case handshakeFailed
    case clientCertificateRejected
    case clientCertificateRequired

    /// The TLS problem behind a failed navigation, or nil when the error is
    /// not a certificate or secure-connection failure.
    static func diagnose(
        domain: String,
        code: Int,
        streamErrorCode: Int? = nil,
        isSelfSigned: Bool = false
    ) -> BrowserCertificateProblem? {
        guard domain == NSURLErrorDomain else { return nil }
        switch code {
        case NSURLErrorClientCertificateRejected:
            return .clientCertificateRejected
        case NSURLErrorClientCertificateRequired:
            return .clientCertificateRequired
        case NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid:
            break
        default:
            return nil
        }
        switch streamErrorCode.map({ OSStatus(truncatingIfNeeded: $0) }) {
        case errSSLCertExpired: return .expired
        case errSSLCertNotYetValid: return .notYetValid
        case errSSLHostNameMismatch: return .wrongHost
        case errSSLXCertChainInvalid, errSSLUnknownRootCert, errSSLNoRootCert:
            return isSelfSigned ? .selfSigned : .unknownIssuer
        default: break
        }
        switch code {
        case NSURLErrorServerCertificateHasBadDate: return .expired
        case NSURLErrorServerCertificateNotYetValid: return .notYetValid
        case NSURLErrorServerCertificateHasUnknownRoot: return isSelfSigned ? .selfSigned : .unknownIssuer
        case NSURLErrorServerCertificateUntrusted: return isSelfSigned ? .selfSigned : .untrusted
        default: return .handshakeFailed
        }
    }

    /// Only a problem with the server's own certificate can be excepted; a
    /// failed handshake or a client-certificate refusal cannot be clicked
    /// through.
    var allowsException: Bool {
        switch self {
        case .expired, .notYetValid, .wrongHost, .selfSigned, .unknownIssuer, .untrusted:
            true
        case .handshakeFailed, .clientCertificateRejected, .clientCertificateRequired:
            false
        }
    }

    func explanation(host: String) -> String {
        switch self {
        case .expired:
            "The certificate of \(host) has expired, so nobody can vouch that this is the real site."
        case .notYetValid:
            "The certificate of \(host) is not valid yet. Check that your Mac’s date and time are correct."
        case .wrongHost:
            "The certificate was issued for a different website, not for \(host)."
        case .selfSigned:
            "\(host) signed its own certificate, so no trusted authority vouches for it."
        case .unknownIssuer:
            "The certificate of \(host) comes from an authority your Mac doesn’t trust."
        case .untrusted:
            "Your Mac doesn’t trust the certificate of \(host)."
        case .handshakeFailed:
            "A secure connection to \(host) couldn’t be set up."
        case .clientCertificateRejected:
            "\(host) rejected the certificate you sent to identify yourself."
        case .clientCertificateRequired:
            "\(host) requires a certificate that identifies you, and none was sent."
        }
    }
}

/// What the address bar's security indicator shows for the current page.
enum BrowserSecurityState: Equatable {
    /// HTTPS with a trusted certificate and only secure subresources.
    case secure
    /// HTTPS, but some subresources came over plain HTTP.
    case mixedContent
    /// Plain HTTP, or the certificate interstitial.
    case notSecure
    /// HTTPS with a certificate the user excepted this launch.
    case excepted
    /// The start page, local files and loopback HTTP.
    case local
    /// No connection to describe: an error page, or an HTTPS page that has
    /// not committed yet.
    case unknown

    static func evaluate(
        url: URL?,
        isStartPage: Bool,
        showsCertificateWarning: Bool,
        showsErrorPage: Bool,
        hasOnlySecureContent: Bool,
        hasServerTrust: Bool,
        isExcepted: Bool
    ) -> BrowserSecurityState {
        if showsCertificateWarning { return .notSecure }
        if isStartPage { return .local }
        if showsErrorPage { return .unknown }
        switch url?.scheme?.lowercased() {
        case "http":
            return BrowserAddressResolver.isLocal(url) ? .local : .notSecure
        case "https":
            if isExcepted { return .excepted }
            if !hasServerTrust { return .unknown }
            return hasOnlySecureContent ? .secure : .mixedContent
        default:
            return .local
        }
    }

    var symbolName: String {
        switch self {
        case .secure: "lock.fill"
        case .mixedContent: "lock.trianglebadge.exclamationmark.fill"
        case .notSecure: "exclamationmark.triangle.fill"
        case .excepted: "lock.slash.fill"
        case .local, .unknown: "globe"
        }
    }

    var toolTip: String {
        switch self {
        case .secure: "Secure connection"
        case .mixedContent: "Parts of this page are not secure"
        case .notSecure: "Connection is not secure"
        case .excepted: "Certificate not trusted"
        case .local: "Local page"
        case .unknown: "No connection details"
        }
    }

    func tint(in colors: ThemeColors) -> NSColor {
        self == .excepted ? colors.danger : colors.textMuted
    }

    func title(host: String) -> String {
        switch self {
        case .secure: "Connection to \(host) is secure"
        case .mixedContent: "Parts of \(host) are not secure"
        case .notSecure: "Connection to \(host) is not secure"
        case .excepted: "\(host) uses a certificate you excepted"
        case .local: "Local page"
        case .unknown: "No connection details"
        }
    }

    var detail: String {
        switch self {
        case .secure:
            "The connection is encrypted and the certificate is trusted."
        case .mixedContent:
            "The page is encrypted, but it loads some content over plain HTTP that others on the network can read or change."
        case .notSecure:
            "Information you send or receive travels unencrypted. Don’t enter passwords or payment details."
        case .excepted:
            "You chose to visit the site although its certificate isn’t trusted. The exception lasts until Soprano Web quits."
        case .local:
            "This page comes from Soprano Web or your Mac, not from the network."
        case .unknown:
            "The page is loading or couldn’t be opened."
        }
    }
}

/// Certificates the user accepted from the interstitial, kept in memory for
/// this launch only. An exception covers one host and one leaf certificate
/// (SHA-256 of its DER bytes); a different certificate on the same host is
/// evaluated normally again.
struct BrowserCertificateExceptions {
    private struct Entry: Hashable {
        let host: String
        let fingerprint: Data
    }

    private var entries: Set<Entry> = []

    mutating func add(host: String, fingerprint: Data) {
        entries.insert(Entry(host: Self.normalized(host), fingerprint: fingerprint))
    }

    func contains(host: String, fingerprint: Data) -> Bool {
        entries.contains(Entry(host: Self.normalized(host), fingerprint: fingerprint))
    }

    func contains(host: String?, trust: SecTrust?) -> Bool {
        guard let host, let trust, let fingerprint = Self.fingerprint(of: trust) else { return false }
        return contains(host: host, fingerprint: fingerprint)
    }

    static func normalized(_ host: String) -> String {
        var host = host.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if host.hasSuffix(".") {
            host.removeLast()
        }
        return host
    }

    /// SHA-256 of the leaf certificate's DER encoding.
    static func fingerprint(of trust: SecTrust) -> Data? {
        guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            return nil
        }
        return Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data))
    }
}

/// Connection security state shared by the window's tabs: certificate
/// exceptions, the client identity chosen per host, and the queue of HTTP
/// sign-in challenges waiting for the sheet. Nothing here is persisted.
@MainActor
final class BrowserConnectionSecurity {
    typealias ChallengeCompletion = @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void

    enum IdentityChoice {
        case identity(SecIdentity)
        /// The user dismissed the chooser: continue without a certificate.
        case none
    }

    struct CredentialRequest {
        let challenge: URLAuthenticationChallenge
        let completion: ChallengeCompletion
    }

    var exceptions = BrowserCertificateExceptions()
    var identityChoices: [String: IdentityChoice] = [:]
    var pendingIdentityRequests: [String: [ChallengeCompletion]] = [:]
    /// The first request is the one the sheet shows.
    var credentialRequests: [CredentialRequest] = []
    var credentialSheet: BrowserCredentialSheet?
}

/// The HTTP sign-in sheet's alert and fields, kept so the snapshot harness
/// can fill and submit it like a user would.
@MainActor
final class BrowserCredentialSheet {
    let alert: NSAlert
    let userField: NSTextField
    let passwordField: NSSecureTextField

    init(alert: NSAlert, userField: NSTextField, passwordField: NSSecureTextField) {
        self.alert = alert
        self.userField = userField
        self.passwordField = passwordField
    }
}

/// The certificate interstitial a tab shows. Its buttons post
/// `certificateInterstitial` messages carrying `token`; the controller acts
/// on them only while this value is set on the tab and the token matches.
struct BrowserCertificateInterstitial {
    let token: String
    let host: String
    let failedURL: URL
    let problem: BrowserCertificateProblem
    let trust: SecTrust?

    var allowsException: Bool {
        problem.allowsException && trust != nil
    }
}
