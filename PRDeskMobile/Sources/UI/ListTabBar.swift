import SwiftUI
import UIKit

/// Which list shows, as the system's own tab bar: a `UITabBar` on its own, which draws itself
/// in glass with the system's selection (the lens that follows a finger across it). Symbols
/// alone, always: which list it is the list itself says, and the menus. What waits in a list is
/// a badge on its symbol's corner, drawn here in the system's manner (`TabBarHost.placeBadges`).
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
            host.setItems(items())
        }
        let index = Self.modes.firstIndex { $0.0 == selection } ?? 0
        if bar.selectedItem?.tag != index { bar.selectedItem = bar.items?[index] }
        let counts = [0, parityCount, inboxCount].map { $0 > 0 ? ($0 > 99 ? "99+" : String($0)) : nil }
        for (item, count) in zip(bar.items ?? [], counts) { item.accessibilityValue = count }
        host.counts = counts
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
/// without. The symbols are off the middle of their buttons: how far is measured in the bar as
/// it laid itself out and made up for (`centerSymbols`); should the system center them one day,
/// there is nothing to make up. And a badge of the bar's own is in the air past its symbol,
/// where the name would end: the badges are views of the host's instead (`placeBadges`).
final class TabBarHost: UIView {
    let bar = UITabBar()
    /// What waits in each list, as a badge shows it; nil for none.
    var counts: [String?] = [] {
        didSet { if counts != oldValue { setNeedsLayout() } }
    }
    /// Told the capsule's size when it is measured or changes.
    var onMeasure: ((CGSize) -> Void)?
    /// The height of a navigation bar's buttons, which the capsule is to match.
    static let buttonHeight: CGFloat = 44
    /// More than any three lists need; the capsule takes what it needs of it.
    private static let room: CGFloat = 1000
    /// Where the bar drew its capsule, in the bar's bounds.
    private var capsule: CGRect?
    private var needsMeasure = true
    private var badges: [Badge] = []
    /// The items' symbols as they were given, plain and chosen.
    private var symbols: [(UIImage?, UIImage?)] = []
    /// The room added beside the symbols to bring them to the middle (`centerSymbols`).
    private var symbolRoom: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(bar)
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

    /// A badge on its symbol's corner, where one sits on an icon: its middle on the symbol's
    /// trailing edge, its top at the top of the symbol's button. The bar's own badges
    /// (`badgeValue`) go where an item's name ends, which with no name is in the air past the
    /// symbol, and the bar puts them back there whatever is done to them or to the view they are
    /// in (`badgePositionAdjustment` moves nothing in this bar; a move of their view the bar
    /// makes up for at its next layout, so they jumped). So these are the host's own, over the
    /// bar, in the measures of the system's: 16 pt tall, a count in white on the tint.
    private func placeBadges() {
        let symbols = symbolViews().suffix(counts.count)
        for label in badges.dropFirst(counts.count) { label.isHidden = true }
        for (index, count) in counts.enumerated() {
            if badges.count <= index {
                badges.append(Badge())
                addSubview(badges[index])
            }
            let label = badges[index]
            // Of the bar's two pictures of each symbol the later ones: the lens draws the
            // others larger under a finger.
            guard let count, symbols.count == counts.count else {
                label.isHidden = true
                continue
            }
            let symbol = symbols[symbols.startIndex + index]
            let frame = symbol.convert(symbol.bounds, to: self)
            let top = symbol.superview.map { $0.convert($0.bounds, to: self).minY } ?? frame.minY
            label.text = count
            let width = max(Badge.height, ceil(label.textSize.width) + Badge.height / 2)
            label.frame = CGRect(x: frame.maxX - max(symbolRoom, 0) - width / 2, y: top, width: width, height: Badge.height)
                .insetBy(dx: -Badge.rim, dy: -Badge.rim)
            label.isHidden = false
        }
    }

    /// A count in white on the tint, with a rim in the ground's color around it, which keeps it
    /// apart from a chosen list's symbol, filled in the same tint. It draws itself: a label or
    /// an image view in a bar's glass is drawn in one color with the rest of the glass's content
    /// (this came out a white disc).
    private final class Badge: UIView {
        static let height: CGFloat = 16
        static let rim: CGFloat = 1.5
        private static let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: UIColor.white,
        ]

        var text = "" {
            didSet { if text != oldValue { setNeedsDisplay() } }
        }

        var textSize: CGSize { (text as NSString).size(withAttributes: Self.attributes) }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = false
            isUserInteractionEnabled = false
            contentMode = .redraw
            // The rim is the ground's color, light or dark.
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (badge: Badge, _) in badge.setNeedsDisplay() }
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func tintColorDidChange() {
            super.tintColorDidChange()
            setNeedsDisplay()
        }

        override func draw(_: CGRect) {
            UIColor.systemBackground.setFill()
            UIBezierPath(roundedRect: bounds, cornerRadius: bounds.height / 2).fill()
            tintColor.setFill()
            let face = bounds.insetBy(dx: Self.rim, dy: Self.rim)
            UIBezierPath(roundedRect: face, cornerRadius: face.height / 2).fill()
            let size = textSize
            (text as NSString).draw(
                at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: Self.attributes
            )
        }
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        if needsMeasure, window != nil { measure() }
        placeBar()
        placeBadges()
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
