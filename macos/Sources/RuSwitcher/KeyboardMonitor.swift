import AppKit
import CoreGraphics
import Foundation

/// Маркер для симулированных событий — KeyboardMonitor их игнорирует
let kRuSwitcherEventMarker: Int64 = 0x52555300

/// Выделенная очередь для файлового I/O лога — чтобы запись на диск не блокировала
/// поток обработки событий (event tap висит на главном run loop, а лог пишется
/// для каждого нажатия при включённом debug).
private let rsLogQueue = DispatchQueue(label: "com.ruswitcher.log")

let debugLogURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    .appendingPathComponent("Library/Logs/NormalSwitcher", isDirectory: true)
    .appendingPathComponent("normalswitcher.log")

func rslog(_ msg: String) {
    // Thread-safe: читаем UserDefaults напрямую (без MainActor)
    guard UserDefaults.standard.bool(forKey: "com.ruswitcher.debugLog") else { return }

    let line = "\(Date()): \(msg)\n"
    rsLogQueue.async {
        let logDir = debugLogURL.deletingLastPathComponent().path
        let path = debugLogURL.path

        // Создаём директорию если нет
        if !FileManager.default.fileExists(atPath: logDir) {
            try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        }

        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            // Ротация: если > 5MB — обрезаем
            if handle.offsetInFile > 5_000_000 {
                handle.truncateFile(atOffset: 0)
                handle.write("--- Log rotated ---\n".data(using: .utf8)!)
            }
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
        }
    }
}

