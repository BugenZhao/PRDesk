import SwiftUI
import UIKit

/// Which list shows, as the system's own tab bar: a `UITabBar` on its own, which draws itself
/// in glass with the system's selection (the lens that follows a finger across it) and badges.
/// Symbols alone, always: which list it is the list itself says, and the menus.
///
/// A tab bar isn't made to sit in a toolbar: it has no size of its own there, and draws its
/// capsule somewhere inside whatever bounds it is given. So it is laid out with room to spare
/// in a host that measures where the capsule came out and shows exactly that
/// (`TabBarHost`): nothing here is a size or an offset set by eye.
struct ListTabBar: View {
    @Binding var selection: AppModel.ListMode
    let parityCount: Int
    let inboxCount: Int
    /// The capsule as the bar drew it in its window; until then, room for three symbols.
    @State private var capsule: CGSize?

    var body: some View {
        TabBarView(selection: $selection, parityCount: parityCount, inboxCount: inboxCount) { size in
            if capsule != size { capsule = size }
        }
        .frame(width: capsule?.width ?? 3 * TabBarHost.buttonHeight, height: capsule?.height ?? TabBarHost.buttonHeight)
    }
}

private struct TabBarView: UIViewRepresentable {
    @Binding var selection: AppModel.ListMode
    let parityCount: Int
    let inboxCount: Int
    let onMeasure: (CGSize) -> Void

    static let modes: [(AppModel.ListMode, String, String)] = [
        (.dashboard, "Dashboard", "square.grid.2x2"),
        (.parity, "Parity", "equal.circle"),
        (.inbox, "Inbox", "bell"),
    ]

