import AppKit
import XCTest
@testable import WiltedMac

/// The native accessibility readers the headless journeys share. SwiftUI vends some AXLabel and
/// AXTitle values as attributed strings; reading one through its declared `String` type raised an
/// Objective-C exception that aborted the Mac test host mid-suite.
@MainActor
final class WiltedMacAccessibilityTextTests: XCTestCase {
    func testAttributedLabelAndTitleReadAsTheirPlainText() {
        let node = AttributedTextNode()
        XCTAssertEqual(WiltedMacHeadless.accessibilityLabel(of: node), "Kitchen Garden, Manual playlist")
        XCTAssertEqual(WiltedMacHeadless.accessibilityTitle(of: node), "Kitchen Garden")
    }

    func testPlainLabelReadsUnchangedAndMissingAttributesReadNil() {
        let button = NSButton(title: "Known AppKit control", target: nil, action: nil)
        button.setAccessibilityLabel("Known AppKit control")
        XCTAssertEqual(WiltedMacHeadless.accessibilityLabel(of: button), "Known AppKit control")
        XCTAssertNil(WiltedMacHeadless.accessibilityLabel(of: NSObject()))
        XCTAssertNil(WiltedMacHeadless.accessibilityLabel(of: "not an accessibility node"))
    }
}

/// Answers the AXLabel and AXTitle selectors with attributed strings, as SwiftUI nodes can.
private final class AttributedTextNode: NSObject {
    @objc func accessibilityLabel() -> NSAttributedString {
        NSAttributedString(string: "Kitchen Garden, Manual playlist")
    }

    @objc func accessibilityTitle() -> NSAttributedString {
        NSAttributedString(string: "Kitchen Garden")
    }
}
