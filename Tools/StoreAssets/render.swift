import AppKit
import CoreText
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

struct Slide: Decodable {
    let id: String
    let source: String
    let ipadSource: String?
    let title: [String]
    let subtitle: String
    let style: String
}

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

struct Palette {
    let night: Bool
    var top: CGColor { color(night ? 0x21152C : 0xFAF7F1) }
    var bottom: CGColor { color(night ? 0x100F16 : 0xEDE5F0) }
    var text: CGColor { color(night ? 0xFFF5E9 : 0x271B31) }
    var secondary: CGColor { color(night ? 0xCEC0D9 : 0x65576D) }
    var accent: CGColor { color(night ? 0xE0BAF1 : 0x77428E) }
}

final class Canvas {
    let width: CGFloat
    let height: CGFloat
    let context: CGContext

    init(_ width: Int, _ height: Int) {
        self.width = CGFloat(width)
        self.height = CGFloat(height)
        context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.interpolationQuality = .high
        context.setAllowsAntialiasing(true)
        context.textMatrix = .identity
    }

    func rect(_ x: CGFloat, _ top: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(x: x, y: self.height - top - height, width: width, height: height)
    }

    func background(_ palette: Palette) {
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: [palette.top, palette.bottom] as CFArray,
                                  locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height),
                                   end: CGPoint(x: width * 0.7, y: 0),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [color(0xA564B7, alpha: palette.night ? 0.18 : 0.07),
                                       color(0xA564B7, alpha: 0)] as CFArray,
                              locations: [0, 1])!
        let center = CGPoint(x: width * 0.85, y: height * 0.35)
        context.drawRadialGradient(glow, startCenter: center, startRadius: 0,
                                   endCenter: center, endRadius: width * 0.9, options: [])
    }

    func font(_ size: CGFloat, serif: Bool, weight: NSFont.Weight = .semibold) -> CTFont {
        let system = NSFont.systemFont(ofSize: size, weight: weight)
        let descriptor = serif ? (system.fontDescriptor.withDesign(.serif) ?? system.fontDescriptor)
                               : system.fontDescriptor
        let selected = NSFont(descriptor: descriptor, size: size) ?? system
        return selected as CTFont
    }

    func line(_ text: String, font: CTFont, color: CGColor, tracking: CGFloat = 0) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTKernAttributeName as String): tracking,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    @discardableResult
    func text(_ lines: [String], x: CGFloat, top: CGFloat, maxWidth: CGFloat, maxHeight: CGFloat,
              size preferred: CGFloat, minimum: CGFloat, serif: Bool = false,
              color: CGColor, centered: Bool = true, tracking: CGFloat = 0) -> CGFloat {
        var size = preferred
        var prepared: [(CTLine, CGFloat, CGFloat, CGFloat)] = []
        while size >= minimum {
            let selected = font(size, serif: serif)
            prepared = lines.map { text in
                let line = line(text, font: selected, color: color, tracking: tracking)
                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                var leading: CGFloat = 0
                let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
                return (line, width, ascent, ascent + descent + max(leading, size * 0.045))
            }
            if prepared.allSatisfy({ $0.1 <= maxWidth })
                && prepared.reduce(CGFloat(0), { $0 + $1.3 }) <= maxHeight { break }
            size -= 1
        }
        precondition(size >= minimum, "Text does not fit: \(lines)")
        var y = top
        for (line, lineWidth, ascent, lineHeight) in prepared {
            context.textPosition = CGPoint(x: x + (centered ? (maxWidth - lineWidth) / 2 : 0),
                                           y: height - y - ascent)
            CTLineDraw(line, context)
            y += lineHeight
        }
        return y
    }

    func image(_ image: CGImage, in bounds: CGRect) {
        context.draw(image, in: bounds)
    }

    func framed(_ image: CGImage, x: CGFloat, top: CGFloat, width: CGFloat, tablet: Bool = false) {
        let border: CGFloat = tablet ? 14 : 12
        let innerWidth = width - border * 2
        let innerHeight = innerWidth * CGFloat(image.height) / CGFloat(image.width)
        let outer = rect(x, top, width, innerHeight + border * 2)
        precondition(outer.minY >= 0 && outer.maxX <= self.width && outer.minX >= 0)
        let radius: CGFloat = tablet ? 34 : width * 0.08
        let outline = CGPath(roundedRect: outer, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -18), blur: 45, color: color(0x000000, alpha: 0.35))
        context.addPath(outline)
        context.setFillColor(color(0x141217))
        context.fillPath()
        context.restoreGState()
        context.addPath(outline)
        context.setStrokeColor(color(0xA69AAF, alpha: 0.7))
        context.setLineWidth(2.5)
        context.strokePath()
        context.saveGState()
        let display = rect(x + border, top + border, innerWidth, innerHeight)
        context.addPath(CGPath(roundedRect: display, cornerWidth: max(18, radius - border),
                               cornerHeight: max(18, radius - border), transform: nil))
        context.clip()
        self.image(image, in: display)
        context.restoreGState()
    }

    func save(_ url: URL, jpeg: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let image = context.makeImage()!
        let type = jpeg ? UTType.jpeg.identifier : UTType.png.identifier
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image,
                                  [kCGImageDestinationLossyCompressionQuality: 0.91] as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        print("Rendered \(url.lastPathComponent): \(Int(width)) × \(Int(height)), opaque sRGB")
    }
}

