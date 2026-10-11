import AppKit
import CoreGraphics
import CoreText
import Foundation
import Vision

enum PDFExporter {
    enum ExportError: LocalizedError {
        case cannotCreate
        case unreadablePage(Int)

        var errorDescription: String? {
            switch self {
            case .cannotCreate: return "Die PDF-Datei konnte nicht angelegt werden."
            case .unreadablePage(let number): return "Seite \(number) konnte nicht gelesen werden."
            }
        }
    }

    /// Schreibt alle Seiten in ein PDF; mit `ocr` wird der erkannte Text unsichtbar über das Bild gelegt.
    static func export(_ pages: [ScannedPage], to url: URL, ocr: Bool,
                       progress: @escaping (Int) -> Void) throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: temporary) }

        let info = [kCGPDFContextCreator: "TobiScan"] as CFDictionary
        guard let context = CGContext(temporary as CFURL, mediaBox: nil, info) else { throw ExportError.cannotCreate }

        for (index, page) in pages.enumerated() {
            guard let image = page.loadImage() else { throw ExportError.unreadablePage(index + 1) }
            let size = page.pointSize
            var box = CGRect(origin: .zero, size: size)
            context.beginPage(mediaBox: &box)
            page.draw(image, in: context, size: size)
            if ocr {
                drawInvisibleText(recognizeText(in: image, orientation: page.orientation), in: context, size: size)
            }
            context.endPage()
            progress(index + 1)
        }
        context.closePDF()

        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    static func recognizeText(in image: CGImage, orientation: CGImagePropertyOrientation) -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["de-DE", "en-US"]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation)
        try? handler.perform([request])
        return request.results ?? []
    }

    private static func drawInvisibleText(_ observations: [VNRecognizedTextObservation], in context: CGContext, size: CGSize) {
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        for observation in observations {
            guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else { continue }
            let box = CGRect(x: observation.boundingBox.minX * size.width,
                             y: observation.boundingBox.minY * size.height,
                             width: observation.boundingBox.width * size.width,
                             height: observation.boundingBox.height * size.height)
            guard box.width > 0, box.height > 0 else { continue }

            let font = CTFontCreateWithName("Helvetica" as CFString, box.height * 0.8, nil)
            let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.clear])
            let line = CTLineCreateWithAttributedString(attributed)
            let lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
            guard lineWidth > 0 else { continue }

            // Zeile horizontal auf die erkannte Breite strecken, damit die Textauswahl zum Bild passt.
            context.saveGState()
            context.translateBy(x: box.minX, y: box.minY + box.height * 0.2)
            context.scaleBy(x: box.width / lineWidth, y: 1)
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
        }
        context.restoreGState()
    }
}
