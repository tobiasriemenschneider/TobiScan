import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ohne Xcode-Projekt startet die App sonst nicht zuverlässig als normale Vordergrund-App.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let model, model.hasUnsavedPages else { return .terminateNow }
            let alert = NSAlert()
            alert.messageText = "TobiScan beenden?"
            alert.informativeText = "Es gibt gescannte Seiten, die noch nicht gespeichert wurden."
            alert.addButton(withTitle: "Beenden")
            alert.addButton(withTitle: "Abbrechen")
            return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            model?.cancelScan()
            model?.cleanUp()
        }
    }
}

struct TobiScanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("TobiScan", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 520)
                .onAppear { delegate.model = model }
                .task { await model.refreshDevices() }
        }
        .defaultSize(width: 1040, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Neues Dokument") { model.newDocument() }
                    .keyboardShortcut("n")
                    .disabled(model.isBusy || model.pages.isEmpty)
                Divider()
                Button("Scannen") { Task { await model.scan() } }
                    .keyboardShortcut("r")
                    .disabled(!model.canScan)
                Button("Als PDF speichern …") { Task { await model.save() } }
                    .keyboardShortcut("s")
                    .disabled(!model.canSave)
            }
        }
    }
}
