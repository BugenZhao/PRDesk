import AppKit
import SwiftUI

/// The list filter as a native search field, for a toolbar item. (SwiftUI's `searchable` always
/// puts its field at the window's trailing edge, which is over the detail pane here.)
struct FilterField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String
    /// Bumped to move keyboard focus into the field.
    var focusRequest: Int
    /// Return, or Escape on an empty field: give focus back to the list.
    var onDone: () -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        // The action also fires for the clear button, which sends no text-change notification.
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchChanged(_:))
        context.coordinator.focusRequest = focusRequest
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            field.window?.makeFirstResponder(field)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView _: NSSearchField, context _: Context) -> CGSize? {
        CGSize(width: 220, height: proposal.height ?? 28)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: FilterField
        var focusRequest = 0

        init(_ parent: FilterField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        @objc func searchChanged(_ field: NSSearchField) {
            if parent.text != field.stringValue { parent.text = field.stringValue }
        }

        func control(_ control: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onDone()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                // The first Escape clears the text (the field's own behavior); the next leaves.
                if (control as? NSSearchField)?.stringValue.isEmpty == true {
                    parent.onDone()
                    return true
                }
                return false
            default:
                return false
            }
        }
    }
}
