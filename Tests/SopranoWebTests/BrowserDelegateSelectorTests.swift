@testable import SopranoWeb
import AppKit
import ObjectiveC
import Testing

/// WebKit's delegate requirements are optional Objective-C methods. A Swift
/// method with a nearly matching Swift signature is accepted by the compiler
/// but never called by WebKit, so the selectors are checked directly.
struct BrowserDelegateSelectorTests {
    @Test func exposesEveryWebKitDelegateSelector() {
        let selectors = [
            "webView:decidePolicyForNavigationAction:decisionHandler:",
            "webView:decidePolicyForNavigationResponse:decisionHandler:",
            "webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:",
            "webViewDidClose:",
            "webView:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:",
            "webView:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:",
            "webView:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:",
            "webView:runOpenPanelWithParameters:initiatedByFrame:completionHandler:",
            "webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:",
            "webView:didStartProvisionalNavigation:",
            "webView:didCommitNavigation:",
            "webView:didFinishNavigation:",
            "webView:didFailNavigation:withError:",
            "webView:didFailProvisionalNavigation:withError:",
            "webView:didReceiveServerRedirectForProvisionalNavigation:",
            "webView:didReceiveAuthenticationChallenge:completionHandler:",
            "webViewWebContentProcessDidTerminate:",
            "webView:navigationAction:didBecomeDownload:",
            "webView:navigationResponse:didBecomeDownload:",
            "download:decideDestinationUsingResponse:suggestedFilename:completionHandler:",
            "downloadDidFinish:",
            "download:didFailWithError:resumeData:",
            "download:willPerformHTTPRedirection:newRequest:decisionHandler:",
        ]

        for selector in selectors {
            #expect(
                class_getInstanceMethod(BrowserWindowController.self, NSSelectorFromString(selector)) != nil,
                "Missing WebKit delegate selector: \(selector)"
            )
        }
    }

    @Test func pageMessageHandlerExposesItsSelector() {
        #expect(class_getInstanceMethod(
            BrowserPageMessageHandler.self,
            NSSelectorFromString("userContentController:didReceiveScriptMessage:")
        ) != nil)
    }

    @Test func notificationCenterExposesItsDelegateSelectors() {
        for selector in [
            "userNotificationCenter:willPresentNotification:withCompletionHandler:",
            "userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:",
        ] {
            #expect(
                class_getInstanceMethod(BrowserNotificationCenter.self, NSSelectorFromString(selector)) != nil,
                "Missing notification delegate selector: \(selector)"
            )
        }
    }
}
