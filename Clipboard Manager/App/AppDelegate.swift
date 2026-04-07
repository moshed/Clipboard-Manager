import AppKit
import SwiftUI
import SwiftData

private func debugLog(_ message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "\(ts): \(message)\n"
    let path = "/tmp/clipboard-manager-debug.log"
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
    }
}

class SnippetPasteData: NSObject {
    let content: String
    let rtfData: Data?
    let matchDestinationFont: Bool
    init(content: String, rtfData: Data?, matchDestinationFont: Bool = true) {
        self.content = content
        self.rtfData = rtfData
        self.matchDestinationFont = matchDestinationFont
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var shared: AppDelegate?

    private var statusItem: NSStatusItem!
    private var panel: ClipboardPanel?
    private var settingsWindow: NSWindow?
    private(set) var clipboardMonitor: ClipboardMonitor?
    private var hotkeyManager: HotkeyManager?
    private var modelContainer: ModelContainer!
    private(set) var previousApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        setupModelContainer()
        setupStatusItem()
        setupPanel()
        setupMonitor()
        setupHotkey()
        setupSnippetHotkeys()
        trackFrontmostApp()

        // Preload SF Symbols catalog on background thread
        DispatchQueue.global(qos: .utility).async {
            SFSymbolLoader.shared.load()
        }

        NotificationCenter.default.addObserver(forName: .snippetHotkeysChanged, object: nil, queue: .main) { [weak self] _ in
            self?.setupSnippetHotkeys()
        }
    }

    private func setupModelContainer() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let storeDir = appSupport.appendingPathComponent("ClipboardManager", isDirectory: true)
        try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let storeURL = storeDir.appendingPathComponent("ClipboardHistory.store")

        let config = ModelConfiguration(url: storeURL)
        do {
            modelContainer = try ModelContainer(for: ClipboardEntry.self, SavedSnippet.self, configurations: config)
        } catch {
            // Migration failed — delete store files and retry
            let fm = FileManager.default
            for ext in ["", "-wal", "-shm"] {
                try? fm.removeItem(at: storeURL.appendingPathExtension(ext.isEmpty ? "" : String(ext.dropFirst())))
                if ext.isEmpty {
                    try? fm.removeItem(at: storeURL)
                }
            }
            // Also remove any .store-wal / .store-shm variants
            let dir = storeURL.deletingLastPathComponent()
            if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for file in files where file.lastPathComponent.hasPrefix("ClipboardHistory.store") {
                    try? fm.removeItem(at: file)
                }
            }
            do {
                modelContainer = try ModelContainer(for: ClipboardEntry.self, SavedSnippet.self, configurations: config)
            } catch {
                fatalError("Failed to create ModelContainer after reset: \(error)")
            }
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clipboard Manager")
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func setupPanel() {
        let panelWidth: CGFloat = 420
        let panelHeight: CGFloat = 520
        let panelRect = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        panel = ClipboardPanel(contentRect: panelRect, modelContainer: modelContainer)
    }

    private func setupMonitor() {
        clipboardMonitor = ClipboardMonitor(modelContainer: modelContainer)
        clipboardMonitor?.start()
    }

    private func setupHotkey() {
        hotkeyManager = HotkeyManager { [weak self] in
            self?.togglePanelCentered()
        }
    }

