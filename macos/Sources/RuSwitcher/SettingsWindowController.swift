import AppKit
import Carbon

/// Окно настроек с вкладками
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private var autoConvertCheckbox: NSButton?      // #4: синк тумблера меню → окно настроек
    private var hotkeyPopups: [HotkeySlot: NSPopUpButton] = [:]
    private var hotkeySidePopups: [HotkeySlot: NSPopUpButton] = [:]
    private var hotkeyDoubleChecks: [HotkeySlot: NSButton] = [:]
    private var hotkeyTitleLabels: [HotkeySlot: NSTextField] = [:]
    private var exceptionEditors: [ExceptionListEditor] = []
    private var abbreviationEditor: AbbreviationEditor?
    private var freqPacksCheckbox: NSButton?
    private var freqPacksStatus: NSTextField?

    /// Callback для обновления меню
    var onAutoSwitchChanged: ((Bool) -> Void)?
    var onPerAppLayoutChanged: ((Bool) -> Void)?
    var onLanguageChanged: (() -> Void)?
    var onTriggerChanged: (() -> Void)?
    var onAutoConvertChanged: ((Bool) -> Void)?
    var onRemoteDesktopChanged: ((Bool) -> Void)?
    var onCaretFlagChanged: ((Bool) -> Void)?
    var onHideIconChanged: ((Bool) -> Void)?
    var onClipboardHistoryChanged: (() -> Void)?
    var onClipboardHistoryPersistenceChanged: (() -> Void)?
    var onClipboardHistoryShortcutChanged: ((ClipboardHistoryShortcut) -> Bool)?
    private weak var clipboardHistoryPersistenceCheckbox: NSButton?
    private weak var clipboardHistoryShortcutButton: NSButton?
    var onMenuBarAppearanceChanged: (() -> Void)?
    var onCheckPermissions: (() -> Void)?
    var onShare: ((NSButton) -> Void)?

    func showWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = []
        let sections = [
            (createGeneralTab(), L10n.settingsTabGeneral, "gearshape"),
            (createHotkeysTab(), L10n.settingsTabHotkeys, "keyboard"),
            (createAutoCorrectionTab(), L10n.settingsTabExceptions, "character.bubble"),
            (createClipboardTab(), L10n.settingsTabClipboard, "clipboard"),
            (createAdvancedTab(), L10n.settingsTabAdvanced, "slider.horizontal.3"),
            (createAboutTab(), L10n.settingsTabAbout, "info.circle"),
        ]
        for (content, title, symbol) in sections {
            let controller = NSViewController()
            controller.view = content
            let item = NSTabViewItem(viewController: controller)
            item.identifier = symbol
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }

        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        let win = NSWindow(contentViewController: tabs)
        win.styleMask = [.titled, .closable]
        tabs.title = L10n.settingsTitle
        win.title = L10n.settingsTitle
        win.toolbarStyle = .preference
        win.isReleasedWhenClosed = false
        win.setContentSize(NSSize(width: 660, height: min(540, max(300, screenHeight - 120))))
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        window = win
    }

    func updateAutoConvertState(_ enabled: Bool) {
        autoConvertCheckbox?.state = enabled ? .on : .off
    }

    // MARK: - Settings layout

    private func scrollable(_ sections: [NSView]) -> NSView {
        let document = SettingsDocumentView()
        let content = settingsStack(sections, spacing: 14)
        content.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            content.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            content.widthAnchor.constraint(equalToConstant: 520),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20),
        ])
        return scroll
    }

    private func title(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 13, weight: .semibold)
        return field
    }

    private func hint(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        return field
    }

    private func check(_ title: String, _ enabled: Bool, _ action: Selector) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.state = enabled ? .on : .off
        (button.cell as? NSButtonCell)?.wraps = true
        return button
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func popup(_ action: Selector) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.target = self
        popup.action = action
        popup.widthAnchor.constraint(equalToConstant: 240).isActive = true
        return popup
    }

    private func row(_ label: NSTextField, _ control: NSView) -> NSStackView {
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 12
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.setContentHuggingPriority(.required, for: .horizontal)
        return row
    }

    private func actions(_ buttons: NSButton...) -> NSStackView {
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 8
        return row
    }

    private func createGeneralTab() -> NSView {
        let settings = SettingsManager.shared
        let first = popup(#selector(layout1Changed))
        let second = popup(#selector(layout2Changed))
        populateLayoutPopup(first, selectedID: settings.layout1ID)
        populateLayoutPopup(second, selectedID: settings.layout2ID)
        let language = popup(#selector(languageChanged))
        populateLanguagePopup(language)
        return scrollable([
            check(L10n.settingsAutoSwitch, settings.autoSwitchEnabled, #selector(autoSwitchChanged(_:))),
            check(L10n.settingsLaunchAtLogin, settings.launchAtLogin, #selector(launchAtLoginChanged(_:))),
            NSBox.separator(),
            title(L10n.settingsGroupLayouts),
            row(NSTextField(wrappingLabelWithString: L10n.settingsLayout1), first),
            row(NSTextField(wrappingLabelWithString: L10n.settingsLayout2), second),
            check(L10n.settingsPerAppLayout, settings.perAppLayout, #selector(perAppLayoutChanged(_:))),
            NSBox.separator(),
            row(NSTextField(wrappingLabelWithString: L10n.settingsLanguage), language),
        ])
    }

    // MARK: - Hotkeys Tab

    private static let modifierItems: [(key: String, title: String)] = [
        ("option", "Option ⌥ (Alt)"),
        ("command", "Command ⌘"),
        ("control", "Control ⌃"),
        ("shift", "Shift ⇧"),
        ("fn", "Fn 🌐 (Globe)"),   // #38
    ]
    // issue #12: комбо двух модификаторов (привычный по Windows стиль Alt+Shift).
    private static let comboItems: [(key: String, title: String)] = [
        ("option+shift", "⌥ + ⇧  (Option + Shift)"),   // discussion #32: виндовый дефолт
        ("command+shift", "⌘ + ⇧  (Command + Shift)"),
        ("control+shift", "⌃ + ⇧  (Control + Shift)"),
        ("command+option", "⌘ + ⌥  (Command + Option)"),
        ("control+option", "⌃ + ⌥  (Control + Option)"),
        ("fn+shift", "🌐 + ⇧  (Fn + Shift)"),
    ]

    private func createHotkeysTab() -> NSView {
        let trigger = hotkeyRow(.trigger, L10n.settingsTrigger, hint: L10n.settingsManualCorrectionHint)
        let switchLayout = hotkeyRow(.switchLayout, L10n.settingsSwitchHotkey, hint: L10n.settingsSwitchLayoutHint)
        let extra = SettingsDisclosure(title: L10n.settingsGroupExtraShortcuts, views: [
            hotkeyRow(.layout1, hotkeyTitle(.layout1)),
            hotkeyRow(.layout2, hotkeyTitle(.layout2)),
            hotkeyRow(.changeCase, L10n.settingsCaseHotkey),
            hotkeyRow(.addException, L10n.settingsHotkeyException, hint: L10n.settingsHotkeyExceptionHint),
        ])
        refreshHotkeyControls()
        return scrollable([trigger, NSBox.separator(), switchLayout, NSBox.separator(), extra])
    }

    private func hotkeyRow(_ slot: HotkeySlot, _ name: String, hint description: String? = nil) -> NSView {
        let tag = HotkeySlot.allCases.firstIndex(of: slot)!
        let label = NSTextField(wrappingLabelWithString: name)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        hotkeyTitleLabels[slot] = label
        let key = popup(#selector(hotkeyKeyChanged(_:)))
        key.tag = tag
        key.setAccessibilityLabel(name)
        hotkeyPopups[slot] = key

        let side = NSPopUpButton(frame: .zero, pullsDown: false)
        side.addItems(withTitles: [L10n.settingsHotkeySideAny, L10n.settingsHotkeySideLeft, L10n.settingsHotkeySideRight])
        side.target = self
        side.action = #selector(hotkeySideChanged(_:))
        side.tag = tag
        hotkeySidePopups[slot] = side
        let double = check(L10n.settingsTriggerDoubleTap, false, #selector(hotkeyDoubleChanged(_:)))
        double.tag = tag
        hotkeyDoubleChecks[slot] = double
        let options = NSStackView(views: [side, double])
        options.orientation = .horizontal
        options.alignment = .centerY
        options.distribution = .fill
        options.spacing = 8
        var views: [NSView] = [row(label, key)]
        if let description { views.append(hint(description)) }
        views.append(SettingsDisclosure(title: L10n.settingsGroupShortcutOptions, views: [options]))
        return settingsStack(views, spacing: 6)
    }

    private func hotkeyTitle(_ slot: HotkeySlot) -> String {
        let first = slot == .layout1
        let name = LayoutSwitcher.pairLayoutName(first ? 1 : 2)
            ?? (first ? L10n.settingsLayout1Name : L10n.settingsLayout2Name)
        return String(format: L10n.settingsEnableLayout, name)
    }

    private func refreshLayoutHotkeyTitles() {
        for slot in [HotkeySlot.layout1, .layout2] {
            let name = hotkeyTitle(slot)
            hotkeyTitleLabels[slot]?.stringValue = name
            hotkeyPopups[slot]?.setAccessibilityLabel(name)
        }
    }

    /// Состояние всех контролов хоткеев по настройкам. Пункты, занятые хоткеем выше по
    /// приоритету (с учётом стороны), гасятся с пометкой: движок их всё равно проигнорирует,
    /// одно нажатие не должно делать два действия (issue #20: не оставлять пункт немым серым).
    private func refreshHotkeyControls() {
        let settings = SettingsManager.shared
        for slot in HotkeySlot.allCases {
            guard let popup = hotkeyPopups[slot] else { continue }
            let current = settings.hotkey(slot)
            popup.removeAllItems()
            popup.autoenablesItems = false
            if slot != .trigger {
                popup.addItem(withTitle: L10n.settingsSwitchHotkeyOff)
                popup.menu?.items.last?.representedObject = "" as NSString
                popup.menu?.addItem(.separator())
            }
            func add(_ it: (key: String, title: String)) {
                popup.addItem(withTitle: it.title)
                guard let menuItem = popup.menu?.items.last else { return }
                menuItem.representedObject = it.key as NSString
                // Занят, только если у клавиши не осталось свободной стороны: при левом ⌘ у
                // раскладки 1 ⌘ для раскладки 2 доступен (сторона сама встанет на правую).
                if Self.freeSide(for: slot, key: it.key, preferred: current.side) == nil {
                    menuItem.isEnabled = false
                    menuItem.title += L10n.settingsSwitchHotkeyBusy
                    menuItem.toolTip = L10n.settingsSwitchHotkeyBusy
                }
            }
            Self.modifierItems.forEach(add)
            popup.menu?.addItem(.separator())
            Self.comboItems.forEach(add)
            let key = slot == .trigger && current.key.isEmpty ? "option" : current.key
            if let idx = popup.menu?.items.firstIndex(where: { ($0.representedObject as? String) == key }) {
                popup.selectItem(at: idx)
            } else {
                popup.selectItem(at: 0)
            }

            let side = hotkeySidePopups[slot]
            side?.selectItem(at: [HotkeySide.any, .left, .right].firstIndex(of: current.hasSides ? current.side : .any) ?? 0)
            side?.isEnabled = !current.key.isEmpty && current.hasSides
            hotkeyDoubleChecks[slot]?.state = current.doubleTap ? .on : .off
            hotkeyDoubleChecks[slot]?.isEnabled = !current.key.isEmpty
        }
    }

    /// Сторона, на которой клавиша свободна от хоткеев выше по приоритету (сначала желаемая).
    /// nil — занята целиком. У комбо стороны нет.
    private static func freeSide(for slot: HotkeySlot, key: String, preferred: HotkeySide) -> HotkeySide? {
        let settings = SettingsManager.shared
        let higher = HotkeySlot.allCases.prefix(while: { $0 != slot }).map { settings.hotkey($0) }
        let sides: [HotkeySide] = HotkeySetting(key: key, side: .any, doubleTap: false).hasSides ? [preferred, .any, .left, .right] : [.any]
        return sides.first { side in !higher.contains { HotkeySetting(key: key, side: side, doubleTap: false).overlaps($0) } }
    }

    private func updateHotkey(tag: Int, keyChanged: Bool = false, _ change: (inout HotkeySetting) -> Void) {
        guard HotkeySlot.allCases.indices.contains(tag) else { return }
        let slot = HotkeySlot.allCases[tag]
        var h = SettingsManager.shared.hotkey(slot)
        change(&h)
        if !h.hasSides { h.side = .any }   // у комбо и у Fn стороны нет
        // Новую клавишу ставим на свободную сторону, если выбранная занята (левый ⌘ уже у
        // раскладки 1 → ⌘ для раскладки 2 сам встаёт на правую).
        if keyChanged, !h.key.isEmpty, let side = Self.freeSide(for: slot, key: h.key, preferred: h.side) { h.side = side }
        SettingsManager.shared.setHotkey(slot, h)
        refreshHotkeyControls()
        onTriggerChanged?()               // reconfigure перечитает все хоткеи
    }

    @objc private func hotkeyKeyChanged(_ sender: NSPopUpButton) {
        let key = (sender.selectedItem?.representedObject as? String) ?? ""
        updateHotkey(tag: sender.tag, keyChanged: true) { $0.key = key }
    }

    @objc private func hotkeySideChanged(_ sender: NSPopUpButton) {
        let side = [HotkeySide.any, .left, .right][max(0, min(2, sender.indexOfSelectedItem))]
        updateHotkey(tag: sender.tag) { $0.side = side }
    }

    @objc private func hotkeyDoubleChanged(_ sender: NSButton) {
        let on = sender.state == .on
        updateHotkey(tag: sender.tag) { $0.doubleTap = on }
    }

    // MARK: - Auto-correction, clipboard, and advanced settings

    private func createAutoCorrectionTab() -> NSView {
        let settings = SettingsManager.shared
        let auto = check(L10n.settingsAutoConvert, settings.autoConvert, #selector(autoConvertChanged(_:)))
        autoConvertCheckbox = auto

        let keys = NSStackView()
        keys.orientation = .horizontal
        keys.alignment = .centerY
        keys.distribution = .fillEqually
        let choices = [(L10n.settingsWordEndSpace, settings.wordEndOnSpace),
                       (L10n.settingsWordEndEnter, settings.wordEndOnEnter),
                       (L10n.settingsWordEndTab, settings.wordEndOnTab)]
        for (index, (name, enabled)) in choices.enumerated() {
            let control = check(name, enabled, #selector(wordEndKeyChanged(_:)))
            control.tag = index
            keys.addArrangedSubview(control)
        }
        let packs = check(L10n.settingsFreqPacks, settings.frequencyPacks, #selector(freqPacksChanged(_:)))
        freqPacksCheckbox = packs
        let status = hint(" ")
        freqPacksStatus = status
        refreshFrequencyPacksState()

        let abbr = AbbreviationEditor(get: { SettingsManager.shared.abbreviations },
                                     set: { SettingsManager.shared.abbreviations = $0 })
        abbreviationEditor = abbr
        let abbreviations = editorView(abbr.makeContainer(frame: NSRect(x: 0, y: 0, width: 504, height: 120)), height: 120)
        let edits = SettingsDisclosure(title: L10n.settingsGroupTextEdits, views: [
            check(L10n.settingsFixTwoCaps, settings.fixTwoCaps, #selector(fixTwoCapsChanged(_:))),
            check(L10n.settingsFixTypos, settings.fixTypos, #selector(fixTyposChanged(_:))),
            hint(L10n.settingsFixTyposHint),
            title(L10n.settingsAbbrHeader),
            abbreviations,
            hint(L10n.settingsAbbrHint),
        ])
        let apps = ExceptionListEditor(kind: .apps, get: { SettingsManager.shared.deniedApps },
                                       set: { SettingsManager.shared.deniedApps = $0 },
                                       isProtected: { AutoSwitchPolicy.protectedApps.contains($0) })
        let never = ExceptionListEditor(kind: .words, get: { SettingsManager.shared.deniedWords },
                                        set: { SettingsManager.shared.deniedWords = $0 },
                                        addWordPrompt: L10n.settingsAddWordPrompt)
        let always = ExceptionListEditor(kind: .words, get: { SettingsManager.shared.alwaysConvertWords },
                                         set: { SettingsManager.shared.alwaysConvertWords = $0 },
                                         addWordPrompt: L10n.settingsAddWordPrompt)
        exceptionEditors = [apps, never, always]
        let exceptions = SettingsDisclosure(title: L10n.settingsGroupExceptions, views: [
            title(L10n.settingsExceptionsApps), exceptionView(apps),
            title(L10n.settingsExceptionsNever), exceptionView(never),
            title(L10n.settingsExceptionsAlways), hint(L10n.settingsAlwaysCorrectHint), exceptionView(always),
        ])
        return scrollable([
            auto, hint(L10n.settingsAutoConvertHint), NSBox.separator(),
            title(L10n.settingsWordEndKeys), keys, hint(L10n.settingsWordEndHint), NSBox.separator(),
            packs, hint(L10n.settingsFreqPacksHint), status, edits, exceptions,
        ])
    }

    private func editorView(_ view: NSView, height: CGFloat) -> NSView {
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    private func exceptionView(_ editor: ExceptionListEditor) -> NSView {
        editorView(editor.makeContainer(frame: NSRect(x: 0, y: 0, width: 504, height: 96)), height: 96)
    }

    private func createClipboardTab() -> NSView {
        let settings = SettingsManager.shared
        let enabled = settings.clipboardHistoryEnabled
        let shortcut = button(clipboardHistoryShortcutTitle, #selector(recordClipboardHistoryShortcut(_:)))
        shortcut.setAccessibilityLabel(L10n.settingsOpenClipboardHistory)
        shortcut.isEnabled = enabled
        clipboardHistoryShortcutButton = shortcut
        let persistence = check(L10n.clipboardHistoryPersistent, settings.clipboardHistoryPersistent,
                                #selector(clipboardHistoryPersistenceChanged(_:)))
        persistence.isEnabled = enabled
        clipboardHistoryPersistenceCheckbox = persistence
        return scrollable([
            check(L10n.clipboardHistoryEnabled, enabled, #selector(clipboardHistoryChanged(_:))),
            hint(String(format: L10n.settingsClipboardHistoryLimit, ClipboardHistory.limit)),
            row(NSTextField(wrappingLabelWithString: L10n.settingsOpenClipboardHistory), shortcut),
            NSBox.separator(), persistence, hint(L10n.clipboardHistoryPersistenceHint),
        ])
    }

    private func createAdvancedTab() -> NSView {
        let s = SettingsManager.shared
        let appearance = SettingsDisclosure(title: L10n.settingsGroupAppearance, views: [
            check(L10n.settingsHideIcon, s.hideMenuBarIcon, #selector(hideIconChanged(_:))),
            hint(L10n.settingsHideIconHint),
            check(L10n.menuMonoIcon, s.monochromeIcon, #selector(monochromeIconChanged(_:))),
            check(L10n.settingsCaretFlag, s.caretFlag, #selector(caretFlagChanged(_:))),
            hint(L10n.settingsCaretFlagHint),
            check(L10n.menuKeySound, s.keySound, #selector(layoutSoundChanged(_:))),
            layoutSoundPicker(s.layoutSound),
            hint(L10n.settingsLayoutSoundHint),
        ])
        let manual = SettingsDisclosure(title: L10n.settingsGroupManual, views: [
            check(L10n.settingsSmartConversion, s.smartConversion, #selector(smartConversionChanged(_:))),
            hint(L10n.settingsSmartConversionHint),
            check(L10n.settingsConvertByText, s.convertByText, #selector(convertByTextChanged(_:))),
            hint(L10n.settingsConvertByTextHint),
            check(L10n.settingsConvertWholeLine, s.convertWholeLine, #selector(convertWholeLineChanged(_:))),
            hint(L10n.settingsConvertWholeLineHint),
        ])
        let diagnostics = SettingsDisclosure(title: L10n.settingsGroupDiagnostics, views: [
            row(NSTextField(wrappingLabelWithString: L10n.settingsKeyboardAccess),
                button(L10n.menuCheckPermissions, #selector(checkPermissions))),
            check(L10n.settingsSecureNotice, s.secureInputNoticeEnabled, #selector(secureNoticeChanged(_:))),
            check(L10n.settingsDebugLog, s.debugLogEnabled, #selector(debugLogChanged(_:))),
            actions(button(L10n.settingsShowLog, #selector(showLogFile)),
                    button(L10n.settingsSendLog, #selector(sendLogFile))),
        ], expanded: true)
        var sections: [NSView] = [appearance, manual, diagnostics]
        if s.showRemoteDesktopBeta {
            sections.append(check(L10n.menuRemoteDesktop, s.remoteDesktopMode, #selector(remoteDesktopChanged(_:))))
            sections.append(hint(L10n.settingsRemoteDesktopHint))
        }
        sections.append(actions(button(L10n.settingsQuit, #selector(quitApp))))
        return scrollable(sections)
    }

    private func createAboutTab() -> NSView {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let devTag = info?["RSDevTag"] as? String ?? ""
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 56).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 56).isActive = true
        let attribution = L10n.languageCode == "ru" ? "На основе RuSwitcher" : "Based on RuSwitcher"
        let upstream = button(attribution, #selector(openUpstreamProject))
        let brand = NSStackView(views: [icon, settingsStack([
            title("NormalSwitcher"), hint("\(L10n.settingsAboutVersion) \(version)\(devTag)"),
        ], spacing: 4), upstream])
        brand.orientation = .horizontal
        brand.alignment = .centerY
        brand.spacing = 12

        let settings = SettingsManager.shared
        return scrollable([
            brand, NSBox.separator(), title(L10n.settingsGroupUpdates),
            check(L10n.settingsCheckUpdates, settings.checkUpdatesEnabled, #selector(checkUpdatesEnabledChanged(_:))),
            check(L10n.settingsBetaChannel, settings.betaChannelEnabled, #selector(betaChannelChanged(_:))),
            hint(L10n.settingsBetaChannelHint),
            actions(button(L10n.menuCheckUpdates, #selector(checkUpdates)),
                    button(L10n.settingsOpenGitHub, #selector(openGitHub)),
                    button(L10n.menuShare, #selector(shareApp(_:)))),
        ])
    }

    @objc private func clipboardHistoryChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        SettingsManager.shared.clipboardHistoryEnabled = enabled
        clipboardHistoryPersistenceCheckbox?.isEnabled = enabled
        clipboardHistoryShortcutButton?.isEnabled = enabled
        onClipboardHistoryChanged?()
    }

    @objc private func clipboardHistoryPersistenceChanged(_ sender: NSButton) {
        SettingsManager.shared.clipboardHistoryPersistent = sender.state == .on
        onClipboardHistoryPersistenceChanged?()
    }

    private var clipboardHistoryShortcutTitle: String {
        SettingsManager.shared.clipboardHistoryShortcut.title
    }

    @objc private func recordClipboardHistoryShortcut(_ sender: NSButton) {
        let alert = NSAlert()
        alert.messageText = L10n.clipboardHistoryShortcutPrompt
        alert.informativeText = L10n.clipboardHistoryShortcutHint
        alert.addButton(withTitle: L10n.commonCancel).keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: L10n.clipboardHistoryShortcutReset)

        var captured: ClipboardHistoryShortcut?
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { return event } // Escape cancels.
            let shortcut = ClipboardHistoryShortcut(keyCode: event.keyCode, flags: event.modifierFlags,
                                                    characters: event.charactersIgnoringModifiers)
            MainActor.assumeIsolated {
                guard let shortcut else {
                    NSSound.beep()
                    return
                }
                captured = shortcut
                NSApp.stopModal(withCode: .OK)
            }
            return nil
        }
        let response = alert.runModal()
        if let monitor { NSEvent.removeMonitor(monitor) }
        alert.window.orderOut(nil)
        let shortcut = response == .alertSecondButtonReturn ? .standard : captured
        guard let shortcut else { return }
        if onClipboardHistoryShortcutChanged?(shortcut) == true {
            sender.title = clipboardHistoryShortcutTitle
        } else {
            let warning = NSAlert()
            warning.messageText = L10n.clipboardHistoryShortcutUnavailable
            warning.runModal()
        }
    }

    @objc private func hideIconChanged(_ sender: NSButton) {
        let hide = sender.state == .on
        if hide {
            // Подтверждение с рецептом возврата — снимает страх «а как я его потом найду».
            let alert = NSAlert()
            alert.messageText = L10n.settingsHideIconAlertTitle
            alert.informativeText = L10n.settingsHideIconAlertText
            alert.alertStyle = .informational
            alert.addButton(withTitle: L10n.settingsHideIcon)
            alert.addButton(withTitle: L10n.commonCancel)
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() != .alertFirstButtonReturn {
                sender.state = .off
                return
            }
        }
        SettingsManager.shared.hideMenuBarIcon = hide
        onHideIconChanged?(hide)
    }

    private func layoutSoundPicker(_ selection: LayoutSound) -> NSView {
        let picker = popup(#selector(layoutSoundSelectionChanged(_:)))
        picker.setAccessibilityLabel(L10n.menuKeySound)
        picker.addItems(withTitles: LayoutSound.allCases.map(\.title))
        picker.selectItem(at: LayoutSound.allCases.firstIndex(of: selection) ?? 0)
        let controls = NSStackView(views: [picker, button(L10n.settingsLayoutSoundPreview, #selector(previewLayoutSound))])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        return controls
    }

    @objc private func layoutSoundSelectionChanged(_ sender: NSPopUpButton) {
        let sounds = LayoutSound.allCases
        guard sounds.indices.contains(sender.indexOfSelectedItem) else { return }
        SettingsManager.shared.layoutSound = sounds[sender.indexOfSelectedItem]
    }

    @objc private func previewLayoutSound() {
        SettingsManager.shared.layoutSound.play()
    }

    @objc private func layoutSoundChanged(_ sender: NSButton) {
        SettingsManager.shared.keySound = sender.state == .on
    }

    @objc private func monochromeIconChanged(_ sender: NSButton) {
        SettingsManager.shared.monochromeIcon = sender.state == .on
        onMenuBarAppearanceChanged?()
    }

    @objc private func checkPermissions() {
        onCheckPermissions?()
    }

    @objc private func shareApp(_ sender: NSButton) {
        onShare?(sender)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Language Popup

    private func populateLanguagePopup(_ popup: NSPopUpButton) {
        popup.removeAllItems()
        popup.addItem(withTitle: "🌐 \(L10n.settingsLanguageAuto)")
        popup.menu?.items.last?.representedObject = "" as NSString

        for lang in L10n.languageNames {
            popup.addItem(withTitle: lang.name)
            popup.menu?.items.last?.representedObject = lang.code as NSString
        }

        selectItem(in: popup, matching: SettingsManager.shared.interfaceLanguage)
    }

    /// Выбирает в popup пункт, у которого representedObject == id (или первый при пустом id)
    private func selectItem(in popup: NSPopUpButton, matching id: String) {
        if id.isEmpty {
            popup.selectItem(at: 0)
            return
        }
        for (i, item) in popup.itemArray.enumerated() {
            if (item.representedObject as? String) == id {
                popup.selectItem(at: i)
                return
            }
        }
        popup.selectItem(at: 0)
    }

    // MARK: - Layout Popup

    private func populateLayoutPopup(_ popup: NSPopUpButton, selectedID: String) {
        popup.removeAllItems()
        popup.addItem(withTitle: L10n.settingsAutoDetect)
        popup.menu?.items.last?.representedObject = "" as NSString

        let layouts = LayoutSwitcher.installedLayouts()
        let names = Dictionary(grouping: layouts, by: LayoutSwitcher.sourceName)
        for layout in layouts {
            let id = LayoutSwitcher.sourceID(layout)
            let name = LayoutSwitcher.sourceName(layout)
            let title = names[name]?.count == 1 && name != L10n.settingsAutoDetect ? name : "\(name) (\(id))"
            popup.addItem(withTitle: title)
            popup.lastItem?.representedObject = id as NSString
        }

        selectItem(in: popup, matching: selectedID)
    }

    private func selectedLayoutID(from popup: NSPopUpButton) -> String {
        (popup.selectedItem?.representedObject as? String) ?? ""
    }

    // MARK: - Actions

    @objc private func autoSwitchChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        SettingsManager.shared.autoSwitchEnabled = enabled
        onAutoSwitchChanged?(enabled)
    }

    @objc private func launchAtLoginChanged(_ sender: NSButton) {
        SettingsManager.shared.launchAtLogin = sender.state == .on
    }

    @objc private func checkUpdatesEnabledChanged(_ sender: NSButton) {
        SettingsManager.shared.checkUpdatesEnabled = sender.state == .on
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        let langCode = (sender.selectedItem?.representedObject as? String) ?? ""
        SettingsManager.shared.interfaceLanguage = langCode  // вызывает L10n.reloadLanguage()
        onLanguageChanged?()  // пересобрать меню статус-бара под новый язык
        // Пересоздаём окно для применения нового языка
        window?.close()
        window = nil
        showWindow()
    }

    @objc private func layout1Changed(_ sender: NSPopUpButton) {
        SettingsManager.shared.layout1ID = selectedLayoutID(from: sender)
        DynamicKeyMapping.clearCache()
        refreshLayoutHotkeyTitles()
    }

    @objc private func layout2Changed(_ sender: NSPopUpButton) {
        SettingsManager.shared.layout2ID = selectedLayoutID(from: sender)
        DynamicKeyMapping.clearCache()
        refreshLayoutHotkeyTitles()
    }

    @objc private func perAppLayoutChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        SettingsManager.shared.perAppLayout = enabled
        onPerAppLayoutChanged?(enabled)
    }

    @objc private func freqPacksChanged(_ sender: NSButton) {
        guard sender.state == .on else {
            FrequencyPacks.disable()
            refreshFrequencyPacksState()
            return
        }
        sender.isEnabled = false
        freqPacksStatus?.textColor = .secondaryLabelColor
        freqPacksStatus?.stringValue = L10n.settingsFreqPacksLoading
        Task { @MainActor in
            let outcome = await FrequencyPacks.enable()
            sender.isEnabled = true
            refreshFrequencyPacksState()
            switch outcome {
            case .installed, .cancelled: break
            case .noPacks: freqPacksStatus?.stringValue = L10n.settingsFreqPacksNone
            case .failed:
                freqPacksStatus?.textColor = .systemRed
                freqPacksStatus?.stringValue = L10n.settingsFreqPacksError
            }
        }
    }

    /// Списки исключений изменились снаружи (хоткей «в исключения», learn-from-undo).
    func reloadExceptionLists() {
        exceptionEditors.forEach { $0.reload() }
        abbreviationEditor?.reload()
    }

    /// Галочка и строка «Установлено: RU 50 000 · EN 30 000» по фактическому состоянию.
    func refreshFrequencyPacksState() {
        let on = SettingsManager.shared.frequencyPacks
        freqPacksCheckbox?.state = on ? .on : .off
        freqPacksStatus?.textColor = .secondaryLabelColor
        let installed = on ? FrequencyPacks.installed().filter { FrequencyPacks.pack(for: $0.lang) != nil } : []
        guard !installed.isEmpty else {
            freqPacksStatus?.stringValue = " "
            return
        }
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        let list = installed.map { "\($0.lang.uppercased()) \(fmt.string(from: NSNumber(value: $0.count)) ?? "\($0.count)")" }
        freqPacksStatus?.stringValue = String(format: L10n.settingsFreqPacksInstalled, list.joined(separator: " · "))
    }

    /// A word-end shortcut can change the mode of the keyboard event tap.
    @objc private func wordEndKeyChanged(_ sender: NSButton) {
        let on = sender.state == .on
        let s = SettingsManager.shared
        switch sender.tag {
        case 0: s.wordEndOnSpace = on
        case 1: s.wordEndOnEnter = on
        default: s.wordEndOnTab = on
        }
        onTriggerChanged?()
    }

    @objc private func fixTwoCapsChanged(_ sender: NSButton) {
        SettingsManager.shared.fixTwoCaps = sender.state == .on
    }

    @objc private func fixTyposChanged(_ sender: NSButton) {
        SettingsManager.shared.fixTypos = sender.state == .on
    }

    @objc private func autoConvertChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        SettingsManager.shared.autoConvert = enabled
        onAutoConvertChanged?(enabled)
    }

    @objc private func remoteDesktopChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        SettingsManager.shared.remoteDesktopMode = enabled
        onRemoteDesktopChanged?(enabled)
    }

    @objc private func caretFlagChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        SettingsManager.shared.caretFlag = enabled
        onCaretFlagChanged?(enabled)
    }

    @objc private func betaChannelChanged(_ sender: NSButton) {
        SettingsManager.shared.betaChannelEnabled = sender.state == .on
    }

    @objc private func smartConversionChanged(_ sender: NSButton) {
        SettingsManager.shared.smartConversion = sender.state == .on
    }

    @objc private func convertByTextChanged(_ sender: NSButton) {
        SettingsManager.shared.convertByText = sender.state == .on
    }

    @objc private func convertWholeLineChanged(_ sender: NSButton) {
        SettingsManager.shared.convertWholeLine = sender.state == .on
    }

    @objc private func secureNoticeChanged(_ sender: NSButton) {
        SettingsManager.shared.secureInputNoticeEnabled = sender.state == .on
    }

    @objc private func debugLogChanged(_ sender: NSButton) {
        SettingsManager.shared.debugLogEnabled = sender.state == .on
    }

    @objc private func openGitHub() {
        if let url = URL(string: SettingsManager.githubURL) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openUpstreamProject() {
        if let url = URL(string: "https://github.com/rashn/RuSwitcher") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func checkUpdates() {
        UpdateChecker.checkNow()
    }

    @objc private func showLogFile() {
        let path = debugLogURL.path
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
        } else {
            let alert = NSAlert()
            alert.messageText = "Log file not found"
            alert.informativeText = "Enable debug logging first."
            alert.runModal()
        }
    }

    @objc private func sendLogFile() {
        let path = debugLogURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            showLogFile() // покажет алерт
            return
        }

        let url = URL(fileURLWithPath: path)
        if let service = NSSharingService(named: .composeEmail) {
            service.perform(withItems: [
                "NormalSwitcher debug log" as NSString,
                url
            ])
        } else {
            // Fallback: показать в Finder
            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
        }
    }


}

private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private func settingsStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.distribution = .fill
    stack.spacing = spacing
    for view in views {
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    return stack
}

@MainActor
private final class SettingsDisclosure: NSStackView {
    private let control: NSButton
    private let body: NSStackView
    private var bodyWidth: NSLayoutConstraint?

    init(title: String, views: [NSView], expanded: Bool = false) {
        control = NSButton(title: title, target: nil, action: nil)
        body = settingsStack(views, spacing: 8)
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        distribution = .fill
        spacing = 8
        control.target = self
        control.action = #selector(toggle)
        control.isBordered = false
        control.alignment = .left
        control.imagePosition = .imageLeading
        addArrangedSubview(control)
        setExpanded(expanded)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func toggle() { setExpanded(body.superview == nil) }

    private func setExpanded(_ expanded: Bool) {
        control.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right",
                                accessibilityDescription: nil)
        if expanded {
            addArrangedSubview(body)
            bodyWidth = body.widthAnchor.constraint(equalTo: widthAnchor, constant: -16)
            bodyWidth?.isActive = true
        } else if body.superview != nil {
            bodyWidth?.isActive = false
            bodyWidth = nil
            removeArrangedSubview(body)
            body.removeFromSuperview()
        }
    }
}

private extension NSBox {
    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return box
    }
}
