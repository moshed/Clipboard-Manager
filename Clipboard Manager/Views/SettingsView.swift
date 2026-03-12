import SwiftUI
import ServiceManagement
import Carbon

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
                settingsTabButton(2, icon: "minus.circle.fill", label: "Excluded Apps")
            }
            .padding(2)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 4)

            // Tab content
            switch settingsTab {
            case 0:
                generalTab
            case 1:
                shortcutsTab
            default:
                ExcludedAppsView(settings: settings)
            }
        }
    }

    private func settingsTabButton(_ tab: Int, icon: String, label: String) -> some View {
        let isActive = settingsTab == tab
        return Button {
            settingsTab = tab
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color(nsColor: .controlAccentColor).opacity(0.2) : Color.clear)
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

            HStack {
                Text("Toolbar Display")
                Spacer()
                Picker("", selection: $settings.toolbarDisplay) {
                    Text("Icons & Text").tag("both")
                    Text("Icons Only").tag("iconOnly")
                    Text("Text Only").tag("textOnly")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 140)
            }

            HStack {
                Text("Paste on Mouse")
                Spacer()
                Picker("", selection: $settings.mouseAction) {
                    Text("Single Click").tag("singleClick")
                    Text("Double Click").tag("doubleClick")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 140)
            }

            HStack {
                Text("Snippet Preview Lines")
                Spacer()
                Picker("", selection: $settings.snippetPreviewLines) {
                    Text("None").tag(0)
                    Text("1").tag(1)
                    Text("2").tag(2)
                    Text("3").tag(3)
                    Text("5").tag(5)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 140)
            }

            HStack {
                Text("Max History")
                Spacer()
                ClearableTextField(text: $historyText, placeholder: "1000")
                    .frame(width: 80)
                    .onChange(of: historyText) { _, newValue in
                        if let val = Int(newValue), val >= 10 {
                            settings.maxHistoryCount = val
                        }
                    }
                Text("entries")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
            }

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
}

struct ShortcutsSettingsView: View {
    @ObservedObject var settings: SettingsManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Global section
            Text("Global")
                .font(.system(size: 14, weight: .bold))

            ShortcutRow(label: "Toggle Clipboard Manager", keyCombo: $settings.toggleShortcut, requireModifier: true, defaultCombo: .defaultToggle)

            Divider()

            // In-App section
            Text("In-App")
                .font(.system(size: 14, weight: .bold))

            OptionalShortcutRow(label: "Copy Plain Text", keyCombo: $settings.copyPlainShortcut, requireModifier: false)
            OptionalShortcutRow(label: "Copy with Formatting", keyCombo: $settings.copyFormattedShortcut, requireModifier: false)
            OptionalShortcutRow(label: "Delete", keyCombo: $settings.deleteShortcut, requireModifier: false)
            OptionalShortcutRow(label: "Preview", keyCombo: $settings.expandShortcut, requireModifier: false)
            OptionalShortcutRow(label: "Focus Search", keyCombo: $settings.searchShortcut, requireModifier: false)

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
