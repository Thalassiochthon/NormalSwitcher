import CoreGraphics
import Foundation

/// Какой клавишей стороны срабатывает хоткей-модификатор. Для комбо сторона не различается.
enum HotkeySide: String {
    case any, left, right
}

struct HotkeySetting: Equatable {
    var key: String          // "" = выключен; "option", "command+shift" и т.п.
    var side: HotkeySide
    var doubleTap: Bool

    var isCombo: Bool { key.contains("+") }
    /// Сторону (левая/правая) различаем только у одиночных модификаторов с парой клавиш:
    /// у комбо сторона не приходит во флагах, а Fn один.
    var hasSides: Bool { !isCombo && key != "fn" }

    /// Одно нажатие запустило бы оба хоткея: та же клавиша и пересекающиеся стороны.
    func overlaps(_ other: HotkeySetting) -> Bool {
        guard !key.isEmpty, key == other.key else { return false }
        if !hasSides { return true }
        return side == .any || other.side == .any || side == other.side
    }
}

/// Хоткеи в порядке приоритета: при конфликте работает тот, что выше.
enum HotkeySlot: String, CaseIterable {
    case trigger, switchLayout, changeCase, layout1, layout2, addException
}

/// Конфигурация клавиши-триггера (читается из настроек, кэшируется в KeyboardMonitor).
struct TriggerConfig {
    enum Kind {
        case modifier(mask: CGEventFlags, left: UInt16, right: UInt16)
        /// Комбо из двух модификаторов (например ⌘+⇧). Детект по флагам: оба зажаты без
        /// посторонних → отпущены все без клавиш между. Сторона (left/right) не важна.
        case combo(CGEventFlags, CGEventFlags)
        case capsLock
    }
    let kind: Kind
    let rightOnly: Bool
    let doubleTap: Bool
    var leftOnly = false

    static let allModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
    /// При НАЖАТИИ учитываем и Fn: Fn+⌥ не тап ⌥. При отпускании бит Fn смотрим только у
    /// хоткеев с Fn: на событиях при зажатых стрелках и F-клавишах он бывает паразитным, и
    /// привычные ⌥ / ⌥+⇧ молча перестали бы срабатывать (ревью #38). Нажатие самой Fn
    /// сбрасывает взведённый хоткей без Fn отдельно (keyCode == KC.function).
    static let pressModifiers = allModifiers.union(.maskSecondaryFn)

    var usesFn: Bool {
        switch kind {
        case let .modifier(mask, _, _): return mask.contains(.maskSecondaryFn)
        case let .combo(a, b): return a.contains(.maskSecondaryFn) || b.contains(.maskSecondaryFn)
        case .capsLock: return false
        }
    }

    /// Что должно быть отпущено, чтобы тап состоялся.
    var releaseModifiers: CGEventFlags { usesFn ? TriggerConfig.pressModifiers : TriggerConfig.allModifiers }

    var isCapsLock: Bool { if case .capsLock = kind { return true } else { return false } }

    /// Кейкоды модификатора, тап которых считается (сторона: любая / левая / правая).
    func accepted(left: UInt16, right: UInt16) -> Set<UInt16> {
        rightOnly ? [right] : (leftOnly ? [left] : [left, right])
    }

    static func current() -> TriggerConfig {
        return make(SettingsManager.shared.hotkey(.trigger))
    }

    /// Дополнительный хоткей (смена раскладки #14, регистр #29, «всегда раскладка 1/2»,
    /// «в исключения»). nil — выключен или конфликтует с хоткеем выше по приоритету:
    /// одно нажатие не должно делать два действия. Белый список обязателен: parse() маппит
    /// неизвестные строки в Option — рукописный мусор в defaults дублировал бы триггер.
    static func forSlot(_ slot: HotkeySlot) -> TriggerConfig? {
        let known: Set<String> = ["option", "command", "control", "shift", "fn", "fn+shift",
                                  "command+shift", "control+shift", "command+option", "control+option",
                                  "option+shift"]
        let s = SettingsManager.shared
        let h = s.hotkey(slot)
        guard slot != .trigger, known.contains(h.key) else { return nil }
        for higher in HotkeySlot.allCases.prefix(while: { $0 != slot }) where h.overlaps(s.hotkey(higher)) {
            return nil
        }
        return make(h)
    }

    /// Сторона у комбо не различается: устаревшая «левая» из настроек в конфиг не попадает.
    private static func make(_ h: HotkeySetting) -> TriggerConfig {
        let side = h.hasSides ? h.side : HotkeySide.any
        return parse(key: h.key, rightOnly: side == .right, doubleTap: h.doubleTap, leftOnly: side == .left)
    }

