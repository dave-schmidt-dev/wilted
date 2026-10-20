import AppKit
import SwiftUI

/// Sizes the window for a fixture launch, so each width band can be looked at
/// without dragging the window by hand: `--wilted-ui-fixture-window-width 900`.
/// Fixture launches only; a normal launch never reads the argument.
@MainActor
enum WiltedMacFixtureWindowWidth {
    static let argument = "--wilted-ui-fixture-window-width"

    /// Explicit fixture viewport height; the initial scene can report zero content height.
    static let minimumFixtureContentHeight: CGFloat = 640

    /// Keeps a fixture usable through the first layout pass while preserving a taller window.
    static func contentSize(current: CGSize, requestedWidth: CGFloat, minimumHeight: CGFloat) -> CGSize {
        CGSize(width: requestedWidth, height: max(minimumFixtureContentHeight, max(current.height, minimumHeight)))
    }

    /// Fits the resized fixture frame inside its intended screen's visible area.
    static func fittedFrame(_ proposed: CGRect, inside visible: CGRect) -> CGRect {
        var frame = proposed
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
        frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY - frame.height))
        return frame
    }

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
                let size = WiltedMacFixtureWindowWidth.contentSize(
                    current: window.contentLayoutRect.size, requestedWidth: self.width,
                    minimumHeight: window.contentMinSize.height
                )
                window.setContentSize(size)
                // Keep the resized fixture wholly on the intended primary screen,
                // including when a wider fixture reuses the same window's origin.
                if let visible = NSScreen.screens.first?.visibleFrame {
                    window.setFrame(WiltedMacFixtureWindowWidth.fittedFrame(window.frame, inside: visible), display: true)
                }
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
