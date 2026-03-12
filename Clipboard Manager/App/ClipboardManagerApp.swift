import SwiftUI

@main
struct ClipboardManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Empty window scene — app is driven by AppDelegate + NSPanel
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
