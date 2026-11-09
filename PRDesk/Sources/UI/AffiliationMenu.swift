import AppKit
import SwiftUI

/// The orgs to tie people to by hand (SPEC §5): each org checked when they have its badge,
/// picking one toggles it, and the manual entries can be cleared. Used by the list's right-click
/// menu and the conversation's menu on a person.
enum AffiliationMenu {
    private static let iconSize = NSSize(width: 16, height: 16)

    @MainActor
    static func make(for logins: [String], model: AppModel) -> NSMenu {
        let affiliations = model.affiliations
        var seen = Set<String>()
        let logins = logins.filter { seen.insert($0.lowercased()).inserted }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for org in Org.allCases {
            let count = logins.count { affiliations.hasFullBadge(org: org, for: $0) }
            let state: NSControl.StateValue = count == 0 ? .off : count == logins.count ? .on : .mixed
            let item = ClosureMenuItem(org.displayName, state: state) {
                model.toggleAffiliation(org, for: logins)
            }
            if let image = Badge(org: org, source: "").image?.copy() as? NSImage {
                image.size = iconSize
                item.image = image
                // macOS 27 hides menu images unless asked; the badge is what the item is about.
                if #available(macOS 27, *) { item.preferredImageVisibility = .visible }
            }
            // Why one person has (or lacks) the badge.
            if logins.count == 1, let login = logins.first {
                if let manual = affiliations.override(org: org, for: login) {
                    item.subtitle = manual.include ? "Added manually" : "Hidden manually"
                } else if let badge = affiliations.badge(org: org, for: login) {
                    item.subtitle = badge.isSecondary ? "\(badge.name): \(badge.source)" : badge.source
                }
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let keys = Set(logins.map { $0.lowercased() })
        let hasManual = affiliations.overrides.contains { keys.contains($0.login) }
        menu.addItem(ClosureMenuItem("Clear Manual Affiliations", systemImage: "arrow.uturn.backward", isEnabled: hasManual) {
            model.clearManualAffiliations(for: logins)
        })
        return menu
    }

    /// The submenu's entry, titled for whose affiliation it sets.
    @MainActor
    static func item(_ title: String, for logins: [String], model: AppModel) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "building.2", accessibilityDescription: nil)
        item.submenu = make(for: logins, model: model)
        return item
    }
}

/// `AffiliationMenu` as a SwiftUI submenu, for the detail header's author.
struct AffiliationSubmenu: View {
    @Environment(AppModel.self) private var model
    let login: String

    var body: some View {
        let affiliations = model.affiliations
        Menu("Affiliation", systemImage: "building.2") {
            ForEach(Org.allCases) { org in
                Toggle(org.displayName, isOn: Binding(
                    get: { affiliations.hasFullBadge(org: org, for: login) },
                    set: { _ in model.toggleAffiliation(org, for: [login]) }
                ))
            }
            Divider()
            Button("Clear Manual Affiliations", systemImage: "arrow.uturn.backward") {
                model.clearManualAffiliations(for: [login])
            }
            .disabled(!affiliations.overrides.contains { $0.login == login.lowercased() })
        }
    }
}
