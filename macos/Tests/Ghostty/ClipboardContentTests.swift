import Foundation
import GhosttyKit
import Testing
@testable import Ghostty

struct ClipboardContentTests {
    @Test func aliasesShareOneOwnedPayload() {
        var source = [UInt8](repeating: 0x41, count: 64)
        let contents = source.withUnsafeBytes { bytes in
            "text/plain".withCString { plain in
                "text/html".withCString { html in
                    "application/octet-stream".withCString { binary in
                        let data = bytes.baseAddress!.assumingMemoryBound(to: CChar.self)
                        let values = [
                            ghostty_clipboard_content_s(mime: plain, data: data, len: 64),
                            ghostty_clipboard_content_s(mime: html, data: data, len: 64),
                            ghostty_clipboard_content_s(mime: binary, data: data, len: 32),
                        ]
                        return values.withUnsafeBufferPointer {
                            Ghostty.ClipboardContent.from(
                                contents: $0.baseAddress!,
                                count: $0.count)
                        }
                    }
                }
            }
        }

        source[0] = 0x42

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
