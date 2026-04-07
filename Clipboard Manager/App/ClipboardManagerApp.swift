import SwiftUI

@main
struct ClipboardManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Minimal window scene — immediately hidden, app is driven by AppDelegate + NSPanel
        Window("", id: "hidden") {
            EmptyView()
        }
        .defaultSize(width: 0, height: 0)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    AppDelegate.shared?.openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