final class KeyboardMonitor: @unchecked Sendable {
    fileprivate var eventTap: CFMachPort?
    var isRunning: Bool { eventTap != nil }
    var isTapEnabled: Bool { eventTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    private var runLoopSource: CFRunLoopSource?
    private var receivedKeyDown = false

    /// Длина текущего набираемого слова
    private(set) var currentWordLength = 0
    /// Длина слова до последнего пробела
    private(set) var wordBeforeBoundaryLength = 0
    /// Сколько пробелов после слова (только пробелы, не enter/стрелки)
    private(set) var boundaryCount = 0
    /// Были ли реальные нажатия после последней конвертации?
    private(set) var keysTypedSinceConversion = true

    /// Нажатия набираемого слова — для движка перепечатки (без буфера обмена)
    private(set) var currentWordKeys: [TypedKey] = []
    /// Нажатия слова перед последней границей-пробелом
    private(set) var prevWordKeys: [TypedKey] = []
    /// issue #24: буфер ВСЕЙ строки (буквы + пробелы-сентинелы char==" ") для перепечатки строки
    /// в терминале, где нет OS-выделения. Любая пунктуация/структурная клавиша/сдвиг курсора
    /// (fullReset) очищает буфер → тогда «вся строка» откатывается на последнее слово.
    private(set) var lineKeys: [TypedKey] = []
    /// Фронтмост-приложение на момент границы слова — чтобы авто-путь не перепечатал
    /// в другое поле, если фокус уехал (Cmd-Tab/Spotlight) без клика/Tab.
    private(set) var prevWordBundleID: String?

    private var onAltTap: (() -> Void)?
    private var onAltReconvert: (() -> Void)?
    struct WordBoundary {
        let key: WordEndKey
        let keys: [TypedKey]
        let pid: pid_t?
        let layoutID: String
        let started: TimeInterval
    }

    /// The poster is valid only within the current tap callback.
    var onWordBoundary: ((WordBoundary, ((CGEvent) -> Void)?) -> Void)?
    var onWordStarted: ((pid_t) -> Void)?
    var onInputReset: (() -> Void)?
    private var boundaryGeneration = 0
    private var wordAppPID: pid_t?
    private var wordLayoutID = ""
    private var orderedSpaceEnabled = false

    private static var wantsOrderedSpace: Bool {
        let settings = SettingsManager.shared
        return settings.autoSwitchEnabled && settings.wordEndPipelineActive && settings.wordEndOnSpace
            && !settings.remoteDesktopMode
    }

    var needsSpaceTapReconfigure: Bool { isRunning && orderedSpaceEnabled != Self.wantsOrderedSpace }
    private var interceptBoundaryKeys = false
    /// Активен ли tap (.defaultTap): тогда он держит каждое событие до ответа колбэка.
    private(set) var tapIsActive = false
    private var suspendDepth = 0
    /// issue #10: любой ввод/клик пользователя — чтобы спрятать флаг у каретки во время печати.
    var onUserInput: (() -> Void)?
    /// issue #10: включена ли фича флага-у-каретки. Гейтит диспатч onUserInput на горячем пути,
    /// чтобы при выключенной фиче (по умолчанию) не будить main-очередь на каждом нажатии.
    var caretFlagEnabled = false

    // Конфиг триггера (кэш; обновляется в start/reconfigure)
    private var triggerConfig = TriggerConfig.current()
    /// Дополнительные хоткеи (смена раскладки #14, регистр #29, «всегда раскладка 1/2»,
    /// «в исключения»): у каждого своя машина тапа. Выключенные в словаре отсутствуют.
    private var detectors: [HotkeySlot: TapDetector] = [:]
    /// Колбэки хоткеев. Ставятся из AppDelegate.
    var onSwitchHotkey: (() -> Void)?
    var onCaseHotkey: (() -> Void)?
    var onLayoutHotkey: ((Int) -> Void)?
    var onExceptionHotkey: (() -> Void)?

    // Детект соло-тапа модификатора
    private var triggerArmed = false
    private var triggerPressTime: Date?
    // Для двойного тапа
    private var lastTapTime: Date?
    private let tapWindow: TimeInterval = 0.4
    // issue #21: окно «тапа» для КОМБО из двух модификаторов. Намеренно большое: аккорд
    // из двух клавиш держат заметно дольше флика одной (0.4с было слишком узко). Но верхний
    // потолок оставлен — иначе комбо срабатывало бы и на «случайное» долгое удержание
    // модификаторов во время скролла/жеста (эти события не сбрасывают armed — их нет в маске
    // event tap'а). 2с покрывает любой намеренный тап и отсекает попутные удержания.
    private let comboTapWindow: TimeInterval = 2.0

    func start(
        onAltTap: @escaping () -> Void,
        onAltReconvert: @escaping () -> Void
    ) -> Bool {
        self.onAltTap = onAltTap
        self.onAltReconvert = onAltReconvert
        receivedKeyDown = false

        triggerConfig = TriggerConfig.current()
        detectors = [:]
        for slot in HotkeySlot.allCases {
            if let cfg = TriggerConfig.forSlot(slot) { detectors[slot] = TapDetector(config: cfg) }
        }
        rslog("Attempting to create event tap... (trigger=\(SettingsManager.shared.triggerKey) hotkeys=\(detectors.keys.map(\.rawValue).sorted()) capsLock=\(triggerConfig.isCapsLock))")
        // Enter/Tab need an active tap to post the edit ahead of the original key.
        // Режим удалённого стола не мешает: проброшенные Screen Sharing клавиши приходят с
        // keyCode 0 и под Enter/Tab не попадают, а фокус в клиенте удалёнки отсекает
        // handleWordEndSync (shouldDeferToRemoteClient).
        let settings = SettingsManager.shared
        interceptBoundaryKeys = settings.wordEndOnEnter || settings.wordEndOnTab
        let keyDownMask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        let mask: CGEventMask =
            keyDownMask
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)

        // Caps Lock can be consumed. Automatic edits use the active tap to preserve ordering.
        let requiresActiveTap = triggerConfig.isCapsLock || interceptBoundaryKeys
        orderedSpaceEnabled = Self.wantsOrderedSpace
        var options: CGEventTapOptions = (requiresActiveTap || orderedSpaceEnabled) ? .defaultTap : .listenOnly

        func createTap(at location: CGEventTapLocation) -> CFMachPort? {
            // Quartz can silently strip keyboard events from a mixed keyboard/mouse mask.
            // With no listening grant, test keyDown alone before accepting the mixed tap.
            if !CGPreflightListenEventAccess() {
                guard let probe = CGEvent.tapCreate(tap: location, place: .tailAppendEventTap,
                                                   options: options, eventsOfInterest: keyDownMask,
                                                   callback: keyboardCallback, userInfo: nil) else {
                    rslog("Keyboard event tap refused keyDown events")
                    return nil
                }
                CFMachPortInvalidate(probe)
            }
            return CGEvent.tapCreate(tap: location, place: .tailAppendEventTap, options: options,
                                     eventsOfInterest: mask, callback: keyboardCallback,
                                     userInfo: Unmanaged.passUnretained(self).toOpaque())
        }

        // Observe events in the logged-in session, including input from remappers
        // and Screen Sharing that may bypass the hardware event stream.
        var tapLocation = CGEventTapLocation.cgSessionEventTap
        var keyboardTap = createTap(at: tapLocation)
        if keyboardTap == nil, !settings.remoteDesktopMode {
            rslog("Session event tap unavailable; trying the HID event tap")
            tapLocation = .cghidEventTap
            keyboardTap = createTap(at: tapLocation)
        }

        // Space ordering is optional when macOS only permits passive monitoring.
        if keyboardTap == nil, orderedSpaceEnabled, !requiresActiveTap {
            options = .listenOnly
            tapLocation = .cgSessionEventTap
            keyboardTap = createTap(at: tapLocation)
            if keyboardTap == nil {
                tapLocation = .cghidEventTap
                keyboardTap = createTap(at: tapLocation)
            }
        }
        guard let tap = keyboardTap else {
            rslog("FAILED to create event tap - no permission")
            return false
        }

        tapIsActive = options == .defaultTap
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        rslog("Event tap created and enabled successfully (\(tapLocation == .cgSessionEventTap ? "session" : "hid"))")
        return true
    }

