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

    @Test func unavailableSuffixNeverAuthorizesDeletion() {
        let result = TextConverter.verifyEditorSuffix(
            original: "ghbdtn", caret: CFRange(location: 6, length: 0)
        ) { _ in nil }
        guard case .failure(.textUnavailable) = result else {
            Issue.record("The range was not verified")
            return
        }
    }

    @Test func movedCaretCannotReplaceAnIdenticalWord() {
        let result = TextConverter.verifyEditorSuffix(
            original: "vbh", caret: CFRange(location: 7, length: 0), expectedLocation: 0
        ) { _ in "vbh" }
        guard case .failure(.contextChanged) = result else {
            Issue.record("An identical word at a new caret position must be left alone")
            return
        }
    }

    @Test func changedSuffixAndActiveSelectionAreRejected() {
        let caret = CFRange(location: 3, length: 0)
        let changed = TextConverter.verifyEditorSuffix(original: "vbh", caret: caret) { _ in "abc" }
        guard case .failure(.textChanged) = changed else {
            Issue.record("The editor text differs from the typed word")
            return
        }
        let selected = TextConverter.verifyEditorSuffix(
            original: "vbh", caret: CFRange(location: 3, length: 1)
        ) { _ in "vbh" }
        guard case .failure(.selectionActive) = selected else {
            Issue.record("The editor already has a selection")
            return
        }
    }

    @Test func suffixCannotStartInTheMiddleOfAGrapheme() {
        #expect(TextConverter.textInRange("🙂vbh", range: CFRange(location: 1, length: 4)) == nil)
        #expect(TextConverter.textInRange("e\u{0301}vbh", range: CFRange(location: 1, length: 4)) == nil)
    }
}
