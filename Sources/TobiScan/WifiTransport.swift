import Darwin
import Foundation

// Netzwerkschicht für das WLAN-Protokoll des ScanSnap iX500 ("VENS").
// Suche per UDP (Port 52217), Reservierung über den Steuerport, Scanbefehle über den Datenport.

enum WifiError: LocalizedError {
    case network(String)
    case protocolViolation(String)
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .network(let message), .protocolViolation(let message), .rejected(let message): return message
        }
    }
}

extension Data {
    func be16(_ offset: Int) -> Int {
        Int(self[startIndex + offset]) << 8 | Int(self[startIndex + offset + 1])
    }

    func be32(_ offset: Int) -> Int {
        (0..<4).reduce(0) { $0 << 8 | Int(self[startIndex + offset + $1]) }
    }

    mutating func setBE16(_ value: Int, at offset: Int) {
        self[startIndex + offset] = UInt8(value >> 8 & 0xff)
        self[startIndex + offset + 1] = UInt8(value & 0xff)
    }

    mutating func setBE32(_ value: Int, at offset: Int) {
        for index in 0..<4 {
            self[startIndex + offset + index] = UInt8(value >> (8 * (3 - index)) & 0xff)
        }
    }

    func cString(at offset: Int, length: Int) -> String {
        let bytes = self[(startIndex + offset)..<(startIndex + offset + length)].prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}

/// Lokale IPv4-Schnittstelle, über die ein Scanner erreichbar sein kann.
struct LocalInterface {
    let name: String
    let address: in_addr
    let broadcast: in_addr
    let mac: [UInt8]

    var addressBytes: [UInt8] { withUnsafeBytes(of: address.s_addr) { Array($0) } }

    static func all() -> [LocalInterface] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }

        var macs: [String: [UInt8]] = [:]
        var result: [(String, in_addr, in_addr)] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sockaddr = entry.pointee.ifa_addr else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            let flags = Int32(entry.pointee.ifa_flags)
            switch Int32(sockaddr.pointee.sa_family) {
            case AF_LINK:
                sockaddr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { link in
                    guard link.pointee.sdl_alen == 6 else { return }
                    let offset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data)! + Int(link.pointee.sdl_nlen)
                    macs[name] = UnsafeRawPointer(link).advanced(by: offset)
                        .withMemoryRebound(to: UInt8.self, capacity: 6) { Array(UnsafeBufferPointer(start: $0, count: 6)) }
                }
            case AF_INET:
                guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, flags & IFF_BROADCAST != 0,
                      let destination = entry.pointee.ifa_dstaddr else { continue }
                let address = sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                let broadcast = destination.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                result.append((name, address, broadcast))
            default:
                break
            }
        }
        return result.compactMap { name, address, broadcast in
            macs[name].map { LocalInterface(name: name, address: address, broadcast: broadcast, mac: $0) }
        }
    }
}

private func socketAddress(_ address: in_addr, port: UInt16) -> sockaddr_in {
    var result = sockaddr_in()
    result.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    result.sin_family = sa_family_t(AF_INET)
    result.sin_port = port.bigEndian
    result.sin_addr = address
    return result
}

private func withSockaddr<T>(_ address: sockaddr_in, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    var copy = address
    return withUnsafePointer(to: &copy) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
}

/// UDP-Socket an einer lokalen Schnittstelle; der Port wird vom System vergeben.
final class UDPSocket {
    let descriptor: Int32
    let port: UInt16

    init(interface: LocalInterface) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw WifiError.network("UDP-Socket konnte nicht geöffnet werden.") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        let bound = withSockaddr(socketAddress(interface.address, port: 0)) { bind(fd, $0, $1) }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard bound == 0, named == 0 else {
            close(fd)
            throw WifiError.network("UDP-Socket konnte nicht gebunden werden.")
        }
        descriptor = fd
        port = UInt16(bigEndian: actual.sin_port)
    }

    deinit { close(descriptor) }

    func send(_ data: Data, to address: in_addr, port: UInt16) {
        _ = data.withUnsafeBytes { buffer in
            withSockaddr(socketAddress(address, port: port)) { sendto(descriptor, buffer.baseAddress, buffer.count, 0, $0, $1) }
        }
    }

    /// Wartet höchstens `timeout` Sekunden auf ein Datagramm.
    func receive(timeout: TimeInterval) -> (data: Data, sender: in_addr)? {
        var descriptorSet = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptorSet, 1, Int32(max(0, timeout) * 1000)) > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 2048)
        var sender = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = withUnsafeMutablePointer(to: &sender) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(descriptor, &buffer, buffer.count, 0, $0, &length) }
        }
        guard count > 0 else { return nil }
        return (Data(buffer[0..<count]), sender.sin_addr)
    }
}

/// Blockierende TCP-Verbindung mit Zeitlimits.
final class TCPConnection {
    private let descriptor: Int32

