import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor private var quitting = false
    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting { return .terminateNow }
        let model = AppModel.shared
        if !model.edits.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Discard unapplied settings?"
            alert.informativeText = "Your saved settings will be kept."
            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Discard Changes")
            if alert.runModal() != .alertSecondButtonReturn { return .terminateCancel }
        }
        if model.running {
            let alert = NSAlert()
            alert.messageText = "Stop streaming and quit?"
            alert.informativeText = "Close your X-Plane flight first. AutoOrtho will unmount its scenery before quitting."
            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Stop and Quit")
            if alert.runModal() != .alertSecondButtonReturn { return .terminateCancel }
        }
        Task { @MainActor in
            let success = await model.shutdown()
            quitting = success
            sender.reply(toApplicationShouldTerminate: success)
            if !success { NSApp.activate(ignoringOtherApps: true) }
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct AutoOrthoNativeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        Window("AutoOrtho", id: "main") {
            RootView().environmentObject(model)
        }
        .defaultSize(width: 1080, height: 760)
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .appInfo) {
                Button("About AutoOrtho") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "AutoOrtho", .applicationVersion: "Native macOS · 0.1",
                        .version: "Patched 3.0.1 streaming engine", .credits: NSAttributedString(string: "Native SwiftUI interface for AutoOrtho.\nhttps://github.com/AustinZhu/autoortho4xplane")
                    ])
                }
            }
            CommandMenu("Navigate") {
                ForEach(Array(Destination.allCases.enumerated()), id: \.element.id) { index, destination in
                    Button(destination.rawValue) { model.destination = destination }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await model.refresh() } }.keyboardShortcut("r", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Link("AutoOrtho Help", destination: URL(string: "https://github.com/AustinZhu/autoortho4xplane")!)
            }
        }
        Settings { NativeSettingsView().environmentObject(model) }
        MenuBarExtra("AutoOrtho", systemImage: "airplane.circle") {
            Text(model.statusTitle)
            Button("Show AutoOrtho") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            SettingsLink { Text("Settings…") }
            Divider()
            Button("Quit AutoOrtho") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
    }
}
