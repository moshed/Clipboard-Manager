import Foundation
import SwiftData

/// Writes a small JSON copy of every snippet on each launch and keeps the most recent
/// files. Snippets are hand-made and irreplaceable — one accidental folder delete once
/// destroyed a whole folder, and the only way back was scraping freed database pages
/// before the app reused them. A plain file makes recovery a copy instead of forensics.
enum SnippetBackup {
    /// How many timestamped backups to keep.
    static let keepCount = 30

    struct Item: Codable {
        var id: UUID
        var title: String
        var content: String
        var order: Int
        var isFolder: Bool
        var folderID: UUID?
        var iconName: String?
        var hotkeyKeyCode: UInt32?
        var hotkeyModifiers: UInt32?
        var matchDestinationFont: Bool
        var createdAt: Date
        /// Rich text, base64 so the backup stays a plain readable JSON file.
        var rtfBase64: String?
    }

    static var directory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport
            .appendingPathComponent("ClipboardManager", isDirectory: true)
            .appendingPathComponent("SnippetBackups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Snapshot every snippet to a timestamped JSON file, then prune old ones.
    /// Skips writing when nothing changed since the newest backup.
    @discardableResult
    static func run(container: ModelContainer) -> URL? {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<SavedSnippet>()
        descriptor.sortBy = [SortDescriptor(\SavedSnippet.order)]
        guard let snippets = try? context.fetch(descriptor), !snippets.isEmpty else { return nil }

        let items = snippets.map { s in
            Item(id: s.id, title: s.title, content: s.content, order: s.order,
                 isFolder: s.isFolder, folderID: s.folderID, iconName: s.iconName,
                 hotkeyKeyCode: s.hotkeyKeyCode, hotkeyModifiers: s.hotkeyModifiers,
                 matchDestinationFont: s.matchDestinationFont, createdAt: s.createdAt,
                 rtfBase64: s.rtfData?.base64EncodedString())
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return nil }

        // Don't pile up identical copies on every relaunch.
        if let newest = existingBackups().first,
           let previous = try? Data(contentsOf: newest),
           previous == data {
            return newest
        }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let url = directory.appendingPathComponent("snippets-\(stamp.string(from: Date())).json")
        guard (try? data.write(to: url)) != nil else { return nil }

        prune()
        NSLog("[ClipboardManager] Snippet backup: %d snippets -> %@", items.count, url.lastPathComponent)
        return url
    }

    /// Newest first.
    static func existingBackups() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private static func prune() {
        let old = existingBackups().dropFirst(keepCount)
        for url in old { try? FileManager.default.removeItem(at: url) }
    }
}
