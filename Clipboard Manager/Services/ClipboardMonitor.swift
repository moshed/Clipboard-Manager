import AppKit
import SwiftData
import Combine
import Vision

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
            let rect = CGRect(
                x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0
            )
            if rect.contains(cgPoint) {
                return NSRunningApplication(processIdentifier: pid)
            }
        }
        return nil
    }

    func stop() {
        timer?.cancel()
        timer = nil
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

        // Determine source app: prefer app under mouse (catches right-click context menus),
        // then frontmost app, then last tracked active app
        let frontApp = appUnderMouse() ?? NSWorkspace.shared.frontmostApplication ?? lastActiveApp
        let bundleID = frontApp?.bundleIdentifier

        if let bid = bundleID, settings.isExcluded(bid) {
            return
        }

        let appName = frontApp?.localizedName

        let context = ModelContext(modelContainer)

        // Check local file URLs first — only file:// URLs, not http(s):// from browsers
        let fileURLs = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.filter { $0.isFileURL }
        if let urls = fileURLs, !urls.isEmpty {
            let paths = urls.map { $0.path }
            let thumbnail = generateFileThumbnail(for: urls.first!)
            let entry = ClipboardEntry(
                imageData: thumbnail,
                filePaths: paths,
                contentType: .file,
                sourceAppBundleID: bundleID,
                sourceAppName: appName
            )
            context.insert(entry)
            if let imgData = thumbnail {
                performOCR(imageData: imgData, entryID: entry.id)
            }
        } else if let imageData = extractImageData(from: pasteboard) {
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
                imageData: imageData,
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
            performOCR(imageData: imageData, entryID: entry.id)
            NSLog("[ClipboardManager] Image captured. isScreenshot=\(isScreenshot), bundleID=\(bundleID ?? "nil"), types=\(pasteboard.types?.map(\.rawValue) ?? [])")
        } else if let rtfData = pasteboard.data(forType: .rtf),
                  let text = pasteboard.string(forType: .string) {
            let rtfdData = pasteboard.data(forType: .rtfd)
            let types = pasteboard.types?.map(\.rawValue) ?? []
            NSLog("[ClipboardManager] RTF captured: rtf=\(rtfData.count)b, rtfd=\(rtfdData?.count ?? 0)b, types=\(types)")
            let entry = ClipboardEntry(
                textContent: text,
                rtfData: rtfData,
                rtfdData: rtfdData,
                contentType: .rtf,
                sourceAppBundleID: bundleID,
                sourceAppName: appName
            )
            context.insert(entry)
        } else if let text = pasteboard.string(forType: .string) {
            let contentType: ContentType = isURL(text) ? .url : .text
            let entry = ClipboardEntry(
                textContent: text,
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
        let imageTypes: [NSPasteboard.PasteboardType] = [.tiff, .png]
        for type in imageTypes {
            if let data = pasteboard.data(forType: type) {
                if let image = NSImage(data: data), let tiff = image.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    return png
                }
                return data
            }
        }
        return nil
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

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                NSLog("[ClipboardManager] OCR: VNImageRequestHandler failed: \(error)")
                return
            }

            guard let observations = request.results else {
                NSLog("[ClipboardManager] OCR: No results")
                return
            }

            let text = observations
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")

            NSLog("[ClipboardManager] OCR: Found \(observations.count) observations, text length=\(text.count)")
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
            context.delete(entry)
        }
        try? context.save()
    }
}
