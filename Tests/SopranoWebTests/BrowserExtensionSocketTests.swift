@testable import SopranoWeb
import AppKit
import Testing

/// A worker's WebSocket made by the app: what its port may say, the
/// protocols and closes it may ask for, the addresses the extension pages'
/// content security policy lets it reach, and the loopback, link-local and
/// private hosts it reaches only with host access.
struct BrowserExtensionSocketTests {
    private func url(_ text: String) -> URL { URL(string: text)! }

    @Test func socketMessagesOpenOnlyWebSocketAddresses() {
        // The posted user agent is ignored: the app sends Chrome's.
        #expect(BrowserExtensionSocket.request(from: ["open": "wss://b5n.1password.com/ws", "protocols": ["a", 3], "userAgent": "UA"])
            == .open(url: url("wss://b5n.1password.com/ws"), protocols: ["a"]))
        for address in ["https://example.com", "file:///etc/passwd", "ws://user:pw@example.com/", "ws:///nohost", "javascript:alert(1)"] {
            #expect(BrowserExtensionSocket.request(from: ["open": address]) == nil, "\(address)")
        }
        #expect(BrowserExtensionSocket.request(from: ["send": "hi"]) == .send("hi"))
        #expect(BrowserExtensionSocket.request(from: ["sendBinary": "AAE="]) == .sendBinary(Data([0, 1])))
        #expect(BrowserExtensionSocket.request(from: ["sendBinary": "%%%"]) == nil)
        #expect(BrowserExtensionSocket.request(from: ["close": 1000]) == .close(code: 1000, reason: ""))
        #expect(BrowserExtensionSocket.request(from: ["close": 4000, "reason": "bye"]) == .close(code: 4000, reason: "bye"))
        // A close `close()` would throw on is ignored.
        #expect(BrowserExtensionSocket.request(from: ["close": 1001]) == nil)
        #expect(BrowserExtensionSocket.request(from: ["close": 1000, "reason": String(repeating: "x", count: 124)]) == nil)
        #expect(BrowserExtensionSocket.request(from: "nonsense") == nil)
    }

    @Test func protocolsAreDistinctTokens() {
        for valid in [[], ["chat"], ["v1.json+x", "chat"], ["a!#$%&'*+-.^_`|~9Z"]] {
            #expect(BrowserExtensionSocket.validProtocols(valid), "\(valid)")
        }
        for invalid in [[""], ["a b"], ["a,b"], ["x\r\nOrigin: chrome-extension://other"], ["chat", "chat"], ["é"], ["a/b"], ["(x)"], ["a\"b"]] {
            #expect(!BrowserExtensionSocket.validProtocols(invalid), "\(invalid)")
        }
    }

    @Test func closesAreTheOnesAWebSocketAllows() {
        for code in [1000, 3000, 4000, 4999] {
            #expect(BrowserExtensionSocket.isValidClose(code: code, reason: ""), "\(code)")
        }
        for code in [0, 999, 1001, 1006, 1015, 2999, 5000, -1] {
            #expect(!BrowserExtensionSocket.isValidClose(code: code, reason: ""), "\(code)")
        }
        // The reason counts UTF-8 bytes: 61 two-byte letters and one more.
        #expect(BrowserExtensionSocket.isValidClose(code: 1000, reason: String(repeating: "é", count: 61) + "a"))
        #expect(!BrowserExtensionSocket.isValidClose(code: 1000, reason: String(repeating: "é", count: 62)))
    }

    @Test func connectSourcesComeFromTheExtensionPagesPolicy() {
        typealias Policy = BrowserExtensionSocketPolicy
        #expect(Policy.connectSources(in: [:]) == nil)
        #expect(Policy.connectSources(in: ["content_security_policy": ["extension_pages": "script-src 'self'"]]) == nil)
        #expect(Policy.connectSources(in: ["content_security_policy": ["sandbox": "connect-src wss:"]]) == nil)
        #expect(Policy.connectSources(in: ["content_security_policy": ["extension_pages": "script-src 'self';  CONNECT-SRC\t'self' wss://a.example ;"]])
            == ["'self'", "wss://a.example"])
        // MV2's string; `default-src` without `connect-src`; the first of a
        // repeated directive.
        #expect(Policy.connectSources(in: ["content_security_policy": "default-src 'self' wss:"]) == ["'self'", "wss:"])
        #expect(Policy.connectSources(in: ["content_security_policy": "default-src wss:; connect-src https:"]) == ["https:"])
        #expect(Policy.connectSources(in: ["content_security_policy": "connect-src ws:; connect-src wss:"]) == ["ws:"])
        // A directive without sources allows nothing; no list, anything.
        #expect(Policy.connectSources(in: ["content_security_policy": "connect-src"]) == [])
        #expect(!Policy.allows(url("wss://a.example/"), sources: []))
        #expect(Policy.allows(url("ws://127.0.0.1/"), sources: nil))
    }

    @Test func sourceExpressionsMatchSocketAddresses() {
        let table: [(source: String, address: String, matches: Bool)] = [
            ("*", "wss://a.example/", true),
            ("'self'", "wss://a.example/", false),
            ("'none'", "wss://a.example/", false),
            ("'nonce-abc'", "wss://a.example/", false),
            ("data:", "wss://a.example/", false),
            // Scheme sources, and the schemes they cover.
            ("wss:", "wss://a.example/", true),
            ("WSS:", "wss://a.example/", true),
            ("wss:", "ws://a.example/", false),
            ("ws:", "ws://a.example/", true),
            ("ws:", "wss://a.example/", true),
            ("https:", "wss://a.example/", true),
            ("https:", "ws://a.example/", false),
            ("http:", "ws://a.example/", true),
            ("http:", "wss://a.example/", true),
            // Host sources: scheme, host, wildcard subdomain.
            ("wss://push.example.com", "wss://push.example.com/socket", true),
            ("WSS://Push.Example.com", "wss://push.example.com/", true),
            ("wss://push.example.com", "ws://push.example.com/", false),
            ("ws://push.example.com", "wss://push.example.com/", true),
            ("https://push.example.com", "wss://push.example.com/", true),
            ("push.example.com", "wss://push.example.com/", true),
            ("push.example.com", "ws://push.example.com/", true),
            ("push.example.com", "wss://other.example.com/", false),
            ("wss://*.1password.com", "wss://b5n.1password.com/ws", true),
            ("wss://*.1password.com", "wss://a.b.1password.com/", true),
            ("wss://*.1password.com", "wss://1password.com/", false),
            ("wss://*.1password.com", "wss://evil-1password.com/", false),
            ("wss://*.1password.com", "wss://1password.com.evil.example/", false),
            ("wss://*", "wss://any.example/", true),
            // Ports: the scheme's default without one, exact, or any.
            ("wss://h.example", "wss://h.example:443/", true),
            ("wss://h.example", "wss://h.example:8443/", false),
            ("http://h.example", "wss://h.example/", true),
            ("ws://h.example:8080", "ws://h.example/", false),
            ("ws://h.example:8080", "ws://h.example:8080/", true),
            ("wss://h.example:*", "wss://h.example:9/", true),
            // Paths: exact, or a prefix when ending in a slash.
            ("wss://h.example/", "wss://h.example/anything", true),
            ("wss://h.example/ws/", "wss://h.example/ws/a", true),
            ("wss://h.example/ws/", "wss://h.example/other", false),
            ("wss://h.example/ws", "wss://h.example/ws", true),
            ("wss://h.example/ws", "wss://h.example/ws/a", false),
        ]
        for row in table {
            #expect(BrowserExtensionSocketPolicy.matches(url(row.address), source: row.source) == row.matches, "\(row.source) \(row.address)")
        }
    }

    @Test func hostsAreRestrictedGlobalOrNamesToResolve() {
        typealias Policy = BrowserExtensionSocketPolicy
        let restricted = [
            "localhost", "LOCALHOST.", "api.localhost", "printer.local", "nas", "",
            "0.0.0.0", "127.0.0.1", "127.255.0.9", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.1.1",
            "169.254.169.254", "100.64.0.1", "100.127.255.255",
            "::1", "[::1]", "::", "fe80::1", "fe80::1%en0", "[fe80::1%25en0]", "febf::1", "fec0::1", "fd00::1", "fc12::5",
            "::ffff:127.0.0.1", "::ffff:192.168.0.1", "::127.0.0.1",
        ]
        for host in restricted {
            #expect(Policy.kind(ofHost: host) == .restricted, "\(host)")
        }
        let global = [
            "93.184.215.14", "8.8.8.8", "172.15.255.255", "172.32.0.1", "100.63.255.255", "100.128.0.1", "192.169.0.1",
            "169.255.0.1", "11.0.0.1", "2606:4700::1111", "[2001:db8::1]", "::ffff:8.8.8.8",
        ]
        for host in global {
            #expect(Policy.kind(ofHost: host) == .global, "\(host)")
        }
        // A numeric form `inet_pton` rejects is resolved to its address.
        for host in ["push.1password.com", "example.com.", "127.1"] {
            #expect(Policy.kind(ofHost: host) == .name, "\(host)")
        }
        #expect(Policy.isRestricted([127, 0, 0, 1]))
        #expect(!Policy.isRestricted([1, 1, 1, 1]))
        #expect(Policy.isRestricted([1, 2, 3]))
        #expect(Policy.httpEquivalent(of: url("wss://h.example:8443/ws?x=1")) == url("https://h.example:8443/ws?x=1"))
        #expect(Policy.httpEquivalent(of: url("ws://localhost:3000/")) == url("http://localhost:3000/"))
    }

    @Test @MainActor func restrictedHostsNeedHostAccessAndThePolicyStillApplies() async {
        let unrestricted = BrowserExtensionSocketPolicy.make(manifest: [:]) { _ in false }
        for address in ["ws://127.0.0.1:2375/", "ws://[::1]/", "wss://printer.local/", "ws://localhost:3000/", "ws://192.168.1.10/", "ws://router/"] {
            #expect(await !unrestricted.permits(url(address)), "\(address)")
        }
        #expect(await unrestricted.permits(url("wss://93.184.215.14/")))

        // Granted the http(s) address of the same host: it opens.
        let granted = BrowserExtensionSocketPolicy.make(manifest: [:]) { $0 == URL(string: "http://localhost:3000/") }
        #expect(await granted.permits(url("ws://localhost:3000/")))
        #expect(await !granted.permits(url("ws://localhost:3001/")))

        // The manifest's policy bounds even a granted host.
        let bounded = BrowserExtensionSocketPolicy.make(
            manifest: ["content_security_policy": ["extension_pages": "connect-src 'self' wss://*.1password.com"]]
        ) { _ in true }
        #expect(await !bounded.permits(url("ws://localhost:3000/")))
        #expect(await !bounded.permits(url("wss://93.184.215.14/")))
    }
}
