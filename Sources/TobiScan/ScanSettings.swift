import Foundation

enum ColorMode: String, Codable, CaseIterable, Identifiable {
    case color, gray, blackWhite
    var id: String { rawValue }

    var title: String {
        switch self {
        case .color: return "Farbe"
        case .gray: return "Graustufen"
        case .blackWhite: return "Schwarzweiß"
        }
    }
}

enum PaperSize: String, Codable, CaseIterable, Identifiable {
    case automatic, a4, a5, a6, letter, legal
    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automatisch"
        case .a4: return "A4"
        case .a5: return "A5"
        case .a6: return "A6"
        case .letter: return "Letter"
        case .legal: return "Legal"
        }
    }

    /// Breite und Höhe in Millimetern; `nil` bedeutet maximale Scanfläche.
    var millimeters: (width: Double, height: Double)? {
        switch self {
        case .automatic: return nil
        case .a4: return (210, 297)
        case .a5: return (148, 210)
        case .a6: return (105, 148)
        case .letter: return (215.9, 279.4)
        case .legal: return (215.9, 355.6)
        }
    }
}

struct ScanSettings: Codable, Equatable {
    var duplex = true
    var colorMode = ColorMode.color
    var resolution = 300
    var paper = PaperSize.a4
    var skipBlankPages = true
    var deskew = true
    var lightenBackground = true
    var detectMultifeed = true
    var scannerButton = true
    var ocr = true
    var suggestFilename = true
    var showTestDevice = false

    init() {}

    /// Fehlende Schlüssel (Einstellungen aus einer älteren Version) behalten ihre Vorgabe.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? values.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        duplex = read(.duplex, duplex)
        colorMode = read(.colorMode, colorMode)
        resolution = read(.resolution, resolution)
        paper = read(.paper, paper)
        skipBlankPages = read(.skipBlankPages, skipBlankPages)
        deskew = read(.deskew, deskew)
        lightenBackground = read(.lightenBackground, lightenBackground)
        detectMultifeed = read(.detectMultifeed, detectMultifeed)
        scannerButton = read(.scannerButton, scannerButton)
        ocr = read(.ocr, ocr)
        suggestFilename = read(.suggestFilename, suggestFilename)
        showTestDevice = read(.showTestDevice, showTestDevice)
    }

    static let resolutions = [150, 200, 300, 600]
    private static let defaultsKey = "scanSettings"

    static func load() -> ScanSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(ScanSettings.self, from: data)
        else { return ScanSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
