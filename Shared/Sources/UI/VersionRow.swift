import SwiftUI

/// In Settings: the commit this copy was built from and, for what it is worth, how far the
/// repository's `main` has moved on since. A note, not a warning: a copy a few commits behind
/// is as good as it was.
struct VersionRow: View {
    @Environment(AppModel.self) private var model
    @State private var behind: Int?

    var body: some View {
        LabeledContent("Version") {
            Text(text)
                .foregroundStyle(.secondaryText)
                .textSelection(.enabled)
        }
        .task { behind = await model.commitsBehindMain() }
    }

    private var text: String {
        guard let commit = AppVersion.commit else { return "Not an install" }
        let lag = switch behind {
        case nil: ""
        case 0?: " · up to date"
        case 1?: " · 1 commit behind main"
        case let count?: " · \(count) commits behind main"
        }
        return commit + lag
    }
}
