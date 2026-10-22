import Foundation
import os

/// The triage board: a GitHub Project whose Status, Priority and Comment fields are the source of
/// truth for triage (SPEC §3.1).
enum BoardQuery {
    static let owner = "vllm-project"
    static let number = 56

    static let items = """
    query($owner: String!, $number: Int!, $after: String) {
      organization(login: $owner) {
        projectV2(number: $number) {
          id
          fields(first: 50) {
            nodes {
              ... on ProjectV2FieldCommon { id name }
              ... on ProjectV2SingleSelectField { options { id name } }
            }
          }
          items(first: 100, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes {
              id isArchived
              content {
                __typename
                ... on PullRequest { id number repository { nameWithOwner } }
                ... on Issue { id number repository { nameWithOwner } }
              }
              status: fieldValueByName(name: "Status") {
                ... on ProjectV2ItemFieldSingleSelectValue { name updatedAt }
              }
              priority: fieldValueByName(name: "Priority") {
                ... on ProjectV2ItemFieldSingleSelectValue { name }
              }
              comment: fieldValueByName(name: "Comment") {
                ... on ProjectV2ItemFieldTextValue { text }
              }
            }
          }
        }
      }
    }
    """

    struct Variables: Encodable, Sendable {
        var owner = BoardQuery.owner
        var number = BoardQuery.number
        var after: String?
    }

    struct Response: Decodable, Sendable {
        struct Organization: Decodable, Sendable { let projectV2: Project? }
        let organization: Organization?
    }

    struct Project: Decodable, Sendable {
        struct Field: Decodable, Sendable {
            struct Option: Decodable, Sendable { let id: String; let name: String }
            /// Absent for field types the fragments don't cover.
            let id: String?
            let name: String?
            let options: [Option]?
        }

        struct Items: Decodable, Sendable {
            struct PageInfo: Decodable, Sendable { let hasNextPage: Bool; let endCursor: String? }
            let pageInfo: PageInfo
            let nodes: [Node?]
        }

        struct Node: Decodable, Sendable {
            struct Content: Decodable, Sendable {
                struct Repository: Decodable, Sendable { let nameWithOwner: String }
                let id: String?
                let number: Int?
                let repository: Repository?
            }

            struct SelectValue: Decodable, Sendable { let name: String?; let updatedAt: Date? }
            struct TextValue: Decodable, Sendable { let text: String? }

            let id: String
            let isArchived: Bool
            let content: Content?
            let status: SelectValue?
            let priority: SelectValue?
            let comment: TextValue?

            var entry: BoardEntry? {
                guard let content, let contentID = content.id, let number = content.number,
                      content.repository?.nameWithOwner == SyncEngine.repo
                else { return nil }
                return BoardEntry(
                    number: number, itemID: id, contentID: contentID,
                    status: status?.name, statusAt: status?.updatedAt,
                    priority: priority?.name, comment: comment?.text,
                    isArchived: isArchived
                )
            }
        }

        let id: String
        let fields: Nodes<Field>
        let items: Items
    }

    struct Nodes<T: Decodable & Sendable>: Decodable, Sendable {
        let nodes: [T?]
    }

    /// Ids needed to write to the board.
    struct Schema: Sendable {
        struct SelectField: Sendable {
            var id: String
            /// Option ids by name.
            var options: [String: String]
        }

        var projectID: String
        var status: SelectField?
        var priority: SelectField?

        init(_ project: Project) {
            projectID = project.id
            var fields: [String: Project.Field] = [:]
            for case let field? in project.fields.nodes {
                if let name = field.name { fields[name] = field }
            }
            func select(_ name: String) -> SelectField? {
                guard let field = fields[name], let id = field.id, let options = field.options else { return nil }
                return SelectField(id: id, options: Dictionary(options.map { ($0.name, $0.id) }, uniquingKeysWith: { a, _ in a }))
            }
            status = select("Status")
            priority = select("Priority")
        }
    }
}

enum BoardError: LocalizedError {
    case missingProject
    case missingField(String)
    case missingOption(field: String, option: String)
    /// The Status was written, but the subscription that goes with it was not.
    case subscription(status: String, underlying: String)

    var errorDescription: String? {
        switch self {
        case .missingProject: "Project #\(BoardQuery.number) of \(BoardQuery.owner) was not found."
        case let .missingField(field): "The board has no \(field) field."
        case let .missingOption(field, option): "The board's \(field) field has no \"\(option)\" option."
        case let .subscription(status, underlying):
            "The board now says \(status), but GitHub notifications weren't changed: \(underlying)"
                + (underlying.contains("notifications") ? "\n\nAdd the scope with `gh auth refresh -h github.com -s notifications`, then relaunch." : "")
        }
    }
}

/// Decodes any JSON value and throws it away, for mutation results we don't need.
private struct Ignored: Decodable, Sendable {
    init(from _: any Decoder) throws {}
}

