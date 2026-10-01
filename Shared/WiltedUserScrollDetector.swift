import SwiftUI

#if os(macOS)
import AppKit

/// Reports a scroll the reader made, as opposed to one the app made.
///
/// `ScrollViewProxy.scrollTo` produces no wheel event, so a local monitor on
/// `.scrollWheel` over this view's frame sees only the trackpad or mouse, and
/// a press that lands on a scroller inside that frame sees the scrollbar. It
/// is a monitor rather than `onScrollPhaseChange` because that API is macOS
/// 15 and this target ships to 14.
struct WiltedUserScrollDetector: NSViewRepresentable {
    let onUserScroll: () -> Void

    func makeNSView(context: Context) -> DetectorView {
        let view = DetectorView()
        view.onUserScroll = onUserScroll
        return view
    }

    func updateNSView(_ view: DetectorView, context: Context) {
        view.onUserScroll = onUserScroll
    }

    static func dismantleNSView(_ view: DetectorView, coordinator: ()) {
        view.removeMonitor()
    }

    final class DetectorView: NSView {
        var onUserScroll: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                if event.type == .scrollWheel {
                    if event.scrollingDeltaY != 0 { self.onUserScroll?() }
                } else if window.contentView?.hitTest(event.locationInWindow) is NSScroller {
                    self.onUserScroll?()
                }
                return event
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        // Never a hit target: the transcript underneath keeps every click.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif
