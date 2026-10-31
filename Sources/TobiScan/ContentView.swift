import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            SettingsPanel()
                .frame(width: 260)
            Divider()
            VStack(spacing: 0) {
                PagesView()
                Divider()
                StatusBar()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.newDocument()
                } label: {
                    Label("Neu", systemImage: "doc.badge.plus")
                }
                .help("Alle Seiten verwerfen und neu beginnen")
                .disabled(model.isBusy || model.pages.isEmpty)

                Button {
                    Task { await model.save() }
                } label: {
                    Label("Als PDF speichern", systemImage: "square.and.arrow.down")
                }
                .help("Alle Seiten als PDF speichern")
                .disabled(!model.canSave)
            }
        }
    }
}

// MARK: - Einstellungen

private struct SettingsPanel: View {
    @EnvironmentObject private var model: AppModel
    // Als Typ statt `@AppStorage`, aus demselben Grund wie bei `PageCell.hovering`.
    private let postProcessingExpanded = AppStorage(wrappedValue: false, "sidebarPostProcessingExpanded")

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Scanner") {
                    ScannerCard(hint: deviceHint)
                }

                Section("Scan") {
                    segmentedRow("Seiten") {
                        Picker("Seiten", selection: $model.settings.duplex) {
                            Text("Einseitig").tag(false)
                            Text("Beidseitig").tag(true)
                        }
                    }
                    segmentedRow("Farbe") {
                        Picker("Farbe", selection: $model.settings.colorMode) {
                            ForEach(ColorMode.allCases) { mode in
                                Text(mode.shortTitle)
                                    .accessibilityLabel(mode.title)
                                    .tag(mode)
                            }
                        }
                    }
                    Picker("Auflösung", selection: $model.settings.resolution) {
                        ForEach(ScanSettings.resolutions, id: \.self) { Text("\($0) dpi").tag($0) }
                    }
                    Picker("Papier", selection: $model.settings.paper) {
                        ForEach(PaperSize.allCases) { Text($0.title).tag($0) }
                    }
                }

                Section {
                    DisclosureGroup(isExpanded: postProcessingExpanded.projectedValue) {
                        Toggle("Leere Seiten entfernen", isOn: $model.settings.skipBlankPages)
                        Toggle("Schräglage korrigieren", isOn: $model.settings.deskew)
                        Toggle("Hintergrund aufhellen", isOn: $model.settings.lightenBackground)
                        Toggle("Doppeleinzug erkennen", isOn: $model.settings.detectMultifeed)
                        Toggle("Scan-Taste am Gerät", isOn: $model.settings.scannerButton)
                        Toggle("Durchsuchbar (Texterkennung)", isOn: $model.settings.ocr)
                        Toggle("Dateinamen vorschlagen (KI)", isOn: $model.settings.suggestFilename)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Nachbearbeitung & PDF")
                            Text("\(model.settings.activePostProcessingCount) von \(ScanSettings.postProcessingOptions.count) Optionen aktiv")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(model.activity == .scanning)

            Divider()
            VStack(spacing: 6) {
                scanButton
                Text(scanHint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
        }
    }

    private func segmentedRow<Content: View>(_ title: String, @ViewBuilder picker: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            picker()
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var scanButton: some View {
        if model.activity == .scanning {
            Button(role: .cancel) {
                model.cancelScan()
            } label: {
                Text("Abbrechen").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        } else {
            Button {
                Task { await model.scan() }
            } label: {
                Label(model.pages.isEmpty ? "Scannen" : "Weitere Seiten scannen", systemImage: "scanner")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canScan)
        }
    }

    /// Die Scan-Taste am Gerät funktioniert nur bei WLAN-Scannern (siehe `AppModel.updateStandby`).
    private var scanHint: String {
        model.settings.scannerButton && model.selectedDevice?.isWifi == true ? "⌘R · oder Scan-Taste am Gerät" : "⌘R"
    }

    private var deviceHint: String? {
        guard model.devices.isEmpty, model.activity != .searching else { return nil }
        if model.toolMissing {
            return "Kein Scanner im WLAN gefunden. Für USB fehlt SANE: im Terminal „brew install sane-backends“ ausführen."
        }
        if model.scanSnapHomeIsRunning {
            return "ScanSnap Home läuft noch und blockiert den Scanner. Bitte ganz beenden (auch das Symbol in der Menüleiste) und neu suchen."
        }
        return "Den iX500 einschalten (Klappe öffnen), ins WLAN bringen oder per USB anschließen und neu suchen."
    }
}

private struct ScannerCard: View {
    @EnvironmentObject private var model: AppModel
    let hint: String?

    private var device: ScanDevice? { model.selectedDevice }
    private var searching: Bool { model.activity == .searching }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "scanner")
                    .font(.system(size: 17))
                    .foregroundStyle(device == nil ? Color.secondary : Color.primary)
                    .frame(width: 34, height: 34)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .fontWeight(.semibold)
                        .foregroundStyle(device == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .help(device?.displayName ?? "")
                    HStack(spacing: 5) {
                        if searching {
                            ProgressView().controlSize(.mini)
                        } else {
                            Circle()
                                .fill(device == nil ? Color.secondary.opacity(0.5) : Color.green)
                                .frame(width: 7, height: 7)
                                .accessibilityHidden(true)
                        }
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
                if hint == nil {
                    Button {
                        Task { await model.refreshDevices() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Scanner neu suchen")
                    .accessibilityLabel("Scanner neu suchen")
                    .disabled(model.isBusy)
                }
            }

            if model.devices.count > 1 {
                Picker("Scanner", selection: $model.selectedDeviceID) {
                    ForEach(model.devices) { device in
                        Text(device.displayName).tag(String?.some(device.id))
                    }
                }
                .labelsHidden()
                .disabled(model.isBusy)
            }

            if let hint {
                Text(hint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Task { await model.refreshDevices() }
                } label: {
                    Label("Neu suchen", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .disabled(model.isBusy)
            }
        }
        .padding(.vertical, 2)
    }

    private var title: String {
        if let device { return device.shortName }
        return searching ? "Suche Scanner …" : "Kein Scanner"
    }

    private var subtitle: String {
        guard let device else { return searching ? "WLAN und USB" : "Nicht gefunden" }
        let state: String
        switch model.activity {
        case .scanning: state = "Scannt …"
        case .searching: state = "Suche …"
        default: state = "Bereit"
        }
        return "\(device.connection) · \(state)"
    }
}

private extension ScanDevice {
    var isTestDevice: Bool { id.hasPrefix("test:") }

    /// Name ohne den Zusatz „(WLAN)“, den die Verbindungszeile schon zeigt.
    var shortName: String {
        isWifi ? displayName.replacingOccurrences(of: " (WLAN)", with: "") : displayName
    }

    var connection: String {
        if isTestDevice { return "Testgerät" }
        return isWifi ? "WLAN" : "USB"
    }
}

// MARK: - Seiten

private struct PagesView: View {
    @EnvironmentObject private var model: AppModel
    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 230), spacing: 20)]

    var body: some View {
        Group {
            if model.pages.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: model.activity == .scanning ? "scanner.fill" : "doc.viewfinder")
                        .font(.system(size: 52, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(model.activity == .scanning ? "Scanne …" : "Noch keine Seiten")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    if model.activity != .scanning {
                        Text("Papier einlegen und auf „Scannen“ klicken.")
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(Array(model.pages.enumerated()), id: \.element.id) { index, page in
                                PageCell(page: page, number: index + 1, count: model.pages.count)
                                    .id(page.id)
                            }
                        }
                        .padding(20)
                    }
                    .onChange(of: model.pages.count) { _ in
                        if model.activity == .scanning, let last = model.pages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

private struct PageCell: View {
    @EnvironmentObject private var model: AppModel
    let page: ScannedPage
    let number: Int
    let count: Int
    // Als Typ statt `@State`: Das Makro-Plugin fehlt ohne Xcode in den Command Line Tools.
    private let hovering = State(initialValue: false)

    var body: some View {
        VStack(spacing: 6) {
            Image(decorative: page.thumbnail, scale: 1, orientation: orientation)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(height: 230)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                .overlay(alignment: .bottom) {
                    if hovering.wrappedValue && !model.isBusy {
                        HStack(spacing: 2) {
                            cellButton("rotate.left", "Nach links drehen") { model.rotate(page, by: -90) }
                            cellButton("rotate.right", "Nach rechts drehen") { model.rotate(page, by: 90) }
                            cellButton("trash", "Seite löschen") { model.delete(page) }
                        }
                        .padding(4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 8)
                    }
                }
            Text("\(number)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering.wrappedValue = $0 }
        .contextMenu {
            Button("Nach links drehen") { model.rotate(page, by: -90) }
            Button("Nach rechts drehen") { model.rotate(page, by: 90) }
            Divider()
            Button("Nach vorne schieben") { model.move(page, by: -1) }
                .disabled(number == 1)
            Button("Nach hinten schieben") { model.move(page, by: 1) }
                .disabled(number == count)
            Divider()
            Button("Seite löschen", role: .destructive) { model.delete(page) }
        }
    }

    private var orientation: Image.Orientation {
        switch page.rotation {
        case 90: return .right
        case 180: return .down
        case 270: return .left
        default: return .up
        }
    }

    private func cellButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 24, height: 22)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

// MARK: - Statuszeile

private struct StatusBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            if let error = model.errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(error)
                    .lineLimit(2)
            } else {
                if case .saving(let done, let total) = model.activity {
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                        .frame(width: 120)
                } else if model.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(model.status)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if model.lastSavedURL != nil, !model.isBusy {
                    Button("Im Finder zeigen") { model.revealSavedFile() }
                        .buttonStyle(.link)
                }
            }
            Spacer()
            if !model.pages.isEmpty {
                Text(model.pages.count == 1 ? "1 Seite" : "\(model.pages.count) Seiten")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .frame(height: 34)
    }
}
