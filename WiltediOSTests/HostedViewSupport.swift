import SwiftUI
import UIKit
import XCTest

/// One element of a hosted SwiftUI view's accessibility tree, in window coordinates.
@MainActor
struct HostedElement {
    let identifier: String?
    let label: String?
    let traits: UIAccessibilityTraits
    let frame: CGRect
    fileprivate let object: NSObject

    var isButton: Bool { traits.contains(.button) }
    @discardableResult func activate() -> Bool { object.accessibilityActivate() }
    var customActionNames: [String] { (object.accessibilityCustomActions ?? []).map(\.name) }

    /// Runs the named VoiceOver custom action; false when the element has none by that name.
    @discardableResult func perform(customAction name: String) -> Bool {
        guard let action = object.accessibilityCustomActions?.first(where: { $0.name == name }) else { return false }
        if let handler = action.actionHandler { return handler(action) }
        if let target = action.target { _ = (target as AnyObject).perform(action.selector, with: action) }
        return true
    }

    /// What VoiceOver's swipe up and down do to an adjustable element (a slider or scrubber).
    func increment() { object.accessibilityIncrement() }
    func decrement() { object.accessibilityDecrement() }
    var isAdjustable: Bool { traits.contains(.adjustable) }

    var className: String { String(describing: type(of: object)) }
}

/// SwiftUI builds its accessibility tree only while an assistive technology is running, so a hosted test
/// switches on the same automation flag XCUITest does (simulator and test target only).
///
/// The switch takes effect through work queued on the main queue. An async test runs as a main-queue job,
/// so `RunLoop.run` inside it cannot drain that work: until the test yields once, every SwiftUI
/// `ScrollView` hosted afterwards exposes no children, however long it settles. Each hosted-test class
/// therefore calls `prepare()` from its async `setUp`.
enum HostedAccessibility {
    @MainActor static let enabled: Bool = {
        guard let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let symbol = dlsym(handle, "_AXSSetAutomationEnabled") else { return false }
        unsafeBitCast(symbol, to: (@convention(c) (Bool) -> Void).self)(true)
        return true
    }()

    @MainActor private(set) static var isPrepared = false

    /// Switches automation on and yields so the main queue applies it before any view is hosted.
    @MainActor static func prepare() async {
        guard !isPrepared else { return }
        _ = enabled
        try? await Task.sleep(nanoseconds: 100_000_000)
        isPrepared = true
    }
}

/// Hosts a SwiftUI view in a real window on the hosted-test simulator so its layout and accessibility
/// tree are the shipping ones; elements are found by their `accessibilityIdentifier`.
@MainActor
final class HostedView<Content: View> {
    let window: UIWindow
    let controller: UIHostingController<Content>

    init(_ content: Content, size: CGSize = CGSize(width: 390, height: 844), dark: Bool = false) {
        if !HostedAccessibility.isPrepared {
            XCTFail("call `await HostedAccessibility.prepare()` in setUp, or ScrollView content is missing from the tree")
        }
        _ = HostedAccessibility.enabled
        controller = UIHostingController(rootView: content)
        window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.rootViewController = controller
        window.makeKeyAndVisible()
        settle()
    }

    deinit {
        let window = window
        Task { @MainActor in window.isHidden = true }
    }

    /// Lets layout, `onAppear` and queued state updates run.
    func settle(_ seconds: TimeInterval = 0.4) {
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        window.layoutIfNeeded()
    }

    private static func identifier(of node: NSObject) -> String? {
        if let id = (node as? UIAccessibilityIdentification)?.accessibilityIdentifier, !id.isEmpty { return id }
        return node.responds(to: Selector(("accessibilityIdentifier")))
            ? node.value(forKey: "accessibilityIdentifier") as? String : nil
    }

    /// Every accessibility element under the window, depth first.
    func elements() -> [HostedElement] {
        var found: [HostedElement] = []
        func visit(_ node: NSObject) {
            if node.isAccessibilityElement {
                found.append(HostedElement(
                    identifier: Self.identifier(of: node),
                    label: node.accessibilityLabel, traits: node.accessibilityTraits,
                    frame: node.accessibilityFrame, object: node))
            }
            if let children = node.accessibilityElements as? [NSObject] {
                children.forEach(visit)
            } else if node.accessibilityElementCount() != NSNotFound, node.accessibilityElementCount() > 0 {
                for index in 0..<node.accessibilityElementCount() {
                    if let child = node.accessibilityElement(at: index) as? NSObject { visit(child) }
                }
            } else if let view = node as? UIView {
                view.subviews.forEach(visit)
            }
        }
        visit(window)
        return found
    }

    func element(_ identifier: String) -> HostedElement? { elements().first { $0.identifier == identifier } }
}