    func stop() {
        fullReset()
        tapIsActive = false
        suspendDepth = 0
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    /// Перезапускает tap с актуальным конфигом триггера. Нужен при смене настройки —
    /// особенно при переключении на/с Caps Lock, т.к. меняется режим tap (consume).
    @discardableResult
    func reconfigure() -> Bool {
        guard let t = onAltTap, let r = onAltReconvert else { return false }
        rslog("Reconfiguring trigger…")
        stop()
        return start(onAltTap: t, onAltReconvert: r)
    }

    func markConverted() {
        currentWordLength = 0
        wordBeforeBoundaryLength = 0
        boundaryCount = 0
        currentWordKeys = []
        prevWordKeys = []
        lineKeys = []
        keysTypedSinceConversion = false
    }

    /// issue #24 / скептик 3.2.0: системная смена раскладки (globe / Ctrl-Space) не проходит через
    /// наш обработчик клавиш. Сохраняем новое слово, если оно уже началось в новой раскладке.
    func resetLineBuffer() {
        lineKeys = []
        if wordLayoutID != LayoutSwitcher.currentLayoutID() { fullReset() }
    }

    private func fullReset() {
        boundaryGeneration &+= 1
        onInputReset?()
        currentWordLength = 0
        wordBeforeBoundaryLength = 0
        boundaryCount = 0
        currentWordKeys = []
        prevWordKeys = []
        lineKeys = []
    }

    private func boundary(_ key: WordEndKey, keys: [TypedKey]) -> WordBoundary {
        WordBoundary(key: key, keys: keys, pid: wordAppPID, layoutID: wordLayoutID,
                     started: ProcessInfo.processInfo.systemUptime)
    }

    private func fireWordBoundary(postBeforeSpace: ((CGEvent) -> Void)?) {
        boundaryGeneration &+= 1
        let settings = SettingsManager.shared
        guard settings.wordEndOnSpace, settings.wordEndPipelineActive else { return }
        let candidate = boundary(.space, keys: prevWordKeys)
        if orderedSpaceEnabled, let postBeforeSpace {
            onWordBoundary?(candidate, postBeforeSpace)
        } else {
            deferWordBoundary(candidate)
        }
    }

    func deferWordBoundary(_ candidate: WordBoundary) {
        let generation = boundaryGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.boundaryGeneration == generation, self.boundaryCount > 0,
                  ProcessInfo.processInfo.systemUptime - candidate.started < 0.12 else { return }
            self.onWordBoundary?(candidate, nil)
        }
    }

