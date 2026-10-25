import AppKit
import SecurityInterface
import WebKit

extension BrowserWindowController {
    // MARK: - Authentication challenges

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        switch BrowserChallengeRoute(authenticationMethod: space.authenticationMethod) {
        case .credentials:
            // The tab stays awake while its sign-in sheet waits.
            let ended = promptBegan(for: webView)
            credentialPrompts.requests.append(
                BrowserConnectionSecurity.CredentialRequest(challenge: challenge) { disposition, credential in
                    ended()
                    completionHandler(disposition, credential)
                }
            )
            if credentialPrompts.requests.count == 1 {
                presentNextCredentialSheet()
            }
        case .clientCertificate:
            answerClientCertificateChallenge(challenge, completion: completionHandler)
        case .serverTrust:
            if let trust = space.serverTrust,
               connectionSecurity.exceptions.contains(host: space.host, trust: trust)
            {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        case .defaultHandling:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    // MARK: - HTTP sign-in sheet

    /// Shows the sheet for the oldest waiting challenge. Every waiting
    /// challenge for the same protection space gets the same answer, so a
    /// page and its subresources ask once.
    private func presentNextCredentialSheet() {
        guard let request = credentialPrompts.requests.first else { return }
        let challenge = request.challenge
        let space = challenge.protectionSpace
        guard let window else {
            finishCredentialRequests(for: space, disposition: .performDefaultHandling, credential: nil)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Sign in to \(Self.signInHostLabel(space))"
        var lines: [String] = []
        if challenge.previousFailureCount > 0 {
            lines.append("The user name or password was incorrect. Try again.")
        }
        if let realm = space.realm, !realm.isEmpty {
            lines.append("The site says: “\(realm)”")
        }
        if space.protocol?.lowercased() == "http" {
            lines.append("This site doesn’t use a secure connection. Your user name and password can be seen by others on the network.")
        }
        alert.informativeText = lines.joined(separator: "\n\n")
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")

        let userField = NSTextField()
        userField.placeholderString = "User name"
        userField.stringValue = challenge.proposedCredential?.user ?? ""
        let passwordField = NSSecureTextField()
        passwordField.placeholderString = "Password"
        for field in [userField, passwordField] {
            field.widthAnchor.constraint(equalToConstant: 200).isActive = true
        }
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "User name:"), userField],
            [NSTextField(labelWithString: "Password:"), passwordField],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.frame.size = grid.fittingSize
        alert.accessoryView = grid
        alert.window.initialFirstResponder = userField.stringValue.isEmpty ? userField : passwordField
        credentialPrompts.sheet = BrowserCredentialSheet(
            alert: alert,
            userField: userField,
            passwordField: passwordField
        )

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.credentialPrompts.sheet = nil
            if response == .alertFirstButtonReturn {
                self.finishCredentialRequests(
                    for: space,
                    disposition: .useCredential,
                    credential: URLCredential(
                        user: userField.stringValue,
                        password: passwordField.stringValue,
                        persistence: .forSession
                    )
                )
            } else {
                // Continuing without a credential lets WebKit show the
                // server's own 401 page instead of a dead load.
                self.finishCredentialRequests(for: space, disposition: .useCredential, credential: nil)
            }
            self.presentNextCredentialSheet()
        }
    }

    private func finishCredentialRequests(
        for space: URLProtectionSpace,
        disposition: URLSession.AuthChallengeDisposition,
        credential: URLCredential?
    ) {
        let matching = credentialPrompts.requests.filter { $0.challenge.protectionSpace == space }
        credentialPrompts.requests.removeAll { $0.challenge.protectionSpace == space }
        for request in matching {
            request.completion(disposition, credential)
        }
    }

    private static func signInHostLabel(_ space: URLProtectionSpace) -> String {
        let defaultPort = space.protocol?.lowercased() == "https" ? 443 : 80
        let host = space.port == 0 || space.port == defaultPort ? space.host : "\(space.host):\(space.port)"
        return space.isProxy() ? "the proxy \(host)" : host
    }

    // MARK: - Client certificates

