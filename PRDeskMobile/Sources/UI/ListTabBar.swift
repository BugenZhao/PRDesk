import SwiftUI
import UIKit

/// Which list shows, as the system's own tab bar: a `UITabBar` on its own, which draws itself
/// in glass with the system's selection (the lens that follows a finger across it) and badges.
/// Symbols alone, or each with its name beside it, the layout the system gives a tab bar in a
/// wide window.
///
/// A tab bar isn't made to sit in a toolbar: it has no size of its own there, and draws its
/// capsule somewhere inside whatever bounds it is given. So it is laid out with room to spare
/// in a host that measures where the capsule came out and shows exactly that
/// (`TabBarHost`): nothing here is a size or an offset set by eye.
struct ListTabBar: View {
    @Binding var selection: AppModel.ListMode
    let parityCount: Int
    let inboxCount: Int
    var showsNames = false
    /// The capsule as the bar drew it in its window; until then, room for three symbols.
    @State private var capsule: CGSize?

    var body: some View {
        TabBarView(selection: $selection, parityCount: parityCount, inboxCount: inboxCount, showsNames: showsNames) { size in
            if capsule != size { capsule = size }
        }
        .frame(width: capsule?.width ?? 3 * TabBarHost.buttonHeight, height: capsule?.height ?? TabBarHost.buttonHeight)
    }
}

private struct TabBarView: UIViewRepresentable {
    @Binding var selection: AppModel.ListMode
    let parityCount: Int
    let inboxCount: Int
    let showsNames: Bool
    let onMeasure: (CGSize) -> Void

    static let modes: [(AppModel.ListMode, String, String)] = [
        (.dashboard, "Dashboard", "square.grid.2x2"),
        (.parity, "Parity", "equal.circle"),
        (.inbox, "Inbox", "bell"),
    ]

    final class Coordinator: NSObject, UITabBarDelegate {
        var select: (AppModel.ListMode) -> Void = { _ in }
        var showsNames: Bool?

        func tabBar(_: UITabBar, didSelect item: UITabBarItem) {
            select(TabBarView.modes[item.tag].0)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> TabBarHost {
        let host = TabBarHost()
        host.bar.delegate = context.coordinator
        return host
    }

    private func items() -> [UITabBarItem] {
        Self.modes.enumerated().map { index, mode in
            // The configuration of the bar's own buttons (measured: the same symbol comes out
            // the same size in both). The chosen list's symbol is filled, as SwiftUI's tab views
            // have theirs; UIKit asks for it by name.
            let configuration = UIImage.SymbolConfiguration(textStyle: .body, scale: .large)
                .applying(UIImage.SymbolConfiguration(weight: .medium))
            let item = UITabBarItem(
                title: showsNames ? mode.1 : nil, image: UIImage(systemName: mode.2, withConfiguration: configuration), tag: index
            )
            item.selectedImage = UIImage(systemName: mode.2 + ".fill", withConfiguration: configuration)
            item.accessibilityLabel = mode.1
            return item
        }
    }

    func updateUIView(_ host: TabBarHost, context: Context) {
        let bar = host.bar
        host.onMeasure = onMeasure
        // The list changes on the next turn, so the bar's own selection isn't held up by it.
        context.coordinator.select = { mode in DispatchQueue.main.async { selection = mode } }
        if context.coordinator.showsNames == nil {
            context.coordinator.showsNames = showsNames
            // The bar is told its width is a wide window's, whatever the window's is: there a
            // tab bar's capsule is as wide as its items need (in a narrow one it fills the
            // bar), and a name is beside its symbol.
            bar.traitOverrides.horizontalSizeClass = .regular
            // Badges in the color of the list's unread dots. On the bar's own appearance, a
            // copy: a new one lays the items out tighter.
            let appearance = bar.standardAppearance.copy()
            for layout in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance] {
                for state in [layout.normal, layout.selected] { state.badgeBackgroundColor = .tintColor }
            }
            bar.standardAppearance = appearance
            bar.items = items()
            host.setNeedsMeasure()
        } else if context.coordinator.showsNames != showsNames {
            context.coordinator.showsNames = showsNames
            // The names open out of the symbols and fold back into them: the same items, their
            // titles set inside the bar's own animated layout.
            host.change {
                for (item, mode) in zip(bar.items ?? [], Self.modes) { item.title = showsNames ? mode.1 : nil }
            }
        }
        let index = Self.modes.firstIndex { $0.0 == selection } ?? 0
        if bar.selectedItem?.tag != index { bar.selectedItem = bar.items?[index] }
        for (item, count) in zip(bar.items ?? [], [0, parityCount, inboxCount]) {
            let value = count > 0 ? (count > 99 ? "99+" : String(count)) : nil
            if item.badgeValue != value { item.badgeValue = value }
        }
    }

