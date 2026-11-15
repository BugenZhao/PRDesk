import SwiftUI

extension StateTint {
    var color: Color {
        switch self {
        case .green: .green
        case .gray: .secondary
        case .yellow: .yellow
        case .purple: .purple
        case .red: .red
        }
    }
}

/// An item's state icon in its state color, as in the list.
struct StateIconView: View {
    let item: Item
    var size: CGFloat = 14
    var isMerging = false

    var body: some View {
        Group {
            switch item.stateIcon {
            case let .asset(name): Image(name).renderingMode(.template).resizable()
            case let .symbol(name): Image(systemName: name).resizable()
            }
        }
        .scaledToFit()
        .frame(width: size, height: size)
        .foregroundStyle(item.stateTint(isMerging: isMerging).color)
        .help(item.stateDescription(isMerging: isMerging))
    }
}
