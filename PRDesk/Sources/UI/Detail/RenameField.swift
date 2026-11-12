import AppKit
import SwiftUI

/// A title being renamed in place, as in Finder: a borderless wrapping field in the title's font
/// that takes keyboard focus with all its text selected as it appears. Return or clicking away
/// ends with `onEnd(true)`, Escape with `onEnd(false)`; Return and Escape give focus back to
/// whatever had it before.
struct RenameField: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont
    var onEnd: (_ commit: Bool) -> Void

    func makeNSView(context: Context) -> Field {
        let field = Field(string: text)
        field.font = font
        field.isBordered = false
        field.drawsBackground = false
        field.usesSingleLineMode = false
        field.lineBreakMode = .byWordWrapping
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.delegate = context.coordinator
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        if field.currentEditor() == nil, field.stringValue != text { field.stringValue = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: Field, context _: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, let cell = field.cell?.copy() as? NSCell else { return nil }
        cell.stringValue = text.isEmpty ? " " : text
        let height = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: ceil(height))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Field: NSTextField {
        /// What had keyboard focus before the field took it.
        weak var previousResponder: NSResponder?
        private var didFocus = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !didFocus else { return }
            didFocus = true
            // The window's field editor is about to be ours; remember the field it was editing.
            if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
                previousResponder = editor.delegate as? NSResponder
            } else {
                previousResponder = window.firstResponder
            }
            // Making a text field first responder selects all its text.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: RenameField
        private var isDone = false

        init(_ parent: RenameField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                end(control, commit: true, restoreFocus: true)
            case #selector(NSResponder.cancelOperation(_:)):
                end(control, commit: false, restoreFocus: true)
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                // A title is one line: ⌥Return adds nothing.
                break
            default:
                return false
            }
            return true
        }

        /// Clicking away (or anything else that takes focus) commits.
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            end(field, commit: true, restoreFocus: false)
        }

        private func end(_ control: NSControl, commit: Bool, restoreFocus: Bool) {
            guard !isDone else { return }
            isDone = true
            if commit { parent.text = control.stringValue }
            if restoreFocus, let field = control as? Field, let window = field.window {
                let previous = field.previousResponder
                let isStillThere = (previous as? NSView).map { $0.window === window } ?? false
                window.makeFirstResponder(isStillThere ? previous : nil)
            }
            parent.onEnd(commit)
        }
    }
}
