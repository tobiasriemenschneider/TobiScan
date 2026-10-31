import Foundation

struct ScanDevice: Identifiable, Hashable {
    /// SANE-Gerätename, z. B. `fujitsu:ScanSnap iX500:12345`.
    let id: String
    let vendor: String
    let model: String
    var isWifi = false

    var displayName: String {
        let name = "\(vendor) \(model)".trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? id : name
    }

    var isTestDevice: Bool { id.hasPrefix("test:") }

    /// Art der Verbindung für Statuszeile und Scannerliste.
    var connection: String {
        if isTestDevice { return "Testgerät" }
        return isWifi ? "WLAN" : "USB"
    }
}

/// Die Optionen, die ein Gerät laut `scanimage -A` tatsächlich anbietet.
struct DeviceOptions {
    var names: Set<String> = []
    var choices: [String: [String]] = [:]
    var maxValues: [String: Double] = [:]

    func has(_ name: String) -> Bool { names.contains(name) }

    static func parse(_ text: String) -> DeviceOptions {
        var options = DeviceOptions()
        let line = try! NSRegularExpression(pattern: #"^ {4}(--?[A-Za-z][A-Za-z0-9-]*)(.*?) \[(.*)\]\s*$"#)
        let range = try! NSRegularExpression(pattern: #"(-?[0-9.]+)\.\.(-?[0-9.]+)"#)

        for raw in text.components(separatedBy: .newlines) {
            let ns = raw as NSString
            guard let match = line.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) else { continue }
            let name = ns.substring(with: match.range(at: 1))
            let spec = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            let current = ns.substring(with: match.range(at: 3))
            if current.hasPrefix("inactive") { continue }
            options.names.insert(name)

            let specNS = spec as NSString
            if let r = range.firstMatch(in: spec, range: NSRange(location: 0, length: specNS.length)) {
                options.maxValues[name] = Double(specNS.substring(with: r.range(at: 2)))
            } else if spec.contains("|"), !spec.hasPrefix("[") {
                options.choices[name] = spec.components(separatedBy: "|")
            }
        }
        return options
    }
}

struct ProcessOutput {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum ScannerError: LocalizedError {
    case toolMissing
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .toolMissing:
            return "scanimage wurde nicht gefunden. Bitte im Terminal „brew install sane-backends“ ausführen."
        case .failed(let message):
            return message
        }
    }
}

