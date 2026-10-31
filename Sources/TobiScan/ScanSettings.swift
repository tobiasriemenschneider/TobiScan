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

    /// Kurzform für den Segment-Umschalter in der Seitenleiste.
    var shortTitle: String {
        switch self {
        case .color: return "Farbe"
        case .gray: return "Grau"
        case .blackWhite: return "S/W"
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

    struct PostProcessingOption: Identifiable {
        let title: String
        /// Name eines SF Symbols.
        let symbol: String
        let keyPath: WritableKeyPath<ScanSettings, Bool>
        /// Die Identität hängt an der Einstellung, nicht am angezeigten Text.
        var id: AnyKeyPath { keyPath }
    }

    /// Die Schalter im Bereich „Nachbearbeitung“, Reihenfolge Bild, Einzug, PDF.
    /// Die Zeilen und die Symbolleiste im zugeklappten Zustand lesen beide diese Tabelle.
    static let postProcessingOptions: [PostProcessingOption] = [
        .init(title: "Leere Seiten entfernen", symbol: "rectangle.portrait.slash", keyPath: \.skipBlankPages),
        .init(title: "Schräglage korrigieren", symbol: "skew", keyPath: \.deskew),
        .init(title: "Hintergrund aufhellen", symbol: "sun.max", keyPath: \.lightenBackground),
        .init(title: "Doppeleinzug erkennen", symbol: "doc.on.doc", keyPath: \.detectMultifeed),
        .init(title: "Scan-Taste am Gerät", symbol: "button.programmable", keyPath: \.scannerButton),
        .init(title: "Texterkennung (OCR)", symbol: "text.viewfinder", keyPath: \.ocr),
        .init(title: "Dateiname vorschlagen", symbol: "sparkles", keyPath: \.suggestFilename),
    ]
    var activePostProcessingCount: Int {
        Self.postProcessingOptions.filter { self[keyPath: $0.keyPath] }.count
    }
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
