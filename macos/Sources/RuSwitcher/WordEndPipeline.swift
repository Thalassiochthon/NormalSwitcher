import Foundation

/// Какая клавиша закончила слово (3.5.0b).
enum WordEndKey: Sendable { case space, enter, tab }

enum FixKind: Equatable, Sendable { case twoCaps, number, typo }

/// Что сделать со словом на его конце.
enum WordEndAction: Equatable, Sendable {
    case none
    /// Автозамена: стереть слово, вставить текст.
    case expand(String)
    /// Конверсия раскладки по плану детектора (coreLength — сколько символов конвертировать,
    /// хвост-пунктуация как раньше, #15/#33). fixedCore — ядро с исправленными двумя заглавными.
    case convert(coreLength: Int, fixedCore: String?)
    /// Правка: заменить слово целиком.
    case fix(String, FixKind)
}

/// Включённые шаги конвейера.
struct WordEndConfig: Sendable {
    var autoConvert = false
    var twoCaps = false
    var typos = false
    /// Пара с ивритом: ивритский словарь принимает любые буквы — правки не работают.
    var hebrewPair = false
}

/// Всё, что конвейеру нужно знать о мире, — замыканиями: в приложении это словарь,
/// раскладки и детектор, на стенде — подделки. Слова в замыканиях — в нижнем регистре.
struct WordEndDeps {
    var abbreviation: () -> String?
    var convertPlan: () -> Int?
    var convertedCore: (Int) -> String
    var isTargetWord: (String) -> Bool
    var isCurrentWord: (String) -> Bool
    var numberFix: () -> String?
    var typoFix: () -> String?
    var isDeniedWord: () -> Bool
}

/// Конвейер конца слова: автозамена → конверсия раскладки → числа → две заглавные →
/// опечатка. Первый сработавший шаг завершает обработку; «две заглавные» дополнительно
/// применяются к результату конверсии.
enum WordEndPipeline {
    static func decide(typed: String, config: WordEndConfig, deps: WordEndDeps) -> WordEndAction {
        if let full = deps.abbreviation() { return .expand(full) }
        if deps.isDeniedWord() { return .none }
        if config.autoConvert, let core = deps.convertPlan() {
            let fixed = config.twoCaps
                ? TextFixes.fixTwoCaps(deps.convertedCore(core), isWord: deps.isTargetWord) : nil
            return .convert(coreLength: core, fixedCore: fixed)
        }
        guard !config.hebrewPair else { return .none }
        if config.typos, let n = deps.numberFix() { return .fix(n, .number) }
        if config.twoCaps, let f = TextFixes.fixTwoCaps(typed, isWord: deps.isCurrentWord) { return .fix(f, .twoCaps) }
        if config.typos, let t = deps.typoFix() { return .fix(t, .typo) }
        return .none
    }
}
