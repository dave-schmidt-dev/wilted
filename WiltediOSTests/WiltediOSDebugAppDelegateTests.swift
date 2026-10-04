#if DEBUG
import ObjectiveC
import UIKit
import XCTest
@testable import WiltediOS

/// Drift guard: the DEBUG app delegate wraps `LibraryPushAppDelegate`, so any application-delegate
/// method the production delegate gains must be forwarded by the DEBUG one too, or DEBUG builds would
/// silently stop receiving that callback.
@MainActor
final class WiltediOSDebugAppDelegateTests: XCTestCase {
    func testDebugDelegateRespondsToEveryApplicationDelegateMethodTheProductionDelegateImplements() {
        let production = LibraryPushAppDelegate()
        let debug = WiltediOSDebugAppDelegate()
        let implemented = Self.applicationDelegateSelectors().filter { production.responds(to: $0) }

        XCTAssertFalse(implemented.isEmpty, "LibraryPushAppDelegate implements no UIApplicationDelegate method")
        for selector in implemented {
            XCTAssertTrue(debug.responds(to: selector), "WiltediOSDebugAppDelegate does not forward \(selector)")
        }
    }

    /// Every instance method, required or optional, declared by `UIApplicationDelegate`.
    private static func applicationDelegateSelectors() -> [Selector] {
        var selectors: [Selector] = []
        for isRequired in [true, false] {
            var count: UInt32 = 0
            guard let list = protocol_copyMethodDescriptionList(UIApplicationDelegate.self, isRequired, true, &count) else {
                continue
            }
            defer { free(list) }
            for index in 0..<Int(count) {
                if let name = list[index].name { selectors.append(name) }
            }
        }
        return selectors
    }
}
#endif
