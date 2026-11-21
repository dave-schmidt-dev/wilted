import AppKit
import SwiftUI
import XCTest
@testable import WiltedMac
import WiltedDomain
import WiltedProducer

extension WiltedPixelSnapshotTests {
    func testSnapshotBaselinePreservesExistingBytesWhenMatchingInRecordMode() throws {
        let baseline = try baselineTestURL(for: "matching-baseline")
        let existingBitmap = makeSolidBitmap(width: 4, height: 2, red: 17, green: 34, blue: 51, alpha: 255)
        let existingBytes = try XCTUnwrap(existingBitmap.representation(using: .png, properties: [:]))
        try existingBytes.write(to: baseline, options: .atomic)

        let actualBitmap = makeSolidBitmap(width: 4, height: 2, red: 17, green: 34, blue: 51, alpha: 255)
        let actualBytes = try XCTUnwrap(actualBitmap.representation(using: .png, properties: [:]))
        let mutation = try applySnapshotRecordModeUpdate(
            baseline: baseline,
            actual: actualBitmap,
            actualPNG: actualBytes,
            forceRecord: false
        )

        XCTAssertFalse(mutation)
        XCTAssertEqual(try Data(contentsOf: baseline), existingBytes)
    }

    func testSnapshotBaselineReplacesWhenBaselineIsMissingOrUnreadableOrDifferentInRecordMode() throws {
        let missingBaseline = try baselineTestURL(for: "missing-baseline")
        let replacement = makeSolidBitmap(width: 3, height: 2, red: 12, green: 25, blue: 38, alpha: 255)
        let replacementBytes = try XCTUnwrap(replacement.representation(using: .png, properties: [:]))
        let missing = try applySnapshotRecordModeUpdate(
            baseline: missingBaseline,
            actual: replacement,
            actualPNG: replacementBytes,
            forceRecord: false
        )
        XCTAssertTrue(missing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: missingBaseline.path))

        let unreadableBaseline = try baselineTestURL(for: "unreadable-baseline")
        try Data("not-an-image".utf8).write(to: unreadableBaseline, options: .atomic)
        let unreadable = try applySnapshotRecordModeUpdate(
            baseline: unreadableBaseline,
            actual: replacement,
            actualPNG: replacementBytes,
            forceRecord: false
        )
        XCTAssertTrue(unreadable)

        let dimensionMismatchBaseline = try baselineTestURL(for: "dimension-mismatch-baseline")
        let smallBitmap = makeSolidBitmap(width: 2, height: 2, red: 12, green: 25, blue: 38, alpha: 255)
        let smallBytes = try XCTUnwrap(smallBitmap.representation(using: .png, properties: [:]))
        try smallBytes.write(to: dimensionMismatchBaseline, options: .atomic)
        let dimensionMismatch = try applySnapshotRecordModeUpdate(
            baseline: dimensionMismatchBaseline,
            actual: replacement,
            actualPNG: replacementBytes,
            forceRecord: false
        )
        XCTAssertTrue(dimensionMismatch)

        let materialMismatchBaseline = try baselineTestURL(for: "material-mismatch-baseline")
        let oldBitmap = makeSolidBitmap(width: 3, height: 2, red: 1, green: 2, blue: 3, alpha: 255)
        let oldBytes = try XCTUnwrap(oldBitmap.representation(using: .png, properties: [:]))
        try oldBytes.write(to: materialMismatchBaseline, options: .atomic)
        let materialMismatch = try applySnapshotRecordModeUpdate(
            baseline: materialMismatchBaseline,
            actual: replacement,
            actualPNG: replacementBytes,
            forceRecord: false
        )
        XCTAssertTrue(materialMismatch)
    }

    func testSnapshotBaselineReplacesWhenForceRecordEnabled() throws {
        let baseline = try baselineTestURL(for: "force-record-baseline")
        let existingBitmap = makeSolidBitmap(width: 2, height: 2, red: 12, green: 25, blue: 38, alpha: 255)
        let existingBytes = try XCTUnwrap(existingBitmap.representation(using: .png, properties: [:]))
        try existingBytes.write(to: baseline, options: .atomic)

        let actualBitmap = makeSolidBitmap(width: 2, height: 2, red: 13, green: 26, blue: 39, alpha: 255)
        let actualBytes = try XCTUnwrap(actualBitmap.representation(using: .png, properties: [:]))
        let mutation = try applySnapshotRecordModeUpdate(
            baseline: baseline,
            actual: actualBitmap,
            actualPNG: actualBytes,
            forceRecord: true
        )
        XCTAssertTrue(mutation)
        XCTAssertNotEqual(try Data(contentsOf: baseline), existingBytes)
    }

    func testForceRecordHasNoEffectWhenRecordModeIsDisabled() throws {
        let baseline = try baselineTestURL(for: "force-without-record")
        let existingBitmap = makeSolidBitmap(width: 2, height: 2, red: 12, green: 25, blue: 38, alpha: 255)
        let existingBytes = try XCTUnwrap(existingBitmap.representation(using: .png, properties: [:]))
        try existingBytes.write(to: baseline, options: .atomic)

        let actualBitmap = makeSolidBitmap(width: 2, height: 2, red: 13, green: 26, blue: 39, alpha: 255)
        let actualBytes = try XCTUnwrap(actualBitmap.representation(using: .png, properties: [:]))
        let mutation = try applySnapshotRecordModeUpdate(
            baseline: baseline,
            actual: actualBitmap,
            actualPNG: actualBytes,
            forceRecord: true,
            recordMode: false
        )
        XCTAssertFalse(mutation)
        XCTAssertEqual(try Data(contentsOf: baseline), existingBytes)
    }
}
