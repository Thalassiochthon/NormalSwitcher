import Testing
@testable import RuSwitcher

struct CaretTranslationInputTests {
    @Test func shortRussianWordGetsAnExplicitSource() {
        #expect(CaretTranslationInput(text: "привет", typingLanguage: "ru-RU").sourceLanguage == "ru")
        #expect(CaretTranslationInput(text: "привет", typingLanguage: nil).sourceLanguage == "ru")
        #expect(CaretTranslationInput(text: "да", typingLanguage: "ru").sourceLanguage == "ru")
    }

    @Test func respectsSpanishAndEnglishText() {
        #expect(CaretTranslationInput(text: "hello", typingLanguage: "en-US").sourceLanguage == "en")
        #expect(CaretTranslationInput(text: "casa", typingLanguage: "es-ES").sourceLanguage == "es")
        #expect(CaretTranslationInput(text: "buenos días", typingLanguage: "en-US").sourceLanguage == "es")
    }
}
