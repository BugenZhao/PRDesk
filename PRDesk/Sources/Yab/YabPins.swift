import AppKit
import os

/// Mirrors pinned items into a folder of Yab's sidebar, one way (SPEC §3.4), through `yab exec`.
/// `native_context` and `tabs` only see the space on screen, so a round runs only while the chosen
/// space is; what's left waits for the next one. Off unless switched on in Settings, which also
/// keeps test copies, with their own preferences, away from the real browser.
enum YabPins {
    static let enabledKey = "yabPinsEnabled"
    static let spaceKey = "yabPinsSpace"
    static let defaultSpace = "Inferact"
    static let folder = "PR Desk"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// The space the folder lives in, by name, set in Settings.
    static var space: String {
        let name = UserDefaults.standard.string(forKey: spaceKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? defaultSpace : name
    }

    /// What a round has to do: pins with no tab yet, and tabs whose pin is gone.
    struct Work: Encodable, Sendable {
        struct Add: Encodable, Sendable {
            var item: Item.ID
            var url: String
            var title: String
        }

        struct Close: Encodable, Sendable {
            var item: Item.ID
            var tab: String
        }

        var add: [Add]
        var close: [Close]
        var isEmpty: Bool { add.isEmpty && close.isEmpty }
    }

    private struct Input: Encodable {
        var space: String
        var folder: String
        var add: [Work.Add]
        var close: [Work.Close]
    }

    private struct Output: Decodable {
        struct Added: Decodable {
            var item: Item.ID
            var tab: String
        }

        var missingSpace: Bool?
        var offScreen: Bool?
        var added: [Added]?
        var released: [Item.ID]?
    }

    private static let logger = Logger(subsystem: "com.bugenzhao.PRDesk", category: "Yab")

    /// Brings Yab in line with the pins. Returns why it can't for now, if so, for Settings.
    @concurrent
    static func reconcile(db: AppDatabase) async -> String? {
        do {
            let work = try await db.yabPinWork()
            guard !work.isEmpty else { return nil }
            guard let yab = Yab.runningExecutable else {
                return "Waiting for Yab to open."
            }
            let space = space
            if isDryRun("Yab: in \(space), add \(work.add.map(\.url)), close \(work.close.map(\.tab))") { return nil }
            let output = try run(yab, input: Input(space: space, folder: folder, add: work.add, close: work.close))
            if output.missingSpace == true { return "Yab has no space named \(space)." }
            if output.offScreen == true { return "Waiting for the \(space) space to be on screen in Yab." }
            for added in output.added ?? [] {
                try await db.updateState(added.item) { $0.yabTabID = added.tab }
            }
            for item in output.released ?? [] {
                try await db.updateState(item) { $0.yabTabID = nil }
            }
            return nil
        } catch {
            logger.error("Round failed: \(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
        }
    }

    private static func run(_ yab: URL, input: Input) throws -> Output {
        let payload = try String(decoding: JSONEncoder().encode(input), as: UTF8.self)
        let answer = try Yab.exec(yab, script: script.replacingOccurrences(of: "__INPUT__", with: payload))
        return try JSONDecoder().decode(Output.self, from: Data(answer.utf8))
    }

    /// One round, run by Yab. A tab is ours by the folder it is in: one the user moved out is theirs
    /// and stays when its pin goes. Yab only dedupes by the exact address and a tab's address moves
    /// as it is used (`#issuecomment-…`, `/files`), so tabs are compared by the item's address.
    /// A pin already open among today's tabs moves into the folder, and one the user keeps elsewhere
    /// stays there, asked about again each round. The tab in front can't be closed: it waits.
    private static let script = #"""
    const input = __INPUT__;
    const key = url => (url.match(/^https:\/\/github\.com\/[^\/]+\/[^\/]+\/(?:pull|issues)\/\d+/i) || [url])[0].toLowerCase();
    function read() {
      const urls = {};
      for (const line of __tool('tabs', {}).split('\n')) {
        const match = line.match(/^(\w+) \[user\].*, (\S+)$/);
        if (match) urls[match[1]] = match[2];
      }
      const tabs = [];
      let context;
      do {
        context = JSON.parse(__tool('native_context', {section: 'summary', limit: 50, offset: tabs.length}));
        tabs.push(...context.tabs);
      } while (context.hasMoreTabs && context.tabs.length);
      for (const tab of tabs) tab.key = key(urls[tab.id.slice(0, 8).toLowerCase()] || '');
      return {context, tabs};
    }
    const inFolder = tab => tab.folderPath === input.folder;

    let {context, tabs} = read();
    const space = context.spaces.find(s => s.name === input.space);
    if (!space) return JSON.stringify({missingSpace: true});
    if (!space.active) return JSON.stringify({offScreen: true});

    const released = [];
    for (const {item, tab} of input.close) {
      const found = tabs.find(t => t.id === tab);
      if (!found || !inFolder(found)) { released.push(item); continue; }
      if (found.active) continue;
      try {
        __tool('native_apply', {action: 'tabs.close', target: {kind: 'space', id: space.id},
          arguments: {tabs: [tab], includePinned: true}, requestId: `prdesk-close-${tab}-${Date.now()}`});
        released.push(item);
      } catch (error) {}
    }

    const toLayOut = [];
    const toMove = [];
    for (const item of input.add) {
      const same = tabs.filter(t => t.key === key(item.url));
      if (same.some(inFolder) || same.some(t => t.kept || t.pinned)) continue;
      if (same.length) toMove.push(same[0].id); else toLayOut.push({url: item.url, title: item.title, folder: input.folder});
    }
    if (toLayOut.length) {
      __tool('lay_out_tabs', {spaces: [{space: input.space, pinned: toLayOut}]});
      ({context, tabs} = read());
    }
    if (toMove.length) {
      const folder = context.folders.find(f => f.path === input.folder);
      const change = folder
        ? {action: 'tabs.move_to_folder', target: {kind: 'folder', id: folder.id}, arguments: {tabs: toMove}}
        : {action: 'tabs.group', target: {kind: 'space', id: space.id}, arguments: {tabs: toMove, name: input.folder}};
      try {
        __tool('native_apply', {...change, requestId: `prdesk-move-${Date.now()}`});
        ({context, tabs} = read());
      } catch (error) {}
    }

    const added = [];
    for (const {item, url} of input.add) {
      const found = tabs.find(t => inFolder(t) && t.key === key(url));
      if (found) added.push({item, tab: found.id});
    }
    return JSON.stringify({added, released});
    """#
}
