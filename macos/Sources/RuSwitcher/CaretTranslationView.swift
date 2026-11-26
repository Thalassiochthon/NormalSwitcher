import AppKit
import NaturalLanguage
import SwiftUI
import Translation

@available(macOS 15.0, *)
struct CaretTranslationView: View {
    private let text: String?
    private let source: String?
    @State private var target: String
    @State private var result: String?
    @State private var failed = false
    @State private var copied = false

    init(text: String?) {
        self.text = text
        source = text.flatMap { NLLanguageRecognizer.dominantLanguage(for: $0)?.rawValue }
        let preferred = L10n.languageCode == "ru" ? "ru" : "en"
        _target = State(initialValue: source == preferred ? (preferred == "ru" ? "en" : "ru") : preferred)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let text {
                HStack {
                    Text(taskText("Translate to", "Перевести на"))
                    Spacer()
                    Picker(taskText("Translate to", "Перевести на"), selection: $target) {
                        ForEach(["en", "ru", "es"], id: \.self) { code in
                            Text(code.uppercased()).tag(code)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 112)
                }
                Text(text)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                if let result {
                    ScrollView {
                        Text(result)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 145)
                    Button(copied ? taskText("Copied", "Скопировано") : taskText("Copy", "Копировать")) {
                        NSPasteboard.general.clearContents()
                        copied = NSPasteboard.general.setString(result, forType: .string)
                    }
                } else if failed {
                    Text(taskText("Translation unavailable. Try another language.",
                                  "Перевод недоступен. Попробуйте другой язык."))
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(taskText("Translating", "Переводим"))
                }
            } else {
                Text(taskText("Select a short phrase or type a word in a text field.",
                              "Выделите короткую фразу или наберите слово в поле ввода."))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 270)
        .onChange(of: target) { _, _ in
            result = nil
            failed = false
            copied = false
        }
        .translationTask(source: nil, target: Locale.Language(identifier: target),
                         action: translateAction(requested: target))
    }

    private func translateAction(requested: String) -> (TranslationSession) async -> Void {
        let input = text
        let sameLanguage = source == requested
        return Self.makeTranslationAction(text: input, sameLanguage: sameLanguage) { translated in
            guard target == requested else { return }
            result = translated
            failed = translated == nil
        }
    }

    nonisolated private static func makeTranslationAction(
        text: String?, sameLanguage: Bool, complete: @escaping @MainActor @Sendable (String?) -> Void
    ) -> (TranslationSession) async -> Void {
        { session in
            guard let text else { return }
            if sameLanguage {
                await complete(text)
                return
            }
            let translated = try? await session.translate(text).targetText
            guard !Task.isCancelled else { return }
            await complete(translated)
        }
    }
}
