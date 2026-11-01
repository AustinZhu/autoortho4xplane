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
        if (model.running || model.stranded) && model.xplaneRunning {
            let alert = NSAlert()
            alert.messageText = "Stop streaming and quit while X-Plane is open?"
            alert.informativeText = "Quitting unmounts the scenery your flight is using. End the flight first, or quit anyway."
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

/// The single Start/Stop command, shared by the Streaming menu and the menu bar extra.
struct StreamingCommandButton: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Button(model.stranded ? "Clean Up Scenery" : model.running ? "Stop Streaming" : "Start Streaming") { model.toggleStreaming() }
            .disabled(model.stranded ? model.busy : model.running ? !model.canStop : !model.canStart)
    }
}

@main
struct AutoOrthoApp: App {
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
                        .applicationName: "AutoOrtho", .applicationVersion: "0.1.0",
                        .version: "Streaming engine 3.0.1", .credits: NSAttributedString(string: "AutoOrtho for macOS.\nhttps://github.com/AustinZhu/autoortho4xplane")
                    ])
                }
            }
            CommandMenu("Streaming") {
                StreamingCommandButton(model: model).keyboardShortcut(.return, modifiers: .command)
                Divider()
                Button("Refresh Status") { Task { await model.refresh() } }.keyboardShortcut("r", modifiers: .command)
            }
            CommandGroup(before: .sidebar) {
                ForEach(Array(Destination.allCases.enumerated()), id: \.element.id) { index, destination in
                    Button(destination.rawValue) { openWindow(id: "main"); model.destination = destination }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
                Divider()
            }
            CommandGroup(replacing: .help) {
                Link("AutoOrtho Help", destination: URL(string: "https://github.com/AustinZhu/autoortho4xplane")!)
            }
        }
        Settings { NativeSettingsView().environmentObject(model) }
        MenuBarExtra {
            Text(model.statusTitle)
            Text(model.mountSummary)
            if !model.running, let blocker = model.startBlocker { Text(blocker.message) }
            Divider()
            StreamingCommandButton(model: model)
            Divider()
            Button("Show AutoOrtho") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            SettingsLink { Text("Settings…") }
            Divider()
            Button("Quit AutoOrtho") { NSApp.terminate(nil) }.keyboardShortcut("q")
        } label: {
            Image(systemName: model.running ? "airplane.circle.fill" : "airplane.circle")
                .accessibilityLabel(model.statusTitle)
        }
    }
}
