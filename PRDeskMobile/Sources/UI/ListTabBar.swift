import SwiftUI
import UIKit

/// Which list shows, as the system's own tab bar: a `UITabBar` on its own, which draws itself
/// in glass with the system's selection and badges. Symbols alone, no titles.
struct ListTabBar: UIViewRepresentable {
    @Binding var selection: AppModel.ListMode
    let parityCount: Int
    let inboxCount: Int

    /// A touch's width a list. The bar draws its capsule in the upper 44 points of its height
    /// (the rest is where titles would go), so it is laid out as 44 tall from its top
    /// (`listTabBarFrame`).
    static let size = CGSize(width: 180, height: 54)
    static let capsuleHeight: CGFloat = 44

    private static let modes: [(AppModel.ListMode, String, String)] = [
        (.dashboard, "Dashboard", "square.grid.2x2"),
        (.parity, "Parity", "arrow.left.arrow.right"),
        (.inbox, "Inbox", "bell"),
    ]

    final class Coordinator: NSObject, UITabBarDelegate {
        var select: (AppModel.ListMode) -> Void = { _ in }

        func tabBar(_: UITabBar, didSelect item: UITabBarItem) {
            select(ListTabBar.modes[item.tag].0)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITabBar {
        let bar = UITabBar()
        bar.items = Self.modes.enumerated().map { index, mode in
            // At the size and weight of the bar's buttons beside it.
            let configuration = UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
            let item = UITabBarItem(title: nil, image: UIImage(systemName: mode.2, withConfiguration: configuration), tag: index)
            item.accessibilityLabel = mode.1
            return item
        }
        bar.delegate = context.coordinator
        return bar
    }

    func updateUIView(_ bar: UITabBar, context: Context) {
        context.coordinator.select = { selection = $0 }
        let index = Self.modes.firstIndex { $0.0 == selection } ?? 0
        if bar.selectedItem?.tag != index { bar.selectedItem = bar.items?[index] }
        for (item, count) in zip(bar.items ?? [], [0, parityCount, inboxCount]) {
            item.badgeValue = count > 0 ? (count > 99 ? "99+" : String(count)) : nil
            item.badgeColor = .tintColor
        }
    }

    func sizeThatFits(_: ProposedViewSize, uiView _: UITabBar, context _: Context) -> CGSize? {
        CGSize(width: Self.size.width, height: Self.size.height)
    }
}

extension View {
    /// Lays a `ListTabBar` out by its capsule, level with the bar's buttons.
    func listTabBarFrame() -> some View {
        frame(width: ListTabBar.size.width, height: ListTabBar.size.height)
            .frame(height: ListTabBar.capsuleHeight, alignment: .top)
            .offset(y: 2)
    }
}
