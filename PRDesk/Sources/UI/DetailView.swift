import SwiftUI

/// Placeholder detail pane; the full timeline arrives in milestone 4.
struct DetailView: View {
    let item: Item?

    var body: some View {
        if let item {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("#\(String(item.number))").foregroundStyle(.secondary).monospacedDigit()
                        Text(item.title).textSelection(.enabled)
                    }
                    .font(.headline)

                    HStack(spacing: 6) {
                        Image(systemName: item.kindSymbol).foregroundStyle(Color(nsColor: item.stateColor))
                        Text(stateText(item))
                        Text("by \(item.author ?? "ghost")")
                        Text("opened \(item.createdAt.compactAge()) ago · updated \(item.updatedAt.compactAge()) ago")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)

                    if !item.labels.isEmpty {
                        Text(item.labels.map(\.name).joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let url = URL(string: item.url) {
                        Link("Open on GitHub", destination: url)
                            .font(.callout)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        } else {
            ContentUnavailableView("No Selection", systemImage: "sidebar.right")
        }
    }

    private func stateText(_ item: Item) -> String {
        switch item.state {
        case .open: item.isDraft ? "Draft" : "Open"
        case .closed: "Closed"
        case .merged: "Merged"
        }
    }
}
