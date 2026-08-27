import SwiftUI
import SwiftData
import ServiceManagement
import Carbon
import UniformTypeIdentifiers
import CoreLocation

struct SettingsView: View {
    @ObservedObject var settings = SettingsManager.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var settingsTab: Int = 0
    var onDismiss: (() -> Void)? = nil
    var onClearAll: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Custom tab bar with icons
            HStack(spacing: 2) {
                settingsTabButton(0, icon: "rectangle.3.group", label: "General")
                settingsTabButton(1, icon: "command", label: "Shortcuts")
                settingsTabButton(2, icon: "minus.circle.fill", label: "Excluded")
                settingsTabButton(3, icon: "wand.and.stars", label: "Transform")
            }
            .padding(4)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 8)

            // Tab content
            switch settingsTab {
            case 0:
                generalTab
            case 1:
                shortcutsTab
            case 2:
                ExcludedAppsView(settings: settings)
            default:
                TransformationsSettingsView(settings: settings)
            }
        }
    }

    private func settingsTabButton(_ tab: Int, icon: String, label: String) -> some View {
        let isActive = settingsTab == tab
        let display = settings.toolbarDisplay
        return Button {
            settingsTab = tab
        } label: {
            VStack(spacing: 3) {
                if display != "textOnly" {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .medium))
                }
                if display != "iconOnly" {
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .frame(minWidth: display == "iconOnly" ? 44 : 70)
            .padding(.horizontal, display == "iconOnly" ? 8 : 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? Color(nsColor: .controlAccentColor).opacity(0.15) : Color.clear)
            )
            .foregroundStyle(isActive ? Color(nsColor: .controlAccentColor) : .secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - General Tab

    private var generalTab: some View {
        GeneralSettingsView(settings: settings, launchAtLogin: $launchAtLogin, onClearAll: onClearAll)
    }

    // MARK: - Shortcuts Tab

    private var shortcutsTab: some View {
        ShortcutsSettingsView(settings: settings)
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var settings: SettingsManager
    @ObservedObject private var location = LocationProvider.shared
    @Binding var launchAtLogin: Bool
    var onClearAll: (() -> Void)?
    @State private var historyText: String = ""
    @State private var showClearConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Launch at Login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    do {
                        if newValue {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        launchAtLogin = !newValue
                    }
                }

            Toggle("Default to Plain Text Copy", isOn: $settings.defaultCopyPlainText)

            Toggle("Dismiss When Clicking Outside", isOn: $settings.dismissOnClickOutside)
                .onChange(of: settings.dismissOnClickOutside) { _, _ in
                    settings.onDismissSettingChanged?()
                }

            Toggle("Instant Typing to Search", isOn: $settings.instantTyping)
                .help("When on, typing immediately filters the list. When off, use a shortcut to focus the search field.")

            Toggle("Excel Cleanup", isOn: $settings.excelCleanup)

            if settings.excelCleanup {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Copy as text instead of image", isOn: $settings.excelCopyAsText)
                    Text("Excel copies include an image. This captures the text content instead.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 20)
                }
                .padding(.leading, 20)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Location")
                    Spacer()
                    locationControl
                }
                Text("Used by the \u{007B}\u{007B}latlon\u{007D}\u{007D} snippet token to insert your current coordinates.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Save Images To")
                    Spacer()
                    Button(settings.imageSaveFolderURL.lastPathComponent) { chooseImageSaveFolder() }
                }
                Text(settings.imageSaveFolderURL.path)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            settingsRow("Toolbar Display") {
                Picker("", selection: $settings.toolbarDisplay) {
                    Text("Icons & Text").tag("both")
                    Text("Icons Only").tag("iconOnly")
                    Text("Text Only").tag("textOnly")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 150)
            }

            settingsRow("Paste on Mouse") {
                Picker("", selection: $settings.mouseAction) {
                    Text("Single Click").tag("singleClick")
                    Text("Double Click").tag("doubleClick")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 150)
            }

            VStack(alignment: .leading, spacing: 6) {
                settingsRow("Multi-Paste Separator") {
                    Picker("", selection: $settings.multiPasteSeparator) {
                        separatorOptions
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 150)
                }

                if settings.multiPasteSeparator == "custom" {
                    settingsRow("Custom Separator") {
                        ClearableTextField(text: $settings.multiPasteCustomSeparator, placeholder: " | ")
                            .frame(width: 150)
                    }
                    .padding(.leading, 20)
                }

                settingsRow("Shift+Enter Separator") {
                    Picker("", selection: $settings.multiPasteAltSeparator) {
                        separatorOptions
                        Divider()
                        Text("Ask Each Time").tag("ask")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 150)
                }

                // "Ask Each Time" offers Custom as one of its choices, so keep the field editable
                if settings.multiPasteAltSeparator == "custom" || settings.multiPasteAltSeparator == "ask" {
                    settingsRow("Custom Shift Separator") {
                        ClearableTextField(text: $settings.multiPasteAltCustomSeparator, placeholder: " | ")
                            .frame(width: 150)
                    }
                    .padding(.leading, 20)
                }

                Text("Enter pastes selected items in the order you picked them. Shift+Enter pastes the same items with the alternate separator. In a custom separator, \\n is a new line and \\t is a tab.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            settingsRow("Snippet Preview Lines") {
                Picker("", selection: $settings.snippetPreviewLines) {
                    Text("None").tag(0)
                    Text("1").tag(1)
                    Text("2").tag(2)
                    Text("3").tag(3)
                    Text("5").tag(5)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 150)
            }

            settingsRow("Max History Entries") {
                ClearableTextField(text: $historyText, placeholder: "1000")
                    .frame(width: 150)
                    .onChange(of: historyText) { _, newValue in
                        if let val = Int(newValue), val >= 10 {
                            settings.maxHistoryCount = val
                        }
                    }
            }

            Divider()

            SnippetBackupView()

            Divider()

            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                HStack {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                    Text("Clear All Clipboard History")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .alert("Clear All History?", isPresented: $showClearConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Clear All", role: .destructive) {
                    onClearAll?()
                }
            } message: {
                Text("This will permanently delete all clipboard history. Pinned items will also be removed.")
            }
        }
        .padding(20)
        .onAppear {
            historyText = "\(settings.maxHistoryCount)"
        }
    }

    @ViewBuilder
    private var locationControl: some View {
        switch location.authStatus {
        case .authorizedAlways, .authorized:
            Label("Enabled", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        case .denied, .restricted:
            Button("Open System Settings…") { LocationProvider.shared.requestAccess() }
                .help("Location was denied. Enable Clipboard Manager under Privacy & Security → Location Services.")
        default: // notDetermined
            Button("Enable Location…") { LocationProvider.shared.requestAccess() }
        }
    }

    private func chooseImageSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = settings.imageSaveFolderURL
        if panel.runModal() == .OK, let url = panel.url {
            settings.imageSaveFolderPath = url.path
        }
    }

    private func settingsRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
            Spacer()
            content()
        }
    }

    @ViewBuilder
    private var separatorOptions: some View {
        Text("New Line").tag("newline")
        Text("Comma").tag("comma")
        Text("Semicolon").tag("semicolon")
        Text("Space").tag("space")
        Text("Dash").tag("dash")
        Text("Tab").tag("tab")
        Text("Custom").tag("custom")
    }
}

