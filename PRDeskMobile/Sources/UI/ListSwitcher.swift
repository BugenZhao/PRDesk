import SwiftUI

/// Which list shows: Dashboard, Parity or the Inbox, as the content of one toolbar item, so the
/// bar gives it the glass capsule and the height it gives its buttons. The chosen list is
/// tinted, its symbol filled, on a pill that slides to it; what waits in Parity and the Inbox
/// is a badge on the symbol's corner. Each list's name is beside its symbol where there is room.
///
/// It has no size of its own to set and none to correct: the symbols and names lay it out, at
/// any text size. (The system's `UITabBar` looked the part but isn't made for a toolbar: it had
/// to be given a frame, cropped to its capsule and nudged level, and with names its capsule is
/// shorter than the bar's buttons.)
struct ListSwitcher: View {
    @Environment(AppModel.self) private var model
    let showsNames: Bool
    @Namespace private var pill
    @State private var namesOpacity = 1.0

    private static let lists: [(mode: AppModel.ListMode, name: String, symbol: String)] = [
        (.dashboard, "Dashboard", "square.grid.2x2"),
        (.parity, "Parity", "equal.circle"),
        (.inbox, "Inbox", "bell"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Self.lists, id: \.mode) { list in
                segment(list.mode, name: list.name, symbol: list.symbol)
            }
        }
        .animation(.snappy(duration: 0.25), value: model.mode)
        // The bar gives the item its new width at once when the names come or go, and centers
        // in it whatever is still on its way: so the layout isn't animated. The names fade in
        // where they belong, and go at once.
        .onChange(of: showsNames) {
            if showsNames {
                withAnimation(.easeOut(duration: 0.3)) { namesOpacity = 1 }
            } else {
                namesOpacity = 0
            }
        }
    }

    private func segment(_ mode: AppModel.ListMode, name: String, symbol: String) -> some View {
        let isChosen = model.mode == mode
        let count = mode == .parity ? model.parityWaitingCount : mode == .inbox ? model.unreadInboxCount : 0
        return Button {
            model.mode = mode
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .symbolVariant(isChosen ? .fill : .none)
                    .overlay(alignment: .topTrailing) { badge(count) }
                if showsNames {
                    Text(name)
                        .font(.subheadline.weight(.medium))
                        .fixedSize()
                        .opacity(namesOpacity)
                }
            }
            .foregroundStyle(isChosen ? Color.accentColor : Color.primary)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background {
                if isChosen {
                    Capsule().fill(Color.primary.opacity(0.09)).matchedGeometryEffect(id: "chosen", in: pill)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count > 0 ? "\(name), \(count) waiting" : name)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    /// On the symbol's upper trailing corner, in the color of the list's unread dots.
    @ViewBuilder
    private func badge(_ count: Int) -> some View {
        if count > 0 {
            Text(count > 99 ? "99+" : String(count))
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .frame(minWidth: 15, minHeight: 15)
                .background(Color.accentColor, in: .capsule)
                .fixedSize()
                // Mostly off the symbol, so the symbol still reads.
                .alignmentGuide(.trailing) { $0[HorizontalAlignment.center] - 4 }
                .alignmentGuide(.top) { $0[VerticalAlignment.center] + 4 }
        }
    }
}
