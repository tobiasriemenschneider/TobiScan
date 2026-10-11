import Darwin
import Foundation

/// Antwort auf einen Scanbefehl: 40-Byte-Kopf mit Status, danach die Nutzdaten.
struct WifiReply {
    let header: Data
    let data: Data

    /// SCSI-Status des Scanners: 0 = in Ordnung, 2 = Zustand per "Request Sense" abfragen, 8 = belegt.
    var status: Int { header.be32(8) == 0xffff_ffff ? -1 : header.be32(12) }
}

/// Eine reservierte Verbindung zu einem Scanner: Steuerport für An- und Abmeldung, Datenport für Scanbefehle.
final class WifiSession {
    let info: WifiScannerInfo
    private var dataConnection: TCPConnection?
    private var keepAliveSocket: UDPSocket?
    private var triggerSocket: UDPSocket?
    private var keepAliveTimer: DispatchSourceTimer?
    private var reserved = false
    private let aliveLock = NSLock()
    private var lastAlive = Date()
    /// Für die Fehlersuche: bekommt jeden Befehl mit Status und Antwortlänge.
    var trace: ((String) -> Void)?

    init(info: WifiScannerInfo) {
        self.info = info
    }

    deinit { close() }

    /// Reserviert den Scanner und öffnet den Datenport.
    func open(password: String? = nil) throws {
        let trigger = try UDPSocket(interface: info.interface)
        triggerSocket = trigger

        var request = WifiProtocol.header(command: 0x11, length: 128, mac: info.interface.mac)
        request.append(Data(count: 96))
        request.setBE16(info.interfaceVersion, at: 0x20)
        request[0x22] = 30                                   // Zeitlimit des Scanners in Sekunden
        request.setBE32(1, at: 0x28)                         // Reservierungsart
        request.replaceSubrange(0x2c..<0x30, with: info.interface.addressBytes)
        request.setBE32(Int(trigger.port), at: 0x30)
        let code = Data(WifiProtocol.cipher(password ?? info.defaultPassword).utf8.prefix(48))
        request.replaceSubrange(0x34..<(0x34 + code.count), with: code)

        let now = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        request.setBE16(now.year ?? 0, at: 0x64)
        for (index, value) in [now.month, now.day, now.hour, now.minute, now.second].enumerated() {
            request[0x66 + index] = UInt8(value ?? 0)
        }
        request.replaceSubrange(0x6c..<0x74, with: info.hostID)
        request.setBE32(-TimeZone.current.secondsFromGMT() & 0xffff_ffff, at: 0x74)

        let reply = try control(request)
        guard reply.count >= 12, reply.be32(8) == 0 else {
            let code = reply.count >= 12 ? reply.be32(8) : -1
            throw WifiError.rejected("Der Scanner hat die Anmeldung abgelehnt (Code \(code)). "
                + "Ist er gerade von einem anderen Gerät belegt oder wurde das WLAN-Passwort geändert?")
        }
        reserved = true
        startKeepAlive()
    }

    /// Der Datenport wird erst beim ersten Scanbefehl geöffnet und zwischen zwei Scans wieder geschlossen;
    /// die Reservierung bleibt über die Lebenszeichen bestehen.
    func disconnectData() {
        dataConnection = nil
    }

    /// Antwortet der Scanner noch auf die Lebenszeichen? Nach Ausschalten oder WLAN-Verlust nicht mehr.
    var isAlive: Bool {
        aliveLock.lock()
        defer { aliveLock.unlock() }
        return reserved && Date().timeIntervalSince(lastAlive) < 8
    }

    /// Schickt einen Befehl an den Steuerport; jede Anfrage läuft über eine eigene Verbindung.
    func control(_ request: Data) throws -> Data {
        let connection = try TCPConnection(address: info.address, port: info.controlPort)
        _ = try connection.receive(16, timeout: 5)
        try connection.send(request)
        let head = try connection.receive(4, timeout: 10)
        let length = head.be32(0)
        guard (4...65536).contains(length) else { throw WifiError.protocolViolation("Unerwartete Antwortlänge \(length).") }
        return head + (try connection.receive(length - 4, timeout: 10))
    }

    /// Schickt einen SCSI-artigen Scanbefehl über den Datenport.
    func command(_ cdb: [UInt8], dataOut: Data = Data(), dataIn: Int = 0, timeout: TimeInterval = 30) throws -> WifiReply {
        guard reserved else { throw WifiError.network("Keine Verbindung zum Scanner.") }
        if dataConnection == nil {
            let opened = try TCPConnection(address: info.address, port: info.dataPort)
            _ = try opened.receive(16, timeout: 5)
            dataConnection = opened
        }
        guard let connection = dataConnection else { throw WifiError.network("Keine Verbindung zum Scanner.") }
        var request = WifiProtocol.header(command: 1, length: 64 + dataOut.count, mac: info.interface.mac)
        request.append(Data(count: 32))
        request.setBE32(cdb.count, at: 0x20)
        request.setBE32(dataIn, at: 0x24)
        request.setBE32(dataOut.count, at: 0x28)
        request.replaceSubrange(0x30..<(0x30 + cdb.count), with: cdb)
        request.append(dataOut)
        try connection.send(request)

        let header = try connection.receive(40, timeout: timeout)
        let length = header.be32(0)
        guard header[4..<8] == WifiProtocol.magic, length >= 40 else {
            throw WifiError.protocolViolation("Unerwartete Antwort des Scanners.")
        }
        let data = length > 40 ? try connection.receive(length - 40, timeout: timeout) : Data()
        trace?(cdb.map { String(format: "%02x", $0) }.joined(separator: " ")
            + " -> Kopf " + header[8..<16].map { String(format: "%02x", $0) }.joined() + ", \(data.count) Byte"
            + (data.count <= 32 ? " [" + data.map { String(format: "%02x", $0) }.joined(separator: " ") + "]" : ""))
        return WifiReply(header: header, data: data)
    }

    /// Wartet auf einen Druck der Scan-Taste am Gerät. Der Scanner schickt jede Meldung mehrfach;
    /// zurückgegeben wird ihr Zähler, damit Wiederholungen erkannt werden können.
    func waitForButton(timeout: TimeInterval) -> Int? {
        guard let (data, _) = triggerSocket?.receive(timeout: timeout) else { return nil }
        guard data.count >= 17, data[4..<8] == WifiProtocol.magic, data.be32(8) == 1 else { return nil }
        return Int(data[16])
    }

    func close() {
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
        dataConnection = nil
        if reserved {
            reserved = false
            let release = WifiProtocol.header(command: 0x12, length: 32, mac: info.interface.mac)
            _ = try? control(release)
        }
        keepAliveSocket = nil
        triggerSocket = nil
    }

    /// Ohne regelmäßiges Lebenszeichen gibt der Scanner die Reservierung nach kurzer Zeit wieder frei.
    private func startKeepAlive() {
        guard let socket = try? UDPSocket(interface: info.interface) else { return }
        keepAliveSocket = socket
        let packet = WifiProtocol.searchPacket(interface: info.interface, replyPort: socket.port, keepAlive: true)
        let address = info.address
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: 1.0)
        aliveLock.lock()
        lastAlive = Date()
        aliveLock.unlock()
        timer.setEventHandler { [weak self] in
            socket.send(packet, to: address, port: WifiProtocol.searchPort)
            while socket.receive(timeout: 0) != nil {
                self?.aliveLock.lock()
                self?.lastAlive = Date()
                self?.aliveLock.unlock()
            }
        }
        timer.resume()
        keepAliveTimer = timer
    }
}
