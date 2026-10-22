import Foundation

/// What the timeline shows about people beside their logins.
@MainActor
protocol TimelinePeople {
    var viewer: String? { get }
    func vote(for login: String?) -> Vote?
    func badges(for login: String) -> [Badge]
    func contribution(for login: String?) -> Contribution?
}

/// The conversation as the timeline page shows it: the description, comment and review cards,
/// and one-line events, as HTML blocks keyed by id (see `detail.js`).
@MainActor
struct TimelineDocument {
    /// JSON for `PRDesk.renderTimeline`.
    let payload: String
    let cardCount: Int

    /// The newest this many cards start expanded; older ones show a one-line preview.
    private static let expandedTail = 5
    private static let descriptionID = "description"

    init(item: Item, detail: ItemDetail, previousSeenAt: Date?, showAutomated: Bool, people: some TimelinePeople) {
        let builder = Builder(people: people, previousSeenAt: previousSeenAt)
        let groups = Self.group(detail.entries.filter { showAutomated || !$0.isAutomated })
        let cardIDs = groups.compactMap { if case let .card(entry) = $0 { entry.id } else { nil } }
        let expandedIDs = Set(cardIDs.suffix(Self.expandedTail))

        var blocks: [Block] = []
        if !detail.bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || item.author != nil {
            blocks.append(builder.card(
                id: Self.descriptionID, login: item.author, verb: "opened", verbClass: "c-secondary",
                at: item.createdAt, url: item.url,
                bodyHTML: detail.bodyHTML.isEmpty ? "<p><em>No description.</em></p>" : detail.bodyHTML,
                bodyText: detail.bodyText, reviewComments: [], isNew: false, expanded: true
            ))
        }
        var firstNew: String?
        for group in groups {
            let isNew = group.entries.contains(where: builder.isNew)
            if isNew, firstNew == nil { firstNew = group.id }
            switch group {
            case let .card(entry):
                blocks.append(builder.card(
                    id: entry.id, login: entry.actor, verb: entry.verb, verbClass: entry.verbClass,
                    at: entry.at, url: entry.url, bodyHTML: entry.bodyHTML ?? "", bodyText: entry.bodyText ?? "",
                    reviewComments: entry.reviewComments, isNew: isNew,
                    expanded: isNew || expandedIDs.contains(entry.id)
                ))
            case let .event(entry):
                blocks.append(builder.event(entry, isNew: isNew))
            case let .commits(entries):
                blocks.append(builder.commits(entries, id: group.id, isNew: isNew))
            case let .reviewRequests(entries):
                blocks.append(builder.reviewRequests(entries, id: group.id, isNew: isNew))
            }
        }

        cardCount = cardIDs.count
        let document = Document(key: String(item.number), blocks: blocks, firstNew: firstNew)
        payload = (try? String(decoding: JSONEncoder().encode(document), as: UTF8.self)) ?? "{}"
    }

    private struct Document: Encodable {
        var key: String
        var blocks: [Block]
        var firstNew: String?
    }

    /// A card (`head`, `preview`, lazily built `body`) or a one-line row (`html`).
    struct Block: Encodable {
        var id: String
        var type: String
        var cls: String
        var head: String?
        var preview: String?
        var body: String?
        var expanded: Bool?
        var html: String?

        func with(id: String) -> Block {
            var block = self
            block.id = id
            return block
        }
    }

    // MARK: Grouping

    private enum Group {
        case card(TimelineEntry)
        case event(TimelineEntry)
        case commits([TimelineEntry])
        case reviewRequests([TimelineEntry])

        var id: String {
            switch self {
            case let .card(entry), let .event(entry): entry.id
            case let .commits(entries): "commits-\(entries[0].id)"
            case let .reviewRequests(entries): "requests-\(entries[0].id)"
            }
        }

        var entries: [TimelineEntry] {
            switch self {
            case let .card(entry), let .event(entry): [entry]
            case let .commits(entries), let .reviewRequests(entries): entries
            }
        }
    }

    /// Groups consecutive commits, and consecutive review requests, by the same person.
    private static func group(_ entries: [TimelineEntry]) -> [Group] {
        var groups: [Group] = []
        for entry in entries {
            if entry.kind == .commit {
                if case var .commits(group) = groups.last, sameLogin(group[0].actor, entry.actor) {
                    group.append(entry)
                    groups[groups.count - 1] = .commits(group)
                } else {
                    groups.append(.commits([entry]))
                }
            } else if entry.kind == .reviewRequested {
                if case var .reviewRequests(group) = groups.last, sameLogin(group[0].actor, entry.actor) {
                    group.append(entry)
                    groups[groups.count - 1] = .reviewRequests(group)
                } else {
                    groups.append(.reviewRequests([entry]))
                }
            } else if entry.isCard {
                groups.append(.card(entry))
            } else {
                groups.append(.event(entry))
            }
        }
        return groups
    }

    // MARK: HTML

    @MainActor
    private struct Builder<People: TimelinePeople> {
        let people: People
        let previousSeenAt: Date?

