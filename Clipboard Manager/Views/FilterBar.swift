import SwiftUI

enum DateFilter: String, CaseIterable {
    case all = "All Time"
    case today = "Today"
    case week = "Last 7 Days"
    case month = "Last 30 Days"

    var startDate: Date? {
        switch self {
        case .all: return nil
        case .today: return Calendar.current.startOfDay(for: Date())
        case .week: return Calendar.current.date(byAdding: .day, value: -7, to: Date())
        case .month: return Calendar.current.date(byAdding: .day, value: -30, to: Date())
        }
    }

    var icon: String {
        switch self {
        case .all: return "calendar"
        case .today: return "sun.max"
        case .week: return "calendar.badge.clock"
        case .month: return "calendar.badge.checkmark"
        }
    }
}

struct FilterPopoverView: View {
    @Binding var dateFilter: DateFilter
    @Binding var appFilter: Set<String>
    @Binding var typeFilter: Set<ContentType>
    let availableApps: [(bundleID: String, name: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Date section
            VStack(alignment: .leading, spacing: 6) {
                Text("Date")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                FlowLayout(spacing: 4) {
                    ForEach(DateFilter.allCases, id: \.self) { filter in
                        FilterChip(
                            label: filter.rawValue,
                            isSelected: dateFilter == filter
                        ) {
                            dateFilter = filter
                        }
                    }
                }
            }

            Divider()

            // Type section
            VStack(alignment: .leading, spacing: 6) {
                Text("Type")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                FlowLayout(spacing: 4) {
                    // All/None toggle: selects all types or clears all
                    FilterChip(
                        label: typeFilter.count == ContentType.allCases.count ? "None" : "All",
                        isSelected: false
                    ) {
                        if typeFilter.count == ContentType.allCases.count {
                            typeFilter = []
                        } else {
                            typeFilter = Set(ContentType.allCases)
                        }
                    }
                    ForEach(ContentType.allCases, id: \.self) { type in
                        FilterChip(
                            label: type.label,
                            icon: type.systemImage,
                            isSelected: typeFilter.contains(type)
                        ) {
                            if typeFilter.contains(type) {
                                typeFilter.remove(type)
                            } else {
                                typeFilter.insert(type)
                            }
                        }
                    }
                }
            }

            if !availableApps.isEmpty {
                Divider()

                // App section
                VStack(alignment: .leading, spacing: 6) {
                    Text("App")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)

                    let totalRows = availableApps.count + 1 // +1 for "All Apps"
                    let rowHeight: CGFloat = 28
                    let maxVisibleRows = min(totalRows, 6) // up to 5 apps + "All Apps"
                    let listHeight = CGFloat(maxVisibleRows) * rowHeight

                    ScrollView {
                        VStack(spacing: 2) {
                            FilterAppRow(name: "All Apps", icon: nil, isSelected: appFilter.isEmpty) {
                                appFilter = []
                            }
                            ForEach(availableApps, id: \.bundleID) { app in
                                FilterAppRow(
                                    name: app.name,
                                    icon: AppIconResolver.shared.icon(forBundleID: app.bundleID),
                                    isSelected: appFilter.contains(app.bundleID)
                                ) {
                                    if appFilter.contains(app.bundleID) {
                                        appFilter.remove(app.bundleID)
                                    } else {
                                        appFilter.insert(app.bundleID)
                                    }
                                }
                            }
                        }
                    }
                    .frame(height: listHeight)
                }
            }

            // Clear all
            if dateFilter != .all || !appFilter.isEmpty || !typeFilter.isEmpty {
                Divider()
                Button {
                    dateFilter = .all
                    appFilter = []
                    typeFilter = []
                } label: {
                    HStack {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 11))
                        Text("Clear All Filters")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(width: 240)
    }
}

struct FilterChip: View {
    let label: String
    var icon: String? = nil
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 9))
                }
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
            )
            .foregroundStyle(isSelected ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
    }
}

struct FilterAppRow: View {
    let name: String
    let icon: NSImage?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon = icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 12))
                        .frame(width: 16, height: 16)
                }
                Text(name)
                    .font(.system(size: 12))
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: ProposedViewSize(bounds.size), subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return (CGSize(width: maxWidth, height: y + rowHeight), positions)
    }
}
