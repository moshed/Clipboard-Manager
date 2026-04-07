import SwiftData
import Foundation

@Model
final class SavedSnippet {
    var id: UUID
    var title: String
    var content: String
    var order: Int
    var hotkeyKeyCode: UInt32?
    var hotkeyModifiers: UInt32?
    var createdAt: Date

    /// If true, this is a folder that groups other snippets
    var isFolder: Bool = false

    /// ID of the folder this snippet belongs to (nil = top-level)
    var folderID: UUID?

    /// SF Symbol name for the snippet icon
    var iconName: String?

    /// RTF data for rich text content (nil = plain text only)
    var rtfData: Data?

    /// When true, paste as plain text so the snippet inherits the destination app's font/size
    var matchDestinationFont: Bool = true

    var keyCombo: KeyCombo? {
        get {
            guard let kc = hotkeyKeyCode, let mods = hotkeyModifiers else { return nil }
            return KeyCombo(keyCode: kc, modifiers: mods)
        }
        set {
            hotkeyKeyCode = newValue?.keyCode
            hotkeyModifiers = newValue?.modifiers
        }
    }

    init(title: String, content: String = "", order: Int = 0, isFolder: Bool = false, folderID: UUID? = nil) {
        self.id = UUID()
        self.title = title
        self.content = content
        self.order = order
        self.isFolder = isFolder
        self.folderID = folderID
        self.createdAt = Date()
    }
}
