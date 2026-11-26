import AppKit
import SwiftUI
import Translation

@available(macOS 15.0, *)
struct CaretTranslationView: View {
    private struct Languages: Equatable {
        var source: String
        var target: String
    }

    static let panelWidth: CGFloat = 270
    private static let targetCodes = ["ru", "en", "es"]
    private let input: CaretTranslationInput?
    private let insert: ((String) async -> Bool)?
    private let close: () -> Void
    @State private var languages: Languages
    @State private var availableSources: [String]
    @State private var result: String?
    @State private var failure: String?
    @State private var copied = false
    @State private var inserting = false
    @State private var insertionFailed = false

    init(input: CaretTranslationInput?, insert: ((String) async -> Bool)?, close: @escaping () -> Void) {
        self.input = input
        self.insert = insert
        self.close = close
        let source = input?.sourceLanguage ?? ""
        let preferred = L10n.languageCode == "ru" ? "ru" : "en"
        let defaultTarget = source == preferred ? (preferred == "ru" ? "en" : "ru") : preferred
        let saved = SettingsManager.shared.caretTranslationTargets[source]
        let target = saved.flatMap { Self.targetCodes.contains($0) && $0 != source ? $0 : nil } ?? defaultTarget
        _languages = State(initialValue: Languages(source: source, target: target))
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
                    Text(result)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(8)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    resultActions(result)
                    if insertionFailed {
                        Text(taskText("Check that the original text is still selected, or copy the translation.",
                                      "Проверьте исходное выделение или скопируйте перевод."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
        .frame(width: Self.panelWidth)
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
            insertionFailed = false
        }
        .translationTask(configuration, action: translateAction(requested: languages))
    }

    private func resultActions(_ text: String) -> some View {
        HStack(spacing: 8) {
            if let insert {
                Button(taskText("Insert", "Вставить")) {
                    inserting = true
                    insertionFailed = false
                    Task {
                        let succeeded = await insert(text)
                        inserting = false
                        insertionFailed = !succeeded
                    }
                }
                .buttonStyle(.borderedProminent)
                Button { copy(text) } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .help(copied ? taskText("Copied", "Скопировано") : taskText("Copy", "Копировать"))
                .accessibilityLabel(taskText("Copy translation", "Скопировать перевод"))
            } else {
                Button(copied ? taskText("Copied", "Скопировано") : taskText("Copy", "Копировать")) { copy(text) }
            }
        }
        .disabled(inserting)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        copied = NSPasteboard.general.setString(text, forType: .string)
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
            Picker(taskText("Target language", "Язык перевода"), selection: Binding(
                get: { languages.target },
                set: { target in
                    languages.target = target
                    if !languages.source.isEmpty, languages.source != target {
                        SettingsManager.shared.caretTranslationTargets[languages.source] = target
                    }
                }
            )) {
                ForEach(Self.targetCodes, id: \.self) { code in
                    Text(languageName(code)).tag(code)
                }
            }
            .help(taskText("Target language", "Язык перевода"))
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .disabled(inserting)
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
