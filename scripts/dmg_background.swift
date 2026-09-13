import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

// A quiet, Retina-aware installation instruction. Build-time only.
let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL,
                                                 UTType.tiff.identifier as CFString, 2, nil)!
for scale in [1, 2] {
    let context = CGContext(data: nil, width: 640 * scale, height: 280 * scale,
                           bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    context.setFillColor(CGColor(gray: 0.97, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 640, height: 280))
    let font = CTFontCreateUIFontForLanguage(.system, 15, nil)!
    let text = NSAttributedString(string: "Drag AgentChirp to Applications", attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.35, alpha: 1)
    ])
    let line = CTLineCreateWithAttributedString(text)
    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
    context.textPosition = CGPoint(x: (640 - width) / 2, y: 238)
    CTLineDraw(line, context)
    context.setStrokeColor(CGColor(gray: 0.55, alpha: 1))
    context.setLineWidth(2)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: CGPoint(x: 294, y: 150))
    context.addLine(to: CGPoint(x: 346, y: 150))
    context.move(to: CGPoint(x: 337, y: 159))
    context.addLine(to: CGPoint(x: 346, y: 150))
    context.addLine(to: CGPoint(x: 337, y: 141))
    context.strokePath()
    CGImageDestinationAddImage(destination, context.makeImage()!, [
        kCGImagePropertyDPIWidth: 72 * scale,
        kCGImagePropertyDPIHeight: 72 * scale
    ] as CFDictionary)
}
guard CGImageDestinationFinalize(destination) else { exit(1) }