    init(address: in_addr, port: UInt16, timeout: TimeInterval = 5) throws {
        descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw WifiError.network("TCP-Socket konnte nicht geöffnet werden.") }
        var yes: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(descriptor, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))

        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        let started = withSockaddr(socketAddress(address, port: port)) { connect(descriptor, $0, $1) }
        if started != 0 {
            var descriptorSet = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            var failure: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            let ready = errno == EINPROGRESS && poll(&descriptorSet, 1, Int32(timeout * 1000)) > 0
            getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &length)
            guard ready, failure == 0 else {
                close(descriptor)
                throw WifiError.network("Keine Verbindung zum Scanner (Port \(port)).")
            }
        }
        _ = fcntl(descriptor, F_SETFL, flags)
    }

    deinit { close(descriptor) }

    func send(_ data: Data) throws {
        var sent = 0
        try data.withUnsafeBytes { buffer in
            while sent < buffer.count {
                let count = Darwin.send(descriptor, buffer.baseAddress! + sent, buffer.count - sent, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw WifiError.network("Verbindung zum Scanner unterbrochen (Senden).") }
                sent += count
            }
        }
    }

    func receive(_ length: Int, timeout: TimeInterval) throws -> Data {
        var data = Data(count: length)
        var received = 0
        let deadline = Date().addingTimeInterval(timeout)
        try data.withUnsafeMutableBytes { buffer in
            while received < length {
                var descriptorSet = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0, poll(&descriptorSet, 1, Int32(remaining * 1000)) > 0 else {
                    throw WifiError.network("Der Scanner antwortet nicht.")
                }
                let count = recv(descriptor, buffer.baseAddress! + received, length - received, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw WifiError.network("Verbindung zum Scanner unterbrochen (Empfangen).") }
                received += count
            }
        }
        return data
    }
}

/// Ein per UDP-Suche gefundener Scanner.
struct WifiScannerInfo {
    let name: String
    let product: String
    let address: in_addr
    let dataPort: UInt16
    let controlPort: UInt16
    let interfaceVersion: Int
    /// Kennung des Rechners, mit dem der Scanner zuletzt gekoppelt wurde.
    let hostID: Data
    let interface: LocalInterface

    var addressString: String { String(cString: inet_ntoa(address)) }

    /// Werkseitiges WLAN-Passwort: die letzten vier Zeichen der Seriennummer (steckt im Gerätenamen).
    var defaultPassword: String { String(name.suffix(4)) }
}

enum WifiProtocol {
    static let magic = Data("VENS".utf8)
    static let searchPort: UInt16 = 52217

    /// Kopf jedes TCP-Pakets: Länge, Kennung, Befehl, Absender-MAC.
    static func header(command: Int, length: Int, mac: [UInt8]) -> Data {
        var packet = Data(count: 32)
        packet.setBE32(length, at: 0)
        packet.replaceSubrange(4..<8, with: magic)
        packet.setBE32(command, at: 8)
        packet.replaceSubrange(16..<22, with: mac)
        return packet
    }

    /// Such- bzw. Lebenszeichenpaket (UDP). Die Antwort geht an `replyPort`.
    static func searchPacket(interface: LocalInterface, replyPort: UInt16, keepAlive: Bool) -> Data {
        var packet = Data(count: 32)
        packet.replaceSubrange(0..<4, with: magic)
        packet[7] = keepAlive ? 1 : 0
        packet.replaceSubrange(8..<12, with: interface.addressBytes)
        packet.replaceSubrange(12..<18, with: interface.mac)
        packet.setBE32(Int(replyPort), at: 20)
        packet[keepAlive ? 24 : 25] = 0x10
        return packet
    }

    static func parseSearchReply(_ data: Data, interface: LocalInterface) -> WifiScannerInfo? {
        guard data.count >= 132, data.prefix(4) == magic else { return nil }
        var address = in_addr()
        withUnsafeMutableBytes(of: &address.s_addr) { $0.copyBytes(from: data[16..<20]) }
        return WifiScannerInfo(name: data.cString(at: 40, length: 64), product: data.cString(at: 104, length: 16),
                               address: address, dataPort: UInt16(data.be32(20)), controlPort: UInt16(data.be32(24)),
                               interfaceVersion: data.be16(8), hostID: Data(data[124..<132]), interface: interface)
    }

    /// Sucht Scanner in allen lokalen Netzen.
    static func discover(timeout: TimeInterval = 1.5) -> [WifiScannerInfo] {
        var found: [String: WifiScannerInfo] = [:]
        let sockets = LocalInterface.all().compactMap { interface in
            (try? UDPSocket(interface: interface)).map { (interface, $0) }
        }
        let everyone = in_addr(s_addr: INADDR_BROADCAST)
        let deadline = Date().addingTimeInterval(timeout)
        var nextSend = Date.distantPast
        while Date() < deadline {
            if Date() >= nextSend {
                for (interface, socket) in sockets {
                    let packet = searchPacket(interface: interface, replyPort: socket.port, keepAlive: false)
                    socket.send(packet, to: interface.broadcast, port: searchPort)
                    socket.send(packet, to: everyone, port: searchPort)
                }
                nextSend = Date().addingTimeInterval(0.4)
            }
            for (interface, socket) in sockets {
                while let (data, _) = socket.receive(timeout: 0.05) {
                    if let info = parseSearchReply(data, interface: interface) {
                        found[info.addressString] = info
                    }
                }
            }
        }
        return found.values.sorted { $0.name < $1.name }
    }

    /// Verschleierung des Passworts, wie sie der Scanner bei der Reservierung erwartet.
    static func cipher(_ password: String) -> String {
        let key = [123, 81, 128, 126, 78, 76, 89, 126, 89, 108, 123, 81, 116, 91, 113, 128]
        return zip(password.utf8, key).map { String(Int($0) + $1) }.joined()
    }
}
