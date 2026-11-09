import Foundation

/// Одно нажатие в буфере конверсии. Для обычного локального ввода известен keyCode
/// (char == nil). Для ввода, проброшенного через удалённый стол, Apple Screen Sharing
/// шлёт keyCode 0 + сам символ — тогда char != nil, и конверсия идёт по символу,
/// а не по бесполезному keyCode 0 (именно keyCode 0 рождал «фффффф»).
struct TypedKey {
    let keyCode: UInt16
    let shift: Bool
    let caps: Bool
    var char: Character? = nil
}

/// Клавиша с shift — ключ таблиц «клавиша → символ» раскладки (3.5.0b).
struct KeyStroke: Hashable, Sendable {
    let code: UInt16
    let shift: Bool
}

/// Режет строку на куски не длиннее limit UTF-16 единиц по границам символов: один
/// CGEvent с юникод-строкой надёжно несёт около 20 единиц, а расшифровка автозамены
/// бывает до 500 знаков. Символ длиннее limit (составной эмодзи) идёт отдельным куском.
func insertChunks(_ s: String, limit: Int = 20) -> [String] {
    var out: [String] = []
    var cur = ""
    var curLen = 0
    for ch in s {
        let n = ch.utf16.count
        if curLen > 0, curLen + n > limit {
            out.append(cur); cur = ""; curLen = 0
        }
        cur.append(ch); curLen += n
    }
    if !cur.isEmpty { out.append(cur) }
    return out
}
