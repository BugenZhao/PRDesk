import SwiftUI

/// What can be done with an item, as a menu: held on a row, and behind the detail's ••• button.
/// The same actions as the Mac's keys and row menu, through `AppModel.perform`.
///
/// In this order: where else the item is (a row of buttons at the menu's head: GitHub, its agent
/// session, its link to copy), what I make of it (read, and the board's Status, Priority and
/// pin), the item itself (its linked PR, its author, draft or ready, its title), then the bots.
struct ItemMenu: View {
    let item: Item
    let model: AppModel
    /// Asks for a new title, where the menu can (the detail's).
    var rename: (() -> Void)?

    /// Whether the board's fields (Status, Priority, the pin) are the app's to set: not for the
    /// parity fork's staging PRs, nor for another tracker's items on the board.
    static func isOnBoard(_ item: Item, model: AppModel) -> Bool {
        !item.isParityStaging && item.isUpstream && model.board(for: item)?.isForeign != true
    }

    var body: some View {
        let board = model.board(for: item)
        let isUnread = model.isUnread(item)

        ControlGroup {
            Button("GitHub", systemImage: "arrow.up.right") { model.perform(.openInBrowser, on: item.id) }
            if board?.sessionLinks.isEmpty == false {
                Button("Session", systemImage: "terminal") { model.perform(.openSession, on: item.id) }
            }
            Button("Copy Link", systemImage: "link") { model.perform(.copyLink, on: item.id) }
        }

        Section {
            Button(isUnread ? "Mark as Read" : "Mark as Unread", systemImage: isUnread ? "envelope.open" : "envelope.badge") {
                model.perform(.toggleRead, on: item.id)
            }
            if Self.isOnBoard(item, model: model) {
                let triage = model.triage(for: item)
                Menu("Status", systemImage: "square.stack") {
                    Toggle("Triage", isOn: Binding(
                        get: { model.listedTriage(for: item) == nil },
                        set: { _ in if let triage { model.perform(.triage(triage), on: item.id) } }
                    ))
                    ForEach(TriageStatus.settable, id: \.self) { status in
                        Toggle(isOn: Binding(
                            get: { model.listedTriage(for: item) == status },
                            set: { _ in if status != triage { model.perform(.triage(status), on: item.id) } }
                        )) {
                            Label(status.rawValue, systemImage: status.symbol)
                        }
                    }
                }
                Menu("Priority", systemImage: "exclamationmark") {
                    ForEach(Priority.allCases, id: \.self) { priority in
                        Toggle(isOn: Binding(
                            get: { board?.priorityValue == priority },
                            set: { _ in if board?.priorityValue != priority { model.perform(.priority(priority), on: item.id) } }
                        )) {
                            Label(priority.optionName, systemImage: priority.symbol)
                        }
                    }
                    Toggle("No Priority", isOn: Binding(
                        get: { board?.priorityValue == nil },
                        set: { _ in if board?.priorityValue != nil { model.perform(.priority(nil), on: item.id) } }
                    ))
                }
                let isPinned = board?.isPinned == true
                Button(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin") {
                    model.perform(.togglePin, on: item.id)
                }
                if model.canAddToDesk(item) {
                    Button("Add to Desk", systemImage: "plus") { model.perform(.addToDesk, on: item.id) }
                }
            }
        }

        Section {
            if model.linkedPR(of: item) != nil {
                Button("Go to Linked PR", systemImage: "arrow.left.arrow.right") { model.perform(.openLinked, on: item.id) }
            }
            if item.author != nil {
                Button("Author's Profile", systemImage: "person.crop.circle") { model.perform(.openAuthorProfile, on: item.id) }
            }
            if let toggle = item.draftToggle {
                Button {
                    Task { await model.toggleDraft(item) }
                } label: {
                    Label { Text(toggle.title) } icon: { toggle.icon.image }
                }
            }
            if let rename {
                Button("Rename…", systemImage: "pencil", action: rename)
            }
        }

        Section("Grok Bot") {
            ForEach(BotRequest.allCases, id: \.self) { request in
                Button("\(request.emoji) \(request.title)…") {
                    model.perform(.sendToBot(request, withNote: true), on: item.id)
                }
                .disabled(!request.applies(to: item))
            }
        }
    }
}
