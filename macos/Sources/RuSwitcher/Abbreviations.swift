import Foundation

/// Сокращение автозамены (3.5.0b): «сув» → «С уважением, Рашид».
struct Abbreviation: Equatable, Sendable {
    var short: String
    var full: String
}

/// Клавиша шаблона сокращения. shift == nil — не важен (буква: регистр не учитываем).
struct PatternKey: Equatable, Sendable {
    let code: UInt16
    let shift: Bool?
}

/// Автозамена сопоставляет ФИЗИЧЕСКИЕ клавиши: «!test» = «!TEST» = «!еуые». Сокращение
/// раскладывается в клавиши по каждой раскладке пары, совпадение в любой — срабатывание.
enum Abbreviations {
    static let maxShort = 32
    static let maxFull = 500

    /// Чистка: пробелы по краям — вон, переводы строк в расшифровке — в пробел, пустые,
    /// слишком длинные и сокращения с пробелами внутри — вон, дубликаты (без регистра) —
    /// побеждает первое.
    static func sanitize(_ list: [Abbreviation]) -> [Abbreviation] {
        var seen = Set<String>()
        var out: [Abbreviation] = []
        for a in list {
            let short = a.short.trimmingCharacters(in: .whitespacesAndNewlines)
            let full = a.full.components(separatedBy: .newlines).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !short.isEmpty, short.count <= maxShort, !short.contains(where: { $0.isWhitespace }),
                  !full.isEmpty, full.count <= maxFull,
                  seen.insert(short.lowercased()).inserted else { continue }
            out.append(Abbreviation(short: short, full: full))
        }
        return out
    }

    /// Символ → клавиша для одной раскладки. Буквы — по нижнему регистру и без shift
    /// (shift: nil); знаки — с точным shift. Символ на двух клавишах берёт основную
    /// (без shift, меньший keyCode).
    static func reverseTable(_ table: [KeyStroke: Character]) -> [Character: PatternKey] {
        var rev: [Character: PatternKey] = [:]
        let order = table.keys.sorted { ($0.shift ? 1 : 0, $0.code) < ($1.shift ? 1 : 0, $1.code) }
        for stroke in order {
            guard let ch = table[stroke] else { continue }
            if ch.isLetter {
                guard let low = String(ch).lowercased().first, rev[low] == nil else { continue }
                rev[low] = PatternKey(code: stroke.code, shift: nil)
            } else if rev[ch] == nil {
                rev[ch] = PatternKey(code: stroke.code, shift: stroke.shift)
            }
        }
        return rev
    }

    /// Клавиши сокращения в раскладке; nil — сокращение в ней не набирается.
    static func pattern(for short: String, reverse: [Character: PatternKey]) -> [PatternKey]? {
        var out: [PatternKey] = []
        for ch in short {
            let key: Character = ch.isLetter ? (String(ch).lowercased().first ?? ch) : ch
            guard let p = reverse[key] else { return nil }
            out.append(p)
        }
        return out
    }

    static func matches(_ typed: [TypedKey], _ pattern: [PatternKey]) -> Bool {
        guard typed.count == pattern.count else { return false }
        for (k, p) in zip(typed, pattern) {
            guard k.char == nil, k.keyCode == p.code else { return false }
            if let s = p.shift, s != k.shift { return false }
        }
        return true
    }

    /// Первое сокращение из списка, совпавшее с набранными клавишами в любой раскладке пары.
    static func match(_ typed: [TypedKey], list: [Abbreviation],
                      reverses: [[Character: PatternKey]]) -> Abbreviation? {
        guard !typed.isEmpty else { return nil }
        for a in list where a.short.count == typed.count {
            for rev in reverses {
                if let p = pattern(for: a.short, reverse: rev), matches(typed, p) { return a }
            }
        }
        return nil
    }
}