func load(_ url: URL) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fatalError("Cannot read image: \(url.path)")
    }
    return image
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let version = CommandLine.arguments.dropFirst().first ?? "1.16.0"
precondition(version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil)
let directory = root.appendingPathComponent("docs/app-store/screenshots/\(version)")
let story = try JSONDecoder().decode([Slide].self,
                                    from: Data(contentsOf: root.appendingPathComponent("Tools/StoreAssets/story.json")))

for family in ["iphone", "ipad"] {
    let tablet = family == "ipad"
    for slide in story {
        let canvas = Canvas(tablet ? 2064 : 1320, tablet ? 2752 : 2868)
        let palette = Palette(night: slide.style == "night")
        canvas.background(palette)
        let margin: CGFloat = tablet ? 140 : 86
        canvas.text(["OSHO TALKS"], x: margin, top: tablet ? 60 : 48,
                    maxWidth: canvas.width - margin * 2, maxHeight: 55,
                    size: tablet ? 31 : 25, minimum: 23, color: palette.accent, tracking: 4)
        canvas.text(slide.title, x: margin, top: tablet ? 136 : 120,
                    maxWidth: canvas.width - margin * 2, maxHeight: tablet ? 334 : 292,
                    size: tablet ? 156 : 130, minimum: tablet ? 112 : 91,
                    serif: true, color: palette.text)
        canvas.text([slide.subtitle], x: margin, top: tablet ? 495 : 432,
                    maxWidth: canvas.width - margin * 2, maxHeight: 76,
                    size: tablet ? 57 : 43, minimum: tablet ? 42 : 34, color: palette.secondary)
        let source = tablet ? (slide.ipadSource ?? slide.source) : slide.source
        let image = load(directory.appendingPathComponent("raw/\(family)/\(source).png"))
        precondition(image.width == (tablet ? 2064 : 1320) && image.height == (tablet ? 2752 : 2868))
        let frameWidth: CGFloat = tablet ? 1544 : 1038
        canvas.framed(image, x: (canvas.width - frameWidth) / 2, top: tablet ? 602 : 552,
                      width: frameWidth, tablet: tablet)
        try canvas.save(directory.appendingPathComponent("\(family)/\(slide.id).png"))
    }
}

let github = root.appendingPathComponent("docs/screenshots")
let hero = Canvas(2400, 1360)
let palette = Palette(night: true)
hero.background(palette)
let icon = load(root.appendingPathComponent("OshoDiscourses/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"))
hero.context.saveGState()
hero.context.addPath(CGPath(roundedRect: hero.rect(134, 112, 102, 102), cornerWidth: 22, cornerHeight: 22, transform: nil))
hero.context.clip()
hero.image(icon, in: hero.rect(134, 112, 102, 102))
hero.context.restoreGState()
hero.text(["OSHO TALKS"], x: 266, top: 135, maxWidth: 700, maxHeight: 70,
          size: 48, minimum: 42, color: palette.accent, centered: false, tracking: 3)
hero.text(["Listen to Osho.", "In English & Hindi."], x: 132, top: 312,
          maxWidth: 1050, maxHeight: 305, size: 117, minimum: 98, serif: true,
          color: palette.text, centered: false)
hero.text(["5,481 discourses. 351 series."], x: 140, top: 671,
          maxWidth: 1030, maxHeight: 80, size: 49, minimum: 40,
          color: palette.secondary, centered: false)
