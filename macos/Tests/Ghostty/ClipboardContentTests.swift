import Foundation
import GhosttyKit
import Testing
@testable import Ghostty

struct ClipboardContentTests {
    @Test func aliasesShareOneOwnedPayload() throws {
        let plain = try #require("text/plain".withCString { strdup($0) })
        let html = try #require("text/html".withCString { strdup($0) })
        let binaryMime = try #require("application/octet-stream".withCString { strdup($0) })
        let mimes = [plain, html, binaryMime]
        let source = UnsafeMutablePointer<CChar>.allocate(capacity: 64)
        let binary = UnsafeMutablePointer<CChar>.allocate(capacity: 32)
        defer {
            mimes.forEach { free($0) }
            source.deallocate()
            binary.deallocate()
        }
        source.initialize(repeating: 0x41, count: 64)
        binary.initialize(repeating: 0x41, count: 32)

        let values = [
            ghostty_clipboard_content_s(
                mime: mimes[0], data: source, len: 64),
            ghostty_clipboard_content_s(
                mime: mimes[1], data: source, len: 64),
            ghostty_clipboard_content_s(
                mime: mimes[2], data: binary, len: 32),
        ]
        let contents = values.withUnsafeBufferPointer {
            Ghostty.ClipboardContent.from(contents: $0.baseAddress!, count: $0.count)
        }

        source[0] = 0x42
        binary[0] = 0x42

        #expect(contents.count == 3)
        #expect(contents[0].data.first == 0x41)
        #expect(contents[0].data.withUnsafeBytes { $0.baseAddress } ==
                contents[1].data.withUnsafeBytes { $0.baseAddress })
        #expect(contents[0].data.withUnsafeBytes { $0.baseAddress } !=
                contents[2].data.withUnsafeBytes { $0.baseAddress })
    }

    @Test func kittyWriteApprovalEchoesNoContents() {
        let contents = [Ghostty.ClipboardContent(
            mime: "text/plain",
            data: Data("value".utf8))]

        #expect(Ghostty.App.completionContents(contents, for: .kitty_write).isEmpty)
        #expect(Ghostty.App.completionContents(contents, for: .kitty_read).count == 1)
    }
}