    /// Uses the identity chosen for this host earlier in the session, or asks
    /// with the system identity chooser. Without a matching identity in the
    /// keychain the connection continues without one.
    private func answerClientCertificateChallenge(
        _ challenge: URLAuthenticationChallenge,
        completion: @escaping BrowserConnectionSecurity.ChallengeCompletion
    ) {
        let host = BrowserCertificateExceptions.normalized(challenge.protectionSpace.host)
        if let choice = connectionSecurity.identityChoices[host] {
            Self.answer(choice, completion: completion)
            return
        }
        if connectionSecurity.pendingIdentityRequests[host] != nil {
            connectionSecurity.pendingIdentityRequests[host]?.append(completion)
            return
        }
        let identities = Self.keychainIdentities(issuers: challenge.protectionSpace.distinguishedNames)
        guard !identities.isEmpty, let window else {
            completion(.performDefaultHandling, nil)
            return
        }
        connectionSecurity.pendingIdentityRequests[host] = [completion]
        let panel = SFChooseIdentityPanel.shared()!
        panel.setAlternateButtonTitle("Continue Without")
        panel.setInformativeText("The certificate you choose is used for \(host) until Soprano Web quits.")
        let target = BrowserSheetEndTarget { [weak self] returnCode in
            guard let self else { return }
            let choice: BrowserConnectionSecurity.IdentityChoice
            if returnCode == NSApplication.ModalResponse.OK.rawValue,
               let identity = panel.identity()?.takeUnretainedValue()
            {
                choice = .identity(identity)
            } else {
                choice = .none
            }
            self.connectionSecurity.identityChoices[host] = choice
            let waiting = self.connectionSecurity.pendingIdentityRequests.removeValue(forKey: host) ?? []
            for completion in waiting {
                Self.answer(choice, completion: completion)
            }
        }
        panel.beginSheet(
            for: window,
            modalDelegate: target,
            didEnd: #selector(BrowserSheetEndTarget.sheetDidEnd(_:returnCode:contextInfo:)),
            contextInfo: nil,
            identities: identities,
            message: "\(host) asks for a certificate that identifies you."
        )
    }

    private static func answer(
        _ choice: BrowserConnectionSecurity.IdentityChoice,
        completion: BrowserConnectionSecurity.ChallengeCompletion
    ) {
        switch choice {
        case let .identity(identity):
            completion(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
        case .none:
            completion(.performDefaultHandling, nil)
        }
    }

    /// Identities in the user's keychains, limited to the issuers the server
    /// accepts when it names them.
    private static func keychainIdentities(issuers: [Data]?) -> [SecIdentity] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        if let issuers, !issuers.isEmpty {
            query[kSecMatchIssuers as String] = issuers
        }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [AnyObject]
        else { return [] }
        return items.compactMap { item in
            CFGetTypeID(item) == SecIdentityGetTypeID() ? (item as! SecIdentity) : nil
        }
    }

    // MARK: - Certificate interstitial

    /// Replaces the error page for TLS failures. Returns false when the error
    /// is not a certificate or secure-connection failure.
    func showCertificateInterstitial(_ tab: BrowserTab, error: NSError, failedURL: String) -> Bool {
        let trust = Self.peerTrust(in: error)
        guard let problem = BrowserCertificateProblem.diagnose(
            domain: error.domain,
            code: error.code,
            streamErrorCode: error.userInfo["_kCFStreamErrorCodeKey"] as? Int,
            isSelfSigned: trust.map(Self.leafIsSelfSigned) ?? false
        ),
            let url = URL(string: failedURL),
            let host = url.host, !host.isEmpty
        else { return false }

        let interstitial = BrowserCertificateInterstitial(
            token: UUID().uuidString,
            host: host,
            failedURL: url,
            problem: problem,
            trust: trust
        )
        tab.certificateInterstitial = interstitial
        tab.errorMessage = problem.explanation(host: host)
        tab.failedURL = failedURL
        tab.isShowingErrorPage = true
        tab.title = "Connection Not Private"
        tab.suppressNextHistoryRecord = true
        tab.webView.loadHTMLString(
            BrowserCertificateInterstitialPage.html(theme: theme, interstitial: interstitial),
            baseURL: nil
        )
        updateTabStrip()
        updateChrome()
        resolveLoadWaiters(
            for: tab,
            result: .failure(BrowserAutomationError.unavailable(error.localizedDescription))
        )
        return true
    }

    /// Handles a button on the interstitial. Accepted only from the tab's
    /// main frame while it shows that interstitial, with its token.
    func handleCertificateInterstitialMessage(body: [String: Any], tab: BrowserTab, frame: WKFrameInfo) {
        guard frame.isMainFrame,
              let interstitial = tab.certificateInterstitial,
              body["token"] as? String == interstitial.token,
              let action = (body["action"] as? String).flatMap(BrowserCertificateInterstitialPage.Action.init)
        else { return }
        switch action {
        case .goBack:
            tab.certificateInterstitial = nil
            if let backItem = tab.webView.backForwardList.backItem {
                tab.pendingURL = backItem.url.absoluteString
                tab.webView.goBack()
            } else {
                loadStartPage(tab)
            }
        case .showCertificate:
            guard let trust = interstitial.trust, let window else { return }
            let panel: SFCertificateTrustPanel = SFCertificateTrustPanel.shared()
            panel.setDefaultButtonTitle("Done")
            panel.setAlternateButtonTitle(nil)
            panel.setInformativeText(interstitial.problem.explanation(host: interstitial.host))
            panel.beginSheet(
                for: window,
                modalDelegate: nil,
                didEnd: nil,
                contextInfo: nil,
                trust: trust,
                message: "This connection to \(interstitial.host) is not private"
            )
        case .visitWebsite:
            guard interstitial.allowsException,
                  let trust = interstitial.trust,
                  let fingerprint = BrowserCertificateExceptions.fingerprint(of: trust)
            else { return }
            connectionSecurity.exceptions.add(host: interstitial.host, fingerprint: fingerprint)
            tab.certificateInterstitial = nil
            navigate(tab, to: interstitial.failedURL)
        }
    }

