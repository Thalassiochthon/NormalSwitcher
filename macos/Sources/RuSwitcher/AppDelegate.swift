import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var statusMenuPasteTarget: NSRunningApplication?
    private let keyboardMonitor = KeyboardMonitor()
    private let textConverter = TextConverter()
    private lazy var clipboardHistory = ClipboardHistory(converter: textConverter, keyboardMonitor: keyboardMonitor)
    private let settingsController = SettingsWindowController()
    private let perAppLayoutManager = PerAppLayoutManager()
    private var permissionCheckTimer: Timer?
    private var requestedInputMonitoring = false
    private var permissionsReminder: DispatchWorkItem?
    private var permissionsAlertShown = false
    private var iconRefreshTimer: Timer?
    private var updateCheckTimer: Timer?   // периодическая авто-проверка обновлений, пока приложение работает
    private var monitoringActive = false
    private var caretIndicator: CaretIndicator?   // issue #10: флаг у каретки (бета, по умолчанию OFF)
    private var startedAsLoginItem = false
    private let secureNotice = SecureInputNotice()  // issue #27: подсказка о защ. вводе без кражи фокуса
    private var lastFlagShown: String?            // идентичность раскладки для детекта смены (не title!)
    private var badgeCache: [String: NSImage] = [:]  // монохромные плашки, чтобы не перерисовывать 2с-опросом

    func applicationDidFinishLaunching(_ notification: Notification) {
        startedAsLoginItem = Self.launchedAsLoginItem()   // Apple-событие запуска доступно только сейчас
        clipboardHistory.configure()
        setupStatusItem()
        setupSettingsCallbacks()
        syncLoginItem()
        // «Запускались раньше?» снимаем ДО визарда: он через startMonitoring →
        // offerLaunchAtLoginIfNeeded выставляет launchAtLoginAsked уже на этом же
        // первом запуске, иначе «Что нового» ложно показалось бы на свежей установке.
        let ranBefore = SettingsManager.shared.launchAtLoginAsked
        runPermissionWizard()
        showWhatsNewIfNeeded(hasRunBefore: ranBefore)
        showBetaWhatsNewIfNeeded()   // отдельная витрина для бет (текст из бета-фида)
        UpdateChecker.checkOnLaunch()
        // Периодическая авто-проверка обновлений, пока приложение работает (не только на старте).
        // Проверка обновляет пункт меню, если включена в настройках.
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { _ in
            Task { @MainActor in
                UpdateChecker.checkPeriodic()
                await FrequencyPacks.refreshIfDue()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            Task { @MainActor in await FrequencyPacks.refreshIfDue() }
        }
        // Прогрев NSSpellChecker: первый чек поднимает XPC AppleSpell (сотни мс на main) —
        // прогреваем в тихую паузу после старта, а не на первом пробеле пользователя.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            Task { @MainActor in Dict.warmUp() }
        }

        // Opening from Finder or Spotlight should be visible even if the menu bar is full.
        // If permissions are missing, the wizard already handles the first interaction.
        if !startedAsLoginItem && permissionsGranted {
            settingsController.showWindow()
        }
    }

    /// Запущены ли мы как login item (автостарт): loginwindow помечает oapp-событие
    /// флагом keyAELaunchedAsLogInItem в propData.
    private static func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            == OSType(keyAELaunchedAsLogInItem)
    }

    private func setupSettingsCallbacks() {
        settingsController.onAutoSwitchChanged = { [weak self] _ in
            // Не адресуем пункт по индексу: с 2.5.0 item(at: 0) — строка версии, а со списком
            // раскладок индексы вообще динамические. Пересборка — как у соседних колбэков.
            self?.refreshSpaceTap()
            self?.rebuildMenu()
        }
        settingsController.onPerAppLayoutChanged = { [weak self] enabled in
            guard let self else { return }
            if enabled {
                self.startPerAppLayout()
            } else {
                self.perAppLayoutManager.stop()
            }
        }
        settingsController.onLanguageChanged = { [weak self] in
            self?.rebuildMenu()
        }
        settingsController.onTriggerChanged = { [weak self] in
            self?.reconfigureTap()
        }
        settingsController.onMenuBarAppearanceChanged = { [weak self] in self?.updateStatusIcon() }
        settingsController.onAutoConvertChanged = { [weak self] enabled in
            self?.refreshSpaceTap()
            self?.rebuildMenu()  // синхронизировать галочку в меню
            if enabled { self?.offerFrequencyPacksIfNeeded() }
        }
        settingsController.onRemoteDesktopChanged = { [weak self] _ in
            self?.reconfigureTap()  // уровень tap зависит от режима
            self?.rebuildMenu()
        }
        settingsController.onCaretFlagChanged = { [weak self] _ in
            self?.rebuildMenu()          // синхронизировать галочку в меню
            self?.syncCaretIndicator()   // создать/снести индикатор + обновить гейт onUserInput
        }
        settingsController.onCheckPermissions = { [weak self] in
            self?.runPermissionWizard(interactive: true)
        }
        settingsController.onShare = { [weak self] button in
            self?.buildShareSubmenu().popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: button)
        }
        settingsController.onHideIconChanged = { [weak self] hide in
            self?.statusItem.isVisible = !hide
        }
        settingsController.onClipboardHistoryChanged = { [weak self] in
            guard let self else { return }
            let configured = self.clipboardHistory.configure()
            self.rebuildMenu()
            if !configured {
                self.clipboardHistory.showStorageError()
            } else if SettingsManager.shared.clipboardHistoryEnabled, !self.clipboardHistory.shortcutAvailable {
                let alert = NSAlert()
                alert.messageText = L10n.clipboardHistoryShortcutUnavailable
                alert.runModal()
            }
        }
        settingsController.onClipboardHistoryPersistenceChanged = { [weak self] in
            guard let self, !self.clipboardHistory.updatePersistence() else { return }
            self.clipboardHistory.showStorageError()
        }
        settingsController.onClipboardHistoryShortcutChanged = { [weak self] shortcut in
            guard let self else { return false }
            let changed = self.clipboardHistory.changeShortcut(shortcut)
            self.rebuildMenu()
            return changed
        }
    }

    /// Повторный запуск приложения (двойной клик в «Программах», Spotlight, Launchpad) —
    /// стандартный для menu-bar-утилит путь добраться до настроек при СКРЫТОЙ иконке.
    /// Открываем настройки и при видимой иконке: reopen без реакции выглядит как «не работает».
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsController.showWindow()
        return false
    }

    // MARK: - Learn-from-undo (предложить добавить слово в never-convert)

    /// Последняя авто-конвертация: слово (как было набрано) + время. Если пользователь
    /// сразу откатывает ручным триггером — предлагаем занести слово в исключения.
    private var lastAutoConverted: (word: String, at: Date)?
    /// Анти-наг: за сессию про одно слово спрашиваем один раз.
    private var offeredExceptionWords: Set<String> = []

    /// Анти-наг для уведомления о защищённом вводе (не чаще раза в N секунд).
    private var lastSecureNoticeAt: Date?

    /// Ручной триггер нажат, но активен защищённый ввод (фокус в поле пароля — часто во
    /// вкладке браузера в фоне) → конверсия by design не трогает клавиши. Без подсказки это
    /// выглядит как «приложение сломалось» (реальный кейс: пользователь мял триггер и лез в
    /// ioreg). Показываем разовое (троттлённое) объяснение с лечением.
    private func notifySecureInputPaused() {
        guard SettingsManager.shared.secureInputNoticeEnabled else { return }
        if let last = lastSecureNoticeAt, Date().timeIntervalSince(last) < 180 { return }
        lastSecureNoticeAt = Date()
        let holder = AutoSwitchPolicy.secureInputHolderName() ?? L10n.securePausedUnknownApp
        // issue #27: неактивирующая плашка вместо NSAlert.runModal() — модалка активировала
        // приложение и уводила фокус из поля пароля (пользователь терял место в терминале).
        secureNotice.show(title: L10n.securePausedTitle,
                          body: String(format: L10n.securePausedBody, holder))
    }

    private func offerExceptionAfterUndo() {
        guard let last = lastAutoConverted, Date().timeIntervalSince(last.at) < 8 else { return }
        lastAutoConverted = nil
        let word = last.word
        let key = word.lowercased()
        guard !offeredExceptionWords.contains(key) else { return }
        offeredExceptionWords.insert(key)
        guard !SettingsManager.shared.deniedWordsSet.contains(key) else { return }

        let alert = NSAlert()
        alert.messageText = L10n.learnQuestion(word)
        alert.addButton(withTitle: L10n.learnAdd)
        alert.addButton(withTitle: L10n.learnNotNow)
        if alert.runModal() == .alertFirstButtonReturn {
            var list = SettingsManager.shared.deniedWords
            list.append(word)
            SettingsManager.shared.deniedWords = list
            settingsController.reloadExceptionLists()
            rslog("learn: added word (len=\(word.count)) to never-convert")
        }
    }

    private func startPerAppLayout() {
        perAppLayoutManager.onLayoutRestored = { [weak self] in
            self?.keyboardMonitor.markConverted()
            self?.textConverter.clearState()
            self?.updateStatusIcon()
        }
        perAppLayoutManager.start()
    }

    // MARK: - Login Item Sync

    /// Синхронизирует состояние автозагрузки с системой при старте.
    /// Если галочка включена, но Login Item потерян (переустановка/обновление) — перерегистрирует.
    /// Если галочка выключена, но Login Item есть — снимает.
    private func syncLoginItem() {
        let settings = SettingsManager.shared
        let wanted = settings.launchAtLogin
        let status = settings.loginItemStatus

        rslog("Login item sync: wanted=\(wanted) status=\(status.rawValue)")

        if wanted && status != .enabled {
            // Галочка стоит, но Login Item не активен — перерегистрируем
            rslog("Re-registering login item...")
            settings.launchAtLogin = true  // setter вызовет doUpdateLoginItem
        } else if !wanted && status == .enabled {
            // Галочка снята, но Login Item активен — убираем
            rslog("Unregistering stale login item...")
            settings.launchAtLogin = false
        }
    }

    // MARK: - Permission Wizard

    private func runPermissionWizard(interactive: Bool = false) {
        if activateKeyboardMonitoring() {
            if interactive { showPermissionsOKAlert() }
            return
        }

        let settings = SettingsManager.shared
        let explain = interactive || settings.permissionsPrompted
        settings.permissionsPrompted = true

        if !AXIsProcessTrusted() {
            let options = ["AXTrustedCheckOptionPrompt" as CFString: true as CFBoolean] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }

        startPermissionPolling { [weak self] in
            _ = self?.activateKeyboardMonitoring()
        }
        if explain {
            permissionsReminder?.cancel()
            DispatchQueue.main.async { [weak self] in self?.showPermissionsMissingAlert() }
        } else {
            armPermissionsReminder()
        }
    }

    private var permissionsGranted: Bool {
        AXIsProcessTrusted() && keyboardMonitor.isRunning
    }

    private func activateKeyboardMonitoring() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        if !monitoringActive {
            startMonitoring()
        } else if !keyboardMonitor.isRunning {
            keyboardMonitor.reconfigure()
        }

        if permissionsGranted {
            permissionCheckTimer?.invalidate()
            permissionCheckTimer = nil
            permissionsReminder?.cancel()
            return true
        }

        // A separate listen grant is only needed if the keyboard event tap could not start.
        if !requestedInputMonitoring {
            requestedInputMonitoring = true
            CGRequestListenEventAccess()
        }
        return false
    }

    private func armPermissionsReminder() {
        permissionsReminder?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.showPermissionsMissingAlert() }
        permissionsReminder = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    /// Нет разрешений и системного окна запроса больше не будет: ведём в нужный раздел настроек.
    private func showPermissionsMissingAlert() {
        guard !permissionsGranted, !permissionsAlertShown else { return }
        permissionsAlertShown = true
        defer { permissionsAlertShown = false }
        let accessibility = AXIsProcessTrusted()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.permissionsMissingTitle
        alert.informativeText = accessibility ? L10n.permissionsMissingInput : L10n.permissionsMissingText
        alert.addButton(withTitle: L10n.permissionsMissingOpen)
        alert.addButton(withTitle: L10n.permissionsMissingLater)
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let pane = accessibility ? "Privacy_ListenEvent" : "Privacy_Accessibility"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Подтверждение при ручной проверке, когда все разрешения уже выданы
    private func showPermissionsOKAlert() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.permissionsOkTitle
        alert.informativeText = L10n.permissionsOkText
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Опрос идёт и пока открыто наше окно с разрешениями: в common-режимах таймер не стоит
    /// на модальном цикле.
    private func startPermissionPolling(_ check: @escaping @MainActor () -> Void) {
        permissionCheckTimer?.invalidate()
        let timer = Timer(timeInterval: 1.5, repeats: true) { _ in
            Task { @MainActor in check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionCheckTimer = timer
    }

    // MARK: - Start Monitoring

    private func startMonitoring() {
        if !keyboardMonitor.start(
            onAltTap: { [weak self] in
                guard let self else { return }
                guard SettingsManager.shared.autoSwitchEnabled else { return }
                // Приватность: в защищённом поле (пароль) ничего не делаем — ставим ДО
                // remote-defer, чтобы поведение точно совпадало с handleAutoConvert.
                guard !AutoSwitchPolicy.secureInputActive else { rslog("trigger: bail secure-input"); self.notifySecureInputPaused(); return }
                if AutoSwitchPolicy.shouldDeferToRemoteClient {
                    // Удалёнка: текст конвертит офисный инстанс по реальным проброшенным символам
                    // (Fix №6). А здесь меняем СВОЮ раскладку — чтобы дальнейший ввод пошёл уже
                    // в правильной раскладке и не пришлось конвертить каждое слово.
                    LayoutSwitcher.switchToOpposite()
                    self.updateStatusIcon()
                    rslog("trigger: local layout switched, conversion handled by controlled instance")
                    return
                }
                // issue #16: в Spotlight обычный путь оставляет лишнюю букву (серое
                // автодополнение съедает Backspace). Особый путь: Cmd+A + буфер, без
                // Backspace. Гейт isActive() строгий (окно видимо + Spotlight держит поле),
                // поэтому здесь мы ТОЧНО в Spotlight — конвертим только своим путём и НЕ
                // проваливаемся в буфер/count-пути (они тут дают лишнюю букву), что бы
                // convertSpotlight ни вернул.
                if SpotlightAX.isActive() {
                    if self.textConverter.convertSpotlight() {
                        self.keyboardMonitor.markConverted()
                        LayoutSwitcher.switchToOpposite()
                        self.updateStatusIcon()
                        self.lastAutoConverted = nil
                    }
                    return
                }
                // issue #24: режим «вся строка».
                if SettingsManager.shared.convertWholeLine {
                    let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                    if AutoSwitchPolicy.isTerminalApp(frontID) {
                        // Терминал: нет OS-выделения → перепечатываем строку по буферу нажатий.
                        // НЕПУСТОЙ буфер (в т.ч. no-op на уже верной строке) завершаем ЗДЕСЬ и НЕ
                        // проваливаемся на последнее слово — иначе безусловный флип испортил бы
                        // верное слово, напр. «git log»→«git дщп» (скептик 3.2.0). На слово падаем
                        // только при ПУСТОМ/сброшенном буфере (пунктуация/Enter/сдвиг курсора).
                        if !self.keyboardMonitor.lineKeys.isEmpty {
                            if self.textConverter.convertLineBuffer(self.keyboardMonitor.lineKeys) {
                                self.keyboardMonitor.markConverted()
                                LayoutSwitcher.switchToOpposite()
                                self.updateStatusIcon()
                                self.lastAutoConverted = nil
                            }
                            return
                        }
                    } else {
                        // Обычные приложения: сами выделяем строку (Shift+Cmd+←) и конвертируем.
                        if self.textConverter.convertLine() {
                            self.keyboardMonitor.markConverted()
                            LayoutSwitcher.switchToOpposite()
                            self.updateStatusIcon()
                            self.lastAutoConverted = nil
                        }
                        return   // whole-line в обычной проге — всегда завершаем (не last-word)
                    }
                }
                let keys = self.keyboardMonitor.currentWordKeys
                let prevKeys = self.keyboardMonitor.prevWordKeys
                let bc = self.keyboardMonitor.boundaryCount
                if self.textConverter.convert(wordKeys: keys, prevWordKeys: prevKeys, boundaryCount: bc) {
                    self.keyboardMonitor.markConverted()
                    LayoutSwitcher.switchToOpposite()
                    self.updateStatusIcon()
                    self.lastAutoConverted = nil
                }
            },
            onAltReconvert: { [weak self] in
                guard let self else { return }
                guard SettingsManager.shared.autoSwitchEnabled else { return }
                guard !AutoSwitchPolicy.secureInputActive else { rslog("reconvert: bail secure-input"); self.notifySecureInputPaused(); return }
                if AutoSwitchPolicy.shouldDeferToRemoteClient {
                    // Удалёнка: текст конвертит офисный инстанс по реальным проброшенным символам
                    // (Fix №6). А здесь меняем СВОЮ раскладку — чтобы дальнейший ввод пошёл уже
                    // в правильной раскладке и не пришлось конвертить каждое слово.
                    LayoutSwitcher.switchToOpposite()
                    self.updateStatusIcon()
                    rslog("trigger: local layout switched, conversion handled by controlled instance")
                    return
                }
                // issue #16: в Spotlight реконверт — тот же путь (Cmd+A + буфер), он
                // реверсивен (конвертит текущее содержимое обратно). НЕ проваливаемся в
                // count-based reconvert() в Spotlight (skeptic: он вайпит буфер и селектит
                // по счётчику — ровно то, чего избегаем).
                if SpotlightAX.isActive() {
                    if self.textConverter.convertSpotlight() {
                        self.keyboardMonitor.markConverted()
                        LayoutSwitcher.switchToOpposite()
                        self.updateStatusIcon()
                    }
                    return
                }
                // 3.5.0b: откат автозамены/правки раскладку не трогает (её и не меняли).
                let switchesLayout = self.textConverter.lastUndoSwitchesLayout
                if self.textConverter.reconvert() {
                    self.keyboardMonitor.markConverted()
                    if switchesLayout {
                        LayoutSwitcher.switchToOpposite()
                        self.updateStatusIcon()
                    }
                    self.offerExceptionAfterUndo()
                }
            }
        ) {
            return
        }

        monitoringActive = true
        keyboardMonitor.onWordBoundary = { [weak self] postBeforeSpace in
            self?.handleAutoConvert(postBeforeSpace: postBeforeSpace)
        }
        keyboardMonitor.onWordEndSync = { [weak self] key, keys, code, flags in
            self?.handleWordEndSync(key: key, keys: keys, keyCode: code, flags: flags) ?? false
        }
        // Ревью C1: пути с Cmd+C / Shift+Cmd+← на главном потоке — при выключенном tap'е.
        textConverter.suspendTap = { [weak self] body in
            guard let self else { body(); return }
            self.keyboardMonitor.withTapSuspended(body)
        }
        keyboardMonitor.onUserInput = { [weak self] in self?.caretIndicator?.userTyped() }  // issue #10
        // issue #14: хоткей чистого переключения раскладки (без конверсии). Буфер после
        // явной смены раскладки неактуален — тот же паттерн, что per-app restore и меню.
        keyboardMonitor.onSwitchHotkey = { [weak self] in
            guard let self, SettingsManager.shared.autoSwitchEnabled else { return }
            if AutoSwitchPolicy.shouldDeferToRemoteClient {
                // Удалёнка (фокус в клиенте Screen Sharing): переключаем только СВОЮ
                // раскладку, как defer-ветка триггера. markConverted/clearState тут лишние —
                // буфер наполняется через handleForwardedChar, а проброшенные модификаторы
                // сами переключат раскладку на контролируемой машине.
                LayoutSwitcher.switchToOpposite()
                self.updateStatusIcon()
                rslog("switch hotkey: local layout switched (remote client focused)")
                return
            }
            LayoutSwitcher.switchToOpposite()
            self.keyboardMonitor.markConverted()
            self.textConverter.clearState()
            self.updateStatusIcon()
        }
        // «Всегда раскладка 1/2» (запрос kobygold, discussion #32): детерминированно, без
        // переключателя — не надо смотреть на индикатор. Уже стоит нужная — ничего не делаем.
        keyboardMonitor.onLayoutHotkey = { [weak self] n in
            guard let self, SettingsManager.shared.autoSwitchEnabled else { return }
            let settings = SettingsManager.shared
            let sources = LayoutSwitcher.installedLayouts()
            let id = n == 1
                ? (settings.layout1ID.isEmpty ? LayoutSwitcher.autoDetectID1(from: sources) : settings.layout1ID)
                : (settings.layout2ID.isEmpty ? LayoutSwitcher.autoDetectID2(from: sources) : settings.layout2ID)
            guard !id.isEmpty, id != LayoutSwitcher.currentLayoutID() else { return }
            guard sources.contains(where: { LayoutSwitcher.sourceID($0) == id }) else {
                rslog("layout hotkey: layout \(n) is not installed")   // удалили из системы — буфер не трогаем
                NSSound.beep()
                return
            }
            LayoutSwitcher.switchTo(layoutID: id)
            if !AutoSwitchPolicy.shouldDeferToRemoteClient {   // удалёнка: буфер живёт на той стороне
                self.keyboardMonitor.markConverted()
                self.textConverter.clearState()
            }
            self.updateStatusIcon()
        }
        // Хоткей «в исключения» (запрос из Telegram): выделил слово или только что его набрал →
        // хоткей → слово в «Никогда не конвертировать», без похода в настройки.
        keyboardMonitor.onExceptionHotkey = { [weak self] in
            self?.addWordToExceptions()
        }
        // issue #29: хоткей смены регистра последнего слова / выделения. Раскладку не трогает,
        // в защищённом поле — пас (приватность), как у триггера.
        keyboardMonitor.onCaseHotkey = { [weak self] in
            guard let self else { return }
            guard !AutoSwitchPolicy.secureInputActive else { rslog("case: bail secure-input"); self.notifySecureInputPaused(); return }
            // Скептик #29: те же гейты, что у onAltTap/onSwitchHotkey. Удалёнка — текст правит
            // контролируемый инстанс (у нас нет своей раскладки для флипа, регистр просто пропускаем).
            if AutoSwitchPolicy.shouldDeferToRemoteClient { rslog("case: bail remote-defer"); return }
            // Spotlight: count-путь оставил бы лишнюю букву (issue #16), а AX там флейкует — не трогаем.
            if SpotlightAX.isActive() { rslog("case: bail spotlight"); return }
            // issue #29: смена регистра зеркалит триггер конверсии — уважает «Convert whole line»
            // (запрос kobygold). Терминал → по буферу строки; обычное приложение → AX-выделение строки.
            if SettingsManager.shared.convertWholeLine {
                let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                if AutoSwitchPolicy.isTerminalApp(frontID) {
                    if !self.keyboardMonitor.lineKeys.isEmpty {
                        if self.textConverter.changeCaseLineBuffer(self.keyboardMonitor.lineKeys) { self.textConverter.clearState() }
                        return   // непустой буфер строки — завершаем здесь (как onAltTap)
                    }
                    // пустой буфер → падаем на последнее слово ниже
                } else {
                    if self.textConverter.changeCaseLine() { self.textConverter.clearState() }
                    return   // обычное приложение, whole-line — всегда завершаем здесь
                }
            }
            // Скептик #29: НЕ markConverted() — буфер слова нужен, чтобы повторный тап циклил
            // регистр. Чистим reconvert-состояние, иначе следующий реконверт сработал бы по
            // устаревшим lastOriginal/lastConverted и испортил текст.
            let keys = self.keyboardMonitor.currentWordKeys
            if self.textConverter.changeCase(wordKeys: keys) {
                self.textConverter.clearState()
            }
        }
        syncCaretIndicator()      // затем создаём индикатор — без стартового ложного «попа»
        rslog("Monitoring started successfully")

        if SettingsManager.shared.perAppLayout {
            startPerAppLayout()
        }

        // Предлагаем автозагрузку и автозамену при первом запуске (по разу)
        offerLaunchAtLoginIfNeeded()
        // Словарь предлагаем не в тот же запуск, что онбординг (иначе три окна подряд), и только
        // при ручном запуске (в т.ч. перезапуск после обновления): при старте вместе с системой
        // модальное окно выскочило бы поверх входа, а отложенное — посреди набора текста.
        if !offerAutoConvertIfNeeded(), !startedAsLoginItem {
            offerFrequencyPacksIfNeeded()
        }
    }

    /// Слово на конце для конвейера (3.5.0b).
    private struct WordCtx {
        let keys: [TypedKey]
        let pair: (original: String, converted: String)
        let langs: (current: String, opposite: String)
    }

    /// Общие гейты и решение конвейера конца слова (3.5.0b): автозамена → конверсия раскладки
    /// → правка текста. nil — конвейер тут не работает (гейт или нечего решать).
    /// Точность-first: при любой неуверенности ничего не делаем. Ручной триггер не трогаем.
    private func evaluateWordEnd(keys allKeys: [TypedKey]) -> (WordEndAction, WordCtx)? {
        let settings = SettingsManager.shared
        guard settings.autoSwitchEnabled else { rslog("auto: bail master-off"); return nil }
        guard settings.wordEndPipelineActive else { rslog("auto: bail flag-off"); return nil }
        guard !AutoSwitchPolicy.secureInputActive else { rslog("auto: bail secure-input"); return nil }
        let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if AutoSwitchPolicy.isDeniedApp(frontID) { rslog("auto: bail denied-app \(frontID ?? "?")"); return nil }
        if let captured = keyboardMonitor.prevWordBundleID, captured != frontID {
            rslog("auto: bail focus-changed"); return nil  // фокус уехал между границей и сейчас
        }
        guard !allKeys.isEmpty else { rslog("auto: bail empty-keys"); return nil }  // курсор уехал — небезопасно
        guard let fullPair = DynamicKeyMapping.convertKeys(allKeys) else { rslog("auto: bail convertKeys-nil"); return nil }

        // Язык для детектора. Для проброшенного через удалёнку текста (все символы — char)
        // направление определяем по СКРИПТУ набранного, а не по раскладке офисной машины:
        // на офисе раскладка может не соответствовать тому, что напечатали на контроллере,
        // и тогда decide ошибочно даёт keep (это и есть «авто в удалёнке не работает»).
        let charOnly = allKeys.allSatisfy { $0.char != nil }
        // Хвост сквозь пару переводим только у своего ввода: проброшенный удалёнкой текст идёт
        // литералом, а управляющая сторона (фокус в клиенте удалёнки) должна решать так же, как
        // управляемая, иначе она переключит свою раскладку на слово, которое та не тронет (#41).
        let remoteClient = settings.remoteDesktopMode && AutoSwitchPolicy.isRemoteDesktopClient(frontID)
        let suffixConvertible = !charOnly && !remoteClient
        let langs: (current: String, opposite: String)
        if charOnly {
            let typedIsCyrillic = fullPair.original.unicodeScalars.contains { $0.value >= 0x0400 && $0.value <= 0x04FF }
            langs = typedIsCyrillic ? ("ru", "en") : ("en", "ru")
        } else if let l = LayoutSwitcher.currentAndOppositeLanguage() {
            langs = l
        } else {
            rslog("auto: bail langs-nil"); return nil
        }

        let cur = String(langs.current.prefix(2)), oth = String(langs.opposite.prefix(2))
        let capsLock = allKeys.contains { $0.caps }
        // Таблицы клавиш пары — для автозамены и правок; у проброшенного удалёнкой текста
        // клавиш нет, там работает только конверсия.
        let tables = charOnly ? nil : DynamicKeyMapping.pairKeyTables()
        var cfg = WordEndConfig()
        cfg.autoConvert = settings.autoConvert
        cfg.twoCaps = settings.fixTwoCaps && !capsLock
        cfg.typos = settings.fixTypos
        cfg.hebrewPair = LayoutDetector.isHebrew(langs.current) || LayoutDetector.isHebrew(langs.opposite)

        let deps = WordEndDeps(
            abbreviation: {
                guard let t = tables else { return nil }
                let list = settings.abbreviations
                guard !list.isEmpty else { return nil }
                let revs = [Abbreviations.reverseTable(t.current), Abbreviations.reverseTable(t.other)]
                return Abbreviations.match(allKeys, list: list, reverses: revs)?.full
            },
            convertPlan: {
                // Хвост слова (#15, #35): «ghbdtn,» → ядро «привет» + запятая литералом;
                // «pyf.» → «знаю» целиком; «levf.» (дума. / думаю) → неоднозначно, не трогаем.
                let plan = LayoutDetector.plan(typed: fullPair.original, converted: fullPair.converted,
                                               canSplit: fullPair.original.count == allKeys.count,
                                               currentLang: langs.current, otherLang: langs.opposite,
                                               capsLock: capsLock, suffixConvertible: suffixConvertible)
                guard case .convert(let core) = plan else {
                    rslog("auto: len=\(fullPair.original.count) \(langs.current)/\(langs.opposite) plan=\(plan)")  // слова не логируем (приватность)
                    return nil
                }
                return core
            },
            convertedCore: { String(fullPair.converted.prefix($0)) },
            isTargetWord: { Dict.isValidTarget($0, lang: oth) },
            isCurrentWord: { Dict.isValidTarget($0, lang: cur) },
            numberFix: {
                guard let t = tables else { return nil }
                return TextFixes.fixNumber(keys: allKeys, typed: fullPair.original,
                                           otherChar: { t.other[KeyStroke(code: $0, shift: false)] })
            },
            typoFix: {
                guard let t = tables, Dict.isAvailable(cur), !capsLock else { return nil }
                // Набрано не в той раскладке (автоконверсия выключена) — не «чиним» в чужое слово.
                if Dict.isValidTarget(fullPair.converted.lowercased(), lang: oth) { return nil }
                let pack = FrequencyPacks.pack(for: cur)
                return TextFixes.fixTypo(
                    keys: allKeys, typed: fullPair.original,
                    charFor: { t.current[KeyStroke(code: $0, shift: $1)] },
                    isTypedWord: { Dict.isValidTarget($0, lang: cur) },
                    // Пак — первым: двоичный поиск дешевле NSSpellChecker.
                    isCandidateWord: { (pack?.contains($0) ?? true) && Dict.isValidWord($0, lang: cur) })
            },
            isDeniedWord: {
                let core = LayoutDetector.trailingCoreLength(typed: fullPair.original, converted: fullPair.converted,
                                                             suffixConvertible: suffixConvertible)
                return AutoSwitchPolicy.isDeniedWord(fullPair.original, fullPair.converted)
                    || AutoSwitchPolicy.isDeniedWord(String(fullPair.original.prefix(core)),
                                                     String(fullPair.converted.prefix(core)))
            })
        let action = WordEndPipeline.decide(typed: fullPair.original, config: cfg, deps: deps)
        rslog("auto: len=\(fullPair.original.count) action=\(Self.logName(action))")   // слова не логируем
        return (action, WordCtx(keys: allKeys, pair: fullPair, langs: langs))
    }

    private static func logName(_ a: WordEndAction) -> String {
        switch a {
        case .none: return "none"
        case .expand: return "expand"
        case .convert(let n, let f): return "convert(\(n)\(f == nil ? "" : ",caps"))"
        case .fix(_, let k): return "fix(\(k))"
        }
    }

    private func handleAutoConvert(postBeforeSpace: ((CGEvent) -> Void)?) {
        rslog("auto: fired")
        let deadline = ProcessInfo.processInfo.systemUptime + 0.12
        let app = postBeforeSpace == nil ? nil : NSWorkspace.shared.frontmostApplication
        let layoutID = postBeforeSpace == nil ? "" : LayoutSwitcher.currentLayoutID()
        // The first system spell check can start AppleSpell. Wait for the launch warm-up
        // before running the detector in an active keyboard callback.
        if postBeforeSpace != nil, !Dict.didWarmUp { return }
        let bc = keyboardMonitor.boundaryCount
        guard let (action, ctx) = evaluateWordEnd(keys: keyboardMonitor.prevWordKeys) else { return }
        if let postBeforeSpace {
            guard let app, action != .none, ProcessInfo.processInfo.systemUptime < deadline else { return }
            if SpotlightAX.isActive(timeout: 0.012) {
                keyboardMonitor.deferWordBoundary()
                return
            }
            guard let edit = wordEndReplacement(action, ctx),
                  textConverter.replaceBeforeSpace(original: ctx.pair.original, insert: edit.text,
                                                   deleteCount: ctx.keys.count, switchesLayout: edit.switchesLayout,
                                                   app: app, layoutID: layoutID, deadline: deadline,
                                                   post: postBeforeSpace) else { return }
            keyboardMonitor.markConverted()
            switch action {
            case .convert(let core, _):
                LayoutSwitcher.switchToOpposite()
                DispatchQueue.main.async { [weak self] in self?.updateStatusIcon() }
                lastAutoConverted = (String(ctx.pair.original.prefix(core)), Date())
            case .fix(_, .typo), .fix(_, .number):
                lastAutoConverted = (ctx.pair.original, Date())
            default:
                lastAutoConverted = nil
            }
            return
        }

        let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // Удалёнка: НЕ выходим сразу — прогоняем детектор по своему (чистому) буферу, и при
        // «не той раскладке» переключаем СВОЮ раскладку (конверсию делает инстанс на той стороне).
        let deferToRemote = SettingsManager.shared.remoteDesktopMode && AutoSwitchPolicy.isRemoteDesktopClient(frontID)
        switch action {
        case .none:
            return
        case .convert(let core, let fixedCore):
            performAutoConvert(ctx, coreLength: core, fixedCore: fixedCore, boundaryCount: bc, deferToRemote: deferToRemote)
        case .expand(let text), .fix(let text, _):
            // Автозамена и правка — только локально и не в Spotlight (там стирание по счётчику
            // оставляет лишнюю букву, #16).
            guard !deferToRemote, !SpotlightAX.isActive() else { return }
            let spaces = String(repeating: " ", count: bc)
            if textConverter.replaceTail(deleteCount: ctx.keys.count + bc, insert: text + spaces,
                                         undoOriginal: ctx.pair.original + spaces) {
                keyboardMonitor.markConverted()
                // Откат опечатки или числа предлагает «в исключения». Автозамены — нет (своё
                // сокращение), двух заглавных — тоже: в список ушло бы «когда» в нижнем регистре
                // и навсегда выключило бы конверсию «rjulf» → «когда» (ревью I2).
                if case .fix(_, let kind) = action, kind != .twoCaps {
                    lastAutoConverted = (ctx.pair.original, Date())
                } else {
                    lastAutoConverted = nil
                }
            }
        }
    }

    /// Конверсия раскладки по решению конвейера (бывшее тело handleAutoConvert после plan).
    private func performAutoConvert(_ ctx: WordCtx, coreLength: Int, fixedCore: String?,
                                    boundaryCount bc: Int, deferToRemote: Bool) {
        let suffix = String(ctx.pair.original.dropFirst(coreLength))
        let keys = suffix.isEmpty ? ctx.keys : Array(ctx.keys.prefix(coreLength))
        guard let pair = suffix.isEmpty ? ctx.pair : DynamicKeyMapping.convertKeys(keys) else {
            rslog("auto: bail convertKeys-nil"); return
        }
        if AutoSwitchPolicy.isDeniedWord(pair.original, pair.converted) { rslog("auto: bail denied-word"); return }
        rslog("auto: len=\(pair.original.count) \(ctx.langs.current)/\(ctx.langs.opposite) convert")

        if deferToRemote {
            // Удалёнка: текст конвертит офисный инстанс по реальным проброшенным символам.
            // Здесь меняем СВОЮ раскладку — чтобы дальнейший ввод пошёл уже в правильной.
            LayoutSwitcher.switchToOpposite()
            updateStatusIcon()
            rslog("auto: local layout switched, conversion handled by controlled instance")
            return
        }

        // issue #16 (авто): в Spotlight стирание по счётчику оставляет лишнюю букву (серое
        // автодополнение ест Backspace). Решение по буферу уже принято верно — меняем только
        // способ замены: по-словное выделение (Shift+Option+Left) + печать поверх, без
        // Backspace. Суффикс-случай (#15) в Spotlight редок и фиддловат — его не трогаем.
        if SpotlightAX.isActive() {
            if suffix.isEmpty,
               textConverter.convertSpotlightWord(converted: fixedCore ?? pair.converted, boundaryCount: bc) {
                keyboardMonitor.markConverted()
                LayoutSwitcher.switchToOpposite()
                updateStatusIcon()
                lastAutoConverted = (pair.original, Date())
            }
            return   // Spotlight: обычный count-путь неприменим
        }

        rslog("auto: convert \(keys.count) keys (+\(suffix.count) punct, +\(bc) sp)")
        // issue #33: хвост-знак конвертим сквозь пару, когда с обеих сторон знак
        // (Русская — ПК: «tkrb?» → «елки,»); буква по ту сторону — литерал (issue #15).
        // Скептик (HIGH): на удалёнке клавиши приходят символами (char-only), направление
        // определено по СКРИПТУ, а локальная раскладка может быть любой — карта пары дала бы
        // мусор (RU '?'→'&'). Для проброшенного текста суффикс остаётся литералом.
        let convertedSuffix = keys.allSatisfy({ $0.char != nil })
            ? suffix : DynamicKeyMapping.punctThroughCurrentPair(suffix)
        if textConverter.convert(wordKeys: [], prevWordKeys: keys, boundaryCount: bc,
                                 passthroughSuffix: convertedSuffix, typedSuffix: suffix,
                                 convertedOverride: fixedCore) {
            keyboardMonitor.markConverted()
            LayoutSwitcher.switchToOpposite()
            updateStatusIcon()
            lastAutoConverted = (pair.original, Date())
        }
    }

    /// Enter/Tab (3.5.0b): решение синхронно в колбэке tap'а (главный поток). true — клавиша
    /// придержана: перепечатка и повтор клавиши уходят асинхронно через replaceTail, отката
    /// нет (сообщение уже ушло / фокус уехал), предложения «в исключения» тоже.
    private func handleWordEndSync(key: WordEndKey, keys: [TypedKey], keyCode: UInt16, flags: CGEventFlags) -> Bool {
        if AutoSwitchPolicy.shouldDeferToRemoteClient { return false }
        // Решение — в колбэке tap'а, который держит клавишу. Дешёвые гейты идут первыми (внутри
        // evaluateWordEnd), Spotlight (CGWindowList + AX) — только если есть что менять (ревью M3).
        let started = Date()
        guard let (action, ctx) = evaluateWordEnd(keys: keys) else { return false }
        if case .none = action { return false }
        if SpotlightAX.isActive() { return false }
        // Долгое решение (холодный AppleSpell) — не рискуем таймаутом tap'а: клавиша уходит как есть.
        if Date().timeIntervalSince(started) > 0.2 { rslog("wordEnd: decision too slow — pass"); return false }
        guard let edit = wordEndReplacement(action, ctx) else { return false }
        let isTypo: Bool
        if case .fix(_, .typo) = action { isTypo = true } else { isTypo = false }
        rslog("wordEnd \(key): replace \(ctx.keys.count) → \(edit.text.count)")
        // Сразу, без main.async (ревью M2): замена встаёт в очередь инжекта раньше, чем
        // успеют прийти клавиши, нажатые после Enter.
        let replaced = textConverter.replaceTail(deleteCount: ctx.keys.count, insert: edit.text,
                                                 repostKey: (keyCode, flags), clearInlineCompletion: true,
                                                 skipIfInlineCompletion: isTypo)
        lastAutoConverted = nil
        if replaced, edit.switchesLayout {   // ревью M1: замены не было — раскладку не трогаем
            LayoutSwitcher.switchToOpposite()
            updateStatusIcon()
        }
        return true
    }

    private func wordEndReplacement(_ action: WordEndAction, _ ctx: WordCtx) -> (text: String, switchesLayout: Bool)? {
        switch action {
        case .none:
            return nil
        case .expand(let text), .fix(let text, _):
            return (text, false)
        case .convert(let core, let fixedCore):
            let suffix = String(ctx.pair.original.dropFirst(core))
            let keys = suffix.isEmpty ? ctx.keys : Array(ctx.keys.prefix(core))
            guard let pair = suffix.isEmpty ? ctx.pair : DynamicKeyMapping.convertKeys(keys),
                  !AutoSwitchPolicy.isDeniedWord(pair.original, pair.converted) else { return nil }
            let tail = keys.allSatisfy({ $0.char != nil }) ? suffix : DynamicKeyMapping.punctThroughCurrentPair(suffix)
            return ((fixedCore ?? pair.converted) + tail, true)
        }
    }

    /// Предлагает включить автозагрузку при первом запуске (один раз)
    private func offerLaunchAtLoginIfNeeded() {
        let settings = SettingsManager.shared
        guard !settings.launchAtLoginAsked else { return }
        settings.launchAtLoginAsked = true

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.wizardLaunchAtLoginTitle
        alert.informativeText = L10n.wizardLaunchAtLoginText
        alert.addButton(withTitle: L10n.wizardYes)
        alert.addButton(withTitle: L10n.wizardNo)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            settings.launchAtLogin = true
            rslog("User enabled launch at login")
        } else {
            rslog("User declined launch at login")
        }
    }

    /// Предлагает включить автозамену при первом запуске (один раз). Фича OFF по умолчанию,
    /// поэтому без явного предложения пользователь о ней не узнает.
    @discardableResult
    private func offerAutoConvertIfNeeded() -> Bool {
        let settings = SettingsManager.shared
        guard !settings.autoConvertOffered else { return false }
        settings.autoConvertOffered = true

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.onboardAutoConvertTitle
        alert.informativeText = L10n.onboardAutoConvertText
        alert.addButton(withTitle: L10n.wizardYes)
        alert.addButton(withTitle: L10n.wizardNo)

        if alert.runModal() == .alertFirstButtonReturn {
            settings.autoConvert = true
            refreshSpaceTap()
            rebuildMenu()  // синхронизировать галочку «Автоматическая конверсия» в меню
            rslog("User enabled auto-convert at onboarding")
        } else {
            rslog("User declined auto-convert at onboarding")
        }
        return true
    }

    /// Слово для хоткея «в исключения», по порядку: набираемое прямо сейчас (выделения тогда
    /// нет: клик и стрелки сбрасывают буфер) → выделение (AX, а без AX — Cmd+C в текстовом
    /// поле) → только что набранное → только что автоконвертированное (буфер после конверсии
    /// пуст, а это как раз момент, когда хоткей нужнее всего). Гейты — как у соседних хоткеев.
    private func addWordToExceptions() {
        guard SettingsManager.shared.autoSwitchEnabled else { return }
        guard !AutoSwitchPolicy.secureInputActive else { notifySecureInputPaused(); return }
        guard !AutoSwitchPolicy.shouldDeferToRemoteClient else { return }
        guard !SpotlightAX.isActive() else { NSSound.beep(); return }   // AX-выделение было бы у окна за Spotlight
        var word = ""
        if !keyboardMonitor.currentWordKeys.isEmpty {
            word = DynamicKeyMapping.convertKeys(keyboardMonitor.currentWordKeys)?.original ?? ""
        } else {
            let ax = textConverter.selectedTextAX()
            if let sel = ax, !sel.isEmpty {
                word = sel
            } else if ax == nil, let copied = textConverter.copySelectionInTextField() {
                word = copied
            }
            word = word.trimmingCharacters(in: .whitespacesAndNewlines)
            if word.isEmpty, !keyboardMonitor.prevWordKeys.isEmpty {
                word = DynamicKeyMapping.convertKeys(keyboardMonitor.prevWordKeys)?.original ?? ""
            }
            if word.isEmpty, let last = lastAutoConverted, Date().timeIntervalSince(last.at) < 8 {
                word = last.word
            }
        }
        word = word.trimmingCharacters(in: .punctuationCharacters)
        guard !word.isEmpty, word.count <= 40, !word.contains(where: { $0.isWhitespace }),
              word.contains(where: { $0.isLetter }) else {
            NSSound.beep()
            return
        }
        let settings = SettingsManager.shared
        if !settings.deniedWordsSet.contains(word.lowercased()) {
            settings.deniedWords.append(word)
            settingsController.reloadExceptionLists()
        }
        rslog("exception hotkey: added word (len \(word.count))")
        secureNotice.show(title: String(format: L10n.noticeExceptionAddedTitle, word), body: L10n.noticeExceptionAddedBody)
    }

    /// Разово предлагает скачать расширенный словарь, когда автоконверсия включена, а в паре
    /// раскладок есть русская: словарь нужен только автоконверсии, и именно на русских машинах
    /// жаловались, что простые слова не переключаются. «Позже» запоминается навсегда.
    private func offerFrequencyPacksIfNeeded() {
        let settings = SettingsManager.shared
        guard settings.autoConvert, !settings.frequencyPacks, !settings.frequencyPacksOffered,
              LayoutSwitcher.pairLanguages().contains("ru") else { return }
        settings.frequencyPacksOffered = true

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.offerFreqPacksTitle
        alert.informativeText = L10n.offerFreqPacksText
        alert.addButton(withTitle: L10n.offerFreqPacksDownload)
        alert.addButton(withTitle: L10n.offerFreqPacksLater)
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            rslog("packs: offer declined")
            return
        }
        Task { @MainActor in
            let outcome = await FrequencyPacks.enable()
            rslog("packs: offer accepted, \(outcome)")
            settingsController.refreshFrequencyPacksState()
            if case .failed = outcome {
                // Согласие было, а скачать не вышло: сказать один раз. Снова не предлагаем (где
                // GitHub недоступен, окно висело бы на каждом запуске); включить можно в настройках.
                secureNotice.show(title: L10n.settingsFreqPacks, body: L10n.settingsFreqPacksError)
            }
        }
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.toolTip = "NormalSwitcher"
        statusItem.button?.setAccessibilityLabel("NormalSwitcher")
        // Иконку можно полностью скрыть (Настройки → Расширенные). isVisible вместо
        // removeStatusItem: система помнит позицию, а объект живёт — все пути обновления
        // (updateStatusIcon/rebuildMenu) продолжают работать без nil-проверок.
        statusItem.isVisible = !SettingsManager.shared.hideMenuBarIcon
        rebuildMenu()
        updateStatusIcon()
        // Keep the flag current even while keyboard permissions are pending.
        iconRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateStatusIcon() }
        }
        // issue #9: иконка должна отражать раскладку и при СИСТЕМНОЙ смене (стандартный/
        // переопределённый хоткей), а не только при нашей конверсии. Слушаем системное
        // распределённое уведомление о смене источника ввода.
        // suspensionBehavior: .deliverImmediately — иначе для фонового menu-bar-приложения
        // распределённое уведомление коалесцируется/откладывается (App Nap / suspend), и
        // иконка после переключения глобусом 🌐 меняется с задержкой до нескольких секунд
        // (ждёт пробуждения или 2-секундного опроса). deliverImmediately обновляет флаг сразу.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemInputSourceChanged),
            name: NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    @objc private func systemInputSourceChanged() {
        updateStatusIcon()
        keyboardMonitor.soundArmed = true  // issue #7: следующая буква даст звук раскладки
        keyboardMonitor.resetLineBuffer()  // скептик 3.2.0: не декодировать строку старой раскладкой
    }

    /// Собирает меню статус-бара. Вызывается заново при смене языка интерфейса,
    /// иначе пункты меню остаются на старом языке.
    private func rebuildMenu() {
        let menu = NSMenu()

        if SettingsManager.shared.clipboardHistoryEnabled {
            let history = NSMenuItem(title: L10n.clipboardHistoryTitle,
                                     action: #selector(openClipboardHistory), keyEquivalent: "")
            history.target = self
            if clipboardHistory.shortcutAvailable {
                let shortcut = SettingsManager.shared.clipboardHistoryShortcut
                history.keyEquivalent = shortcut.menuKeyEquivalent
                history.keyEquivalentModifierMask = shortcut.menuModifierFlags
            }
            menu.addItem(history)
            menu.addItem(.separator())
        }

        for item in layoutMenuItems() { menu.addItem(item) }
        menu.addItem(.separator())

        let autoConvert = NSMenuItem(title: L10n.menuAutomaticCorrection,
                                     action: #selector(toggleAutoConvert), keyEquivalent: "")
        autoConvert.target = self
        autoConvert.state = SettingsManager.shared.autoConvert ? .on : .off
        menu.addItem(autoConvert)
        menu.addItem(.separator())

        let missing = NSMenuItem(title: L10n.menuCheckPermissions, action: #selector(recheckPermissions), keyEquivalent: "")
        missing.target = self
        missing.tag = Self.permissionsItemTag
        missing.isHidden = permissionsGranted
        menu.addItem(missing)

        let settings = NSMenuItem(title: L10n.menuSettings, action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let update = NSMenuItem(title: UpdateChecker.menuTitle, action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        update.tag = Self.updateItemTag
        menu.addItem(update)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: L10n.menuQuit, action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
        rslog("Menu (re)built with \(menu.items.count) items")
    }

    // MARK: - Layout list in menu

    /// Метка пунктов-раскладок, чтобы находить и обновлять их группу в меню.
    private static let layoutItemTag = 741
    private static let permissionsItemTag = 742
    private static let updateItemTag = 743

    /// Пункты списка раскладок: «флаг + локализованное имя», галочка на текущей.
    private func layoutMenuItems() -> [NSMenuItem] {
        let currentID = LayoutSwitcher.currentLayoutID()
        return LayoutSwitcher.installedLayouts().map { source in
            let id = LayoutSwitcher.sourceID(source)
            let badge = Self.regionalFlag(forLayoutID: id) ?? LayoutSwitcher.languageCode(source).map(Self.flagBadge(forLanguage:))
            let item = NSMenuItem(title: LayoutSwitcher.sourceName(source), action: #selector(selectLayout(_:)), keyEquivalent: "")
            if let badge, !SettingsManager.shared.monochromeIcon {
                item.image = flatFlag(for: badge, height: 12)
            }
            item.target = self
            item.representedObject = id
            item.state = (id == currentID) ? .on : .off
            item.tag = Self.layoutItemTag
            return item
        }
    }

    /// Пересобирает группу раскладок при каждом открытии меню: состав и галочка должны
    /// отражать систему на момент клика (раскладки добавляют/удаляют в настройках ОС,
    /// а текущую меняют и мимо нас — системным хоткеем).
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        statusMenuPasteTarget = NSWorkspace.shared.frontmostApplication
        menu.item(withTag: Self.permissionsItemTag)?.isHidden = permissionsGranted
        menu.item(withTag: Self.updateItemTag)?.title = UpdateChecker.menuTitle
        let insertAt = menu.items.firstIndex { $0.tag == Self.layoutItemTag } ?? (SettingsManager.shared.clipboardHistoryEnabled ? 2 : 0)
        for old in menu.items where old.tag == Self.layoutItemTag { menu.removeItem(old) }
        for (offset, item) in layoutMenuItems().enumerated() {
            menu.insertItem(item, at: insertAt + offset)
        }
    }

    @objc private func checkForUpdates() {
        UpdateChecker.checkNow()
    }

    @objc private func selectLayout(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              id != LayoutSwitcher.currentLayoutID() else { return }
        LayoutSwitcher.switchTo(layoutID: id)
        // Явная смена раскладки делает набранный буфер неактуальным — как при per-app restore.
        keyboardMonitor.markConverted()
        textConverter.clearState()
        updateStatusIcon()
    }

    func updateStatusIcon() {
        let flag = flagForCurrentLayout()
        // Каретку дёргаем ТОЛЬКО при реальной смене раскладки: updateStatusIcon зовётся ещё и
        // 2-секундным опросом-страховкой, иначе флаг у каретки выскакивал бы каждые 2с.
        // Сравниваем по флагу-идентичности, а не по title — в монохромном режиме title пуст.
        let changed = lastFlagShown != flag
        lastFlagShown = flag
        let settings = SettingsManager.shared
        statusItem.button?.title = ""
        statusItem.button?.image = (settings.monochromeIcon ? nil : flatFlag(for: flag, height: 12))
            ?? badgeImage(for: currentBadgeLabel())
        if changed { caretIndicator?.layoutChanged() }
    }

    private func flatFlag(for flag: String, height: Int) -> NSImage? {
        guard flag == "🇷🇺" || flag == "🇺🇸" else { return nil }
        let cacheKey = "\(flag)-\(height)"
        if let image = badgeCache[cacheKey] { return image }

        let size = NSSize(width: (CGFloat(height) * 1.5).rounded(), height: CGFloat(height))
        let image = NSImage(size: size, flipped: false) { rect in
            let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 1.5, yRadius: 1.5)
            NSGraphicsContext.saveGraphicsState()
            outline.addClip()
            NSColor.white.setFill()
            rect.fill()
            if flag == "🇷🇺" {
                let band = rect.height / 3
                NSColor(srgbRed: 0.10, green: 0.34, blue: 0.73, alpha: 1).setFill()
                NSRect(x: 0, y: band, width: rect.width, height: band).fill()
                NSColor(srgbRed: 0.82, green: 0.15, blue: 0.20, alpha: 1).setFill()
                NSRect(x: 0, y: 0, width: rect.width, height: band).fill()
            } else {
                let band = rect.height / 13
                NSColor(srgbRed: 0.73, green: 0.16, blue: 0.23, alpha: 1).setFill()
                for index in stride(from: 0, to: 13, by: 2) {
                    NSRect(x: 0, y: CGFloat(index) * band, width: rect.width, height: band).fill()
                }
                let canton = NSRect(x: 0, y: 6 * band, width: rect.width * 0.42, height: 7 * band)
                NSColor(srgbRed: 0.19, green: 0.24, blue: 0.43, alpha: 1).setFill()
                canton.fill()
                NSColor.white.setFill()
                // Simplified stars remain distinct at menu-bar sizes.
                for row in 0..<3 {
                    for column in 0..<4 {
                        let point = NSPoint(x: canton.width * CGFloat(column + 1) / 5,
                                            y: canton.minY + canton.height * CGFloat(row + 1) / 4)
                        NSBezierPath(ovalIn: NSRect(x: point.x - 0.35, y: point.y - 0.35,
                                                   width: 0.7, height: 0.7)).fill()
                    }
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            NSColor.labelColor.withAlphaComponent(0.23).setStroke()
            outline.lineWidth = 0.5
            outline.stroke()
            return true
        }
        badgeCache[cacheKey] = image
        return image
    }

    /// Подпись монохромной плашки — родная аббревиатура языка, как у системного индикатора.
    private func currentBadgeLabel() -> String {
        if let lang = LayoutSwitcher.currentLanguageCode()?.lowercased(), !lang.isEmpty {
            // 'iw' — устаревший код иврита: нормализуем, как и flagBadge.
            let code = LayoutDetector.isHebrew(lang) ? "he" : String(lang.prefix(2))
            let labels: [String: String] = [
                "ru": "РУ", "en": "EN", "uk": "УК", "be": "БЕ",
                "de": "DE", "fr": "FR", "es": "ES", "it": "IT",
                "pt": "PT", "pl": "PL", "ja": "あ", "zh": "拼", "ko": "한",
                "he": "עב",   // иврит (3.0)
                "el": "ΕΛ", "bg": "БГ", "hy": "ՀԱ", "ka": "ქა",
            ]
            return labels[code] ?? code.uppercased()
        }
        // Язык раскладки недоступен — мягкий фолбэк по ID (как у flagForCurrentLayout).
        let id = LayoutSwitcher.currentLayoutID().lowercased()
        return (id.contains("russian") || id.hasSuffix(".ru")) ? "РУ" : "EN"
    }

    /// Монохромная плашка в стиле системного индикатора раскладки Sequoia: скруглённый
    /// прямоугольник с «выбитыми» буквами. Template-image — система сама красит её под
    /// светлый/тёмный меню-бар и пользовательский тинт.
    private func badgeImage(for label: String) -> NSImage {
        if let cached = badgeCache[label] { return cached }
        let font = NSFont.systemFont(ofSize: 10, weight: .bold)
        let textSize = label.size(withAttributes: [.font: font])
        let size = NSSize(width: max(ceil(textSize.width) + 8, 20), height: 15)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3.5, yRadius: 3.5).fill()
            // Буквы «выбиваются» из плашки (прозрачные), как у системного индикатора.
            NSGraphicsContext.current?.cgContext.setBlendMode(.destinationOut)
            label.draw(at: NSPoint(x: (rect.width - textSize.width) / 2,
                                   y: (rect.height - textSize.height) / 2),
                       withAttributes: [.font: font, .foregroundColor: NSColor.white])
            return true
        }
        image.isTemplate = true
        badgeCache[label] = image
        return image
    }

    /// Флаг текущей раскладки по коду языка (BCP-47), а не по подстроке в ID — иначе
    /// "Belarusian" ложно матчил "ru", а любая не-RU/EN пара показывалась как 🇺🇸.
    func flagForCurrentLayout() -> String {
        if let regional = Self.regionalFlag(forLayoutID: LayoutSwitcher.currentLayoutID()) { return regional }
        guard let lang = LayoutSwitcher.currentLanguageCode()?.lowercased(), !lang.isEmpty else {
            // Язык раскладки недоступен — мягкий фолбэк по ID.
            let id = LayoutSwitcher.currentLayoutID().lowercased()
            return (id.contains("russian") || id.hasSuffix(".ru")) ? "🇷🇺" : "🇺🇸"
        }
        return Self.flagBadge(forLanguage: lang)
    }

    /// Флаг страны для региональных раскладок Apple. Язык у них общий (британская, австралийская
    /// и US все отдают «en», бразильская — «pt»), поэтому по языку британская показывалась
    /// флагом США. Страну берём из названия раскладки и только там, где она однозначна.
    private static func regionalFlag(forLayoutID id: String) -> String? {
        let prefix = "com.apple.keylayout."
        guard id.hasPrefix(prefix) else { return nil }
        let name = id.dropFirst(prefix.count)
        let regions: [(String, String)] = [
            ("British", "🇬🇧"), ("Australian", "🇦🇺"), ("Irish", "🇮🇪"), ("NewZealand", "🇳🇿"),
            ("Canadian", "🇨🇦"), ("Brazilian", "🇧🇷"), ("Austrian", "🇦🇹"), ("Swiss", "🇨🇭"), ("Belgian", "🇧🇪"),
        ]
        return regions.first { name.hasPrefix($0.0) }?.1
    }

    /// Единый бейдж раскладки для иконки меню-бара и списка раскладок в меню:
    /// «🇷🇺» для известных языков, иначе код («EL»).
    private static func flagBadge(forLanguage lang: String) -> String {
        // Иврит может прийти устаревшим кодом 'iw' — движок его понимает (isHebrew),
        // индикация должна тоже, иначе в баре будет «IW» вместо 🇮🇱.
        let code = LayoutDetector.isHebrew(lang) ? "he" : String(lang.lowercased().prefix(2))
        let flags: [String: String] = [
            "ru": "🇷🇺", "en": "🇺🇸", "uk": "🇺🇦", "be": "🇧🇾",
            "de": "🇩🇪", "fr": "🇫🇷", "es": "🇪🇸", "it": "🇮🇹",
            "pt": "🇵🇹", "pl": "🇵🇱", "ja": "🇯🇵", "zh": "🇨🇳", "ko": "🇰🇷",
            "he": "🇮🇱",   // иврит (3.0). Арабский в 3.1 — глифом ع (флага нет), см. дизайн 3.0.
        ]
        return flags[code] ?? code.uppercased()
    }

    /// issue #10: создаёт/освобождает индикатор каретки по флагу настроек. Создаётся лениво,
    /// только когда фича включена И мониторинг запущен (нужны разрешения).
    private func syncCaretIndicator() {
        keyboardMonitor.caretFlagEnabled = SettingsManager.shared.caretFlag   // гейт диспатча onUserInput
        if SettingsManager.shared.caretFlag, monitoringActive {
            if caretIndicator == nil {
                let ci = CaretIndicator()
                ci.flagProvider = { [weak self] in self?.flagForCurrentLayout() ?? "" }
                caretIndicator = ci
            }
        } else {
            caretIndicator?.teardown()
            caretIndicator = nil
        }
    }

    // MARK: - Actions

    @objc private func toggleAutoConvert(_ sender: NSMenuItem) {
        SettingsManager.shared.autoConvert.toggle()
        sender.state = SettingsManager.shared.autoConvert ? .on : .off
        settingsController.updateAutoConvertState(SettingsManager.shared.autoConvert)   // #4
        refreshSpaceTap()
        if SettingsManager.shared.autoConvert { offerFrequencyPacksIfNeeded() }
    }

    private func refreshSpaceTap() {
        if keyboardMonitor.needsSpaceTapReconfigure { reconfigureTap() }
    }

    /// Пересоздаёт event tap и, если создание не удалось (например, session-tap отклонён),
    /// ретраит — иначе тумблер «вкл», а tap'а нет, и приложение молча не реагирует на триггер.
    private func reconfigureTap() {
        guard !keyboardMonitor.reconfigure() else { return }
        rslog("reconfigure failed (tap denied) — retry in 3s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.keyboardMonitor.reconfigure() == false { rslog("reconfigure retry failed") }
        }
    }

    @objc private func recheckPermissions() {
        runPermissionWizard(interactive: true)
    }

    @objc private func openSettings() {
        settingsController.showWindow()
    }

    @objc private func openClipboardHistory() {
        let target = statusMenuPasteTarget
        DispatchQueue.main.async { [weak self] in self?.clipboardHistory.show(for: target) }
    }

    /// Окно «Что нового» — один раз после обновления, на языке приложения.
    /// НЕ показываем на свежей установке (там визард первого запуска): отличаем по
    /// launchAtLoginAsked — он выставляется на первом запуске, значит приложение уже
    /// работало ⇒ пустой lastWhatsNewVersion при hasRunBefore = обновление со старой версии.
    private func showWhatsNewIfNeeded(hasRunBefore: Bool) {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        guard !current.isEmpty else { return }
        // Бета-версии (с буквой, напр. «3.2.0a») имеют ОТДЕЛЬНУЮ витрину
        // (showBetaWhatsNewIfNeeded) с текстом из бета-фида; локализованный whatsnew.body
        // под беты не обновляется (иначе тестер увидел бы устаревший текст).
        guard current.last?.isLetter != true else { return }
        let settings = SettingsManager.shared
        // Показываем только на РЕАЛЬНОМ повышении версии: current строго новее сохранённой
        // (numeric-сравнение, не строковое) — иначе даунгрейд 3.2→3.1 снова показал бы окно.
        guard current.compare(settings.lastWhatsNewVersion, options: .numeric) == .orderedDescending else { return }
        guard hasRunBefore else {                          // свежая установка: не показываем,
            settings.lastWhatsNewVersion = current         // но фиксируем версию (и на 2-м запуске молчим)
            return
        }
        // После обновления macOS мог сбросить права — идёт визард, мониторинг ещё не поднят.
        // Не наваливаем промо поверх запроса прав: откладываем до следующего запуска,
        // версию НЕ фиксируем (покажем, когда права выданы и мониторинг активен).
        guard monitoringActive else { return }
        settings.lastWhatsNewVersion = current             // фиксируем только когда реально показываем

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "\(L10n.whatsNewTitle) \(current)"
        alert.informativeText = L10n.whatsNewBody
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: L10n.whatsNewMore)
        if alert.runModal() == .alertSecondButtonReturn,
           let url = URL(string: "\(SettingsManager.githubURL)/releases/latest") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Отдельная витрина для БЕТ: текст изменений берётся из notes бета-фида
    /// (version-beta.json), а не из локализованного whatsnew.body — так его можно менять под
    /// каждую бету без пересборки и ×16-локализации. Только для подписчиков беты, один раз на
    /// версию. Текст двуязычный (RU+EN) — аудитория беты небольшая и приглашённая.
    private func showBetaWhatsNewIfNeeded() {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        guard current.last?.isLetter == true else { return }         // только беты
        guard SettingsManager.shared.betaChannelEnabled else { return }  // только подписчики беты
        guard SettingsManager.shared.lastBetaNotesShown != current else { return }
        guard monitoringActive else { return }                        // не поверх запроса прав
        Task { @MainActor in
            guard let notes = await UpdateChecker.fetchBetaNotes(), !notes.isEmpty else { return }
            // перепроверяем после await (мог показаться параллельно / версия изменилась)
            guard SettingsManager.shared.lastBetaNotesShown != current else { return }
            SettingsManager.shared.lastBetaNotesShown = current
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "\(L10n.whatsNewTitle) \(current) \(L10n.updateBeta)"
            alert.informativeText = notes
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: L10n.whatsNewMore)
            if alert.runModal() == .alertSecondButtonReturn,
               let url = URL(string: "\(SettingsManager.githubURL)/releases") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Подменю «Поделиться» — прямые share-intent ссылки на площадки, актуальные для
    /// аудитории (Telegram/VK — главные для RU), + копирование. Нативный NSSharingServicePicker
    /// на macOS для этого слаб (нет соцсетей/мессенджеров), поэтому свои web-intent'ы.
    private func buildShareSubmenu() -> NSMenu {
        let link = SettingsManager.githubURL
        let text = L10n.shareMessage
        let menu = NSMenu()

        let copyItem = NSMenuItem(title: L10n.menuShareCopy, action: #selector(copyShareLink), keyEquivalent: "")
        copyItem.target = self
        copyItem.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        menu.addItem(copyItem)
        menu.addItem(NSMenuItem.separator())

        // (заголовок, icon-slug, base, параметры). icon: ключ ShareIcons или "sf:<symbol>".
        let targets: [(String, String, String, [(String, String)])] = [
            ("Telegram", "telegram", "https://t.me/share/url",                 [("url", link), ("text", text)]),
            ("VK",       "vk",       "https://vk.com/share.php",                [("url", link), ("title", text)]),
            ("X",        "x",        "https://twitter.com/intent/tweet",        [("text", text), ("url", link)]),
            ("WhatsApp", "whatsapp", "https://wa.me/",                          [("text", "\(text) \(link)")]),
            ("Facebook", "facebook", "https://www.facebook.com/sharer/sharer.php", [("u", link)]),
            ("Reddit",   "reddit",   "https://www.reddit.com/submit",           [("url", link), ("title", text)]),
            (L10n.menuShareEmail, "sf:envelope", "mailto:",                     [("subject", "NormalSwitcher"), ("body", "\(text) \(link)")]),
        ]
        for (title, icon, base, params) in targets {
            guard let shareURL = Self.buildQueryURL(base, params) else { continue }
            let item = NSMenuItem(title: title, action: #selector(openShareLink(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = shareURL
            if icon.hasPrefix("sf:") {
                item.image = NSImage(systemSymbolName: String(icon.dropFirst(3)), accessibilityDescription: nil)
            } else {
                item.image = ShareIcons.image(icon)
            }
            menu.addItem(item)
        }
        return menu
    }

    /// Собирает URL с корректно закодированными query-параметрами (в т.ч. mailto).
    private static func buildQueryURL(_ base: String, _ params: [(String, String)]) -> String? {
        var comps = URLComponents(string: base)
        comps?.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) }
        // URLComponents кодирует пробел как %20 (не '+'), а литеральный '+' в значении
        // оставляет как есть — но многие сервисы трактуют '+' как пробел. Поэтому
        // однозначно кодируем именно '+' → %2B (пробелы уже %20, их не трогаем).
        return comps?.url?.absoluteString.replacingOccurrences(of: "+", with: "%2B")
    }

    @objc private func openShareLink(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? String, let url = URL(string: s) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func copyShareLink() {
        let pb = NSPasteboard.general
        pb.clearContents()
        let link = SettingsManager.githubURL
        pb.setString("\(L10n.shareMessage) \(link)", forType: .string)
    }

    func applicationWillTerminate(_ notification: Notification) {
        iconRefreshTimer?.invalidate()
        clipboardHistory.stop()
        // Не теряем буфер обмена в 2-секундном окне отложенного восстановления
        // (актуально и при само-обновлении, которое завершает процесс).
        textConverter.flushPendingClipboardRestore()
    }

    @objc private func quit() {
        textConverter.flushPendingClipboardRestore()
        perAppLayoutManager.stop()
        keyboardMonitor.stop()
        NSApplication.shared.terminate(nil)
    }
}
