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

    @State private var focusedIndex: Int = 0
    @FocusState private var isContainerFocused: Bool

    private var actions: [() -> Void] {
        var list: [() -> Void] = []
        // Date
        for filter in DateFilter.allCases {
            list.append({ dateFilter = filter })
        }
        // Type: All/None + each type
        list.append({
            if typeFilter.count == ContentType.allCases.count {
                typeFilter = []
            } else {
                typeFilter = Set(ContentType.allCases)
            }
        })
        for type in ContentType.allCases {
            list.append({
                if typeFilter.contains(type) {
                    typeFilter.remove(type)
                } else {
                    typeFilter.insert(type)
                }
            })
        }
        // App
        if !availableApps.isEmpty {
            list.append({ appFilter = [] })
            for app in availableApps {
                let bid = app.bundleID
                list.append({
                    if appFilter.contains(bid) {
                        appFilter.remove(bid)
                    } else {
                        appFilter.insert(bid)
                    }
                })
            }
        }
        // Clear All
        if dateFilter != .all || !appFilter.isEmpty || !typeFilter.isEmpty {
            list.append({
                dateFilter = .all
                appFilter = []
                typeFilter = []
            })
        }
        return list
    }

    var body: some View {
        let dateBase = 0
        let typeBase = dateBase + DateFilter.allCases.count
        let appBase = typeBase + 1 + ContentType.allCases.count
        let clearBase = appBase + (availableApps.isEmpty ? 0 : 1 + availableApps.count)

        VStack(alignment: .leading, spacing: 12) {
            // Date section
            VStack(alignment: .leading, spacing: 6) {
                Text("Date")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                FlowLayout(spacing: 4) {
                    ForEach(Array(DateFilter.allCases.enumerated()), id: \.element) { idx, filter in
                        FilterChip(
                            label: filter.rawValue,
                            isSelected: dateFilter == filter,
                            isFocused: focusedIndex == dateBase + idx
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
                    FilterChip(
                        label: typeFilter.count == ContentType.allCases.count ? "None" : "All",
                        isSelected: false,
                        isFocused: focusedIndex == typeBase
                    ) {
                        if typeFilter.count == ContentType.allCases.count {
                            typeFilter = []
                        } else {
                            typeFilter = Set(ContentType.allCases)
                        }
                    }

                    ForEach(Array(ContentType.allCases.enumerated()), id: \.element) { idx, type in
                        FilterChip(
                            label: type.label,
                            icon: type.systemImage,
                            isSelected: typeFilter.contains(type),
                            isFocused: focusedIndex == typeBase + 1 + idx
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

                    let totalRows = availableApps.count + 1
                    let rowHeight: CGFloat = 28
                    let maxVisibleRows = min(totalRows, 6)
                    let listHeight = CGFloat(maxVisibleRows) * rowHeight

                    ScrollView {
                        VStack(spacing: 2) {
                            FilterAppRow(
                                name: "All Apps",
                                icon: nil,
                                isSelected: appFilter.isEmpty,
                                isFocused: focusedIndex == appBase
                            ) {
                                appFilter = []
                            }

                            ForEach(Array(availableApps.enumerated()), id: \.element.bundleID) { idx, app in
                                FilterAppRow(
                                    name: app.name,
                                    icon: AppIconResolver.shared.icon(forBundleID: app.bundleID),
                                    isSelected: appFilter.contains(app.bundleID),
                                    isFocused: focusedIndex == appBase + 1 + idx
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
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(focusedIndex == clearBase ? Color.red.opacity(0.15) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(width: 240)
        .focusable()
        .focused($isContainerFocused)
        .focusEffectDisabled()
        .onAppear {
            focusedIndex = 0
            DispatchQueue.main.async { isContainerFocused = true }
        }
        .onKeyPress(.downArrow) {
            let count = actions.count
            guard count > 0 else { return .ignored }
            focusedIndex = (focusedIndex + 1) % count
            return .handled
        }
        .onKeyPress(.upArrow) {
            let count = actions.count
            guard count > 0 else { return .ignored }
            focusedIndex = (focusedIndex - 1 + count) % count
            return .handled
        }
        .onKeyPress(.return) {
            guard focusedIndex < actions.count else { return .ignored }
            actions[focusedIndex]()
            return .handled
        }
        .onKeyPress(.space) {
            guard focusedIndex < actions.count else { return .ignored }
            actions[focusedIndex]()
            return .handled
        }
    }
}

struct FilterChip: View {
    let label: String
    var icon: String? = nil
    let isSelected: Bool
    var isFocused: Bool = false
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
                    .strokeBorder(
                        isFocused ? Color.accentColor : (isSelected ? Color.accentColor.opacity(0.3) : Color.clear),
                        lineWidth: isFocused ? 1.5 : 1
                    )
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
    var isFocused: Bool = false
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
                    .fill(isFocused ? Color.accentColor.opacity(0.2) : (isSelected ? Color.accentColor.opacity(0.1) : Color.clear))
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
