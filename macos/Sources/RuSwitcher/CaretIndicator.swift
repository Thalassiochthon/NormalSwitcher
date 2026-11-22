import AppKit
import ApplicationServices
import CoreGraphics

/// issue #10: показывает флаг текущей раскладки рядом с текстовой кареткой — кратко после
/// переключения, прячется при печати/клике. Позицию каретки берём через Accessibility
/// (kAXBoundsForRangeParameterizedAttribute). Если приложение её не отдаёт (Electron/веб,
/// часть терминалов) — просто не показываем; флаг в меню-баре остаётся. Click-through,
/// не крадёт фокус (LSUIElement + .nonactivatingPanel + orderFrontRegardless).
@MainActor
final class CaretIndicator {
    private let panel: NSPanel
    private let label: NSTextField

    private var hideTimer: Timer?
    private var visible = false

    /// Сколько держим флаг после переключения, прежде чем спрятать сам (если не печатают).
    private let showDuration: TimeInterval = 1.0

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 30, height: 24),
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
        label.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: backdrop.widthAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor),
        ])
    }

    // MARK: - Entry points (вызываются из AppDelegate)

    /// Реальная смена раскладки → показать флаг у каретки (на showDuration).
    func layoutChanged() {
        guard SettingsManager.shared.caretFlag else { return }
        showAtCaret()
    }

    /// Любой ввод/клик пользователя → прячем (issue #10: «скрывать при печати»).
    func userTyped() { if visible { hide() } }

    /// Фича выключена / выход — снять окно и таймер.
    func teardown() {
        hideTimer?.invalidate(); hideTimer = nil
        panel.orderOut(nil)
        visible = false

    }

    // MARK: - Internals

    private func showAtCaret() {
        guard let (rect, rtl) = axCaretRectAppKit(),
              let name = Self.badgeLabel(LayoutSwitcher.currentLanguageCode()) ?? LayoutSwitcher.currentInputSourceName() else {
            hide()
            return
        }
        label.stringValue = name
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        let width = min(152, max(28, ceil(label.intrinsicContentSize.width) + 12))
        panel.setContentSize(NSSize(width: width, height: 19))
        guard position(forCaret: rect, rtl: rtl) else { hide(); return }
        if !panel.isVisible { panel.orderFrontRegardless() }            // показ БЕЗ кражи фокуса
        fade(to: 1, duration: 0.12)
        visible = true
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: showDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    private func hide() {
        hideTimer?.invalidate(); hideTimer = nil
        guard visible else { return }
        visible = false
        // Остаётся ordered-in на alpha 0 — невидимо и click-through; полный orderOut в teardown().
        fade(to: 0, duration: 0.18)
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

    /// Каретка в координатах AppKit (низ-лево), или nil если недоступна / гвард не пустил.
    private func axCaretRectAppKit() -> (NSRect, Bool)? {
        guard SettingsManager.shared.caretFlag else { return nil }
        guard AXIsProcessTrusted() else { return nil }
        guard !AutoSwitchPolicy.secureInputActive else { return nil }          // не над полем пароля
        let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // denylist авто-конверсии НЕ применяем: он про «не менять текст», а флаг ничего не меняет —
        // в IDE/терминалах индикатор раскладки как раз полезен. Пароли закрыты secure-input выше.
        guard !AutoSwitchPolicy.shouldDeferToRemoteClient else { return nil }  // удалёнка: каретка на той стороне
        guard frontID != Bundle.main.bundleIdentifier else { return nil }      // не над своим окном

        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // Ограничиваем AX round-trip: с зависшим/занятым таргетом (или Chromium, чьё дерево
        // только строится после AXManualAccessibility) дефолтный таймаут ~6с завесил бы главный
        // поток. 0.25с — не успел, значит nil → hide(), без залипания UI на смене раскладки.
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        enableChromiumA11y(axApp)   // поднять ленивое дерево Electron/Chromium (идемпотентно)
        var focusedRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedRaw) == .success,
              let focused = focusedRaw else { return nil }
        let element = focused as! AXUIElement
        // Нативные Cocoa → range-путь; веб/Electron → text-marker (приватные AX-атрибуты).
        let index = insertionIndex(of: element)
        guard let topLeft = index.flatMap({ insertionBounds(of: element, at: $0) }) ?? axCaretRectViaTextMarker(of: element) else { return nil }
        var rtl = false
        if let index {
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
        guard let primary = NSScreen.screens.first else { return nil }
        var r = topLeft
        r.origin.y = primary.frame.height - topLeft.origin.y - topLeft.height
        return (r, rtl)
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

    /// Electron/Chromium строят дерево a11y лениво — поднимаем его приватным атрибутом
    /// AXManualAccessibility (так делают TextSniper/PopClip). Идемпотентно (на уже включённом
    /// Chromium и на нативных приложениях — no-op). Без кэша по pid: pid переиспользуются при
    /// перезапуске приложений, а кэш «навсегда» ломал бы флаг для перезапущенного Electron.
    private func enableChromiumA11y(_ axApp: AXUIElement) {
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
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
