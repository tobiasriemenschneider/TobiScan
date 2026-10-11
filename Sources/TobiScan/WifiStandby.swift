import Foundation

/// Hält einen WLAN-Scanner reserviert, solange die App läuft, und meldet Drücke der Scan-Taste am Gerät.
/// Alles, was die Verbindung benutzt (auch der Scan selbst), läuft nacheinander auf einer eigenen Warteschlange.
final class WifiStandby: @unchecked Sendable {
    private let queue = DispatchQueue(label: "TobiScan.wifi-standby")
    private let onButton: () -> Void
    private var info: WifiScannerInfo
    private var session: WifiSession?
    private var stopped = false
    private var nextAttempt = Date.distantPast
    private var lastButton: Int?

    init(info: WifiScannerInfo, onButton: @escaping () -> Void) {
        self.info = info
        self.onButton = onButton
        queue.async { self.poll() }
    }

    private func poll() {
        guard !stopped else { return }
        if session == nil, Date() >= nextAttempt {
            connect()
        }
        if let current = session {
            if !current.isAlive {
                ScanLog.write("Bereitschaft: Scanner antwortet nicht mehr")
                current.close()
                session = nil
                nextAttempt = Date().addingTimeInterval(3)
            } else if let counter = current.waitForButton(timeout: 0.4), counter != lastButton {
                lastButton = counter
                ScanLog.write("Bereitschaft: Scan-Taste gedrückt (\(counter))")
                DispatchQueue.main.async(execute: onButton)
            }
        } else {
            Thread.sleep(forTimeInterval: 0.4)
        }
        queue.async { self.poll() }
    }

    private func connect() {
        let candidate = WifiSession(info: info)
        do {
            try candidate.open()
            session = candidate
            lastButton = nil
            ScanLog.write("Bereitschaft: \(info.name) reserviert")
        } catch {
            // Scanner aus oder mit neuer Adresse im Netz: beim nächsten Versuch frisch suchen.
            nextAttempt = Date().addingTimeInterval(5)
            if let found = WifiProtocol.discover(timeout: 1).first(where: { $0.name == info.name }) {
                info = found
            }
        }
    }

    /// Führt einen Scan über die reservierte Verbindung aus (oder ohne, falls gerade keine besteht).
    func run<T>(_ body: @escaping (WifiSession?) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let current = self.session?.isAlive == true ? self.session : nil
                do {
                    let value = try body(current)
                    // Tastendrücke während des Scans nicht nachträglich als neuen Scan werten.
                    while let counter = current?.waitForButton(timeout: 0) { self.lastButton = counter }
                    continuation.resume(returning: value)
                } catch {
                    if case WifiError.network = error {
                        self.session?.close()
                        self.session = nil
                    }
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Gibt den Scanner frei; kehrt erst zurück, wenn das erledigt ist.
    func stop() {
        queue.sync {
            stopped = true
            session?.close()
            session = nil
        }
    }
}
