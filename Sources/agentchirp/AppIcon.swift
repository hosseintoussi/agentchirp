import Cocoa

// Reuse the console/menu-bar vector so the installed icon cannot drift.
func exportAppIcon(to directory: String) {
    do {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = size * scale
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                let context = NSGraphicsContext(bitmapImageRep: rep)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                let side = CGFloat(pixels)
                let tile = NSRect(x: side * 0.06, y: side * 0.06, width: side * 0.88, height: side * 0.88)
                NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
                NSBezierPath(roundedRect: tile, xRadius: side * 0.2, yRadius: side * 0.2).fill()
                BeaconMark.draw(in: NSRect(x: side * 0.2, y: side * 0.17, width: side * 0.6, height: side * 0.6),
                                color: NSColor(calibratedWhite: 0.12, alpha: 1))
                context.flushGraphics()
                NSGraphicsContext.restoreGraphicsState()
                let suffix = scale == 2 ? "@2x" : ""
                let url = URL(fileURLWithPath: directory).appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
                try rep.representation(using: .png, properties: [:])!.write(to: url)
            }
        }
    } catch { fputs("Could not export app icon: \(error)\n", stderr); exit(1) }
}
