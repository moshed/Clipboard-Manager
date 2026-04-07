import SwiftUI
import Carbon

private func snippetDebugLog(_ message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "\(ts): \(message)\n"
    let path = "/tmp/clipboard-manager-debug.log"
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
    }
}

struct SnippetEditorView: View {
    @Environment(\.modelContext) private var modelContext
    var snippet: SavedSnippet?
    var nextOrder: Int
    var folderID: UUID? = nil
    var folders: [SavedSnippet] = []
    var onSave: () -> Void
    var onCancel: () -> Void

    @State private var title: String = ""
    @State private var content: String = ""
    @State private var keyCombo: KeyCombo?
    @State private var selectedFolderID: UUID?
    @State private var isFolder: Bool = false
    @State private var iconName: String?
    @State private var showIconPicker = false
    @State private var matchDestinationFont: Bool = true
    @State private var attributedContent = NSMutableAttributedString()
    @State private var editorCoordinator: RichTextEditorCoordinator?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                // Header
                HStack {
                    Text(editorTitle)
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button("Cancel") { onCancel() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isFolder && title.isEmpty)
                }

                // Title + Icon row
                HStack(spacing: 8) {
                    Button {
                        showIconPicker.toggle()
                    } label: {
                        Image(systemName: iconName ?? "square.dashed")
                            .font(.system(size: 18))
                            .frame(width: 36, height: 36)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(iconName != nil ? .primary : .tertiary)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showIconPicker) {
                        SFSymbolPicker(selected: $iconName, onDismiss: { showIconPicker = false })
                    }

                    TextField(isFolder ? "Folder name" : "Label for this snippet (not inserted)", text: $title)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                if !isFolder {
                    // Font mode toggle + formatting toolbar
                    HStack(spacing: 8) {
                        Picker("", selection: $matchDestinationFont) {
                            Text("Match Destination Font").tag(true)
                            Text("Custom Font").tag(false)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }

                    if !matchDestinationFont {
                        FormatToolbar(coordinator: editorCoordinator)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            if !isFolder {
                // Rich text content — takes remaining space
                RichTextEditor(attributedText: $attributedContent, onCoordinator: { editorCoordinator = $0 })
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(.horizontal, 16)

                // Bottom controls
                VStack(alignment: .leading, spacing: 8) {
                    // Token buttons
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Insert Token")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            tokenButton("{{clipboard}}")
                            tokenButton("{{date}}")
                            tokenButton("{{time}}")
                            tokenButton("{{datetime}}")
                        }
                        HStack(spacing: 6) {
                            Text("Custom:")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            tokenButton("{{date:yyyy-MM-dd}}")
                            tokenButton("{{date:MMM d, yyyy}}")
                            tokenButton("{{date:h:mm a}}")
                        }
                    }

                    // Folder picker
                    if !folders.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Folder")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            Picker("", selection: $selectedFolderID) {
                                Text("None").tag(nil as UUID?)
                                ForEach(folders, id: \.id) { folder in
                                    Text(folder.title).tag(folder.id as UUID?)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                    }

                    // Global Shortcut
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Global Shortcut (optional)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        HStack {
                            OptionalShortcutRecorder(keyCombo: $keyCombo)
                            if keyCombo != nil {
                                Button {
                                    keyCombo = nil
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            } else {
                // Folder: just shortcut
                VStack(alignment: .leading, spacing: 4) {
                    Text("Global Shortcut (shows folder menu)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    HStack {
                        OptionalShortcutRecorder(keyCombo: $keyCombo)
                        if keyCombo != nil {
                            Button {
                                keyCombo = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            snippetDebugLog("onAppear: snippet=\(snippet == nil ? "nil" : snippet!.id.uuidString)")
            if let s = snippet {
                title = s.title
                content = s.content
                keyCombo = s.keyCombo
                isFolder = s.isFolder
                selectedFolderID = s.folderID
                iconName = s.iconName
                matchDestinationFont = s.matchDestinationFont
                snippetDebugLog("onAppear EDIT: content=\"\(s.content.prefix(40))\" rtf=\(s.rtfData?.count ?? 0)b")
                if let rtf = s.rtfData, let attr = NSAttributedString(rtf: rtf, documentAttributes: nil) {
                    snippetDebugLog("  loaded RTF attr.length=\(attr.length)")
                    attributedContent = NSMutableAttributedString(attributedString: attr)
                } else if !s.content.isEmpty {
                    snippetDebugLog("  loaded plain text")
                    attributedContent = NSMutableAttributedString(string: s.content, attributes: [
                        .font: NSFont.systemFont(ofSize: 13)
                    ])
                } else {
                    snippetDebugLog("  WARNING: content and rtfData both empty!")
                }
            } else {
                snippetDebugLog("onAppear NEW snippet")
                selectedFolderID = folderID
                isFolder = false
                attributedContent = NSMutableAttributedString(string: "", attributes: [
                    .font: NSFont.systemFont(ofSize: 13)
                ])
            }
        }
    }

    private var editorTitle: String {
        if let s = snippet {
            return s.isFolder ? "Edit Folder" : "Edit Snippet"
        }
        return "New Snippet"
    }

    private func tokenButton(_ token: String) -> some View {
        Button {
            editorCoordinator?.insertText(token)
        } label: {
            Text(token)
                .font(.system(size: 10, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    private func save() {
        snippetDebugLog("SAVE: coordinator=\(editorCoordinator != nil), tv=\(editorCoordinator?.textView != nil), snapshot=\(editorCoordinator?.latestAttributedString?.length ?? -1)")
        let liveContent: NSAttributedString
        if let snapshot = editorCoordinator?.latestAttributedString {
            liveContent = snapshot
            snippetDebugLog("  source=snapshot len=\(snapshot.length)")
        } else if let tv = editorCoordinator?.textView {
            liveContent = tv.attributedString()
            snippetDebugLog("  source=textView len=\(liveContent.length)")
        } else {
            liveContent = attributedContent
            snippetDebugLog("  source=@State len=\(attributedContent.length)")
        }
        let plainText = liveContent.string
        let rtf = try? liveContent.data(from: NSRange(location: 0, length: liveContent.length),
                                         documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        snippetDebugLog("  plainText=\"\(plainText.prefix(60))\" rtf=\(rtf?.count ?? 0)b")

        if let s = snippet {
            s.title = title
            s.keyCombo = keyCombo
            s.iconName = iconName
            if !s.isFolder {
                s.content = plainText
                s.rtfData = rtf
                s.folderID = selectedFolderID
                s.matchDestinationFont = matchDestinationFont
            }
            snippetDebugLog("  UPDATED id=\(s.id) content=\"\(s.content.prefix(40))\" rtf=\(s.rtfData?.count ?? 0)b")
        } else {
            let s = SavedSnippet(title: title, content: plainText, order: nextOrder, folderID: selectedFolderID)
            s.keyCombo = keyCombo
            s.iconName = iconName
            s.rtfData = rtf
            s.matchDestinationFont = matchDestinationFont
            modelContext.insert(s)
            snippetDebugLog("  CREATED id=\(s.id) content=\"\(s.content.prefix(40))\"")
        }
        try? modelContext.save()
        snippetDebugLog("  modelContext.save() called")
        onSave()
    }
}

// Global flag to suppress KeyEventHandler while recording a shortcut
var isRecordingShortcut = false

// Reusable shortcut recorder for optional KeyCombo (global shortcuts require modifier)
struct OptionalShortcutRecorder: View {
    @Binding var keyCombo: KeyCombo?
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
                } else if let combo = keyCombo {
                    Text(combo.displayString)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                } else {
                    Text("None")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
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
        isRecordingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.carbonFlags
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return nil
            }
            // Global shortcuts require at least one modifier
            guard modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 else {
                return nil
            }
            keyCombo = KeyCombo(keyCode: UInt32(event.keyCode), modifiers: modifiers)
            stopRecording()
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

// MARK: - Rich Text Editor

struct RichTextEditor: NSViewRepresentable {
    @Binding var attributedText: NSMutableAttributedString
    var onCoordinator: ((RichTextEditorCoordinator) -> Void)?

    func makeCoordinator() -> RichTextEditorCoordinator {
        RichTextEditorCoordinator(attributedText: $attributedText)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isRichText = true
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.delegate = context.coordinator
        context.coordinator.textView = textView

        if attributedText.length > 0 {
            textView.textStorage?.setAttributedString(attributedText)
            context.coordinator.latestAttributedString = NSAttributedString(attributedString: attributedText)
        }

        context.coordinator.installClickOutsideMonitor()

        DispatchQueue.main.async {
            onCoordinator?(context.coordinator)
        }

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        let currentLen = textView.attributedString().length
        let newLen = attributedText.length
        snippetDebugLog("updateNSView: currentLen=\(currentLen) newLen=\(newLen)")
        if newLen > 0 && currentLen == 0 {
            snippetDebugLog("  pushing attributedText to NSTextView")
            textView.textStorage?.setAttributedString(attributedText)
            context.coordinator.latestAttributedString = NSAttributedString(attributedString: attributedText)
        }
    }
}

// Bullet/list prefix pattern: optional tabs + (• or digits.) + space/tab
private let bulletPrefixPattern = try! NSRegularExpression(pattern: #"^(\t*)(•|\d+\.)\s?"#)

/// Returns the bullet prefix of a line (e.g. "\t• ", "1.\t", etc.) or nil
private func bulletPrefix(of line: String) -> String? {
    let range = NSRange(line.startIndex..., in: line)
    guard let match = bulletPrefixPattern.firstMatch(in: line, range: range),
          let matchRange = Range(match.range, in: line) else { return nil }
    return String(line[matchRange])
}

/// Returns (lineRange, lineContent) for the line containing the given character index
private func currentLine(in string: String, at location: Int) -> (Range<String.Index>, String)? {
    guard location <= string.count else { return nil }
    let idx = string.index(string.startIndex, offsetBy: min(location, string.count))
    let lineRange = string.lineRange(for: idx..<idx)
    return (lineRange, String(string[lineRange]))
}

class RichTextEditorCoordinator: NSObject, NSTextViewDelegate {
    @Binding var attributedText: NSMutableAttributedString
    var textView: NSTextView?
    private var clickMonitor: Any?
    /// Always-current snapshot of the text view content, updated on every change
    var latestAttributedString: NSAttributedString?

    init(attributedText: Binding<NSMutableAttributedString>) {
        _attributedText = attributedText
        super.init()
    }

    /// Install a local event monitor that resigns first responder when clicking outside the text view
    /// Only resigns on clicks that don't land on any button/control, so Save/Cancel still work
    func installClickOutsideMonitor() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let tv = self?.textView, let window = tv.window else { return event }
            let loc = tv.convert(event.locationInWindow, from: nil)
            if !tv.bounds.contains(loc) {
                // Check if the click landed on an interactive control — if so, don't interfere
                if let hitView = window.contentView?.hitTest(event.locationInWindow),
                   hitView is NSButton || hitView is NSControl || hitView is NSTextField ||
                   hitView.superview is NSButton || hitView.superview?.superview is NSButton {
                    // Let the button/control handle it normally
                } else {
                    window.makeFirstResponder(nil)
                }
            }
            return event
        }
    }

    func removeClickOutsideMonitor() {
        if let m = clickMonitor {
            NSEvent.removeMonitor(m)
            clickMonitor = nil
        }
    }

    deinit {
        removeClickOutsideMonitor()
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = textView else { return }
        let snapshot = NSMutableAttributedString(attributedString: tv.attributedString())
        latestAttributedString = snapshot
        attributedText = snapshot
    }

    func insertText(_ text: String) {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
        tv.insertText(text, replacementRange: tv.selectedRange())
    }

    // MARK: - Command handling for bullets

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        let str = textView.string
        let loc = textView.selectedRange().location

        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            return handleNewline(textView: textView, string: str, location: loc)
        }

        if commandSelector == #selector(NSResponder.deleteBackward(_:)) {
            return handleDeleteBackward(textView: textView, string: str, location: loc)
        }

        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            return handleTab(textView: textView, string: str, location: loc)
        }

        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            return handleBacktab(textView: textView, string: str, location: loc)
        }

        return false
    }

    private func handleNewline(textView: NSTextView, string: String, location: Int) -> Bool {
        guard let (lineRange, line) = currentLine(in: string, at: location) else { return false }
        guard let prefix = bulletPrefix(of: line) else { return false }

        // If line is ONLY the bullet prefix (empty bullet), remove it
        let trimmedLine = line.replacingOccurrences(of: "\n", with: "")
        if trimmedLine == prefix.replacingOccurrences(of: "\n", with: "").trimmingCharacters(in: .whitespaces) ||
           trimmedLine.trimmingCharacters(in: .whitespaces) == prefix.trimmingCharacters(in: .whitespacesAndNewlines) {
            // Remove the bullet prefix from this line
            let nsRange = NSRange(lineRange, in: string)
            textView.insertText("\n", replacementRange: NSRange(location: nsRange.location, length: nsRange.length - (line.hasSuffix("\n") ? 1 : 0)))
            return true
        }

        // Auto-continue: insert newline + same prefix
        // For numbered lists, increment the number
        var newPrefix = prefix
        if let numMatch = try? NSRegularExpression(pattern: #"^(\t*)(\d+)\."#).firstMatch(in: prefix, range: NSRange(prefix.startIndex..., in: prefix)),
           let numRange = Range(numMatch.range(at: 2), in: prefix),
           let num = Int(prefix[numRange]) {
            let tabs = prefix[prefix.startIndex..<numRange.lowerBound]
            newPrefix = "\(tabs)\(num + 1). "
        }

        textView.insertText("\n\(newPrefix)", replacementRange: textView.selectedRange())
        return true
    }

    private func handleDeleteBackward(textView: NSTextView, string: String, location: Int) -> Bool {
        guard location > 0 else { return false }
        guard let (lineRange, line) = currentLine(in: string, at: location) else { return false }
        guard let prefix = bulletPrefix(of: line) else { return false }

        // Calculate cursor position within the line
        let lineStart = string.distance(from: string.startIndex, to: lineRange.lowerBound)
        let cursorInLine = location - lineStart

        // If cursor is within or right after the bullet prefix, don't delete into it
        if cursorInLine <= prefix.count {
            return true // Swallow the backspace
        }

        return false // Let normal backspace happen
    }

    private func handleTab(textView: NSTextView, string: String, location: Int) -> Bool {
        guard let (lineRange, line) = currentLine(in: string, at: location) else { return false }
        guard bulletPrefix(of: line) != nil else { return false }

        // Add a tab at the start of the line to indent the bullet
        let lineStart = NSRange(lineRange, in: string).location
        textView.insertText("\t", replacementRange: NSRange(location: lineStart, length: 0))
        return true
    }

    private func handleBacktab(textView: NSTextView, string: String, location: Int) -> Bool {
        guard let (lineRange, line) = currentLine(in: string, at: location) else { return false }
        guard bulletPrefix(of: line) != nil else { return false }

        // Remove one leading tab if present
        if line.hasPrefix("\t") {
            let lineStart = NSRange(lineRange, in: string).location
            textView.insertText("", replacementRange: NSRange(location: lineStart, length: 1))
        }
        return true
    }

    // MARK: - Formatting Actions

    func toggleBold() {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        guard range.length > 0 else {
            var attrs = tv.typingAttributes
            if let font = attrs[.font] as? NSFont {
                attrs[.font] = toggleBoldTrait(font)
                tv.typingAttributes = attrs
            }
            return
        }
        tv.textStorage?.enumerateAttribute(.font, in: range) { value, attrRange, _ in
            if let font = value as? NSFont {
                tv.textStorage?.addAttribute(.font, value: toggleBoldTrait(font), range: attrRange)
            }
        }
        textDidChange(Notification(name: .init("")))
    }

    func toggleItalic() {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        guard range.length > 0 else {
            var attrs = tv.typingAttributes
            if let font = attrs[.font] as? NSFont {
                attrs[.font] = toggleItalicTrait(font)
                tv.typingAttributes = attrs
            }
            return
        }
        tv.textStorage?.enumerateAttribute(.font, in: range) { value, attrRange, _ in
            if let font = value as? NSFont {
                tv.textStorage?.addAttribute(.font, value: toggleItalicTrait(font), range: attrRange)
            }
        }
        textDidChange(Notification(name: .init("")))
    }

    func toggleUnderline() {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        guard range.length > 0 else {
            var attrs = tv.typingAttributes
            let current = attrs[.underlineStyle] as? Int ?? 0
            attrs[.underlineStyle] = current == 0 ? NSUnderlineStyle.single.rawValue : 0
            tv.typingAttributes = attrs
            return
        }
        tv.textStorage?.enumerateAttribute(.underlineStyle, in: range) { value, attrRange, _ in
            let current = value as? Int ?? 0
            let newVal = current == 0 ? NSUnderlineStyle.single.rawValue : 0
            tv.textStorage?.addAttribute(.underlineStyle, value: newVal, range: attrRange)
        }
        textDidChange(Notification(name: .init("")))
    }

    func setFontSize(_ size: CGFloat) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        if range.length == 0 {
            var attrs = tv.typingAttributes
            if let font = attrs[.font] as? NSFont {
                attrs[.font] = NSFontManager.shared.convert(font, toSize: size)
                tv.typingAttributes = attrs
            }
            return
        }
        tv.textStorage?.enumerateAttribute(.font, in: range) { value, attrRange, _ in
            if let font = value as? NSFont {
                tv.textStorage?.addAttribute(.font, value: NSFontManager.shared.convert(font, toSize: size), range: attrRange)
            }
        }
        textDidChange(Notification(name: .init("")))
    }

    func setFontFamily(_ family: String) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        if range.length == 0 {
            var attrs = tv.typingAttributes
            if let font = attrs[.font] as? NSFont {
                attrs[.font] = NSFontManager.shared.convert(font, toFamily: family)
                tv.typingAttributes = attrs
            }
            return
        }
        tv.textStorage?.enumerateAttribute(.font, in: range) { value, attrRange, _ in
            if let font = value as? NSFont {
                tv.textStorage?.addAttribute(.font, value: NSFontManager.shared.convert(font, toFamily: family), range: attrRange)
            }
        }
        textDidChange(Notification(name: .init("")))
    }

    func insertBullet() {
        guard let tv = textView else { return }
        let str = tv.string
        let loc = tv.selectedRange().location
        if let (lineRange, line) = currentLine(in: str, at: loc) {
            if bulletPrefix(of: line) != nil {
                // Already has bullet — remove it
                let nsRange = NSRange(lineRange, in: str)
                guard let prefix = bulletPrefix(of: line) else { return }
                let rest = String(line.dropFirst(prefix.count))
                tv.insertText(rest, replacementRange: NSRange(location: nsRange.location, length: line.count - (line.hasSuffix("\n") ? 1 : 0)))
            } else {
                // Add bullet at line start
                let lineStart = NSRange(lineRange, in: str).location
                tv.insertText("• ", replacementRange: NSRange(location: lineStart, length: 0))
            }
        } else {
            tv.insertText("• ", replacementRange: tv.selectedRange())
        }
    }

    func insertNumberedList() {
        guard let tv = textView else { return }
        let str = tv.string
        let loc = tv.selectedRange().location
        if let (lineRange, line) = currentLine(in: str, at: loc) {
            if bulletPrefix(of: line) != nil {
                // Already has bullet — remove it
                let nsRange = NSRange(lineRange, in: str)
                guard let prefix = bulletPrefix(of: line) else { return }
                let rest = String(line.dropFirst(prefix.count))
                tv.insertText(rest, replacementRange: NSRange(location: nsRange.location, length: line.count - (line.hasSuffix("\n") ? 1 : 0)))
            } else {
                // Add number at line start
                let lineStart = NSRange(lineRange, in: str).location
                tv.insertText("1. ", replacementRange: NSRange(location: lineStart, length: 0))
            }
        } else {
            tv.insertText("1. ", replacementRange: tv.selectedRange())
        }
    }

    private func toggleBoldTrait(_ font: NSFont) -> NSFont {
        let fm = NSFontManager.shared
        if font.fontDescriptor.symbolicTraits.contains(.bold) {
            return fm.convert(font, toNotHaveTrait: .boldFontMask)
        } else {
            return fm.convert(font, toHaveTrait: .boldFontMask)
        }
    }

    private func toggleItalicTrait(_ font: NSFont) -> NSFont {
        let fm = NSFontManager.shared
        if font.fontDescriptor.symbolicTraits.contains(.italic) {
            return fm.convert(font, toNotHaveTrait: .italicFontMask)
        } else {
            return fm.convert(font, toHaveTrait: .italicFontMask)
        }
    }
}

// MARK: - Format Toolbar

struct FormatToolbar: View {
    var coordinator: RichTextEditorCoordinator?
    @State private var selectedSize: CGFloat = 13
    @State private var selectedFont = "System"

    private static let fontSizes: [CGFloat] = [9, 10, 11, 12, 13, 14, 16, 18, 20, 24, 28, 32, 36, 48, 64]
    private static let fontFamilies: [String] = {
        var families = NSFontManager.shared.availableFontFamilies.sorted()
        families.insert("System", at: 0)
        return families
    }()

    var body: some View {
        HStack(spacing: 4) {
            // Font picker
            Picker("", selection: $selectedFont) {
                ForEach(Self.fontFamilies, id: \.self) { family in
                    Text(family).tag(family)
                }
            }
            .labelsHidden()
            .frame(width: 100)
            .onChange(of: selectedFont) { _, newFont in
                if newFont == "System" {
                    coordinator?.setFontFamily(".AppleSystemUIFont")
                } else {
                    coordinator?.setFontFamily(newFont)
                }
            }

            // Size picker
            Picker("", selection: $selectedSize) {
                ForEach(Self.fontSizes, id: \.self) { size in
                    Text("\(Int(size))").tag(size)
                }
            }
            .labelsHidden()
            .frame(width: 52)
            .onChange(of: selectedSize) { _, newSize in
                coordinator?.setFontSize(newSize)
            }

            Divider().frame(height: 16)

            // Bold
            formatButton("bold", icon: "bold") { coordinator?.toggleBold() }
            // Italic
            formatButton("italic", icon: "italic") { coordinator?.toggleItalic() }
            // Underline
            formatButton("underline", icon: "underline") { coordinator?.toggleUnderline() }

            Divider().frame(height: 16)

            // Bullet list toggle
            formatButton("bullet list", icon: "list.bullet") { coordinator?.insertBullet() }

            // Numbered list toggle
            formatButton("numbered list", icon: "list.number") { coordinator?.insertNumberedList() }

            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func formatButton(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label.capitalized)
    }
}

// MARK: - SF Symbol Picker

struct SFSymbolCategory: Identifiable {
    let id: String
    let label: String
    let icon: String
    let keywords: [String]
}

private let sfCategories: [SFSymbolCategory] = [
    .init(id: "all", label: "All", icon: "square.grid.2x2", keywords: []),
    .init(id: "communication", label: "Communication", icon: "message", keywords: [
        "envelope", "phone", "message", "bubble", "paperplane", "video",
        "teletype", "antenna", "megaphone", "mic", "speaker", "mail",
    ]),
    .init(id: "weather", label: "Weather", icon: "cloud.sun", keywords: [
        "sun", "moon", "cloud", "snow", "wind", "tornado", "hurricane",
        "thermometer", "humidity", "umbrella", "rainbow", "sparkle",
    ]),
    .init(id: "maps", label: "Maps", icon: "map", keywords: [
        "map", "pin", "mappin", "location", "globe", "compass", "safari",
        "building", "house", "flag", "signpost",
    ]),
    .init(id: "objects", label: "Objects & Tools", icon: "wrench", keywords: [
        "pencil", "eraser", "scissors", "wrench", "hammer", "screwdriver",
        "paintbrush", "eyedropper", "magnifyingglass", "flashlight",
        "briefcase", "suitcase", "basket", "cart", "bag", "gift",
        "lightbulb", "lamp", "fan", "key", "lock", "pin", "link",
        "paperclip", "ruler", "level", "stethoscope", "bandage",
        "cross", "pills", "syringe", "wand", "crown", "trophy",
        "medal", "rosette", "seal", "graduationcap",
    ]),
    .init(id: "devices", label: "Devices", icon: "desktopcomputer", keywords: [
        "iphone", "ipad", "macbook", "desktopcomputer", "laptop", "display",
        "server", "cpu", "memorychip", "printer", "scanner", "keyboard",
        "mouse", "trackpad", "headphones", "earbuds", "airpod",
        "homepod", "appletv", "watch", "visionpro", "camera",
    ]),
    .init(id: "connectivity", label: "Connectivity", icon: "wifi", keywords: [
        "wifi", "antenna", "radiowaves", "bluetooth", "airplay",
        "personalhotspot", "network", "cable", "sensor",
    ]),
    .init(id: "transport", label: "Transportation", icon: "car", keywords: [
        "car", "bus", "tram", "train", "ferry", "airplane", "bicycle",
        "scooter", "skateboard", "fuelpump", "ev.plug", "road", "steeringwheel",
    ]),
    .init(id: "human", label: "Human", icon: "person", keywords: [
        "person", "figure", "hand", "eye", "ear", "nose", "mouth",
        "brain", "lungs", "heart.text", "face", "mustache",
    ]),
    .init(id: "nature", label: "Nature", icon: "leaf", keywords: [
        "leaf", "tree", "flower", "drop", "flame", "bolt", "water",
        "mountain", "fossil", "pawprint", "hare", "tortoise", "bird",
        "fish", "ant", "ladybug", "dog", "cat", "lizard",
    ]),
    .init(id: "editing", label: "Editing", icon: "slider.horizontal.3", keywords: [
        "slider", "dial", "gauge", "tuningfork", "waveform",
        "crop", "selection", "lasso",
    ]),
    .init(id: "text", label: "Text Formatting", icon: "textformat", keywords: [
        "textformat", "bold", "italic", "underline", "strikethrough",
        "character", "paragraph", "list", "increase", "decrease", "text.",
    ]),
    .init(id: "media", label: "Media", icon: "play", keywords: [
        "play", "pause", "stop", "record", "forward", "backward",
        "music", "note", "radio", "film", "photo", "video",
    ]),
    .init(id: "commerce", label: "Commerce", icon: "creditcard", keywords: [
        "creditcard", "banknote", "coloncurrency", "dollar", "sterling",
        "euro", "yen", "rubl", "tugrik", "lira", "won", "rupee",
        "percent", "chart", "bag", "cart", "barcode", "qrcode",
    ]),
    .init(id: "time", label: "Time", icon: "clock", keywords: [
        "clock", "alarm", "timer", "stopwatch", "calendar",
        "hourglass",
    ]),
    .init(id: "privacy", label: "Privacy & Security", icon: "lock", keywords: [
        "lock", "shield", "checkmark.shield", "hand.raised",
        "eye.slash", "faceid", "touchid",
    ]),
    .init(id: "shapes", label: "Shapes", icon: "circle", keywords: [
        "circle", "square", "rectangle", "triangle", "diamond",
        "hexagon", "pentagon", "octagon", "oval", "capsule",
        "rhombus", "seal", "shield", "star", "heart", "suit",
    ]),
    .init(id: "arrows", label: "Arrows", icon: "arrow.right", keywords: [
        "arrow", "chevron", "arrowtriangle",
    ]),
    .init(id: "indices", label: "Indices", icon: "a.circle", keywords: [
        ".circle", ".square",
    ]),
    .init(id: "math", label: "Math", icon: "plus", keywords: [
        "plus", "minus", "multiply", "divide", "equal", "lessthan",
        "greaterthan", "number", "sum", "percent",
    ]),
    .init(id: "keyboard", label: "Keyboard", icon: "keyboard", keywords: [
        "keyboard", "command", "option", "control", "shift", "delete",
        "return", "escape", "power", "eject", "globe",
    ]),
    .init(id: "gaming", label: "Gaming", icon: "gamecontroller", keywords: [
        "gamecontroller", "dpad", "l.joystick", "r.joystick",
        "circle.grid", "puzzlepiece",
    ]),
    .init(id: "health", label: "Health", icon: "heart", keywords: [
        "heart", "waveform", "staroflife", "medical", "cross.vial",
    ]),
    .init(id: "home", label: "Home", icon: "house", keywords: [
        "house", "door", "bed", "sofa", "chair", "table",
        "oven", "refrigerator", "washer", "lamp", "fan", "spigot",
        "shower", "bathtub", "lightswitch", "powerplug",
    ]),
    .init(id: "doc", label: "Documents", icon: "doc", keywords: [
        "doc", "folder", "tray", "archivebox", "clipboard", "note",
        "book", "magazine", "newspaper", "menucard",
    ]),
]

class SFSymbolLoader {
    static let shared = SFSymbolLoader()

    private(set) var allSymbols: [String] = []
    private(set) var categorized: [String: [String]] = [:]
    private var loaded = false

    func load() {
        guard !loaded else { return }
        loaded = true

        let localeSuffixes = [".ar", ".hi", ".zh", ".th", ".ja", ".ko", ".he", ".km", ".my", ".bn", ".gu", ".kn", ".ml", ".mr", ".or", ".pa", ".si", ".ta", ".te", ".ur"]

        let path = "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist"
        guard let dict = NSDictionary(contentsOfFile: path),
              let symbols = dict["symbols"] as? [String: Any] else { return }

        var names = Array(symbols.keys)
            .filter { name in !localeSuffixes.contains(where: { name.hasSuffix($0) }) }
            .sorted()

        allSymbols = names

        // Build category index
        for cat in sfCategories where cat.id != "all" {
            categorized[cat.id] = names.filter { name in
                cat.keywords.contains { kw in name.contains(kw) }
            }
        }
    }

    func symbols(for categoryID: String, search: String) -> [String] {
        let base = categoryID == "all" ? allSymbols : (categorized[categoryID] ?? [])
        if search.isEmpty { return base }
        return base.filter { $0.localizedCaseInsensitiveContains(search) }
    }
}

struct SFSymbolPicker: View {
    @Binding var selected: String?
    var onDismiss: () -> Void
    @State private var search = ""
    @State private var selectedCategory = "all"
    @State private var symbols: [String] = []

    private let loader = SFSymbolLoader.shared

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                TextField("Search symbols...", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                if selected != nil {
                    Button {
                        selected = nil
                        onDismiss()
                    } label: {
                        Text("Clear")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            // Category toolbar
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(sfCategories) { cat in
                        categoryChip(cat)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }

            Divider()

            // Symbol grid
            ScrollView {
                if symbols.isEmpty {
                    Text("No symbols found")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 30)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 34, maximum: 40), spacing: 2)], spacing: 2) {
                        ForEach(symbols, id: \.self) { name in
                            symbolButton(name)
                        }
                    }
                    .padding(6)
                }
            }
        }
        .frame(width: 320, height: 360)
        .onAppear {
            loader.load()
            updateSymbols()
        }
        .onChange(of: search) { _, _ in updateSymbols() }
        .onChange(of: selectedCategory) { _, _ in updateSymbols() }
    }

    private func updateSymbols() {
        symbols = loader.symbols(for: selectedCategory, search: search)
    }

    private func categoryChip(_ cat: SFSymbolCategory) -> some View {
        let isActive = selectedCategory == cat.id
        return Button {
            selectedCategory = cat.id
        } label: {
            Image(systemName: cat.icon)
                .font(.system(size: 11))
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isActive ? Color.accentColor.opacity(0.2) : Color.clear)
                )
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .help(cat.label)
    }

    private func symbolButton(_ name: String) -> some View {
        Button {
            selected = name
            onDismiss()
        } label: {
            Image(systemName: name)
                .font(.system(size: 14))
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected == name ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.04))
                )
                .foregroundStyle(selected == name ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
        .help(name)
    }
}
