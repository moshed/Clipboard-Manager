import SwiftUI
import SwiftData

struct ClipboardListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ClipboardEntry.timestamp, order: .reverse) private var allEntries: [ClipboardEntry]
    @Query(sort: \SavedSnippet.order) private var allSnippets: [SavedSnippet]
    @ObservedObject private var settings = SettingsManager.shared

    @State private var selectedEntry: ClipboardEntry?
    @State private var selectedIDs: Set<UUID> = []
    @State private var popoverEntry: ClipboardEntry?
    @State private var searchText = ""
    @State private var dateFilter = DateFilter.all
    @State private var appFilter: Set<String> = []
    @State private var typeFilter: Set<ContentType> = []
    @State private var copiedID: UUID?
    @State private var showFilters = false
    @State private var viewMode: ViewMode = .clipboard
    @State private var selectedSnippetID: UUID?
    @FocusState private var isSearchFocused: Bool

    private enum ViewMode: Int {
        case clipboard = 0, snippets = 1, settings = 2
    }

    private var filteredEntries: [ClipboardEntry] {
        allEntries.filter { entry in
            if let startDate = dateFilter.startDate, entry.timestamp < startDate {
                return false
            }
            if !appFilter.isEmpty, let bid = entry.sourceAppBundleID, !appFilter.contains(bid) {
                return false
            }
            if !typeFilter.isEmpty, !typeFilter.contains(entry.contentType) {
                return false
            }
            if !searchText.isEmpty {
                let text = entry.textContent ?? entry.firstLine ?? ""
                let appName = entry.sourceAppName ?? ""
                let ocrText = entry.ocrText ?? ""
                if !text.localizedCaseInsensitiveContains(searchText)
                    && !appName.localizedCaseInsensitiveContains(searchText)
                    && !ocrText.localizedCaseInsensitiveContains(searchText) {
                    return false
                }
            }
            return true
        }
    }

    private var availableApps: [(bundleID: String, name: String)] {
        var seen = Set<String>()
        var apps: [(bundleID: String, name: String)] = []
        for entry in allEntries {
            if let bid = entry.sourceAppBundleID, let name = entry.sourceAppName, !seen.contains(bid) {
                seen.insert(bid)
                apps.append((bundleID: bid, name: name))
            }
        }
        return apps.sorted { $0.name < $1.name }
    }

    private var activeFilterCount: Int {
        var count = 0
        if dateFilter != .all { count += 1 }
        if !appFilter.isEmpty { count += 1 }
        if !typeFilter.isEmpty { count += 1 }
        return count
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            switch viewMode {
            case .clipboard:
                clipboardContent
            case .snippets:
                SnippetListView(selectedSnippetID: $selectedSnippetID) { snippet in
                    AppDelegate.shared?.pasteSnippetFromPanel(snippet)
                }
            case .settings:
                settingsContent
            }
        }
        .frame(minWidth: 320, idealWidth: 420, minHeight: 400, idealHeight: 520)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .focusEffectDisabled()
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            viewMode = .settings
        }
        .onReceive(NotificationCenter.default.publisher(for: .dismissSettings)) { _ in
            if viewMode == .settings { viewMode = .clipboard }
        }
        .onReceive(NotificationCenter.default.publisher(for: .panelDidOpen)) { _ in
            selectedEntry = filteredEntries.first
            selectedIDs = Set([filteredEntries.first?.id].compactMap { $0 })
            popoverEntry = nil
        }
        .background(KeyEventHandlerView(
            onCopyPlain: {
                if viewMode == .snippets {
                    insertSelectedSnippet()
                } else if viewMode == .clipboard {
                    let entries = selectedEntries
                    if !entries.isEmpty {
                        copyPlainMultiple(entries)
                        AppDelegate.shared?.pasteIntoPreviousApp()
                    }
                }
            },
            onCopyFormatted: {
                if viewMode == .snippets {
                    insertSelectedSnippet()
                } else if viewMode == .clipboard {
                    let entries = selectedEntries
                    if !entries.isEmpty {
                        copyFormattedMultiple(entries)
                        AppDelegate.shared?.pasteIntoPreviousApp()
                    }
                }
            },
            onDownArrow: {
                if viewMode == .snippets {
                    moveSnippetSelection(by: 1)
                } else if viewMode == .clipboard {
                    moveSelection(by: 1)
                }
            },
            onUpArrow: {
                if viewMode == .snippets {
                    moveSnippetSelection(by: -1)
                } else if viewMode == .clipboard {
                    moveSelection(by: -1)
                }
            },
            onRightArrow: {
                if viewMode == .snippets {
                    NotificationCenter.default.post(name: .snippetExpandFolder, object: nil)
                }
            },
            onLeftArrow: {
                if viewMode == .snippets {
                    NotificationCenter.default.post(name: .snippetCollapseFolder, object: nil)
                }
            },
            onExpand: {
                if viewMode == .clipboard, let entry = selectedEntry {
                    popoverEntry = popoverEntry?.id == entry.id ? nil : entry
                }
            },
            onDelete: {
                if viewMode == .snippets {
                    NotificationCenter.default.post(name: .snippetDeleteSelected, object: nil)
                    return
                }
                guard viewMode == .clipboard else { return }
                let toDelete = selectedEntries
                guard !toDelete.isEmpty else { return }
                let entries = filteredEntries
                let indices = toDelete.compactMap { e in entries.firstIndex(where: { $0.id == e.id }) }
                let minIdx = indices.min() ?? 0
                // Compute next selection BEFORE deleting
                let deleteIDs = Set(toDelete.map(\.id))
                let remaining = entries.filter { !deleteIDs.contains($0.id) }
                let nextEntry = remaining.first(where: { e in
                    entries.firstIndex(where: { $0.id == e.id }).map { $0 >= minIdx } ?? false
                }) ?? remaining.last
                // Now delete and update selection
                popoverEntry = nil
                selectedEntry = nextEntry
                selectedIDs = nextEntry.map { Set([$0.id]) } ?? []
                for entry in toDelete {
                    modelContext.delete(entry)
                }
            },
            onEnter: {
                if viewMode == .snippets {
                    insertSelectedSnippet()
                } else if viewMode == .clipboard {
                    let entries = selectedEntries
                    if !entries.isEmpty {
                        copyPlainMultiple(entries)
                        AppDelegate.shared?.pasteIntoPreviousApp()
                    }
                }
            },
            onShiftEnter: {
                if viewMode == .snippets {
                    insertSelectedSnippet()
                } else if viewMode == .clipboard {
                    let entries = selectedEntries
                    if !entries.isEmpty {
                        copyFormattedMultiple(entries)
                        AppDelegate.shared?.pasteIntoPreviousApp()
                    }
                }
            },
            onTyping: { chars in
                guard viewMode == .clipboard else { return }
                searchText += chars
                isSearchFocused = true
            },
            onFocusSearch: {
                if viewMode == .clipboard {
                    isSearchFocused = true
                }
            },
            onToggleTab: {
                switch viewMode {
                case .clipboard: viewMode = .snippets
                case .snippets: viewMode = .settings
                case .settings: viewMode = .clipboard
                }
            },
            onToggleTabBackward: {
                switch viewMode {
                case .clipboard: viewMode = .settings
                case .snippets: viewMode = .clipboard
                case .settings: viewMode = .snippets
                }
            }
        ))
    }

    // MARK: - Top Bar

    private var topBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                WindowControlButtons()
                Spacer()
                tabBar
                Spacer()
                Color.clear.frame(width: 52, height: 12)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            // Search + filter row (only for clipboard mode)
            if viewMode == .clipboard {
                HStack(spacing: 8) {
                    searchField
                    filterMenuButton
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            tabButton(.clipboard, icon: "doc.on.clipboard", label: "Clipboard")
            tabButton(.snippets, icon: "star.fill", label: "Snippets")
            tabButton(.settings, icon: "gear", label: "Settings")
        }
        .padding(2)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func tabButton(_ mode: ViewMode, icon: String, label: String) -> some View {
        let isActive = viewMode == mode
        let display = settings.toolbarDisplay
        return Button {
            viewMode = mode
        } label: {
            HStack(spacing: 4) {
                if display != "textOnly" {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .medium))
                }
                if display != "iconOnly" {
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .padding(.horizontal, display == "iconOnly" ? 8 : 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color(nsColor: .controlAccentColor).opacity(0.2) : Color.clear)
            )
            .foregroundStyle(isActive ? Color(nsColor: .controlAccentColor) : .secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Clipboard Content

    private var clipboardContent: some View {
        clipsList
    }

    // MARK: - Settings Content

    private var settingsContent: some View {
        ScrollView {
            SettingsView(onClearAll: {
                for entry in allEntries {
                    modelContext.delete(entry)
                }
            })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Clips List

    private var clipsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(filteredEntries, id: \.id) { entry in
                        entryRow(for: entry)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            .onChange(of: selectedEntry?.id) { _, newID in
                if let id = newID {
                    proxy.scrollTo(id, anchor: nil)
                }
            }
        }
    }

    @ViewBuilder
    private func entryRow(for entry: ClipboardEntry) -> some View {
        let isSelected = selectedIDs.contains(entry.id)
        let isCopied = copiedID == entry.id
        let showPopover = Binding<Bool>(
            get: { popoverEntry?.id == entry.id },
            set: { if !$0 { popoverEntry = nil } }
        )

        VStack(spacing: 0) {
            ClipboardRowView(entry: entry, isSelected: isSelected)
                .overlay {
                    TwoFingerTapView {
                        selectedEntry = entry
                        popoverEntry = popoverEntry?.id == entry.id ? nil : entry
                    }
                }
                .onTapGesture(count: 2) {
                    if settings.mouseAction == "doubleClick" {
                        handleTap(entry)
                        copyPlainMultiple([entry])
                        AppDelegate.shared?.pasteIntoPreviousApp()
                    }
                }
                .onTapGesture(count: 1) {
                    let flags = NSEvent.modifierFlags
                    if flags.contains(.command) || flags.contains(.shift) {
                        handleTap(entry, command: flags.contains(.command), shift: flags.contains(.shift))
                    } else {
                        handleTap(entry)
                        if settings.mouseAction == "singleClick" {
                            copyPlainMultiple([entry])
                            AppDelegate.shared?.pasteIntoPreviousApp()
                        }
                    }
                }
                .popover(isPresented: showPopover, arrowEdge: .trailing) {
                    popoverContent(for: entry)
                }

            if isCopied {
                copiedBadge
            }
        }
    }

    private var copiedBadge: some View {
        HStack {
            Spacer()
            Text("Copied!")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Color.green.opacity(0.1))
                .clipShape(Capsule())
            Spacer()
        }
        .transition(.opacity)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func entryContextMenu(for entry: ClipboardEntry) -> some View {
        Button("Copy Plain Text  (\(settings.copyPlainShortcut?.displayString ?? "—"))") { copyPlain(entry) }
        if entry.contentType == .image || entry.contentType == .screenshot {
            if let url = entry.sourceURL {
                Button("Copy Address  (\(settings.copyFormattedShortcut?.displayString ?? "—"))") { copyString(url, for: entry) }
            }
        } else if entry.contentType == .file, let paths = entry.filePaths, !paths.isEmpty {
            Button("Copy Path  (\(settings.copyFormattedShortcut?.displayString ?? "—"))") {
                copyString(paths.joined(separator: "\n"), for: entry)
            }
        } else {
            Button("Copy Formatted  (\(settings.copyFormattedShortcut?.displayString ?? "—"))") { copyFormatted(entry) }
        }
        Divider()
        Button(entry.isPinned ? "Unpin" : "Pin") {
            entry.isPinned.toggle()
        }
        if entry.contentType == .text || entry.contentType == .rtf || entry.contentType == .url {
            Button("Save to Snippets") {
                saveEntryAsSnippet(entry)
            }
        }
        Divider()
        Button("Delete", role: .destructive) {
            if selectedIDs.contains(entry.id) {
                selectedIDs.remove(entry.id)
                if selectedEntry?.id == entry.id {
                    selectedEntry = filteredEntries.first(where: { selectedIDs.contains($0.id) })
                }
            }
            if popoverEntry?.id == entry.id { popoverEntry = nil }
            modelContext.delete(entry)
        }
    }

    private func handleTap(_ entry: ClipboardEntry, command: Bool = false, shift: Bool = false) {
        if command {
            if selectedIDs.contains(entry.id) {
                selectedIDs.remove(entry.id)
                if selectedEntry?.id == entry.id {
                    selectedEntry = filteredEntries.first(where: { selectedIDs.contains($0.id) })
                }
            } else {
                selectedIDs.insert(entry.id)
                selectedEntry = entry
            }
        } else if shift, let anchor = selectedEntry {
            let entries = filteredEntries
            if let anchorIdx = entries.firstIndex(where: { $0.id == anchor.id }),
               let clickIdx = entries.firstIndex(where: { $0.id == entry.id }) {
                let range = min(anchorIdx, clickIdx)...max(anchorIdx, clickIdx)
                selectedIDs = Set(entries[range].map(\.id))
            }
        } else {
            selectedEntry = entry
            selectedIDs = [entry.id]
        }
        popoverEntry = nil
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)

            TextField("Search clips...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isSearchFocused)
                .onSubmit {
                    if let entry = selectedEntry {
                        copyPlain(entry)
                        AppDelegate.shared?.pasteIntoPreviousApp()
                    }
                }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var filterMenuButton: some View {
        Button {
            showFilters.toggle()
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(activeFilterCount > 0 ? .white : .primary)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(activeFilterCount > 0 ? Color.accentColor : Color.primary.opacity(0.05))
                )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showFilters, arrowEdge: .bottom) {
            FilterPopoverView(
                dateFilter: $dateFilter,
                appFilter: $appFilter,
                typeFilter: $typeFilter,
                availableApps: availableApps
            )
        }
    }

    // MARK: - Popover Content

    private func popoverContent(for entry: ClipboardEntry) -> some View {
        let panelSize = panelFrameSize()
        return ClipboardDetailView(
            entry: entry,
            onCopyPlain: { copyPlain(entry) },
            onCopyFormatted: { copyFormatted(entry) },
            onDelete: {
                popoverEntry = nil
                if selectedIDs.contains(entry.id) {
                    selectedIDs.remove(entry.id)
                    if selectedEntry?.id == entry.id {
                        selectedEntry = filteredEntries.first(where: { selectedIDs.contains($0.id) })
                    }
                }
                modelContext.delete(entry)
            },
            onSaveSnippet: entry.contentType == .text || entry.contentType == .rtf || entry.contentType == .url ? { saveEntryAsSnippet(entry) } : nil
        )
        .frame(maxWidth: panelSize.width, maxHeight: panelSize.height)
    }

    // MARK: - Popover Sizing

    private func panelFrameSize() -> CGSize {
        let panel = NSApp.windows.first(where: { $0 is ClipboardPanel })
        return panel?.frame.size ?? CGSize(width: 420, height: 520)
    }

    // MARK: - Selection Helpers

    private var selectedEntries: [ClipboardEntry] {
        let entries = filteredEntries
        return entries.filter { selectedIDs.contains($0.id) }
    }

    // MARK: - Actions

    private func copyPlainMultiple(_ entries: [ClipboardEntry]) {
        if entries.count == 1 {
            copyPlain(entries[0])
            return
        }
        let combined = entries.compactMap { entry -> String? in
            entry.textContent ?? entry.ocrText
        }.joined(separator: "\n")
        AppDelegate.shared?.clipboardMonitor?.selfCopiedEntryID = entries.first?.id
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(combined, forType: .string)
        if let first = entries.first { showCopiedFeedback(first) }
    }

    private func copyFormattedMultiple(_ entries: [ClipboardEntry]) {
        if entries.count == 1 {
            copyFormatted(entries[0])
            return
        }
        copyPlainMultiple(entries)
    }

    private func copyPlain(_ entry: ClipboardEntry) {
        AppDelegate.shared?.clipboardMonitor?.selfCopiedEntryID = entry.id
        let pb = NSPasteboard.general
        pb.clearContents()
        if entry.contentType == .image || entry.contentType == .screenshot {
            if let data = entry.imageData {
                copyImageToPasteboard(data, pasteboard: pb)
            }
        } else if let text = entry.textContent {
            pb.setString(text, forType: .string)
        } else if let data = entry.imageData {
            copyImageToPasteboard(data, pasteboard: pb)
        }
        showCopiedFeedback(entry)
    }

    private func copyImageToPasteboard(_ pngData: Data, pasteboard: NSPasteboard) {
        guard let image = NSImage(data: pngData) else {
            pasteboard.setData(pngData, forType: .png)
            return
        }
        if let tiff = image.tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }
        pasteboard.setData(pngData, forType: .png)
    }

    private func copyFormatted(_ entry: ClipboardEntry) {
        if entry.contentType == .image || entry.contentType == .screenshot {
            if let url = entry.sourceURL {
                copyString(url, for: entry)
            } else {
                copyPlain(entry)
            }
            return
        }
        if entry.contentType == .file, let paths = entry.filePaths, !paths.isEmpty {
            copyString(paths.joined(separator: "\n"), for: entry)
            return
        }

        AppDelegate.shared?.clipboardMonitor?.selfCopiedEntryID = entry.id
        let pb = NSPasteboard.general
        pb.clearContents()
        if let rtfd = entry.rtfdData { pb.setData(rtfd, forType: .rtfd) }
        if let rtf = entry.rtfData { pb.setData(rtf, forType: .rtf) }
        if let text = entry.textContent { pb.setString(text, forType: .string) }
        if let data = entry.imageData { pb.setData(data, forType: .png) }
        showCopiedFeedback(entry)
    }

    private func copyString(_ string: String, for entry: ClipboardEntry) {
        AppDelegate.shared?.clipboardMonitor?.selfCopiedEntryID = entry.id
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
        showCopiedFeedback(entry)
    }

    private func showCopiedFeedback(_ entry: ClipboardEntry) {
        withAnimation(.easeInOut(duration: 0.2)) { copiedID = entry.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeOut(duration: 0.3)) {
                if copiedID == entry.id { copiedID = nil }
            }
        }
    }

    private func moveSelection(by offset: Int) {
        let entries = filteredEntries
        guard !entries.isEmpty else { return }
        if let current = selectedEntry,
           let currentIndex = entries.firstIndex(where: { $0.id == current.id }) {
            let newIndex = min(max(currentIndex + offset, 0), entries.count - 1)
            selectedEntry = entries[newIndex]
            selectedIDs = [entries[newIndex].id]
        } else {
            let entry = offset > 0 ? entries.first : entries.last
            selectedEntry = entry
            selectedIDs = Set([entry?.id].compactMap { $0 })
        }
        popoverEntry = nil
    }

    private func moveSnippetSelection(by offset: Int) {
        NotificationCenter.default.post(name: .snippetMoveSelection, object: offset)
    }

    private func insertSelectedSnippet() {
        NotificationCenter.default.post(name: .snippetInsertSelected, object: nil)
    }

    private func saveEntryAsSnippet(_ entry: ClipboardEntry) {
        guard let text = entry.textContent else { return }
        let title = String((text.prefix(50)).components(separatedBy: .newlines).first ?? "")
        let allSnippetsList = (try? modelContext.fetch(FetchDescriptor<SavedSnippet>())) ?? []
        let nextOrder = (allSnippetsList.map(\.order).max() ?? -1) + 1
        let snippet = SavedSnippet(title: title, content: text, order: nextOrder)
        modelContext.insert(snippet)
        viewMode = .snippets
    }
}

// MARK: - Window Control Buttons

struct WindowControlButtons: View {
    var body: some View {
        HStack(spacing: 7) {
            windowButton(color: .red) {
                NSApp.keyWindow?.orderOut(nil)
            }
            windowButton(color: .yellow) {
                NSApp.keyWindow?.miniaturize(nil)
            }
            windowButton(color: .green) {}
        }
    }

    private func windowButton(color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .overlay(Circle().strokeBorder(color.opacity(0.3), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Two-Finger Tap Gesture

struct TwoFingerTapView: NSViewRepresentable {
    var onTwoFingerTap: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = TwoFingerTapNSView()
        view.onTwoFingerTap = onTwoFingerTap
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? TwoFingerTapNSView)?.onTwoFingerTap = onTwoFingerTap
    }
}

private class TwoFingerTapNSView: NSView {
    var onTwoFingerTap: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Transparent views are skipped by hit testing — override to accept events
    override func hitTest(_ point: NSPoint) -> NSView? {
        return frame.contains(point) ? self : nil
    }

    override func rightMouseDown(with event: NSEvent) {
        onTwoFingerTap?()
    }
}
