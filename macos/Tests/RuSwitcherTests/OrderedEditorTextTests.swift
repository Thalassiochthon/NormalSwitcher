import Foundation
import Testing
@testable import RuSwitcher

struct OrderedEditorTextTests {
    @Test func caretRangeUsesUTF16Offsets() {
        let text = "🙂 ghbdtn"
        #expect(TextConverter.textInRange(text, range: CFRange(location: 3, length: 6)) == "ghbdtn")
    }

    @Test func staleAndInvalidCaretRangesAreRejected() {
        #expect(TextConverter.textInRange("vbh", range: CFRange(location: 1, length: 3)) == nil)
        #expect(TextConverter.textInRange("vbh", range: CFRange(location: -1, length: 3)) == nil)
        #expect(TextConverter.textInRange("vbh", range: CFRange(location: 1, length: Int.max)) == nil)
    }
}
