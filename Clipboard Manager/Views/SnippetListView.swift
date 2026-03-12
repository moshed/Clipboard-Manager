import SwiftUI
import SwiftData
import Carbon

struct SnippetListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SavedSnippet.order) private var allSnippets: [SavedSnippet]

    @Binding var selectedSnippetID: UUID?
    @State private var selectedIDs: Set<UUID> = []
    @State private var editingSnippet: SavedSnippet?
    @State private var showEditor = false
    @State private var searchText = ""
    @State private var editingFolderID: UUID?
    @State private var dragTargetFolderID: UUID?
    @State private var dragInsertBeforeID: UUID?
    @State private var expandedFolderIDs: Set<UUID> = []
    @State private var draggingItemID: UUID?
    @State private var iconPickerItemID: UUID?
    @State private var editorSessionID = UUID()

    private let settings = SettingsManager.shared
    var onInsert: (SavedSnippet) -> Void

    /// Top-level items (folders + standalone snippets)
    private var topLevelItems: [SavedSnippet] {
        allSnippets.filter { $0.folderID == nil }.sorted { $0.order < $1.order }
    }

    /// Visible items including children of expanded folders
    private var visibleItems: [SavedSnippet] {
        var result: [SavedSnippet] = []
        let top = topLevelItems
        let filtered = searchText.isEmpty ? top : top.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.content.localizedCaseInsensitiveContains(searchText)
        }
        for item in filtered {
            result.append(item)
            if item.isFolder && expandedFolderIDs.contains(item.id) {
                result.append(contentsOf: snippetsInFolder(item.id))
            }
        }
        return result
    }

    private func snippetsInFolder(_ folderID: UUID) -> [SavedSnippet] {
        allSnippets.filter { $0.folderID == folderID && !$0.isFolder }.sorted { $0.order < $1.order }
    }

    private var folders: [SavedSnippet] {
        allSnippets.filter { $0.isFolder && $0.folderID == nil }
    }

    /// If a folder or item-in-folder is selected, return that folder ID for new snippets
    private var selectedFolderForNew: UUID? {
        guard let id = selectedSnippetID,
              let item = allSnippets.first(where: { $0.id == id }) else { return nil }
        if item.isFolder { return item.id }
        return item.folderID
    }

    // Called from parent for right arrow
    func expandSelectedFolder() {
        guard let id = selectedSnippetID,
              let item = allSnippets.first(where: { $0.id == id }),
              item.isFolder else { return }
        expandedFolderIDs.insert(id)
    }

    // Called from parent for left arrow
    func collapseSelectedFolder() {
        guard let id = selectedSnippetID else { return }
        // If selected item is in a folder, select the folder and collapse
        if let item = allSnippets.first(where: { $0.id == id }),
           let fid = item.folderID {
            selectedSnippetID = fid
            selectedIDs = [fid]
            expandedFolderIDs.remove(fid)
        } else {
            // If selected is a folder, collapse it
            expandedFolderIDs.remove(id)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if showEditor {
                SnippetEditorView(
                    snippet: editingSnippet,
                    nextOrder: (allSnippets.map(\.order).max() ?? -1) + 1,
                    folderID: editingFolderID,
                    folders: folders,
                    onSave: {
                        showEditor = false
                        editingSnippet = nil
                        editingFolderID = nil
                        NotificationCenter.default.post(name: .snippetHotkeysChanged, object: nil)
                    },
                    onCancel: {
                        showEditor = false
                        editingSnippet = nil
                        editingFolderID = nil
                    }
                )
                .id(editorSessionID)
            } else {
                // Search + add buttons
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.tertiary)
                        TextField("Search snippets...", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
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

                    // Add folder
                    Button {
                        createFolder()
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.primary)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.primary.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                    .help("New Folder")

                    // Add snippet
                    Button {
                        editingFolderID = selectedFolderForNew
                        editingSnippet = nil
                        editorSessionID = UUID(); showEditor = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.primary)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.primary.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                    .help("New Snippet")
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 6)

                // Snippet list
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            if visibleItems.isEmpty {
                                VStack(spacing: 8) {
                                    Image(systemName: "text.quote")
                                        .font(.system(size: 28))
                                        .foregroundStyle(.quaternary)
                                    Text("No snippets yet")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                    Text("Click + to create one, or save from clipboard history")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.tertiary)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                            } else {
                                let items = visibleItems
                                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                    VStack(spacing: 0) {
                                        // Drop indicator above this row
                                        if dragInsertBeforeID == item.id {
                                            reorderDropIndicator
                                        }
                                        snippetRow(item)
                                            .id(item.id)
                                    }
                                    .onDrop(of: [.text], delegate: SnippetReorderDropDelegate(
                                        item: item,
                                        items: items,
                                        dragItemID: $draggingItemID,
                                        dragTargetFolderID: $dragTargetFolderID,
                                        dragInsertBeforeID: $dragInsertBeforeID,
                                        onReorder: { draggedID, beforeID in
                                            reorderSnippet(draggedID: draggedID, beforeID: beforeID)
                                        },
                                        onMoveToFolder: { snippetIDStrings, folderID in
                                            moveSnippetsToFolder(snippetIDStrings: snippetIDStrings, folderID: folderID)
                                        }
                                    ))
                                }
                                // Drop indicator at the very end
                                if dragInsertBeforeID == UUID(uuidString: "00000000-0000-0000-0000-000000000000") {
                                    reorderDropIndicator
                                }
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                    }
                    .onChange(of: selectedSnippetID) { _, newID in
                        if let id = newID {
                            proxy.scrollTo(id, anchor: nil)
                        }
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .snippetExpandFolder)) { _ in
            expandSelectedFolder()
        }
        .onReceive(NotificationCenter.default.publisher(for: .snippetCollapseFolder)) { _ in
            collapseSelectedFolder()
        }
        .onReceive(NotificationCenter.default.publisher(for: .snippetMoveSelection)) { notif in
            if let offset = notif.object as? Int {
                moveSelection(by: offset)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .snippetInsertSelected)) { _ in
            insertSelected()
        }
        .onReceive(NotificationCenter.default.publisher(for: .snippetDeleteSelected)) { _ in
            deleteSelected()
        }
        .onAppear {
            // Expand all folders by default
            expandedFolderIDs = Set(allSnippets.filter { $0.isFolder }.map(\.id))
        }
        .onChange(of: allSnippets.count) { _, _ in
            // Auto-expand newly created folders
            for item in allSnippets where item.isFolder && !expandedFolderIDs.contains(item.id) {
                expandedFolderIDs.insert(item.id)
            }
        }
    }

    // MARK: - Row

    private func snippetRow(_ item: SavedSnippet) -> some View {
        let isSelected = selectedIDs.contains(item.id)
        let children = item.isFolder ? snippetsInFolder(item.id) : []
        let isDragTarget = dragTargetFolderID == item.id
        let isExpanded = expandedFolderIDs.contains(item.id)
        let isChild = item.folderID != nil
        let bgColor: Color = isSelected
            ? Color(nsColor: .controlAccentColor).opacity(0.25)
            : isDragTarget ? Color.orange.opacity(0.15) : Color.clear
        let borderColor: Color = isDragTarget ? Color.orange.opacity(0.5) : Color.clear

        return HStack(spacing: 10) {
            if item.isFolder {
                Button {
                    iconPickerItemID = item.id
                } label: {
                    ZStack {
                        Image(systemName: "folder")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                        if let icon = item.iconName {
                            Image(systemName: icon)
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.secondary)
                                .offset(y: 2)
                        }
                    }
                    .frame(width: 20)
                }
                .buttonStyle(.plain)
                .popover(isPresented: Binding(
                    get: { iconPickerItemID == item.id },
                    set: { if !$0 { iconPickerItemID = nil } }
                )) {
                    SFSymbolPicker(selected: Binding(
                        get: { item.iconName },
                        set: { item.iconName = $0 }
                    ), onDismiss: { iconPickerItemID = nil })
                }
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            if isChild {
                Color.clear.frame(width: 16)
            }
            if !item.isFolder {
                Button {
                    iconPickerItemID = item.id
                } label: {
                    Image(systemName: item.iconName ?? "square.dashed")
                        .font(.system(size: 13))
                        .foregroundStyle(item.iconName != nil ? .secondary : .quaternary)
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
                .popover(isPresented: Binding(
                    get: { iconPickerItemID == item.id },
                    set: { if !$0 { iconPickerItemID = nil } }
                )) {
                    SFSymbolPicker(selected: Binding(
                        get: { item.iconName },
                        set: { item.iconName = $0 }
                    ), onDismiss: { iconPickerItemID = nil })
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if !item.title.isEmpty {
                        Text(item.title)
                            .font(.system(size: 12.5, weight: isChild ? .regular : .medium))
                            .lineLimit(1)
                    }
                    if item.isFolder {
                        Text("\(children.count)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                if !item.isFolder {
                    if settings.snippetPreviewLines > 0 {
                        Text(item.content)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(settings.snippetPreviewLines)
                    }
                }
            }
            Spacer(minLength: 4)
            InlineShortcutBadge(snippet: item)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(bgColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(borderColor, lineWidth: 2)
        )
        .background(NonDraggableArea())
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard settings.mouseAction == "doubleClick" else { return }
            if !item.isFolder {
                selectedSnippetID = item.id
                selectedIDs = [item.id]
                onInsert(item)
            }
        }
        .onTapGesture(count: 1) {
            let flags = NSEvent.modifierFlags
            if flags.contains(.command) {
                if selectedIDs.contains(item.id) {
                    selectedIDs.remove(item.id)
                    if selectedSnippetID == item.id {
                        selectedSnippetID = selectedIDs.first
                    }
                } else {
                    selectedIDs.insert(item.id)
                    selectedSnippetID = item.id
                }
            } else if flags.contains(.shift), let anchor = selectedSnippetID {
                let items = visibleItems
                if let anchorIdx = items.firstIndex(where: { $0.id == anchor }),
                   let clickIdx = items.firstIndex(where: { $0.id == item.id }) {
                    let range = min(anchorIdx, clickIdx)...max(anchorIdx, clickIdx)
                    selectedIDs = Set(items[range].map(\.id))
                }
            } else {
                selectedSnippetID = item.id
                selectedIDs = [item.id]
                if item.isFolder {
                    // Toggle expand/collapse
                    if expandedFolderIDs.contains(item.id) {
                        expandedFolderIDs.remove(item.id)
                    } else {
                        expandedFolderIDs.insert(item.id)
                    }
                } else if settings.mouseAction == "singleClick" {
                    onInsert(item)
                }
            }
        }
        .onDrag {
            draggingItemID = item.id
            return NSItemProvider(object: item.id.uuidString as NSString)
        }
        .contextMenu {
            if item.isFolder {
                if !children.isEmpty {
                    ForEach(children, id: \.id) { child in
                        Button {
                            onInsert(child)
                        } label: {
                            Label(
                                child.title.isEmpty ? String(child.content.prefix(40)) : child.title,
                                systemImage: child.iconName ?? "doc.text"
                            )
                        }
                    }
                    Divider()
                }
                Button("Add Snippet to Folder") {
                    editingFolderID = item.id
                    editingSnippet = nil
                    editorSessionID = UUID(); showEditor = true
                }
                Button("Edit Folder") {
                    editingSnippet = item
                    editingFolderID = nil
                    editorSessionID = UUID(); showEditor = true
                }
                Divider()
                Button("Delete Folder", role: .destructive) {
                    for child in children { modelContext.delete(child) }
                    modelContext.delete(item)
                    expandedFolderIDs.remove(item.id)
                    NotificationCenter.default.post(name: .snippetHotkeysChanged, object: nil)
                }
            } else {
                Button("Insert") { onInsert(item) }
                Button("Edit") {
                    editingSnippet = item
                    editingFolderID = item.folderID
                    editorSessionID = UUID(); showEditor = true
                }
                if !folders.isEmpty {
                    let moveIDs = selectedIDs.contains(item.id) && selectedIDs.count > 1
                        ? selectedIDs : [item.id]
                    Menu(moveIDs.count > 1 ? "Move \(moveIDs.count) to Folder" : "Move to Folder") {
                        ForEach(folders, id: \.id) { folder in
                            Button(folder.title) {
                                moveToFolder(snippetIDs: moveIDs, folderID: folder.id)
                            }
                        }
                        Divider()
                        if item.folderID != nil {
                            Button("Remove from Folder") {
                                moveToFolder(snippetIDs: moveIDs, folderID: nil)
                            }
                        }
                    }
                }
                Divider()
                Button("Delete", role: .destructive) {
                    modelContext.delete(item)
                    selectedIDs.remove(item.id)
                    NotificationCenter.default.post(name: .snippetHotkeysChanged, object: nil)
                }
            }
        }
    }

    // MARK: - Navigation

    private func moveSelection(by offset: Int) {
        let items = visibleItems
        guard !items.isEmpty else { return }
        if let current = selectedSnippetID,
           let idx = items.firstIndex(where: { $0.id == current }) {
            let newIdx = min(max(idx + offset, 0), items.count - 1)
            selectedSnippetID = items[newIdx].id
            selectedIDs = [items[newIdx].id]
        } else {
            let item = offset > 0 ? items.first : items.last
            selectedSnippetID = item?.id
            if let id = item?.id { selectedIDs = [id] }
        }
    }

    private func insertSelected() {
        guard let id = selectedSnippetID,
              let snippet = allSnippets.first(where: { $0.id == id }) else { return }
        if snippet.isFolder {
            // Toggle expand
            if expandedFolderIDs.contains(id) {
                expandedFolderIDs.remove(id)
            } else {
                expandedFolderIDs.insert(id)
            }
        } else {
            onInsert(snippet)
        }
    }

    private func deleteSelected() {
        guard let id = selectedSnippetID,
              let item = allSnippets.first(where: { $0.id == id }) else { return }
        let items = visibleItems
        // Compute next selection before deleting
        if let idx = items.firstIndex(where: { $0.id == id }) {
            let nextIdx = idx + 1 < items.count ? idx + 1 : idx - 1
            if nextIdx >= 0 && nextIdx < items.count && items[nextIdx].id != id {
                selectedSnippetID = items[nextIdx].id
                selectedIDs = [items[nextIdx].id]
            } else {
                selectedSnippetID = nil
                selectedIDs = []
            }
        }
        // Delete folder children too
        if item.isFolder {
            for child in snippetsInFolder(item.id) { modelContext.delete(child) }
            expandedFolderIDs.remove(item.id)
        }
        modelContext.delete(item)
        NotificationCenter.default.post(name: .snippetHotkeysChanged, object: nil)
    }

    // MARK: - Actions

    private func createFolder() {
        let nextOrder = (allSnippets.map(\.order).max() ?? -1) + 1
        let folder = SavedSnippet(title: "New Folder", content: "", order: nextOrder, isFolder: true)
        modelContext.insert(folder)
        editingSnippet = folder
        editingFolderID = nil
        editorSessionID = UUID(); showEditor = true
    }

    private func moveToFolder(snippetIDs: Set<UUID>, folderID: UUID?) {
        for snippet in allSnippets where snippetIDs.contains(snippet.id) && !snippet.isFolder {
            snippet.folderID = folderID
        }
    }

    private var reorderDropIndicator: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.accentColor)
            .frame(height: 2)
            .padding(.horizontal, 8)
    }

    private func reorderSnippet(draggedID: UUID, beforeID: UUID?) {
        guard let dragged = allSnippets.first(where: { $0.id == draggedID }) else { return }

        // Determine the list we're reordering within
        let parentFolder = dragged.folderID
        var siblings = allSnippets
            .filter { $0.folderID == parentFolder }
            .sorted { $0.order < $1.order }
            .filter { $0.id != draggedID }

        if let beforeID, let idx = siblings.firstIndex(where: { $0.id == beforeID }) {
            siblings.insert(dragged, at: idx)
        } else {
            siblings.append(dragged)
        }

        for (i, item) in siblings.enumerated() {
            item.order = i
        }
    }

    private func moveSnippetsToFolder(snippetIDStrings: [String], folderID: UUID) {
        var idsToMove = Set<UUID>()
        for str in snippetIDStrings {
            if let uuid = UUID(uuidString: str) {
                idsToMove.insert(uuid)
            }
        }
        if !idsToMove.isDisjoint(with: selectedIDs) {
            idsToMove.formUnion(selectedIDs)
        }
        for snippet in allSnippets where idsToMove.contains(snippet.id) && !snippet.isFolder {
            snippet.folderID = folderID
        }
    }
}

