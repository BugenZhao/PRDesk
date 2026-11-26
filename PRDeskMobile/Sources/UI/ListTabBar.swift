import SwiftUI
import UIKit

/// Which list shows, as the system's own tab bar: a `UITabBar` on its own, which draws itself
/// in glass with the system's selection and badges. Symbols alone where room is short (the list
/// as a sidebar), or each with its name beside it, the layout the system gives a tab bar in a
/// wide window.
struct ListTabBar: UIViewRepresentable {
    @Binding var selection: AppModel.ListMode
    let parityCount: Int
    let inboxCount: Int
    var showsNames = false

    /// A touch's width a list, or room for its name too. The bar draws its capsule in the upper
    /// 44 points of its height (the rest is where titles go when they are under the symbols),
    /// so it is laid out as 44 tall from its top (`listTabBarFrame`).
    static func size(showsNames: Bool) -> CGSize {
        CGSize(width: showsNames ? 340 : 180, height: 54)
    }

    static let capsuleHeight: CGFloat = 44

    private static let modes: [(AppModel.ListMode, String, String)] = [
        (.dashboard, "Dashboard", "square.grid.2x2"),
        (.parity, "Parity", "equal.circle"),
        (.inbox, "Inbox", "bell"),
    ]

    final class Coordinator: NSObject, UITabBarDelegate {
        var select: (AppModel.ListMode) -> Void = { _ in }
        var showsNames: Bool?

        func tabBar(_: UITabBar, didSelect item: UITabBarItem) {
            select(ListTabBar.modes[item.tag].0)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITabBar {
        let bar = UITabBar()
        bar.delegate = context.coordinator
        return bar
    }

    private func items() -> [UITabBarItem] {
        Self.modes.enumerated().map { index, mode in
            // At the size and weight of the bar's buttons beside it. The chosen list's symbol
            // is filled, as SwiftUI's tab views have theirs; UIKit asks for it by name.
            let configuration = UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
            let item = UITabBarItem(
                title: showsNames ? mode.1 : nil, image: UIImage(systemName: mode.2, withConfiguration: configuration), tag: index
            )
            item.selectedImage = UIImage(systemName: mode.2 + ".fill", withConfiguration: configuration)
            item.accessibilityLabel = mode.1
            return item
        }
    }

    func updateUIView(_ bar: UITabBar, context: Context) {
        context.coordinator.select = { selection = $0 }
        if context.coordinator.showsNames != showsNames {
            context.coordinator.showsNames = showsNames
            // A name beside its symbol is how the system lays a tab bar out in a wide window;
            // the bar is told its width is one, whatever the window's is (a phone, or the
            // list at full width, where the split view is told compact).
            bar.traitOverrides.horizontalSizeClass = showsNames ? .regular : .compact
            // Beside a name the badge sits on the name's end: moved clear of its last letter
            // (a positive horizontal adjustment moves it back over the name).
            // The bar's own appearance, changed, rather than a new one, which lays out tighter.
            let appearance = bar.standardAppearance.copy()
            for layout in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance] {
                for state in [layout.normal, layout.selected] {
                    if showsNames { state.badgePositionAdjustment = UIOffset(horizontal: -6, vertical: -3) }
                    state.badgeBackgroundColor = .tintColor
                }
            }
            bar.standardAppearance = appearance
            bar.items = items()
        }
        let index = Self.modes.firstIndex { $0.0 == selection } ?? 0
        if bar.selectedItem?.tag != index { bar.selectedItem = bar.items?[index] }
        for (item, count) in zip(bar.items ?? [], [0, parityCount, inboxCount]) {
            item.badgeValue = count > 0 ? (count > 99 ? "99+" : String(count)) : nil
            item.badgeColor = .tintColor
        }
    }

    func sizeThatFits(_: ProposedViewSize, uiView _: UITabBar, context _: Context) -> CGSize? {
        Self.size(showsNames: showsNames)
    }
}

extension View {
    /// Lays a `ListTabBar` out by its capsule, level with the bar's buttons. The bar centers its
    /// capsule in the width it is given and wants margins beside it, which the layout leaves out.
    func listTabBarFrame(showsNames: Bool) -> some View {
        let size = ListTabBar.size(showsNames: showsNames)
        return frame(width: size.width, height: size.height)
            .frame(width: showsNames ? 270 : size.width, height: ListTabBar.capsuleHeight, alignment: .top)
            // The capsule with names is the shorter one of a wide window's tab bar.
            .offset(y: showsNames ? 5 : -1)
    }
}