    static func parse(key: String, rightOnly: Bool, doubleTap: Bool, leftOnly: Bool = false) -> TriggerConfig {
        let kind: Kind
        switch key {
        case "command": kind = .modifier(mask: .maskCommand, left: KC.leftCommand, right: KC.rightCommand)
        case "control": kind = .modifier(mask: .maskControl, left: KC.leftControl, right: KC.rightControl)
        case "shift":   kind = .modifier(mask: .maskShift,   left: KC.leftShift,   right: KC.rightShift)
        // Комбо двух модификаторов (issue #12: привычный по Windows стиль Alt+Shift и т.п.).
        // #38: Fn / 🌐 (только клавиатуры Apple: у сторонних Fn обрабатывается в самой клавиатуре).
        case "fn":             kind = .modifier(mask: .maskSecondaryFn, left: KC.function, right: KC.function)
        case "fn+shift":       kind = .combo(.maskSecondaryFn, .maskShift)
        case "command+shift":  kind = .combo(.maskCommand, .maskShift)
        case "control+shift":  kind = .combo(.maskControl, .maskShift)
        case "command+option": kind = .combo(.maskCommand, .maskAlternate)
        case "control+option": kind = .combo(.maskControl, .maskAlternate)
        // discussion #32: ⌥+⇧ — виндовый дефолт; тап-детект комбо (любой keyDown между
        // нажатием и отпусканием сбрасывает взвод) исключает конфликт с ⌥⇧+буква/стрелки.
        case "option+shift":   kind = .combo(.maskAlternate, .maskShift)
        // ТЕХДОЛГ: нативный Caps Lock убран из UI (нестабилен — HID-дебаунс/тоггл,
        // нужен HID-драйвер уровня Karabiner). Код consume-пути оставлен на будущее.
        case "capsLock": kind = .capsLock
        default:        kind = .modifier(mask: .maskAlternate, left: KC.leftOption, right: KC.rightOption)
        }
        return TriggerConfig(kind: kind, rightOnly: rightOnly, doubleTap: doubleTap, leftOnly: leftOnly)
    }
}

/// Машина тапа для дополнительных хоткеев — та же логика, что у триггера: соло-тап без
/// других модификаторов и без клавиш между (в пределах tapWindow), комбо — оба зажаты и
/// отпущены без клавиш между (в пределах comboTapWindow), двойной тап — два тапа подряд.
/// Разоружается на keyDown/клике: Ctrl+Shift+P и подобные шорткаты хоткеем не считаются.
struct TapDetector {
    let config: TriggerConfig
    private var armed = false
    private var pressTime: Date?
    private var lastTapTime: Date?

    init(config: TriggerConfig) { self.config = config }

    mutating func disarm() {
        armed = false
        lastTapTime = nil
    }

    /// true — хоткей сработал (с учётом двойного тапа).
    mutating func handle(flags: CGEventFlags, keyCode: UInt16, tapWindow: TimeInterval, comboTapWindow: TimeInterval) -> Bool {
        if keyCode == KC.function, !config.usesFn {
            armed = false
            pressTime = nil
            return false
        }
        let release = config.releaseModifiers
        var tapped = false
        switch config.kind {
        case .capsLock:
            return false
        case let .modifier(mask, left, right):
            let accepted = config.accepted(left: left, right: right)
            if flags.contains(mask) {
                armed = accepted.contains(keyCode) && flags.intersection(TriggerConfig.pressModifiers.subtracting(mask)).isEmpty
                pressTime = armed ? Date() : nil
            } else {
                if armed, accepted.contains(keyCode), let t = pressTime, Date().timeIntervalSince(t) < tapWindow {
                    tapped = true
                }
                armed = false
                pressTime = nil
            }
        case let .combo(maskA, maskB):
            let both: CGEventFlags = [maskA, maskB]
            if !flags.intersection(release.subtracting(both)).isEmpty {
                armed = false
            } else if flags.contains(both) {
                armed = flags.intersection(TriggerConfig.pressModifiers.subtracting(both)).isEmpty
                pressTime = armed ? Date() : nil
            } else if flags.intersection(release).isEmpty {
                // issue #21: окно комбо шире (аккорд держат дольше флика), но с потолком —
                // не срабатывать на попутное удержание во время скролла/жеста.
                if armed, let t = pressTime, Date().timeIntervalSince(t) < comboTapWindow {
                    tapped = true
                }
                armed = false
                pressTime = nil
            }
        }
        guard tapped else { return false }
        guard config.doubleTap else { return true }
        if let last = lastTapTime, Date().timeIntervalSince(last) < tapWindow {
            lastTapTime = nil
            return true
        }
        lastTapTime = Date()
        return false
    }
}
