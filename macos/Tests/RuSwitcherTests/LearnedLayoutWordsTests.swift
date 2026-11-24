import Testing
@testable import RuSwitcher

@MainActor
struct LearnedLayoutWordsTests {
    @Test func convertsLearnedWordsInEitherDirection() {
        let words: Set<String> = ["лабуба", "glorp"]
        #expect(LayoutDetector.plan(typed: "Kf,e,f", converted: "Лабуба", canSplit: true,
                                    currentLang: "en", otherLang: "ru", capsLock: false,
                                    alwaysConvertWords: words) == .convert(coreLength: 6))
        #expect(LayoutDetector.plan(typed: "пдщкз", converted: "glorp", canSplit: true,
                                    currentLang: "ru", otherLang: "en", capsLock: false,
                                    alwaysConvertWords: words) == .convert(coreLength: 5))
    }

    @Test func keepsCorrectlyTypedLearnedWords() {
        #expect(LayoutDetector.plan(typed: "Лабуба!", converted: "Kf,e,f!", canSplit: true,
                                    currentLang: "ru", otherLang: "en", capsLock: false,
                                    alwaysConvertWords: ["лабуба", "kf,e,f"]) == .skip(.keep))
    }

    @Test func distinguishesLearnedFinalLetterFromExtraPunctuation() {
        #expect(LayoutDetector.plan(typed: "rjn,,", converted: "котбб", canSplit: true,
                                    currentLang: "en", otherLang: "ru", capsLock: false,
                                    alwaysConvertWords: ["котб"]) == .convert(coreLength: 4))
    }

    @Test func learnsWordsInAnotherKeyboardPair() {
        #expect(LayoutDetector.plan(typed: "ысрьэр", converted: "schmäh", canSplit: true,
                                    currentLang: "ru", otherLang: "de", capsLock: false,
                                    alwaysConvertWords: ["schmäh"]) == .convert(coreLength: 6))
    }
}
