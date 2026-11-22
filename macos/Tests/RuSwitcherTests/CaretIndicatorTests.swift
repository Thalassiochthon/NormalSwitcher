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
}
