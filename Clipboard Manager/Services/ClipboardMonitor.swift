import AppKit
import SwiftData
import Combine
import Vision
import QuickLookThumbnailing

class ClipboardMonitor: ObservableObject {
    private var timer: AnyCancellable?
    private var lastChangeCount: Int
    private let modelContainer: ModelContainer
    private let settings = SettingsManager.shared
    private var appObserver: Any?

    /// Tracks the last non-self app that was activated (more reliable than
    /// checking frontmostApplication at poll time, especially across spaces).
    private var lastActiveApp: NSRunningApplication?

    /// Set to an entry ID before copying from the app — the monitor will
    /// move that entry to the top instead of creating a duplicate.
    var selfCopiedEntryID: UUID?

    /// Set to true before pasting a snippet — the monitor will skip the next change.
    var snippetPasteFlag = false

    /// Set to true before a manual Excel copy (via the Clean Excel Selection hotkey) —
    /// the monitor will strip non-contiguous gaps from the next captured copy.
    var pendingExcelClean = false

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        self.lastChangeCount = NSPasteboard.general.changeCount
        trackActiveApp()
    }

    private func trackActiveApp() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastActiveApp = front
        }
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            self?.lastActiveApp = app
        }
    }

    func start() {
        timer = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.checkClipboard()
                }
            }
        backfillFavicons()
    }

    /// The app that currently owns keyboard focus (the key window), via the Accessibility API.
    /// This is the true source of a ⌘C even for non-activating floating panels (e.g. Beam),
    /// which are never `NSWorkspace.frontmostApplication`. Requires Accessibility permission.
    private func focusedApplication() -> NSRunningApplication? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let appElement = value as! AXUIElement
        var pid: pid_t = 0
        guard AXUIElementGetPid(appElement, &pid) == .success, pid > 0 else { return nil }
        let app = NSRunningApplication(processIdentifier: pid)
        // Ignore our own panel having focus (e.g. the search field) — that's not a real source.
        if app?.bundleIdentifier == Bundle.main.bundleIdentifier { return nil }
        return app
    }

    /// Find the app that owns the window under the mouse cursor.
    /// This catches right-click context menu copies where the app isn't activated.
    private func appUnderMouse() -> NSRunningApplication? {
        let mouseLocation = NSEvent.mouseLocation
        let screenHeight = NSScreen.screens.first(where: {
            NSMouseInRect(mouseLocation, $0.frame, false)
        })?.frame.height ?? NSScreen.main?.frame.height ?? 0
        // CGWindowList uses top-left origin
        let cgPoint = CGPoint(x: mouseLocation.x, y: screenHeight - mouseLocation.y)

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        let selfPID = ProcessInfo.processInfo.processIdentifier
        for window in windowList {
            guard let boundsDict = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let pid = window[kCGWindowOwnerPID as String] as? Int32,
                  pid != selfPID else { continue }
            // Skip transient overlays (e.g. a Notification Center banner under the cursor)
            // so we resolve the real window beneath them.
            let owner = NSRunningApplication(processIdentifier: pid)
            if let bid = owner?.bundleIdentifier, Self.nonSourceBundleIDs.contains(bid) { continue }
            let rect = CGRect(
                x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0
            )
            if rect.contains(cgPoint) {
                return owner
            }
        }
        return nil
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Manual "Clean Excel Selection" action (global hotkey): copies the current Excel
    /// selection and flags the resulting capture for non-contiguous gap stripping.
    /// No-op unless Excel is frontmost.
    @MainActor
    func cleanExcelSelection() {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.microsoft.Excel" else { return }
        pendingExcelClean = true
        // The user is still physically holding ⌘⌥C when the hotkey fires. If we synthesize
        // ⌘C now, the held ⌥ contaminates it (Excel sees ⌘⌥C and won't copy). Wait until the
        // modifier keys are released, then post a clean ⌘C.
        waitForModifiersThenCopy(attempts: 0)
        // Safety: clear the flag if the copy never produced a pasteboard change.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.pendingExcelClean = false
        }
    }

    private func waitForModifiersThenCopy(attempts: Int) {
        let mods = NSEvent.modifierFlags
        let held = mods.contains(.command) || mods.contains(.option)
            || mods.contains(.control) || mods.contains(.shift)
        if held && attempts < 60 {  // wait up to ~1.8s for the user to release ⌘⌥C
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                self?.waitForModifiersThenCopy(attempts: attempts + 1)
            }
            return
        }
        postCmdC()
    }

    /// Post ⌘C to the frontmost app via CGEvent (requires Accessibility permission).
    private func postCmdC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)  // 'C'
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    @MainActor
    private func checkClipboard() {
        let pasteboard = NSPasteboard.general
        let currentCount = pasteboard.changeCount

        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        // If we just pasted a snippet, skip this change
        if snippetPasteFlag {
            snippetPasteFlag = false
            return
        }

        // If we just copied from within the app, move that entry to the top
        if let entryID = selfCopiedEntryID {
            selfCopiedEntryID = nil
            let context = ModelContext(modelContainer)
            let descriptor = FetchDescriptor<ClipboardEntry>(
                predicate: #Predicate<ClipboardEntry> { $0.id == entryID }
            )
            if let entry = try? context.fetch(descriptor).first {
                entry.timestamp = Date()
                try? context.save()
            }
            return
        }

        // Consume the manual Excel-clean request (set by the Clean Excel Selection hotkey).
        let doExcelClean = pendingExcelClean
        pendingExcelClean = false

        // Determine source app: if our own panel has a text view as first responder,
        // the copy came from within Clipboard Manager. Otherwise prefer app under mouse
        // (catches right-click context menus), then frontmost app, then last tracked active app.
        let fromSelf: Bool
        if let panel = NSApp.windows.first(where: { $0 is ClipboardPanel }),
           panel.isVisible,
           panel.firstResponder is NSTextView {
            fromSelf = true
        } else {
            fromSelf = false
        }

        let frontApp: NSRunningApplication?
        if fromSelf {
            frontApp = NSRunningApplication.current
        } else {
            // Prefer the app with keyboard focus (Accessibility) — this catches non-activating
            // floating panels like Beam that own the key window without being "frontmost".
            // Then app under mouse (right-click menus), then frontmost app.
            var candidate = focusedApplication() ?? appUnderMouse() ?? NSWorkspace.shared.frontmostApplication
            // If we landed on a transient overlay (Notification Center, etc.), use the
            // last real active app instead — that's where the copy actually came from.
            if let bid = candidate?.bundleIdentifier, Self.nonSourceBundleIDs.contains(bid) {
                candidate = lastActiveApp
            }
            frontApp = candidate ?? lastActiveApp
        }
        var bundleID = frontApp?.bundleIdentifier
        var appName = frontApp?.localizedName

        // An app can stamp itself as the copy source via a marker type (timing-independent) —
        // used by non-activating panels like Beam that dismiss before our poll sees the change.
        // Trust the stamp when present.
        if let stamped = pasteboard.string(forType: NSPasteboard.PasteboardType("com.dnz.clipboard.source-app")),
           !stamped.isEmpty {
            bundleID = stamped
            appName = NSRunningApplication.runningApplications(withBundleIdentifier: stamped).first?.localizedName
                ?? appName
        }

        if let bid = bundleID, settings.isExcluded(bid) {
            return
        }

        let context = ModelContext(modelContainer)

        debugLog("Copy from: \(bundleID ?? "nil") (\(appName ?? "nil")), types: \(pasteboard.types?.map(\.rawValue) ?? [])")

        // Check local file URLs first — only file:// URLs, not http(s):// from browsers
        let fileURLs = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.filter { $0.isFileURL }
        if let urls = fileURLs, !urls.isEmpty {
            let paths = urls.map { $0.path }

            // For image files, capture full-size image from pasteboard so pasting
            // back preserves the original size (not a 256x256 thumbnail)
            let firstExt = urls.first?.pathExtension.lowercased() ?? ""
            let imgExts: Set<String> = ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "webp", "heic"]
            let imageData: Data?
            if imgExts.contains(firstExt), let fullImage = extractImageData(from: pasteboard) {
                imageData = fullImage
            } else {
                imageData = generateFileThumbnail(for: urls.first!)
            }

            let entry = ClipboardEntry(
                filePaths: paths,
                contentType: .file,
                sourceAppBundleID: bundleID,
                sourceAppName: appName
            )
            context.insert(entry)
            if let imgData = imageData {
                attachImage(imgData, to: entry, context: context)
                performOCR(imageData: imgData, entryID: entry.id)
            }
            // Upgrade the row preview to the real Quick Look thumbnail (video frames,
            // document/PDF previews, etc.) — same image Finder shows.
            if let first = urls.first {
                generateQuickLookThumbnail(for: first, entryID: entry.id)
            }
        } else if !((bundleID == "com.microsoft.Excel" && settings.excelCleanup && settings.excelCopyAsText) || doExcelClean), let imageData = extractImageData(from: pasteboard) {
            // Detect screenshots: macOS screenshot copies have specific pasteboard types
            let screenshotBundleIDs: Set<String> = [
                "com.apple.screencaptureui",
                "com.apple.Screenshot",
                "com.apple.screenshot.launcher"
            ]
            let hasScreenshotType = pasteboard.types?.contains(where: {
                $0.rawValue.contains("com.apple.screenshot") ||
                $0.rawValue.contains("dyn.") == false && $0 == .png
            }) ?? false
            let isFromScreenshotApp = bundleID.map { screenshotBundleIDs.contains($0) } ?? false
            // If only image data with no text — likely a screenshot or pasted image
            let hasNoText = pasteboard.string(forType: .string) == nil
            let isScreenshot = isFromScreenshotApp || (hasScreenshotType && hasNoText)

            let entry = ClipboardEntry(
                contentType: isScreenshot ? .screenshot : .image,
                sourceAppBundleID: isScreenshot ? nil : bundleID,
                sourceAppName: isScreenshot ? "Mac" : appName
            )
            // Capture source URL if available (e.g. image copied from browser)
            if let urlString = pasteboard.string(forType: .string),
               urlString.hasPrefix("http") {
                entry.sourceURL = urlString
            } else if let urlFromPboard = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
                      let firstURL = urlFromPboard.first,
                      let scheme = firstURL.scheme,
                      scheme.hasPrefix("http") {
                entry.sourceURL = firstURL.absoluteString
            }
            context.insert(entry)
            attachImage(imageData, to: entry, context: context)
            performOCR(imageData: imageData, entryID: entry.id)
            // Capture the source page + favicon the image was copied from — async so it
            // never blocks the copy. Runs when the source is a browser OR when the image
            // carries a web URL (e.g. copies routed through Notification Center).
            let isBrowser = bundleID.map { Self.browserAppNames[$0] != nil } ?? false
            if !isScreenshot, isBrowser || entry.sourceURL != nil {
                enrichSource(entryID: entry.id, bundleID: bundleID, fallbackURL: entry.sourceURL)
            }
            NSLog("[ClipboardManager] Image captured. isScreenshot=\(isScreenshot), bundleID=\(bundleID ?? "nil"), types=\(pasteboard.types?.map(\.rawValue) ?? [])")
        } else if let rtfData = pasteboard.data(forType: .rtf),
                  let text = pasteboard.string(forType: .string) {
            let rtfdData = pasteboard.data(forType: .rtfd)
            let types = pasteboard.types?.map(\.rawValue) ?? []
            NSLog("[ClipboardManager] RTF captured: rtf=\(rtfData.count)b, rtfd=\(rtfdData?.count ?? 0)b, types=\(types)")
            if doExcelClean {
                let cleanText = cleanExcelText(from: pasteboard) ?? text
                // Excel's HTML compacts rows but keeps the in-between COLUMNS. Filter those out
                // of Excel's own HTML so the paste keeps Excel's cell styling (colors/borders/
                // fonts) while being gap-free. Fall back to a regenerated table if needed.
                var htmlData: Data? = nil
                if let original = pasteboard.data(forType: .html),
                   let s = String(data: original, encoding: .utf8),
                   let sel = getExcelSelection(), let minCol = sel.cols.min(), let maxCol = sel.cols.max() {
                    let keep = Set(sel.cols.map { $0 - minCol })
                    let filtered = keep.count < (maxCol - minCol + 1) ? Self.filterHTMLColumns(s, keep: keep) : s
                    htmlData = filtered.data(using: .utf8)
                }
                if htmlData == nil { htmlData = Self.htmlTable(fromTabbed: cleanText) }
                pasteboard.clearContents()
                var types: [NSPasteboard.PasteboardType] = [.string]
                if htmlData != nil { types.append(.html) }
                pasteboard.declareTypes(types, owner: nil)
                pasteboard.setString(cleanText, forType: .string)
                if let htmlData { pasteboard.setData(htmlData, forType: .html) }
                lastChangeCount = pasteboard.changeCount
                let rtf = htmlData.flatMap { Self.rtf(fromHTML: $0) }
                let entry = ClipboardEntry(
                    textContent: cleanText,
                    rtfData: rtf,
                    contentType: rtf != nil ? .rtf : .text,
                    sourceAppBundleID: bundleID,
                    sourceAppName: appName
                )
                context.insert(entry)
            } else {
                let entry = ClipboardEntry(
                    textContent: text,
                    rtfData: rtfData,
                    rtfdData: rtfdData,
                    contentType: .rtf,
                    sourceAppBundleID: bundleID,
                    sourceAppName: appName
                )
                // A copied file embedded as an attachment (PDF from Safari's viewer or a Mail
                // attachment, which also puts the filename as plain text): surface a preview
                // image + filename. richEmbeddedPreview self-gates to attachment-only docs.
                if let rtfdData, let preview = Self.richEmbeddedPreview(fromRTFD: rtfdData) {
                    entry.thumbnailData = Self.makeThumbnail(from: preview.image)
                    if entry.firstLine?.isEmpty ?? true {
                        entry.firstLine = preview.name ?? "Rich content"
                    }
                }
                context.insert(entry)
            }
        } else if let text = pasteboard.string(forType: .string) {
            let cleanedText = doExcelClean ? cleanExcelText(from: pasteboard) : nil
            var finalText = cleanedText ?? text
            // WebKit-based apps (e.g. Bambu Studio) sometimes leave plain text empty and put the
            // real content only in HTML/webarchive — recover it so the copy isn't lost.
            if finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let recovered = Self.recoverWebText(from: pasteboard) {
                finalText = recovered
            }
            // Skip genuinely empty copies (some apps put an empty webarchive on the pasteboard)
            // rather than creating a blank, useless entry.
            guard !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                try? context.save()
                pruneIfNeeded(context: context)
                return
            }
            if let cleaned = cleanedText {
                // Replace system clipboard with cleaned text
                pasteboard.clearContents()
                pasteboard.setString(cleaned, forType: .string)
                lastChangeCount = pasteboard.changeCount
            }
            let contentType: ContentType = isURL(finalText) ? .url : .text
            let entry = ClipboardEntry(
                textContent: finalText,
                contentType: contentType,
                sourceAppBundleID: bundleID,
                sourceAppName: appName
            )
            context.insert(entry)
        }

        try? context.save()
        pruneIfNeeded(context: context)
    }

    private func extractImageData(from pasteboard: NSPasteboard) -> Data? {
        // Prefer raw PNG — no conversion needed, preserves original dimensions and DPI
        if let pngData = pasteboard.data(forType: .png) {
            return pngData
        }
        // Convert TIFF to PNG using NSBitmapImageRep directly (avoids NSImage DPI changes)
        if let tiffData = pasteboard.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiffData),
           let png = rep.representation(using: .png, properties: [:]) {
            return png
        }
        return nil
    }

    /// Async: generate the macOS Quick Look thumbnail for a file (video poster frame, PDF/doc
    /// preview, etc.) and update the entry's row thumbnail. Falls back silently if unsupported.
    private func generateQuickLookThumbnail(for url: URL, entryID: UUID) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let container = self.modelContainer
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 320, height: 320),
            scale: scale,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            guard let representation,
                  let thumb = ClipboardMonitor.makeThumbnail(from: representation.nsImage) else { return }
            DispatchQueue.main.async {
                let context = ModelContext(container)
                let descriptor = FetchDescriptor<ClipboardEntry>(
                    predicate: #Predicate<ClipboardEntry> { $0.id == entryID }
                )
                guard let entry = try? context.fetch(descriptor).first else { return }
                entry.thumbnailData = thumb
                try? context.save()
            }
        }
    }

    private func generateFileThumbnail(for url: URL) -> Data? {
        let size = CGSize(width: 256, height: 256)
        let ext = url.pathExtension.lowercased()

        // For image files, try to load the actual image
        let imageExtensions = Set(["png", "jpg", "jpeg", "gif", "bmp", "tiff", "webp", "heic"])
        if imageExtensions.contains(ext) {
            if let image = NSImage(contentsOf: url) {
                return resizeImage(image, to: size)
            }
        }

        // For PDFs, render the first page
        if ext == "pdf" {
            if let pdfDoc = CGPDFDocument(url as CFURL),
               let page = pdfDoc.page(at: 1) {
                let pageRect = page.getBoxRect(.mediaBox)
                let scale = min(size.width / pageRect.width, size.height / pageRect.height)
                let scaledSize = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)

                let image = NSImage(size: scaledSize)
                image.lockFocus()
                if let ctx = NSGraphicsContext.current?.cgContext {
                    ctx.setFillColor(NSColor.white.cgColor)
                    ctx.fill(CGRect(origin: .zero, size: scaledSize))
                    ctx.scaleBy(x: scale, y: scale)
                    ctx.drawPDFPage(page)
                }
                image.unlockFocus()
                return resizeImage(image, to: size)
            }
        }

        // For other files, use the file icon
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = size
        if let tiff = icon.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return png
        }
        return nil
    }

    private func resizeImage(_ image: NSImage, to size: CGSize) -> Data? {
        let resized = NSImage(size: size)
        resized.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy, fraction: 1.0)
        resized.unlockFocus()
        if let tiff = resized.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return png
        }
        return nil
    }

    private func performOCR(imageData: Data, entryID: UUID) {
        let container = self.modelContainer
        NSLog("[ClipboardManager] OCR: Starting for entry \(entryID), imageData size=\(imageData.count)")

        DispatchQueue.global(qos: .utility).async {
            guard let cgImageSource = CGImageSourceCreateWithData(imageData as CFData, nil) else {
                NSLog("[ClipboardManager] OCR: Failed to create CGImageSource")
                return
            }
            guard let cgImage = CGImageSourceCreateImageAtIndex(cgImageSource, 0, nil) else {
                NSLog("[ClipboardManager] OCR: Failed to create CGImage from source")
                return
            }

            NSLog("[ClipboardManager] OCR: CGImage created, size=\(cgImage.width)x\(cgImage.height)")

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate

            // Also decode QR codes / barcodes so their payload (usually a link) is searchable.
            let barcodeRequest = VNDetectBarcodesRequest()

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request, barcodeRequest])
            } catch {
                NSLog("[ClipboardManager] OCR: VNImageRequestHandler failed: \(error)")
                return
            }

            let recognized = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")

            // Barcode/QR payloads — dedupe so the same link isn't repeated.
            var barcodeLines: [String] = []
            for obs in barcodeRequest.results ?? [] {
                if let payload = obs.payloadStringValue, !payload.isEmpty,
                   !barcodeLines.contains(payload) {
                    barcodeLines.append(payload)
                }
            }
            let barcodeText = barcodeLines.joined(separator: "\n")

            let text = [recognized, barcodeText]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")

            NSLog("[ClipboardManager] OCR: \(request.results?.count ?? 0) text obs, \(barcodeRequest.results?.count ?? 0) barcodes, text length=\(text.count)")
            if !text.isEmpty {
                NSLog("[ClipboardManager] OCR: Text preview: \(String(text.prefix(200)))")
            }

            guard !text.isEmpty else { return }

            DispatchQueue.main.async {
                let context = ModelContext(container)
                let descriptor = FetchDescriptor<ClipboardEntry>(
                    predicate: #Predicate<ClipboardEntry> { $0.id == entryID }
                )
                do {
                    if let entry = try context.fetch(descriptor).first {
                        entry.ocrText = text
                        try context.save()
                        NSLog("[ClipboardManager] OCR: Saved text for entry \(entryID)")
                    } else {
                        NSLog("[ClipboardManager] OCR: Entry \(entryID) not found in store")
                    }
                } catch {
                    NSLog("[ClipboardManager] OCR: Save failed: \(error)")
                }
            }
        }
    }

    /// When Excel copies non-contiguous rows, the plain text includes all
    /// intermediate rows. The HTML only contains the actually selected rows.
    /// Parse the HTML table to produce clean tab-separated text.
    private func debugLog(_ message: String) {
        let path = "/tmp/clipboard-manager-excel-debug.log"
        let line = "\(Date()): \(message)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
        }
    }

    /// Convert Excel column letter(s) to 1-based index (A=1, B=2, ..., Z=26, AA=27, etc.)
    private func columnToIndex(_ col: String) -> Int {
        var result = 0
        for char in col.uppercased() {
            result = result * 26 + Int(char.asciiValue! - 64)
        }
        return result
    }

    /// Query Excel via osascript for the current selection address
    /// Returns (selectedRows, selectedColumns) as 1-based sets, or nil if unavailable
    private func getExcelSelection() -> (rows: Set<Int>, cols: Set<Int>)? {
        let script = "tell application \"Microsoft Excel\" to get address of selection"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            debugLog("osascript launch error: \(error)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let address = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !address.isEmpty else {
            debugLog("osascript failed, status=\(process.terminationStatus)")
            return nil
        }
        debugLog("Excel selection address: \(address)")

        // Parse address like "$A$1:$A$3,$C$1:$C$3"
        // Each cell ref is $COL$ROW
        var rows = Set<Int>()
        var cols = Set<Int>()
        let cellPattern = try! NSRegularExpression(pattern: "\\$([A-Z]+)\\$([0-9]+)")
        let ranges = address.split(separator: ",")
        for range in ranges {
            let s = String(range)
            let matches = cellPattern.matches(in: s, range: NSRange(s.startIndex..., in: s))
            var rangeCols: [Int] = []
            var rangeRows: [Int] = []
            for m in matches {
                if let colRange = Range(m.range(at: 1), in: s),
                   let rowRange = Range(m.range(at: 2), in: s) {
                    rangeCols.append(columnToIndex(String(s[colRange])))
                    rangeRows.append(Int(s[rowRange])!)
                }
            }
            // Expand ranges (e.g. $A$1:$C$3 → cols 1-3, rows 1-3)
            if rangeCols.count >= 2 {
                for c in rangeCols.min()!...rangeCols.max()! { cols.insert(c) }
            } else if let c = rangeCols.first { cols.insert(c) }
            if rangeRows.count >= 2 {
                for r in rangeRows.min()!...rangeRows.max()! { rows.insert(r) }
            } else if let r = rangeRows.first { rows.insert(r) }
        }
        return (rows.isEmpty || cols.isEmpty) ? nil : (rows, cols)
    }

    private func cleanExcelText(from pasteboard: NSPasteboard) -> String? {
        guard let text = pasteboard.string(forType: .string) else { return nil }

        let textRows = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard !textRows.isEmpty else { return nil }

        guard let selection = getExcelSelection() else {
            debugLog("Excel: couldn't get selection, returning text as-is")
            return nil
        }

        let selectedRows = selection.rows
        let selectedCols = selection.cols
        let minRow = selectedRows.min()!
        let maxRow = selectedRows.max()!
        let minCol = selectedCols.min()!
        let maxCol = selectedCols.max()!

        // If text has more lines than the bounding box of selected rows,
        // cells contain in-cell line breaks — can't reliably map lines to rows
        let boundingRowCount = maxRow - minRow + 1
        if textRows.count > boundingRowCount {
            debugLog("Excel: text lines (\(textRows.count)) > bounding rows (\(boundingRowCount)), in-cell line breaks — skipping cleanup")
            return nil
        }

        // Count total columns in bounding box
        let totalCols = maxCol - minCol + 1
        let textColCount = textRows.first.map { $0.split(separator: "\t", omittingEmptySubsequences: false).count } ?? totalCols

        // Check if filtering is needed
        let allRowsSelected = textRows.count == selectedRows.count
        let allColsSelected = textColCount == selectedCols.count
        if allRowsSelected && allColsSelected { return nil } // no cleaning needed

        debugLog("Excel: selected rows=\(selectedRows.sorted()), cols=\(selectedCols.sorted()), textRows=\(textRows.count), textCols=\(textColCount)")

        var cleanedRows: [String] = []
        for (index, row) in textRows.enumerated() {
            let excelRow = minRow + index
            if !selectedRows.contains(excelRow) { continue }

            // Filter columns
            let cells = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if allColsSelected {
                cleanedRows.append(row)
            } else {
                var filteredCells: [String] = []
                for (colIndex, cell) in cells.enumerated() {
                    let excelCol = minCol + colIndex
                    if selectedCols.contains(excelCol) {
                        filteredCells.append(cell)
                    }
                }
                cleanedRows.append(filteredCells.joined(separator: "\t"))
            }
        }

        debugLog("Excel: cleaned \(textRows.count)x\(textColCount) → \(cleanedRows.count)x\(selectedCols.count)")
        let result = cleanedRows.joined(separator: "\n")
        return result.isEmpty ? nil : result
    }

    /// Apps that are never the real source of a copy — transient overlays / system UI.
    /// When one of these is detected as the source, fall back to the last active app.
    private static let nonSourceBundleIDs: Set<String> = [
        "com.apple.notificationcenterui",
        "com.apple.controlcenter",
        "com.apple.Spotlight",
        "com.apple.dock",
        "com.apple.WindowManager",
    ]

    /// AppleScript application names for browsers we can query the active page URL from.
    private static let browserAppNames: [String: String] = [
        "com.apple.Safari": "Safari",
        "com.apple.SafariTechnologyPreview": "Safari Technology Preview",
        "com.google.Chrome": "Google Chrome",
        "com.google.Chrome.canary": "Google Chrome Canary",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.brave.Browser": "Brave Browser",
        "company.thebrowser.Browser": "Arc",
        "com.vivaldi.Vivaldi": "Vivaldi",
    ]

    /// Off the capture path: query the browser's active page URL + fetch the domain favicon,
    /// then update the entry. Runs on a background queue (the AppleScript is in a subprocess,
    /// so no main-thread block) — the copy itself stays instant.
    private func enrichSource(entryID: UUID, bundleID: String?, fallbackURL: String?) {
        let container = self.modelContainer
        DispatchQueue.global(qos: .utility).async {
            // Prefer the actual browser page URL; fall back to the image's web URL.
            var pageURL: String? = nil
            if let bid = bundleID, Self.browserAppNames[bid] != nil {
                pageURL = self.browserPageURL(bundleID: bid)
            }
            guard let domainSource = pageURL ?? fallbackURL,
                  let host = URL(string: domainSource)?.host, !host.isEmpty else { return }
            let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            let favicon = self.fetchFavicon(domain: domain)
            guard pageURL != nil || favicon != nil else { return }

            DispatchQueue.main.async {
                let context = ModelContext(container)
                let descriptor = FetchDescriptor<ClipboardEntry>(
                    predicate: #Predicate<ClipboardEntry> { $0.id == entryID }
                )
                guard let entry = try? context.fetch(descriptor).first else { return }
                if let pageURL { entry.sourcePageURL = pageURL }
                if let favicon { entry.faviconData = favicon }
                try? context.save()
            }
        }
    }

    /// One-time pass: fetch favicons for recent entries that have a web source but no icon yet.
    private func backfillFavicons() {
        let container = self.modelContainer
        DispatchQueue.global(qos: .background).async {
            let context = ModelContext(container)
            var descriptor = FetchDescriptor<ClipboardEntry>(
                predicate: #Predicate<ClipboardEntry> {
                    $0.faviconData == nil && ($0.sourceURL != nil || $0.sourcePageURL != nil)
                },
                sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
            )
            descriptor.fetchLimit = 60
            guard let entries = try? context.fetch(descriptor) else { return }
            for entry in entries {
                guard let src = entry.sourcePageURL ?? entry.sourceURL,
                      let host = URL(string: src)?.host, !host.isEmpty else { continue }
                let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
                guard let favicon = self.fetchFavicon(domain: domain) else { continue }
                let id = entry.id
                DispatchQueue.main.async {
                    let ctx = ModelContext(container)
                    let d = FetchDescriptor<ClipboardEntry>(predicate: #Predicate<ClipboardEntry> { $0.id == id })
                    if let e = try? ctx.fetch(d).first {
                        e.faviconData = favicon
                        try? ctx.save()
                    }
                }
            }
        }
    }

    /// Query the frontmost browser for its active tab/document URL via AppleScript subprocess.
    private func browserPageURL(bundleID: String?) -> String? {
        guard let bundleID, let appName = Self.browserAppNames[bundleID] else { return nil }
        let isSafari = bundleID.hasPrefix("com.apple.Safari")
        let script = isSafari
            ? "tell application \"\(appName)\" to get URL of front document"
            : "tell application \"\(appName)\" to get URL of active tab of front window"
        return runAppleScript(script)
    }

    /// Fetch a favicon for the domain via icon services (DuckDuckGo, then Google).
    private func fetchFavicon(domain: String) -> Data? {
        let sources = [
            "https://icons.duckduckgo.com/ip3/\(domain).ico",
            "https://www.google.com/s2/favicons?sz=64&domain=\(domain)",
        ]
        for s in sources {
            guard let url = URL(string: s),
                  let data = try? Data(contentsOf: url),
                  data.count > 70,                 // skip empty/placeholder responses
                  NSImage(data: data) != nil else { continue }
            return data
        }
        return nil
    }

    private func runAppleScript(_ script: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch { return nil }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (result?.isEmpty ?? true) ? nil : result
    }

    /// For a rich copy with no plain text (e.g. a PDF page copied from Safari), pull the first
    /// embedded attachment as a preview image and its filename. Returns nil if none found.
    static func richEmbeddedPreview(fromRTFD data: Data) -> (image: NSImage, name: String?)? {
        guard let attr = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtfd],
            documentAttributes: nil
        ) else { return nil }
        // Only treat this as an embedded-file preview if the doc is essentially just the
        // attachment(s) — strip object-replacement chars (U+FFFC) + whitespace; if nothing
        // is left it's a copied file (PDF/image), not rich text that happens to contain images.
        let visible = attr.string
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard visible.isEmpty else { return nil }
        var result: (NSImage, String?)? = nil
        attr.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attr.length)) { value, _, stop in
            guard let attachment = value as? NSTextAttachment else { return }
            let name = attachment.fileWrapper?.preferredFilename
            let image: NSImage? = attachment.fileWrapper?.regularFileContents.flatMap { NSImage(data: $0) }
                ?? attachment.image
            if let image {
                result = (image, name)
                stop.pointee = true
            }
        }
        return result
    }

    /// Recover plain text from the pasteboard's HTML or webarchive (for WebKit-based apps that
    /// leave the plain-text type empty). Returns nil if there's no readable text.
    static func recoverWebText(from pb: NSPasteboard) -> String? {
        var html = pb.data(forType: .html)
        if html?.isEmpty ?? true,
           let wa = pb.data(forType: NSPasteboard.PasteboardType("com.apple.webarchive")),
           let plist = try? PropertyListSerialization.propertyList(from: wa, options: [], format: nil) as? [String: Any],
           let main = plist["WebMainResource"] as? [String: Any] {
            html = main["WebResourceData"] as? Data
        }
        guard let html, !html.isEmpty,
              let attr = try? NSAttributedString(
                data: html,
                options: [.documentType: NSAttributedString.DocumentType.html],
                documentAttributes: nil
              ) else { return nil }
        let text = attr.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Build a clean HTML table from tab-separated / newline-separated text. Used to give
    /// Excel non-contiguous copies a gap-free formatted paste regenerated from the clean text.
    static func htmlTable(fromTabbed text: String) -> Data? {
        let rows = text.components(separatedBy: "\n")
        guard !rows.isEmpty else { return nil }
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        var html = "<table>"
        for row in rows {
            html += "<tr>"
            for cell in row.components(separatedBy: "\t") {
                html += "<td>\(esc(cell))</td>"
            }
            html += "</tr>"
        }
        html += "</table>"
        return html.data(using: .utf8)
    }

    /// Keep only the cells at the given 0-based column positions in every <tr> of an HTML
    /// table, preserving each surviving cell's full markup (and thus Excel's styling).
    /// Strips <col>/<colgroup> so the column count still lines up.
    static func filterHTMLColumns(_ html: String, keep: Set<Int>) -> String {
        guard let trRegex = try? NSRegularExpression(pattern: "<tr\\b[^>]*>.*?</tr>", options: [.dotMatchesLineSeparators, .caseInsensitive]),
              let openRegex = try? NSRegularExpression(pattern: "<tr\\b[^>]*>", options: [.caseInsensitive]),
              let cellRegex = try? NSRegularExpression(pattern: "<t[dh]\\b[^>]*>.*?</t[dh]>", options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return html }
        let ns = html as NSString
        var output = ""
        var cursor = 0
        for tr in trRegex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            output += ns.substring(with: NSRange(location: cursor, length: tr.range.location - cursor))
            let trStr = ns.substring(with: tr.range)
            let trNS = trStr as NSString
            var rebuilt = openRegex.firstMatch(in: trStr, range: NSRange(location: 0, length: trNS.length))
                .map { trNS.substring(with: $0.range) } ?? "<tr>"
            let cells = cellRegex.matches(in: trStr, range: NSRange(location: 0, length: trNS.length))
            for (idx, cell) in cells.enumerated() where keep.contains(idx) {
                rebuilt += trNS.substring(with: cell.range)
            }
            rebuilt += "</tr>"
            output += rebuilt
            cursor = tr.range.location + tr.range.length
        }
        output += ns.substring(from: cursor)
        for pattern in ["<col\\b[^>]*>", "</?colgroup\\b[^>]*>"] {
            if let r = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                output = r.stringByReplacingMatches(in: output, range: NSRange(location: 0, length: (output as NSString).length), withTemplate: "")
            }
        }
        return output
    }

    /// Best-effort HTML → RTF conversion (for storing a formatted history entry).
    static func rtf(fromHTML html: Data) -> Data? {
        guard let attr = try? NSAttributedString(
            data: html,
            options: [.documentType: NSAttributedString.DocumentType.html],
            documentAttributes: nil
        ) else { return nil }
        return try? attr.data(from: NSRange(location: 0, length: attr.length),
                              documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    private func isURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { return false }
        return url.scheme == "http" || url.scheme == "https"
    }

    private func pruneIfNeeded(context: ModelContext) {
        let maxCount = settings.maxHistoryCount
        let descriptor = FetchDescriptor<ClipboardEntry>(
            predicate: #Predicate { !$0.isPinned },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )

        guard let allEntries = try? context.fetch(descriptor),
              allEntries.count > maxCount else { return }

        for entry in allEntries.dropFirst(maxCount) {
            ClipboardImageStore.deleteBlob(for: entry.id, context: context)
            context.delete(entry)
        }
        try? context.save()
    }

    /// Render a small JPEG thumbnail (max ~320pt) for fast list-row display.
    static func makeThumbnail(from data: Data) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        return makeThumbnail(from: image)
    }

    /// Rasterize an image straight into a ≤320px JPEG thumbnail. Drawing directly at the
    /// target size avoids huge intermediate bitmaps (a big PDF page can be an 800MB+ TIFF).
    static func makeThumbnail(from image: NSImage) -> Data? {
        let maxDim: CGFloat = 320
        let w = image.size.width
        let h = image.size.height
        guard w > 0, h > 0 else { return nil }
        let scale = min(maxDim / max(w, h), 1.0)
        let targetW = max(1, Int(w * scale))
        let targetH = max(1, Int(h * scale))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: targetW, pixelsHigh: targetH,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32
        ) else { return nil }
        rep.size = NSSize(width: targetW, height: targetH)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: targetW, height: targetH),
                   from: .zero, operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }

    /// Store full image bytes in a blob row and a small thumbnail on the entry.
    /// Leaves `entry.imageData` nil so list-row fetches don't fault the heavy data.
    private func attachImage(_ data: Data, to entry: ClipboardEntry, context: ModelContext) {
        entry.thumbnailData = Self.makeThumbnail(from: data)
        context.insert(ClipboardImageBlob(id: entry.id, data: data))
    }
}
