import SwiftUI

/// A menu a detail page asks for (`WebDocument.MenuRequest`): on a reaction's button, on holding
/// a person or a file's header. Shown as a popover at the point the page gave.
struct PageMenu: Identifiable {
    let id = UUID()
    let request: WebDocument.MenuRequest
    /// In the window.
    let point: CGPoint
    let page: WebDocument

    var anchor: CGRect { CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2) }

    /// The reactions hang under their button, a row as wide as a phone: left to the system
    /// they went beside it, where the row had no room and lost its ends. The others are left
    /// to the system (they are asked for anywhere on the page).
    var arrowEdge: Edge? {
        if case .reaction = request { .top } else { nil }
    }
}

struct PageMenuView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let menu: PageMenu

    var body: some View {
        Group {
            switch menu.request {
            case let .reaction(subject): reactions(subject)
            case let .login(login): PersonMenuView(login: login)
            case let .file(path, url, viewed): file(path: path, url: url, viewed: viewed)
            }
        }
        // A popover on a phone too: these are a few buttons, not a sheet's worth.
        .presentationCompactAdaptation(.popover)
    }

    // MARK: Reactions

    /// The reactions to add on a comment, review or description, the viewer's own marked (picking
    /// one of those takes it back).
    private func reactions(_ subject: String) -> some View {
        let mine = Set((model.detail?.reactions(on: subject) ?? []).filter(\.viewerHasReacted).map(\.content))
        return HStack(spacing: 2) {
            ForEach(Reaction.Content.allCases, id: \.self) { content in
                Button {
                    model.toggleReaction(content, on: subject)
                    dismiss()
                } label: {
                    Text(content.emoji)
                        .font(.title2)
                        .frame(width: 42, height: 42)
                        .background(mine.contains(content) ? Color.accentColor.opacity(0.22) : .clear, in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(content.name)
            }
        }
        .padding(8)
    }

    // MARK: A file

    private func file(path: String, url: String, viewed: Bool?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondaryText)
                .lineLimit(2)
                .truncationMode(.middle)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            if let viewed, let literal = WebDocument.jsonLiteral(path) {
                MenuRow("Viewed", isOn: viewed) {
                    menu.page.run("PRDesk.toggleViewed(\(literal))")
                    dismiss()
                }
            }
            MenuRow("Copy Path", systemImage: "doc.on.doc") {
                Platform.copy(path)
                dismiss()
            }
            if let link = URL(string: url), !url.isEmpty {
                MenuRow("Open on GitHub", systemImage: "arrow.up.right") {
                    Platform.open(link)
                    dismiss()
                }
            }
        }
        .frame(width: 290)
    }
}

/// A person's menu, on holding their name in a page or above it: what hovering it says on the Mac
/// (`personFacts`), their profile, their name to copy, and the orgs to tie them to by hand
/// (SPEC §5), each checked when they have its badge, picking one toggles it.
struct PersonMenuView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let login: String

    var body: some View {
        let affiliations = model.affiliations
        let facts = personFacts(contribution: model.contribution(for: login), badges: affiliations.badges(for: login))
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    AvatarView(login: login, size: 26)
                    Text(login).font(.headline).lineLimit(1)
                    BadgeIcons(login: login)
                    Spacer(minLength: 0)
                }
                if !facts.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(facts, id: \.self) { fact in
                            Text(fact).lineLimit(3)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    // Under the name, past the avatar.
                    .padding(.leading, 34)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            MenuRow("Open Profile on GitHub", systemImage: "person.crop.circle") {
                AppModel.openProfile(login)
                dismiss()
            }
            MenuRow("Copy Username", systemImage: "doc.on.doc") {
                Platform.copy(login)
                dismiss()
            }
            // Read from the Mac, badges aren't set here: its next file would undo it.
            if model.canEditAffiliations {
                Divider()
                Text("Affiliation")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondaryText)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Org.allCases) { org in
                            MenuRow(org.displayName, isOn: affiliations.hasFullBadge(org: org, for: login)) {
                                model.toggleAffiliation(org, for: [login])
                            }
                        }
                        if affiliations.overrides.contains(where: { $0.login == login.lowercased() }) {
                            Divider()
                            MenuRow("Clear Manual Affiliations", systemImage: "arrow.uturn.backward") {
                                model.clearManualAffiliations(for: [login])
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .frame(width: 290)
    }
}

/// A line of such a menu: an action with its symbol, or an option with its checkmark.
private struct MenuRow: View {
    let title: String
    var systemImage: String?
    var isOn: Bool?
    let action: () -> Void

    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    init(_ title: String, isOn: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isOn = isOn
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isOn == nil ? (systemImage ?? "circle") : "checkmark")
                    .font(.body.weight(isOn == nil ? .regular : .semibold))
                    .foregroundStyle(isOn == nil ? .secondaryText : AnyShapeStyle(.tint))
                    .opacity(isOn == false ? 0 : 1)
                    .frame(width: 22)
                Text(title).foregroundStyle(Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowStyle())
    }
}

private struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(Color.primary.opacity(configuration.isPressed ? 0.1 : 0))
    }
}