    /// Insert the edit ahead of the original Enter/Tab without consuming either key event.
    fileprivate func processBoundaryKey(keyCode: UInt16, flags: CGEventFlags, autorepeat: Bool,
                                        post: @escaping (CGEvent) -> Void) {
        guard interceptBoundaryKeys, tapIsActive, !autorepeat, !currentWordKeys.isEmpty,
              flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty else { return }
        let settings = SettingsManager.shared
        let key: WordEndKey
        switch keyCode {
        case KC.enter, KC.keypadEnter:
            guard settings.wordEndOnEnter else { return }
            key = .enter
        case KC.tab:
            guard settings.wordEndOnTab, !flags.contains(.maskShift) else { return }
            key = .tab
        default:
            return
        }
        prevWordBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        onWordBoundary?(boundary(key, keys: currentWordKeys), post)
    }

    /// 3.5.0b (ревью C1): выполнить body с выключенным tap'ом. Активный tap держит каждое
    /// событие, пока колбэк не ответит, а колбэк живёт в главном run loop: пути, которые с
    /// главного потока шлют Cmd+C / Shift+Cmd+← и ждут эффекта в usleep, иначе получали бы
    /// свои клавиши только после возврата. listenOnly-tap ничего не держит — там просто body.
    /// Нажатия за время паузы буфер не видел — после неё сброс (вложенные вызовы — по счётчику).
    func withTapSuspended<T>(_ body: () -> T) -> T {
        guard tapIsActive, let tap = eventTap else { return body() }
        suspendDepth += 1
        if suspendDepth == 1 { CGEvent.tapEnable(tap: tap, enable: false) }
        defer {
            suspendDepth -= 1
            if suspendDepth == 0 {
                CGEvent.tapEnable(tap: tap, enable: true)
                fullReset()
            }
        }
        return body()
    }

    /// Сброс буфера при клике мышью — иначе backspace перепечатки сотрёт не то
    /// (курсор мог уехать в другое место).
    func resetInputTracking() {
        triggerArmed = false
        disarmHotkeys()
        lastTapTime = nil
        keysTypedSinceConversion = true
        if caretFlagEnabled { DispatchQueue.main.async { [weak self] in self?.onUserInput?() } }   // issue #10: клик прячет флаг у каретки
        fullReset()
    }

    // MARK: - Event Handling

