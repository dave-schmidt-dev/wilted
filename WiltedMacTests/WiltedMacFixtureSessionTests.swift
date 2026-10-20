import Foundation
import XCTest
@testable import WiltedMac

/// The Mac UI gate names its launch ledger with a `realpath` parent
/// (`/private/var/...`). Foundation's symlink resolution shortens that to
/// `/var/...`, which once made the fixture session refuse the gate's own
/// path and leave the run's launch count unproven.
@MainActor
final class WiltedMacFixtureSessionTests: XCTestCase {
    func testTheGatesCanonicalLedgerPathIsAcceptedAndAliasesAreRefused() throws {
        let parent = try canonicalDirectory()
        let ledger = parent + "/" + WiltedMacFixtureSession.ledgerFilename
        XCTAssertEqual(ledgerURL(ledger)?.path, ledger, "the gate's realpath ledger is accepted")

        let link = try canonicalDirectory("ledger-link") + "/alias"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: parent)
        XCTAssertNil(ledgerURL(link + "/" + WiltedMacFixtureSession.ledgerFilename), "a symlinked parent is refused")
        XCTAssertNil(ledgerURL(parent + "/other.jsonl"), "only the fixed ledger filename is accepted")
        XCTAssertNil(ledgerURL("relative/" + WiltedMacFixtureSession.ledgerFilename), "a relative path is refused")
        XCTAssertNil(ledgerURL(parent + "/missing/" + WiltedMacFixtureSession.ledgerFilename),
                     "a parent that does not exist is refused")
        XCTAssertNil(WiltedMacFixtureSession.ledgerForLaunch(environment: [:]), "no variable, no ledger")
    }

    private func ledgerURL(_ path: String) -> URL? {
        WiltedMacFixtureSession.ledgerForLaunch(environment: [WiltedMacFixtureSession.ledgerVariable: path])
    }

    /// An existing directory under this test's owned root, as realpath(3) names it.
    private func canonicalDirectory(_ name: String = "ledger") throws -> String {
        let directory = wiltedTemporaryDirectory("fixture-session").appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let resolved = try XCTUnwrap(realpath(directory.path, nil))
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
