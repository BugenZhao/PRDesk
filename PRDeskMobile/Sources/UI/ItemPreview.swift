import SwiftUI

/// What holding a row shows above its menu: what the row has no room for, read without opening
/// the item. The whole title; the author as a name's menu tells of them in a page (PRs merged,
/// each affiliation and why, the profile's company and bio), with their profile a button in the
/// menu under it; then where the item stands: the board's Status, Priority and Comment, reviews,
/// CI and size, the latest event and whose turn it is, the labels, and when it was opened and
/// last updated. Only what the list already has: holding a row costs no request.
struct ItemPreview: View {
    let row: ItemRow
    let model: AppModel
    let width: CGFloat

    private var item: Item { row.item }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                stateLine
                title
            }
            author
            facts
            if !item.labels.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(item.labels, id: \.name) { LabelChip(name: $0.name, hex: $0.color) }
                }
            }
        }
        .padding(16)
        .frame(width: width, alignment: .leading)
        .environment(model)
    }

    /// The state, the number (and the repository when it isn't vLLM's), the pin, the dates.
    private var stateLine: some View {
        HStack(spacing: 6) {
            StateIconView(item: item, size: 15, isMerging: row.isMerging)
            ItemStateChip(item: item)
            Text(item.isUpstream ? "#\(String(item.number))" : "\(item.repo)#\(String(item.number))")
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.head)
            if row.isPinned {
                Image(systemName: "pin.fill").font(.caption2)
            }
            Spacer(minLength: 8)
            Text("opened \(item.createdAt.compactAge()) · updated \(item.updatedAt.compactAge())")
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .font(.caption)
        .foregroundStyle(.secondaryText)
    }

    /// In full, tags too: the row cuts it at its end and shortens its tags.
    private var title: some View {
        Text(itemTitle: item.title, shortenedTags: false, codeFont: .callout.monospaced().weight(.semibold), tagStyle: .secondaryText)
            .font(.headline)
            .lineLimit(8)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Author

    private var author: some View {
        let login = item.author
        let badges = login.map(model.affiliations.badges(for:)) ?? []
        let contribution = model.contribution(for: login)
        let unvouched = contribution?.isUnvouched(badges: badges) ?? false
        let lines = personFacts(contribution: contribution, badges: badges) + profileLines(login, badges: badges)
        return HStack(alignment: .top, spacing: 10) {
            AvatarView(login: login, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(login ?? "ghost")
                        .font(.subheadline.weight(.semibold))
                        .italic(unvouched)
                        .lineLimit(1)
                    BadgeIcons(login: login, size: 14)
                }
                ForEach(lines, id: \.self) { line in
                    Text(line).lineLimit(2)
                }
                .font(.caption)
                .foregroundStyle(.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    /// The profile's company and bio, which the badges are partly worked out from; a company
    /// a badge already names ("@IBM" beside IBM's) is left out.
    private func profileLines(_ login: String?, badges: [Badge]) -> [String] {
        guard let login, let user = model.affiliations.users[login.lowercased()] else { return [] }
        let company = user.company.map { $0.trimmingCharacters(in: .whitespaces.union(["@"])) }
        let named = company.map { company in badges.contains { $0.name.caseInsensitiveCompare(company) == .orderedSame } } ?? false
        return [named ? nil : company, user.bio]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0.replacing(/\s+/, with: " ") }
    }

    // MARK: Facts

    /// One line for each thing known, a symbol before it.
    @ViewBuilder private var facts: some View {
        let lines = factLines
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(lines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: line.symbol)
                            .foregroundStyle(line.tint)
                            .frame(width: 16)
                        line.text
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondaryText)
        }
    }

    private struct FactLine: Identifiable {
        let id: String
        let symbol: String
        var tint: Color = .secondaryText
        let text: Text
    }

    private var factLines: [FactLine] {
        var lines: [FactLine] = []
        if ItemMenu.isOnBoard(item, model: model) {
            let status = row.listedTriage
            var parts = [status?.rawValue ?? "Triage"]
            if let priority = row.priority { parts.append("\(Self.name(priority)) priority") }
            lines.append(FactLine(id: "board", symbol: status?.symbol ?? "tray", text: Text(parts.joined(separator: " · "))))
        }
        if let comment = row.comment, !comment.isEmpty {
            lines.append(FactLine(id: "comment", symbol: "text.bubble", text: Text(comment)))
        }
        if let summary = row.insight.summary {
            let at = row.insight.summaryAt.map { " \($0.compactAge()) ago" } ?? ""
            let turn = row.turnMark.map { $0.isMine ? " · your turn" : " · their turn" } ?? ""
            lines.append(FactLine(
                id: "event", symbol: "clock",
                text: Text("\(summary)\(at)\(Text(turn).fontWeight(row.turnMark?.isMine == true ? .semibold : .regular))")
            ))
        }
        if item.kind == .pullRequest {
            lines += reviewLines
            if let pr = pullRequestLine { lines.append(pr) }
        }
        if !item.assignees.isEmpty {
            lines.append(FactLine(id: "assignees", symbol: "person.2", text: Text("Assigned to \(item.assignees.formatted(.list(type: .and)))")))
        }
        return lines
    }

    /// Who approved, who asked for changes, and of whom a review is asked.
    private var reviewLines: [FactLine] {
        var latest: [String: Item.Review] = [:]
        for review in item.reviews where review.state == "APPROVED" || review.state == "CHANGES_REQUESTED" {
            let key = review.login.lowercased()
            if let seen = latest[key], (seen.submittedAt ?? .distantPast) > (review.submittedAt ?? .distantPast) { continue }
            latest[key] = review
        }
        let reviews = latest.values.sorted { ($0.submittedAt ?? .distantPast) < ($1.submittedAt ?? .distantPast) }
        let approved = reviews.filter { $0.state == "APPROVED" }.map(\.login)
        let changes = reviews.filter { $0.state == "CHANGES_REQUESTED" }.map(\.login)
        var lines: [FactLine] = []
        if !approved.isEmpty {
            lines.append(FactLine(id: "approved", symbol: "checkmark", tint: .green, text: Text("Approved by \(approved.formatted(.list(type: .and)))")))
        }
        if !changes.isEmpty {
            lines.append(FactLine(id: "changes", symbol: "xmark", tint: .red, text: Text("Changes asked by \(changes.formatted(.list(type: .and)))")))
        }
        if item.isOpen, !item.reviewRequests.isEmpty {
            lines.append(FactLine(id: "requested", symbol: "eye", text: Text("Review asked of \(item.reviewRequests.formatted(.list(type: .and)))")))
        }
        return lines
    }

    /// CI, mergeability and size on one line.
    private var pullRequestLine: FactLine? {
        var parts: [Text] = []
        if let ci = item.ci {
            parts.append(Text(ciText(ci)).foregroundStyle(ci.failed > 0 ? AnyShapeStyle(.red) : .secondaryText))
        }
        if item.isOpen, item.mergeable == "CONFLICTING" {
            parts.append(Text("conflicts").foregroundStyle(.orange))
        }
        if let additions = item.additions, let deletions = item.deletions {
            parts.append(Text("\(Text(verbatim: "+\(additions)").foregroundStyle(Color.diffAdded)) \(Text(verbatim: "−\(deletions)").foregroundStyle(Color.diffRemoved))"))
        }
        guard let first = parts.first else { return nil }
        let text = parts.dropFirst().reduce(first) { Text("\($0) · \($1)") }
        let tint: Color = switch item.ciTint {
        case .some(let tint): tint == .gray ? .gray : tint.color
        case nil: .secondaryText
        }
        return FactLine(id: "pr", symbol: item.isMarkedReady ? "circle.fill" : "circle", tint: tint, text: text.monospacedDigit())
    }

    /// As the detail's CI summary (`CISummary`).
    private func ciText(_ ci: Item.CIStatus) -> String {
        if ci.failed > 0 { return "CI \(ci.failed) failed" }
        if ci.pending > 0 { return "CI \(ci.pending) pending" }
        switch ci.state {
        case "SUCCESS": return "CI passed"
        case "FAILURE", "ERROR": return "CI cancelled"
        default: return "CI \(ci.state.lowercased())"
        }
    }

    private static func name(_ priority: Priority) -> String {
        switch priority {
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        }
    }
}