    /// Whatever it is given: the size is `ListTabBar`'s to set, from what the host measured.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView _: TabBarHost, context _: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 3 * TabBarHost.buttonHeight, height: TabBarHost.buttonHeight))
    }
}

/// Holds a tab bar laid out with room to spare, measures where the bar drew its capsule, and
/// places the bar so that the capsule fills the host.
///
/// The bar draws its capsule as wide as its items need, centered, and as tall as its own height
/// allows: so the height is tried until the capsule comes out as tall as the bar's buttons,
/// with names as without (left to itself a tab bar with names is shorter). Measured only in a
/// window: before, the bar doesn't lay out as it will.
final class TabBarHost: UIView {
    let bar = UITabBar()
    /// Told the capsule's size when it is measured or changes.
    var onMeasure: ((CGSize) -> Void)?
    /// The height of a navigation bar's buttons, which the capsule is to match.
    static let buttonHeight: CGFloat = 44
    /// More than any three lists need; the capsule takes what it needs of it.
    private static let room: CGFloat = 1000
    /// Where the bar drew its capsule, in the bar's bounds.
    private var capsule: CGRect?
    private var needsMeasure = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(bar)
        // Another text size is another capsule.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (host: TabBarHost, _) in host.setNeedsMeasure() }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setNeedsMeasure() {
        needsMeasure = true
        setNeedsLayout()
    }

    /// Makes a change to the bar that resizes its capsule, animated: the capsule grows or
    /// shrinks from its leading end, the bar moving under it in the same animation (the bar
    /// keeps its capsule centered in its own, wider, bounds).
    func change(_ change: @escaping () -> Void) {
        guard window != nil, !UIAccessibility.isReduceMotionEnabled else {
            change()
            return setNeedsMeasure()
        }
        UIView.animate(
            withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            change()
            self.measure()
            self.placeBar()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { setNeedsMeasure() }
    }

    /// The bar's capsule is its first subview: found by where it is, not by its (private) name.
    private func measure() {
        needsMeasure = false
        var height = bar.sizeThatFits(CGSize(width: Self.room, height: 200)).height
        var measured: CGRect?
        for _ in 0 ..< 4 {
            bar.frame.size = CGSize(width: Self.room, height: height)
            bar.setNeedsLayout()
            bar.layoutIfNeeded()
            guard let frame = bar.subviews.first?.frame, frame.width > 0, frame.height > 0 else { break }
            measured = frame
            let short = Self.buttonHeight - frame.height
            if abs(short) < 0.5 { break }
            height += short
        }
        guard let measured, measured != capsule else { return }
        capsule = measured
        // Not in the middle of a layout pass.
        DispatchQueue.main.async { [weak self] in self?.onMeasure?(measured.size) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if needsMeasure, window != nil { measure() }
        placeBar()
    }

    /// At the host's leading end, whatever the host's width is just then: the item is given
    /// its new width at once when the names come or go, while the capsule is still on its way.
    private func placeBar() {
        guard let capsule else { return }
        bar.frame.origin = CGPoint(x: -capsule.minX, y: -capsule.minY + (bounds.height - capsule.height) / 2)
    }

    /// Touches on the capsule, wherever the bar's own bounds are.
    override func point(inside point: CGPoint, with _: UIEvent?) -> Bool {
        bounds.contains(point)
    }
}