enum Scanner {
    static var toolURL: URL? {
        ["/opt/homebrew/bin/scanimage", "/usr/local/bin/scanimage"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Eigene dll.conf, damit SANE nur das Fujitsu-Backend lädt und nicht alle Netzwerk-Backends absucht.
    /// Der abschließende Doppelpunkt hängt das Standardverzeichnis an (dort liegt fujitsu.conf).
    static func environment(includeTestDevice: Bool) -> [String: String] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TobiScan-sane", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let backends = includeTestDevice ? "fujitsu\ntest\n" : "fujitsu\n"
        try? backends.write(to: dir.appendingPathComponent("dll.conf"), atomically: true, encoding: .utf8)

        var env = ProcessInfo.processInfo.environment
        env["SANE_CONFIG_DIR"] = dir.path + ":"
        return env
    }

    static func run(_ arguments: [String], includeTestDevice: Bool,
                    started: ((Process) -> Void)? = nil) async throws -> ProcessOutput {
        guard let tool = toolURL else { throw ScannerError.toolMissing }
        let env = environment(includeTestDevice: includeTestDevice)

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let outPipe = Pipe(), errPipe = Pipe()
                process.executableURL = tool
                process.arguments = arguments
                process.environment = env
                process.standardOutput = outPipe
                process.standardError = errPipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: ProcessOutput(status: -1, stdout: "", stderr: error.localizedDescription))
                    return
                }
                started?(process)

                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                continuation.resume(returning: ProcessOutput(
                    status: process.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self)))
            }
        }
    }

    static func listDevices(includeTestDevice: Bool) async throws -> [ScanDevice] {
        let output = try await run(["-f", "%d|%v|%m%n"], includeTestDevice: includeTestDevice)
        return output.stdout.components(separatedBy: .newlines).compactMap { line in
            let parts = line.components(separatedBy: "|")
            guard parts.count >= 3, !parts[0].isEmpty else { return nil }
            return ScanDevice(id: parts[0], vendor: parts[1], model: parts[2])
        }
    }

    static func options(for device: ScanDevice, includeTestDevice: Bool) async throws -> DeviceOptions {
        let output = try await run(["-d", device.id, "-A"], includeTestDevice: includeTestDevice)
        let options = DeviceOptions.parse(output.stdout)
        if options.names.isEmpty {
            throw ScannerError.failed(friendlyMessage(for: output.stderr))
        }
        return options
    }

    static func scanArguments(device: ScanDevice, settings: ScanSettings, options: DeviceOptions,
                              outputPattern: String) -> [String] {
        var args = ["-d", device.id]
        var feedsFromADF = false

        if let sources = options.choices["--source"] {
            let duplexSource = sources.first { $0.localizedCaseInsensitiveContains("duplex") }
            let simplexSource = sources.first { $0.localizedCaseInsensitiveContains("front") }
                ?? sources.first { $0.localizedCaseInsensitiveContains("adf") || $0.localizedCaseInsensitiveContains("feeder") }
            if let source = (settings.duplex ? duplexSource : nil) ?? simplexSource ?? sources.first {
                args += ["--source", source]
                feedsFromADF = ["adf", "feeder", "duplex"].contains { source.localizedCaseInsensitiveContains($0) }
            }
        }

        if let modes = options.choices["--mode"] {
            let wanted: [String]
            switch settings.colorMode {
            case .color: wanted = ["Color"]
            case .gray: wanted = ["Gray"]
            case .blackWhite: wanted = ["Lineart", "Gray"]
            }
            if let mode = wanted.first(where: modes.contains) {
                args += ["--mode", mode]
            }
        }

        if options.has("--resolution") {
            args += ["--resolution", String(settings.resolution)]
        }

        // Papierformat: erst die Blattgröße, dann den Scanbereich darin.
        let size = settings.paper.millimeters ?? (width: 1000, height: 360)
        for (option, value) in [("--page-width", size.width), ("--page-height", size.height),
                                ("-x", size.width), ("-y", size.height)] where options.has(option) {
            let clamped = min(value, options.maxValues[option] ?? value)
            args += [option, String(format: "%.1f", clamped)]
        }
        if settings.paper == .automatic, options.has("--swcrop") {
            args.append("--swcrop=yes")
        }
        if settings.deskew, options.has("--swdeskew") {
            args.append("--swdeskew=yes")
        }
        // Das SANE-Testgerät liefert sonst nur schwarze Seiten.
        if options.has("--test-picture") {
            args += ["--test-picture", "Grid"]
        }

        args += ["--format=tiff", "--batch=\(outputPattern)"]
        if !feedsFromADF {
            args.append("--batch-count=1")
        }
        return args
    }

    static func friendlyMessage(for stderr: String) -> String {
        let table: [(String, String)] = [
            ("out of documents", "Kein Papier im Einzug."),
            ("jammed", "Papierstau – bitte das Papier entfernen und erneut scannen."),
            ("cover is open", "Die Abdeckung des Scanners ist offen."),
            ("Device busy", "Der Scanner ist belegt. Läuft ScanSnap Home noch im Hintergrund?"),
            ("Access to resource has been denied", "Kein Zugriff auf den Scanner. Läuft ScanSnap Home noch im Hintergrund?"),
            ("Error during device I/O", "Verbindung zum Scanner unterbrochen. Bitte USB-Kabel prüfen."),
            ("no SANE devices found", "Kein Scanner gefunden."),
            ("open of device", "Der Scanner konnte nicht geöffnet werden. Ist er eingeschaltet und per USB verbunden?"),
        ]
        for (needle, message) in table where stderr.localizedCaseInsensitiveContains(needle) {
            return message
        }
        let lines = stderr.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.last ?? "Unbekannter Fehler beim Scannen."
    }
}
