import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI

/// Shows the input source briefly on a switch, or keeps the correction controls at the caret.
/// The panel never takes focus.
private final class CaretPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class CaretControlButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class CaretIndicator: NSObject {
    private let panel: NSPanel
    private let label: NSTextField
    private let correctionButton: NSButton
    private let translationButton: NSButton
    private var showsTranslation = false
    private var translationPopover: NSPopover?
    private var translationOwner: pid_t?
    var translationInput: () -> CaretTranslationRequest? = { nil }
    var onTranslationInserted: () -> Void = {}
    private var refreshTimer: Timer?
    private var persistent = false
    var canCorrect: () -> Bool = { false }
    var resolvedEditor: (pid_t) -> AXUIElement? = { _ in nil }
    var onCorrect: () -> Void = {}


    private var hideTimer: Timer?
    private var visible = false
    private var pointerAnchor: (pid: pid_t, point: CGPoint, expires: TimeInterval)?

    /// Сколько держим плашку после переключения, прежде чем спрятать сам (если не печатают).
    private let showDuration: TimeInterval = 1.0

    override init() {
        panel = CaretPanel(contentRect: NSRect(x: 0, y: 0, width: 30, height: 24),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.worksWhenModal = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true                 // click-through — обязательно
        panel.alphaValue = 0
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isExcludedFromWindowsMenu = true

        // Полупрозрачная скруглённая подложка — читаемость флага на любом фоне.
        let backdrop = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 30, height: 24))
        backdrop.wantsLayer = true
        backdrop.material = .popover
        backdrop.state = .active
        backdrop.blendingMode = .behindWindow
        backdrop.layer?.masksToBounds = true
        backdrop.layer?.cornerRadius = 5
        panel.contentView = backdrop

