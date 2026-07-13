import SwiftUI

struct ClipboardRowView: View {
    let entry: ClipboardEntry
    let isSelected: Bool
    /// 1-based position in the multi-select paste order, when more than one item is selected.
    var selectionIndex: Int? = nil

    private var thumbnailBytes: Data? {
        entry.thumbnailData ?? entry.imageData
    }

    private var hasVisualPreview: Bool {
        thumbnailBytes != nil
    }

    private func thumbnailView(nsImage: NSImage) -> some View {
        let imgW = nsImage.size.width
        let imgH = nsImage.size.height
        let maxH: CGFloat = hasVisualPreview ? 64 : 36
        let maxW: CGFloat = 80
        let scaleH = imgH > 0 ? maxH / imgH : 1
        let scaleW = imgW > 0 ? maxW / imgW : 1
        let scale = min(scaleH, scaleW, 1)
        let w = imgW * scale
        let h = imgH * scale
        // Pre-render at exact target size so SwiftUI can't resize it
        let rendered = NSImage(size: NSSize(width: w, height: h))
        rendered.lockFocus()
        nsImage.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        rendered.unlockFocus()

        return Image(nsImage: rendered)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
    }

    /// Small site-favicon badge for the bottom-right corner of the source app icon.
    @ViewBuilder
    private var faviconBadge: some View {
        if let data = entry.faviconData, let favicon = NSImage(data: data) {
            Image(nsImage: favicon)
                .resizable()
                .interpolation(.high)
                .frame(width: 14, height: 14)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(.white.opacity(0.9), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                .offset(x: 4, y: 4)
        }
    }

    /// Numbered chip showing where this item lands in the paste order.
    @ViewBuilder
    private var orderBadge: some View {
        if let index = selectionIndex {
            Text("\(index)")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(minWidth: 16)
                .padding(.vertical, 1)
                .background(Color(nsColor: .controlAccentColor), in: Capsule())
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            orderBadge

            // App icon
            if entry.contentType == .screenshot {
                Image(systemName: "macbook")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            } else {
                Image(nsImage: AppIconResolver.shared.icon(forBundleID: entry.sourceAppBundleID))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 28, height: 28)
                    .shadow(color: .black.opacity(0.1), radius: 1, y: 1)
                    .overlay(alignment: .bottomTrailing) { faviconBadge }
            }

            // Content preview
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.firstLine ?? entry.contentType.label)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 6) {
                    Text(entry.sourceAppName ?? "Unknown")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)

                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)

                    Text(entry.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute().second())
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)

                    if let domain = entry.sourceDomain {
                        Text("·")
                            .font(.system(size: 10))
                            .foregroundStyle(.quaternary)
                        HStack(spacing: 2) {
                            Image(systemName: "globe")
                                .font(.system(size: 8))
                            Text(domain)
                                .font(.system(size: 10.5))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .foregroundStyle(.blue)
                    }
                }
            }

            Spacer(minLength: 4)

            // Thumbnail — fit within 120 x maxH, preserving aspect ratio
            if let data = thumbnailBytes, let nsImage = NSImage(data: data) {
                thumbnailView(nsImage: nsImage)
            }

            if entry.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, hasVisualPreview ? 6 : 7)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Color(nsColor: .controlAccentColor).opacity(0.25) : Color.clear)
        )
        .contentShape(Rectangle())
    }
}