    fileprivate func handleKeyDown(keyCode: UInt16, flags: CGEventFlags, char: Character? = nil,
                                   postBeforeSpace: ((CGEvent) -> Void)? = nil) {
        if !receivedKeyDown {
            receivedKeyDown = true
            rslog("Keyboard event tap received its first keyDown")
        }
        // На части клавиатур Глобус шлёт и keyDown (179): это не печать, хоткей Fn он сбивать
        // не должен (ревью #38).
        if keyCode == KC.globeKeyDown { return }
        triggerArmed = false
        disarmHotkeys()   // клавиша между модификаторами = шорткат, не хоткей
        lastTapTime = nil
        keysTypedSinceConversion = true
        if caretFlagEnabled { DispatchQueue.main.async { [weak self] in self?.onUserInput?() } }   // issue #10: спрятать флаг при печати

        // Удалёнка: Screen Sharing шлёт проброшенные символы как keyCode 0 + юникод. Перехватываем
        // ТОЛЬКО в режиме удалённого стола. КРИТИЧНО: локально keyCode 0 — это обычная клавиша
        // 'a' (и 'ф' в ЙЦУКЕН), её нельзя глотать, иначе ломается локальная конверсия слов с
        // этими буквами. В локальном режиме сюда не заходим — буква идёт обычным путём ниже.
        if SettingsManager.shared.remoteDesktopMode, keyCode == 0 {
            // ⌘A/⌘C/⌘X и т.п. по удалёнке прилетают как символ 'a' (keyCode 0) с флагом Cmd.
            // НЕ копим их в буфер: иначе ⌘A добавляет лишнюю «ф» (keyCode 0 = 'ф' в ЙЦУКЕН)
            // и рушит выделение. Сбрасываем буфер — триггер уйдёт по clipboard-пути (выделение).
            // Локальный аналог этого guard — ниже, на ветке модификаторов (PR #13).
            let modifiers = flags.intersection([.maskCommand, .maskControl, .maskAlternate])
            if !modifiers.isEmpty { fullReset(); return }
            if let ch = char { handleForwardedChar(ch) }
            return
        }

        // Структурные клавиши обрабатываем ВСЕГДА, даже если в flags остался
        // «грязный» модификатор (stale .maskAlternate и т.п.) — иначе счётчик
        // слова не сбрасывается и конвертация захватывает лишние символы.

        // Пробел — единственная граница через которую можно вернуться
        if keyCode == KC.space {
            if !flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty {
                fullReset()
                return
            }
            finishWord(postBeforeSpace: postBeforeSpace)
            return
        }

        // Enter, Tab — полный сброс
        if keyCode == KC.enter || keyCode == KC.keypadEnter || keyCode == KC.tab {
            fullReset()
            return
        }

        // Стрелки (Left…Up) — полный сброс
        if keyCode >= KC.left && keyCode <= KC.up {
            fullReset()
            return
        }

        // Backspace
        if keyCode == KC.backspace {
            if currentWordLength > 0 {
                currentWordLength -= 1
                if !currentWordKeys.isEmpty { currentWordKeys.removeLast() }
                if !lineKeys.isEmpty { lineKeys.removeLast() }   // #24: синхронно с буфером строки
            } else {
                fullReset()   // стирание через границу слова — буфер строки ненадёжен, сброс
            }
            return
        }

        // (Cmd+A, Cmd+C, Cmd+X и т.п.) могло изменить выделение — сбрасываем наш буфер.
        let modifiers = flags.intersection([.maskCommand, .maskControl, .maskAlternate])
        if !modifiers.isEmpty {
            fullReset()
            return
        }

        if KeyMapping.keycodeToEN[keyCode] != nil {
            if currentWordLength == 0 {
                boundaryGeneration &+= 1
                wordAppPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                wordLayoutID = LayoutSwitcher.currentLayoutID()
                if let pid = wordAppPID, SettingsManager.shared.wordEndPipelineActive,
                   !AutoSwitchPolicy.secureInputActive { onWordStarted?(pid) }
            }
            let tk = TypedKey(keyCode: keyCode, shift: flags.contains(.maskShift), caps: flags.contains(.maskAlphaShift))
            currentWordKeys.append(tk)
            lineKeys.append(tk)   // #24: буква в буфер строки
            currentWordLength += 1
            wordBeforeBoundaryLength = 0
            boundaryCount = 0
            prevWordKeys = []
        } else {
            // Esc, F-клавиши, и т.д. — полный сброс
            fullReset()
        }
    }

    private func finishWord(postBeforeSpace: ((CGEvent) -> Void)?) {
        let hasWord = currentWordLength > 0
        if hasWord {
            wordBeforeBoundaryLength = currentWordLength
            boundaryCount = 1
            prevWordKeys = currentWordKeys
            let app = NSWorkspace.shared.frontmostApplication
            prevWordBundleID = app?.bundleIdentifier
            if wordAppPID != app?.processIdentifier {
                fullReset()
                return
            }
        } else {
            boundaryCount += 1
        }
        currentWordLength = 0
        currentWordKeys = []
        if !lineKeys.isEmpty {
            lineKeys.append(TypedKey(keyCode: KC.space, shift: false, caps: false, char: " "))
        }
        if hasWord { fireWordBoundary(postBeforeSpace: postBeforeSpace) }
    }

