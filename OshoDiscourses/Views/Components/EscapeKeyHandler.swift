import SwiftUI
import UIKit

/// Escape and ⌘. for the full-window player, which never otherwise holds first
/// responder, so neither a button shortcut nor a menu key equivalent reaches it.
struct EscapeKeyHandler: UIViewRepresentable {
    let action: () -> Void

    func makeUIView(context: Context) -> KeyView {
        let view = KeyView()
        view.action = action
        return view
    }

    func updateUIView(_ view: KeyView, context: Context) {
        view.action = action
    }

    final class KeyView: UIView {
        var action: (() -> Void)?

        override var canBecomeFirstResponder: Bool { true }

        override var keyCommands: [UIKeyCommand]? {
            let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escapePressed))
            escape.wantsPriorityOverSystemBehavior = true
            // ⌘. is the other standard cancel on iPad and Mac.
            let commandPeriod = UIKeyCommand(input: ".", modifierFlags: .command, action: #selector(escapePressed))
            return [escape, commandPeriod]
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            // Deferred until the presentation finishes attaching the view.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                self.becomeFirstResponder()
            }
        }

        @objc private func escapePressed() {
            action?()
        }
    }
}