struct ShortcutsSettingsView: View {
    @ObservedObject var settings: SettingsManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Global section
            Text("Global")
                .font(.system(size: 14, weight: .bold))

            ShortcutRow(label: "Toggle Clipboard Manager", keyCombo: $settings.toggleShortcut, requireModifier: true, defaultCombo: .defaultToggle)

            VStack(alignment: .leading, spacing: 2) {
                OptionalShortcutRow(label: "Clean Excel Selection", keyCombo: $settings.excelCleanShortcut, requireModifier: true)
                Text("In Excel, copies the current selection and strips non-contiguous row/column gaps.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }

            VStack(alignment: .leading, spacing: 2) {
                OptionalShortcutRow(label: "Save Clipboard Image to Finder", keyCombo: $settings.saveToFinderShortcut, requireModifier: true)
                Text("In Finder, saves the clipboard image as a PNG into the front window's folder and selects it. Only active while Finder is frontmost.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }

            Divider()

            // In-App section
            Text("In-App")
                .font(.system(size: 14, weight: .bold))

            OptionalShortcutRow(label: "Copy Plain Text", keyCombo: $settings.copyPlainShortcut, requireModifier: false)
            VStack(alignment: .leading, spacing: 2) {
                OptionalShortcutRow(label: "Secondary Copy", keyCombo: $settings.copyFormattedShortcut, requireModifier: false)
                Text("Copies with formatting, or the path/address for files and images.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 2) {
                OptionalShortcutRow(label: "Paste in Selection Order", keyCombo: $settings.pasteOrderedShortcut, requireModifier: false)
                Text("Pastes multiple selected items in the order they were clicked.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            OptionalShortcutRow(label: "Transform", keyCombo: $settings.transformShortcut, requireModifier: false)
            VStack(alignment: .leading, spacing: 2) {
                OptionalShortcutRow(label: "Save Image to Folder", keyCombo: $settings.saveImageShortcut, requireModifier: true)
                Text("Saves the selected image entry to the folder set in General.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            OptionalShortcutRow(label: "Delete", keyCombo: $settings.deleteShortcut, requireModifier: false)
            OptionalShortcutRow(label: "Preview", keyCombo: $settings.expandShortcut, requireModifier: false)
            OptionalShortcutRow(label: "Focus Search", keyCombo: $settings.searchShortcut, requireModifier: false)
            OptionalShortcutRow(label: "Toggle Filters", keyCombo: $settings.filterShortcut, requireModifier: true)

            Divider()

            Text("Navigation")
                .font(.system(size: 14, weight: .bold))

            OptionalShortcutRow(label: "Next Tab", keyCombo: $settings.tabToggleShortcut, requireModifier: false)
            OptionalShortcutRow(label: "Previous Tab", keyCombo: $settings.tabBackwardShortcut, requireModifier: false)
        }
        .padding(20)
    }
}

struct OptionalShortcutRow: View {
    let label: String
    @Binding var keyCombo: KeyCombo?
    let requireModifier: Bool

    private var nonOptionalBinding: Binding<KeyCombo> {
        Binding<KeyCombo>(
            get: { keyCombo ?? KeyCombo.none },
            set: { keyCombo = $0 }
        )
    }

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
            Spacer()
            if keyCombo != nil {
                ShortcutRecorderView(keyCombo: nonOptionalBinding, requireModifier: requireModifier)
                Button {
                    keyCombo = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                ShortcutRecorderView(keyCombo: nonOptionalBinding, requireModifier: requireModifier, startEmpty: true)
            }
        }
    }
}

struct ShortcutRow: View {
    let label: String
    @Binding var keyCombo: KeyCombo
    let requireModifier: Bool
    var defaultCombo: KeyCombo? = nil

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
            Spacer()
            ShortcutRecorderView(keyCombo: $keyCombo, requireModifier: requireModifier)
            if let defaultCombo, keyCombo != defaultCombo {
                Button {
                    keyCombo = defaultCombo
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reset to default")
            }
        }
    }
}

struct ShortcutRecorderView: View {
    @Binding var keyCombo: KeyCombo
    var requireModifier: Bool = true
    var startEmpty: Bool = false
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            if isRecording {
                stopRecording()
            } else {
                startRecording()
            }
        } label: {
            HStack(spacing: 4) {
                if isRecording {
                    Image(systemName: "record.circle")
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse, isActive: true)
                    Text("Press keys...")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.red)
                } else if startEmpty {
                    Text("None")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    Text(keyCombo.displayString)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isRecording ? Color.red.opacity(0.1) : Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isRecording ? Color.red.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.carbonFlags

            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return nil
            }

            if requireModifier {
                guard modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 else {
                    return nil
                }
            }

            keyCombo = KeyCombo(keyCode: UInt32(event.keyCode), modifiers: modifiers)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }
}

extension NSEvent.ModifierFlags {
    var carbonFlags: UInt32 {
        var flags: UInt32 = 0
        if contains(.command) { flags |= UInt32(cmdKey) }
        if contains(.option) { flags |= UInt32(optionKey) }
        if contains(.control) { flags |= UInt32(controlKey) }
        if contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }
}

// MARK: - Transformations Settings

struct TransformationsSettingsView: View {
    @ObservedObject var settings: SettingsManager
    @State private var newName = ""
    @State private var newPattern = ""
    @State private var newReplacement = ""
    @State private var testInput = ""
    @State private var editingID: UUID?

    private var testResult: String {
        guard let regex = try? NSRegularExpression(pattern: newPattern) else {
            return "Invalid regex"
        }
        let range = NSRange(testInput.startIndex..., in: testInput)
        let matches = regex.matches(in: testInput, range: range)
        var result = testInput
        for match in matches.reversed() {
            guard match.range.length > 0 else { continue }
            let replacement = regex.replacementString(for: match, in: result, offset: 0, template: newReplacement)
            let start = result.index(result.startIndex, offsetBy: match.range.location)
            let end = result.index(start, offsetBy: match.range.length)
            result.replaceSubrange(start..<end, with: replacement)
        }
        return result
    }

    private var testResultIsError: Bool {
        (try? NSRegularExpression(pattern: newPattern)) == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Custom Transformations")
                .font(.system(size: 14, weight: .bold))

            Text("Define regex-based text transformations. Use $1, $2 for capture groups in the replacement.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            List {
                ForEach(settings.customTransformations) { transform in
                    transformRow(transform)
                }
                .onMove { from, to in
                    settings.customTransformations.move(fromOffsets: from, toOffset: to)
                }
            }
            .listStyle(.plain)
            .frame(minHeight: CGFloat(settings.customTransformations.count * 36 + 8), maxHeight: 300)

            Divider()

            HStack {
                Text(editingID != nil ? "Editing" : "Add New")
                    .font(.system(size: 12, weight: .semibold))
                if editingID != nil {
                    Button("Cancel") { clearForm() }
                        .font(.system(size: 11))
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }

            labeledField("Name", field: ClearableTextField(text: $newName, placeholder: ""))
            labeledField("Pattern", field: MonoTextField(text: $newPattern, placeholder: ""))
            labeledField("Replace", field: MonoTextField(text: $newReplacement, placeholder: ""))
            labeledField("Test", field: ClearableTextField(text: $testInput, placeholder: ""))

            if !testInput.isEmpty && !newPattern.isEmpty {
                HStack(spacing: 6) {
                    Text("Result")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 55, alignment: .trailing)
                    Text(testResult)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(testResultIsError ? .red : .primary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.03))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }

            Button {
                saveNewTransform()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 12))
                    Text(editingID != nil ? "Update" : "Save")
                        .font(.system(size: 13, weight: .medium))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(newName.isEmpty || newPattern.isEmpty)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(20)
    }

    private func saveNewTransform() {
        guard !newName.isEmpty, !newPattern.isEmpty else { return }
        if let id = editingID,
           let idx = settings.customTransformations.firstIndex(where: { $0.id == id }) {
            settings.customTransformations[idx].name = newName
            settings.customTransformations[idx].pattern = newPattern
            settings.customTransformations[idx].replacement = newReplacement
        } else {
            let t = CustomTransformation(name: newName, pattern: newPattern, replacement: newReplacement)
            settings.customTransformations.append(t)
        }
        clearForm()
    }

    private func clearForm() {
        editingID = nil
        newName = ""
        newPattern = ""
        newReplacement = ""
        testInput = ""
    }

    private func transformRow(_ transform: CustomTransformation) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Toggle("", isOn: Binding(
                get: { transform.isEnabled },
                set: { newValue in
                    if let idx = settings.customTransformations.firstIndex(where: { $0.id == transform.id }) {
                        settings.customTransformations[idx].isEnabled = newValue
                    }
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.mini)

            Text(transform.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(transform.isEnabled ? .primary : .secondary)

            Spacer()

            if transform.isBuiltIn {
                Text("Built-in")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                Button {
                    editingID = transform.id
                    newName = transform.name
                    newPattern = transform.pattern
                    newReplacement = transform.replacement
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Button {
                    if editingID == transform.id { clearForm() }
                    settings.customTransformations.removeAll { $0.id == transform.id }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(editingID == transform.id ? Color.accentColor.opacity(0.1) : Color.clear)
    }

    private func labeledField<F: View>(_ label: String, field: F) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 55, alignment: .trailing)
            field
        }
    }

}

// MARK: - Monospaced Text Field

struct MonoTextField: View {
    @Binding var text: String
    var placeholder: String = ""

    var body: some View {
        HStack(spacing: 4) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Clearable Text Field

struct ClearableTextField: View {
    @Binding var text: String
    var placeholder: String = ""

    var body: some View {
        HStack(spacing: 4) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Snippet Export/Import

struct BackupData: Codable {
    var snippets: [SnippetJSON]
    var settings: SettingsJSON?

    struct SnippetJSON: Codable {
        var id: UUID
        var title: String
        var content: String
        var order: Int
        var isFolder: Bool
        var folderID: UUID?
        var iconName: String?
        var hotkeyKeyCode: UInt32?
        var hotkeyModifiers: UInt32?
        var rtfDataBase64: String?
        var createdAt: Date
    }

    struct SettingsJSON: Codable {
        var defaultCopyPlainText: Bool?
        var maxHistoryCount: Int?
        var dismissOnClickOutside: Bool?
        var instantTyping: Bool?
        var toolbarDisplay: String?
        var mouseAction: String?
        var snippetPreviewLines: Int?
        var multiPasteSeparator: String?
        var multiPasteCustomSeparator: String?
        var multiPasteAltSeparator: String?
        var multiPasteAltCustomSeparator: String?
        var excelCleanup: Bool?
        var excelCopyAsText: Bool?
        var excludedBundleIDs: [String]?
        var toggleShortcut: KeyCombo?
        var copyPlainShortcut: KeyCombo?
        var copyFormattedShortcut: KeyCombo?
        var deleteShortcut: KeyCombo?
        var expandShortcut: KeyCombo?
        var searchShortcut: KeyCombo?
        var tabToggleShortcut: KeyCombo?
        var tabBackwardShortcut: KeyCombo?
        var excelCleanShortcut: KeyCombo?
        var saveToFinderShortcut: KeyCombo?
        var saveImageShortcut: KeyCombo?
        var imageSaveFolderPath: String?
    }
}

struct SnippetBackupView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SavedSnippet.order) private var allSnippets: [SavedSnippet]
    @State private var importResult: String?
    @State private var showImportConfirm = false
    @State private var pendingImportURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Backup (Snippets & Settings)")
                .font(.system(size: 12, weight: .semibold))

            HStack(spacing: 12) {
                Button {
                    exportSnippets()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 11))
                        Text("Export")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    chooseImportFile()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 11))
                        Text("Import")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if let result = importResult {
                    Text(result)
                        .font(.system(size: 11))
                        .foregroundStyle(result.contains("Error") ? .red : .green)
                }
            }
            .alert("Import Snippets?", isPresented: $showImportConfirm) {
                Button("Cancel", role: .cancel) { pendingImportURL = nil }
                Button("Replace All", role: .destructive) {
                    if let url = pendingImportURL {
                        importSnippets(from: url, merge: false)
                    }
                }
                Button("Merge") {
                    if let url = pendingImportURL {
                        importSnippets(from: url, merge: true)
                    }
                }
            } message: {
                Text("Replace all existing snippets, or merge with current ones?")
            }
        }
    }

    private func exportSnippets() {
        let sm = SettingsManager.shared
        let items = allSnippets.map { s in
            BackupData.SnippetJSON(
                id: s.id,
                title: s.title,
                content: s.content,
                order: s.order,
                isFolder: s.isFolder,
                folderID: s.folderID,
                iconName: s.iconName,
                hotkeyKeyCode: s.hotkeyKeyCode,
                hotkeyModifiers: s.hotkeyModifiers,
                rtfDataBase64: s.rtfData.map { $0.base64EncodedString() },
                createdAt: s.createdAt
            )
        }
        let settingsJSON = BackupData.SettingsJSON(
            defaultCopyPlainText: sm.defaultCopyPlainText,
            maxHistoryCount: sm.maxHistoryCount,
            dismissOnClickOutside: sm.dismissOnClickOutside,
            instantTyping: sm.instantTyping,
            toolbarDisplay: sm.toolbarDisplay,
            mouseAction: sm.mouseAction,
            snippetPreviewLines: sm.snippetPreviewLines,
            multiPasteSeparator: sm.multiPasteSeparator,
            multiPasteCustomSeparator: sm.multiPasteCustomSeparator,
            multiPasteAltSeparator: sm.multiPasteAltSeparator,
            multiPasteAltCustomSeparator: sm.multiPasteAltCustomSeparator,
            excelCleanup: sm.excelCleanup,
            excelCopyAsText: sm.excelCopyAsText,
            excludedBundleIDs: Array(sm.excludedBundleIDs),
            toggleShortcut: sm.toggleShortcut,
            copyPlainShortcut: sm.copyPlainShortcut,
            copyFormattedShortcut: sm.copyFormattedShortcut,
            deleteShortcut: sm.deleteShortcut,
            expandShortcut: sm.expandShortcut,
            searchShortcut: sm.searchShortcut,
            tabToggleShortcut: sm.tabToggleShortcut,
            tabBackwardShortcut: sm.tabBackwardShortcut,
            excelCleanShortcut: sm.excelCleanShortcut,
            saveToFinderShortcut: sm.saveToFinderShortcut,
            saveImageShortcut: sm.saveImageShortcut,
            imageSaveFolderPath: sm.imageSaveFolderPath
        )
        let exportData = BackupData(snippets: items, settings: settingsJSON)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(exportData) else {
            importResult = "Error: Failed to encode"
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "clipboard-manager-backup.json"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url)
                importResult = "Exported \(items.count) snippets + settings"
            } catch {
                importResult = "Error: \(error.localizedDescription)"
            }
        }
    }

    private func chooseImportFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            pendingImportURL = url
            showImportConfirm = true
        }
    }

    private func importSnippets(from url: URL, merge: Bool) {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let backup = try decoder.decode(BackupData.self, from: data)

            // Import settings if present
            if let s = backup.settings {
                let sm = SettingsManager.shared
                if let v = s.defaultCopyPlainText { sm.defaultCopyPlainText = v }
                if let v = s.maxHistoryCount { sm.maxHistoryCount = v }
                if let v = s.dismissOnClickOutside { sm.dismissOnClickOutside = v }
                if let v = s.instantTyping { sm.instantTyping = v }
                if let v = s.toolbarDisplay { sm.toolbarDisplay = v }
                if let v = s.mouseAction { sm.mouseAction = v }
                if let v = s.snippetPreviewLines { sm.snippetPreviewLines = v }
                if let v = s.multiPasteSeparator { sm.multiPasteSeparator = v }
                if let v = s.multiPasteCustomSeparator { sm.multiPasteCustomSeparator = v }
                if let v = s.multiPasteAltSeparator { sm.multiPasteAltSeparator = v }
                if let v = s.multiPasteAltCustomSeparator { sm.multiPasteAltCustomSeparator = v }
                if let v = s.excelCleanup { sm.excelCleanup = v }
                if let v = s.excelCopyAsText { sm.excelCopyAsText = v }
                if let v = s.excludedBundleIDs { sm.excludedBundleIDs = Set(v) }
                if let v = s.toggleShortcut { sm.toggleShortcut = v }
                if let v = s.copyPlainShortcut { sm.copyPlainShortcut = v }
                if let v = s.copyFormattedShortcut { sm.copyFormattedShortcut = v }
                if let v = s.deleteShortcut { sm.deleteShortcut = v }
                if let v = s.expandShortcut { sm.expandShortcut = v }
                if let v = s.searchShortcut { sm.searchShortcut = v }
                if let v = s.tabToggleShortcut { sm.tabToggleShortcut = v }
                if let v = s.tabBackwardShortcut { sm.tabBackwardShortcut = v }
                if let v = s.excelCleanShortcut { sm.excelCleanShortcut = v }
                if let v = s.saveToFinderShortcut { sm.saveToFinderShortcut = v }
                if let v = s.saveImageShortcut { sm.saveImageShortcut = v }
                if let v = s.imageSaveFolderPath { sm.imageSaveFolderPath = v }
            }

            if !merge {
                for s in allSnippets { modelContext.delete(s) }
            }

            let existingIDs = merge ? Set(allSnippets.map(\.id)) : []
            var imported = 0

            for item in backup.snippets {
                if merge && existingIDs.contains(item.id) { continue }
                let s = SavedSnippet(title: item.title, content: item.content, order: item.order, isFolder: item.isFolder, folderID: item.folderID)
                s.id = item.id
                s.iconName = item.iconName
                s.hotkeyKeyCode = item.hotkeyKeyCode
                s.hotkeyModifiers = item.hotkeyModifiers
                s.createdAt = item.createdAt
                if let b64 = item.rtfDataBase64 {
                    s.rtfData = Data(base64Encoded: b64)
                }
                modelContext.insert(s)
                imported += 1
            }

            try? modelContext.save()
            let hasSettings = backup.settings != nil
            importResult = "Imported \(imported) snippets\(hasSettings ? " + settings" : "")"
            NotificationCenter.default.post(name: .snippetHotkeysChanged, object: nil)
        } catch {
            importResult = "Error: \(error.localizedDescription)"
        }
        pendingImportURL = nil
    }
}

