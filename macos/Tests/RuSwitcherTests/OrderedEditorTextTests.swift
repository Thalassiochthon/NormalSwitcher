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

    @Test func delayedLastCharacterCanSettleBeforeTheSpace() throws {
        var text = "ghbdt"
        let range = try TextConverter.readSettledSuffix {
            TextConverter.verifyEditorSuffix(original: "ghbdtn", caret: CFRange(location: text.utf16.count, length: 0)) {
                TextConverter.textInRange(text, range: $0)
            }
        } beforeRetry: {
            text.append("n")
            return nil
        }.get()
        #expect(range.range.location == 0 && range.range.length == 6)
    }

    @Test func recognizesOnlyTheEditorCapitalizingTheFirstLetter() throws {
        let caret = CFRange(location: 6, length: 0)
        let suffix = try TextConverter.verifyEditorSuffix(
            original: "ghbdtn", caret: caret, allowInitialCapital: true
        ) { _ in "Ghbdtn" }.get()
        #expect(suffix.range.location == 0)
        #expect(suffix.text == "Ghbdtn")
        #expect(suffix.applyingCapitalization(to: "привет") == "Привет")
        for different in ["gHbdtn", "GHBDTN", "Ghbdtx"] {
            let result = TextConverter.verifyEditorSuffix(
                original: "ghbdtn", caret: caret, allowInitialCapital: true
            ) { _ in different }
            guard case .failure(.textChanged) = result else {
                Issue.record("Only an initial capitalization can match")
                continue
            }
        }
        let strict = TextConverter.verifyEditorSuffix(original: suffix.text, caret: caret) { _ in "ghbdtn" }
        guard case .failure(.textChanged) = strict else {
            Issue.record("An edit between verification and replacement must be rejected")
            return
        }
    }

    @Test func stableMismatchAndContextChangeAbortTheEdit() {
        var reads = 0
        func mismatch() -> Result<CFRange, TextConverter.AutomaticEditFailure> {
            reads += 1
            return .failure(.textChanged)
        }
        let mismatchResult = TextConverter.readSettledSuffix(read: mismatch, beforeRetry: { nil })
        guard case .failure(.textChanged) = mismatchResult else {
            Issue.record("A persistent mismatch must skip the replacement")
            return
        }
        #expect(reads == 2)
        let changed = TextConverter.readSettledSuffix(read: mismatch, beforeRetry: { .contextChanged })
        guard case .failure(.contextChanged) = changed else {
            Issue.record("A focus or layout change during the wait must abort the retry")
            return
        }
        #expect(reads == 3)
    }

    @Test func suffixCannotStartInTheMiddleOfAGrapheme() {
        #expect(TextConverter.textInRange("🙂vbh", range: CFRange(location: 1, length: 4)) == nil)
        #expect(TextConverter.textInRange("e\u{0301}vbh", range: CFRange(location: 1, length: 4)) == nil)
    }
}
