import Foundation
import Vision
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Schlägt aus dem Inhalt der ersten Seiten einen Dateinamen vor: `JJJJ-MM-TT_Absender-Inhalt`.
/// Die Auswertung macht das Sprachmodell von macOS auf dem Rechner; es verlässt kein Text den Mac.
enum FilenameSuggester {
    static func suggest(for pages: [ScannedPage]) async -> String? {
        let text = await Task.detached(priority: .userInitiated) { recognizedText(of: pages.prefix(2)) }.value
        guard text.count > 40 else { return nil }
        // Das Modell darf den Speichern-Dialog nicht beliebig lange aufhalten.
        return await withTaskGroup(of: String?.self) { group in
            group.addTask { await askModel(String(text.prefix(2500))).flatMap { assemble($0, documentText: text, today: Date()) } }
            group.addTask {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func recognizedText(of pages: ArraySlice<ScannedPage>) -> String {
        pages.compactMap { page -> String? in
            guard let image = page.loadImage() else { return nil }
            return PDFExporter.recognizeText(in: image, orientation: page.orientation)
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private static func askModel(_ text: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else { return nil }
            let session = LanguageModelSession(instructions: """
                Du benennst gescannte Dokumente. Antworte mit genau drei Zeilen und nichts sonst:
                DATUM: das Datum des Dokuments im Format JJJJ-MM-TT (nicht Geburtsdaten oder Fristen); wenn keins erkennbar ist: unbekannt
                ABSENDER: die Firma oder Behörde, von der das Dokument stammt, kurz (1 bis 3 Wörter)
                INHALT: worum es geht, kurz (1 bis 4 Wörter), z. B. Rechnung Strom, Bescheid Kindergeld, Kontoauszug
                """)
            return try? await session.respond(to: "Text des Dokuments:\n\n" + text).content
        }
        #endif
        return nil
    }

    /// Baut aus der Antwort des Modells den Dateinamen; fehlt ein gültiges Datum, gilt das heutige.
    static func assemble(_ answer: String, documentText: String, today: Date) -> String? {
        var fields: [String: String] = [:]
        for line in answer.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).uppercased()
            fields[key] = clean(String(line[line.index(after: colon)...]))
        }
        let sender = fields["ABSENDER"].flatMap { isMissing($0) ? nil : $0 }
        let subject = fields["INHALT"].flatMap { isMissing($0) ? nil : $0 }
        let description = [sender, subject].compactMap { $0 }.joined(separator: "-")
        guard !description.isEmpty else { return nil }
        return "\(validDate(fields["DATUM"], in: documentText, today: today))_\(description)"
    }

    private static func isMissing(_ value: String) -> Bool {
        value.isEmpty || ["unbekannt", "unknown", "-", "keine", "n/a"].contains(value.lowercased())
    }

    private static func clean(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|_").union(.newlines).union(.controlCharacters)
        let parts = value.components(separatedBy: forbidden).joined(separator: " ")
            .split(separator: " ").joined(separator: " ")
        return String(parts.trimmingCharacters(in: CharacterSet(charactersIn: " .-")).prefix(40))
            .trimmingCharacters(in: .whitespaces)
    }

    private typealias Day = (year: Int, month: Int, day: Int)

    /// Alle Datumsangaben in einem Text, deutsch (TT.MM.JJJJ) oder ISO (JJJJ-MM-TT).
    private static func days(in text: String) -> [Day] {
        var found: [Day] = []
        let patterns = [(#"(?<!\d)(\d{1,2})\.\s?(\d{1,2})\.\s?(\d{4})(?!\d)"#, [3, 2, 1]), (#"(?<!\d)(\d{4})-(\d{2})-(\d{2})(?!\d)"#, [1, 2, 3])]
        for (pattern, order) in patterns {
            let expression = try! NSRegularExpression(pattern: pattern)
            let source = text as NSString
            for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
                let parts = order.map { Int(source.substring(with: match.range(at: $0))) ?? 0 }
                found.append((parts[0], parts[1], parts[2]))
            }
        }
        return found
    }

    /// Das Modell verrutscht gelegentlich bei Ziffern. Deshalb zählt sein Datum nur, wenn es so im Dokument
    /// steht; stimmen nur Tag und Monat, gilt das Datum aus dem Dokument. Sonst das heutige.
    private static func validDate(_ value: String?, in text: String, today: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.dateComponents([.year, .month, .day], from: today)
        func format(_ day: Day) -> String { String(format: "%04d-%02d-%02d", day.year, day.month, day.day) }
        func plausible(_ day: Day) -> Bool {
            (1950...(now.year ?? 0) + 1).contains(day.year)
                && calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day))
                    .map { calendar.component(.day, from: $0) == day.day && calendar.component(.month, from: $0) == day.month } == true
        }
        let inDocument = days(in: text).filter(plausible)
        if let proposed = days(in: value ?? "").first {
            if let exact = inDocument.first(where: { $0 == proposed }) { return format(exact) }
            if let sameDay = inDocument.first(where: { $0.month == proposed.month && $0.day == proposed.day }) { return format(sameDay) }
        }
        return format((now.year ?? 0, now.month ?? 1, now.day ?? 1))
    }
}
