import Foundation
import Carbon

struct CustomTransformation: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var pattern: String
    var replacement: String
    var isEnabled: Bool = true
    var isBuiltIn: Bool = false
}

extension CustomTransformation {
    static let builtInUppercase = CustomTransformation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "UPPERCASE", pattern: "", replacement: "", isBuiltIn: true)
    static let builtInLowercase = CustomTransformation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "lowercase", pattern: "", replacement: "", isBuiltIn: true)
    static let builtInCapitalCase = CustomTransformation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, name: "Capital Case", pattern: "", replacement: "", isBuiltIn: true)

    static let defaultBuiltIns: [CustomTransformation] = [builtInUppercase, builtInLowercase, builtInCapitalCase]
}

struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    var displayString: String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(keyCodeToString(keyCode))
        return parts.joined()
    }

    static let defaultToggle = KeyCombo(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey))
    static let defaultCopyPlain = KeyCombo(keyCode: UInt32(kVK_Return), modifiers: 0)
    static let defaultCopyFormatted = KeyCombo(keyCode: UInt32(kVK_Return), modifiers: UInt32(shiftKey))
    static let defaultDelete = KeyCombo(keyCode: UInt32(kVK_Delete), modifiers: UInt32(cmdKey))
    static let defaultExcelClean = KeyCombo(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey | optionKey))
    static let defaultSaveImage = KeyCombo(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey))
    static let defaultExpand: KeyCombo? = nil
    static let none = KeyCombo(keyCode: UInt32.max, modifiers: UInt32.max)

    var isReturn: Bool { keyCode == UInt32(kVK_Return) }
    var isSpace: Bool { keyCode == UInt32(kVK_Space) }
    var hasNoModifiers: Bool { modifiers == 0 }
    var hasOnlyShift: Bool { modifiers == UInt32(shiftKey) }

    func matches(keyCode kc: UInt32, modifiers mods: UInt32) -> Bool {
        self.keyCode == kc && self.modifiers == mods
    }

    private func keyCodeToString(_ code: UInt32) -> String {
        let map: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
            UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
            UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
            UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
            UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
            UInt32(kVK_ANSI_9): "9",
            UInt32(kVK_Space): "Space", UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥",
            UInt32(kVK_Delete): "⌫", UInt32(kVK_Escape): "⎋",
            UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
            UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
            UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
            UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
            UInt32(kVK_ANSI_Minus): "-", UInt32(kVK_ANSI_Equal): "=",
            UInt32(kVK_ANSI_LeftBracket): "[", UInt32(kVK_ANSI_RightBracket): "]",
            UInt32(kVK_ANSI_Semicolon): ";", UInt32(kVK_ANSI_Quote): "'",
            UInt32(kVK_ANSI_Comma): ",", UInt32(kVK_ANSI_Period): ".",
            UInt32(kVK_ANSI_Slash): "/", UInt32(kVK_ANSI_Backslash): "\\",
            UInt32(kVK_ANSI_Grave): "`",
            UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
            UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
        ]
        return map[code] ?? "?"
    }
}

