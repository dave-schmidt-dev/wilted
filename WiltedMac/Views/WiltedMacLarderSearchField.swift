import AppKit
import SwiftUI

/// Owns the exact native toolbar editor and supplies its mounted responder capability.
struct WiltedMacLarderSearchField: NSViewRepresentable {
    @Binding var query: String
    let registerFocusAction: ((() -> Void)?) -> Void
    @Environment(\.wiltedTextScale) private var textScale

    func makeCoordinator() -> Coordinator {
        Coordinator(query: $query, registerFocusAction: registerFocusAction)
    }

    func makeNSView(context: Context) -> Field {
        let field = Field(frame: .zero)
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.placeholderString = ""
        field.setAccessibilityLabel("Search episodes")
        field.setAccessibilityIdentifier("wilted-larder-search")
        context.coordinator.connect(field)
        updateNSView(field, context: context)
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.query = $query
        context.coordinator.registerFocusAction = registerFocusAction
        field.font = .systemFont(ofSize: WiltedTheme.scaled(
            NSFont.preferredFont(forTextStyle: .body).pointSize, scale: textScale))
        context.coordinator.updateText(field)
    }

    static func dismantleNSView(_ field: Field, coordinator: Coordinator) {
        coordinator.disconnect(field)
    }

    /// Window attachment determines whether the registered native capability is usable.
    final class Field: NSTextField {
        var windowChanged: ((Field) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            windowChanged?(self)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var query: Binding<String>
        var registerFocusAction: ((() -> Void)?) -> Void
        private weak var field: Field?

        init(query: Binding<String>, registerFocusAction: @escaping ((() -> Void)?) -> Void) {
            self.query = query
            self.registerFocusAction = registerFocusAction
        }

        func connect(_ field: Field) {
            self.field = field
            field.delegate = self
            field.windowChanged = { [weak self] field in self?.windowChanged(field) }
            updateText(field)
        }

        func updateText(_ field: Field) {
            let value = query.wrappedValue
            // A native editing notification already updated the binding. Reassigning
            // unchanged text would reset the field editor selection on every keystroke.
            if field.stringValue != value { field.stringValue = value }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? Field, field === self.field else { return }
            let value = field.stringValue
            if query.wrappedValue != value { query.wrappedValue = value }
        }

        func disconnect(_ field: Field) {
            guard field === self.field else { return }
            field.windowChanged = nil
            field.delegate = nil
            self.field = nil
            registerFocusAction(nil)
            trace("larder-search-focus-unregistered")
        }

        private func windowChanged(_ field: Field) {
            guard field === self.field else { return }
            guard field.window != nil else {
                registerFocusAction(nil)
                trace("larder-search-focus-unregistered")
                return
            }
            registerFocusAction { [weak self, weak field] in
                guard let self, let field, field === self.field, let window = field.window else { return }
                self.trace("larder-search-focus-requested")
                let accepted = window.makeFirstResponder(field)
                WiltedMacAppDelegate.windowLifecycleTrace?.record(
                    "larder-search-focus-native-result", values: ["accepted": String(accepted)]
                )
                self.trace("larder-search-focus-state-snapshot")
            }
            trace("larder-search-focus-registered")
        }

        private func trace(_ event: String) {
            WiltedMacAppDelegate.windowLifecycleTrace?.recordWindowLifecycle(
                event, application: NSApplication.shared
            )
        }
    }
}