extension SyncEngine {
    /// Fetches the whole board, caches it and returns the content ids of open items on it, so they
    /// can be refreshed even when no tracking search finds them.
    func syncBoard() async throws -> [String] {
        let startedAt = Date()
        var entries: [BoardEntry] = []
        var after: String?
        repeat {
            let response = try await client.query(BoardQuery.items, variables: BoardQuery.Variables(after: after), as: BoardQuery.Response.self)
            guard let project = response.organization?.projectV2 else { throw BoardError.missingProject }
            if after == nil { boardSchema = BoardQuery.Schema(project) }
            entries += project.items.nodes.compactMap { $0?.entry }
            after = project.items.pageInfo.hasNextPage ? project.items.pageInfo.endCursor : nil
        } while after != nil
        // Writes made while the board was being read would be undone by what it read.
        let recent = Set(boardWrites.filter { $0.value > startedAt.addingTimeInterval(-Self.boardWriteGrace) }.keys)
        let previous = try await db.replaceBoard(entries, keeping: recent)
        // The first read has nothing to compare with.
        if !previous.isEmpty {
            await followStatusChanges(entries.filter { !recent.contains($0.number) }, previous: previous)
        }
        return entries.filter { !$0.isForeign && !$0.isArchived }.map(\.contentID)
    }

    private static let boardWriteGrace: TimeInterval = 10

    private func schema() async throws -> BoardQuery.Schema {
        if let boardSchema { return boardSchema }
        _ = try await syncBoard()
        guard let boardSchema else { throw BoardError.missingProject }
        return boardSchema
    }

    /// Applies `change` to the item's board entry locally, then writes the changed field to GitHub,
    /// adding the item to the board first if needed.
    private func writeBoard(
        number: Int, contentID: String,
        change: @Sendable (inout BoardEntry) -> Void,
        field: @Sendable (BoardQuery.Schema, BoardEntry) throws -> (id: String, value: FieldValue?)
    ) async throws {
        let schema = try await schema()
        var entry = try await db.boardEntry(number: number)
            ?? BoardEntry(number: number, itemID: "", contentID: contentID, isArchived: false)
        let wasArchived = entry.isArchived
        entry.isArchived = false
        change(&entry)
        let (fieldID, value) = try field(schema, entry)
        boardWrites[number] = Date()
        try await db.saveBoardEntry(entry)

        if isDryRun("set board field \(fieldID) of #\(number) to \(String(describing: value))") { return }
        if entry.itemID.isEmpty {
            entry.itemID = try await addToBoard(projectID: schema.projectID, contentID: contentID)
            try await db.saveBoardEntry(entry)
        } else if wasArchived {
            try await mutate(
                "mutation($input: UnarchiveProjectV2ItemInput!) { unarchiveProjectV2Item(input: $input) { clientMutationId } }",
                ["projectId": schema.projectID, "itemId": entry.itemID]
            )
        }
        if let value {
            struct Input: Encodable, Sendable { let projectId: String; let itemId: String; let fieldId: String; let value: FieldValue }
            struct Variables: Encodable, Sendable { let input: Input }
            _ = try await client.query(
                "mutation($input: UpdateProjectV2ItemFieldValueInput!) { updateProjectV2ItemFieldValue(input: $input) { clientMutationId } }",
                variables: Variables(input: Input(projectId: schema.projectID, itemId: entry.itemID, fieldId: fieldID, value: value)),
                as: [String: Ignored].self,
                strict: true
            )
        } else {
            try await mutate(
                "mutation($input: ClearProjectV2ItemFieldValueInput!) { clearProjectV2ItemFieldValue(input: $input) { clientMutationId } }",
                ["projectId": schema.projectID, "itemId": entry.itemID, "fieldId": fieldID]
            )
        }
        boardWrites[number] = Date()
    }

    struct FieldValue: Encodable, Sendable {
        var singleSelectOptionId: String?
    }

    private func addToBoard(projectID: String, contentID: String) async throws -> String {
        struct Input: Encodable, Sendable { let projectId: String; let contentId: String }
        struct Variables: Encodable, Sendable { let input: Input }
        struct Response: Decodable, Sendable {
            struct Payload: Decodable, Sendable {
                struct Item: Decodable, Sendable { let id: String }
                let item: Item
            }

            let addProjectV2ItemById: Payload
        }
        return try await client.query(
            "mutation($input: AddProjectV2ItemByIdInput!) { addProjectV2ItemById(input: $input) { item { id } } }",
            variables: Variables(input: Input(projectId: projectID, contentId: contentID)),
            as: Response.self,
            strict: true
        ).addProjectV2ItemById.item.id
    }

    private func mutate(_ mutation: String, _ input: [String: String]) async throws {
        struct Variables: Encodable, Sendable { let input: [String: String] }
        _ = try await client.query(mutation, variables: Variables(input: input), as: [String: Ignored].self, strict: true)
    }