class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    @Published var excludedBundleIDs: Set<String> {
        didSet { UserDefaults.standard.set(Array(excludedBundleIDs), forKey: "excludedBundleIDs") }
    }

    @Published var defaultCopyPlainText: Bool {
        didSet { UserDefaults.standard.set(defaultCopyPlainText, forKey: "defaultCopyPlainText") }
    }

    @Published var maxHistoryCount: Int {
        didSet { UserDefaults.standard.set(maxHistoryCount, forKey: "maxHistoryCount") }
    }

    @Published var dismissOnClickOutside: Bool {
        didSet { UserDefaults.standard.set(dismissOnClickOutside, forKey: "dismissOnClickOutside") }
    }

    @Published var instantTyping: Bool {
        didSet { UserDefaults.standard.set(instantTyping, forKey: "instantTyping") }
    }

    /// Toolbar display: "both", "iconOnly", "textOnly"
    @Published var toolbarDisplay: String {
        didSet { UserDefaults.standard.set(toolbarDisplay, forKey: "toolbarDisplay") }
    }

    @Published var searchShortcut: KeyCombo? {
        didSet { saveOptionalKeyCombo(searchShortcut, forKey: "searchShortcut") }
    }

    @Published var filterShortcut: KeyCombo? {
        didSet { saveOptionalKeyCombo(filterShortcut, forKey: "filterShortcut") }
    }

    @Published var tabToggleShortcut: KeyCombo? {
        didSet { saveOptionalKeyCombo(tabToggleShortcut, forKey: "tabToggleShortcut") }
    }

    @Published var tabBackwardShortcut: KeyCombo? {
        didSet { saveOptionalKeyCombo(tabBackwardShortcut, forKey: "tabBackwardShortcut") }
    }

    /// Mouse paste action: "singleClick", "doubleClick", "singleTap"
    @Published var mouseAction: String {
        didSet { UserDefaults.standard.set(mouseAction, forKey: "mouseAction") }
    }

    @Published var snippetPreviewLines: Int {
        didSet { UserDefaults.standard.set(snippetPreviewLines, forKey: "snippetPreviewLines") }
    }

    @Published var excelCleanup: Bool {
        didSet { UserDefaults.standard.set(excelCleanup, forKey: "excelCleanup") }
    }

    @Published var excelCopyAsText: Bool {
        didSet { UserDefaults.standard.set(excelCopyAsText, forKey: "excelCopyAsText") }
    }

    /// Global shortcut to copy the current Excel selection and strip non-contiguous gaps.
    @Published var excelCleanShortcut: KeyCombo? {
        didSet {
            saveOptionalKeyCombo(excelCleanShortcut, forKey: "excelCleanShortcut")
            onExcelCleanShortcutChanged?()
        }
    }

    @Published var toggleShortcut: KeyCombo {
        didSet { saveKeyCombo(toggleShortcut, forKey: "toggleShortcut") }
    }

    @Published var copyPlainShortcut: KeyCombo? {
        didSet { saveOptionalKeyCombo(copyPlainShortcut, forKey: "copyPlainShortcut") }
    }

    @Published var copyFormattedShortcut: KeyCombo? {
        didSet { saveOptionalKeyCombo(copyFormattedShortcut, forKey: "copyFormattedShortcut") }
    }

    @Published var deleteShortcut: KeyCombo? {
        didSet { saveOptionalKeyCombo(deleteShortcut, forKey: "deleteShortcut") }
    }

    @Published var expandShortcut: KeyCombo? {
        didSet { saveOptionalKeyCombo(expandShortcut, forKey: "expandShortcut") }
    }


    @Published var transformShortcut: KeyCombo? {
        didSet { saveOptionalKeyCombo(transformShortcut, forKey: "transformShortcut") }
    }

    /// In-app shortcut to save the selected image entry(ies) to `imageSaveFolderURL`.
    @Published var saveImageShortcut: KeyCombo? {
        didSet { saveOptionalKeyCombo(saveImageShortcut, forKey: "saveImageShortcut") }
    }

    /// Folder where the "Save Image" action writes PNGs. nil → ~/Downloads.
    @Published var imageSaveFolderPath: String? {
        didSet { UserDefaults.standard.set(imageSaveFolderPath, forKey: "imageSaveFolderPath") }
    }

    /// Resolved destination folder for saved images (defaults to ~/Downloads).
    var imageSaveFolderURL: URL {
        if let p = imageSaveFolderPath, !p.isEmpty {
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    @Published var customTransformations: [CustomTransformation] {
        didSet {
            if let data = try? JSONEncoder().encode(customTransformations) {
                UserDefaults.standard.set(data, forKey: "customTransformations")
            }
        }
    }

    @Published var pasteOrderedShortcut: KeyCombo? {
        didSet { saveOptionalKeyCombo(pasteOrderedShortcut, forKey: "pasteOrderedShortcut") }
    }

    /// "newline", "comma", "semicolon", "space", "dash", "tab", "custom"
    @Published var multiPasteSeparator: String {
        didSet { UserDefaults.standard.set(multiPasteSeparator, forKey: "multiPasteSeparator") }
    }

    @Published var multiPasteCustomSeparator: String {
        didSet { UserDefaults.standard.set(multiPasteCustomSeparator, forKey: "multiPasteCustomSeparator") }
    }

    /// Separator used when pasting with Shift held (Shift+Enter).
    @Published var multiPasteAltSeparator: String {
        didSet { UserDefaults.standard.set(multiPasteAltSeparator, forKey: "multiPasteAltSeparator") }
    }

    @Published var multiPasteAltCustomSeparator: String {
        didSet { UserDefaults.standard.set(multiPasteAltCustomSeparator, forKey: "multiPasteAltCustomSeparator") }
    }

    static func separatorText(_ kind: String, custom: String) -> String {
        switch kind {
        case "comma": return ", "
        case "semicolon": return "; "
        case "space": return " "
        case "dash": return " - "
        case "tab": return "\t"
        case "custom": return unescape(custom)
        default: return "\n"
        }
    }

    /// A custom separator is typed into a single-line field, so a newline can only be
    /// expressed as an escape. Turn `\n` / `\t` / `\r` / `\\` into the real characters.
    static func unescape(_ s: String) -> String {
        var out = ""
        var iterator = s.makeIterator()
        while let c = iterator.next() {
            guard c == "\\", let next = iterator.next() else {
                out.append(c)
                continue
            }
            switch next {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "\\": out.append("\\")
            default:
                out.append(c)
                out.append(next)
            }
        }
        return out
    }

    var resolvedSeparator: String {
        Self.separatorText(multiPasteSeparator, custom: multiPasteCustomSeparator)
    }

    var resolvedAltSeparator: String {
        Self.separatorText(multiPasteAltSeparator, custom: multiPasteAltCustomSeparator)
    }

    var onToggleShortcutChanged: (() -> Void)?
    var onExcelCleanShortcutChanged: (() -> Void)?
    var onDismissSettingChanged: (() -> Void)?

    private init() {
        let excluded = UserDefaults.standard.stringArray(forKey: "excludedBundleIDs") ?? []
        self.excludedBundleIDs = Set(excluded)
        self.defaultCopyPlainText = UserDefaults.standard.object(forKey: "defaultCopyPlainText") as? Bool ?? true
        self.maxHistoryCount = UserDefaults.standard.object(forKey: "maxHistoryCount") as? Int ?? 1000
        self.dismissOnClickOutside = UserDefaults.standard.object(forKey: "dismissOnClickOutside") as? Bool ?? true
        self.instantTyping = UserDefaults.standard.object(forKey: "instantTyping") as? Bool ?? true
        self.toolbarDisplay = UserDefaults.standard.string(forKey: "toolbarDisplay") ?? "both"
        self.searchShortcut = SettingsManager.loadKeyCombo(forKey: "searchShortcut") ?? KeyCombo(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(cmdKey))
        self.filterShortcut = SettingsManager.loadKeyCombo(forKey: "filterShortcut") ?? KeyCombo(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(cmdKey | shiftKey))
        self.tabToggleShortcut = SettingsManager.loadKeyCombo(forKey: "tabToggleShortcut") ?? KeyCombo(keyCode: UInt32(kVK_Tab), modifiers: 0)
        self.tabBackwardShortcut = SettingsManager.loadKeyCombo(forKey: "tabBackwardShortcut") ?? KeyCombo(keyCode: UInt32(kVK_Tab), modifiers: UInt32(shiftKey))
        self.snippetPreviewLines = UserDefaults.standard.object(forKey: "snippetPreviewLines") as? Int ?? 2
        self.excelCleanup = UserDefaults.standard.object(forKey: "excelCleanup") as? Bool ?? true
        self.excelCopyAsText = UserDefaults.standard.object(forKey: "excelCopyAsText") as? Bool ?? true
        self.excelCleanShortcut = SettingsManager.loadKeyCombo(forKey: "excelCleanShortcut") ?? .defaultExcelClean
        self.mouseAction = UserDefaults.standard.string(forKey: "mouseAction") ?? "singleClick"
        self.toggleShortcut = SettingsManager.loadKeyCombo(forKey: "toggleShortcut") ?? .defaultToggle
        self.copyPlainShortcut = SettingsManager.loadKeyCombo(forKey: "copyPlainShortcut") ?? .defaultCopyPlain
        self.copyFormattedShortcut = SettingsManager.loadKeyCombo(forKey: "copyFormattedShortcut") ?? .defaultCopyFormatted
        let loadedDelete = SettingsManager.loadKeyCombo(forKey: "deleteShortcut")
        let oldDefaultDelete = KeyCombo(keyCode: UInt32(kVK_Delete), modifiers: UInt32(shiftKey))
        if loadedDelete == oldDefaultDelete {
            self.deleteShortcut = .defaultDelete
        } else {
            self.deleteShortcut = loadedDelete ?? .defaultDelete
        }
        self.expandShortcut = SettingsManager.loadKeyCombo(forKey: "expandShortcut")
        self.transformShortcut = SettingsManager.loadKeyCombo(forKey: "transformShortcut")
        self.saveImageShortcut = SettingsManager.loadKeyCombo(forKey: "saveImageShortcut") ?? .defaultSaveImage
        self.imageSaveFolderPath = UserDefaults.standard.string(forKey: "imageSaveFolderPath")
        if let data = UserDefaults.standard.data(forKey: "customTransformations"),
           let transforms = try? JSONDecoder().decode([CustomTransformation].self, from: data) {
            // Ensure built-ins exist (for existing users upgrading)
            var list = transforms
            for builtIn in CustomTransformation.defaultBuiltIns {
                if !list.contains(where: { $0.id == builtIn.id }) {
                    list.insert(builtIn, at: 0)
                }
            }
            self.customTransformations = list
        } else {
            self.customTransformations = CustomTransformation.defaultBuiltIns
        }
        self.pasteOrderedShortcut = SettingsManager.loadKeyCombo(forKey: "pasteOrderedShortcut")
        self.multiPasteSeparator = UserDefaults.standard.string(forKey: "multiPasteSeparator") ?? "newline"
        self.multiPasteCustomSeparator = UserDefaults.standard.string(forKey: "multiPasteCustomSeparator") ?? " | "
        self.multiPasteAltSeparator = UserDefaults.standard.string(forKey: "multiPasteAltSeparator") ?? "comma"
        self.multiPasteAltCustomSeparator = UserDefaults.standard.string(forKey: "multiPasteAltCustomSeparator") ?? " | "
    }

    private func saveOptionalKeyCombo(_ combo: KeyCombo?, forKey key: String) {
        if let combo = combo {
            saveKeyCombo(combo, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func isExcluded(_ bundleID: String) -> Bool {
        excludedBundleIDs.contains(bundleID)
    }

    func toggleExclusion(_ bundleID: String) {
        if excludedBundleIDs.contains(bundleID) {
            excludedBundleIDs.remove(bundleID)
        } else {
            excludedBundleIDs.insert(bundleID)
        }
    }

    private func saveKeyCombo(_ combo: KeyCombo, forKey key: String) {
        if let data = try? JSONEncoder().encode(combo) {
            UserDefaults.standard.set(data, forKey: key)
        }
        if key == "toggleShortcut" {
            onToggleShortcutChanged?()
        }
    }

    private static func loadKeyCombo(forKey key: String) -> KeyCombo? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(KeyCombo.self, from: data)
    }
}
