import SwiftUI

/// The selected item's checks, from its loaded detail: the CI status's popover on the Mac, a sheet
/// on the phone.
struct ItemChecksView: View {
    @Environment(AppModel.self) private var model
    let item: Item
    /// The most the list grows to before it scrolls; nil fills what it's given.
    var maxHeight: CGFloat?

    var body: some View {
        if let detail = model.detail, detail.id == item.id {
            ChecksView(checks: detail.checks, maxHeight: maxHeight)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: maxHeight == nil ? nil : 80, maxHeight: .infinity)
        }
    }
}

/// Checks of the head commit, grouped by state with failures first.
struct ChecksView: View {
    let checks: [Check]
    var maxHeight: CGFloat?
    @State private var expanded: Set<Check.State>
    @State private var contentHeight: CGFloat = 0

    init(checks: [Check], maxHeight: CGFloat? = nil) {
        self.checks = checks
        self.maxHeight = maxHeight
        // Failed and pending ones open; when there are none, the passed ones.
        let unsettled = checks.contains { $0.state == .failed || $0.state == .pending }
        _expanded = State(initialValue: unsettled ? [.failed, .pending] : [.passed])
    }

    var body: some View {
        if checks.isEmpty {
            ContentUnavailableView("No Checks", systemImage: "checkmark.seal")
                .frame(minHeight: maxHeight == nil ? nil : 120)
        } else {
            ScrollView {
                groups
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            // Sized to its content up to the cap, so a popover is as tall as the list it shows.
            .frame(height: maxHeight.map { min(max(contentHeight, 1), $0) })
        }
    }

    private var groups: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Check.State.allCases, id: \.self) { state in
                let group = checks.filter { $0.state == state }.sorted { $0.name < $1.name }
                if !group.isEmpty {
                    let isExpanded = expanded.contains(state)
                    VStack(alignment: .leading, spacing: 1) {
                        Button {
                            withAnimation(.snappy(duration: 0.2)) {
                                if isExpanded { expanded.remove(state) } else { expanded.insert(state) }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                                    .frame(width: 10)
                                Text(state.title)
                                Text(String(group.count)).monospacedDigit()
                                    .foregroundStyle(.tertiaryText)
                                Spacer(minLength: 0)
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if isExpanded {
                            // By position: one workflow can report the same app and name twice
                            // (e.g. pre-commit for both the push and the pull request).
                            ForEach(Array(group.enumerated()), id: \.offset) { CheckRow(check: $0.element) }
                        }
                    }
                }
            }
        }
        .padding(8)
    }
}

private struct CheckRow: View {
    let check: Check
    @State private var isHovered = false

    var body: some View {
        Button {
            if let url = check.url.flatMap(URL.init(string:)) { Platform.open(url) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: check.state.symbol)
                    .foregroundStyle(check.state.color)
                Text(check.name).lineLimit(1).truncationMode(.middle)
                if let app = check.app {
                    Text(app).foregroundStyle(.tertiaryText).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let duration {
                    Text(duration).foregroundStyle(.secondaryText).monospacedDigit()
                }
                if check.url != nil {
                    Image(systemName: "arrow.up.right").foregroundStyle(.tertiaryText)
                }
            }
            .font(.callout)
            .padding(.horizontal, 6)
            .padding(.vertical, rowPadding)
            .background(isHovered && check.url != nil ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(check.summary ?? check.name)
    }

    private var rowPadding: CGFloat {
        #if os(macOS)
            3
        #else
            7
        #endif
    }

    private var duration: String? {
        guard let start = check.startedAt, let end = check.completedAt else { return nil }
        let seconds = Int(end.timeIntervalSince(start))
        return seconds >= 3600 ? "\(seconds / 3600)h \(seconds % 3600 / 60)m" : "\(seconds / 60)m \(seconds % 60)s"
    }
}

/// The CI rollup in a detail header, e.g. "CI 3 failed"; clicking it shows the checks.
struct CISummary: View {
    let ci: Item.CIStatus

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).foregroundStyle(ci.failed > 0 ? AnyShapeStyle(.red) : .secondaryText)
        }
    }

    // As the list's CI column: a failed rollup with no failed checks means they were cancelled.
    private var color: Color {
        if ci.failed > 0 { return .red }
        if ci.pending > 0 || ci.state == "PENDING" || ci.state == "EXPECTED" { return .yellow }
        return ci.state == "SUCCESS" ? .green : .gray
    }

    private var text: String {
        if ci.failed > 0 { return "CI \(ci.failed) failed" }
        if ci.pending > 0 { return "CI \(ci.pending) pending" }
        switch ci.state {
        case "SUCCESS": return "CI passed"
        case "FAILURE", "ERROR": return "CI cancelled"
        default: return "CI \(ci.state.lowercased())"
        }
    }
}

private extension Check.State {
    var title: String {
        switch self {
        case .failed: "Failed"
        case .pending: "Pending"
        case .passed: "Passed"
        case .skipped: "Skipped / cancelled"
        }
    }

    var symbol: String {
        switch self {
        case .failed: "xmark.circle.fill"
        case .pending: "clock.fill"
        case .passed: "checkmark.circle.fill"
        case .skipped: "minus.circle"
        }
    }

    var color: Color {
        switch self {
        case .failed: .red
        case .pending: .yellow
        case .passed: .green
        case .skipped: .secondaryText
        }
    }
}