hero.text(["Offline listening. Read-along transcripts."], x: 140, top: 768,
          maxWidth: 1030, maxHeight: 70, size: 40, minimum: 36,
          color: palette.secondary, centered: false)
hero.text(["Every feature is free."], x: 140, top: 946,
          maxWidth: 1000, maxHeight: 80, size: 53, minimum: 45,
          color: palette.text, centered: false)
hero.text(["iPhone + iPad  ·  iOS 18+"], x: 140, top: 1050,
          maxWidth: 1000, maxHeight: 70, size: 37, minimum: 34,
          color: palette.accent, centered: false)
hero.framed(load(directory.appendingPathComponent("raw/iphone/transcript-english.png")),
            x: 1780, top: 217, width: 470)
hero.framed(load(directory.appendingPathComponent("raw/iphone/player.png")),
            x: 1270, top: 84, width: 550)
try hero.save(github.appendingPathComponent("osho-talks-hero.jpg"), jpeg: true)

let galleries: [(String, [String])] = [
    ("listen-and-read", ["01-listen", "02-read-along", "06-hindi"]),
    ("explore-and-offline", ["04-explore", "03-denoise", "05-offline"]),
    ("bookmarks-and-routine", ["07-bookmarks", "08-sleep-timer", "09-listening-stats"]),
]
for (name, slides) in galleries {
    let canvas = Canvas(2464, 1770)
    canvas.background(Palette(night: true))
    for (index, slide) in slides.enumerated() {
        canvas.image(load(directory.appendingPathComponent("iphone/\(slide).png")),
                     in: canvas.rect(16 + CGFloat(index) * 816, 16, 800, 1738))
    }
    try canvas.save(github.appendingPathComponent("\(name).jpg"), jpeg: true)
}

for family in ["iphone", "ipad"] {
    let tablet = family == "ipad"
    let thumbWidth: CGFloat = tablet ? 420 : 330
    let thumbHeight: CGFloat = tablet ? 560 : 717
    let canvas = Canvas(Int(thumbWidth * 3 + 48), Int(thumbHeight * 3 + 48))
    canvas.background(Palette(night: true))
    for (index, slide) in story.enumerated() {
        canvas.image(load(directory.appendingPathComponent("\(family)/\(slide.id).png")),
                     in: canvas.rect(12 + CGFloat(index % 3) * (thumbWidth + 12),
                                     12 + CGFloat(index / 3) * (thumbHeight + 12), thumbWidth, thumbHeight))
    }
    try canvas.save(directory.appendingPathComponent("\(family)-overview.jpg"), jpeg: true)
}

var sets: [[String: Any]] = []
var sourceBuilds = Set<String>()
for family in ["iphone", "ipad"] {
    let files: [[String: Any]] = try story.map { slide in
        let relative = "\(family)/\(slide.id).png"
        let url = directory.appendingPathComponent(relative)
        let data = try Data(contentsOf: url)
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
        precondition(properties[kCGImagePropertyHasAlpha] as? Bool != true)
        let captureName = family == "ipad" ? (slide.ipadSource ?? slide.source) : slide.source
        let capturePath = "raw/\(family)/\(captureName)"
        let captureData = try Data(contentsOf: directory.appendingPathComponent(capturePath + ".json"))
        let captureMetadata = try JSONSerialization.jsonObject(with: captureData) as! [String: Any]
        sourceBuilds.insert(captureMetadata["appBuild"] as! String)
        return [
            "file": relative,
            "sourceCapture": capturePath + ".png",
            "bytes": data.count,
            "width": properties[kCGImagePropertyPixelWidth] as! Int,
            "height": properties[kCGImagePropertyPixelHeight] as! Int,
            "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            "md5": Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined(),
        ]
    }
    sets.append(["family": family,
                 "displayType": family == "iphone" ? "IPHONE_69" : "IPAD_PRO_3GEN_129",
                 "files": files])
}
precondition(sourceBuilds.count == 1, "Review mixed-build captures before preparing a listing")
let manifest: [String: Any] = [
    "appID": "6774409039", "version": version, "locale": "en-US",
    "sourceBuild": sourceBuilds.first!, "sets": sets,
]
let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
try manifestData.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
print("Recorded checksums and verified opaque output for all \(story.count * 2) store images")