    /// Обработка символа, проброшенного через удалённый стол (keyCode 0 + юникод).
    /// Работаем по самому символу: пробел — граница слова, backspace — откат,
    /// буква — кладём реальный символ в буфер (конверсия пойдёт по нему, см. convertKeys).
    private func handleForwardedChar(_ ch: Character) {
        if currentWordLength == 0 {
            boundaryGeneration &+= 1
            wordAppPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            wordLayoutID = LayoutSwitcher.currentLayoutID()
        }
        // Пробел — граница слова (как локальный keyCode space)
        if ch == " " {
            finishWord(postBeforeSpace: nil)
            return
        }
        // Перенос строки / таб — полный сброс
        if ch == "\n" || ch == "\r" || ch == "\t" {
            fullReset()
            return
        }
        // Backspace / Delete — откат одной буквы
        if ch == "\u{8}" || ch == "\u{7f}" {
            if currentWordLength > 0 {
                currentWordLength -= 1
                if !currentWordKeys.isEmpty { currentWordKeys.removeLast() }
                if !lineKeys.isEmpty { lineKeys.removeLast() }   // #24
            } else {
                fullReset()
            }
            return
        }
        // Буква — кладём реальный символ (keyCode 0 = «проброшено»). shift несём из регистра.
        if ch.isLetter {
            let tk = TypedKey(keyCode: 0, shift: ch.isUppercase, caps: false, char: ch)
            currentWordKeys.append(tk)
            lineKeys.append(tk)   // #24
            currentWordLength += 1
            wordBeforeBoundaryLength = 0
            boundaryCount = 0
            prevWordKeys = []
            return
        }
        // Цифры/пунктуация/прочее: в буфер не копим, НО и слово «живым» не оставляем —
        // иначе счёт стирания разъезжается с полем и конверсия портит текст (ревью-находка:
        // «ghbdtn,» по удалёнке = 6 букв в буфере при 7 символах в поле → стёрся бы лишний).
        // Консервативно сбрасываем: слово с пунктуацией по удалёнке просто не авто-конвертится.
        fullReset()
    }

    /// Возвращает true, если событие надо «съесть» (только Caps Lock в consume-режиме).
    fileprivate func handleFlagsChanged(flags: CGEventFlags, keyCode: UInt16) -> Bool {
        handleHotkeyFlags(flags: flags, keyCode: keyCode)
        switch triggerConfig.kind {
        case .capsLock:
            guard keyCode == KC.capsLock else { return false }
            // Caps Lock шлёт одно событие на нажатие. Используем как тап и съедаем,
            // чтобы не переключался регистр.
            registerTap()
            return true

        case let .modifier(mask, left, right):
            if keyCode == KC.function, !triggerConfig.usesFn {   // Fn поверх триггера — не тап (#38)
                triggerArmed = false
                return false
            }
            let accepted = triggerConfig.accepted(left: left, right: right)
            let otherMods = TriggerConfig.pressModifiers.subtracting(mask)

            if flags.contains(mask) {
                // нажатие: армим только если это нужная клавиша и нет других модификаторов
                if accepted.contains(keyCode) && flags.intersection(otherMods).isEmpty {
                    triggerArmed = true
                    triggerPressTime = Date()
                } else {
                    triggerArmed = false  // не та сторона / комбо
                }
            } else {
                // отпускание: соло-тап нужной клавиши, быстро и без клавиш между
                if triggerArmed, accepted.contains(keyCode), let t = triggerPressTime,
                   Date().timeIntervalSince(t) < tapWindow {
                    registerTap()
                }
                triggerArmed = false
                triggerPressTime = nil
            }
            return false

        case let .combo(maskA, maskB):
            if keyCode == KC.function, !triggerConfig.usesFn {   // Fn поверх комбо — не тап (#38)
                triggerArmed = false
                return false
            }
            let both: CGEventFlags = [maskA, maskB]
            let release = triggerConfig.releaseModifiers
            if !flags.intersection(release.subtracting(both)).isEmpty {
                triggerArmed = false                 // зажат посторонний модификатор — не наш триггер
            } else if flags.contains(both) {
                // ровно оба нужных, без посторонних (и без Fn) → армим
                triggerArmed = flags.intersection(TriggerConfig.pressModifiers.subtracting(both)).isEmpty
                triggerPressTime = triggerArmed ? Date() : nil
            } else if flags.intersection(release).isEmpty {
                // всё отпущено: комбо, если был армлен и без клавиш между (triggerArmed это
                // гарантирует). Окно расширено 0.4→2с (comboTapWindow, issue #21), но потолок
                // сохранён — не срабатывать на попутное удержание во время скролла/жеста.
                if triggerArmed, let t = triggerPressTime, Date().timeIntervalSince(t) < comboTapWindow {
                    registerTap()
                }
                triggerArmed = false
                triggerPressTime = nil
            }
            // частичное состояние (зажат один из двух) — ждём, ничего не трогаем
            return false
        }
    }

    private func disarmHotkeys() {
        for slot in Array(detectors.keys) { detectors[slot]?.disarm() }
    }

