import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    enum Activity: Equatable {
        case idle
        case searching
        case scanning
        case naming
        case saving(done: Int, total: Int)
    }

    @Published var settings = ScanSettings.load() {
        didSet {
            settings.save()
            if settings.showTestDevice != oldValue.showTestDevice {
                Task { await refreshDevices() }
            }
            if settings.scannerButton != oldValue.scannerButton { updateStandby() }
        }
    }
    @Published var devices: [ScanDevice] = []
    @Published var selectedDeviceID: String? {
        didSet {
            if selectedDeviceID != oldValue {
                options = nil
                updateStandby()
            }
        }
    }
    @Published var pages: [ScannedPage] = []
    @Published var activity = Activity.idle
    @Published var status = ""
    @Published var errorMessage: String?
    @Published var lastSavedURL: URL?
    @Published var toolMissing = false
    @Published var hasUnsavedPages = false

    private var options: DeviceOptions?
    private var wifiScanners: [String: WifiScannerInfo] = [:]
    private var scanProcess: Process?
    private var wifiJob: WifiScanJob?
    private var standby: WifiStandby?
    private var standbyDeviceID: String?
    private var cancelRequested = false
    private let sessionDirectory: URL

    init() {
        sessionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TobiScan-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
    }

    var selectedDevice: ScanDevice? { devices.first { $0.id == selectedDeviceID } }
    var isBusy: Bool { activity != .idle }
    var canScan: Bool { !isBusy && selectedDevice != nil }
    var canSave: Bool { !isBusy && !pages.isEmpty }

    /// ScanSnap Home hält den Scanner exklusiv geöffnet, solange es (auch nur im Hintergrund) läuft.
    var scanSnapHomeIsRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier?.hasPrefix("com.fujitsu.pfu") == true }
    }

    func cleanUp() {
        standby?.stop()
        standby = nil
        try? FileManager.default.removeItem(at: sessionDirectory)
    }

    /// Für die Scan-Taste am Gerät bleibt der gewählte WLAN-Scanner reserviert, solange die App läuft.
    private func updateStandby() {
        let wanted = settings.scannerButton ? selectedDevice.flatMap { $0.isWifi ? wifiScanners[$0.id] : nil } : nil
        let wantedID = wanted == nil ? nil : selectedDeviceID
        guard wantedID != standbyDeviceID else { return }
        if let old = standby {
            // Freigeben kann bei ausgeschaltetem Scanner einige Sekunden dauern, also nicht im Hauptthread.
            DispatchQueue.global(qos: .utility).async { old.stop() }
        }
        standbyDeviceID = wantedID
        standby = wanted.map { info in
            WifiStandby(info: info) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.canScan else { return }
                    NSApp.activate(ignoringOtherApps: true)
                    Task { await self.scan() }
                }
            }
        }
    }

    // MARK: Geräte

    func refreshDevices() async {
        guard !isBusy else { return }
        activity = .searching
        status = "Suche Scanner …"
        defer { activity = .idle }
        // WLAN und USB parallel absuchen; WLAN funktioniert auch ohne installiertes SANE.
        async let wifiSearch = Task.detached(priority: .userInitiated) { WifiProtocol.discover() }.value
        var found: [ScanDevice] = []
        do {
            found = try await Scanner.listDevices(includeTestDevice: settings.showTestDevice)
            toolMissing = false
        } catch {
            if case ScannerError.toolMissing = error { toolMissing = true }
        }
        let wifi = await wifiSearch
        wifiScanners = Dictionary(uniqueKeysWithValues: wifi.map { ("wifi:" + $0.addressString, $0) })
        found += wifi.map {
            ScanDevice(id: "wifi:" + $0.addressString, vendor: "", model: $0.name, isWifi: true)
        }
        devices = found
        if selectedDevice == nil {
            selectedDeviceID = (devices.first { !$0.isTestDevice } ?? devices.first)?.id
        }
        updateStandby()
        status = devices.isEmpty ? "Kein Scanner gefunden" : "Bereit"
    }

    // MARK: Scannen

    func scan() async {
        guard canScan, let device = selectedDevice else { return }
        activity = .scanning
        status = "Scanne …"
        errorMessage = nil
        lastSavedURL = nil
        cancelRequested = false
        defer {
            activity = .idle
            scanProcess = nil
        }

        let incoming = sessionDirectory.appendingPathComponent("incoming-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: incoming) }

        let scanSettings = settings
        let countBefore = pages.count
        var blankCount = 0
        // Meldung des Scanners, falls der Lauf nicht sauber zu Ende ging.
        var failure: String?
        // Erklärung, falls gar keine Seite herauskam.
        var emptyReason: String?

        // Fertige Seiten schon während des Scans einlesen. Die jeweils neueste Datei
        // bleibt liegen, bis der Scanner sie sicher zu Ende geschrieben hat.
        let ingestTask = Task {
            while !Task.isCancelled {
                blankCount += await self.ingest(from: incoming, settings: scanSettings, includeNewest: false)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        do {
            if device.isWifi {
                guard let info = wifiScanners[device.id] else {
                    throw ScannerError.failed("Der Scanner wurde im WLAN nicht mehr gefunden. Bitte neu suchen.")
                }
                let job = WifiScanJob(info: info, settings: scanSettings, directory: incoming)
                wifiJob = job
                defer { wifiJob = nil }
                if let standby {
                    _ = try await standby.run { session in try job.run(session: session) }
                } else {
                    try await Task.detached(priority: .userInitiated) { _ = try job.run() }.value
                }
            } else {
                let deviceOptions: DeviceOptions
                if let cached = options {
                    deviceOptions = cached
                } else {
                    deviceOptions = try await Scanner.options(for: device, includeTestDevice: scanSettings.showTestDevice)
                    options = deviceOptions
                }
                let arguments = Scanner.scanArguments(device: device, settings: scanSettings, options: deviceOptions,
                                                      outputPattern: incoming.appendingPathComponent("p%05d.tif").path)
                let output = try await Scanner.run(arguments, includeTestDevice: scanSettings.showTestDevice) { process in
                    Task { @MainActor in
                        self.scanProcess = process
                        if self.cancelRequested { process.interrupt() }
                    }
                }
                // scanimage endet auch bei leerem Einzug oder Stau regulär; die Ursache steht in der Ausgabe.
                emptyReason = Scanner.friendlyMessage(for: output.stderr)
                if output.stderr.localizedCaseInsensitiveContains("jammed") { failure = emptyReason }
            }
        } catch {
            failure = error.localizedDescription
        }
        ingestTask.cancel()
        await ingestTask.value
        blankCount += await ingest(from: incoming, settings: scanSettings, includeNewest: true)

        let added = pages.count - countBefore
        if added > 0 { hasUnsavedPages = true }
        if added == 0 && blankCount == 0 {
            if !cancelRequested { errorMessage = failure ?? emptyReason ?? "Es wurden keine Seiten gescannt." }
            status = "Bereit"
        } else {
            var parts = [added == 1 ? "1 Seite gescannt" : "\(added) Seiten gescannt"]
            if blankCount > 0 {
                parts.append(blankCount == 1 ? "1 leere Seite entfernt" : "\(blankCount) leere Seiten entfernt")
            }
            if cancelRequested { parts.append("abgebrochen") }
            status = parts.joined(separator: " · ")
            // Ein Fehler mitten im Stapel soll nicht untergehen, nur weil schon Seiten da sind.
            if !cancelRequested { errorMessage = failure }
        }
    }

    func cancelScan() {
        cancelRequested = true
        scanProcess?.interrupt()
        wifiJob?.cancel()
    }

    /// Liest neue TIFFs ein und gibt die Zahl der verworfenen leeren Seiten zurück.
    private func ingest(from directory: URL, settings: ScanSettings, includeNewest: Bool) async -> Int {
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["tif", "jpg"].contains($0.pathExtension) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let ready = includeNewest ? files : Array(files.dropLast())
        let pagesDirectory = sessionDirectory

        var blank = 0
        for file in ready {
            let result = await Task.detached(priority: .userInitiated) {
                PageImporter.importScan(at: file, into: pagesDirectory, dpi: settings.resolution,
                                        skipBlank: settings.skipBlankPages, colorMode: settings.colorMode,
                                        deskew: settings.deskew, lighten: settings.lightenBackground)
            }.value
            switch result {
            case .page(let page): pages.append(page)
            case .blank: blank += 1
            case .unreadable: break
            }
            try? FileManager.default.removeItem(at: file)
        }
        return blank
    }

    // MARK: Seiten bearbeiten

    func rotate(_ page: ScannedPage, by degrees: Int) {
        guard let index = pages.firstIndex(where: { $0.id == page.id }) else { return }
        pages[index].rotation = (pages[index].rotation + degrees + 360) % 360
        hasUnsavedPages = true
    }

    func move(_ page: ScannedPage, by offset: Int) {
        guard let index = pages.firstIndex(where: { $0.id == page.id }) else { return }
        let target = index + offset
        guard pages.indices.contains(target) else { return }
        pages.swapAt(index, target)
        hasUnsavedPages = true
    }

    func delete(_ page: ScannedPage) {
        guard let index = pages.firstIndex(where: { $0.id == page.id }) else { return }
        try? FileManager.default.removeItem(at: pages[index].fileURL)
        pages.remove(at: index)
        hasUnsavedPages = !pages.isEmpty
    }

    func newDocument() {
        guard !isBusy else { return }
        if hasUnsavedPages {
            let alert = NSAlert()
            alert.messageText = "Ungespeicherte Seiten verwerfen?"
            alert.informativeText = pages.count == 1
                ? "Die gescannte Seite wurde noch nicht gespeichert."
                : "Die \(pages.count) gescannten Seiten wurden noch nicht gespeichert."
            alert.addButton(withTitle: "Verwerfen")
            alert.addButton(withTitle: "Abbrechen")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        for page in pages {
            try? FileManager.default.removeItem(at: page.fileURL)
        }
        pages = []
        hasUnsavedPages = false
        lastSavedURL = nil
        errorMessage = nil
        status = "Bereit"
    }

    // MARK: Speichern

    func save() async {
        guard canSave else { return }
        var suggestion: String?
        if settings.suggestFilename {
            activity = .naming
            status = "Dateiname wird vorgeschlagen …"
            suggestion = await FilenameSuggester.suggest(for: pages)
            activity = .idle
            status = "Bereit"
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        panel.nameFieldStringValue = (suggestion ?? "Scan \(formatter.string(from: Date()))") + ".pdf"
        if let folder = UserDefaults.standard.string(forKey: "lastSaveFolder") {
            panel.directoryURL = URL(fileURLWithPath: folder, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "lastSaveFolder")

        let snapshot = pages
        let ocr = settings.ocr
        activity = .saving(done: 0, total: snapshot.count)
        status = ocr ? "Texterkennung und Speichern …" : "Speichern …"
        errorMessage = nil
        defer { activity = .idle }

        do {
            try await Task.detached(priority: .userInitiated) { [weak self] in
                try PDFExporter.export(snapshot, to: url, ocr: ocr) { done in
                    Task { @MainActor [weak self] in
                        // Verspätete Meldungen dürfen den Zustand nach dem Ende nicht zurücksetzen.
                        guard let self, case .saving = self.activity else { return }
                        self.activity = .saving(done: done, total: snapshot.count)
                    }
                }
            }.value
            lastSavedURL = url
            hasUnsavedPages = false
            status = "Gespeichert: \(url.lastPathComponent)"
        } catch {
            errorMessage = error.localizedDescription
            status = "Speichern fehlgeschlagen"
        }
    }

    func revealSavedFile() {
        if let url = lastSavedURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