        label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.alignment = .center
        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false
        correctionButton = CaretControlButton(frame: .zero)
        translationButton = CaretControlButton(frame: .zero)
        super.init()
        correctionButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        correctionButton.isBordered = false
        correctionButton.target = self
        correctionButton.action = #selector(correctLastWord)
        correctionButton.isHidden = true
        correctionButton.widthAnchor.constraint(equalToConstant: 21).isActive = true
        translationButton.title = "文A"
        translationButton.font = .systemFont(ofSize: 10, weight: .semibold)
        translationButton.isBordered = false
        translationButton.target = self
        translationButton.action = #selector(translate)
        translationButton.isHidden = true
        translationButton.widthAnchor.constraint(equalToConstant: 25).isActive = true
        let row = NSStackView(views: [label, correctionButton, translationButton])
        row.orientation = .horizontal
        row.spacing = 2
        row.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(row)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            row.widthAnchor.constraint(lessThanOrEqualTo: backdrop.widthAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor),
        ])
    }

    func configure(persistent enabled: Bool, learnsCorrections: Bool, showsTranslation: Bool = false) {
        let title = learnsCorrections
            ? taskText("Correct and remember the last word", "Исправить и запомнить последнее слово")
            : taskText("Correct the last word", "Исправить последнее слово")
        correctionButton.toolTip = title
        correctionButton.setAccessibilityLabel(title)
        let translateTitle = taskText("Translate the selection or last word", "Перевести выделение или последнее слово")
        translationButton.toolTip = translateTitle
        translationButton.setAccessibilityLabel(translateTitle)
        if #available(macOS 15.0, *) {
            self.showsTranslation = enabled && showsTranslation
        }
        if !self.showsTranslation { closeTranslation() }
        guard enabled != persistent else {
            if enabled { showAtCaret() }
            return
        }
        persistent = enabled
        pointerAnchor = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        hide()
        guard enabled else { return }
        let timer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.showAtCaret() }
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        showAtCaret()
    }

    func hitControl() -> Bool {
        guard persistent, visible else { return false }
        return [correctionButton, translationButton].contains { button in
            !button.isHidden && button.isEnabled
                && panel.convertToScreen(button.convert(button.bounds, to: nil)).contains(NSEvent.mouseLocation)
        }
    }

    func openTranslationFromHotkey() {
        guard showsTranslation else { return }
        showAtCaret(layoutChanged: true)
        translate()
    }

    @objc private func translate() {
        guard #available(macOS 15.0, *), showsTranslation, visible,
              !AutoSwitchPolicy.secureInputActive,
              let app = NSWorkspace.shared.frontmostApplication else { return }
        let owner = app.processIdentifier
        if translationPopover?.isShown == true {
            closeTranslation()
            return
        }
        let request = translationInput()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == owner,
              !AutoSwitchPolicy.secureInputActive else { return }
        let popover = NSPopover()
        // Keep the session's view alive while macOS asks to download a language.
        popover.behavior = .applicationDefined
        let replace: ((String) async -> Bool)? = request?.replaceSelection.map { apply in
            { [weak self, weak popover] text in
                guard let self, let popover else { return false }
                return await self.insertTranslation(text, in: app, from: popover, replace: apply)
            }
        }
        popover.contentViewController = NSHostingController(rootView: CaretTranslationView(
            input: request?.input, insert: replace, close: { [weak self] in self?.closeTranslation() }
        ))
        translationPopover = popover
        translationOwner = owner
        let edge = panel.screen.map {
            Self.translationEdge(for: panel.frame, visible: $0.visibleFrame, width: CaretTranslationView.panelWidth)
        } ?? .maxY
        let anchor = panel.contentView ?? translationButton
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: edge)
    }

    private func insertTranslation(_ text: String, in app: NSRunningApplication, from popover: NSPopover,
                                   replace: (String) -> Bool) async -> Bool {
        let owner = app.processIdentifier
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard translationPopover === popover, !app.isTerminated, !AutoSwitchPolicy.secureInputActive else { return false }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ownPID {
            app.activate(options: [])
            for _ in 0..<6 {
                guard translationPopover === popover, !AutoSwitchPolicy.secureInputActive else { return false }
                let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
                if front == owner { break }
                guard front == nil || front == ownPID else { return false }
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
        guard translationPopover === popover, replace(text) else { return false }
        onTranslationInserted()
        closeTranslation()
        return true
    }

    private func closeTranslation() {
        translationPopover?.close()
        translationPopover = nil
        translationOwner = nil
    }

    @objc private func correctLastWord() {
        onCorrect()
        correctionButton.isEnabled = false
        panel.ignoresMouseEvents = !showsTranslation
    }

    func indicateRememberedWord() {
        guard persistent, visible else { return }
        correctionButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.correctionButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        }
    }

    // MARK: - Entry points (вызываются из AppDelegate)

    /// Реальная смена раскладки → показать код раскладки (на showDuration).
    func layoutChanged() {
        guard persistent || SettingsManager.shared.caretFlag else { return }
        showAtCaret(layoutChanged: true)
    }

    /// Любой ввод/клик пользователя → прячем (issue #10: «скрывать при печати»).
    func userTyped() { if visible, !persistent { hide() } }

    /// Фича выключена / выход — снять окно и таймер.
    func teardown() {
        closeTranslation()
        refreshTimer?.invalidate()
        refreshTimer = nil
        hideTimer?.invalidate(); hideTimer = nil
        panel.orderOut(nil)
        panel.alphaValue = 0
        pointerAnchor = nil
        visible = false
    }

    // MARK: - Internals

    private func showAtCaret(layoutChanged: Bool = false) {
        if translationPopover?.isShown == true, !AutoSwitchPolicy.secureInputActive,
           let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier == translationOwner || front.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return
        }
        if translationPopover != nil { closeTranslation() }
        guard !AutoSwitchPolicy.secureInputActive, !AutoSwitchPolicy.shouldDeferToRemoteClient,
              let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              !persistent || !AutoSwitchPolicy.isDeniedApp(app.bundleIdentifier),
              let name = Self.badgeLabel(LayoutSwitcher.currentLanguageCode()) ?? LayoutSwitcher.currentInputSourceName() else {
            pointerAnchor = nil
            hide()
            return
        }
        label.stringValue = name
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        correctionButton.isHidden = !persistent
        correctionButton.isEnabled = persistent && canCorrect()
        let labelWidth = min(130, max(18, ceil(label.intrinsicContentSize.width)))
        translationButton.isHidden = !showsTranslation
        let controlsWidth: CGFloat = (persistent ? 34 : 12) + (showsTranslation ? 27 : 0)
        let size = NSSize(width: labelWidth + controlsWidth, height: persistent ? 21 : 19)
        if panel.frame.size != size { panel.setContentSize(size) }
        let caret = caretLocation(pid: app.processIdentifier)
        if case .protectedField = caret {
            pointerAnchor = nil
            hide()
            return
        }
        if persistent {
            if case .known(let rect, _) = caret, positionAboveCaret(rect) {
                pointerAnchor = nil
            } else if case .selection(let bounds, let editor) = caret,
                      positionOutsideEditor(selection: bounds, editor: editor, pid: app.processIdentifier) {
                pointerAnchor = nil
            } else if case .editorWithoutCaret(let frame?) = caret,
                      positionOutsideEditor(selection: nil, editor: frame, pid: app.processIdentifier) {
                if !visible || pointerAnchor != nil {
                    rslog("layout-indicator: editor edge app=\(app.bundleIdentifier ?? "unknown")")
                }
                pointerAnchor = nil
            } else {
                guard positionAtPointerAnchor(app: app, refresh: layoutChanged || correctionButton.isEnabled) else {
                    hide()
                    return
                }
            }
            panel.ignoresMouseEvents = !correctionButton.isEnabled && !showsTranslation
            panel.alphaValue = panel.frame.contains(NSEvent.mouseLocation) ? 0.92 : 0.68
            if !panel.isVisible { panel.orderFrontRegardless() }
            visible = true
            return
        }
        if case .known(let rect, let rtl) = caret, position(forCaret: rect, rtl: rtl) {
            rslog("layout-indicator: caret")
        } else if positionBesidePointer(NSEvent.mouseLocation) {
            rslog("layout-indicator: pointer")
        } else {
            hide()
            return
        }
        if !visible {
            if !panel.isVisible { panel.orderFrontRegardless() }
            fade(to: 1, duration: 0.12)
            visible = true
        }
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: showDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    private func positionAtPointerAnchor(app: NSRunningApplication, refresh: Bool) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        let pid = app.processIdentifier
        if pointerAnchor?.pid != pid || (pointerAnchor?.expires ?? 0) <= now { pointerAnchor = nil }
        guard refresh || pointerAnchor != nil,
              let window = focusedWindowFrame(pid: pid) else {
            pointerAnchor = nil
            return false
        }
        // Pin the fallback so the button stays clickable, even when the mouse moves.
        let pointer = pointerAnchor?.point ?? NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }),
              let origin = Self.persistentPointerOrigin(for: pointer, size: panel.frame.size,
                                                       visible: window.intersection(screen.visibleFrame)) else {
            pointerAnchor = nil
            return false
        }
        if refresh {
            if pointerAnchor == nil {
                rslog("layout-indicator: persistent pointer fallback app=\(app.bundleIdentifier ?? "unknown")")
            }
            pointerAnchor = (pid, pointer, now + showDuration)
        }
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        return true
    }

    static func aboveCaretOrigin(_ caret: CGRect, size: CGSize, visible: CGRect) -> CGPoint? {
        guard isInsertionRect(caret), visible.contains(CGPoint(x: caret.midX, y: caret.midY)),
              size.width <= visible.width else { return nil }
        let x = min(max(caret.midX - size.width / 2, visible.minX), visible.maxX - size.width)
        let above = caret.maxY + 4
        let y = above + size.height <= visible.maxY ? above : caret.minY - size.height - 4
        guard y >= visible.minY else { return nil }
        return CGPoint(x: x.rounded(), y: y.rounded())
    }

    private func positionAboveCaret(_ caret: CGRect) -> Bool {
        for screen in NSScreen.screens {
            if let origin = Self.aboveCaretOrigin(caret, size: panel.frame.size, visible: screen.visibleFrame) {
                if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
                return true
            }
        }
        return false
    }

    static func outsideEditorOrigin(selection: CGRect?, editor: CGRect?, size: CGSize, visible: CGRect) -> CGPoint? {
        guard let bounds = editor ?? selection, !visible.isNull,
              size.width <= visible.width, size.height <= visible.height,
              bounds.intersects(visible) else { return nil }
        let field = bounds.intersection(visible)
        let anchor = selection.flatMap { $0.intersects(field) ? $0.intersection(field) : nil }
        let reference = anchor.map { CGPoint(x: $0.midX, y: $0.midY) }
            ?? CGPoint(x: field.minX + min(12, field.width / 2), y: field.minY + min(12, field.height / 2))
        let x = min(max(reference.x - size.width / 2, visible.minX), visible.maxX - size.width)
        let y = min(max(reference.y - size.height / 2, visible.minY), visible.maxY - size.height)
        let gap: CGFloat = 8
        let candidates = [
            CGPoint(x: field.maxX + gap, y: y),
            CGPoint(x: field.minX - gap - size.width, y: y),
            CGPoint(x: x, y: field.minY - gap - size.height),
        ].filter { visible.contains(CGRect(origin: $0, size: size)) }

        func distance(from origin: CGPoint) -> CGFloat {
            abs(origin.x + size.width / 2 - reference.x) + abs(origin.y + size.height / 2 - reference.y)
        }
        if let nearest = candidates.min(by: { distance(from: $0) < distance(from: $1) }) { return nearest }

        // The editor can fill the window near the screen edge. Leave room for
        // the app's formatting toolbar above its selected text in that case.
        let above = CGPoint(x: x, y: field.maxY + 40)
        return visible.contains(CGRect(origin: above, size: size)) ? above : nil
    }

    private func positionOutsideEditor(selection: CGRect?, editor: CGRect?, pid: pid_t) -> Bool {
        guard let anchor = selection ?? editor else { return false }
        let window = focusedWindowFrame(pid: pid)
        for screen in NSScreen.screens where screen.frame.intersects(anchor) {
            let visible = window.map { $0.intersection(screen.visibleFrame) } ?? screen.visibleFrame
            if let origin = Self.outsideEditorOrigin(selection: selection, editor: editor,
                                                      size: panel.frame.size, visible: visible) {
                if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
                return true
            }
        }
        return false
    }

    static func translationEdge(for badge: CGRect, visible: CGRect, width: CGFloat) -> NSRectEdge {
        let required = width + 20
        if visible.maxX - badge.maxX >= required { return .maxX }
        if badge.minX - visible.minX >= required { return .minX }
        return badge.midY > visible.midY ? .minY : .maxY
    }

    private func hide() {
        hideTimer?.invalidate(); hideTimer = nil
        guard visible else { return }
        visible = false
        panel.ignoresMouseEvents = true
        if persistent {
            panel.orderOut(nil)
            panel.alphaValue = 0
        } else {
            fade(to: 0, duration: 0.18)
        }
    }

    private func fade(to alpha: CGFloat, duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            panel.animator().alphaValue = alpha
        }
    }

    static func badgeLabel(_ language: String?) -> String? {
        guard let code = language?.split(whereSeparator: { $0 == "-" || $0 == "_" }).first,
              !code.isEmpty, code != "und" else { return nil }
        return code == "iw" ? "HE" : code.uppercased()
    }

    static func origin(for caret: CGRect, size: CGSize, visible: CGRect, rtl: Bool) -> CGPoint? {
        guard isInsertionRect(caret), visible.contains(CGPoint(x: caret.midX, y: caret.midY)),
              size.height <= visible.height else { return nil }
        let right = caret.maxX + 4
        let left = caret.minX - size.width - 4
        for x in rtl ? [left, right] : [right, left] where x >= visible.minX && x + size.width <= visible.maxX {
            let y = min(max(caret.midY - size.height / 2, visible.minY), visible.maxY - size.height)
            return CGPoint(x: x.rounded(), y: y.rounded())
        }
        return nil
    }

    private func position(forCaret caret: NSRect, rtl: Bool) -> Bool {
        for screen in NSScreen.screens {
            if let point = Self.origin(for: caret, size: panel.frame.size, visible: screen.visibleFrame, rtl: rtl) {
                panel.setFrameOrigin(point)
                return true
            }
        }
        return false
    }

    static func pointerOrigin(for pointer: CGPoint, size: CGSize, visible: CGRect) -> CGPoint? {
        guard size.width <= visible.width, size.height <= visible.height else { return nil }
        let gap: CGFloat = 13
        let right = pointer.x + gap
        let x = right + size.width <= visible.maxX ? right : pointer.x - size.width - gap
        let y = pointer.y - size.height - 5
        return CGPoint(x: min(max(x, visible.minX), visible.maxX - size.width),
                       y: min(max(y, visible.minY), visible.maxY - size.height))
    }

    static func persistentPointerOrigin(for pointer: CGPoint, size: CGSize, visible: CGRect) -> CGPoint? {
        let inset = visible.insetBy(dx: 8, dy: 8)
        guard visible.contains(pointer), !inset.isEmpty, size.width <= inset.width,
              size.height <= inset.height else { return nil }
        let gap: CGFloat = 12
        let left = pointer.x - size.width - gap
        let preferredX = left >= inset.minX ? left : pointer.x + gap
        let x = min(max(preferredX, inset.minX), inset.maxX - size.width)
        let above = max(pointer.y + gap, inset.minY)
        if above + size.height <= inset.maxY { return CGPoint(x: x, y: above) }
        let below = min(pointer.y - gap - size.height, inset.maxY - size.height)
        guard below >= inset.minY else { return nil }
        return CGPoint(x: x, y: below)
    }

    private func positionBesidePointer(_ pointer: CGPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }),
              let point = Self.pointerOrigin(for: pointer, size: panel.frame.size, visible: screen.visibleFrame) else {
            return false
        }
        panel.setFrameOrigin(point)
        return true
    }

    private enum CaretLocation {
        case known(NSRect, rtl: Bool)
        case selection(NSRect, editor: NSRect?)
        case editorWithoutCaret(NSRect?)
        case unavailable
        case protectedField
    }

    private func caretLocation(pid: pid_t) -> CaretLocation {
        guard AXIsProcessTrusted() else { return .unavailable }
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, persistent ? 0.012 : 0.025)
        let appFocus = focusedElement(axApp)
        var editorFallback: CaretLocation?
        func inspect(_ element: AXUIElement) -> CaretLocation? {
            let location = caretLocation(in: element)
            switch location {
            case .unavailable: return nil
            case .editorWithoutCaret(let anchor):
                if anchor != nil || editorFallback == nil { editorFallback = location }
                return nil
            default: return location
            }
        }
        if let appFocus, let location = inspect(appFocus) { return location }
        let systemFocus = systemFocusedElement(pid: pid)
        if let systemFocus, appFocus.map({ !CFEqual($0, systemFocus) }) ?? true,
           let location = inspect(systemFocus) { return location }
        if persistent, editorFallback == nil, let editor = resolvedEditor(pid),
           appFocus.map({ !CFEqual($0, editor) }) ?? true,
           systemFocus.map({ !CFEqual($0, editor) }) ?? true {
            return inspect(editor) ?? editorFallback ?? .editorWithoutCaret(editorAnchor(in: editor))
        }
        return editorFallback ?? .unavailable
    }

    private func caretLocation(in element: AXUIElement) -> CaretLocation {
        AXUIElementSetMessagingTimeout(element, persistent ? 0.012 : 0.025)
        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
           subrole as? String == kAXSecureTextFieldSubrole { return .protectedField }
        // Native controls expose character ranges. Web editors may expose text markers instead.
        let range = selectedRange(of: element)
        let index = range.flatMap { $0.length == 0 ? $0.location : nil }
        let nativeCaret = index.flatMap { insertionBounds(of: element, at: $0) }
        let marker = nativeCaret == nil ? axBoundsViaTextMarker(of: element) : nil

        if persistent, let range, range.length > 0, isEditableField(element) {
            let editor = editorAnchor(in: element)
            if let bounds = textBounds(of: element, range: range) ?? marker,
               bounds.width > 4, let selection = Self.appKitRect(bounds) {
                return .selection(selection, editor: editor)
            }
            return .editorWithoutCaret(editor)
        }
        if persistent, range == nil, let marker, marker.width > 4,
           isEditableField(element), let selection = Self.appKitRect(marker) {
            return .selection(selection, editor: editorAnchor(in: element))
        }
        guard let bounds = nativeCaret ?? marker.flatMap({ Self.isInsertionRect($0) ? $0 : nil }),
              let rect = Self.appKitRect(bounds) else {
            guard persistent, index != nil || isEditableField(element) else { return .unavailable }
            return .editorWithoutCaret(editorAnchor(in: element))
        }

        var rtl = false
        if !persistent, let index {
            // Compare insertion positions on this line; no text content is needed.
            if index < Int.max, let next = insertionBounds(of: element, at: index + 1),
               abs(bounds.midY - next.midY) < 1, next.midX != bounds.midX {
                rtl = next.midX < bounds.midX
            } else if index > 0, let previous = insertionBounds(of: element, at: index - 1),
                      abs(bounds.midY - previous.midY) < 1 {
                rtl = previous.midX > bounds.midX
            }
        }
        return .known(rect, rtl: rtl)
    }

    private static func appKitRect(_ rect: CGRect) -> CGRect? {
        // AX starts at the top of the primary screen; AppKit starts at the bottom.
        guard let primary = NSScreen.screens.first else { return nil }
        return CGRect(x: rect.minX, y: primary.frame.height - rect.maxY, width: rect.width, height: rect.height)
    }

    private func focusedWindowFrame(pid: pid_t) -> NSRect? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.006)
        guard let window = elementAttribute(app, kAXFocusedWindowAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(window, 0.006)
        return accessibilityFrame(of: window)
    }

    private func editorAnchor(in element: AXUIElement) -> NSRect? {
        guard let frame = accessibilityFrame(of: element),
              frame.width >= 20, (8...400).contains(frame.height) else { return nil }
        return frame
    }

    private func accessibilityFrame(of element: AXUIElement) -> NSRect? {
        func frameValue(_ key: String) -> AXValue? {
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, key as CFString, &raw) == .success,
                  let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
            return (raw as! AXValue)
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard let pointValue = frameValue(kAXPositionAttribute), AXValueGetValue(pointValue, .cgPoint, &position),
              let sizeValue = frameValue(kAXSizeAttribute), AXValueGetValue(sizeValue, .cgSize, &size),
              position.x.isFinite, position.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0, let primary = NSScreen.screens.first else { return nil }
        return NSRect(x: position.x, y: primary.frame.height - position.y - size.height,
                      width: size.width, height: size.height)
    }

    private func isEditableField(_ element: AXUIElement) -> Bool {
        var raw: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &raw) == .success,
           let editable = raw as? Bool { return editable }
        raw = nil
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &raw) == .success,
              let role = raw as? String else { return false }
        return [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role)
    }

    private func selectedRange(of element: AXUIElement) -> CFRange? {
        var rangeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rv = rangeValue, CFGetTypeID(rv) == AXValueGetTypeID() else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rv as! AXValue, .cfRange, &range) else { return nil }

        return range.location >= 0 && range.length >= 0 ? range : nil
    }

    private func insertionBounds(of element: AXUIElement, at index: Int) -> CGRect? {
        guard let bounds = textBounds(of: element, range: CFRange(location: index, length: 0)),
              Self.isInsertionRect(bounds) else { return nil }
        return bounds
    }

    private func textBounds(of element: AXUIElement, range: CFRange) -> CGRect? {
        var range = range
        guard let arg = AXValueCreate(.cfRange, &range) else { return nil }
        var boundsValue: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, arg, &boundsValue
        ) == .success else { return nil }
        return Self.axTextBounds(boundsValue)
    }

    private static func axTextBounds(_ value: AnyObject?) -> CGRect? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect),
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite, rect.width >= 0, rect.height >= 1 else { return nil }
        return rect
    }

    static func isInsertionRect(_ rect: CGRect) -> Bool {
        // AX uses screen points. A normal insertion caret is zero or a few points wide.
        rect.origin.x.isFinite && rect.origin.y.isFinite &&
            rect.size.height.isFinite && rect.size.height >= 1 && (0...4).contains(rect.size.width)
    }

    private func focusedElement(_ owner: AXUIElement) -> AXUIElement? {
        elementAttribute(owner, kAXFocusedUIElementAttribute)
    }

    private func elementAttribute(_ owner: AXUIElement, _ key: String) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(owner, key as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private func systemFocusedElement(pid: pid_t) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, persistent ? 0.006 : 0.025)
        guard let element = focusedElement(system) else { return nil }
        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success, owner == pid else { return nil }
        return element
    }

    /// Веб/Electron: каретка приходит через AXTextMarker, а не CFRange. Приватные,
    /// недокументированные атрибуты (стабильны на практике годами).
    private func axBoundsViaTextMarker(of element: AXUIElement) -> CGRect? {
        var markerRange: AnyObject?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &markerRange) == .success,
              let mr = markerRange else { return nil }
        var boundsValue: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, "AXBoundsForTextMarkerRange" as CFString, mr as CFTypeRef, &boundsValue) == .success else { return nil }
        return Self.axTextBounds(boundsValue)
    }
}
