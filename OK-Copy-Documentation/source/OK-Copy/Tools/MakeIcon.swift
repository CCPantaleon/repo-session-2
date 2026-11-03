import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let box = NSRect(x: 72, y: 72, width: 880, height: 880)
        let path = NSBezierPath(roundedRect: box, xRadius: 195, yRadius: 195)
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.25); shadow.shadowBlurRadius = 30; shadow.shadowOffset = NSSize(width: 0, height: -10); shadow.set()
        NSColor(red: 0.22, green: 0.10, blue: 0.38, alpha: 1).setFill(); path.fill()
        NSShadow().set()
        NSGradient(starting: NSColor(red: 0.28, green: 0.12, blue: 0.48, alpha: 1), ending: NSColor(red: 0.60, green: 0.34, blue: 0.82, alpha: 1))!.draw(in: path, angle: 80)
        let back = NSBezierPath(roundedRect: NSRect(x: 300, y: 350, width: 400, height: 440), xRadius: 48, yRadius: 48)
        NSColor.white.withAlphaComponent(0.9).setStroke(); back.lineWidth = 32; back.stroke()
        let front = NSBezierPath(roundedRect: NSRect(x: 230, y: 235, width: 400, height: 440), xRadius: 48, yRadius: 48)
        NSColor(red: 0.97, green: 0.94, blue: 1, alpha: 1).setFill(); front.fill()
        NSColor(red: 0.43, green: 0.21, blue: 0.65, alpha: 1).setStroke(); front.lineWidth = 20; front.stroke()
        for y in [370, 455, 540] {
            let line = NSBezierPath(); line.move(to: NSPoint(x: 325, y: y)); line.line(to: NSPoint(x: 530, y: y)); line.lineWidth = 25; line.lineCapStyle = .round; line.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    }
}

// PNG-backed ICNS chunks avoid dependence on iconutil's GUI service availability.
func bigEndian(_ value: UInt32) -> Data {
    var word = value.bigEndian
    return withUnsafeBytes(of: &word) { Data($0) }
}
var chunks = Data()
for (type, filename) in [("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"), ("icp6", "icon_32x32@2x.png"), ("ic07", "icon_128x128.png"), ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"), ("ic10", "icon_512x512@2x.png")] {
    let png = try Data(contentsOf: output.appendingPathComponent(filename))
    chunks.append(Data(type.utf8)); chunks.append(bigEndian(UInt32(png.count + 8))); chunks.append(png)
}
var icns = Data("icns".utf8); icns.append(bigEndian(UInt32(chunks.count + 8))); icns.append(chunks)
try icns.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
