import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

enum ClipboardEntry: Hashable, Sendable {
    case text(String)
    case image(ClipboardImage)

    var text: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    @MainActor
    func pasteboardItem() -> NSPasteboardItem? {
        let item = NSPasteboardItem()
        let written: Bool
        switch self {
        case .text(let text): written = item.setString(text, forType: .string)
        case .image(let image): written = item.setData(image.bytes, forType: NSPasteboard.PasteboardType(image.type))
        }
        return written ? item : nil
    }

    @MainActor
    func write(to board: NSPasteboard) -> Bool {
        guard let item = pasteboardItem() else { return false }
        board.clearContents()
        return board.writeObjects([item])
    }
}

struct ClipboardImage: Hashable, Sendable {
    static let maxInputBytes = 64 * 1024 * 1024
    static let maxBytes = 16 * 1024 * 1024
    static let totalBytes = 64 * 1024 * 1024
    let bytes: Data
    let type: String
    let id: String
    let width: Int
    let height: Int
    let thumbnail: Data

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    init?(_ data: Data) {
        guard !data.isEmpty, data.count <= Self.maxInputBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let format = CGImageSourceGetType(source) as String?,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 32_000_000 / height else { return nil }
        switch format {
        case UTType.png.identifier, UTType.jpeg.identifier:
            guard data.count <= Self.maxBytes else { return nil }
            bytes = data
            type = format
        case UTType.tiff.identifier:
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImageFromSource(destination, source, 0, nil)
            guard CGImageDestinationFinalize(destination), output.length <= Self.maxBytes else { return nil }
            bytes = output as Data
            type = UTType.png.identifier
        default: return nil
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 112]
        let preview = NSMutableData()
        guard let small = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let destination = CGImageDestinationCreateWithData(preview, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, small, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        thumbnail = preview as Data
        self.width = width
        self.height = height
        id = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
