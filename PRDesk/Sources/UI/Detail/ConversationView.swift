import AppKit
import SwiftUI

/// The timeline: comment and review cards plus compact event lines, in one web page
/// (`TimelineDocument`) under a native bar of options.
struct ConversationView: View {
    @Environment(AppModel.self) private var model
    let item: Item
    let detail: ItemDetail
    /// Entries by others after this are highlighted as new.
    let previousSeenAt: Date?
    let page: WebDocument

    @AppStorage("showAutomated") private var showAutomated = false

    var body: some View {
        let document = TimelineDocument(
            item: item, detail: detail, previousSeenAt: previousSeenAt, showAutomated: showAutomated, people: model
        )
        VStack(spacing: 0) {
            toolbar(cardCount: document.cardCount)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            Divider()
            WebDocumentView(document: page, key: item.id, payload: document.payload)
        }
        .onAppear {
            page.loginMenu = { [model] login in Self.loginMenu(login, model: model) }
            page.reactionMenu = { [model] subject in Self.reactionMenu(subject, model: model) }
            page.toggleReaction = { [model] content, subject in model.toggleReaction(content, on: subject) }
        }
        // A link that pointed to a comment of this item (e.g. Yab's tab in front) scrolls to it.
        .onChange(of: model.linkedComment, initial: true) { _, link in
            if let link, let fragment = link.anchor, link.key == item.repoNumber {
                page.reveal(fragment: fragment, key: item.id)
            }
        }
    }

    private func toolbar(cardCount: Int) -> some View {
        HStack(spacing: 10) {
            Toggle("Show automated", isOn: $showAutomated)
                .toggleStyle(.checkbox)
                .help("Bots and agent accounts (such as vllm-agent), and comments that only run commands, like @codex review or /ci")
            Text("\(cardCount) comment\(cardCount == 1 ? "" : "s")")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Expand all") { page.run("PRDesk.setAllCards(true)") }
            Button("Collapse all") { page.run("PRDesk.setAllCards(false)") }
        }
        .font(.caption)
        .controlSize(.small)
        .buttonStyle(.link)
    }

    /// The reactions to add on a comment, review or description, the viewer's own checked (picking
    /// one of those takes it back).
    private static func reactionMenu(_ subjectID: String, model: AppModel) -> NSMenu? {
        guard let reactions = model.detail?.reactions(on: subjectID) else { return nil }
        let menu = NSMenu()
        for content in Reaction.Content.allCases {
            let reacted = reactions.contains { $0.content == content && $0.viewerHasReacted }
            menu.addItem(ClosureMenuItem("\(content.emoji)  \(content.name)", state: reacted ? .on : .off) {
                model.toggleReaction(content, on: subjectID)
            })
        }
        return menu
    }

    /// Right-clicking a person: vote on them (as `VoteMenu`), set their affiliation, or open or copy
    /// their profile.
    private static func loginMenu(_ login: String, model: AppModel) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if !sameLogin(login, model.viewer) {
            let current = model.vote(for: login)
            menu.addItem(ClosureMenuItem("Upvote \(login)", systemImage: "hand.thumbsup", isEnabled: current != .up) {
                model.setVote(.up, for: login)
            })
            menu.addItem(ClosureMenuItem("Downvote \(login)", systemImage: "hand.thumbsdown", isEnabled: current != .down) {
                model.setVote(.down, for: login)
            })
            menu.addItem(ClosureMenuItem("Clear Vote", systemImage: "hand.raised.slash", isEnabled: current != nil) {
                model.setVote(nil, for: login)
            })
            menu.addItem(.separator())
        }
        menu.addItem(AffiliationMenu.item("Affiliation", for: [login], model: model))
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Open Profile on GitHub") { AppModel.openProfile(login) })
        menu.addItem(ClosureMenuItem("Copy Username") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(login, forType: .string)
        })
        return menu
    }
}

extension AppModel: TimelinePeople {
    func badges(for login: String) -> [Badge] {
        affiliations.badges(for: login)
    }
}