    private static func peerTrust(in error: NSError) -> SecTrust? {
        guard let value = error.userInfo[NSURLErrorFailingURLPeerTrustErrorKey] else { return nil }
        let object = value as CFTypeRef
        return CFGetTypeID(object) == SecTrustGetTypeID() ? (object as! SecTrust) : nil
    }

    private static func leafIsSelfSigned(_ trust: SecTrust) -> Bool {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              chain.count == 1,
              let leaf = chain.first,
              let issuer = SecCertificateCopyNormalizedIssuerSequence(leaf),
              let subject = SecCertificateCopyNormalizedSubjectSequence(leaf)
        else { return false }
        return (issuer as Data) == (subject as Data)
    }

    // MARK: - Security indicator

    /// Adds the observations that keep the security indicator current.
    func observeSecurity(_ tab: BrowserTab) {
        let webView = tab.webView
        tab.observations += [
            webView.observe(\.hasOnlySecureContent, options: [.new]) { [weak self, weak tab] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let tab, tab.id == self.selectedTab?.id else { return }
                    self.updateChrome()
                }
            },
            webView.observe(\.serverTrust, options: [.new]) { [weak self, weak tab] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let tab, tab.id == self.selectedTab?.id else { return }
                    self.updateChrome()
                }
            },
        ]
    }

    func securityState(for tab: BrowserTab) -> BrowserSecurityState {
        let webView = tab.webView
        let url = webView.url
        return BrowserSecurityState.evaluate(
            url: url,
            isStartPage: tab.isStartPage,
            showsCertificateWarning: tab.certificateInterstitial != nil,
            showsErrorPage: tab.errorMessage != nil,
            hasOnlySecureContent: webView.hasOnlySecureContent,
            hasServerTrust: webView.serverTrust != nil,
            isExcepted: url?.scheme?.lowercased() == "https"
                && connectionSecurity.exceptions.contains(host: url?.host, trust: webView.serverTrust)
        )
    }

    /// The security indicator's click: the connection state in a sheet, with
    /// Show Certificate when the page has a server trust and the "Block ads
    /// on this site" switch while ad blocking is on.
    func showConnectionInfo() {
        guard let tab = selectedTab, let window else { return }
        let state = securityState(for: tab)
        let interstitial = tab.certificateInterstitial
        let host = interstitial?.host ?? tab.webView.url?.host ?? ""
        let trust = interstitial?.trust ?? tab.webView.serverTrust
        let alert = NSAlert()
        alert.messageText = state.title(host: host)
        alert.informativeText = interstitial?.problem.explanation(host: host) ?? state.detail
        alert.addButton(withTitle: "Done")
        alert.accessoryView = siteBlockingAccessory(for: tab)
        if trust != nil {
            alert.addButton(withTitle: "Show Certificate")
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertSecondButtonReturn, let trust else { return }
            // The alert's sheet is still closing; attach the panel after it.
            DispatchQueue.main.async {
                guard let window = self.window else { return }
                let panel = SFCertificatePanel.shared()!
                panel.setDefaultButtonTitle("Done")
                panel.setAlternateButtonTitle(nil)
                panel.beginSheet(
                    for: window,
                    modalDelegate: nil,
                    didEnd: nil,
                    contextInfo: nil,
                    trust: trust,
                    showGroup: true
                )
            }
        }
    }
}

/// The modal delegate for SecurityInterface's selector-based sheets. It keeps
/// itself alive until the sheet ends.
@MainActor
final class BrowserSheetEndTarget: NSObject {
    private let onEnd: (Int) -> Void
    private var keepAlive: BrowserSheetEndTarget?

    init(onEnd: @escaping (Int) -> Void) {
        self.onEnd = onEnd
        super.init()
        keepAlive = self
    }

    @objc func sheetDidEnd(_ sheet: NSWindow, returnCode: Int, contextInfo: UnsafeMutableRawPointer?) {
        onEnd(returnCode)
        keepAlive = nil
    }
}
