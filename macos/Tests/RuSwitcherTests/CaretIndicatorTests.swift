import CoreGraphics
import Testing
@testable import RuSwitcher

@Suite @MainActor
struct CaretIndicatorTests {
    @Test func acceptsInsertionPointOnSecondaryDisplay() {
        for width: CGFloat in [0, 1, 2] {
            #expect(CaretIndicator.isInsertionRect(CGRect(x: -180, y: 240, width: width, height: 18)))
        }
    }

    @Test func rejectsLineBoundsAndMissingGeometry() {
        #expect(!CaretIndicator.isInsertionRect(CGRect(x: 40, y: 240, width: 960, height: 18)))
        #expect(!CaretIndicator.isInsertionRect(.zero))
        #expect(!CaretIndicator.isInsertionRect(CGRect(x: CGFloat.infinity, y: 10, width: 0, height: 18)))
    }

    @Test func positionsBesideInsertionPointInBothDirections() {
        let frame = CGRect(x: 0, y: 0, width: 500, height: 300)
        let size = CGSize(width: 28, height: 19)
        func x(_ offset: CGFloat, rtl: Bool) -> CGFloat? {
            CaretIndicator.origin(for: CGRect(x: offset, y: 80, width: 1, height: 20),
                                  size: size, visible: frame, rtl: rtl)?.x
        }
        #expect(x(60, rtl: false) == 65)
        #expect(x(60, rtl: true) == 28)
        #expect(x(497, rtl: false) == 465)
        #expect(x(2, rtl: true) == 7)
        #expect(x(-100, rtl: false) == nil)
    }

    @Test func usesCurrentLanguageSubtag() {
        #expect(CaretIndicator.badgeLabel("en-US") == "EN")
        #expect(CaretIndicator.badgeLabel("ru") == "RU")
        #expect(CaretIndicator.badgeLabel("es-419") == "ES")
        #expect(CaretIndicator.badgeLabel("fil") == "FIL")
        #expect(CaretIndicator.badgeLabel("iw") == "HE")
        #expect(CaretIndicator.badgeLabel(nil) == nil)
    }
    @Test func persistentControlsStayAboveTheCaretOrFlipAtScreenEdge() {
        let visible = CGRect(x: -500, y: 0, width: 500, height: 300)
        let size = CGSize(width: 54, height: 21)
        let normal = CGRect(x: -100, y: 100, width: 0, height: 18)
        let nearTop = CGRect(x: -4, y: 280, width: 0, height: 18)
        let notACaret = CGRect(x: -400, y: 100, width: 300, height: 18)
        #expect(CaretIndicator.aboveCaretOrigin(normal, size: size, visible: visible) == CGPoint(x: -127, y: 122))
        #expect(CaretIndicator.aboveCaretOrigin(nearTop, size: size, visible: visible) == CGPoint(x: -54, y: 255))
        #expect(CaretIndicator.aboveCaretOrigin(notACaret, size: size, visible: visible) == nil)
    }

    @Test func pointerFallbackStaysOnCurrentDisplay() {
        let screen = CGRect(x: -500, y: 40, width: 500, height: 300)
        let size = CGSize(width: 28, height: 19)
        #expect(CaretIndicator.pointerOrigin(for: CGPoint(x: -200, y: 120), size: size, visible: screen)
                == CGPoint(x: -187, y: 96))
        #expect(CaretIndicator.pointerOrigin(for: CGPoint(x: -2, y: 43), size: size, visible: screen)
                == CGPoint(x: -43, y: 40))
    }

    @Test func persistentPointerFallbackStaysInsideTheAppWindow() {
        let visibleWindow = CGRect(x: 100, y: 200, width: 500, height: 300)
        let size = CGSize(width: 54, height: 21)
        let nearSendButton = CGPoint(x: 546, y: 208)
        #expect(CaretIndicator.persistentPointerOrigin(for: nearSendButton, size: size, visible: visibleWindow)
                == CGPoint(x: 480, y: 220))
        #expect(CaretIndicator.persistentPointerOrigin(for: CGPoint(x: 598, y: 497), size: size, visible: visibleWindow)
                == CGPoint(x: 532, y: 464))
        #expect(CaretIndicator.persistentPointerOrigin(for: CGPoint(x: 546, y: 199), size: size, visible: visibleWindow) == nil)
        #expect(CaretIndicator.persistentPointerOrigin(for: nearSendButton, size: size, visible: .null) == nil)
    }
}
