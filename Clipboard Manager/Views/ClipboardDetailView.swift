import SwiftUI

struct ClipboardDetailView: View {
    let entry: ClipboardEntry
    let onCopyPlain: () -> Void
    let onCopyFormatted: () -> Void
    var onDelete: (() -> Void)? = nil
    var onSaveSnippet: (() -> Void)? = nil

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
            if (entry.contentType == .image || entry.contentType == .screenshot || entry.contentType == .file),
               let data = entry.imageData, let nsImage = NSImage(data: data) {
                ZoomableImageView(image: nsImage)
                    .frame(maxHeight: 300)
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

struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 1.0
        scrollView.maxMagnification = 5.0
        scrollView.magnification = 1.0

        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        imageView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = imageView

        let clipView = scrollView.contentView
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: clipView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            imageView.widthAnchor.constraint(equalTo: clipView.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: clipView.heightAnchor),
        ])

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let imageView = nsView.documentView as? NSImageView {
            imageView.image = image
        }
    }
}
