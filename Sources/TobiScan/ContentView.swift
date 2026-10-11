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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Scanner") {
                    HStack {
                        Picker("Scanner", selection: $model.selectedDeviceID) {
                            if model.devices.isEmpty {
                                Text("Kein Scanner").tag(String?.none)
                            }
                            ForEach(model.devices) { device in
                                Text(device.displayName).tag(String?.some(device.id))
                            }
                        }
                        .labelsHidden()
                        Button {
                            Task { await model.refreshDevices() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Scanner neu suchen")
                        .disabled(model.isBusy)
                    }
                    if let hint = deviceHint {
                        Text(hint)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section("Scan") {
                    Picker("Seiten", selection: $model.settings.duplex) {
                        Text("Einseitig").tag(false)
                        Text("Beidseitig").tag(true)
                    }
                    Picker("Farbe", selection: $model.settings.colorMode) {
                        ForEach(ColorMode.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Auflösung", selection: $model.settings.resolution) {
                        ForEach(ScanSettings.resolutions, id: \.self) { Text("\($0) dpi").tag($0) }
                    }
                    Picker("Papier", selection: $model.settings.paper) {
                        ForEach(PaperSize.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Leere Seiten entfernen", isOn: $model.settings.skipBlankPages)
                    Toggle("Schräglage korrigieren", isOn: $model.settings.deskew)
                    Toggle("Hintergrund aufhellen", isOn: $model.settings.lightenBackground)
                    Toggle("Doppeleinzug erkennen", isOn: $model.settings.detectMultifeed)
                    Toggle("Scan-Taste am Gerät", isOn: $model.settings.scannerButton)
                }

                Section("PDF") {
                    Toggle("Durchsuchbar (Texterkennung)", isOn: $model.settings.ocr)
                    Toggle("Dateinamen vorschlagen (KI)", isOn: $model.settings.suggestFilename)
                }

                Section {
                    Toggle("Virtuelles Testgerät anzeigen", isOn: $model.settings.showTestDevice)
                }
            }
            .formStyle(.grouped)
            .disabled(model.activity == .scanning)

            Divider()
            scanButton
                .padding(16)
        }
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
