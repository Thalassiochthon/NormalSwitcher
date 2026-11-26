import AppKit
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

    @Test func persistentControlsPreferTheSideOfTheCaret() {
        let visible = CGRect(x: -500, y: 0, width: 500, height: 300)
        let size = CGSize(width: 81, height: 21)
        let caret = CGRect(x: -180, y: 100, width: 0, height: 18)
        let nearRightEdge = CGRect(x: -4, y: 100, width: 0, height: 18)
        #expect(CaretIndicator.origin(for: caret, size: size, visible: visible, rtl: false,
                                      allowVerticalFallback: true) == CGPoint(x: -176, y: 99))
        #expect(CaretIndicator.origin(for: caret, size: size, visible: visible, rtl: true,
                                      allowVerticalFallback: true) == CGPoint(x: -265, y: 99))
        #expect(CaretIndicator.origin(for: nearRightEdge, size: size, visible: visible, rtl: false,
                                      allowVerticalFallback: true) == CGPoint(x: -89, y: 99))
    }

    @Test func persistentControlsUseVerticalSpaceWhenNeitherSideFits() {
        let visible = CGRect(x: -140, y: 0, width: 140, height: 300)
        let size = CGSize(width: 81, height: 21)
        let caret = CGRect(x: -70, y: 100, width: 0, height: 18)
        let nearTop = CGRect(x: -70, y: 280, width: 0, height: 18)
        let notACaret = CGRect(x: -100, y: 100, width: 80, height: 18)
        #expect(CaretIndicator.origin(for: caret, size: size, visible: visible, rtl: false,
                                      allowVerticalFallback: true) == CGPoint(x: -111, y: 122))
        #expect(CaretIndicator.origin(for: nearTop, size: size, visible: visible, rtl: false,
                                      allowVerticalFallback: true) == CGPoint(x: -111, y: 255))
        #expect(CaretIndicator.origin(for: notACaret, size: size, visible: visible, rtl: false,
                                      allowVerticalFallback: true) == nil)
    }

    @Test func popoverDoesNotShareTheFormattingToolbarAreaAboveTheSelection() {
        let visible = CGRect(x: 0, y: 0, width: 600, height: 400)
        let editor = CGRect(x: 145, y: 10, width: 430, height: 70)
        let selection = CGRect(x: 165, y: 50, width: 50, height: 18)
        let size = CGSize(width: 81, height: 21)
        let formatting = CGRect(x: 110, y: 74, width: 180, height: 34)
        let origin = CaretIndicator.outsideEditorOrigin(selection: selection, editor: editor, size: size, visible: visible)
        #expect(origin == CGPoint(x: 56, y: 48.5))
        if let origin {
            let badge = CGRect(origin: origin, size: size)
            #expect(!badge.intersects(editor))
            #expect(!badge.intersects(formatting))
        }
    }

    @Test func selectionWithoutBoundsClearsTheFormattingToolbar() {
        let visible = CGRect(x: 0, y: 0, width: 600, height: 400)
        let size = CGSize(width: 81, height: 21)
        let wide = CGRect(x: 10, y: 45, width: 580, height: 70)
        let narrowMargin = CGRect(x: 10, y: 5, width: 580, height: 70)
        #expect(CaretIndicator.outsideEditorOrigin(selection: nil, editor: wide, size: size, visible: visible,
                                                  hasSelection: true) == CGPoint(x: 22, y: 16))
        #expect(CaretIndicator.outsideEditorOrigin(selection: nil, editor: narrowMargin, size: size, visible: visible,
                                                  hasSelection: true) == CGPoint(x: 22, y: 115))
    }

    @Test func fieldOnlyFallbackStaysNearTheStartAsTheEditorGetsWider() {
        let visible = CGRect(x: 0, y: 0, width: 950, height: 400)
        let editor = CGRect(x: 35, y: 26, width: 736, height: 54)
        let size = CGSize(width: 81, height: 21)
        #expect(CaretIndicator.outsideEditorOrigin(selection: nil, editor: editor, size: size, visible: visible)
                == CGPoint(x: 47, y: 88))
        let wider = CGRect(x: editor.minX, y: editor.minY, width: 900, height: editor.height)
        #expect(CaretIndicator.outsideEditorOrigin(selection: nil, editor: wider, size: size, visible: visible)
                == CGPoint(x: 47, y: 88))
        #expect(CaretIndicator.outsideEditorOrigin(selection: nil, editor: editor, size: size, visible: visible, rtl: true)
                == CGPoint(x: 678, y: 88))
    }

    @Test func fieldOnlyFallbackKeepsTheBadgeNearTheFirstLineAtTheScreenEdge() {
        let visible = CGRect(x: 0, y: 0, width: 950, height: 400)
        let size = CGSize(width: 81, height: 21)
        let sideSpace = CGRect(x: 120, y: 350, width: 600, height: 50)
        #expect(CaretIndicator.outsideEditorOrigin(selection: nil, editor: sideSpace, size: size, visible: visible)
                == CGPoint(x: 31, y: 379))
        let editor = CGRect(x: 35, y: 250, width: 900, height: 150)
        #expect(CaretIndicator.outsideEditorOrigin(selection: nil, editor: editor, size: size, visible: visible) == nil)
    }

    @Test func usesLogicalEdgesOfAdjacentGlyphsAndRejectsFieldBounds() {
        let glyph = CGRect(x: 140, y: 90, width: 9, height: 18)
        let left = CGRect(x: 140, y: 90, width: 0, height: 18)
        let right = CGRect(x: 149, y: 90, width: 0, height: 18)
        #expect(CaretIndicator.insertionEdge(of: glyph, following: true, rtl: false) == left)
        #expect(CaretIndicator.insertionEdge(of: glyph, following: false, rtl: false) == right)
        #expect(CaretIndicator.insertionEdge(of: glyph, following: true, rtl: true) == right)
        #expect(CaretIndicator.insertionEdge(of: glyph, following: false, rtl: true) == left)
        let field = CGRect(x: 140, y: 90, width: 440, height: 35)
        #expect(CaretIndicator.insertionEdge(of: field, following: true, rtl: false) == nil)
    }

    @Test func translationPopoverUsesTheNearestAvailableSideOfTheBadge() {
        let visible = CGRect(x: -900, y: 20, width: 900, height: 600)
        let left = CGRect(x: -690, y: 70, width: 81, height: 21)
        let right = CGRect(x: -140, y: 70, width: 81, height: 21)
        #expect(CaretIndicator.translationEdge(for: left, visible: visible, width: 270) == .maxX)
        #expect(CaretIndicator.translationEdge(for: right, visible: visible, width: 270) == .minX)
        #expect(CaretIndicator.translationEdge(for: left, visible: CGRect(x: -740, y: 20, width: 230, height: 600),
                                              width: 270) == .maxY)
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
