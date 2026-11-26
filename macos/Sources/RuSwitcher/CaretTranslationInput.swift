import Foundation
import NaturalLanguage

struct CaretTranslationRequest {
    let input: CaretTranslationInput
    let replaceSelection: ((String) -> Bool)?
}

struct CaretTranslationInput {
    let text: String
    let typingLanguage: String?

    var sourceLanguage: String? {
        let layout = typingLanguage.map { Locale.Language(identifier: $0) }
        let letters = String(text.filter(\.isLetter))
        let cyrillic = letters.range(of: #"^\p{Cyrillic}+$"#, options: .regularExpression) != nil
        let latin = letters.range(of: #"^\p{Latin}+$"#, options: .regularExpression) != nil
        if cyrillic, layout?.script?.identifier == "Cyrl" {
            return layout?.minimalIdentifier
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let guess = recognizer.languageHypotheses(withMaximum: 1).first
        // Short Cyrillic words such as "привет" can rank Bulgarian above Russian.
        // For an unlabelled selection, use Russian unless the evidence for another language is strong.
        if cyrillic, (guess?.value ?? 0) < 0.95 { return "ru" }
        if let guess, guess.value >= 0.55 { return guess.key.rawValue }
        if latin {
            return layout?.script?.identifier == "Latn" ? layout?.minimalIdentifier : "en"
        }
        return guess?.key.rawValue
    }
}
