@testable import SopranoWeb
import AppKit
import Testing

struct BrowserNetscapeBookmarksTests {
    private func link(_ url: String, _ title: String, _ seconds: TimeInterval? = nil) -> BrowserImportedNode {
        .link(BrowserImportedLink(url: url, title: title, addedAt: seconds.map { Date(timeIntervalSince1970: $0) }))
    }

    private func folder(_ name: String, _ seconds: TimeInterval? = nil, _ children: [BrowserImportedNode]) -> BrowserImportedNode {
        .folder(BrowserImportedFolder(name: name, addedAt: seconds.map { Date(timeIntervalSince1970: $0) }, children: children))
    }

    @Test func parsesAChromeStyleFileWithNestedFoldersAndEntities() {
        let html = """
            <!DOCTYPE NETSCAPE-Bookmark-file-1>
            <!-- This is an automatically generated file.
                 It will be read and overwritten.
                 DO NOT EDIT! -->
            <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
            <TITLE>Bookmarks</TITLE>
            <H1>Bookmarks</H1>
            <DL><p>
                <DT><H3 ADD_DATE="1700000000" LAST_MODIFIED="1700000100" PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>
                <DL><p>
                    <DT><A HREF="https://example.com/?a=1&amp;b=2" ADD_DATE="1700000001" ICON="data:image/png;base64,AAAA">Tom &amp; Jerry&#39;s &quot;Page&quot;</A>
                    <DT><H3>Nested</H3>
                    <DL><p>
                        <DT><A HREF="https://emoji.example/">Smile &#x1F600; &#128512;</A>
                    </DL><p>
                </DL><p>
                <DT><A HREF="https://top.example/">Top   level
                    title</A>
            </DL><p>
            """
        #expect(BrowserNetscapeBookmarks.parse(html) == [
            folder("Bookmarks bar", 1_700_000_000, [
                link("https://example.com/?a=1&b=2", "Tom & Jerry's \"Page\"", 1_700_000_001),
                folder("Nested", nil, [link("https://emoji.example/", "Smile 😀 😀")]),
            ]),
            link("https://top.example/", "Top level title"),
        ])
    }

    @Test func toleratesMalformedMarkup() {
        let html = """
            </DL>
            <dl><p>
              <dt><a href='https://lower.example/' add_date=1700000000>Lower case
              <dt><h3>Empty folder</h3>
              <dt><a>No href</a>
              <dt><a href="">Empty href</a>
              <!-- <dt><a href="https://commented.example/">Hidden</a> -->
              <dt><h3>Open folder</h3>
              <dl>
                <dt><A HREF="https://quoted.example/?q=a>b">Quoted &gt; sign</A>
                <dt><a href=https://unquoted.example/>Unquoted</a>
            """
        #expect(BrowserNetscapeBookmarks.parse(html) == [
            link("https://lower.example/", "Lower case", 1_700_000_000),
            folder("Empty folder", nil, []),
            folder("Open folder", nil, [
                link("https://quoted.example/?q=a>b", "Quoted > sign"),
                link("https://unquoted.example/", "Unquoted"),
            ]),
        ])
    }

    @Test func linksWithoutAnyListStillParse() {
        let html = #"<A HREF="https://a.example/">A</A><A HREF="https://b.example/"></A>"#
        #expect(BrowserNetscapeBookmarks.parse(html) == [
            link("https://a.example/", "A"),
            link("https://b.example/", "https://b.example/"),
        ])
        #expect(BrowserNetscapeBookmarks.parse("").isEmpty)
        #expect(BrowserNetscapeBookmarks.parse("<<<>>><DL><DT><A HREF=\"x").isEmpty)
    }

    @Test func addDateInMillisecondsOrMicrosecondsIsRecognised() {
        let html = """
            <DL><DT><A HREF="https://ms.example/" ADD_DATE="1700000000000">ms</A>
            <DT><A HREF="https://us.example/" ADD_DATE="1700000000000000">us</A>
            <DT><A HREF="https://bad.example/" ADD_DATE="soon">bad</A></DL>
            """
        #expect(BrowserNetscapeBookmarks.parse(html) == [
            link("https://ms.example/", "ms", 1_700_000_000),
            link("https://us.example/", "us", 1_700_000_000),
            link("https://bad.example/", "bad"),
        ])
    }

    @Test func writtenFilesParseBackToTheSameTree() {
        let nodes: [BrowserImportedNode] = [
            folder("Work <&> \"stuff\"", 1_600_000_000, [
                link("https://example.com/?a=1&b=<2>", "Tom & Jerry's \"Page\" <b>", 1_600_000_001),
                folder("Empty", nil, []),
                folder("Deeper", 1_600_000_002, [link("https://deep.example/", "Ünïcødé 😀")]),
            ]),
            link("https://top.example/", "Top", 1_600_000_003),
        ]
        let html = BrowserNetscapeBookmarks.html(for: nodes)
        #expect(html.hasPrefix("<!DOCTYPE NETSCAPE-Bookmark-file-1>\n"))
        #expect(html.contains("<DT><A HREF=\"https://example.com/?a=1&amp;b=&lt;2&gt;\" ADD_DATE=\"1600000001\">"))
        #expect(BrowserNetscapeBookmarks.parse(html) == nodes)
        #expect(BrowserNetscapeBookmarks.parse(data: Data(html.utf8)) == nodes)
    }

    @Test func entityDecodingIsSinglePassAndLeavesUnknownsAlone() {
        #expect(BrowserNetscapeBookmarks.decodeEntities("a &amp;lt; b") == "a &lt; b")
        #expect(BrowserNetscapeBookmarks.decodeEntities("&foo; & &amp &#xZZ; &#0;") == "&foo; & &amp &#xZZ; &#0;")
        #expect(BrowserNetscapeBookmarks.decodeEntities("&AMP;&Lt;&#65;&#x42;&nbsp;&mdash;") == "&<AB \u{2014}")
        #expect(BrowserNetscapeBookmarks.decodeEntities("no entities") == "no entities")
    }

    @Test func latin1FilesDecode() {
        let data = Data([0x3C, 0x41, 0x20, 0x48, 0x52, 0x45, 0x46, 0x3D, 0x22, 0x78, 0x3A, 0x22, 0x3E, 0xE9, 0x3C, 0x2F, 0x41, 0x3E])
        #expect(BrowserNetscapeBookmarks.parse(data: data) == [link("x:", "é")])
    }
}
