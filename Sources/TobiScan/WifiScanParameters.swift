import Foundation

/// Parameterblöcke, die der iX500 vor einem Scan erwartet. Maße in 1/1200 Zoll.
/// Der Scanner liefert über WLAN immer Farb-JPEGs beider Seiten; Farbmodus und
/// Einseitig/Beidseitig setzt erst der Rechner um.
struct WifiScanParameters {
    let resolution: Int
    let width: Int
    let length: Int
    let automaticSize: Bool
    /// Doppeleinzug-Erkennung: 0xd0 = Ultraschall, 0x88 = Längenvergleich, 0x00 = aus.
    var multifeedDetection: UInt8

    init(settings: ScanSettings) {
        resolution = [150, 200, 300, 600].contains(settings.resolution) ? settings.resolution : 300
        automaticSize = settings.paper == .automatic
        multifeedDetection = settings.detectMultifeed ? 0xd0 : 0x00
        switch settings.paper {
        case .automatic: (width, length) = (10448, 17628)
        case .a4: (width, length) = (9921, 14032)
        case .a5: (width, length) = (6992, 9921)
        case .a6: (width, length) = (4961, 6992)
        case .letter: (width, length) = (10200, 13200)
        case .legal: (width, length) = (10200, 16800)
        }
    }

    /// Bei 600 dpi überträgt der Scanner Vorder- und Rückseite verschränkt.
    var interleavedTransfer: Bool { resolution == 600 }

    /// Datenblock für "Vorab-Lesemodus" (Befehl 0xE9), muss zu `setParams` passen.
    var preReadMode: Data {
        var block = Data(count: 32)
        block.setBE16(resolution, at: 0)
        block.setBE16(resolution, at: 2)
        block.setBE32(width, at: 4)
        block.setBE32(length, at: 8)
        block[12] = 0x05
        return block
    }

    /// Datenblock für "Parameter setzen" (Befehl 0xD4): 32 Byte Einstellungen + 48 Byte Scanfenster.
    /// Nicht kommentierte Konstanten sind vom Hersteller-Treiber übernommen.
    var setParams: Data {
        var block = Data(count: 80)
        block[1] = 0x03
        block[2] = automaticSize ? 1 : 0                 // Papiergröße automatisch erkennen
        block[3] = automaticSize ? 1 : 0
        block[4] = multifeedDetection
        block[6] = 0xc1
        for index in 7...12 { block[index] = 0x80 }
        if resolution == 300 { block[10] = 0x90 }        // gehört zur JPEG-Stufe des Fensters
        block[13] = interleavedTransfer ? 0x80 : 0
        block[31] = 0x30

        let window = 32
        block[window + 1] = 0x10
        block.setBE16(resolution, at: window + 2)
        block.setBE16(resolution, at: window + 4)
        block[window + 6] = 0x05                         // Farbe
        block[window + 7] = 0x81                         // JPEG
        block[window + 8] = [150: 0x05, 200: 0x05, 300: 0x00, 600: 0x0a][resolution] ?? 0
        block.setBE32(width, at: window + 10)
        block.setBE32(length, at: window + 14)
        block[window + 18] = 0x04
        return block
    }
}
