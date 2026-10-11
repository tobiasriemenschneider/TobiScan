import Foundation

/// `TobiScan --wifi-probe`: sucht Scanner im WLAN und fragt Gerätedaten und Status ab, ohne zu scannen.
enum WifiProbe {
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    /// `TobiScan --wifi-scan <Ordner> [dpi] [auto]`: scannt den Stapel im Einzug über WLAN in einen Ordner.
    static func scan(arguments: [String]) -> Never {
        guard let info = WifiProtocol.discover().first else {
            print("Kein Scanner im WLAN gefunden.")
            exit(1)
        }
        let directory = URL(fileURLWithPath: arguments.first ?? ".", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var settings = ScanSettings()
        settings.resolution = arguments.dropFirst().compactMap { Int($0) }.first ?? 300
        if arguments.contains("auto") { settings.paper = .automatic }
        let job = WifiScanJob(info: info, settings: settings, directory: directory)
        job.log = { print("  " + $0); ScanLog.write($0) }
        if let mode = arguments.first(where: { $0.hasPrefix("mf=") }), let value = UInt8(mode.dropFirst(3), radix: 16) {
            job.parameters.multifeedDetection = value
        }
        do {
            let started = Date()
            let sheets = try job.run()
            print(String(format: "%d Blatt in %.1f s nach %@", sheets, Date().timeIntervalSince(started), directory.path))
            exit(0)
        } catch {
            print("Fehler: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func run() -> Never {
        let scanners = WifiProtocol.discover()
        if scanners.isEmpty {
            print("Kein Scanner im WLAN gefunden.")
            exit(1)
        }
        for info in scanners {
            print("Gefunden: \(info.name) (\(info.product)) \(info.addressString), Ports \(info.dataPort)/\(info.controlPort), "
                + "IF-Version \(info.interfaceVersion), Host-ID \(hex(info.hostID)), über \(info.interface.name)")
            let session = WifiSession(info: info)
            do {
                try session.open()
                print("  Reservierung ok")
                let inquiry = try session.command([0x12, 0, 0, 0, 0x60], dataIn: 0x60)
                print("  Inquiry: Status \(inquiry.status), \(inquiry.data.cString(at: 8, length: 28))")
                let status = try session.command([0xc2, 0, 0, 0, 0, 0, 0, 0, 0x20, 0], dataIn: 0x20)
                print("  Hardwarestatus: \(hex(status.data))")
                print("  Antwortkopf:    \(hex(status.header))")
            } catch {
                print("  Fehler: \(error.localizedDescription)")
            }
            session.close()
            print("  Freigegeben")
        }
        exit(0)
    }
}
