import AppKit
import Foundation

/// Mirrors clipboard IMAGES and FILES into a real folder (~/Clipboard by default) so any
/// app's file picker or upload dialog can reach them. Text, RTF and URLs are deliberately
/// skipped — the folder is for things you'd attach, not things you'd paste.
enum ClipboardFolder {
    /// Newest files to keep; older ones are pruned so the folder stays browsable.
    static let keepCount = 60

    static var url: URL {
        if let custom = SettingsManager.shared.clipboardFolderPath, !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Clipboard", isDirectory: true)
    }

    @discardableResult
    static func ensureFolder() -> URL {
        let dir = url
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Save PNG image bytes into the folder. `label` becomes part of the file name.
    @discardableResult
    static func saveImage(_ data: Data, label: String? = nil) -> URL? {
        guard SettingsManager.shared.clipboardFolderEnabled else { return nil }
        let dir = ensureFolder()
        let name = sanitize(label) ?? "Image"
        guard let target = uniqueURL(in: dir, base: name, ext: "png") else { return nil }
        guard (try? data.write(to: target)) != nil else { return nil }
        prune()
        return target
    }

    /// Copy real files that were put on the clipboard (Finder copies, attachments, …).
    @discardableResult
    static func saveFiles(_ paths: [String]) -> [URL] {
        guard SettingsManager.shared.clipboardFolderEnabled else { return [] }
        let dir = ensureFolder()
        var saved: [URL] = []
        let fm = FileManager.default
        for path in paths {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let source = URL(fileURLWithPath: path)
            let base = source.deletingPathExtension().lastPathComponent
            guard let target = uniqueURL(in: dir, base: base, ext: source.pathExtension) else { continue }
            if (try? fm.copyItem(at: source, to: target)) != nil { saved.append(target) }
        }
        if !saved.isEmpty { prune() }
        return saved
    }

    // MARK: - Private

    private static func sanitize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = raw
            .components(separatedBy: .newlines).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-") ?? ""
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(40))
    }

    private static func uniqueURL(in dir: URL, base: String, ext: String) -> URL? {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let prefix = "\(base) \(stamp.string(from: Date()))"
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        var candidate = dir.appendingPathComponent(prefix + suffix)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(prefix) (\(n))\(suffix)")
            n += 1
            if n > 50 { return nil }
        }
        return candidate
    }

    /// Keep the folder to `keepCount` newest files.
    private static func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return a > b
        }
        for old in sorted.dropFirst(keepCount) { try? fm.removeItem(at: old) }
    }
}
