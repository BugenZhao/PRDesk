import SwiftUI

/// Checks of the head commit, grouped by state with failures first.
struct ChecksView: View {
    let checks: [Check]
    @State private var expanded: Set<Check.State> = [.failed, .pending]

    var body: some View {
        if checks.isEmpty {
            ContentUnavailableView("No Checks", systemImage: "checkmark.seal")
        } else {
            List {
                ForEach(Check.State.allCases, id: \.self) { state in
                    let group = checks.filter { $0.state == state }.sorted { $0.name < $1.name }
                    if !group.isEmpty {
                        Section(isExpanded: Binding(
                            get: { expanded.contains(state) },
                            set: { if $0 { expanded.insert(state) } else { expanded.remove(state) } }
                        )) {
                            ForEach(group) { CheckRow(check: $0) }
                        } header: {
                            HStack {
                                Text(state.title)
                                Text(String(group.count)).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }
}

private struct CheckRow: View {
    let check: Check

    var body: some View {
        Button {
            if let url = check.url.flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: check.state.symbol)
                    .foregroundStyle(check.state.color)
                Text(check.name).lineLimit(1).truncationMode(.middle)
                if let app = check.app {
                    Text(app).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer()
                if let duration {
                    Text(duration).foregroundStyle(.secondary).monospacedDigit()
                }
                if check.url != nil {
                    Image(systemName: "arrow.up.right").foregroundStyle(.tertiary)
                }
            }
            .font(.callout)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(check.summary ?? check.name)
    }

    private var duration: String? {
        guard let start = check.startedAt, let end = check.completedAt else { return nil }
        let seconds = Int(end.timeIntervalSince(start))
        return seconds >= 3600 ? "\(seconds / 3600)h \(seconds % 3600 / 60)m" : "\(seconds / 60)m \(seconds % 60)s"
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
        case .skipped: .secondary
        }
    }
}