// Prevents window dragging when placed as background of a view
struct NonDraggableArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NonDraggableNSView {
        NonDraggableNSView()
    }
    func updateNSView(_ nsView: NonDraggableNSView, context: Context) {}
}

class NonDraggableNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
}

// MARK: - Reorder Drop Delegate

struct SnippetReorderDropDelegate: DropDelegate {
    let item: SavedSnippet
    let items: [SavedSnippet]
    @Binding var dragItemID: UUID?
    @Binding var dragTargetFolderID: UUID?
    @Binding var dragInsertBeforeID: UUID?
    let onReorder: (UUID, UUID?) -> Void
    let onMoveToFolder: ([String], UUID) -> Void

    private static let endSentinel = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    func dropEntered(info: DropInfo) {
        guard let dragID = dragItemID, dragID != item.id else { return }

        if item.isFolder {
            // Hovering over a folder — show folder highlight
            dragTargetFolderID = item.id
            dragInsertBeforeID = nil
        } else {
            // Hovering over a regular item — show reorder indicator
            dragTargetFolderID = nil
            dragInsertBeforeID = item.id
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if dragTargetFolderID == item.id {
            dragTargetFolderID = nil
        }
        if dragInsertBeforeID == item.id {
            dragInsertBeforeID = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let dragID = dragItemID else { return false }

        if let folderID = dragTargetFolderID {
            // Drop into folder
            onMoveToFolder([dragID.uuidString], folderID)
        } else {
            // Reorder
            onReorder(dragID, dragInsertBeforeID)
        }

        dragItemID = nil
        dragTargetFolderID = nil
        dragInsertBeforeID = nil
        return true
    }
}

// MARK: - Inline Shortcut Badge

struct InlineShortcutBadge: View {
    var snippet: SavedSnippet
    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var currentCombo: KeyCombo?

    var body: some View {
        Button {
            if isRecording {
                stopRecording()
            } else {
                startRecording()
            }
        } label: {
            if isRecording {
                Image(systemName: "record.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse, isActive: true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Color.red.opacity(0.3), lineWidth: 1)
                    )
            } else if let combo = currentCombo {
                Text(combo.displayString)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            } else {
                Image(systemName: "record.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.quaternary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
            }
        }
        .buttonStyle(.plain)
        .onAppear { currentCombo = snippet.keyCombo }
        .onChange(of: snippet.hotkeyKeyCode) { _, _ in currentCombo = snippet.keyCombo }
    }

    private func startRecording() {
        isRecording = true
        isRecordingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.carbonFlags
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return nil
            }
            guard modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 else {
                return nil
            }
            let combo = KeyCombo(keyCode: UInt32(event.keyCode), modifiers: modifiers)
            snippet.keyCombo = combo
            currentCombo = combo
            stopRecording()
            NotificationCenter.default.post(name: .snippetHotkeysChanged, object: nil)
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        isRecordingShortcut = false
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }
}
