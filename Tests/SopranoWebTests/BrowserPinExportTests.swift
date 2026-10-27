@testable import SopranoWeb
import AppKit
import Testing

/// File ▸ Export Pinned Tabs… writes a Netscape bookmarks file that reads
/// back (here, and in File ▸ Import Browser Data… as a bookmarks file) as
/// the same tree.
struct BrowserPinExportTests {
    private let added = Date(timeIntervalSince1970: 1_700_000_000)

    private func space(_ name: String, _ children: [BrowserPinNode]) -> BrowserSpace {
        BrowserSpace(name: name, color: .blue, profileID: BrowserProfile.defaultID, pinned: BrowserPinTree(children: children))
    }

    private func pin(_ title: String, _ url: String) -> BrowserPinNode {
        .pin(BrowserPin(url: url, title: title, addedAt: added))
    }

    /// Titles, addresses and nesting, one line per node.
    private func outline(_ nodes: [BrowserImportedNode], depth: Int = 0) -> [String] {
        nodes.flatMap { node -> [String] in
            let indent = String(repeating: "  ", count: depth)
            switch node {
            case let .link(link):
                return ["\(indent)\(link.title) <\(link.url)> \(link.addedAt.map { Int($0.timeIntervalSince1970) } ?? 0)"]
            case let .folder(folder):
                return ["\(indent)\(folder.name)/"] + outline(folder.children, depth: depth + 1)
            }
        }
    }

    private var work: BrowserSpace {
        space("Work", [
            .folder(BrowserPinFolder(name: "Docs & <Specs>", addedAt: added, children: [
                pin("WebKit \"Docs\"", "https://developer.apple.com/documentation/webkit?a=1&b=2"),
                .folder(BrowserPinFolder(name: "Empty", addedAt: added)),
            ])),
            pin("Swift", "https://www.swift.org/"),
        ])
    }

    @Test func oneSpaceRoundTripsThroughNetscapeHTML() {
        let html = BrowserPinExport.html(spaces: [work], allSpaces: false)
        #expect(html.hasPrefix("<!DOCTYPE NETSCAPE-Bookmark-file-1>"))
        let parsed = BrowserNetscapeBookmarks.parse(html)
        #expect(outline(parsed) == outline(BrowserImportPlanner.importedNodes(work.pinned.root.children)))
        #expect(outline(parsed) == [
            "Docs & <Specs>/",
            "  WebKit \"Docs\" <https://developer.apple.com/documentation/webkit?a=1&b=2> 1700000000",
            "  Empty/",
            "Swift <https://www.swift.org/> 1700000000",
        ])
    }

    @Test func everySpaceBecomesATopLevelFolder() {
        let reading = space("Reading", [pin("Blog", "https://webkit.org/blog/")])
        let parsed = BrowserNetscapeBookmarks.parse(BrowserPinExport.html(spaces: [work, reading], allSpaces: true))
        #expect(parsed.compactMap { node -> String? in
            if case let .folder(folder) = node { return folder.name }
            return nil
        } == ["Work", "Reading"])
        let counts = BrowserImportPlanner.nodeCounts(parsed)
        #expect(counts.pins == 3)
        #expect(counts.folders == 4)
    }

    @Test func anExportImportsBackAsTheSamePins() {
        let parsed = BrowserNetscapeBookmarks.parse(BrowserPinExport.html(spaces: [work], allSpaces: false))
        let pins = BrowserPinTree(children: BrowserImportPlanner.pinNodes(parsed))
        #expect(pins.entries().map(\.pin.url) == work.pinned.entries().map(\.pin.url))
        #expect(pins.entries().map(\.path) == work.pinned.entries().map(\.path))
    }
}
