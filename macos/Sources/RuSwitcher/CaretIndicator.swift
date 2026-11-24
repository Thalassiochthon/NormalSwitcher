import AppKit
import ApplicationServices
import CoreGraphics

/// Shows the input source briefly on a switch, or keeps the correction controls at the caret.
/// The panel never takes focus.
private final class CaretPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class CaretCorrectionButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class CaretIndicator: NSObject {
    private let panel: NSPanel
    private let label: NSTextField
    private let correctionButton: NSButton
    private var refreshTimer: Timer?
    private var persistent = false
    var canCorrect: () -> Bool = { false }
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
        correctionButton = CaretCorrectionButton(frame: .zero)
        super.init()
        correctionButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        correctionButton.isBordered = false
        correctionButton.toolTip = taskText("Correct and remember the last word", "Исправить и запомнить последнее слово")
        correctionButton.setAccessibilityLabel(correctionButton.toolTip)
        correctionButton.target = self
        correctionButton.action = #selector(correctLastWord)
        correctionButton.isHidden = true
        correctionButton.widthAnchor.constraint(equalToConstant: 21).isActive = true
        let row = NSStackView(views: [label, correctionButton])
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

    func configure(persistent enabled: Bool) {
        guard enabled != persistent else { return }
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

    func hitCorrectionButton() -> Bool {
        guard persistent, visible, correctionButton.isEnabled else { return false }
        return panel.convertToScreen(correctionButton.convert(correctionButton.bounds, to: nil))
            .contains(NSEvent.mouseLocation)
    }

    @objc private func correctLastWord() {
        onCorrect()
        correctionButton.isEnabled = false
        panel.ignoresMouseEvents = true
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
        showAtCaret()
    }

    /// Любой ввод/клик пользователя → прячем (issue #10: «скрывать при печати»).
    func userTyped() { if visible, !persistent { hide() } }

    /// Фича выключена / выход — снять окно и таймер.
    func teardown() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        hideTimer?.invalidate(); hideTimer = nil
        panel.orderOut(nil)
        panel.alphaValue = 0
        pointerAnchor = nil
        visible = false
    }

    // MARK: - Internals

    private func showAtCaret() {
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
        let size = NSSize(width: labelWidth + (persistent ? 34 : 12), height: persistent ? 21 : 19)
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
            } else if !positionAtPointerAnchor(pid: app.processIdentifier) {
                hide()
                return
            }
            panel.ignoresMouseEvents = !correctionButton.isEnabled
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

    private func positionAtPointerAnchor(pid: pid_t) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if pointerAnchor?.pid != pid { pointerAnchor = nil }
        if correctionButton.isEnabled {
            // Pin the fallback where it first appeared so the button stays clickable.
            if pointerAnchor == nil { rslog("layout-indicator: persistent pointer fallback") }
            let point = pointerAnchor?.point ?? NSEvent.mouseLocation
            pointerAnchor = (pid, point, now + showDuration)
        }
        guard let anchor = pointerAnchor, anchor.expires > now else {
            pointerAnchor = nil
            return false
        }
        return positionBesidePointer(anchor.point)
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
        case unavailable
        case protectedField
    }

    private func caretLocation(pid: pid_t) -> CaretLocation {
        guard AXIsProcessTrusted() else { return .unavailable }
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, persistent ? 0.012 : 0.025)
        let appFocus = focusedElement(axApp)
        if let appFocus {
            let result = caretLocation(in: appFocus)
            if case .unavailable = result {} else { return result }
        }
        guard let systemFocus = systemFocusedElement(pid: pid),
              appFocus.map({ !CFEqual($0, systemFocus) }) ?? true else { return .unavailable }
        return caretLocation(in: systemFocus)
    }

    private func caretLocation(in element: AXUIElement) -> CaretLocation {
        AXUIElementSetMessagingTimeout(element, persistent ? 0.012 : 0.025)
        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
           subrole as? String == kAXSecureTextFieldSubrole { return .protectedField }
        // Нативные Cocoa → range-путь; веб/Electron → text-marker (приватные AX-атрибуты).
        let index = insertionIndex(of: element)
        guard let topLeft = index.flatMap({ insertionBounds(of: element, at: $0) }) ?? axCaretRectViaTextMarker(of: element) else { return .unavailable }
        var rtl = false
        if !persistent, let index {
            // Compare insertion positions on this line; no text content is needed.
            if index < Int.max, let next = insertionBounds(of: element, at: index + 1),
               abs(topLeft.midY - next.midY) < 1, next.midX != topLeft.midX {
                rtl = next.midX < topLeft.midX
            } else if index > 0, let previous = insertionBounds(of: element, at: index - 1),
                      abs(topLeft.midY - previous.midY) < 1 {
                rtl = previous.midX > topLeft.midX
            }
        }

        // AX отдаёт глобальные координаты с началом сверху-слева ОСНОВНОГО экрана; AppKit — снизу-слева.
        // Отражаем по полной высоте основного экрана (screens.first), не по visibleFrame, не по целевому.
        guard let primary = NSScreen.screens.first else { return .unavailable }
        var r = topLeft
        r.origin.y = primary.frame.height - topLeft.origin.y - topLeft.height
        return .known(r, rtl: rtl)
    }

    private func insertionIndex(of element: AXUIElement) -> Int? {
        var rangeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rv = rangeValue, CFGetTypeID(rv) == AXValueGetTypeID() else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rv as! AXValue, .cfRange, &range) else { return nil }

        return range.location >= 0 && range.length == 0 ? range.location : nil
    }

    private func insertionBounds(of element: AXUIElement, at index: Int) -> CGRect? {
        var range = CFRange(location: index, length: 0)
        guard let arg = AXValueCreate(.cfRange, &range) else { return nil }
        var boundsValue: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, arg, &boundsValue
        ) == .success else { return nil }
        return Self.caretBounds(boundsValue)
    }

    private static func caretBounds(_ value: AnyObject?) -> CGRect? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect),
              isInsertionRect(rect) else { return nil }
        return rect
    }

    static func isInsertionRect(_ rect: CGRect) -> Bool {
        // AX uses screen points. A normal insertion caret is zero or a few points wide.
        rect.origin.x.isFinite && rect.origin.y.isFinite &&
            rect.size.height.isFinite && rect.size.height >= 1 && (0...4).contains(rect.size.width)
    }

    private func focusedElement(_ owner: AXUIElement) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(owner, kAXFocusedUIElementAttribute as CFString, &raw) == .success,
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
    private func axCaretRectViaTextMarker(of element: AXUIElement) -> CGRect? {
        var markerRange: AnyObject?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &markerRange) == .success,
              let mr = markerRange else { return nil }
        var boundsValue: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, "AXBoundsForTextMarkerRange" as CFString, mr as CFTypeRef, &boundsValue) == .success else { return nil }
        return Self.caretBounds(boundsValue)
    }
}
