import SwiftUI
import SwiftData

struct ClipboardListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ClipboardEntry.timestamp, order: .reverse) private var allEntries: [ClipboardEntry]
    @Query(sort: \SavedSnippet.order) private var allSnippets: [SavedSnippet]
    @ObservedObject private var settings = SettingsManager.shared

    @State private var selectedEntry: ClipboardEntry?
    @State private var selectedIDs: Set<UUID> = []
    @State private var selectionOrder: [UUID] = []
    @State private var popoverEntry: ClipboardEntry?
    @State private var searchText = ""
    @State private var dateFilter = DateFilter.all
    @State private var appFilter: Set<String> = []
    @State private var typeFilter: Set<ContentType> = []
    @State private var copiedID: UUID?
    @State private var showFilters = false
    @State private var viewMode: ViewMode = .clipboard
    @State private var selectedSnippetID: UUID?
    @State private var hoveredEntryID: UUID?
    @FocusState private var isSearchFocused: Bool

    private enum ViewMode: Int {
        case clipboard = 0, snippets = 1
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
                let domain = entry.sourceDomain ?? ""
                let pageURL = entry.sourcePageURL ?? ""
                let srcURL = entry.sourceURL ?? ""
                if !text.localizedCaseInsensitiveContains(searchText)
                    && !appName.localizedCaseInsensitiveContains(searchText)
                    && !ocrText.localizedCaseInsensitiveContains(searchText)
                    && !domain.localizedCaseInsensitiveContains(searchText)
                    && !pageURL.localizedCaseInsensitiveContains(searchText)
                    && !srcURL.localizedCaseInsensitiveContains(searchText) {
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
            }
        }
        .frame(minWidth: 320, idealWidth: 420, minHeight: 400, idealHeight: 520)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .focusEffectDisabled()
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            AppDelegate.shared?.openSettingsWindow()
        }
        .onReceive(NotificationCenter.default.publisher(for: .panelEscapePressed)) { _ in
            if showFilters {
                showFilters = false
            } else if !searchText.isEmpty {
                searchText = ""
            } else {
                AppDelegate.shared?.closePanel()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .panelDidOpen)) { _ in
            selectedEntry = filteredEntries.first
            selectedIDs = Set([filteredEntries.first?.id].compactMap { $0 })
            selectionOrder = [filteredEntries.first?.id].compactMap { $0 }
            popoverEntry = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .panelDidClose)) { _ in
            dateFilter = .all
            appFilter = []
            typeFilter = []
        }
        .background(KeyEventHandlerView(
            onCopyPlain: {
                if viewMode == .snippets {
                    insertSelectedSnippet()
                } else if viewMode == .clipboard {
                    pastePrimary()
                }
            },
            onCopyFormatted: {
                if viewMode == .snippets {
                    insertSelectedSnippet()
                } else if viewMode == .clipboard {
                    pasteAlternate()
                }
            },
            onPasteOrdered: {
                guard viewMode == .clipboard else { return }
                let entries = selectedEntriesInOrder
                guard !entries.isEmpty else { return }
                copyOrderedMultiple(entries)
                AppDelegate.shared?.pasteIntoPreviousApp()
            },
            onTransform: {
                guard viewMode == .clipboard, let entry = selectedEntry, transformableText(for: entry) != nil else { return }
                showTransformMenu(for: entry)
            },
            onSaveImage: {
                guard viewMode == .clipboard else { return }
                let images = selectedEntries.filter { $0.contentType == .image || $0.contentType == .screenshot }
                guard !images.isEmpty else { return }
                saveImagesToFolder(images)
            },
            onDownArrow: {
                if viewMode == .snippets {
                    moveSnippetSelection(by: 1)
                } else if viewMode == .clipboard {
                    // In the grid, down moves a whole row rather than one tile.
                    moveSelection(by: showImageGrid ? Self.gridColumnCount : 1)
                }
            },
            onUpArrow: {
                if viewMode == .snippets {
                    moveSnippetSelection(by: -1)
                } else if viewMode == .clipboard {
                    moveSelection(by: showImageGrid ? -Self.gridColumnCount : -1)
                }
            },
            onShiftDownArrow: {
                if viewMode == .clipboard { extendSelection(by: 1) }
            },
            onShiftUpArrow: {
                if viewMode == .clipboard { extendSelection(by: -1) }
            },
            onRightArrow: {
                if viewMode == .snippets {
                    NotificationCenter.default.post(name: .snippetExpandFolder, object: nil)
                } else if viewMode == .clipboard, showImageGrid {
                    moveSelection(by: 1)
                }
            },
            onLeftArrow: {
                if viewMode == .snippets {
                    NotificationCenter.default.post(name: .snippetCollapseFolder, object: nil)
                } else if viewMode == .clipboard, showImageGrid {
                    moveSelection(by: -1)
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
                selectionOrder = [nextEntry?.id].compactMap { $0 }
                for entry in toDelete {
                    ClipboardImageStore.deleteBlob(for: entry.id, context: modelContext)
                    modelContext.delete(entry)
                }
            },
            onDeleteWithContents: {
                // Cmd+Delete in the snippets tab = delete a folder AND its contents
                // (the snippet list confirms first). Clipboard tab keeps normal delete.
                if viewMode == .snippets {
                    NotificationCenter.default.post(name: .snippetDeleteWithContents, object: nil)
                }
            },
            onFilterType: { kind in
                guard viewMode == .clipboard else { return }
                toggleTypeFilter(kind)
            },
            onEnter: {
                if viewMode == .snippets {
                    insertSelectedSnippet()
                } else if viewMode == .clipboard {
                    pastePrimary()
                }
            },
            onShiftEnter: {
                if viewMode == .snippets {
                    insertSelectedSnippet()
                } else if viewMode == .clipboard {
                    pasteAlternate()
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
            onToggleFilters: {
                if viewMode == .clipboard {
                    showFilters.toggle()
                }
            },
            onToggleTab: {
                viewMode = viewMode == .clipboard ? .snippets : .clipboard
            },
            onToggleTabBackward: {
                viewMode = viewMode == .clipboard ? .snippets : .clipboard
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
            HStack(spacing: 5) {
                if display != "textOnly" {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .medium))
                }
                if display != "iconOnly" {
                    Text(label)
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .padding(.horizontal, display == "iconOnly" ? 10 : 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color(nsColor: .controlAccentColor).opacity(0.2) : Color.clear)
            )
            .foregroundStyle(isActive ? Color(nsColor: .controlAccentColor) : .secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Clipboard Content

    /// True when the current filter shows images only — the cue to switch to the grid.
    private var isImagesOnlyFilter: Bool {
        typeFilter == [.image, .screenshot] || typeFilter == [.image] || typeFilter == [.screenshot]
    }

    private var showImageGrid: Bool {
        settings.imageGridEnabled && isImagesOnlyFilter
    }

    /// Columns in the image grid, used for both layout and up/down arrow navigation.
    private static let gridColumnCount = 3

    @ViewBuilder
    private var clipboardContent: some View {
        if showImageGrid {
            imageGrid
        } else {
            clipsList
        }
    }

    // MARK: - Image Grid

    private var imageGrid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: Self.gridColumnCount),
                    spacing: 6
                ) {
                    ForEach(filteredEntries, id: \.id) { entry in
                        imageTile(for: entry).id(entry.id)
                    }
                }
                .padding(8)
            }
            .onChange(of: selectedEntry?.id) { _, newID in
                if let id = newID { proxy.scrollTo(id, anchor: nil) }
            }
        }
    }

    @ViewBuilder
    private func imageTile(for entry: ClipboardEntry) -> some View {
        let isSelected = selectedIDs.contains(entry.id)
        let orderIndex: Int? = selectedIDs.count > 1
            ? selectionOrder.firstIndex(of: entry.id).map { $0 + 1 }
            : nil

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.05))

            if let data = entry.thumbnailData ?? entry.imageData, let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: entry.contentType.systemImage)
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let orderIndex {
                Text("\(orderIndex)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(minWidth: 16)
                    .padding(.vertical, 1)
                    .background(Color(nsColor: .controlAccentColor), in: Capsule())
                    .padding(4)
            }
        }
        .frame(height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color(nsColor: .controlAccentColor) : Color.primary.opacity(0.12),
                              lineWidth: isSelected ? 2.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if settings.mouseAction == "doubleClick" {
                handleTap(entry)
                copyPlainMultiple([entry])
                AppDelegate.shared?.pasteIntoPreviousApp()
            }
        }
        .onTapGesture(count: 1) {
            let flags = NSEvent.modifierFlags
            if flags.contains(.command) {
                handleTap(entry, command: true)
            } else if flags.contains(.shift) {
                handleTap(entry, shift: true)
            } else {
                handleTap(entry)
                if settings.mouseAction == "singleClick" && selectedIDs.count == 1 {
                    copyPlainMultiple([entry])
                    AppDelegate.shared?.pasteIntoPreviousApp()
                }
            }
        }
        .contextMenu { entryContextMenu(for: entry) }
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

        // Position in the paste order — only meaningful once more than one item is picked
        let orderIndex: Int? = selectedIDs.count > 1
            ? selectionOrder.firstIndex(of: entry.id).map { $0 + 1 }
            : nil

        VStack(spacing: 0) {
            ClipboardRowView(entry: entry, isSelected: isSelected, selectionIndex: orderIndex)
                .background(isSelected ? AnchorViewRepresentable() : nil)
                .overlay(alignment: .trailing) {
                    ZStack(alignment: .trailing) {
                        TwoFingerTapView {
                            selectedEntry = entry
                            popoverEntry = popoverEntry?.id == entry.id ? nil : entry
                        }
                        if transformableText(for: entry) != nil && hoveredEntryID == entry.id {
                            transformMenuButton(for: entry)
                                .padding(.trailing, 6)
                        }
                    }
                }
                .onHover { hovering in
                    hoveredEntryID = hovering ? entry.id : nil
                }
                .onTapGesture(count: 2) {
                    if settings.mouseAction == "doubleClick" {
                        handleTap(entry)
                        copyPlainMultiple([entry])
                        AppDelegate.shared?.pasteIntoPreviousApp()
                    }
                }
                // Single tap gesture owns ALL click selection. Previously this coexisted
                // with two `.simultaneousGesture(TapGesture().modifiers(...))` handlers, so a
                // Command- or Shift-click fired handleTap TWICE — and because command-click
                // *toggles*, the row got added then removed, silently dropping out of the
                // selection. Whether both fired was timing-dependent → flaky "only one pasted".
                .onTapGesture(count: 1) {
                    let flags = NSEvent.modifierFlags
                    if flags.contains(.command) {
                        handleTap(entry, command: true)
                    } else if flags.contains(.shift) {
                        handleTap(entry, shift: true)
                    } else {
                        handleTap(entry)
                        // Only auto-paste (single-click mode) when this really was a single
                        // selection — if sticky multi-select just added a row, don't paste one.
                        if settings.mouseAction == "singleClick" && selectedIDs.count == 1 {
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
            Button("Save Image to Folder  (\(settings.saveImageShortcut?.displayString ?? "—"))") {
                saveImagesToFolder([entry])
            }
        } else if entry.contentType == .file, let paths = entry.filePaths, !paths.isEmpty {
            Button("Copy Path  (\(settings.copyFormattedShortcut?.displayString ?? "—"))") {
                copyString(paths.joined(separator: "\n"), for: entry)
            }
            Button("Copy Path in Backticks") {
                let backticked = paths.map { "`\($0)`" }.joined(separator: "\n")
                copyString(backticked, for: entry)
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
                selectionOrder.removeAll { $0 == entry.id }
                if selectedEntry?.id == entry.id {
                    selectedEntry = filteredEntries.first(where: { selectedIDs.contains($0.id) })
                }
            }
            if popoverEntry?.id == entry.id { popoverEntry = nil }
            ClipboardImageStore.deleteBlob(for: entry.id, context: modelContext)
            modelContext.delete(entry)
        }
    }

    private func handleTap(_ entry: ClipboardEntry, command: Bool = false, shift: Bool = false) {
        if command {
            if selectedIDs.contains(entry.id) {
                selectedIDs.remove(entry.id)
                selectionOrder.removeAll { $0 == entry.id }
                if selectedEntry?.id == entry.id {
                    selectedEntry = filteredEntries.first(where: { selectedIDs.contains($0.id) })
                }
            } else {
                selectedIDs.insert(entry.id)
                selectionOrder.append(entry.id)
                selectedEntry = entry
            }
        } else if shift {
            let entries = filteredEntries
            // Anchor priority: the explicit selectedEntry, else the first already-selected
            // row, else the top of the list. Without this fallback a shift-click while
            // selectedEntry was nil just selected the one clicked row instead of the range.
            let anchor = selectedEntry
                ?? entries.first(where: { selectedIDs.contains($0.id) })
                ?? entries.first
            if let anchor,
               let anchorIdx = entries.firstIndex(where: { $0.id == anchor.id }),
               let clickIdx = entries.firstIndex(where: { $0.id == entry.id }) {
                let range = min(anchorIdx, clickIdx)...max(anchorIdx, clickIdx)
                selectedIDs = Set(entries[range].map(\.id))
                selectionOrder = entries[range].map(\.id)
                selectedEntry = anchor
            }
        } else if selectedIDs.count >= 2 {
            // "Sticky" multi-select: once 2+ rows are picked, a plain click keeps building
            // the list instead of collapsing it to one — a missed Command key can no longer
            // wipe the selection. Clicking an already-picked row collapses back to just it
            // (the way out); Escape / reopening the panel clears everything.
            if selectedIDs.contains(entry.id) {
                selectedEntry = entry
                selectedIDs = [entry.id]
                selectionOrder = [entry.id]
            } else {
                selectedIDs.insert(entry.id)
                selectionOrder.append(entry.id)
                selectedEntry = entry
            }
        } else {
            selectedEntry = entry
            selectedIDs = [entry.id]
            selectionOrder = [entry.id]
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
                ClipboardImageStore.deleteBlob(for: entry.id, context: modelContext)
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

    /// Toggle a quick content-type filter. Pressing the same shortcut again clears it,
    /// so ⌘I shows only images and ⌘I again shows everything.
    private func toggleTypeFilter(_ kind: String) {
        let types: Set<ContentType>
        switch kind {
        case "images": types = [.image, .screenshot]
        case "text":   types = [.text, .rtf]
        case "links":  types = [.url]
        case "files":  types = [.file]
        default: return
        }
        if typeFilter == types {
            typeFilter = []          // same shortcut again -> show everything
        } else {
            typeFilter = types
        }
        // Keep the selection valid for the new list.
        let entries = filteredEntries
        selectedEntry = entries.first
        selectedIDs = Set([entries.first?.id].compactMap { $0 })
        selectionOrder = [entries.first?.id].compactMap { $0 }
        popoverEntry = nil
    }

    // MARK: - Selection Helpers

    private var selectedEntries: [ClipboardEntry] {
        let entries = filteredEntries
        return entries.filter { selectedIDs.contains($0.id) }
    }

    /// Entries in the order they were selected (for secondary copy)
    private var selectedEntriesInOrder: [ClipboardEntry] {
        let entryMap = Dictionary(uniqueKeysWithValues: filteredEntries.map { ($0.id, $0) })
        var ordered = selectionOrder.compactMap { entryMap[$0] }
        // Add any selected entries not in the order list (e.g. from shift-select)
        let orderedIDs = Set(ordered.map(\.id))
        let remaining = filteredEntries.filter { selectedIDs.contains($0.id) && !orderedIDs.contains($0.id) }
        ordered.append(contentsOf: remaining)
        return ordered
    }

    // MARK: - Actions

    /// Full image bytes for an entry — checks legacy inline imageData first, then the blob store.
    private func fullImageData(for entry: ClipboardEntry) -> Data? {
        if let data = entry.imageData { return data }
        return ClipboardImageStore.fullData(for: entry.id, context: modelContext)
    }

    /// Whether the entry has any image bytes available (inline, blob, or thumbnail marker).
    private func hasImageBytes(_ entry: ClipboardEntry) -> Bool {
        entry.imageData != nil || entry.thumbnailData != nil
    }

    /// Build pasteboard items for an entry (one per file path, or one for image/text)
    private func pasteboardItems(for entry: ClipboardEntry) -> [NSPasteboardItem] {
        if entry.contentType == .file, let paths = entry.filePaths, !paths.isEmpty {
            var items: [NSPasteboardItem] = []
            let imageBytes = fullImageData(for: entry)
            for (i, path) in paths.enumerated() {
                let item = NSPasteboardItem()
                if FileManager.default.fileExists(atPath: path) {
                    item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
                }
                // Add image data to first item for inline paste support
                if i == 0, let data = imageBytes {
                    item.setData(data, forType: .png)
                    if let rep = NSBitmapImageRep(data: data),
                       let tiff = rep.representation(using: .tiff, properties: [:]) {
                        item.setData(tiff, forType: .tiff)
                    }
                }
                items.append(item)
            }
            return items
        } else if (entry.contentType == .image || entry.contentType == .screenshot), let imageData = fullImageData(for: entry) {
            let item = NSPasteboardItem()
            item.setData(imageData, forType: .png)
            if let rep = NSBitmapImageRep(data: imageData),
               let tiff = rep.representation(using: .tiff, properties: [:]) {
                item.setData(tiff, forType: .tiff)
            }
            return [item]
        } else {
            let item = NSPasteboardItem()
            if let text = entry.textContent ?? entry.ocrText {
                item.setString(text, forType: .string)
            }
            return [item]
        }
    }

    /// Pasteboard items for a *multi-item* paste. Images are spilled to temp PNGs and carried
    /// as **file URLs only** — an item that also carries `.png`/`.tiff` makes readers treat the
    /// whole pasteboard as a single image and take just the first one (verified in Mail).
    private func multiPasteboardItems(for entry: ClipboardEntry) -> [NSPasteboardItem] {
        if entry.contentType == .file, let paths = entry.filePaths, !paths.isEmpty {
            return paths.compactMap { path in
                guard FileManager.default.fileExists(atPath: path) else { return nil }
                let item = NSPasteboardItem()
                item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
                return item
            }
        }
        guard entry.contentType == .image || entry.contentType == .screenshot,
              let data = fullImageData(for: entry) else {
            return pasteboardItems(for: entry)
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ClipboardManager", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(entry.id.uuidString).png")
        guard (try? data.write(to: url)) != nil else { return pasteboardItems(for: entry) }

        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        return [item]
    }

    /// Whether an entry carries non-text data (image or file) that needs per-item pasteboard items
    private func isNonTextEntry(_ entry: ClipboardEntry) -> Bool {
        entry.contentType == .image || entry.contentType == .screenshot ||
        (entry.contentType == .file && (hasImageBytes(entry) || entry.filePaths != nil))
    }

    private func copyPlainMultiple(_ entries: [ClipboardEntry]) {
        if entries.count == 1 {
            copyPlain(entries[0])
            return
        }
        AppDelegate.shared?.clipboardMonitor?.selfCopiedEntryID = entries.first?.id
        let pb = NSPasteboard.general
        pb.clearContents()

        if entries.contains(where: { isNonTextEntry($0) }) {
            pb.writeObjects(entries.flatMap { pasteboardItems(for: $0) })
        } else {
            let separator = settings.resolvedSeparator
            let combined = entries.compactMap { entry -> String? in
                entry.textContent ?? entry.ocrText
            }.joined(separator: separator)
            pb.setString(combined, forType: .string)
        }
        if let first = entries.first { showCopiedFeedback(first) }
    }

    private func copyFormattedMultiple(_ entries: [ClipboardEntry]) {
        if entries.count == 1 {
            copyFormatted(entries[0])
            return
        }
        AppDelegate.shared?.clipboardMonitor?.selfCopiedEntryID = entries.first?.id
        let pb = NSPasteboard.general
        pb.clearContents()

        if entries.contains(where: { isNonTextEntry($0) }) {
            pb.writeObjects(entries.flatMap { pasteboardItems(for: $0) })
        } else {
            let separator = settings.resolvedSeparator
            let combined = entries.compactMap { entry -> String? in
                if entry.contentType == .file, let paths = entry.filePaths, !paths.isEmpty {
                    return paths.joined(separator: separator)
                } else if (entry.contentType == .image || entry.contentType == .screenshot), let url = entry.sourceURL {
                    return url
                }
                return entry.textContent ?? entry.ocrText
            }.joined(separator: separator)
            pb.setString(combined, forType: .string)
        }
        if let first = entries.first { showCopiedFeedback(first) }
    }

    // MARK: - Paste Entry Points
    //
    // Enter (copyPlainShortcut) and Shift+Enter (copyFormattedShortcut) both land here.
    // A single item keeps its old behaviour (plain / formatted copy); a multi-selection
    // pastes in pick order joined with the primary / alternate separator.

    private func pastePrimary() {
        let entries = selectedEntriesInOrder
        guard !entries.isEmpty else { return }
        copyOrderedMultiple(entries)
        AppDelegate.shared?.pasteIntoPreviousApp()
    }

    private func pasteAlternate() {
        let entries = selectedEntriesInOrder
        guard !entries.isEmpty else { return }
        if entries.count == 1 {
            copyFormatted(entries[0])
            AppDelegate.shared?.pasteIntoPreviousApp()
            return
        }
        if settings.multiPasteAltSeparator == "ask" {
            showSeparatorMenu(for: entries)
            return
        }
        copyOrderedMultiple(entries, separator: settings.resolvedAltSeparator)
        AppDelegate.shared?.pasteIntoPreviousApp()
    }

    /// Pop up a separator picker anchored to the selected row, then paste with the choice.
    private func showSeparatorMenu(for entries: [ClipboardEntry]) {
        let choices: [(String, String)] = [
            ("New Line", "\n"),
            ("Comma", ", "),
            ("Semicolon", "; "),
            ("Space", " "),
            ("Dash", " - "),
            ("Tab", "\t"),
            ("Custom (\(settings.multiPasteAltCustomSeparator))",
             SettingsManager.unescape(settings.multiPasteAltCustomSeparator))
        ]
        let menu = NSMenu()
        for (index, choice) in choices.enumerated() {
            let number = index + 1
            let item = NSMenuItem(title: "\(number)   \(choice.0)",
                                  action: #selector(SeparatorMenuTarget.pick(_:)),
                                  keyEquivalent: "\(number)")
            item.keyEquivalentModifierMask = []
            item.representedObject = choice.1
            item.target = SeparatorMenuTarget.shared
            menu.addItem(item)
        }
        SeparatorMenuTarget.shared.onPick = { separator in
            copyOrderedMultiple(entries, separator: separator)
            AppDelegate.shared?.pasteIntoPreviousApp()
        }
        if let anchorView = AnchorViewRepresentable.currentView {
            let bounds = anchorView.bounds
            let point = NSPoint(x: bounds.maxX, y: bounds.midY)
            menu.popUp(positioning: menu.items.first, at: point, in: anchorView)
        }
    }

    /// Paste multiple items in the order they were selected, joined with `separator`
    /// (defaults to the separator configured in Settings).
    /// Text an entry contributes to a joined multi-paste. Images/files fall back to their
    /// source URL or file path so a mixed selection still pastes as usable text.
    private func joinableText(for entry: ClipboardEntry) -> String? {
        if let text = entry.textContent, !text.isEmpty { return text }
        if let ocr = entry.ocrText, !ocr.isEmpty { return ocr }
        if entry.contentType == .file, let paths = entry.filePaths, !paths.isEmpty {
            return paths.joined(separator: "\n")
        }
        if let url = entry.sourceURL, !url.isEmpty { return url }
        return nil
    }

    private func copyOrderedMultiple(_ entries: [ClipboardEntry], separator: String? = nil) {
        if entries.count == 1 {
            copyPlain(entries[0])
            return
        }
        AppDelegate.shared?.clipboardMonitor?.selfCopiedEntryID = entries.first?.id
        let pb = NSPasteboard.general
        pb.clearContents()

        // Only spill to separate file/image pasteboard items when EVERY item is a
        // non-text image/file. Any text or link in the mix would otherwise be written as
        // its own item, and web/text fields read only the first item — so a link
        // selection would paste just one. Mixed/text selections go out as one joined string.
        let allNonText = entries.allSatisfy { isNonTextEntry($0) }
        if allNonText {
            pb.writeObjects(entries.flatMap { multiPasteboardItems(for: $0) })
        } else {
            let sep = separator ?? settings.resolvedSeparator
            let combined = entries.compactMap { joinableText(for: $0) }.joined(separator: sep)
            pb.setString(combined, forType: .string)
        }
        if let first = entries.first { showCopiedFeedback(first) }
    }

    private func copyPlain(_ entry: ClipboardEntry) {
        AppDelegate.shared?.clipboardMonitor?.selfCopiedEntryID = entry.id
        let pb = NSPasteboard.general
        pb.clearContents()
        if entry.contentType == .file, let paths = entry.filePaths, !paths.isEmpty {
            // Reconstruct original pasteboard: file URLs + image data for inline paste
            let imageBytes = fullImageData(for: entry)
            var items: [NSPasteboardItem] = []
            for (i, path) in paths.enumerated() {
                let item = NSPasteboardItem()
                if FileManager.default.fileExists(atPath: path) {
                    item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
                }
                if i == 0, let data = imageBytes {
                    item.setData(data, forType: .png)
                    if let rep = NSBitmapImageRep(data: data),
                       let tiff = rep.representation(using: .tiff, properties: [:]) {
                        item.setData(tiff, forType: .tiff)
                    }
                }
                items.append(item)
            }
            pb.writeObjects(items)
        } else if entry.contentType == .image || entry.contentType == .screenshot {
            if let data = fullImageData(for: entry) {
                copyImageToPasteboard(data, pasteboard: pb)
            }
        } else if let text = entry.textContent {
            pb.setString(text, forType: .string)
        } else if let data = fullImageData(for: entry) {
            copyImageToPasteboard(data, pasteboard: pb)
        }
        showCopiedFeedback(entry)
    }

    private func copyImageToPasteboard(_ pngData: Data, pasteboard: NSPasteboard) {
        // Use NSBitmapImageRep directly to avoid NSImage DPI changes on Retina
        if let rep = NSBitmapImageRep(data: pngData),
           let tiff = rep.representation(using: .tiff, properties: [:]) {
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
        if let data = fullImageData(for: entry) { pb.setData(data, forType: .png) }
        showCopiedFeedback(entry)
    }

    private func copyString(_ string: String, for entry: ClipboardEntry) {
        AppDelegate.shared?.clipboardMonitor?.selfCopiedEntryID = entry.id
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
        showCopiedFeedback(entry)
    }

    /// Write the given image entries to the configured save folder as PNGs.
    /// Reveals the saved file(s) in Finder and flashes the first row as feedback.
    private func saveImagesToFolder(_ entries: [ClipboardEntry]) {
        let folder = settings.imageSaveFolderURL
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"

        var savedURLs: [URL] = []
        for entry in entries {
            guard let data = fullImageData(for: entry) else { continue }
            let base = "Clipboard Image \(df.string(from: entry.timestamp))"
            var dest = folder.appendingPathComponent("\(base).png")
            var n = 2
            while fm.fileExists(atPath: dest.path) {
                dest = folder.appendingPathComponent("\(base) (\(n)).png")
                n += 1
            }
            if (try? data.write(to: dest)) != nil {
                savedURLs.append(dest)
            }
        }

        guard !savedURLs.isEmpty else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(savedURLs)
        if let first = entries.first { showCopiedFeedback(first) }
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
            let raw = currentIndex + offset
            let newIndex = ((raw % entries.count) + entries.count) % entries.count
            selectedEntry = entries[newIndex]
            selectedIDs = [entries[newIndex].id]
            selectionOrder = [entries[newIndex].id]
        } else {
            let entry = offset > 0 ? entries.first : entries.last
            selectedEntry = entry
            selectedIDs = Set([entry?.id].compactMap { $0 })
            selectionOrder = [entry?.id].compactMap { $0 }
        }
        popoverEntry = nil
    }

    private func extendSelection(by offset: Int) {
        let entries = filteredEntries
        guard !entries.isEmpty, let current = selectedEntry,
              let currentIndex = entries.firstIndex(where: { $0.id == current.id }) else { return }
        let raw = currentIndex + offset
        let newIndex = max(0, min(raw, entries.count - 1))
        let next = entries[newIndex]
        selectedEntry = next
        selectedIDs.insert(next.id)
        if !selectionOrder.contains(next.id) {
            selectionOrder.append(next.id)
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

    // MARK: - Transformations

    /// Returns the text to transform: textContent for text entries, file paths for file entries
    private func transformableText(for entry: ClipboardEntry) -> String? {
        if let text = entry.textContent { return text }
        if entry.contentType == .file, let paths = entry.filePaths, !paths.isEmpty {
            return paths.joined(separator: "\n")
        }
        return nil
    }

    private func transformMenuButton(for entry: ClipboardEntry) -> some View {
        Menu {
            ForEach(settings.customTransformations.filter(\.isEnabled)) { transform in
                Button(transform.name) {
                    if transform.isBuiltIn {
                        applyBuiltIn(builtInKind(for: transform), to: entry)
                    } else {
                        applyCustom(transform, to: entry)
                    }
                }
            }
        } label: {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(0.08)))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func showTransformMenu(for entry: ClipboardEntry) {
        let menu = NSMenu()
        let enabled = settings.customTransformations.filter(\.isEnabled)
        for transform in enabled {
            let item = NSMenuItem(title: transform.name, action: #selector(TransformMenuTarget.performTransform(_:)), keyEquivalent: "")
            item.representedObject = TransformBox(transform)
            item.target = TransformMenuTarget.shared
            menu.addItem(item)
        }
        TransformMenuTarget.shared.onApply = { [self] transform in
            if transform.isBuiltIn {
                applyBuiltIn(builtInKind(for: transform), to: entry)
            } else {
                applyCustom(transform, to: entry)
            }
        }

        // Anchor to the selected row via the stored anchor view
        if let anchorView = AnchorViewRepresentable.currentView {
            let bounds = anchorView.bounds
            let point = NSPoint(x: bounds.maxX, y: bounds.midY)
            menu.popUp(positioning: menu.items.first, at: point, in: anchorView)
        }
    }

    enum BuiltInTransform {
        case uppercase, lowercase, capitalCase, cleanWhitespace
    }

    private func builtInKind(for transform: CustomTransformation) -> BuiltInTransform {
        switch transform.id {
        case CustomTransformation.builtInUppercase.id: return .uppercase
        case CustomTransformation.builtInLowercase.id: return .lowercase
        case CustomTransformation.builtInCleanWhitespace.id: return .cleanWhitespace
        default: return .capitalCase
        }
    }

    private func applyBuiltIn(_ transform: BuiltInTransform, to entry: ClipboardEntry) {
        guard let text = transformableText(for: entry) else { return }
        let result: String
        switch transform {
        case .uppercase: result = text.uppercased()
        case .lowercase: result = text.lowercased()
        case .capitalCase: result = text.capitalized
        case .cleanWhitespace: result = Self.cleanWhitespace(text)
        }
        createTransformedEntry(from: entry, newText: result)
    }

    /// Trim each line, collapse runs of spaces/tabs to one, and collapse blank lines —
    /// then trim the whole thing. Used by the built-in "Clean Whitespace" transform.
    static func cleanWhitespace(_ text: String) -> String {
        func replace(_ pattern: String, _ template: String, in s: String) -> String {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
            return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        var out = text
        out = replace("(?m)^[ \\t]+", "", in: out)          // trim line starts
        out = replace("(?m)[ \\t]+$", "", in: out)          // trim line ends
        out = replace("[ \\t]{2,}", " ", in: out)           // collapse double spaces
        out = replace("\\n[ \\t]*\\n(?:[ \\t]*\\n)*", "\n", in: out) // collapse blank lines
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func applyCustom(_ custom: CustomTransformation, to entry: ClipboardEntry) {
        guard let text = transformableText(for: entry),
              let regex = try? NSRegularExpression(pattern: custom.pattern) else { return }
        let fullRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: fullRange)

        // Replace in reverse order, skipping zero-length matches to avoid
        // inserting the replacement template at empty-string positions
        var result = text
        for match in matches.reversed() {
            guard match.range.length > 0 else { continue }
            let replacement = regex.replacementString(for: match, in: result, offset: 0, template: custom.replacement)
            let start = result.index(result.startIndex, offsetBy: match.range.location)
            let end = result.index(start, offsetBy: match.range.length)
            result.replaceSubrange(start..<end, with: replacement)
        }
        createTransformedEntry(from: entry, newText: result)
    }

    private func createTransformedEntry(from original: ClipboardEntry, newText: String) {
        let newEntry = ClipboardEntry(
            textContent: newText,
            contentType: .text,
            sourceAppBundleID: Bundle.main.bundleIdentifier,
            sourceAppName: "Clipboard Manager"
        )
        modelContext.insert(newEntry)
        try? modelContext.save()
        selectedEntry = newEntry
        selectedIDs = [newEntry.id]
        selectionOrder = [newEntry.id]

        // Copy to clipboard and paste into active app
        AppDelegate.shared?.clipboardMonitor?.selfCopiedEntryID = newEntry.id
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(newText, forType: .string)
        AppDelegate.shared?.pasteIntoPreviousApp()
    }
}

// MARK: - Transform Menu Target

private class TransformBox: NSObject {
    let value: CustomTransformation
    init(_ value: CustomTransformation) { self.value = value }
}

private class SeparatorMenuTarget: NSObject {
    static let shared = SeparatorMenuTarget()
    var onPick: ((String) -> Void)?

    @objc func pick(_ sender: NSMenuItem) {
        guard let separator = sender.representedObject as? String else { return }
        onPick?(separator)
    }
}

private class TransformMenuTarget: NSObject {
    static let shared = TransformMenuTarget()
    var onApply: ((CustomTransformation) -> Void)?

    @objc func performTransform(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? TransformBox else { return }
        onApply?(box.value)
    }
}

// MARK: - Anchor View for Transform Menu

private struct AnchorViewRepresentable: NSViewRepresentable {
    static weak var currentView: NSView?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        AnchorViewRepresentable.currentView = nsView
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