    final class Coordinator: NSObject, UITabBarDelegate {
        var select: (AppModel.ListMode) -> Void = { _ in }
        var isSetUp = false

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
            let item = UITabBarItem(title: nil, image: UIImage(systemName: mode.2, withConfiguration: configuration), tag: index)
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
        if !context.coordinator.isSetUp {
            context.coordinator.isSetUp = true
            // The bar is told its width is a wide window's, whatever the window's is: there a
            // tab bar's capsule is as wide as its items need (in a narrow one it fills the
            // bar).
            bar.traitOverrides.horizontalSizeClass = .regular
            // Badges in the color of the list's unread dots. On the bar's own appearance, a
            // copy: a new one lays the items out tighter.
            let appearance = bar.standardAppearance.copy()
            for layout in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance] {
                for state in [layout.normal, layout.selected] { state.badgeBackgroundColor = .tintColor }
            }
            bar.standardAppearance = appearance
            host.setItems(items())
        }
        let index = Self.modes.firstIndex { $0.0 == selection } ?? 0
        if bar.selectedItem?.tag != index { bar.selectedItem = bar.items?[index] }
        for (item, count) in zip(bar.items ?? [], [0, parityCount, inboxCount]) {
            let value = count > 0 ? (count > 99 ? "99+" : String(count)) : nil
            if item.badgeValue != value {
                item.badgeValue = value
                host.setNeedsBadges()
            }
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
/// allows: so the height is tried until the capsule comes out as tall as the bar's buttons.
/// Measured only in a window: before, the bar doesn't lay out as it will.
///
/// A tab bar's items have names wherever the system uses one, and two things come out wrong
/// without: the symbols are off the middle of their buttons, and a badge is in the air past its
/// symbol. Both are measured in the bar as it laid itself out and made up for (`centerSymbols`,
/// `placeBadges`); should the system lay them out right one day, there is nothing to make up.
final class TabBarHost: UIView {
    /// Tells when it has laid itself out, which is when it puts its badges where it wants them.
    final class Bar: UITabBar {
        var onLayout: (() -> Void)?

        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?()
        }
    }

    let bar = Bar()
    /// Told the capsule's size when it is measured or changes.
    var onMeasure: ((CGSize) -> Void)?
    /// The height of a navigation bar's buttons, which the capsule is to match.
    static let buttonHeight: CGFloat = 44
    /// More than any three lists need; the capsule takes what it needs of it.
    private static let room: CGFloat = 1000
    /// Where the bar drew its capsule, in the bar's bounds.
    private var capsule: CGRect?
    private var needsMeasure = true
    private var needsBadges = false
    /// The items' symbols as they were given, plain and chosen.
    private var symbols: [(UIImage?, UIImage?)] = []
    /// The room added beside the symbols to bring them to the middle (`centerSymbols`).
    private var symbolRoom: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(bar)
        bar.onLayout = { [weak self] in
            self?.placeBadges()
            self?.setNeedsBadges()
        }
        // Another text size is another capsule, and other symbols to draw (bold text too).
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitLegibilityWeight.self]) { (host: TabBarHost, _) in
            host.redrawSymbols()
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setItems(_ items: [UITabBarItem]) {
        symbols = items.map { ($0.image, $0.selectedImage) }
        symbolRoom = 0
        bar.items = items
        setNeedsMeasure()
    }

    func setNeedsMeasure() {
        needsMeasure = true
        setNeedsLayout()
    }

    /// Back to the symbols themselves, to be measured and drawn again.
    private func redrawSymbols() {
        if symbolRoom != 0 {
            symbolRoom = 0
            for (item, symbol) in zip(bar.items ?? [], symbols) {
                item.image = symbol.0
                item.selectedImage = symbol.1
            }
        }
        setNeedsMeasure()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        setNeedsMeasure()
        settleLens()
    }

    /// Under a finger the lens draws the chosen item larger, and lets it back down in an
    /// animation after. A bar taken out of its window meanwhile (the split view rebuilding its
    /// columns, right after a list was picked) loses the animation and keeps the item large:
    /// back in a window, the bar's buttons are put at their own size.
    private func settleLens() {
        func visit(_ view: UIView) {
            if view is UIControl, !view.transform.isIdentity { view.transform = .identity }
            view.subviews.forEach(visit)
        }
        bar.subviews.first.map(visit)
    }

    /// The bar's capsule is its first subview: found by where it is, not by its (private) name.
    private func measure() {
        needsMeasure = false
        var height = bar.sizeThatFits(CGSize(width: Self.room, height: 200)).height
        var measured: CGRect?
        for _ in 0 ..< 6 {
            bar.frame.size = CGSize(width: Self.room, height: height)
            bar.setNeedsLayout()
            bar.layoutIfNeeded()
            guard let frame = bar.subviews.first?.frame, frame.width > 0, frame.height > 0 else { break }
            measured = frame
            let short = Self.buttonHeight - frame.height
            if abs(short) >= 0.5 {
                height += short
            } else if !centerSymbols() {
                break
            }
        }
        guard let measured, measured != capsule else { return }
        capsule = measured
        // Not in the middle of a layout pass.
        DispatchQueue.main.async { [weak self] in self?.onMeasure?(measured.size) }
    }

    // MARK: Symbols

    /// A symbol with no name beside it the bar lays out a few points past the middle of its
    /// button. How far is measured, and made up for by a picture of the symbol with that much
    /// room added beside it, so the symbol is in the middle wherever the bar puts the picture.
    /// (Saying so with the symbol's alignment rectangle works for the plain symbols only: the
    /// bar drops it from the chosen ones.) Returns whether anything changed, to lay out again.
    private func centerSymbols() -> Bool {
        guard let items = bar.items, items.count == symbols.count else { return false }
        let room = symbolRoom + 2 * (symbolShift() ?? 0)
        guard abs(room - symbolRoom) > 0.25 else { return false }
        symbolRoom = room
        for (item, symbol) in zip(items, symbols) {
            item.image = symbol.0.map { Self.picture(of: $0, room: room, traits: traitCollection) }
            item.selectedImage = symbol.1.map { Self.picture(of: $0, room: room, traits: traitCollection) }
        }
        return true
    }

    /// The symbol drawn with room beside it: after it, or before it when negative. A template
    /// like the symbol, so the bar colors it the same.
    private static func picture(of symbol: UIImage, room: CGFloat, traits: UITraitCollection) -> UIImage {
        guard room != 0 else { return symbol }
        let size = CGSize(width: symbol.size.width + abs(room), height: symbol.size.height)
        let renderer = UIGraphicsImageRenderer(size: size, format: UIGraphicsImageRendererFormat(for: traits))
        return renderer.image { _ in symbol.draw(at: CGPoint(x: max(-room, 0), y: 0)) }
            .withRenderingMode(.alwaysTemplate)
    }

    /// The bar's pictures of its items' symbols, each in its button (the bar keeps two of each:
    /// one is for the chosen item's lens).
    private func symbolViews() -> [UIImageView] {
        var views: [UIImageView] = []
        func visit(_ view: UIView) {
            if let image = view as? UIImageView, image.image != nil, image.superview is UIControl { views.append(image) }
            view.subviews.forEach(visit)
        }
        bar.subviews.first.map(visit)
        return views
    }

    /// How far past the middle of its button the bar has put a symbol, by the first of them
    /// (they are all laid out alike).
    private func symbolShift() -> CGFloat? {
        guard let image = symbolViews().first, let button = image.superview else { return nil }
        return image.frame.midX - symbolRoom / 2 - button.bounds.midX
    }

    // MARK: Badges

    /// Places the badges once more on the next turn of the run loop: the bar makes a badge's
    /// view some time after it is given the count, with no layout of its own to tell by.
    func setNeedsBadges() {
        guard !needsBadges else { return }
        needsBadges = true
        DispatchQueue.main.async { [weak self] in
            if self?.needsBadges == true { self?.placeBadges() }
        }
    }

    /// A badge the bar puts at the end of its item's name; with no name that is in the air
    /// past the symbol. The badges are moved onto the symbols' corners instead, a badge's
    /// middle on its symbol's trailing edge, where a badge sits on an icon. The bar offers no way
    /// to say so (`badgePositionAdjustment` moves nothing in this bar), and puts a badge's own
    /// view back where it wants it (a transform is gone once the badge has appeared): so the
    /// view all the badges are in is moved, which the bar only ever resizes.
    private func placeBadges() {
        needsBadges = false
        guard let platter = bar.subviews.first, let items = bar.items else { return }
        // The capsule lays its badges out in its own turn, after the bar's.
        platter.layoutIfNeeded()
        let counts = Set(items.compactMap(\.badgeValue))
        var found: UIView?
        func visit(_ view: UIView) {
            if found == nil, let label = view as? UILabel, let text = label.text, counts.contains(text) { found = label.superview }
            view.subviews.forEach(visit)
        }
        visit(platter)
        guard let badge = found, let badges = badge.superview else { return }
        // Where the bar has the badge, apart from the move made here, and its own symbol: the
        // last that begins before the badge does.
        let place = badge.frame.offsetBy(dx: badges.frame.minX, dy: 0)
        let edges = symbolViews().map { $0.convert($0.bounds, to: platter) }.filter { $0.minX < place.minX }.map(\.maxX)
        guard let edge = edges.max() else { return }
        let shift = edge - max(symbolRoom, 0) - place.midX
        if abs(badges.bounds.origin.x + shift) > 0.1 { badges.bounds.origin.x = -shift }
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        if needsMeasure, window != nil { measure() }
        placeBar()
    }

    /// At the host's leading end, whatever the host's width is just then.
    private func placeBar() {
        guard let capsule else { return }
        bar.frame.origin = CGPoint(x: -capsule.minX, y: -capsule.minY + (bounds.height - capsule.height) / 2)
    }

    /// Touches on the capsule, wherever the bar's own bounds are.
    override func point(inside point: CGPoint, with _: UIEvent?) -> Bool {
        bounds.contains(point)
    }
}
