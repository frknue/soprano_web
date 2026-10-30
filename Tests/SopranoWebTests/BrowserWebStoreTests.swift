@testable import SopranoWeb
import AppKit
import Testing

/// What an install input names, the update service's URLs and answer, and
/// the hosts a package may come from.
struct BrowserWebStoreTests {
    private let id = "ddkjiahejlhfcafbddmgiahcphecmpfh"

    @Test func inputsNameAnIdAStorePageOrAFolder() {
        let home = URL(fileURLWithPath: "/Users/someone/work", isDirectory: true)
        #expect(BrowserWebStore.source(for: id) == .webStore(id: id))
        #expect(BrowserWebStore.source(for: "  \(id.uppercased()) ") == .webStore(id: id))
        #expect(BrowserWebStore.source(for: "https://chromewebstore.google.com/detail/ublock-origin-lite/\(id)") == .webStore(id: id))
        #expect(BrowserWebStore.source(for: "https://chromewebstore.google.com/detail/\(id)?hl=de") == .webStore(id: id))
        #expect(BrowserWebStore.source(for: "https://chrome.google.com/webstore/detail/ublock/\(id)") == .webStore(id: id))
        #expect(BrowserWebStore.source(for: "http://chromewebstore.google.com/detail/\(id)") == nil)
        #expect(BrowserWebStore.source(for: "https://evil.example/detail/\(id)") == nil)
        #expect(BrowserWebStore.source(for: "https://user@chromewebstore.google.com/detail/\(id)") == nil)
        func folder(_ input: String, in directory: URL? = nil) -> String? {
            if case let .folder(url)? = BrowserWebStore.source(for: input, workingDirectory: directory) { return url.path }
            return nil
        }
        #expect(folder("ext/ublock", in: home) == "/Users/someone/work/ext/ublock")
        #expect(folder("/tmp/x/../ext") == "/tmp/ext")
        #expect(BrowserWebStore.source(for: "") == nil)
    }

    @Test func downloadAndUpdateURLsAskTheUpdateService() {
        let download = BrowserWebStore.downloadURL(id: id).absoluteString
        #expect(download.hasPrefix("https://clients2.google.com/service/update2/crx?response=redirect"))
        #expect(download.contains("acceptformat=crx3"))
        #expect(download.contains("prodversion=\(BrowserWebStore.chromeVersion)"))
        #expect(download.contains("x=id%3D\(id)%26installsource%3Dondemand%26uc"))
        let check = BrowserWebStore.updateCheckURL([(id, "2025.1.2"), ("gppongmhjkpfnbhagpmjfkannfbllamg", "6.10")]).absoluteString
        #expect(check.contains("response=updatecheck"))
        #expect(check.contains("x=id%3D\(id)%26v%3D2025.1.2%26uc"))
        #expect(check.contains("x=id%3Dgppongmhjkpfnbhagpmjfkannfbllamg%26v%3D6.10%26uc"))
    }

    @Test func theUpdateCheckAnswerListsNewVersions() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gupdate xmlns="http://www.google.com/update2/response" protocol="2.0">
          <daystart elapsed_seconds="1"/>
          <app appid="\(id)" status="ok">
            <updatecheck codebase="https://clients2.googleusercontent.com/crx/blobs/abc/extension.crx"
              hash_sha256="00ff" status="ok" version="2025.2.1"/>
          </app>
          <app appid="gppongmhjkpfnbhagpmjfkannfbllamg" status="ok"><updatecheck status="noupdate"/></app>
        </gupdate>
        """
        let updates = BrowserWebStore.parseUpdateCheck(Data(xml.utf8))
        #expect(updates.count == 1)
        #expect(updates[id]?.version == "2025.2.1")
        #expect(updates[id]?.sha256 == "00ff")
        #expect(updates[id]?.codebase.host == "clients2.googleusercontent.com")
        #expect(BrowserWebStore.parseUpdateCheck(Data("garbage".utf8)).isEmpty)
    }

    @Test func versionsCompareByNumber() {
        #expect(BrowserWebStore.isNewer("2025.10.1", than: "2025.9.30"))
        #expect(BrowserWebStore.isNewer("1.0.1", than: "1.0"))
        #expect(!BrowserWebStore.isNewer("1.0.0", than: "1.0"))
        #expect(!BrowserWebStore.isNewer("1.2", than: "1.10"))
    }

    @Test func packagesComeOnlyFromTheStoreHostsOverHTTPS() {
        #expect(BrowserWebStore.isAllowedDownload(URL(string: "https://clients2.google.com/service/update2/crx")))
        #expect(BrowserWebStore.isAllowedDownload(URL(string: "https://clients2.googleusercontent.com/crx/blobs/x.crx")))
        #expect(BrowserWebStore.isAllowedDownload(URL(string: "https://clients2.googleusercontent.com:443/x.crx")))
        #expect(!BrowserWebStore.isAllowedDownload(URL(string: "http://clients2.google.com/x")))
        #expect(!BrowserWebStore.isAllowedDownload(URL(string: "https://clients2.google.com:8443/x")))
        #expect(!BrowserWebStore.isAllowedDownload(URL(string: "https://evil.example/x.crx")))
        #expect(!BrowserWebStore.isAllowedDownload(URL(string: "https://user:pw@clients2.google.com/x")))
        #expect(!BrowserWebStore.isAllowedDownload(nil))
    }

    @Test func siteHostsDropSchemeAndWww() {
        #expect(BrowserExtensions.siteHost("https://www.Example.com/a?b") == "example.com")
        #expect(BrowserExtensions.siteHost("news.example.org") == "news.example.org")
        #expect(BrowserExtensions.sitePatterns("example.com") == ["*://example.com/*", "*://*.example.com/*"])
    }
}
