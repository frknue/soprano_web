@testable import SopranoWeb
import AppKit
import Testing

struct BrowserContentDispositionTests {
    @Test func attachmentDownloadsWhateverTheParameters() {
        #expect(BrowserContentDisposition.isAttachment("attachment"))
        #expect(BrowserContentDisposition.isAttachment("attachment; filename=\"report.pdf\""))
        #expect(BrowserContentDisposition.isAttachment("ATTACHMENT;filename*=UTF-8''r%C3%A9sum%C3%A9.pdf"))
        #expect(BrowserContentDisposition.isAttachment("  Attachment ; filename=a.txt"))
    }

    @Test func inlineAndMissingHeadersRender() {
        #expect(!BrowserContentDisposition.isAttachment(nil))
        #expect(!BrowserContentDisposition.isAttachment(""))
        #expect(!BrowserContentDisposition.isAttachment("inline"))
        #expect(!BrowserContentDisposition.isAttachment("inline; filename=\"attachment.pdf\""))
        #expect(!BrowserContentDisposition.isAttachment("form-data; name=\"attachment\""))
    }

    @Test func malformedTypesAreNotAttachments() {
        #expect(!BrowserContentDisposition.isAttachment("; filename=attachment"))
        #expect(!BrowserContentDisposition.isAttachment("attachment filename=a.txt"))
        #expect(!BrowserContentDisposition.isAttachment("\"attachment\""))
        #expect(!BrowserContentDisposition.isAttachment("attachments"))
        #expect(BrowserContentDisposition.dispositionType("Inline ; x=1") == "inline")
    }
}
