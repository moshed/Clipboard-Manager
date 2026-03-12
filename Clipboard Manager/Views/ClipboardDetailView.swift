import SwiftUI

struct ClipboardDetailView: View {
    let entry: ClipboardEntry
    let onCopyPlain: () -> Void
    let onCopyFormatted: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Separator
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 1)
                .padding(.horizontal, 12)

            // Content area
            VStack(alignment: .leading, spacing: 10) {
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
                }

                // Full content
                if (entry.contentType == .image || entry.contentType == .screenshot || entry.contentType == .file),
                   let data = entry.imageData, let nsImage = NSImage(data: data) {
                    ZoomableImageView(image: nsImage)
                        .frame(maxHeight: 300)
                } else if entry.contentType == .rtf, let rtfData = entry.rtfData {
                    ScrollView {
                        RTFTextView(rtfData: rtfData)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                } else if let text = entry.textContent {
                    ScrollView {
                        Text(text)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(minHeight: 60, maxHeight: 500)
                } else if let paths = entry.filePaths {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(paths, id: \.self) { path in
                            HStack(spacing: 6) {
                                Image(systemName: "doc")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                Text(URL(fileURLWithPath: path).lastPathComponent)
                                    .font(.system(size: 12))
                            }
                        }
                    }
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.02))
        }
    }
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

        // Pin image view to clip view; scaleProportionallyDown handles aspect ratio
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

// MARK: - RTF Text View

struct RTFTextView: NSViewRepresentable {
    let rtfData: Data

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0

        if let attrString = NSAttributedString(rtf: rtfData, documentAttributes: nil) {
            textView.textStorage?.setAttributedString(attrString)
        }

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = false
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
