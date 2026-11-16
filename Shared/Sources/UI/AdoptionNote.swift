import SwiftUI

/// In the detail header, the other end of a parity adoption (SPEC §3.2): on the staging PR, the
/// upstream PR it adopts and whose it is; on that PR, its staging PR. Clicking opens it in the app.
struct AdoptionNote: View {
    @Environment(AppModel.self) private var model
    let item: Item

    var body: some View {
        if let adoption = model.adoption(of: item) {
            if adoption.staging.id == item.id {
                if let number = Parity.adoptedNumber(item.headRef) {
                    let upstream = adoption.upstream
                    note(
                        target: upstream,
                        text: "Adopts #\(number)" + (upstream?.author.map { " by @\($0)" } ?? ""),
                        help: upstream.map { "\($0.repo)#\($0.number) \($0.title)" } ?? "\(SyncEngine.repo)#\(number)"
                    ) {
                        model.openItem(repo: SyncEngine.repo, number: number)
                    }
                }
            } else {
                let staging = adoption.staging
                note(
                    target: staging,
                    text: "Adopted by the parity agent in #\(staging.number)",
                    help: "\(staging.repo)#\(staging.number) \(staging.title)"
                ) {
                    model.openItem(repo: staging.repo, number: staging.number)
                }
            }
        }
    }

    private func note(target: Item?, text: String, help: String, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack(spacing: 4) {
                if let target {
                    StateIconView(item: target, size: 12)
                }
                Text(text)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(help)
    }
}
