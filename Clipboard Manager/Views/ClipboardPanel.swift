import AppKit
import SwiftUI
import SwiftData

class ClipboardPanel: NSPanel {
    private let settings = SettingsManager.shared
    private let frameSaveKey = "ClipboardPanelFrame"

    init(contentRect: NSRect, modelContainer: ModelContainer) {
        // Restore saved size, keep default position
        var rect = contentRect
        if let savedFrame = UserDefaults.standard.string(forKey: "ClipboardPanelFrame") {
            let restored = NSRectFromString(savedFrame)
            if restored.width >= 320 && restored.height >= 400 {
                rect.size = restored.size
            }
        }

        super.init(
            contentRect: rect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        self.level = .floating
        self.hidesOnDeactivate = settings.dismissOnClickOutside
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.isMovableByWindowBackground = true
        self.animationBehavior = .utilityWindow
        self.isReleasedWhenClosed = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.backgroundColor = .clear
        self.isOpaque = false
        self.minSize = NSSize(width: 320, height: 400)
        self.maxSize = NSSize(width: 600, height: 900)

        let hostingView = NSHostingView(
            rootView: ClipboardListView()
                .modelContainer(modelContainer)
        )
        self.contentView = hostingView

        settings.onDismissSettingChanged = { [weak self] in
            self?.hidesOnDeactivate = self?.settings.dismissOnClickOutside ?? true
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(saveFrameOnResize),
            name: NSWindow.didResizeNotification,
            object: self
        )
    }

    @objc private func saveFrameOnResize() {
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: frameSaveKey)
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }

    override func resignKey() {
        super.resignKey()
        if settings.dismissOnClickOutside {
            orderOut(nil)
        }
    }

    func centerOnActiveScreen() {
        let mouseLocation = NSEvent.mouseLocation
        let activeScreen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let screen = activeScreen else { return }

        let screenFrame = screen.visibleFrame
        let panelSize = frame.size
        let x = screenFrame.midX - panelSize.width / 2
        let y = screenFrame.midY - panelSize.height / 2
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