    private static func option(_ field: BoardQuery.Schema.SelectField?, named name: String, in fieldName: String) throws -> (String, String) {
        guard let field else { throw BoardError.missingField(fieldName) }
        guard let option = field.options[name] else { throw BoardError.missingOption(field: fieldName, option: name) }
        return (field.id, option)
    }

    /// Sets (or with nil clears) the item's Status, and moves its subscription along with it:
    /// quiet statuses turn notifications down, leaving them turns them back on.
    func setTriage(_ status: TriageStatus?, number: Int, contentID: String) async throws {
        let previous = try await db.boardEntry(number: number)?.triage
        try await writeBoard(number: number, contentID: contentID) { entry in
            entry.status = status?.rawValue
            entry.statusAt = Date()
        } field: { schema, _ in
            guard let status else {
                guard let field = schema.status else { throw BoardError.missingField("Status") }
                return (field.id, nil)
            }
            let (id, option) = try Self.option(schema.status, named: status.rawValue, in: "Status")
            return (id, FieldValue(singleSelectOptionId: option))
        }
        do {
            try await followSubscription(from: previous, to: status, number: number, contentID: contentID)
        } catch {
            throw BoardError.subscription(status: status?.rawValue ?? "untriaged", underlying: error.localizedDescription)
        }
    }

    /// Moves the subscription along with a Status change: going quiet records the viewer's
    /// subscription and unsubscribes; leaving puts the recorded one back (SUBSCRIBED if none was
    /// recorded), so undoing a skip restores exactly what was there. Setting the same status again
    /// (renewing a woken skip) unsubscribes again, since a mention may have subscribed the viewer.
    private func followSubscription(from previous: TriageStatus?, to status: TriageStatus?, number: Int, contentID: String) async throws {
        let renewing = status != nil && status == previous
        if let quiet = status?.subscription {
            if previous?.isQuiet != true {
                let current = try await viewerSubscription(subjectID: contentID)
                try await db.updateState(number) { $0.subscriptionBeforeQuiet = current }
            }
            if renewing || quiet != previous?.subscription {
                try await setSubscription(quiet, subjectID: contentID)
            }
        } else if previous?.isQuiet == true {
            // GitHub no longer takes IGNORED on an issue or PR; unsubscribing comes closest.
            let recorded = try await db.state(number)?.subscriptionBeforeQuiet
            try await setSubscription(recorded.map { $0 == "IGNORED" ? "UNSUBSCRIBED" : $0 } ?? "SUBSCRIBED", subjectID: contentID)
            try await db.updateState(number) { $0.subscriptionBeforeQuiet = nil }
        }
    }

    /// `SUBSCRIBED`, `UNSUBSCRIBED` or `IGNORED`.
    private func viewerSubscription(subjectID: String) async throws -> String? {
        struct Variables: Encodable, Sendable { let id: String }
        struct Response: Decodable, Sendable {
            struct Node: Decodable, Sendable { let viewerSubscription: String? }
            let node: Node?
        }
        return try await client.query(
            "query($id: ID!) { node(id: $id) { ... on Subscribable { viewerSubscription } } }",
            variables: Variables(id: subjectID),
            as: Response.self
        ).node?.viewerSubscription
    }

    /// Follows Status changes made outside the app (on the web) with the subscription, as
    /// `setTriage` does for the app's own. Only a change counts, so a subscription changed by hand
    /// on GitHub afterwards stands. Done is set by the board's workflow, not a triage decision.
    private func followStatusChanges(_ entries: [BoardEntry], previous: [Int: BoardEntry]) async {
        for entry in entries where !entry.isForeign && !entry.isArchived && entry.status != "Done" {
            let before = previous[entry.number]
            guard before?.isForeign != true, before?.triage != entry.triage else { continue }
            do {
                try await followSubscription(from: before?.triage, to: entry.triage, number: entry.number, contentID: entry.contentID)
            } catch {
                Self.boardLogger.error("Failed to follow the Status of #\(entry.number) with its subscription: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private static let boardLogger = Logger(subsystem: "com.bugenzhao.PRDesk", category: "Board")

    func setPriority(_ priority: Priority?, number: Int, contentID: String) async throws {
        try await writeBoard(number: number, contentID: contentID) { entry in
            entry.priority = priority?.optionName
        } field: { schema, _ in
            guard let priority else {
                guard let field = schema.priority else { throw BoardError.missingField("Priority") }
                return (field.id, nil)
            }
            let (id, option) = try Self.option(schema.priority, named: priority.optionName, in: "Priority")
            return (id, FieldValue(singleSelectOptionId: option))
        }
    }

    /// `SUBSCRIBED` or `UNSUBSCRIBED` (only when participating or mentioned).
    private func setSubscription(_ state: String, subjectID: String) async throws {
        if isDryRun("set subscription of \(subjectID) to \(state)") { return }
        try await mutate(
            "mutation($input: UpdateSubscriptionInput!) { updateSubscription(input: $input) { subscribable { id } } }",
            ["subscribableId": subjectID, "state": state]
        )
    }
}
