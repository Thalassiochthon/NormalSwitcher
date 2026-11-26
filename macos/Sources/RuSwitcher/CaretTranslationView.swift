import AppKit
import SwiftUI
import Translation

@available(macOS 15.0, *)
struct CaretTranslationView: View {
    private struct Languages: Equatable {
        var source: String
        var target: String
    }

    private static let targetCodes = ["ru", "en", "es"]
    private let input: CaretTranslationInput?
    private let close: () -> Void
    @State private var languages: Languages
    @State private var availableSources: [String]
    @State private var result: String?
    @State private var failure: String?
    @State private var copied = false

    init(input: CaretTranslationInput?, close: @escaping () -> Void) {
        self.input = input
        self.close = close
        let source = input?.sourceLanguage ?? ""
        let preferred = L10n.languageCode == "ru" ? "ru" : "en"
        _languages = State(initialValue: Languages(source: source, target: source == preferred
                                                   ? (preferred == "ru" ? "en" : "ru") : preferred))
        _availableSources = State(initialValue: Self.targetCodes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if input != nil { languageMenus }
                Spacer(minLength: 3)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(taskText("Close", "Закрыть"))
            }
            if let input {
                Text(input.text)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                if languages.source.isEmpty {
                    Text(taskText("Choose the source language.", "Выберите язык исходного текста."))
                        .foregroundStyle(.secondary)
                } else if languages.source == languages.target {
                    Text(taskText("The text is already in that language.", "Текст уже на этом языке."))
                        .foregroundStyle(.secondary)
                } else if let result {
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
                } else if let failure {
                    Text(failure).foregroundStyle(.secondary)
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
        .task {
            guard input != nil else { return }
            let supported = await Self.supportedSourceCodes()
            guard !Task.isCancelled else { return }
            availableSources = Array(Set(Self.targetCodes + supported)).sorted {
                languageName($0).localizedStandardCompare(languageName($1)) == .orderedAscending
            }
        }
        .onChange(of: languages) { _, _ in
            result = nil
            failure = nil
            copied = false
        }
        .translationTask(configuration, action: translateAction(requested: languages))
    }

    private var languageMenus: some View {
        HStack(spacing: 5) {
            Picker(taskText("Source language", "Исходный язык"), selection: $languages.source) {
                if languages.source.isEmpty {
                    Text(taskText("From…", "С языка…")).tag("")
                }
                ForEach(sourceCodes, id: \.self) { code in
                    Text(languageName(code)).tag(code)
                }
            }
            .help(taskText("Source language", "Исходный язык"))
            Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityHidden(true)
            Picker(taskText("Target language", "Язык перевода"), selection: $languages.target) {
                ForEach(Self.targetCodes, id: \.self) { code in
                    Text(languageName(code)).tag(code)
                }
            }
            .help(taskText("Target language", "Язык перевода"))
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
    }

    nonisolated private static func supportedSourceCodes() async -> [String] {
        await LanguageAvailability().supportedLanguages.map(\.minimalIdentifier)
    }

    private var sourceCodes: [String] {
        let source = languages.source
        return source.isEmpty || availableSources.contains(source) ? availableSources : [source] + availableSources
    }

    private func languageName(_ code: String) -> String {
        Locale(identifier: L10n.languageCode).localizedString(forLanguageCode: code) ?? code.uppercased()
    }

    private var configuration: TranslationSession.Configuration? {
        guard input != nil, !languages.source.isEmpty, languages.source != languages.target else { return nil }
        return TranslationSession.Configuration(source: Locale.Language(identifier: languages.source),
                                                target: Locale.Language(identifier: languages.target))
    }

    private func translateAction(requested: Languages) -> (TranslationSession) async -> Void {
        Self.makeTranslationAction(text: input?.text) { translated, error in
            guard languages == requested else { return }
            result = translated
            if let error {
                let info = error as NSError
                rslog("caret translation: \(requested.source)→\(requested.target) \(info.domain) \(info.code)")
                failure = error is TranslationError ? error.localizedDescription
                    : taskText("Couldn’t translate. Try again or change the source language.",
                               "Не удалось перевести. Попробуйте снова или смените исходный язык.")
            }
        }
    }

    nonisolated private static func makeTranslationAction(
        text: String?, complete: @escaping @MainActor @Sendable (String?, (any Error)?) -> Void
    ) -> (TranslationSession) async -> Void {
        { session in
            guard let text else { return }
            do {
                let translated = try await session.translate(text).targetText
                guard !Task.isCancelled else { return }
                await complete(translated, nil)
            } catch {
                guard !Task.isCancelled else { return }
                await complete(nil, error)
            }
        }
    }
}
