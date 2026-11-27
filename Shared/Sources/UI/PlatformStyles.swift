import SwiftUI

#if os(macOS)
    import AppKit

    /// The platform's font type, for measuring text the shared views lay out by hand.
    typealias PlatformFont = NSFont
#else
    import UIKit

    typealias PlatformFont = UIFont
#endif

/// A diff page's options at the end of its bar: wrapping, and every file open or shut, behind
/// one button, so the bar has room for what the diff is.
struct DiffOptions: View {
    @Binding var wrapLines: Bool
    let page: WebDocument

    var body: some View {
        #if os(macOS)
            Menu {
                Toggle("Wrap Lines", isOn: $wrapLines)
                Divider()
                Button("Expand All") { page.run("PRDesk.setAllFiles(true)") }
                Button("Collapse All") { page.run("PRDesk.setAllFiles(false)") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Diff Options")
        #else
            Menu {
                Toggle("Wrap Lines", systemImage: "arrow.turn.down.left", isOn: $wrapLines)
                Button("Expand All", systemImage: "rectangle.expand.vertical") { page.run("PRDesk.setAllFiles(true)") }
                Button("Collapse All", systemImage: "rectangle.compress.vertical") { page.run("PRDesk.setAllFiles(false)") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondaryText)
                    .frame(width: 36, height: 26)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Diff Options")
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
            Text("Not yet").foregroundStyle(.secondaryText)
        case let .done(date):
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                let age = date.compactAge()
                Text(age == "now" ? "\(verb) just now" : "\(verb) \(age) ago").foregroundStyle(.secondaryText)
            }
        case let .failed(message):
            Text(message).foregroundStyle(.red).lineLimit(2)
        }
    }
}

/// In Settings: whether this copy tells the viewer's other devices about its writes and hears of
/// theirs (`CloudHints`), and when it last did.
struct OtherDevicesRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        LabeledContent("Other Devices") {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Text(text).foregroundStyle(.secondaryText)
            }
        }
    }

    private var text: String {
        let status = model.hintsStatus
        guard status.isOn else { return "Not signed for iCloud" }
        var parts: [String] = []
        if let sent = status.lastSent { parts.append("sent \(Self.age(sent))") }
        if let received = status.lastReceived {
            let from = status.lastSender.flatMap { $0.isEmpty ? nil : " from the \($0)" } ?? ""
            parts.append("heard \(Self.age(received))\(from)")
        }
        return parts.isEmpty ? "Through iCloud" : parts.joined(separator: " · ").capitalizedFirst
    }

    private static func age(_ date: Date) -> String {
        let age = date.compactAge()
        return age == "now" ? "just now" : "\(age) ago"
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
