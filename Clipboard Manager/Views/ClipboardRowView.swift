import SwiftUI

struct ClipboardRowView: View {
    let entry: ClipboardEntry
    let isSelected: Bool

    private var hasVisualPreview: Bool {
        entry.imageData != nil && (entry.contentType == .image || entry.contentType == .screenshot || entry.contentType == .file)
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

    var body: some View {
        HStack(spacing: 10) {
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
                }
            }

            Spacer(minLength: 4)

            // Thumbnail — fit within 120 x maxH, preserving aspect ratio
            if let data = entry.imageData, let nsImage = NSImage(data: data) {
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
