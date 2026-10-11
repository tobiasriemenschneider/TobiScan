// Erzeugt Resources/AppIcon.icns. Aufruf: swift Tools/make-icon.swift (aus dem Projektordner)
import AppKit

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    let scale = CGFloat(pixels) / 1024
    context.scaleBy(x: scale, y: scale)

    // Abgerundete Fläche im üblichen macOS-Raster (824 pt auf 1024 pt) mit weichem Schatten.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    context.addPath(shape)
    context.setFillColor(CGColor(red: 0.10, green: 0.42, blue: 0.86, alpha: 1))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()
    let colors = [CGColor(red: 0.27, green: 0.66, blue: 1.0, alpha: 1), CGColor(red: 0.05, green: 0.30, blue: 0.78, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Blatt, das in den Scanner läuft
    let sheet = CGRect(x: 322, y: 430, width: 380, height: 400)
    context.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: CGColor(gray: 0, alpha: 0.25))
    context.addPath(CGPath(roundedRect: sheet, cornerWidth: 22, cornerHeight: 22, transform: nil))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fillPath()
    context.setShadow(offset: .zero, blur: 0, color: nil)
    context.setFillColor(CGColor(red: 0.62, green: 0.72, blue: 0.86, alpha: 1))
    for (index, width) in [250.0, 280, 210, 280, 170].enumerated() {
        context.addPath(CGPath(roundedRect: CGRect(x: 372, y: 752 - Double(index) * 54, width: width, height: 20),
                               cornerWidth: 10, cornerHeight: 10, transform: nil))
    }
    context.fillPath()

    // Scannerkörper mit Lichtleiste
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: CGColor(gray: 0, alpha: 0.3))
    context.addPath(CGPath(roundedRect: CGRect(x: 212, y: 250, width: 600, height: 230), cornerWidth: 56, cornerHeight: 56, transform: nil))
    context.setFillColor(CGColor(red: 0.13, green: 0.16, blue: 0.22, alpha: 1))
    context.fillPath()
    context.setShadow(offset: .zero, blur: 14, color: CGColor(red: 0.4, green: 1.0, blue: 0.8, alpha: 0.9))
    context.addPath(CGPath(roundedRect: CGRect(x: 272, y: 428, width: 480, height: 16), cornerWidth: 8, cornerHeight: 8, transform: nil))
    context.setFillColor(CGColor(red: 0.55, green: 1.0, blue: 0.85, alpha: 1))
    context.fillPath()
    context.setShadow(offset: .zero, blur: 0, color: nil)
    context.addEllipse(in: CGRect(x: 700, y: 310, width: 52, height: 52))
    context.setFillColor(CGColor(red: 0.27, green: 0.66, blue: 1.0, alpha: 1))
    context.fillPath()
    context.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("TobiScan.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let tool = Process()
tool.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
tool.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try tool.run()
tool.waitUntilExit()
try? FileManager.default.copyItem(at: iconset.appendingPathComponent("icon_512x512.png"), to: URL(fileURLWithPath: "/tmp/tobiscan-icon-preview.png"))
print(tool.terminationStatus == 0 ? "Resources/AppIcon.icns geschrieben" : "iconutil fehlgeschlagen")
