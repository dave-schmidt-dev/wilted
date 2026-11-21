import AppKit
import SwiftUI
import XCTest
@testable import WiltedMac
import WiltedDomain
import WiltedProducer

enum WiltedSnapshotContract {
    static let stateCount = WiltedPreviewState.allCases.count
    static let variantCount = WiltedVisualVariant.matrix.count
    static let shellCount = 76
    static let expectedPixelBaselineCount = stateCount * variantCount + shellCount

    static var recordMode: Bool {
        ProcessInfo.processInfo.environment["WILTED_RECORD_SNAPSHOTS"] == "1"
    }

    static var forceRecordMode: Bool {
        ProcessInfo.processInfo.environment["WILTED_FORCE_RECORD_SNAPSHOTS"] == "1"
    }

    static func stateName(state: WiltedPreviewState, variant: WiltedVisualVariant) -> String {
        "state-\(state.id)-\(variant.id)"
    }

    static func shellName(kind: String, appearance: WiltedAppearance) -> String {
        "mac-shell-\(kind)-\(appearance.rawValue)"
    }
}
