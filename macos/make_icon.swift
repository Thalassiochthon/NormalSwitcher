import AppKit
import CoreText

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256, 512, 1024]
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ rgb: Int) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [
        CGFloat((rgb >> 16) & 255) / 255, CGFloat((rgb >> 8) & 255) / 255, CGFloat(rgb & 255) / 255, 1
    ])!
}

func polygon(_ points: [(CGFloat, CGFloat)], on context: CGContext) {
    context.beginPath()
    context.move(to: CGPoint(x: points[0].0, y: points[0].1))
    for (x, y) in points.dropFirst() { context.addLine(to: CGPoint(x: x, y: y)) }
    context.closePath()
    context.fillPath()
}

func png(at size: Int) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let small = size <= 64
    let inset: CGFloat = small ? 32 : 54
    let tile = CGRect(x: inset, y: inset, width: 1024 - 2 * inset, height: 1024 - 2 * inset)
    ctx.setFillColor(color(small ? 0x64309A : 0x2C1735))
    ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 218, cornerHeight: 218, transform: nil))
    ctx.fillPath()
    let white = color(0xF6F8F6)
    ctx.setFillColor(white)
    if small {
        polygon([(254, 239), (254, 785), (370, 785), (654, 430), (654, 785), (770, 785),
                 (770, 239), (654, 239), (370, 594), (370, 239)], on: ctx)
    } else {
        let arrow: [(CGFloat, CGFloat)] = [
            (222, 618), (595, 618), (595, 559), (817, 724),
            (595, 889), (595, 830), (222, 830)
        ]
        // The large icon uses the same arrow shape in both directions.
        let upper = arrow.map { ($0.0, ($0.1 - 724) * 0.79 + 722) }
        polygon(upper, on: ctx)
        ctx.setFillColor(color(0xFFAD46))
        polygon(upper.map { (1024 - $0.0, 1237 - $0.1) }, on: ctx)

        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 130, nil)
        let label = NSAttributedString(string: "NORMAL", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): white,
            NSAttributedString.Key(kCTKernAttributeName as String): 11
        ])
        let line = CTLineCreateWithAttributedString(label)
        let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        ctx.textPosition = CGPoint(x: 512 - bounds.midX, y: 244 - bounds.midY)
        CTLineDraw(line, ctx)
    }
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let images = Dictionary(uniqueKeysWithValues: sizes.map { ($0, png(at: $0)) })
let mac = root.appendingPathComponent("macos")
let catalog = mac.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
for size in [16, 32, 64, 128, 256, 512, 1024] {
    try images[size]!.write(to: catalog.appendingPathComponent("icon_\(size).png"))
}
try images[1024]!.write(to: mac.appendingPathComponent("icon-1024.png"))
try images[256]!.write(to: mac.appendingPathComponent("icon.png"))

func bytes<T: FixedWidthInteger>(of value: T) -> Data {
    var number = value
    return withUnsafeBytes(of: &number) { Data($0) }
}

// ICNS uses a big-endian length for each PNG chunk and for the container.
let macFrames = [
    ("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128), ("ic08", 256),
    ("ic09", 512), ("ic10", 1024), ("ic11", 32), ("ic12", 64),
    ("ic13", 256), ("ic14", 512)
]
var chunks = Data()
for (type, size) in macFrames {
    let image = images[size]!
    chunks += Data(type.utf8) + bytes(of: UInt32(image.count + 8).bigEndian) + image
}
let icns = Data("icns".utf8) + bytes(of: UInt32(chunks.count + 8).bigEndian) + chunks
try icns.write(to: mac.appendingPathComponent("NormalSwitcher.icns"))

let windowsIcon = root.appendingPathComponent("windows/src/RuSwitcher.Win/NormalSwitcher.ico")
if FileManager.default.fileExists(atPath: windowsIcon.path) {
    let windowsSizes = sizes.filter { $0 <= 256 }
    var directory = bytes(of: UInt16(0)) + bytes(of: UInt16(1).littleEndian)
    directory += bytes(of: UInt16(windowsSizes.count).littleEndian)
    var offset = 6 + windowsSizes.count * 16
    for size in windowsSizes {
        let side = UInt8(truncatingIfNeeded: size) // 256 is stored as zero.
        directory.append(contentsOf: [side, side, 0, 0])
        directory += bytes(of: UInt16(1).littleEndian) + bytes(of: UInt16(32).littleEndian)
        directory += bytes(of: UInt32(images[size]!.count).littleEndian) + bytes(of: UInt32(offset).littleEndian)
        offset += images[size]!.count
    }
    for size in windowsSizes { directory += images[size]! }
    try directory.write(to: windowsIcon)
}
