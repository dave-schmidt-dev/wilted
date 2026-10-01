import AppKit
import SwiftUI

/// Sizes the window for a fixture launch, so each width band can be looked at
/// without dragging the window by hand: `--wilted-ui-fixture-window-width 900`.
/// Fixture launches only; a normal launch never reads the argument.
@MainActor
enum WiltedMacFixtureWindowWidth {
    static let argument = "--wilted-ui-fixture-window-width"

    /// The requested content width, or nil when the launch is not a fixture
    /// launch or names no usable number.
    static func width(arguments: [String]) -> CGFloat? {
        guard WiltedMacModel.isFixtureLaunch(arguments: arguments),
              let index = arguments.firstIndex(of: argument),
              arguments.indices.contains(index + 1),
              let value = Double(arguments[index + 1]), value.isFinite, value > 0
        else { return nil }
        return CGFloat(value)
    }
}

/// Applies the requested width once, when the window first appears.
struct WiltedMacFixtureWindowSizer: NSViewRepresentable {
    let width: CGFloat

    func makeNSView(context: Context) -> NSView { SizerView(width: width) }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class SizerView: NSView {
        let width: CGFloat
        private var applied = false

        init(width: CGFloat) {
            self.width = width
            super.init(frame: .zero)
        }

        @available(*, unavailable) required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !applied, let window else { return }
            applied = true
            // After the first layout pass, which would otherwise restore the
            // window's own size over this one.
            DispatchQueue.main.async {
                var size = window.contentLayoutRect.size
                size.width = self.width
                window.setContentSize(size)
                // And onto the screen: a restored window can hang off the
                // bottom, which hides the part of it a capture is meant to show.
                if let visible = window.screen?.visibleFrame {
                    var frame = window.frame
                    frame.size.height = min(frame.height, visible.height)
                    frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY - frame.height))
                    window.setFrame(frame, display: true)
                }
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