struct AppInfo: Identifiable {
    let id: String // bundleID
    let name: String
    let icon: NSImage
}

struct ExcludedAppsView: View {
    @ObservedObject var settings: SettingsManager
    @State private var allApps: [AppInfo] = []
    @State private var searchText = ""

    private var sortedApps: [AppInfo] {
        let filtered = searchText.isEmpty
            ? allApps
            : allApps.filter { $0.name.localizedCaseInsensitiveContains(searchText) }

        return filtered.sorted { a, b in
            let aExcluded = settings.isExcluded(a.id)
            let bExcluded = settings.isExcluded(b.id)
            if aExcluded != bExcluded { return aExcluded }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Excluded apps won't have their clipboard contents saved.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 12)

            // Search with clear button
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                TextField("Search apps...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(sortedApps) { app in
                        HStack {
                            Image(nsImage: app.icon)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 22, height: 22)
                            Text(app.name)
                                .font(.system(size: 13))
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { settings.isExcluded(app.id) },
                                set: { _ in
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        settings.toggleExclusion(app.id)
                                    }
                                }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .onAppear { loadAllApps() }
    }

    private func loadAllApps() {
        DispatchQueue.global(qos: .userInitiated).async {
            var appMap: [String: (name: String, icon: NSImage)] = [:]

            let searchPaths = [
                "/Applications",
                "/System/Applications",
                "/System/Applications/Utilities",
                NSHomeDirectory() + "/Applications",
            ]

            for searchPath in searchPaths {
                let url = URL(fileURLWithPath: searchPath)
                guard let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isApplicationKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for case let fileURL as URL in enumerator {
                    if fileURL.pathExtension == "app" {
                        enumerator.skipDescendants()
                        if let bundle = Bundle(url: fileURL),
                           let bid = bundle.bundleIdentifier {
                            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                                ?? fileURL.deletingPathExtension().lastPathComponent
                            let icon = NSWorkspace.shared.icon(forFile: fileURL.path)
                            appMap[bid] = (name: name, icon: icon)
                        }
                    }
                }
            }

            let results = appMap.map { AppInfo(id: $0.key, name: $0.value.name, icon: $0.value.icon) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            DispatchQueue.main.async {
                allApps = results
            }
        }
    }
}
