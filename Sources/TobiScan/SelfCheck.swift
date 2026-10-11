import AppKit
import Foundation
import PDFKit

/// `TobiScan --selfcheck`: prüft Scan-Pipeline und PDF-Export ohne Fenster, gegen das SANE-Testgerät.
enum SelfCheck {
    static func run() -> Never {
        let semaphore = DispatchSemaphore(value: 0)
        var failures = 0
        Task.detached {
            failures = await check()
            semaphore.signal()
        }
        semaphore.wait()
        print(failures == 0 ? "SELFCHECK OK" : "SELFCHECK FEHLGESCHLAGEN (\(failures))")
        exit(failures == 0 ? 0 : 1)
    }

    private static func check() async -> Int {
        var failures = 0
        func expect(_ condition: Bool, _ what: String) {
            print(condition ? "  ok   " : "  FAIL ", what)
            if !condition { failures += 1 }
        }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("TobiScan-selfcheck-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // 1. Geräte, Optionen und Stapelscan über das Testgerät
        var pages: [ScannedPage] = []
        do {
            let devices = try await Scanner.listDevices(includeTestDevice: true)
            expect(devices.contains { $0.id == "test:0" }, "Testgerät gefunden (\(devices.map(\.id)))")
            let device = ScanDevice(id: "test:0", vendor: "Noname", model: "frontend-tester")
            let options = try await Scanner.options(for: device, includeTestDevice: true)
            expect(options.choices["--source"]?.contains("Automatic Document Feeder") == true, "Quellen erkannt")
            expect(options.choices["--mode"] == ["Gray", "Color"], "Modi erkannt")
            expect(options.maxValues["-x"] == 200, "Maximale Breite erkannt")
            expect(!options.has("--three-pass"), "Inaktive Optionen ausgelassen")

            var settings = ScanSettings()
            settings.resolution = 150
            let arguments = Scanner.scanArguments(device: device, settings: settings, options: options,
                                                  outputPattern: work.appendingPathComponent("p%05d.tif").path)
            print("  args ", arguments.joined(separator: " "))
            let output = try await Scanner.run(arguments, includeTestDevice: true)
            let files = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "tif" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            expect(files.count == 10, "10 Seiten aus dem Einzug (\(files.count), Status \(output.status))")
            for file in files {
                if case .page(let page) = PageImporter.importScan(at: file, into: work, dpi: 150, skipBlank: true) {
                    pages.append(page)
                }
            }
            expect(pages.count == 10, "Gitterseiten gelten nicht als leer (\(pages.count))")
            expect(Scanner.friendlyMessage(for: output.stderr) == "Kein Papier im Einzug.", "Fehlermeldung übersetzt")
        } catch {
            expect(false, "Scan über Testgerät: \(error.localizedDescription)")
        }

        // 2. Leerseitenerkennung und Texterkennung mit künstlichen Seiten
        let textURL = work.appendingPathComponent("text.tif"), blankURL = work.appendingPathComponent("blank.tif")
        writeTIFF(textPage(lines: ["Rechnung Nummer 4711", "Vielen Dank für Ihren Einkauf"]), to: textURL)
        writeTIFF(textPage(lines: []), to: blankURL)
        if case .blank = PageImporter.importScan(at: blankURL, into: work, dpi: 300, skipBlank: true) {
            expect(true, "Leere Seite erkannt")
        } else {
            expect(false, "Leere Seite erkannt")
        }
        guard case .page(var textPage) = PageImporter.importScan(at: textURL, into: work, dpi: 300, skipBlank: true) else {
            expect(false, "Textseite importiert")
            return failures
        }
        expect(textPage.isJPEG && textPage.pixelWidth == 2480, "Textseite importiert")

        // Seite liegt um 90° gedreht vor und wird im Programm zurückgedreht.
        textPage.rotation = 90
        let pdfURL = work.appendingPathComponent("out.pdf")
        do {
            try PDFExporter.export(pages + [textPage], to: pdfURL, ocr: true) { _ in }
            let document = PDFDocument(url: pdfURL)
            expect(document?.pageCount == pages.count + 1, "PDF hat \(pages.count + 1) Seiten")
            let last = document?.page(at: pages.count)
            let bounds = last?.bounds(for: .mediaBox) ?? .zero
            expect(abs(bounds.width - 841.9) < 1 && abs(bounds.height - 595.3) < 1, "Gedrehte Seite ist A4 quer (\(bounds.size))")
            let text = last?.string ?? ""
            expect(text.contains("4711") && text.contains("Einkauf"), "Text durchsuchbar: \(text.replacingOccurrences(of: "\n", with: " | "))")
            let size = (try? FileManager.default.attributesOfItem(atPath: pdfURL.path)[.size] as? Int) ?? 0
            print("  info  PDF-Größe \(size / 1024) KB")
            if let keep = ProcessInfo.processInfo.environment["TOBISCAN_KEEP_PDF"] {
                try? FileManager.default.removeItem(atPath: keep)
                try? FileManager.default.copyItem(atPath: pdfURL.path, toPath: keep)
            }
        } catch {
            expect(false, "PDF-Export: \(error.localizedDescription)")
        }
        return failures
    }

    /// A4 bei 300 dpi, Text um 90° gegen den Uhrzeigersinn gedreht (wie ein quer eingelegtes Blatt).
    private static func textPage(lines: [String]) -> CGImage {
        let width = 2480, height = 3508
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.97, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: CGFloat(width), y: 0)
        context.rotate(by: .pi / 2)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for (index, line) in lines.enumerated() {
            (line as NSString).draw(at: NSPoint(x: 300, y: 1900 - index * 200),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 90), .foregroundColor: NSColor.black])
        }
        NSGraphicsContext.current = nil
        return context.makeImage()!
    }

    private static func writeTIFF(_ image: CGImage, to url: URL) {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
