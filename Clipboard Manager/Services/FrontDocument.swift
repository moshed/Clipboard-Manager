import AppKit
import ApplicationServices

/// Finds the file on disk behind the frontmost app's window.
///
/// Most document apps (Preview, TextEdit, Excel, Xcode, VS Code, Terminal) publish it as the
/// window's Accessibility `AXDocument` attribute — a `file://` URL string. Finder has no
/// document, so it gives its selection instead. Office apps sometimes report zero windows to
/// Accessibility, so they fall back to AppleScript.
enum FrontDocument {
    private static let finderBundleID = "com.apple.finder"

    /// AppleScript expression for the front document's file, per Office app.
    private static let officeExpressions: [String: String] = [
        "com.microsoft.Excel": "full name of active workbook",
        "com.microsoft.Word": "full name of active document",
        "com.microsoft.Powerpoint": "full name of active presentation",
    ]

    /// The front window's file as a POSIX path (newline-separated for a Finder multi-selection),
    /// or nil when the window has no file on disk.
    static func paths() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let bundleID = app.bundleIdentifier ?? ""
        if bundleID == finderBundleID { return finderSelection() }
        if let path = axDocumentPath(pid: app.processIdentifier) { return path }
        if let expression = officeExpressions[bundleID] {
            return officePath(bundleID: bundleID, expression: expression)
        }
        return nil
    }

    // MARK: - Accessibility

    private static func axDocumentPath(pid: pid_t) -> String? {
        let axApp = AXUIElementCreateApplication(pid)
        // A hung app would otherwise block the main thread for the 6 s default.
        AXUIElementSetMessagingTimeout(axApp, 1.0)
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var window: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, attribute as CFString, &window) == .success,
                  let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { continue }
            var document: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXDocumentAttribute as CFString, &document) == .success
            else { continue }
            let raw: String
            if let string = document as? String {
                raw = string
            } else if let url = document as? URL {
                raw = url.absoluteString
            } else {
                continue
            }
            if let path = existingPath(from: raw) { return path }
        }
        return nil
    }

    /// AXDocument is usually a `file://` URL string, but some apps give a bare path.
    private static func existingPath(from raw: String) -> String? {
        var path = raw
        if raw.hasPrefix("file://") {
            guard let url = URL(string: raw) else { return nil }
            path = url.path
        }
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    // MARK: - AppleScript

    /// Finder: the selected items, else the folder the front window shows, else the Desktop.
    private static func finderSelection() -> String? {
        let script = """
        tell application "Finder"
            set out to ""
            repeat with anItem in (get selection)
                set out to out & POSIX path of (anItem as alias) & linefeed
            end repeat
            if out is not "" then return out
            try
                if (count of windows) > 0 then return POSIX path of (target of front window as alias)
            end try
            return POSIX path of (desktop as alias)
        end tell
        """
        let lines = runScript(script)
            .split(separator: "\n")
            .map { line -> String in
                // Folders come back with a trailing slash; Finder's own "Copy as Pathname" has none.
                line.count > 1 && line.hasSuffix("/") ? String(line.dropLast()) : String(line)
            }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func officePath(bundleID: String, expression: String) -> String? {
        let script = """
        tell application id "\(bundleID)"
            try
                return POSIX path of ((\(expression)) as text)
            on error
                return ""
            end try
        end tell
        """
        return existingPath(from: runScript(script))
    }

    private static func runScript(_ script: String) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return "" }
        task.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
