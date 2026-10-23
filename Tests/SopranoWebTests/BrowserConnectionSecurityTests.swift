@testable import SopranoWeb
import AppKit
import Testing

struct BrowserConnectionSecurityTests {
    // MARK: Challenge routing

    @Test func routesPasswordMethodsToTheSignInSheet() {
        for method in [
            NSURLAuthenticationMethodHTTPBasic,
            NSURLAuthenticationMethodHTTPDigest,
            NSURLAuthenticationMethodNTLM,
        ] {
            #expect(BrowserChallengeRoute(authenticationMethod: method) == .credentials)
        }
    }

    @Test func routesCertificatesAndLeavesTheRestToWebKit() {
        #expect(BrowserChallengeRoute(authenticationMethod: NSURLAuthenticationMethodClientCertificate) == .clientCertificate)
        #expect(BrowserChallengeRoute(authenticationMethod: NSURLAuthenticationMethodServerTrust) == .serverTrust)
        #expect(BrowserChallengeRoute(authenticationMethod: NSURLAuthenticationMethodNegotiate) == .defaultHandling)
        #expect(BrowserChallengeRoute(authenticationMethod: NSURLAuthenticationMethodHTMLForm) == .defaultHandling)
        #expect(BrowserChallengeRoute(authenticationMethod: "") == .defaultHandling)
    }

    // MARK: Error code → interstitial

    @Test func certificateErrorsBecomeExceptableInterstitials() {
        let cases: [(Int, BrowserCertificateProblem)] = [
            (NSURLErrorServerCertificateHasBadDate, .expired),
            (NSURLErrorServerCertificateNotYetValid, .notYetValid),
            (NSURLErrorServerCertificateHasUnknownRoot, .unknownIssuer),
            (NSURLErrorServerCertificateUntrusted, .untrusted),
        ]
        for (code, problem) in cases {
            let diagnosed = BrowserCertificateProblem.diagnose(domain: NSURLErrorDomain, code: code)
            #expect(diagnosed == problem)
            #expect(diagnosed?.allowsException == true)
        }
    }

    @Test func connectionAndClientCertificateFailuresCannotBeExcepted() {
        let cases: [(Int, BrowserCertificateProblem)] = [
            (NSURLErrorSecureConnectionFailed, .handshakeFailed),
            (NSURLErrorClientCertificateRejected, .clientCertificateRejected),
            (NSURLErrorClientCertificateRequired, .clientCertificateRequired),
        ]
        for (code, problem) in cases {
            let diagnosed = BrowserCertificateProblem.diagnose(domain: NSURLErrorDomain, code: code)
            #expect(diagnosed == problem)
            #expect(diagnosed?.allowsException == false)
        }
    }

    @Test func otherFailuresKeepThePlainErrorPage() {
        #expect(BrowserCertificateProblem.diagnose(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost) == nil)
        #expect(BrowserCertificateProblem.diagnose(domain: NSURLErrorDomain, code: NSURLErrorTimedOut) == nil)
        #expect(BrowserCertificateProblem.diagnose(domain: "WebKitErrorDomain", code: NSURLErrorServerCertificateUntrusted) == nil)
    }

    @Test func streamCodeAndSelfSignedLeafNameTheReason() {
        let untrusted = NSURLErrorServerCertificateUntrusted
        #expect(BrowserCertificateProblem.diagnose(
            domain: NSURLErrorDomain, code: untrusted, streamErrorCode: -9843
        ) == .wrongHost)
        #expect(BrowserCertificateProblem.diagnose(
            domain: NSURLErrorDomain, code: untrusted, streamErrorCode: -9814
        ) == .expired)
        #expect(BrowserCertificateProblem.diagnose(
            domain: NSURLErrorDomain, code: untrusted, streamErrorCode: -9813, isSelfSigned: true
        ) == .selfSigned)
        #expect(BrowserCertificateProblem.diagnose(
            domain: NSURLErrorDomain, code: untrusted, streamErrorCode: -9813
        ) == .unknownIssuer)
        #expect(BrowserCertificateProblem.diagnose(
            domain: NSURLErrorDomain, code: untrusted, isSelfSigned: true
        ) == .selfSigned)
        // A handshake failure that is really a bad chain is excepted like one.
        #expect(BrowserCertificateProblem.diagnose(
            domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed, streamErrorCode: -9807
        ) == .unknownIssuer)
    }

    // MARK: Security state

    private func state(
        _ address: String?,
        startPage: Bool = false,
        warning: Bool = false,
        errorPage: Bool = false,
        onlySecure: Bool = true,
        trust: Bool = true,
        excepted: Bool = false
    ) -> BrowserSecurityState {
        BrowserSecurityState.evaluate(
            url: address.flatMap(URL.init(string:)),
            isStartPage: startPage,
            showsCertificateWarning: warning,
            showsErrorPage: errorPage,
            hasOnlySecureContent: onlySecure,
            hasServerTrust: trust,
            isExcepted: excepted
        )
    }

    @Test func httpsStatesFollowTrustAndContent() {
        #expect(state("https://example.com") == .secure)
        #expect(state("https://example.com", onlySecure: false) == .mixedContent)
        #expect(state("https://example.com", trust: false) == .unknown)
        #expect(state("https://example.com", onlySecure: false, excepted: true) == .excepted)
    }

    @Test func plainHTTPIsNotSecureExceptOnLoopback() {
        #expect(state("http://example.com", onlySecure: false, trust: false) == .notSecure)
        #expect(state("http://localhost:8080", onlySecure: false, trust: false) == .local)
        #expect(state("http://127.0.0.1:8080", onlySecure: false, trust: false) == .local)
    }

    @Test func localAndFailedPagesHaveNoConnectionClaim() {
        #expect(state(nil, startPage: true, trust: false) == .local)
        #expect(state("file:///tmp/page.html", trust: false) == .local)
        #expect(state("about:blank", errorPage: true, trust: false) == .unknown)
        #expect(state("about:blank", warning: true, errorPage: true, trust: false) == .notSecure)
    }

    // MARK: Certificate exceptions

    @Test func exceptionMatchesHostAndFingerprintTogether() {
        let leaf = Data(repeating: 0xAB, count: 32)
        let other = Data(repeating: 0xCD, count: 32)
        var exceptions = BrowserCertificateExceptions()
        exceptions.add(host: "Router.Local", fingerprint: leaf)

        #expect(exceptions.contains(host: "router.local", fingerprint: leaf))
        #expect(exceptions.contains(host: "ROUTER.LOCAL.", fingerprint: leaf))
        #expect(!exceptions.contains(host: "router.local", fingerprint: other))
        #expect(!exceptions.contains(host: "evil.local", fingerprint: leaf))
    }

    @Test func ipv6HostsMatchWithOrWithoutBrackets() {
        let leaf = Data(repeating: 1, count: 32)
        var exceptions = BrowserCertificateExceptions()
        exceptions.add(host: "[::1]", fingerprint: leaf)
        #expect(exceptions.contains(host: "::1", fingerprint: leaf))
    }

    @Test func missingTrustNeverMatches() {
        var exceptions = BrowserCertificateExceptions()
        exceptions.add(host: "example.com", fingerprint: Data(repeating: 2, count: 32))
        #expect(!exceptions.contains(host: "example.com", trust: nil))
        #expect(!exceptions.contains(host: nil, trust: nil))
    }
}
