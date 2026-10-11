import Foundation

/// Schreibt den Ablauf von WLAN-Scans nach ~/Library/Logs/TobiScan.log, damit sich Fehler nachvollziehen lassen.
enum ScanLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/TobiScan.log")
    private static let queue = DispatchQueue(label: "TobiScan.log")
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static func write(_ message: String) {
        queue.async {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size > 2_000_000 { try? FileManager.default.removeItem(at: url) }
            let line = Data("\(formatter.string(from: Date())) \(message)\n".utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: url)
            }
        }
    }
}