        func isNew(_ entry: TimelineEntry) -> Bool {
            guard let previousSeenAt else { return false }
            return entry.at > previousSeenAt && !sameLogin(entry.actor, people.viewer)
        }

        func card(
            id: String, login: String?, verb: String, verbClass: String, at: Date, url: String?,
            bodyHTML: String, bodyText: String, reviewComments: [ReviewComment], isNew: Bool, expanded: Bool
        ) -> Block {
            var head = avatar(login) + person(login)
            head += #"<span class="verb \#(verbClass)">\#(verb.htmlEscaped)</span>"#
            head += age(at, cls: "c-secondary")
            if isNew { head += #"<span class="chip accent">New</span>"# }
            head += #"<span class="spacer"></span>"#
            if let url {
                head += #"<a class="icon-link" href="\#(url.htmlEscaped)" title="Open on GitHub">\#(symbol("arrow.up.right"))</a>"#
            }
            head += symbol("chevron.right", cls: "chev")

            var body = ""
            if !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || reviewComments.isEmpty {
                body += #"<div class="md">\#(bodyHTML)</div>"#
            }
            for comment in reviewComments {
                body += reviewComment(comment)
            }

            let preview = bodyText.split(whereSeparator: \.isNewline).first.map(String.init)
                ?? reviewComments.first.map { "\($0.path): …" }
            return Block(
                id: id, type: "card", cls: isNew ? "new" : "", head: head, preview: preview ?? "",
                body: body, expanded: expanded
            )
        }

        private func reviewComment(_ comment: ReviewComment) -> String {
            let location = comment.line.map { "\(comment.path):\($0)" } ?? comment.path
            var html = #"<div class="rc"><div class="rc-head">\#(symbol("doc.text"))"#
            html += #"<span class="rc-path" title="\#(location.htmlEscaped)"><bdi>\#(location.htmlEscaped)</bdi></span>"#
            if comment.outdated { html += #"<span class="chip">Outdated</span>"# }
            html += #"<span class="spacer"></span>"#
            html += #"<a class="icon-link" href="\#(comment.url.htmlEscaped)" title="Open on GitHub">\#(symbol("arrow.up.right"))</a></div>"#
            // The last few lines of the hunk, for where the comment sits.
            html += #"<div class="rc-hunk">"#
            for line in comment.diffHunk.split(separator: "\n", omittingEmptySubsequences: false).suffix(4) {
                let cls = line.hasPrefix("+") ? "a" : line.hasPrefix("-") ? "d" : ""
                html += #"<div class="\#(cls)">\#(String(line).htmlEscaped)</div>"#
            }
            html += #"</div><div class="md">\#(comment.bodyHTML)</div></div>"#
            return html
        }

        func event(_ entry: TimelineEntry, isNew: Bool) -> Block {
            var html = symbol(entry.symbol, cls: entry.verbClass) + avatar(entry.actor, small: true) + person(entry.actor)
            switch entry.kind {
            case .labeled, .unlabeled:
                html += #"<span class="text">\#(entry.kind == .labeled ? "added" : "removed")</span>"#
                html += labelChip(name: entry.detail ?? "", hex: entry.color ?? "")
            case .crossReferenced:
                let title = (entry.detail ?? "").htmlEscaped
                let link = entry.url.map { #"<a href="\#($0.htmlEscaped)">\#(title)</a>"# } ?? title
                html += #"<span class="text">mentioned this in \#(link)</span>"#
            default:
                html += #"<span class="text">\#(entry.eventText.htmlEscaped)</span>"#
            }
            html += age(entry.at, cls: "age")
            return Block(id: entry.id, type: "row", cls: isNew ? "row new-bar" : "row", html: html)
        }

        func commits(_ entries: [TimelineEntry], id: String, isNew: Bool) -> Block {
            let count = entries.count
            var html = #"<div class="row">\#(symbol("arrow.up.circle", cls: "c-secondary"))"#
            html += avatar(entries[0].actor, small: true) + person(entries[0].actor)
            html += #"<span class="text">pushed \#(count) commit\#(count == 1 ? "" : "s")</span>"#
            html += age(entries[count - 1].at, cls: "age") + "</div>"
            for entry in entries.suffix(6) {
                let headline = (entry.detail ?? "").htmlEscaped
                html += #"<div class="commit" title="\#(headline)">\#(headline)</div>"#
            }
            if count > 6 {
                html += #"<div class="more">and \#(count - 6) earlier</div>"#
            }
            return Block(id: id, type: "row", cls: isNew ? "commits new-bar" : "commits", html: html)
        }

        /// "requested review from a, b and 5 others", every name in the tooltip.
        func reviewRequests(_ entries: [TimelineEntry], id: String, isNew: Bool) -> Block {
            guard entries.count > 1 else { return event(entries[0], isNew: isNew).with(id: id) }
            let names = entries.map { $0.detail ?? "someone" }
            let shown = names.prefix(3).joined(separator: ", ")
            let text = names.count > 3 ? "\(shown) and \(names.count - 3) others" : "\(names.dropLast().joined(separator: ", ")) and \(names[names.count - 1])"
            var html = symbol("person.badge.plus", cls: "c-secondary") + avatar(entries[0].actor, small: true) + person(entries[0].actor)
            html += #"<span class="text" title="\#(names.joined(separator: ", ").htmlEscaped)">requested review from \#(text.htmlEscaped)</span>"#
            html += age(entries[entries.count - 1].at, cls: "age")
            return Block(id: id, type: "row", cls: isNew ? "row new-bar" : "row", html: html)
        }

        // MARK: Parts

        private func avatar(_ login: String?, small: Bool = false) -> String {
            let cls = small ? "avatar small" : "avatar"
            guard let login else { return #"<span class="\#(cls)"></span>"# }
            return #"<img class="\#(cls)" src="\#(AvatarSchemeHandler.url(for: login).htmlEscaped)" alt="">"#
        }

        /// The login with the viewer's vote and affiliation badges, as `LoginText` and `BadgeIcons`.
        private func person(_ login: String?) -> String {
            guard let login else { return #"<span class="person"><span class="login">ghost</span></span>"# }
            let escaped = login.htmlEscaped
            var html = #"<span class="person"><span class="login" data-login="\#(escaped)">\#(escaped)</span>"#
            if let vote = people.vote(for: login) {
                let title = vote == .up ? "Upvoted" : "Downvoted: sinks to the bottom of Triage"
                html += symbol(vote.symbol, cls: vote == .up ? "vote c-green" : "vote c-red", title: title)
            }
            let badges = people.badges(for: login)
            if let contribution = people.contribution(for: login) {
                // An org badge already says the author is established.
                if contribution.isRegular, badges.isEmpty {
                    html += symbol("checkmark.seal", cls: "c-green", title: contribution.summary)
                } else if contribution.isFirstTime {
                    html += #"<span class="tile first" title="\#(contribution.summary.htmlEscaped)">1st</span>"#
                }
            }
            for badge in badges {
                let title = "\(badge.name) — \(badge.source)".htmlEscaped
                html += #"<img class="badge" src="\#(AvatarSchemeHandler.url(for: badge).htmlEscaped)" title="\#(title)" alt="\#(badge.org.shortLabel.htmlEscaped)">"#
            }
            return html + "</span>"
        }

        private func age(_ date: Date, cls: String) -> String {
            let full = date.formatted(date: .abbreviated, time: .shortened)
            let milliseconds = Int64(date.timeIntervalSince1970 * 1000)
            return #"<span class="\#(cls)" data-at="\#(milliseconds)" title="\#(full.htmlEscaped)">\#(date.compactAge()) ago</span>"#
        }

        private func labelChip(name: String, hex: String) -> String {
            let valid = hex.count == 6 && hex.allSatisfy(\.isHexDigit)
            let style = valid ? #" style="background: #\#(hex)38; border-color: #\#(hex)99""# : ""
            return #"<span class="label-chip"\#(style)>\#(name.htmlEscaped)</span>"#
        }

        private func symbol(_ name: String, cls: String = "", title: String? = nil) -> String {
            let classes = ["sym", WebSymbols.className(name), cls].filter { !$0.isEmpty }.joined(separator: " ")
            let title = title.map { #" title="\#($0.htmlEscaped)""# } ?? ""
            return #"<i class="\#(classes)"\#(title)></i>"#
        }
    }
}

private extension TimelineEntry {
    var verb: String {
        switch kind {
        case .comment: "commented"
        case .approved: "approved"
        case .changesRequested: "requested changes"
        default: "reviewed"
        }
    }

    var verbClass: String {
        switch kind {
        case .approved, .reopened: "c-green"
        case .changesRequested, .closed: "c-red"
        case .merged: "c-purple"
        default: "c-secondary"
        }
    }

    var symbol: String {
        switch kind {
        case .forcePush: "arrow.triangle.2.circlepath"
        case .merged: "arrow.triangle.merge"
        case .closed: "xmark.circle"
        case .reopened: "arrow.uturn.left.circle"
        case .readyForReview: "eye"
        case .convertToDraft: "pencil.circle"
        case .reviewRequested: "person.badge.plus"
        case .reviewDismissed: "xmark.seal"
        case .labeled, .unlabeled: "tag"
        case .crossReferenced: "link"
        case .assigned: "person.crop.circle.badge.checkmark"
        case .renamed: "pencil"
        case .reviewed, .approved, .changesRequested: "eye.circle"
        case .comment, .commit: "circle"
        }
    }

    var eventText: String {
        switch kind {
        case .forcePush: "force-pushed\(detail.map { " to \($0)" } ?? "")"
        case .merged: "merged this"
        case .closed: "closed this"
        case .reopened: "reopened this"
        case .readyForReview: "marked this ready for review"
        case .convertToDraft: "converted this to draft"
        case .reviewRequested: "requested review from \(detail ?? "someone")"
        case .reviewDismissed: "dismissed a review"
        case .assigned: "assigned \(detail ?? "someone")"
        case .renamed: "changed the title to “\(detail ?? "")”"
        case .reviewed: "reviewed"
        default: ""
        }
    }
}
