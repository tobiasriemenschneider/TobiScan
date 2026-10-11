import Foundation

/// Führt einen Stapelscan über WLAN aus und legt jede Seite als JPEG in `directory` ab.
final class WifiScanJob {
    private let info: WifiScannerInfo
    private let settings: ScanSettings
    var parameters: WifiScanParameters
    private let directory: URL
    private let lock = NSLock()
    private var cancelled = false
    private var fileCount = 0
    /// Der Scanner hat für ein angefordertes Blatt keine Bilddaten geliefert.
    private struct NoImageData: Error {}
    var log: (String) -> Void = ScanLog.write

    init(info: WifiScannerInfo, settings: ScanSettings, directory: URL) {
        self.info = info
        self.settings = settings
        self.parameters = WifiScanParameters(settings: settings)
        self.directory = directory
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private struct Sense {
        let key: Int
        let endOfMedium: Bool
        let information: Int
        let asc: Int
        let ascq: Int

        var noPaper: Bool { key == 3 && ascq == 0x03 }
        /// "Vorübergehend keine Daten": Die angefragte Seite ist noch nicht gescannt – oder es kommt keine mehr.
        var noData: Bool { key == 3 && ascq == 0x13 }

        var message: String {
            switch (key, ascq) {
            case (3, 0x01): return "Papierstau – bitte das Papier entfernen und erneut scannen."
            case (3, 0x02): return "Die Abdeckung des Scanners ist offen."
            case (3, 0x03): return "Kein Papier im Einzug."
            case (3, 0x13): return "Der Scanner hat keine Bilddaten geliefert."
            case (3, 0x07): return "Doppeleinzug erkannt – bitte die Blätter auffächern und erneut einlegen."
            case (3, 0x31), (3, 0x35): return "Der Scanner ist gerade belegt."
            case (2, _): return "Der Scanner ist nicht bereit."
            default: return String(format: "Scannerfehler (Sense %x/%02x/%02x).", key, asc, ascq)
            }
        }
    }

    /// Scannt, bis der Einzug leer ist. Gibt die Zahl der gescannten Blätter zurück.
    /// Mit `session` läuft der Scan über eine bereits reservierte Verbindung, die danach offen bleibt.
    @discardableResult
    func run(session existing: WifiSession? = nil) throws -> Int {
        do {
            let sheets = try scan(existing)
            log("Ende: \(sheets) Blatt")
            return sheets
        } catch {
            log("Fehler: \(error.localizedDescription)")
            throw error
        }
    }

    private func scan(_ existing: WifiSession?) throws -> Int {
        let session = existing ?? WifiSession(info: info)
        session.trace = log
        log("=== Scan über WLAN: \(info.name), \(parameters.resolution) dpi, Papier \(settings.paper.rawValue), "
            + "\(settings.duplex ? "beidseitig" : "einseitig") ===")
        if existing == nil { try session.open() }
        defer {
            session.trace = nil
            if existing == nil { session.close() } else { session.disconnectData() }
        }

        try expectGood(session.command([0xd5, 0, 0, 0, 0x08, 0x08], dataOut: Data(count: 8), dataIn: 8), session, "Job starten")
        defer { _ = try? session.command([0xd6, 0, 0, 0, 0, 0]) }
        _ = try session.command([0xd8, 0, 0, 0, 0, 0])

        try expectGood(session.command([0xe9, 0, 0, 0, 0, 0, 0, 0x20, 0, 0], dataOut: parameters.preReadMode), session, "Lesemodus setzen")
        try expectGood(session.command([0xd4, 0, 0, 0, 0x50, 0], dataOut: parameters.setParams), session, "Parameter setzen")

        let hardware = try session.command([0xc2, 0, 0, 0, 0, 0, 0, 0, 0x20, 0], dataIn: 0x20)
        if hardware.data.count >= 4, hardware.data[3] & 0x80 != 0 {
            throw WifiError.rejected("Kein Papier im Einzug.")
        }
        try expectGood(session.command([0xe0, 0, 0, 0, 0, 0]), session, "Blatt einziehen")

        var sheets = 0
        do {
            while true {
                let front = UInt8(truncatingIfNeeded: sheets * 2), back = front &+ 1
                var sides: [Data]
                do {
                    sides = parameters.interleavedTransfer
                        ? try readInterleaved(session, front: front, back: back)
                        : [try readSide(session, window: 0x00, page: front), try readSide(session, window: 0x80, page: back)]
                } catch is NoImageData {
                    // Auch nach Wartezeit kam kein weiteres Blatt: Bei leerem Einzug ist der Stapel zu Ende.
                    let status = try session.command([0xc2, 0, 0, 0, 0, 0, 0, 0, 0x20, 0], dataIn: 0x20)
                    let hopperEmpty = status.data.count >= 4 && status.data[3] & 0x80 != 0
                    if isCancelled || (hopperEmpty && sheets > 0) { break }
                    throw WifiError.rejected(hopperEmpty
                        ? "Kein Papier im Einzug."
                        : "Der Scanner hat keine Bilddaten geliefert, obwohl noch Papier im Einzug liegt. Bitte erneut scannen.")
                }
                log("Blatt \(sheets + 1): Vorderseite \(sides[0].count) Byte, Rückseite \(sides[1].count) Byte")

                // Nach jedem Blatt fragt der Hersteller-Treiber die Bildmaße ab; bei automatischer
                // Größe steht dort die tatsächliche Länge, die noch in die JPEGs eingetragen werden muss.
                if parameters.automaticSize {
                    let pixelSize = try session.command([0x28, 0, 0x80, 0, 0, 0x80, 0, 0, 0x20, 0, back, 0], dataIn: 0x20)
                    log("Bildmaße: " + WifiProbe.hex(pixelSize.data))
                    if pixelSize.status == 0, pixelSize.data.count >= 16 {
                        let lines = pixelSize.data.be32(12)
                        sides = sides.map { Self.settingJPEGHeight($0, to: lines) }
                    }
                } else {
                    _ = try session.command([0x28, 0, 0x81, 0, 0, 0x80, 0, 0, 0x08, 0, back, 0], dataIn: 0x08)
                }

                try write(sides[0])
                if settings.duplex { try write(sides[1]) }
                sheets += 1

                if isCancelled { break }
                let status = try session.command([0xc2, 0, 0, 0, 0, 0, 0, 0, 0x20, 0], dataIn: 0x20)
                if status.data.count >= 7, status.data[6] & 0x80 != 0 {
                    let sense = try requestSense(session)
                    if sense.key != 0 { throw WifiError.rejected(sense.message) }
                    break
                }
                let next = try session.command([0xe0, 0, 0, 0, 0, 0])
                if next.status != 0 {
                    let sense = try requestSense(session)
                    if sense.noPaper { break }
                    throw WifiError.rejected(sense.message)
                }
            }
        } catch {
            _ = try? session.command([0xd8, 0, 0, 0, 0, 0])
            throw error
        }
        // Auch am regulären Ende: verwirft den Lesevorgang, der ins Leere lief.
        _ = try? session.command([0xd8, 0, 0, 0, 0, 0])
        return sheets
    }

    private func requestSense(_ session: WifiSession) throws -> Sense {
        let reply = try session.command([0x03, 0, 0, 0, 0x12, 0], dataIn: 0x12)
        guard reply.data.count >= 14 else { throw WifiError.protocolViolation("Unvollständige Statusantwort des Scanners.") }
        let data = reply.data
        let sense = Sense(key: Int(data[2] & 0x0f), endOfMedium: data[2] & 0x40 != 0, information: data.be32(3),
                          asc: Int(data[12]), ascq: Int(data[13]))
        log(String(format: "Sense: key %x asc %02x ascq %02x eom %d info %d", sense.key, sense.asc, sense.ascq, sense.endOfMedium ? 1 : 0, sense.information))
        return sense
    }

    private func expectGood(_ reply: WifiReply, _ session: WifiSession, _ step: String) throws {
        switch reply.status {
        case 0: return
        case 2: throw WifiError.rejected(try requestSense(session).message)
        case 8: throw WifiError.rejected("Der Scanner ist gerade belegt.")
        default: throw WifiError.protocolViolation("Der Scanner hat „\(step)“ abgelehnt.")
        }
    }

    /// Liest einen Bildblock. Meldet der Scanner "belegt" oder "vorübergehend keine Daten", ist die Seite
    /// noch nicht fertig gescannt; dann wird kurz gewartet und erneut gefragt. Zu einem Block mit Status 2
    /// gehört die bereits abgefragte Zustandsmeldung.
    private func readChunk(_ session: WifiSession, cdb: [UInt8], length: Int, pageStart: Bool) throws -> (WifiReply, Sense?) {
        let started = Date()
        // So lange darf bei leerem Einzug noch ein Blatt unterwegs sein, bevor der Stapel als beendet gilt.
        let emptyGrace: TimeInterval = parameters.resolution == 600 ? 10 : 4
        while true {
            let reply = try session.command(cdb, dataIn: length, timeout: 120)
            let waited = Date().timeIntervalSince(started)
            switch reply.status {
            case 0:
                return (reply, nil)
            case 2:
                let sense = try requestSense(session)
                guard sense.noData, pageStart else { return (reply, sense) }
                let hardware = try session.command([0xc2, 0, 0, 0, 0, 0, 0, 0, 0x20, 0], dataIn: 0x20)
                let hopperEmpty = hardware.data.count >= 4 && hardware.data[3] & 0x80 != 0
                if (hopperEmpty && waited > emptyGrace) || waited > 30 || isCancelled { throw NoImageData() }
            case 8:
                if waited > 60 || isCancelled {
                    throw WifiError.protocolViolation("Der Scanner liefert keine Bilddaten (dauerhaft belegt).")
                }
            default:
                log("Unerwarteter Lesestatus \(reply.status), Kopf " + WifiProbe.hex(reply.header))
                throw WifiError.protocolViolation("Bilddaten konnten nicht gelesen werden (Status \(reply.status)).")
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    /// Liest eine Seite blockweise, bis der Scanner das Ende meldet. Jeder Block beginnt mit 2 Byte Seiten-/Blocknummer.
    private func readSide(_ session: WifiSession, window: UInt8, page: UInt8) throws -> Data {
        var image = Data()
        var sequence: UInt8 = 0
        while true {
            let (reply, sense) = try readChunk(session, cdb: [0x28, 0, 0, 0, 0, window, 0x30, 0, 0, 0, page, sequence],
                                               length: 0x300000, pageStart: image.isEmpty)
            image.append(reply.data.dropFirst(2))
            guard let sense else {
                sequence &+= 1
                continue
            }
            guard sense.endOfMedium, sense.key == 0 else { throw WifiError.rejected(sense.message) }
            return image
        }
    }

    /// Bei 600 dpi kommen Vorder- und Rückseite abwechselnd in kleinen Blöcken.
    private func readInterleaved(_ session: WifiSession, front: UInt8, back: UInt8) throws -> [Data] {
        let chunk = 0x20000
        var images = [Data(), Data()]
        var finished = [false, false]
        var sequence: UInt8 = 0
        while !(finished[0] && finished[1]) {
            for (index, window, page) in [(0, UInt8(0x00), front), (1, UInt8(0x80), back)] where !finished[index] {
                let (reply, sense) = try readChunk(session, cdb: [0x28, 0, 0, 0, 0, window, 0x02, 0, 0, 0, page, sequence],
                                                   length: chunk, pageStart: images[index].isEmpty)
                let payload = reply.data.dropFirst(2)
                guard let sense else {
                    images[index].append(payload)
                    continue
                }
                guard sense.endOfMedium, sense.key == 0 else { throw WifiError.rejected(sense.message) }
                images[index].append(payload.prefix(max(0, min(payload.count, chunk - 2 - sense.information))))
                finished[index] = true
            }
            sequence &+= 1
        }
        return images
    }

    private func write(_ image: Data) throws {
        fileCount += 1
        // Erst unter anderem Namen schreiben, damit die App keine halbfertige Datei einliest.
        let final = directory.appendingPathComponent(String(format: "p%05d.jpg", fileCount))
        let partial = final.appendingPathExtension("part")
        try image.write(to: partial)
        try FileManager.default.moveItem(at: partial, to: final)
    }

    /// Trägt die tatsächliche Zeilenzahl in den JPEG-Kopf ein (Feld "Höhe" im SOF-Segment).
    static func settingJPEGHeight(_ jpeg: Data, to height: Int) -> Data {
        guard height > 0, height < 65536, jpeg.count > 4, jpeg[jpeg.startIndex] == 0xff, jpeg[jpeg.startIndex + 1] == 0xd8 else { return jpeg }
        var data = Data(jpeg)
        var offset = 2
        while offset + 9 < data.count, data[offset] == 0xff {
            let marker = data[offset + 1]
            if (0xc0...0xc2).contains(marker) {
                data.setBE16(height, at: offset + 5)
                return data
            }
            if marker == 0xda { break }
            offset += 2 + data.be16(offset + 2)
        }
        return jpeg
    }
}
