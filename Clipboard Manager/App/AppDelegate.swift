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
        suppressPlaceholderWindows()

        // Warm up location for the {{latlon}} snippet token if already authorized
        // (never prompts at launch — first opt-in happens via the editor chip).
        LocationProvider.shared.startIfAuthorized()

        // Preload SF Symbols catalog on background thread
        DispatchQueue.global(qos: .utility).async {
            SFSymbolLoader.shared.load()
        }

        // Snapshot snippets to a JSON file so an accidental delete is recoverable by
        // copying a file instead of scraping freed database pages.
        Task.detached(priority: .utility) { [container = modelContainer!] in
            SnippetBackup.run(container: container)
        }

        // Backfill: move legacy inline imageData into ClipboardImageBlob + thumbnailData
        Task.detached(priority: .utility) { [container = modelContainer!] in
            await Self.migrateInlineImagesToBlobs(container: container)
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
            modelContainer = try ModelContainer(for: ClipboardEntry.self, ClipboardImageBlob.self, SavedSnippet.self, configurations: config)
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
                modelContainer = try ModelContainer(for: ClipboardEntry.self, ClipboardImageBlob.self, SavedSnippet.self, configurations: config)
            } catch {
                fatalError("Failed to create ModelContainer after reset: \(error)")
            }
        }
    }

    /// Walks legacy entries with inline imageData and moves them into ClipboardImageBlob
    /// while populating a small thumbnailData on the entry. Runs in batches with yields
    /// so the UI stays responsive during the migration of large stores.
    private static func migrateInlineImagesToBlobs(container: ModelContainer) async {
        let context = ModelContext(container)
        let batchSize = 25
        var total = 0
        while !Task.isCancelled {
            var descriptor = FetchDescriptor<ClipboardEntry>(
                predicate: #Predicate { $0.imageData != nil }
            )
            descriptor.fetchLimit = batchSize
            guard let batch = try? context.fetch(descriptor), !batch.isEmpty else { break }
            for entry in batch {
                guard let data = entry.imageData else { continue }
                if entry.thumbnailData == nil {
                    entry.thumbnailData = ClipboardMonitor.makeThumbnail(from: data)
                }
                // Insert blob if one doesn't already exist for this id
                let entryID = entry.id
                var blobCheck = FetchDescriptor<ClipboardImageBlob>(
                    predicate: #Predicate { $0.id == entryID }
                )
                blobCheck.fetchLimit = 1
                if (try? context.fetch(blobCheck))?.isEmpty != false {
                    context.insert(ClipboardImageBlob(id: entryID, data: data))
                }
                entry.imageData = nil
                total += 1
            }
            try? context.save()
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        NSLog("[ClipboardManager] Image migration finished: moved %d entries to blobs", total)
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
        hotkeyManager?.setupExcelCleanHotkey { [weak self] in
            MainActor.assumeIsolated {
                self?.clipboardMonitor?.cleanExcelSelection()
            }
        }
        hotkeyManager?.setupSaveToFinderHotkey { [weak self] in
            MainActor.assumeIsolated {
                self?.saveClipboardImageToFinderWindow()
            }
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
    func pasteIntoPreviousApp(completion: (() -> Void)? = nil) {
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
        activateAndPostCmdV(targetApp: prevApp, completion: completion)
    }

    /// Snapshot every type currently on the general pasteboard, so a transient paste
    /// (e.g. a snippet) can put the user's real clipboard back afterward.
    private func snapshotPasteboard() -> [(NSPasteboard.PasteboardType, Data)] {
        let pb = NSPasteboard.general
        return (pb.types ?? []).compactMap { type in
            pb.data(forType: type).map { (type, $0) }
        }
    }

    /// Restore a snapshot taken by `snapshotPasteboard()`. Flags the monitor so the
    /// restore isn't recorded as a new clipboard entry.
    private func restorePasteboard(_ snapshot: [(NSPasteboard.PasteboardType, Data)]) {
        clipboardMonitor?.snippetPasteFlag = true
        let pb = NSPasteboard.general
        pb.clearContents()
        guard !snapshot.isEmpty else { return }
        pb.declareTypes(snapshot.map { $0.0 }, owner: nil)
        for (type, data) in snapshot {
            pb.setData(data, forType: type)
        }
    }

    /// Restore the saved clipboard after a snippet paste, once the target app has consumed
    /// the Cmd+V. The delay must comfortably outlast the app's paste — restoring too early
    /// races the paste and the app ends up inserting the OLD clipboard instead of the
    /// snippet (seen as "the date shortcut pasted my clipboard"). 0.6s clears every app
    /// tested; the synthetic Cmd+V is virtually always consumed well within it.
    private func restoreClipboardAfterPaste(_ snapshot: [(NSPasteboard.PasteboardType, Data)]) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.restorePasteboard(snapshot)
        }
    }

    /// Activate the target app and run `action` as soon as activation is confirmed
    /// (typically 10–30ms via didActivateApplicationNotification, with a 0.20s fallback).
    private func activate(_ targetApp: NSRunningApplication, then action: @escaping () -> Void) {
        // If already frontmost, skip the wait entirely
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == targetApp.processIdentifier {
            action()
            return
        }

        targetApp.activate()

        var fired = false
        var observer: NSObjectProtocol?
        let fire = {
            guard !fired else { return }
            fired = true
            if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
            action()
        }

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier == targetApp.processIdentifier else { return }
            fire()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { fire() }
    }

    /// Activate the target app and post Cmd+V once it is frontmost.
    /// `completion` runs right after Cmd+V is posted — used to restore the clipboard.
    private func activateAndPostCmdV(targetApp: NSRunningApplication, completion: (() -> Void)? = nil) {
        activate(targetApp) { [weak self] in
            self?.postCmdV()
            completion?()
        }
    }

    /// Activate the target app and "type" a plain-text string directly via synthetic
    /// key events — no clipboard involved, so nothing to save/restore and no paste race.
    /// Used for plain snippets (e.g. {{date}}); rich/formatted snippets still paste.
    private func activateAndType(targetApp: NSRunningApplication, text: String) {
        activate(targetApp) { [weak self] in
            self?.typeText(text)
        }
    }

    /// Insert `text` as if typed, using CGEvent Unicode strings (chunked — a single event
    /// carries only a short string). Requires the same Accessibility grant as Cmd+V.
    private func typeText(_ text: String) {
        if !AXIsProcessTrusted() {
            debugLog("type: ABORT — Accessibility not trusted; prompting user")
            promptForAccessibility()
            return
        }
        // Use a private event source so the events do NOT merge with the physical keyboard
        // state. Otherwise, while the user is still holding the snippet hotkey's modifiers
        // (e.g. ⌘⌥⌃ for a date snippet), each typed event — which uses virtualKey 0 (the
        // "a" key) — would inherit those modifiers and read as ⌘⌥⌃A, firing OTHER apps'
        // global hotkeys (this fired Window Manager's ⌘⌥⌃A "cascade all" action). We also
        // clear the flags explicitly on every event so no modifier ever leaks in.
        let source = CGEventSource(stateID: .privateState)
        let utf16 = Array(text.utf16)
        let chunkSize = 16
        var i = 0
        while i < utf16.count {
            let end = min(i + chunkSize, utf16.count)
            var chunk = Array(utf16[i..<end])
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                down.flags = []
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                up.flags = []
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                up.post(tap: .cghidEventTap)
            }
            i = end
        }
    }

    private func postCmdV() {
        // If Accessibility was revoked (e.g. after a signature/entitlement change), the
        // synthetic Cmd+V silently does nothing — surface that instead of failing quietly.
        if !AXIsProcessTrusted() {
            debugLog("paste: ABORT — Accessibility not trusted; prompting user")
            promptForAccessibility()
            return
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
        debugLog("paste: Cmd+V posted, keyDown=\(keyDown != nil ? "ok" : "nil"), keyUp=\(keyUp != nil ? "ok" : "nil")")
    }

    /// Trigger the system Accessibility prompt (with the "Open System Settings" deep link).
    /// Accessibility can be silently revoked when the app's signature/entitlements change.
    private func promptForAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
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
            for (index, child) in children.enumerated() {
                let baseTitle = child.title.isEmpty ? String(child.content.prefix(40)) : child.title
                // Number the first 9 items and bind the bare number key to insert them.
                let number = index + 1
                let title = number <= 9 ? "\(number)   \(baseTitle)" : baseTitle
                let keyEquiv = number <= 9 ? "\(number)" : ""
                let item = NSMenuItem(title: title, action: #selector(self?.folderMenuItemClicked(_:)), keyEquivalent: keyEquiv)
                item.keyEquivalentModifierMask = []  // press the number alone, no ⌘
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

    /// Turn literal bullet lines ("\t• text", "1. text") into REAL lists.
    ///
    /// Snippets typed with plain "•" characters carry no list structure — the stored RTF has
    /// no \\listtable at all — so the receiving app pastes them as ordinary text and pressing
    /// Return does NOT continue the list. Rebuilding them as NSTextList paragraphs makes the
    /// RTF carry proper list tables, so Mail/Word treat them as live bullets.
    private func convertLiteralBulletsToLists(_ attrStr: NSMutableAttributedString) {
        guard attrStr.length > 0 else { return }
        let ns = attrStr.string as NSString
        var paraRanges: [NSRange] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: [.byParagraphs, .substringNotRequired]) { _, r, _, _ in
            paraRanges.append(r)
        }
        guard let pattern = try? NSRegularExpression(
            pattern: "^([\\t ]*)([\u{2022}\u{25E6}\u{2023}\u{2043}\u{25AA}*\\-]|\\d+[.)])[\\t ]+(.*)$"
        ) else { return }

        // One NSTextList instance per (level, marker), REUSED across items. A fresh
        // instance per line makes every bullet its own single-item list, which renders with
        // extra space between items and breaks list continuity.
        var sharedLists: [String: NSTextList] = [:]

        // Back-to-front so earlier ranges stay valid while mutating.
        for range in paraRanges.reversed() {
            let line = ns.substring(with: range)
            let lineNS = line as NSString
            guard let m = pattern.firstMatch(in: line, range: NSRange(location: 0, length: lineNS.length)),
                  m.numberOfRanges == 4 else { continue }
            let indent = lineNS.substring(with: m.range(at: 1))
            let marker = lineNS.substring(with: m.range(at: 2))
            let body = lineNS.substring(with: m.range(at: 3))
            let tabs = indent.filter { $0 == "\t" }.count
            let level = max(0, tabs - (tabs > 0 ? 1 : 0))

            let isNumbered = marker.rangeOfCharacter(from: .decimalDigits) != nil
            // Keep the marker the user actually typed at EVERY level. Imposing the usual
            // disc → circle → square cascade silently rewrote their nested "\u{2022}" as a
            // hollow "\u{25E6}", so the paste no longer matched the snippet they wrote.
            let fmt: NSTextList.MarkerFormat
            switch marker {
            case "\u{25E6}": fmt = .circle
            case "\u{25AA}": fmt = .square
            case "-", "*":   fmt = .hyphen
            default:         fmt = isNumbered ? .decimal : .disc
            }
            var lists: [NSTextList] = []
            for i in 0...level {
                let key = "\(i)-\(fmt.rawValue)"
                if let existing = sharedLists[key] {
                    lists.append(existing)
                } else {
                    let made = NSTextList(markerFormat: fmt, options: 0)
                    sharedLists[key] = made
                    lists.append(made)
                }
            }
            // Start from the paragraph's EXISTING style so line/paragraph spacing the user
            // set is preserved — building a fresh style dropped it and looked double-spaced.
            let base = attrStr.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let para = (base?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            para.textLists = lists
            para.firstLineHeadIndent = CGFloat(level * 36)
            para.headIndent = CGFloat((level + 1) * 36)
            para.paragraphSpacing = 0
            para.paragraphSpacingBefore = 0
            para.lineSpacing = 0

            // Cocoa's list convention is: tab, marker, tab, text.
            let markerText = isNumbered ? marker : "\u{2022}"
            let attrIndex = min(range.location + (indent as NSString).length, max(0, attrStr.length - 1))
            let attrs = attrStr.attributes(at: attrIndex, effectiveRange: nil)
            let replacement = NSMutableAttributedString(string: "\t\(markerText)\t\(body)", attributes: attrs)
            replacement.addAttribute(.paragraphStyle, value: para,
                                     range: NSRange(location: 0, length: replacement.length))
            attrStr.replaceCharacters(in: range, with: replacement)
        }
    }

    /// Resolve a snippet's RTF (tokens substituted) and put it on the pasteboard.
    ///
    /// `matchDestinationFont` means "adopt the destination's typeface", NOT "send plain
    /// text" — sending plain text loses bullets, numbering and bold, which is what users
    /// notice ("pasted plain, no bullets"). So the RTF is always sent; when the flag is on
    /// we only drop each run's font family/size, keeping its bold/italic traits and all
    /// paragraph structure (NSTextList bullets survive because they live in the paragraph
    /// style, not the font).
    private func writeSnippetRTF(_ rtfData: Data, clipboardText: String,
                                 matchDestinationFont: Bool, to pb: NSPasteboard) {
        guard let attrStr = NSMutableAttributedString(rtf: rtfData, documentAttributes: nil) else { return }

        let tokens = SnippetTokenResolver.findTokenRanges(in: attrStr.string, clipboardText: clipboardText)
        for (range, replacement) in tokens.reversed() {
            attrStr.replaceCharacters(in: range, with: replacement)
        }

        // Rebuild any literal "• " lines as real lists so Return continues the list.
        convertLiteralBulletsToLists(attrStr)

        if matchDestinationFont {
            let full = NSRange(location: 0, length: attrStr.length)
            attrStr.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
                guard let font = value as? NSFont else { return }
                let traits = font.fontDescriptor.symbolicTraits
                var replacement = NSFont.systemFont(ofSize: NSFont.systemFontSize)
                let descriptor = replacement.fontDescriptor.withSymbolicTraits(traits)
                if let traited = NSFont(descriptor: descriptor, size: NSFont.systemFontSize) {
                    replacement = traited
                }
                attrStr.addAttribute(.font, value: replacement, range: range)
            }
        }

        let full = NSRange(location: 0, length: attrStr.length)
        let hasList = Self.containsTextList(attrStr)

        // For list content, prefer HTML. Cocoa's RTF writer closes and reopens the list for
        // EVERY item, which the receiving app renders with a big gap between bullets — the
        // "very tall line spacing" symptom. In HTML we can merge those blocks back into one
        // <ul>, so the list stays continuous and tight.
        if hasList,
           let htmlData = try? attrStr.data(from: full, documentAttributes: [
               .documentType: NSAttributedString.DocumentType.html,
               .excludedElements: ["doctype", "html", "head", "meta", "style", "body"]
           ]),
           var html = String(data: htmlData, encoding: .utf8) {
            html = html.replacingOccurrences(of: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>", with: "")
            for tag in ["ul", "ol"] {
                if let re = try? NSRegularExpression(pattern: "</\(tag)>\\s*<\(tag)([^>]*)>") {
                    html = re.stringByReplacingMatches(in: html,
                                                       range: NSRange(html.startIndex..., in: html),
                                                       withTemplate: "")
                }
            }
            if let merged = html.data(using: .utf8) {
                pb.setData(merged, forType: .html)
                pb.setString(attrStr.string, forType: .string)
                return
            }
        }

        if let resolvedRTF = try? attrStr.data(from: full,
                                               documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            pb.setData(resolvedRTF, forType: .rtf)
        }
        pb.setString(attrStr.string, forType: .string)
    }

    /// Whether any paragraph carries a real NSTextList (i.e. the content is a live list).
    private static func containsTextList(_ attrStr: NSAttributedString) -> Bool {
        var found = false
        attrStr.enumerateAttribute(.paragraphStyle,
                                   in: NSRange(location: 0, length: attrStr.length),
                                   options: []) { value, _, stop in
            if let style = value as? NSParagraphStyle, !style.textLists.isEmpty {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    private func pasteSnippetContent(_ content: String, rtfData: Data? = nil, matchDestinationFont: Bool = true) {
        let savedClipboard = NSPasteboard.general.string(forType: .string) ?? ""
        let needsRTF = rtfData != nil && !SnippetTokenResolver.isTokenOnly(content)

        // Paste into the current frontmost app (panel isn't open for global hotkey)
        guard let frontApp = previousApp ?? NSWorkspace.shared.frontmostApplication else { return }

        if !needsRTF {
            // Plain text → type it directly. No clipboard touched: instant, no restore, no race.
            let resolved = SnippetTokenResolver.resolve(content, clipboardText: savedClipboard)
            activateAndType(targetApp: frontApp, text: resolved)
            return
        }

        // Rich formatting must go through the pasteboard, so snapshot + restore the clipboard.
        clipboardMonitor?.snippetPasteFlag = true
        let pb = NSPasteboard.general
        let snapshot = snapshotPasteboard()
        pb.clearContents()
        if let rtfData {
            writeSnippetRTF(rtfData, clipboardText: savedClipboard,
                            matchDestinationFont: matchDestinationFont, to: pb)
        }
        activateAndPostCmdV(targetApp: frontApp) { [weak self] in
            self?.restoreClipboardAfterPaste(snapshot)
        }
    }

    /// Insert a snippet from the panel UI (with panel dismissal)
    func pasteSnippetFromPanel(_ snippet: SavedSnippet) {
        let savedClipboard = NSPasteboard.general.string(forType: .string) ?? ""
        let needsRTF = snippet.rtfData != nil
            && !SnippetTokenResolver.isTokenOnly(snippet.content)

        if !needsRTF {
            // Plain text → type directly, no clipboard touched. Dismiss the panel first.
            let resolved = SnippetTokenResolver.resolve(snippet.content, clipboardText: savedClipboard)
            panel?.orderOut(nil)
            guard let prevApp = previousApp else { return }
            activateAndType(targetApp: prevApp, text: resolved)
            return
        }

        // Rich formatting must go through the pasteboard, so snapshot + restore the clipboard.
        clipboardMonitor?.snippetPasteFlag = true
        let pb = NSPasteboard.general
        let snapshot = snapshotPasteboard()
        pb.clearContents()
        if let rtfData = snippet.rtfData {
            writeSnippetRTF(rtfData, clipboardText: savedClipboard,
                            matchDestinationFont: snippet.matchDestinationFont, to: pb)
        }
        pasteIntoPreviousApp { [weak self] in
            self?.restoreClipboardAfterPaste(snapshot)
        }
    }


    // MARK: - Save clipboard image into the front Finder window

    private static let finderBundleID = "com.apple.finder"

    /// Write any image on the clipboard into the folder the front Finder window shows,
    /// then select it. Falls back to the configured save folder (or Downloads) when
    /// Finder has no window open — e.g. only the Desktop is showing.
    private func saveClipboardImageToFinderWindow() {
        let pb = NSPasteboard.general
        var data = pb.data(forType: .png)
        if data == nil, let tiff = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff) {
            data = rep.representation(using: .png, properties: [:])
        }
        guard let imageData = data else {
            NSSound.beep()
            return
        }

        let folder = frontFinderFolder() ?? SettingsManager.shared.imageSaveFolderURL

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        var url = folder.appendingPathComponent("Clipboard \(stamp.string(from: Date())).png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("Clipboard \(stamp.string(from: Date())) (\(n)).png")
            n += 1
        }

        do {
            try imageData.write(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSLog("[ClipboardManager] Save to Finder failed: %@", error.localizedDescription)
            NSSound.beep()
        }
    }

    /// The folder shown by Finder's frontmost window, via AppleScript (needs Automation
    /// permission for Finder — macOS prompts once).
    private func frontFinderFolder() -> URL? {
        let script = """
        tell application "Finder"
            if (count of windows) is 0 then return ""
            try
                return POSIX path of (target of front window as alias)
            on error
                return ""
            end try
        end tell
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return nil }
        task.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !out.isEmpty else { return nil }
        return URL(fileURLWithPath: out, isDirectory: true)
    }

    /// Continuously track the frontmost app so previousApp is always accurate,
    /// even when the user switches desktops/spaces before invoking the panel.
    private static let excelBundleID = "com.microsoft.Excel"

    private func trackFrontmostApp() {
        // Set initial Excel-clean hotkey state based on what's frontmost right now.
        hotkeyManager?.setExcelCleanHotkeyActive(
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.excelBundleID
        )
        hotkeyManager?.setSaveToFinderHotkeyActive(
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.finderBundleID
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            // Scope the Excel-clean hotkey to Excel only, so its combo (⌘⌥C) passes
            // through to Finder ("Copy as Pathname") and every other app untouched.
            // Ignore activations of our own (non-activating) app so the state sticks while in Excel.
            if app.bundleIdentifier != Bundle.main.bundleIdentifier {
                self?.hotkeyManager?.setExcelCleanHotkeyActive(app.bundleIdentifier == Self.excelBundleID)
                // Same scoping for save-to-Finder: only live while Finder is frontmost.
                self?.hotkeyManager?.setSaveToFinderHotkeyActive(app.bundleIdentifier == Self.finderBundleID)
                self?.previousApp = app
            }
        }
    }

    func closePanel() {
        panel?.orderOut(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// SwiftUI's `Window("", id: "hidden")` placeholder scene can be surfaced by AppKit
    /// when the panel is dismissed (e.g. via Escape). Hide it at launch and after every
    /// panel close. Identifies the hidden window by its empty title + zero-ish size,
    /// to avoid touching popovers, status menus, or the settings window.
    func hidePlaceholderWindows() {
        for w in NSApp.windows {
            guard w !== panel, w !== settingsWindow else { continue }
            if w.isVisible && w.className.contains("SwiftUI") {
                w.orderOut(nil)
            }
        }
    }

    private func suppressPlaceholderWindows() {
        // One-shot hide right after launch, once SwiftUI has created its scenes.
        DispatchQueue.main.async { [weak self] in
            self?.hidePlaceholderWindows()
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
    static let panelDidClose = Notification.Name("panelDidClose")
    static let panelEscapePressed = Notification.Name("panelEscapePressed")
    static let snippetHotkeysChanged = Notification.Name("snippetHotkeysChanged")
    static let snippetExpandFolder = Notification.Name("snippetExpandFolder")
    static let snippetCollapseFolder = Notification.Name("snippetCollapseFolder")
    static let snippetMoveSelection = Notification.Name("snippetMoveSelection")
    static let snippetInsertSelected = Notification.Name("snippetInsertSelected")
    static let snippetDeleteSelected = Notification.Name("snippetDeleteSelected")
    /// Delete a folder AND everything inside it (Cmd+Delete, asks first).
    static let snippetDeleteWithContents = Notification.Name("snippetDeleteWithContents")
}
