import AppKit
import CoreText
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

// Promotional images for the three yearly support subscriptions: 1024 × 1024 opaque sRGB PNGs.
// Apple frames these and puts the app icon in the lower-left corner, so that corner stays quiet.

struct Petal {
    let angle: CGFloat
    let length: CGFloat
    let width: CGFloat
    let lift: CGFloat
}

struct Layer {
    let petals: [Petal]
    let base: UInt32
    let tip: UInt32
    let alpha: CGFloat
}

struct Tier {
    let file: String
    let productID: String
    let subscriptionID: String
    let label: String
    let layers: [Layer]
    let glow: CGFloat
    let ripples: Int
}

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func fan(_ angles: [CGFloat], length: (CGFloat) -> CGFloat, width: CGFloat, lift: CGFloat = 0) -> [Petal] {
    angles.map { Petal(angle: $0, length: length(abs($0)), width: width, lift: lift) }
}

let outer: UInt32 = 0x7A4579, outerTip: UInt32 = 0xA9719E
let middle: UInt32 = 0xB0729F, middleTip: UInt32 = 0xD79AC2
let inner: UInt32 = 0xE7A9CF, innerTip: UInt32 = 0xF8D3E7

let tiers = [
    Tier(file: "annual5.png", productID: "com.agraabhi.oshodiscourses.support.annual5",
         subscriptionID: "6821753721", label: "Small",
         layers: [
            Layer(petals: fan([-34, 34], length: { _ in 150 }, width: 30, lift: 2), base: outer, tip: outerTip, alpha: 0.85),
            Layer(petals: fan([-11, 11], length: { _ in 226 }, width: 58), base: middle, tip: middleTip, alpha: 0.82),
            Layer(petals: fan([0], length: { _ in 244 }, width: 60), base: inner, tip: innerTip, alpha: 0.8),
         ], glow: 0.35, ripples: 1),
    Tier(file: "annual10.png", productID: "com.agraabhi.oshodiscourses.support.annual10",
         subscriptionID: "6821753662", label: "Generous",
         layers: [
            Layer(petals: fan([-52, -26, 0, 26, 52], length: { 262 - $0 * 1.3 }, width: 64), base: outer, tip: outerTip, alpha: 0.72),
            Layer(petals: fan([-30, -10, 10, 30], length: { 222 - $0 * 0.9 }, width: 58, lift: 6), base: middle, tip: middleTip, alpha: 0.66),
            Layer(petals: fan([-8, 8], length: { _ in 176 }, width: 50, lift: 10), base: inner, tip: innerTip, alpha: 0.78),
         ], glow: 0.6, ripples: 2),
    Tier(file: "annual15.png", productID: "com.agraabhi.oshodiscourses.support.annual15",
         subscriptionID: "6821753750", label: "Extra",
         layers: [
            Layer(petals: fan([-78, -52, -26, 0, 26, 52, 78], length: { 282 - $0 * 1.15 }, width: 66), base: outer, tip: outerTip, alpha: 0.7),
            Layer(petals: fan([-58, -34, -12, 12, 34, 58], length: { 236 - $0 * 0.95 }, width: 60, lift: 6), base: middle, tip: middleTip, alpha: 0.62),
            Layer(petals: fan([-30, -10, 10, 30], length: { 184 - $0 * 0.8 }, width: 52, lift: 12), base: inner, tip: innerTip, alpha: 0.74),
         ], glow: 0.85, ripples: 3),
]

let size = 1024
let side = CGFloat(size)
let waterline: CGFloat = 300
let scale: CGFloat = 1.22
let centerX = side / 2
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func petalPath(_ petal: Petal) -> CGPath {
    let path = CGMutablePath()
    let l = petal.length * scale, w = petal.width * scale
    path.move(to: .zero)
    path.addCurve(to: CGPoint(x: 0, y: l), control1: CGPoint(x: w * 1.2, y: l * 0.28),
                  control2: CGPoint(x: w * 0.62, y: l * 0.8))
    path.addCurve(to: .zero, control1: CGPoint(x: -w * 0.62, y: l * 0.8),
                  control2: CGPoint(x: -w * 1.2, y: l * 0.28))
    var transform = CGAffineTransform(translationX: centerX, y: waterline + 14 + petal.lift * scale)
        .rotated(by: -petal.angle * .pi / 180)
    return path.copy(using: &transform)!
}

func drawLotus(_ tier: Tier, in context: CGContext) {
    for layer in tier.layers {
        for petal in layer.petals {
            let path = petalPath(petal)
            context.saveGState()
            context.addPath(path)
            context.clip()
            let box = path.boundingBox
            let gradient = CGGradient(colorsSpace: space,
                                      colors: [color(layer.base, alpha: layer.alpha),
                                               color(layer.tip, alpha: layer.alpha)] as CFArray,
                                      locations: [0, 1])!
            context.drawLinearGradient(gradient, start: CGPoint(x: centerX, y: waterline),
                                       end: CGPoint(x: centerX, y: box.maxY), options: [.drawsAfterEndLocation])
            context.restoreGState()
            context.addPath(path)
            context.setStrokeColor(color(innerTip, alpha: 0.16))
            context.setLineWidth(1.5)
            context.strokePath()
        }
    }
    let heart = CGPoint(x: centerX, y: waterline + 62)
    let warm = CGGradient(colorsSpace: space,
                          colors: [color(0xFFE6B0, alpha: tier.glow), color(0xF6B7D6, alpha: tier.glow * 0.35),
                                   color(0xF6B7D6, alpha: 0)] as CFArray,
                          locations: [0, 0.35, 1])!
    context.drawRadialGradient(warm, startCenter: heart, startRadius: 0, endCenter: heart,
                               endRadius: (70 + tier.glow * 60) * scale, options: [])
}

