import SwiftUI
import SwiftData

struct ClipboardDetailView: View {
    let entry: ClipboardEntry
    let onCopyPlain: () -> Void
    let onCopyFormatted: () -> Void
    var onDelete: (() -> Void)? = nil
    var onSaveSnippet: (() -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @State private var loadedFullImage: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 8) {
                Image(nsImage: AppIconResolver.shared.icon(forBundleID: entry.sourceAppBundleID))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 18, height: 18)

                Text(entry.sourceAppName ?? "Unknown")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text("·")
                    .foregroundStyle(.quaternary)

                Text(entry.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute().second())
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)

                Spacer()

                // Action buttons
                HStack(spacing: 4) {
                    if let onSaveSnippet = onSaveSnippet {
                        Button {
                            onSaveSnippet()
                        } label: {
                            Image(systemName: "star")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Save to Snippets")
                    }
                    if let onDelete = onDelete {
                        Button {
                            onDelete()
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red.opacity(0.7))
                        .help("Delete")
                    }
                }
            }
            .padding(12)

            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 1)
                .padding(.horizontal, 12)

            // Content area
            let _ = debugLogDetail("popover opened: type=\(entry.contentType) hasText=\(entry.textContent != nil) hasRTF=\(entry.rtfData != nil) textLen=\(entry.textContent?.count ?? 0)")
            if entry.contentType == .image || entry.contentType == .screenshot || entry.contentType == .file {
                imagePreviewSection
            } else if entry.contentType == .rtf, let rtfData = entry.rtfData {
                let height = rtfHeight(for: rtfData)
                let _ = debugLogDetail("rtf path: height=\(Int(height))")
                SelectableRTFView(rtfData: rtfData)
                    .frame(height: height)
            } else if let text = entry.textContent {
                let height = textHeight(for: text)
                let _ = debugLogDetail("plain text path: height=\(Int(height))")
                SelectableTextView(text: text)
                    .frame(height: height)
            } else if let paths = entry.filePaths {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(paths, id: \.self) { path in
                        HStack(spacing: 6) {
                            Image(systemName: "doc")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Text(URL(fileURLWithPath: path).lastPathComponent)
                                .font(.system(size: 12))
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(12)
            }
        }
        .background(Color.primary.opacity(0.02))
    }

    @ViewBuilder
    private var imagePreviewSection: some View {
        Group {
            if let nsImage = loadedFullImage {
                ZoomableImageView(image: nsImage)
            } else if let data = entry.thumbnailData, let nsImage = NSImage(data: data) {
                // Show thumbnail upscaled while full image loads
                ZoomableImageView(image: nsImage)
                    .opacity(0.6)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .frame(minWidth: 320, minHeight: 320, idealHeight: 480, maxHeight: 600)
        .task(id: entry.id) {
            loadedFullImage = nil
            let entryID = entry.id
            let inlineData = entry.imageData
            let context = modelContext
            let loaded: NSImage? = await Task.detached(priority: .userInitiated) {
                if let data = inlineData, let img = NSImage(data: data) { return img }
                let blobData = await MainActor.run {
                    ClipboardImageStore.fullData(for: entryID, context: context)
                }
                if let blobData, let img = NSImage(data: blobData) { return img }
                return nil
            }.value
            loadedFullImage = loaded
        }
    }
}

private func debugLogDetail(_ message: String) {
    let path = "/tmp/clipboard-manager-debug.log"
    let line = "\(ISO8601DateFormatter().string(from: Date())): \(message)\n"
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
    }
}

extension ClipboardDetailView {
    func textHeight(for text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12)
        let panelWidth = NSApp.windows.first(where: { $0 is ClipboardPanel })?.frame.width ?? 420
        let textWidth = max(panelWidth - 24, 100)

        // Replicate exact NSTextView layout for accurate measurement
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: textWidth, height: 0))
        textView.font = font
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.size = NSSize(width: textWidth - 24, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let rect = textView.layoutManager!.usedRect(for: textView.textContainer!)
        let height = ceil(rect.height) + 24

        return height
    }

    func rtfHeight(for rtfData: Data) -> CGFloat {
        let panelWidth = NSApp.windows.first(where: { $0 is ClipboardPanel })?.frame.width ?? 420
        // Match the SelectableRTFView: textContainerInset.width=12 on each side
        let textWidth = max(panelWidth - 24, 100)

        let attrString = NSAttributedString(rtf: rtfData, documentAttributes: nil) ?? NSAttributedString(string: "")

        // Replicate exact NSTextView layout for accurate measurement
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: textWidth, height: 0))
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.size = NSSize(width: textWidth - 24, height: CGFloat.greatestFiniteMagnitude)
        textView.textStorage?.setAttributedString(attrString)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let rect = textView.layoutManager!.usedRect(for: textView.textContainer!)
        // Add textContainerInset top + bottom (12 + 12)
        let height = ceil(rect.height) + 24

        let msg = "rtfHeight: textWidth=\(Int(textWidth)) containerW=\(Int(textWidth - 24)) measuredH=\(Int(rect.height)) finalH=\(Int(height)) panelW=\(Int(panelWidth))\n"
        if let fh = FileHandle(forWritingAtPath: "/tmp/clipboard-manager-debug.log") {
            fh.seekToEndOfFile()
            fh.write(msg.data(using: .utf8)!)
            fh.closeFile()
        }
        return height
    }
}

// MARK: - Selectable Text View (NSTextView for proper Cmd+C)

struct SelectableTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textContainer?.lineFragmentPadding = 0
        textView.font = .systemFont(ofSize: 12)
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let textView = nsView.documentView as? NSTextView {
            textView.string = text
        }
    }
}

// MARK: - Selectable RTF View

struct SelectableRTFView: NSViewRepresentable {
    let rtfData: Data

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textContainer?.lineFragmentPadding = 0

        if let attrString = NSAttributedString(rtf: rtfData, documentAttributes: nil) {
            textView.textStorage?.setAttributedString(attrString)
        }

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

// MARK: - Zoomable Image (NSViewRepresentable with pinch support)

struct ZoomableImageView: View {
    let image: NSImage
    @State private var magnify: CGFloat = 1.0
    @State private var lastMagnify: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(magnify)
                .offset(offset)
                .gesture(
                    MagnifyGesture()
                        .onChanged { v in
                            magnify = max(1.0, min(5.0, lastMagnify * v.magnification))
                            if magnify == 1.0 { offset = .zero; lastOffset = .zero }
                        }
                        .onEnded { _ in lastMagnify = magnify }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { v in
                            guard magnify > 1.0 else { return }
                            offset = CGSize(
                                width: lastOffset.width + v.translation.width,
                                height: lastOffset.height + v.translation.height
                            )
                        }
                        .onEnded { _ in lastOffset = offset }
                )
                .onTapGesture(count: 2) {
                    if magnify > 1.0 {
                        magnify = 1.0; lastMagnify = 1.0
                        offset = .zero; lastOffset = .zero
                    } else {
                        magnify = 2.0; lastMagnify = 2.0
                    }
                }
        }
        .clipped()
    }
}
