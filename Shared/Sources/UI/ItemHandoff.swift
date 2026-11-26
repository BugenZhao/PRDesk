import SwiftUI

/// Handoff: the item being looked at on one device is offered on the others (in the Mac's Dock,
/// an iPad's, a phone's app switcher), and picking it there opens the same item on the same
/// tab. A view of no size for a scene's background, so that only it follows the selection.
///
/// The activity is the item's page on GitHub (`webpageURL`): this app takes it where it is
/// installed (the type is in both apps' `NSUserActivityTypes`), a browser where it isn't. The
/// system hands off only between apps of one developer team signed in to one iCloud account,
/// so not to or from a copy signed ad hoc.
struct ItemHandoff: View {
    @Environment(AppModel.self) private var model

    static let activityType = "com.bugenzhao.PRDesk.item"

    /// What is offered: the selected item's page, with the tab showing.
    private struct Target: Equatable {
        var title: String
        var url: URL
    }

    private var target: Target? {
        guard let item = model.selectedItem else { return nil }
        let page = switch item.kind == .pullRequest ? model.detailTab : .conversation {
        case .conversation: ""
        // The tab opens on all changes, which a browser shows as the files.
        case .commits: "/files"
        }
        guard let url = URL(string: item.url + page) else { return nil }
        return Target(title: "#\(item.number) \(item.title)", url: url)
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .userActivity(Self.activityType, element: target) { target, activity in
                activity.title = target.title
                activity.webpageURL = target.url
                activity.isEligibleForHandoff = true
            }
            .onContinueUserActivity(Self.activityType) { activity in
                // Parsed as a link pasted in would be: the item is opened, fetched if it isn't
                // here, on the tab the link names.
                guard let url = activity.webpageURL, let link = ItemLink(url.absoluteString) else { return }
                model.showWindow?()
                model.open(link)
            }
    }
}
