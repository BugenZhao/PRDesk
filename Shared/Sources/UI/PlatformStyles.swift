import SwiftUI

#if os(macOS)
    import AppKit

    /// The platform's font type, for measuring text the shared views lay out by hand.
    typealias PlatformFont = NSFont
#else
    import UIKit

    typealias PlatformFont = UIFont
#endif

extension View {
    /// A small on/off option in a bar above a page ("Wrap lines"): a checkbox on the Mac, a
    /// button that stays pressed where there are no checkboxes.
    @ViewBuilder func optionToggleStyle() -> some View {
        #if os(macOS)
            toggleStyle(.checkbox)
        #else
            toggleStyle(.button)
        #endif
    }

    /// A text button in such a bar ("Expand all").
    @ViewBuilder func textButtonStyle() -> some View {
        #if os(macOS)
            buttonStyle(.link)
        #else
            buttonStyle(.borderless)
        #endif
    }
}

/// How tall rows of the shared views' own lists are: closer on the Mac, where a pointer picks
/// them, than under a finger.
enum RowMetrics {
    #if os(macOS)
        static let commitRowHeight: CGFloat = 24
        static let stackRowHeight: CGFloat = 20
    #else
        static let commitRowHeight: CGFloat = 36
        static let stackRowHeight: CGFloat = 30
    #endif
}

/// A spinner that appears only if loading takes a moment, so quick switches between items don't
/// flash it.
struct DelayedProgressView: View {
    @State private var isShown = false

    var body: some View {
        ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(isShown ? 1 : 0)
            .task {
                try? await Task.sleep(for: .milliseconds(250))
                withAnimation(.easeIn(duration: 0.15)) { isShown = true }
            }
    }
}

/// How sharing badges between the devices last went, in a word or two (`BadgeShare`).
struct BadgeShareStatus: View {
    let state: AppModel.BadgeShareState
    /// What a success is called here: "Published" on the Mac, "Read" on the iPad.
    let verb: String

    var body: some View {
        switch state {
        case .none:
            Text("Not yet").foregroundStyle(.secondary)
        case let .done(date):
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                let age = date.compactAge()
                Text(age == "now" ? "\(verb) just now" : "\(verb) \(age) ago").foregroundStyle(.secondary)
            }
        case let .failed(message):
            Text(message).foregroundStyle(.red).lineLimit(2)
        }
    }
}
