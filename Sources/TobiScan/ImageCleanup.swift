import CoreGraphics
import Foundation

/// Nachbearbeitung am Rechner: Schräglage aus den Textzeilen schätzen, geradedrehen, Papierton aufhellen.
enum ImageCleanup {
    private struct Bitmap {
        let pixels: [UInt8]
        let width: Int
        let height: Int
    }

    /// Verkleinerte Kopie; Zeile 0 ist die oberste Bildzeile. `components` ist 1 (Grau) oder 4 (RGBX).
    private static func bitmap(_ image: CGImage, width: Int, components: Int) -> Bitmap? {
        let width = min(width, image.width)
        let height = max(1, image.height * width / max(1, image.width))
        var pixels = [UInt8](repeating: 0, count: width * height * components)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            let space = components == 1 ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
            let info = components == 1 ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * components, space: space, bitmapInfo: info)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? Bitmap(pixels: pixels, width: width, height: height) : nil
    }

    /// Winkel in Grad, um den das Bild im Uhrzeigersinn gedreht werden muss, damit die Zeilen waagerecht liegen.
    /// `nil`, wenn sich keine verlässliche Richtung findet (zu wenig Text, Fotos).
    static func skewAngle(of image: CGImage) -> Double? {
        guard let small = bitmap(image, width: 800, components: 1) else { return nil }
        var histogram = [Int](repeating: 0, count: 256)
        for value in small.pixels { histogram[Int(value)] += 1 }
        var seen = 0, paper = 255
        for level in 0..<256 {
            seen += histogram[level]
            if seen * 2 >= small.pixels.count { paper = level; break }
        }
        guard paper >= 100 else { return nil }

        // Dunkle Punkte abseits der Ränder (dort liegen Schatten und Kanten des Blatts).
        let marginX = small.width / 20, marginY = small.height / 20
        var points: [(x: Double, y: Double)] = []
        for y in marginY..<(small.height - marginY) {
            for x in marginX..<(small.width - marginX) where Int(small.pixels[y * small.width + x]) < paper - 50 {
                points.append((Double(x - small.width / 2), Double(y)))
            }
        }
        guard points.count > 800 else { return nil }
        if points.count > 150_000 {
            let step = points.count / 150_000 + 1
            points = stride(from: 0, to: points.count, by: step).map { points[$0] }
        }

        // Für jeden Winkel die Punkte entlang der gedachten Zeilenrichtung aufsummieren:
        // Liegen die Zeilen genau waagerecht, ist das Profil am schärfsten.
        let pad = small.width
        func sharpness(_ degrees: Double) -> Double {
            let slope = tan(degrees * .pi / 180)
            var rows = [Int32](repeating: 0, count: small.height + 2 * pad)
            for point in points { rows[Int(point.y + point.x * slope) + pad] += 1 }
            return rows.reduce(0.0) { $0 + Double($1) * Double($1) }
        }
        let coarse = stride(from: -5.0, through: 5.0, by: 0.25).map { ($0, sharpness($0)) }
        guard let roughBest = coarse.max(by: { $0.1 < $1.1 }) else { return nil }
        let fine = stride(from: roughBest.0 - 0.25, through: roughBest.0 + 0.25, by: 0.05).map { ($0, sharpness($0)) }
        guard let best = fine.max(by: { $0.1 < $1.1 }) else { return nil }

        // Nur vertrauen, wenn der beste Winkel sich deutlich vom Durchschnitt abhebt und nicht am Rand des Suchbereichs liegt.
        let average = coarse.reduce(0.0) { $0 + $1.1 } / Double(coarse.count)
        guard best.1 > average * 1.2, abs(best.0) < 4.9 else { return nil }
        return best.0
    }

    /// Farbe des Papiers: der häufigste helle Ton. `nil` bei Bildern ohne klaren Papierhintergrund.
    private static func paperColor(of image: CGImage) -> (red: Double, green: Double, blue: Double)? {
        guard let small = bitmap(image, width: 300, components: 4) else { return nil }
        let count = small.width * small.height
        var histogram = [Int](repeating: 0, count: 256)
        var luminance = [UInt8](repeating: 0, count: count)
        for index in 0..<count {
            let value = (Int(small.pixels[index * 4]) * 3 + Int(small.pixels[index * 4 + 1]) * 6 + Int(small.pixels[index * 4 + 2])) / 10
            luminance[index] = UInt8(value)
            histogram[value] += 1
        }
        guard let peak = (120..<256).max(by: { histogram[$0] < histogram[$1] }) else { return nil }
        var sums = (0.0, 0.0, 0.0), members = 0.0
        for index in 0..<count where abs(Int(luminance[index]) - peak) <= 8 {
            sums.0 += Double(small.pixels[index * 4])
            sums.1 += Double(small.pixels[index * 4 + 1])
            sums.2 += Double(small.pixels[index * 4 + 2])
            members += 1
        }
        guard members > Double(count) * 0.3 else { return nil }
        return (sums.0 / members, sums.1 / members, sums.2 / members)
    }

    /// Dreht das Bild um `degrees` im Uhrzeigersinn und hellt auf Wunsch den Papierton auf Weiß auf.
    static func process(_ image: CGImage, rotateBy degrees: Double, lighten: Bool) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let base = context.data
        else { return nil }
        let paper = paperColor(of: image)

        // Die beim Drehen frei werdenden Ecken mit dem Papierton füllen.
        let fill = paper ?? (255, 255, 255)
        context.setFillColor(red: fill.red / 255, green: fill.green / 255, blue: fill.blue / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.translateBy(x: Double(width) / 2, y: Double(height) / 2)
        context.rotate(by: -degrees * .pi / 180)
        context.translateBy(x: -Double(width) / 2, y: -Double(height) / 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        if lighten, let paper {
            // Jeden Farbkanal so strecken, dass der Papierton knapp unter Weiß landet; das nimmt auch den Farbstich.
            let tables = [paper.red, paper.green, paper.blue].map { tone -> [UInt8] in
                let gain = min(1.8, 250 / max(tone, 1))
                return (0..<256).map { UInt8(min(255, (Double($0) * gain).rounded())) }
            }
            let pixels = base.bindMemory(to: UInt8.self, capacity: width * height * 4)
            for index in 0..<(width * height) {
                pixels[index * 4] = tables[0][Int(pixels[index * 4])]
                pixels[index * 4 + 1] = tables[1][Int(pixels[index * 4 + 1])]
                pixels[index * 4 + 2] = tables[2][Int(pixels[index * 4 + 2])]
            }
        }
        return context.makeImage()
    }
}