func font(_ size: CGFloat, serif: Bool, weight: NSFont.Weight) -> CTFont {
    let system = NSFont.systemFont(ofSize: size, weight: weight)
    let descriptor = serif ? (system.fontDescriptor.withDesign(.serif) ?? system.fontDescriptor) : system.fontDescriptor
    return (NSFont(descriptor: descriptor, size: size) ?? system) as CTFont
}

func drawCentered(_ text: String, font: CTFont, color: CGColor, baseline: CGFloat, tracking: CGFloat,
                  in context: CGContext) {
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        NSAttributedString.Key(kCTKernAttributeName as String): tracking,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    // Trailing kerning would push tracked capitals left of centre.
    let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - tracking
    precondition(width < side - 160, "Label too wide: \(text)")
    context.textPosition = CGPoint(x: (side - width) / 2, y: baseline)
    CTLineDraw(line, context)
}

func render(_ tier: Tier) -> CGImage {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.interpolationQuality = .high
    context.setAllowsAntialiasing(true)

    let sky = CGGradient(colorsSpace: space, colors: [color(0x1E0F44), color(0x2C1752)] as CFArray,
                         locations: [0, 1])!
    context.drawLinearGradient(sky, start: CGPoint(x: 0, y: side), end: CGPoint(x: 0, y: waterline), options: [])
    let halo = CGGradient(colorsSpace: space,
                          colors: [color(0xA564B7, alpha: 0.22), color(0xA564B7, alpha: 0)] as CFArray,
                          locations: [0, 1])!
    let haloCenter = CGPoint(x: centerX, y: waterline + 190)
    context.drawRadialGradient(halo, startCenter: haloCenter, startRadius: 0, endCenter: haloCenter,
                               endRadius: 460, options: [])

    let water = CGRect(x: 0, y: 0, width: side, height: waterline)
    let pond = CGGradient(colorsSpace: space, colors: [color(0x1A0D3B), color(0x0F0828)] as CFArray,
                          locations: [0, 1])!
    context.saveGState()
    context.clip(to: water)
    context.drawLinearGradient(pond, start: CGPoint(x: 0, y: waterline), end: .zero, options: [])
    context.restoreGState()

    context.saveGState()
    context.clip(to: water)
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    context.translateBy(x: 0, y: waterline * 2 + 10)
    context.scaleBy(x: 1, y: -1)
    drawLotus(tier, in: context)
    context.scaleBy(x: 1, y: -1)
    context.translateBy(x: 0, y: -(waterline * 2 + 10))
    let fade = CGGradient(colorsSpace: space,
                          colors: [CGColor(gray: 0, alpha: 0.3), CGColor(gray: 0, alpha: 0)] as CFArray,
                          locations: [0, 1])!
    context.setBlendMode(.destinationIn)
    context.drawLinearGradient(fade, start: CGPoint(x: 0, y: waterline), end: CGPoint(x: 0, y: waterline - 250),
                               options: [.drawsAfterEndLocation])
    context.endTransparencyLayer()
    context.restoreGState()

    for index in 0..<tier.ripples {
        let width = 340 + CGFloat(index) * 170
        let height = width * 0.1
        let ellipse = CGRect(x: centerX - width / 2, y: waterline - 16 - CGFloat(index) * 24 - height / 2,
                             width: width, height: height)
        context.addEllipse(in: ellipse)
        context.setStrokeColor(color(0xE0BAF1, alpha: 0.13 - CGFloat(index) * 0.03))
        context.setLineWidth(1.5)
        context.strokePath()
    }
    let shore = CGGradient(colorsSpace: space,
                           colors: [color(0xE0BAF1, alpha: 0), color(0xE0BAF1, alpha: 0.28), color(0xE0BAF1, alpha: 0)] as CFArray,
                           locations: [0, 0.5, 1])!
    context.saveGState()
    context.clip(to: CGRect(x: 0, y: waterline - 1, width: side, height: 2))
    context.drawLinearGradient(shore, start: CGPoint(x: 120, y: 0), end: CGPoint(x: side - 120, y: 0), options: [])
    context.restoreGState()

    drawLotus(tier, in: context)

    drawCentered("YEARLY SUPPORT", font: font(30, serif: false, weight: .semibold), color: color(0xE0BAF1),
                 baseline: side - 140, tracking: 6, in: context)
    drawCentered(tier.label, font: font(100, serif: true, weight: .semibold), color: color(0xFFF5E9),
                 baseline: side - 262, tracking: 0, in: context)
    return context.makeImage()!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let directory = root.appendingPathComponent("docs/app-store/subscription-images")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
var records: [[String: Any]] = []
for tier in tiers {
    let image = render(tier)
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: 72, kCGImagePropertyDPIHeight: 72] as CFDictionary)
    precondition(CGImageDestinationFinalize(destination))
    let bytes = data as Data
    let properties = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(bytes as CFData, nil)!, 0, nil)! as NSDictionary
    precondition(properties[kCGImagePropertyHasAlpha] as? Bool != true)
    try bytes.write(to: directory.appendingPathComponent(tier.file), options: .atomic)
    records.append([
        "file": tier.file, "productId": tier.productID, "subscriptionId": tier.subscriptionID,
        "label": tier.label, "width": size, "height": size, "bytes": bytes.count,
        "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
        "md5": Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
    ])
    print("Rendered \(tier.file): \(size) × \(size), opaque sRGB")
}
let manifest = try JSONSerialization.data(withJSONObject: ["appID": "6774409039", "images": records],
                                          options: [.prettyPrinted, .sortedKeys])
try manifest.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