    @objc func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent!
        if event.type == .rightMouseUp {
            showStatusMenu()
        } else {
            togglePanelFromStatusItem()
        }
    }

    private func showStatusMenu() {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Relaunch", action: #selector(relaunchApp), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Quit Clipboard Manager", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc func openSettings() {
        openSettingsWindow()
    }

    func openSettingsWindow() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.setActivationPolicy(.regular)
            return
        }

        let settingsView = ScrollView {
            SettingsView(onClearAll: { [weak self] in
                guard let container = self?.modelContainer else { return }
                let context = ModelContext(container)
                let descriptor = FetchDescriptor<ClipboardEntry>()
                if let entries = try? context.fetch(descriptor) {
                    for entry in entries { context.delete(entry) }
                    try? context.save()
                }
            })
        }
        .frame(minWidth: 420, idealWidth: 480, minHeight: 500, idealHeight: 600)
        .modelContainer(modelContainer)

        let hostingView = NSHostingView(rootView: settingsView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Clipboard Manager Settings"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Show dock icon while settings is open
        NSApp.setActivationPolicy(.regular)

        settingsWindow = window

        // Hide the SwiftUI-managed empty window that reappears when activation policy changes
        DispatchQueue.main.async { [weak self] in
            for w in NSApp.windows {
                if w !== self?.settingsWindow && w !== self?.panel && w.className.contains("AppKitWindow") {
                    w.orderOut(nil)
                }
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === settingsWindow {
            sender.orderOut(nil)
            settingsWindow = nil
            NSApp.setActivationPolicy(.accessory)
            return false  // Don't actually close — just hide, so app doesn't quit
        }
        return true
    }

    @objc private func relaunchApp() {
        let url = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", url.path]
        try? task.run()
        NSApp.terminate(nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // Triggered by global hotkey - center on active screen
    @objc func togglePanelCentered() {
        guard let panel = panel else { return }

        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            previousApp = NSWorkspace.shared.frontmostApplication

            panel.centerOnActiveScreen()
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .panelDidOpen, object: nil)
        }
    }

    // Triggered by clicking the status item - position below it
    private func togglePanelFromStatusItem() {
        guard let panel = panel else { return }

        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            previousApp = NSWorkspace.shared.frontmostApplication

            positionPanelBelowStatusItem()
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .panelDidOpen, object: nil)
        }
    }

    /// Dismiss panel, switch to previous app, and simulate Cmd+V to paste
    func pasteIntoPreviousApp() {
        debugLog("pasteIntoPreviousApp called")
        guard let panel = panel else {
            debugLog("paste: panel is nil, aborting")
            return
        }
        panel.orderOut(nil)

        guard let prevApp = previousApp else {
            debugLog("paste: previousApp is nil, aborting")
            return
        }
        debugLog("paste: activating \(prevApp.localizedName ?? "?") pid=\(prevApp.processIdentifier)")
        prevApp.activate()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            let source = CGEventSource(stateID: .combinedSessionState)
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
            keyDown?.flags = .maskCommand
            keyUp?.flags = .maskCommand
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
            debugLog("paste: Cmd+V posted, keyDown=\(keyDown != nil ? "ok" : "nil"), keyUp=\(keyUp != nil ? "ok" : "nil")")
        }
    }

    private func setupSnippetHotkeys() {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<SavedSnippet>()
        guard let snippets = try? context.fetch(descriptor) else { return }

        let combos: [(id: UUID, combo: KeyCombo)] = snippets.compactMap { snippet in
            guard let combo = snippet.keyCombo else { return nil }
            return (id: snippet.id, combo: combo)
        }

        hotkeyManager?.registerSnippetHotkeys(snippets: combos) { [weak self] snippetID in
            self?.pasteSnippet(id: snippetID)
        }
    }

    private func pasteSnippet(id: UUID) {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<SavedSnippet>(
            predicate: #Predicate<SavedSnippet> { $0.id == id }
        )
        guard let snippet = try? context.fetch(descriptor).first else { return }

        // If this is a folder, show a context menu of its children
        if snippet.isFolder {
            showFolderMenu(folderID: snippet.id, context: context)
            return
        }

        pasteSnippetContent(snippet.content, rtfData: snippet.rtfData, matchDestinationFont: snippet.matchDestinationFont)
    }

    private func showFolderMenu(folderID: UUID, context: ModelContext) {
        var allDescriptor = FetchDescriptor<SavedSnippet>()
        allDescriptor.sortBy = [SortDescriptor(\SavedSnippet.order)]
        guard let allSnippets = try? context.fetch(allDescriptor) else { return }
        let children = allSnippets.filter { $0.folderID == folderID && !$0.isFolder }
        guard !children.isEmpty else { return }

        DispatchQueue.main.async { [weak self] in
            let menu = NSMenu()
            for child in children {
                let title = child.title.isEmpty ? String(child.content.prefix(40)) : child.title
                let item = NSMenuItem(title: title, action: #selector(self?.folderMenuItemClicked(_:)), keyEquivalent: "")
                item.target = self
                // Store both content and rtfData
                item.representedObject = SnippetPasteData(content: child.content, rtfData: child.rtfData, matchDestinationFont: child.matchDestinationFont)
                if let iconName = child.iconName, let img = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) {
                    img.isTemplate = true
                    item.image = img
                }
                menu.addItem(item)
            }

            // Show menu at mouse location using a temporary window
            let mouseLocation = NSEvent.mouseLocation
            let menuWindow = NSWindow(contentRect: NSRect(x: mouseLocation.x, y: mouseLocation.y, width: 1, height: 1),
                                      styleMask: .borderless, backing: .buffered, defer: false)
            menuWindow.isReleasedWhenClosed = true
            menuWindow.orderFront(nil)
            menu.popUp(positioning: menu.items.first, at: .zero, in: menuWindow.contentView)
        }
    }

    @objc private func folderMenuItemClicked(_ sender: NSMenuItem) {
        if let data = sender.representedObject as? SnippetPasteData {
            pasteSnippetContent(data.content, rtfData: data.rtfData, matchDestinationFont: data.matchDestinationFont)
        }
    }

    private func pasteSnippetContent(_ content: String, rtfData: Data? = nil, matchDestinationFont: Bool = true) {
        // Set a flag so the clipboard monitor ignores this change
        clipboardMonitor?.snippetPasteFlag = true

        let pb = NSPasteboard.general
        // Capture clipboard BEFORE clearing so {{clipboard}} token can use it
        let savedClipboard = pb.string(forType: .string) ?? ""
        pb.clearContents()

        let isTokenOnly = SnippetTokenResolver.isTokenOnly(content)

        if let rtfData, !isTokenOnly, !matchDestinationFont,
           let attrStr = NSMutableAttributedString(rtf: rtfData, documentAttributes: nil) {
            // Resolve tokens in RTF — preserves custom font/size
            let tokens = SnippetTokenResolver.findTokenRanges(in: attrStr.string, clipboardText: savedClipboard)
            for (range, replacement) in tokens.reversed() {
                attrStr.replaceCharacters(in: range, with: replacement)
            }
            if let resolvedRTF = try? attrStr.data(from: NSRange(location: 0, length: attrStr.length),
                                                     documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
                pb.setData(resolvedRTF, forType: .rtf)
            }
            pb.setString(attrStr.string, forType: .string)
        } else {
            let resolved = SnippetTokenResolver.resolve(content, clipboardText: savedClipboard)
            pb.setString(resolved, forType: .string)
        }

        // Paste into the current frontmost app (panel isn't open for global hotkey)
        guard let frontApp = previousApp ?? NSWorkspace.shared.frontmostApplication else { return }
        frontApp.activate()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let source = CGEventSource(stateID: .combinedSessionState)
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
            keyDown?.flags = .maskCommand
            keyUp?.flags = .maskCommand
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
        }
    }

    /// Insert a snippet from the panel UI (with panel dismissal)
    func pasteSnippetFromPanel(_ snippet: SavedSnippet) {
        clipboardMonitor?.snippetPasteFlag = true

        let pb = NSPasteboard.general
        // Capture clipboard BEFORE clearing so {{clipboard}} token can use it
        let savedClipboard = pb.string(forType: .string) ?? ""
        debugLog("pasteSnippetFromPanel: savedClipboard=\"\(savedClipboard.prefix(60))\" snippet.content=\"\(snippet.content.prefix(60))\"")
        pb.clearContents()

        let isTokenOnly = SnippetTokenResolver.isTokenOnly(snippet.content)

        if let rtfData = snippet.rtfData, !isTokenOnly, !snippet.matchDestinationFont,
           let attrStr = NSMutableAttributedString(rtf: rtfData, documentAttributes: nil) {
            // Resolve tokens in both RTF and plain text — preserves custom font/size
            let tokens = SnippetTokenResolver.findTokenRanges(in: attrStr.string, clipboardText: savedClipboard)
            debugLog("  RTF path: \(tokens.count) tokens found, attrStr=\"\(attrStr.string.prefix(60))\"")
            // Replace from end to start to preserve ranges
            for (range, replacement) in tokens.reversed() {
                debugLog("  replacing range \(range) with \"\(replacement.prefix(40))\"")
                attrStr.replaceCharacters(in: range, with: replacement)
            }
            debugLog("  after resolve: \"\(attrStr.string.prefix(80))\"")
            if let resolvedRTF = try? attrStr.data(from: NSRange(location: 0, length: attrStr.length),
                                                     documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
                pb.setData(resolvedRTF, forType: .rtf)
            }
            pb.setString(attrStr.string, forType: .string)
        } else {
            let resolved = SnippetTokenResolver.resolve(snippet.content, clipboardText: savedClipboard)
            debugLog("  plain path: resolved=\"\(resolved.prefix(80))\"")
            pb.setString(resolved, forType: .string)
        }

        pasteIntoPreviousApp()
    }

    /// Continuously track the frontmost app so previousApp is always accurate,
    /// even when the user switches desktops/spaces before invoking the panel.
    private func trackFrontmostApp() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            self?.previousApp = app
        }
    }

    private func positionPanelBelowStatusItem() {
        guard let panel = panel, let button = statusItem.button,
              let buttonWindow = button.window else { return }

        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let panelWidth = panel.frame.width
        let panelHeight = panel.frame.height

        let x = buttonFrame.midX - panelWidth / 2
        let y = buttonFrame.minY - panelHeight - 4

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

extension Notification.Name {
    static let openSettings = Notification.Name("openSettings")

    static let panelDidOpen = Notification.Name("panelDidOpen")
    static let panelEscapePressed = Notification.Name("panelEscapePressed")
    static let snippetHotkeysChanged = Notification.Name("snippetHotkeysChanged")
    static let snippetExpandFolder = Notification.Name("snippetExpandFolder")
    static let snippetCollapseFolder = Notification.Name("snippetCollapseFolder")
    static let snippetMoveSelection = Notification.Name("snippetMoveSelection")
    static let snippetInsertSelected = Notification.Name("snippetInsertSelected")
    static let snippetDeleteSelected = Notification.Name("snippetDeleteSelected")
}