    /// Дополнительные хоткеи параллельно триггеру. Каждый со своей машиной тапа; конфликты
    /// с триггером и между собой отсечены ещё в TriggerConfig.forSlot.
    private func handleHotkeyFlags(flags: CGEventFlags, keyCode: UInt16) {
        for slot in Array(detectors.keys) {
            guard detectors[slot]?.handle(flags: flags, keyCode: keyCode, tapWindow: tapWindow,
                                          comboTapWindow: comboTapWindow) == true else { continue }
            rslog("hotkey: \(slot.rawValue)")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch slot {
                case .switchLayout: self.onSwitchHotkey?()
                case .changeCase: self.onCaseHotkey?()
                case .layout1: self.onLayoutHotkey?(1)
                case .layout2: self.onLayoutHotkey?(2)
                case .addException: self.onExceptionHotkey?()
                case .trigger: break
                }
            }
        }
    }

    /// Учитывает одиночный/двойной тап и запускает конвертацию.
    private func registerTap() {
        if triggerConfig.doubleTap {
            if let last = lastTapTime, Date().timeIntervalSince(last) < tapWindow {
                lastTapTime = nil
                fireConversion()
            } else {
                lastTapTime = Date()  // ждём второй тап
            }
        } else {
            fireConversion()
        }
    }

    private func fireConversion() {
        if !keysTypedSinceConversion {
            rslog("trigger: RECONVERT")
            DispatchQueue.main.async { [weak self] in self?.onAltReconvert?() }
        } else {
            rslog("trigger: CONVERT")
            DispatchQueue.main.async { [weak self] in self?.onAltTap?() }
        }
    }
}

// MARK: - C Callback

/// Событие принадлежит системе: возвращаем его как есть, passUnretained. passRetained
/// добавлял лишнее удержание на КАЖДОЕ нажатие и щелчок, и события копились в памяти
/// (за несколько дней работы — десятки мегабайт).
private func keyboardCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo {
            let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            monitor.resetInputTracking()
            if let tap = monitor.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        return Unmanaged.passUnretained(event)
    }

    // Игнорируем собственные симулированные события по маркеру
    if event.getIntegerValueField(.eventSourceUserData) == kRuSwitcherEventMarker {
        return Unmanaged.passUnretained(event)
    }

    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .keyDown {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let remote = SettingsManager.shared.remoteDesktopMode
        // Удалёнка: игнорируем авто-повтор клавиш — латентность Screen Sharing рождает
        // ложные повторы (тот самый «фффффф»), засоряющие буфер конверсии.
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0, remote {
            return Unmanaged.passUnretained(event)
        }
        monitor.processBoundaryKey(keyCode: keyCode, flags: event.flags,
                                   autorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                                   post: { $0.tapPostEvent(proxy) })
        // Удалёнка: Screen Sharing пробрасывает символы как keyCode 0 + юникод-payload.
        // Читаем сам символ — без него буфер забивается keyCode 0 (= один символ → «фффффф»).
        var forwardedChar: Character? = nil
        if remote, keyCode == 0 {
            var buf = [UniChar](repeating: 0, count: 4)
            var len = 0
            event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &len, unicodeString: &buf)
            if len >= 1, let scalar = UnicodeScalar(buf[0]) {
                forwardedChar = Character(scalar)
                if SettingsManager.shared.debugLogEnabled {
                    // Приватность: НЕ логируем сам символ/кодпоинт — иначе получается посимвольный
                    // лог удалённой сессии. Фиксируем только факт проброса.
                    rslog("remote: forwarded char")
                }
            }
        }
        // Events inserted through this proxy reach the app before the original space.
        let poster: ((CGEvent) -> Void)? = keyCode == KC.space && monitor.tapIsActive && !remote
            ? { $0.tapPostEvent(proxy) } : nil
        monitor.handleKeyDown(keyCode: keyCode, flags: event.flags, char: forwardedChar,
                              postBeforeSpace: poster)
    } else if type == .flagsChanged {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if monitor.handleFlagsChanged(flags: event.flags, keyCode: keyCode) {
            return nil  // съедаем Caps Lock, чтобы не переключался регистр
        }
    } else if type == .leftMouseDown || type == .rightMouseDown {
        monitor.resetInputTracking()
    }

    return Unmanaged.passUnretained(event)
}
