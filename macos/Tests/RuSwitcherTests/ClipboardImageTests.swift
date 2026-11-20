import AppKit
import CryptoKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import RuSwitcher

@MainActor
struct ClipboardImageTests {
    private func raster(width: Int, format: UTType = .png) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: 20, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.systemPurple.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: 20))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(output, format.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        try #require(CGImageDestinationFinalize(dest))
        return output as Data
    }

    @Test func screenshotsKeepOriginalDimensionsAndPasteAnImage() throws {
        let item = NSPasteboardItem()
        let original = try raster(width: 420)
        item.setData(original, forType: .png)
        item.setString("caption", forType: .string)
        guard case .image(let input) = ClipboardHistory.input(from: item, imagesEnabled: true) else {
            Issue.record("Expected the image representation")
            return
        }
        let image = try #require(ClipboardImage(input))
        let pasted = try #require(ClipboardEntry.image(image).pasteboardItem())
        #expect(pasted.data(forType: .png) == original)
        #expect(image.width == 420 && image.height == 20)
        #expect((NSImage(data: image.thumbnail)?.size.width ?? 0) < 420)
        guard case .text("caption") = ClipboardHistory.input(from: item, imagesEnabled: false) else {
            Issue.record("Disabling images should still permit copying text")
            return
        }
        let tiff = try #require(ClipboardImage(raster(width: 420, format: .tiff)))
        #expect(tiff.type == UTType.png.identifier && tiff.width == 420 && tiff.height == 20)
    }

    @Test func imageEvictionPreservesTextAndEncryptedOriginals() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        func makeModel() -> ClipboardHistoryModel {
            ClipboardHistoryModel(store: ClipboardHistoryStore(directory: dir) { _ in key })
        }
        let model = makeModel()
        let first = try #require(ClipboardImage(raster(width: 220)))
        let last = try #require(ClipboardImage(raster(width: 330)))
        #expect(model.setPersistent(true))
        model.capture(.image(first))
        model.capture(.image(last))
        model.capture(.image(first))
        let payload = dir.appendingPathComponent("Images/" + first.id)
        let encrypted = try Data(contentsOf: payload)
        #expect(encrypted.range(of: first.bytes) == nil)
        model.capture(.text("keep"))
        #expect(try Data(contentsOf: payload) == encrypted)
        #expect(model.setImageLimit(1))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Images/" + last.id).path))
        let restored = makeModel()
        #expect(restored.setPersistent(true))
        #expect(restored.entries == [.text("keep"), .image(first)])
        #expect(restored.setImageLimit(0))
        restored.capture(.image(last))
        #expect(restored.entries == [.text("keep")])
        #expect(!FileManager.default.fileExists(atPath: payload.path))
        #expect(restored.setPersistent(false))
    }

    @Test func selectingAScreenshotPastesTheOriginalEntry() throws {
        _ = NSApplication.shared
        let image = try #require(ClipboardImage(raster(width: 330)))
        var pasted: ClipboardEntry?
        let controller = ClipboardHistoryWindow(entries: [.image(image), .text("older")], storageFailed: false,
            emptyMessage: "Empty", onAddTask: nil, onRetry: {}, onClear: {}) { pasted = $0 }
        defer { controller.close() }
        let search = NSSearchField()
        #expect(controller.control(search, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(pasted == .image(image))
    }

    @Test func combinedImageBudgetEvictsOldestEvenBelowCountLimit() throws {
        let first = try #require(ClipboardImage(raster(width: 140)))
        let second = try #require(ClipboardImage(raster(width: 150)))
        let entries: [ClipboardEntry] = [.image(second), .text("keep"), .image(first)]
        #expect(ClipboardHistoryStore.normalized(entries, imageLimit: 10, byteLimit: second.bytes.count)
                == [.image(second), .text("keep")])
    }
}
