import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ScannedPage: Identifiable {
    let id = UUID()
    /// JPEG (Farbe/Grau) oder PNG (Schwarzweiß) im Sitzungsordner.
    let fileURL: URL
    let pixelWidth: Int
    let pixelHeight: Int
    let dpi: Int
    let thumbnail: CGImage
    /// Drehung im Uhrzeigersinn: 0, 90, 180 oder 270.
    var rotation = 0

    var isJPEG: Bool { fileURL.pathExtension == "jpg" }

    /// Seitengröße in PDF-Punkten, Drehung berücksichtigt.
    var pointSize: CGSize {
        let scale = 72.0 / Double(dpi)
        let size = CGSize(width: Double(pixelWidth) * scale, height: Double(pixelHeight) * scale)
        return rotation % 180 == 0 ? size : CGSize(width: size.height, height: size.width)
    }

    var orientation: CGImagePropertyOrientation {
        switch rotation {
        case 90: return .right
        case 180: return .down
        case 270: return .left
        default: return .up
        }
    }

    func loadImage() -> CGImage? {
        if isJPEG, let provider = CGDataProvider(url: fileURL as CFURL) {
            // Als JPEG-Datenquelle laden, damit das PDF die Daten ohne Neukodierung übernimmt.
            return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Zeichnet das Bild gedreht in eine Seite der Größe `size` (Ursprung unten links).
    func draw(_ image: CGImage, in context: CGContext, size: CGSize) {
        let upright = rotation % 180 == 0 ? size : CGSize(width: size.height, height: size.width)
        context.saveGState()
        switch rotation {
        case 90:
            context.translateBy(x: 0, y: upright.width)
            context.rotate(by: -.pi / 2)
        case 180:
            context.translateBy(x: upright.width, y: upright.height)
            context.rotate(by: .pi)
        case 270:
            context.translateBy(x: upright.height, y: 0)
            context.rotate(by: .pi / 2)
        default:
            break
        }
        context.draw(image, in: CGRect(origin: .zero, size: upright))
        context.restoreGState()
    }
}

enum PageImporter {
    enum Result {
        case page(ScannedPage)
        case blank
        case unreadable
    }

    /// Wandelt eine vom Scanner gelieferte Datei (TIFF über USB, Farb-JPEG über WLAN) in eine Seitendatei um.
    /// `colorMode` wird nur auf JPEGs angewendet: Über WLAN liefert der Scanner immer Farbe.
    /// Über WLAN richtet der Scanner die Seiten nicht selbst aus; `deskew` erledigt das für JPEGs am Rechner.
    static func importScan(at url: URL, into directory: URL, dpi: Int, skipBlank: Bool,
                           colorMode: ColorMode = .color, deskew: Bool = false, lighten: Bool = false) -> Result {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              var image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return .unreadable }

        if skipBlank, isBlank(image) { return .blank }
        let sourceIsJPEG = url.pathExtension == "jpg"
        var bitonal = image.bitsPerPixel == 1
        var unchanged = true
        if !bitonal {
            let angle = deskew && sourceIsJPEG ? ImageCleanup.skewAngle(of: image) : nil
            let rotation = angle.map { abs($0) >= 0.1 ? $0 : 0 } ?? 0
            if rotation != 0 || lighten, let cleaned = ImageCleanup.process(image, rotateBy: rotation, lighten: lighten) {
                image = cleaned
                unchanged = false
            }
        }
        if sourceIsJPEG, colorMode != .color {
            guard let converted = grayscale(image, binarize: colorMode == .blackWhite) else { return .unreadable }
            image = converted
            bitonal = colorMode == .blackWhite
        }
        guard let thumbnail = scaled(image, maxPixel: 480) else { return .unreadable }

        let fileURL = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(bitonal ? "png" : "jpg")
        if sourceIsJPEG, colorMode == .color, unchanged {
            // Das JPEG des Scanners unverändert übernehmen statt es erneut zu komprimieren.
            guard (try? FileManager.default.copyItem(at: url, to: fileURL)) != nil else { return .unreadable }
        } else {
            let type = (bitonal ? UTType.png : UTType.jpeg).identifier as CFString
            guard let destination = CGImageDestinationCreateWithURL(fileURL as CFURL, type, 1, nil) else { return .unreadable }
            let properties: [CFString: Any] = [
                kCGImageDestinationLossyCompressionQuality: 0.8,
                kCGImagePropertyDPIWidth: dpi,
                kCGImagePropertyDPIHeight: dpi,
            ]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return .unreadable }
        }

        return .page(ScannedPage(fileURL: fileURL, pixelWidth: image.width, pixelHeight: image.height,
                                 dpi: dpi, thumbnail: thumbnail))
    }

    /// Graustufenfassung eines Bildes; mit `binarize` rein schwarzweiß (Schwelle nach Otsu).
    static func grayscale(_ image: CGImage, binarize: Bool) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let base = context.data
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard binarize else { return context.makeImage() }

        let pixels = base.bindMemory(to: UInt8.self, capacity: width * height)
        var histogram = [Int](repeating: 0, count: 256)
        for index in 0..<(width * height) { histogram[Int(pixels[index])] += 1 }
        let total = Double(width * height)
        let sumAll = (0..<256).reduce(0.0) { $0 + Double($1) * Double(histogram[$1]) }
        var sumBelow = 0.0, countBelow = 0.0, best = 0.0, threshold = 128
        for level in 0..<256 {
            countBelow += Double(histogram[level])
            sumBelow += Double(level) * Double(histogram[level])
            let countAbove = total - countBelow
            guard countBelow > 0, countAbove > 0 else { continue }
            let difference = sumBelow / countBelow - (sumAll - sumBelow) / countAbove
            let variance = countBelow * countAbove * difference * difference
            if variance > best { (best, threshold) = (variance, level) }
        }
        for index in 0..<(width * height) { pixels[index] = Int(pixels[index]) > threshold ? 255 : 0 }
        return context.makeImage()
    }

    static func scaled(_ image: CGImage, maxPixel: Int) -> CGImage? {
        let scale = min(1, Double(maxPixel) / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Eine Seite gilt als leer, wenn sich (abseits der Ränder) fast nichts vom Papierton abhebt.
    static func isBlank(_ image: CGImage) -> Bool {
        let width = 512
        let height = max(1, image.height * width / max(1, image.width))
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return false }

        let marginX = width * 6 / 100, marginY = height * 6 / 100
        var histogram = [Int](repeating: 0, count: 256)
        var total = 0
        for y in marginY..<(height - marginY) {
            for x in marginX..<(width - marginX) {
                histogram[Int(pixels[y * width + x])] += 1
                total += 1
            }
        }
        guard total > 0 else { return false }

        var seen = 0, paper = 255
        for value in 0..<256 {
            seen += histogram[value]
            if seen * 2 >= total { paper = value; break }
        }
        // Dunkle Seiten (z. B. Fotos) nie verwerfen.
        guard paper >= 100 else { return false }

        let ink = histogram[0..<max(0, paper - 40)].reduce(0, +)
        return Double(ink) / Double(total) < 0.0005
    }
}
