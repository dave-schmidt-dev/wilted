import Foundation
import XCTest
@testable import WiltedMac

final class WiltedMacLibraryRuntimeSelectionTests: XCTestCase {
    func testRuntimeSelectionExhaustiveMatrix() {
        typealias Selection = WiltedMacLibraryRuntimeSelection

        let liveFacts = WiltedMacLibraryBuildFacts(compiledLive: true, hostsTests: false)
        let nonLive = WiltedMacLibraryBuildFacts(compiledLive: false, hostsTests: false)
        let liveTestHost = WiltedMacLibraryBuildFacts(compiledLive: true, hostsTests: true)

        let envOptions: [String?] = [nil, "", "0", "1", "off", "true"]
        let factsOptions: [WiltedMacLibraryBuildFacts] = [liveFacts, nonLive, liveTestHost]
        let fixtureOptions: [Bool] = [true, false]

        var testCount = 0

        for envValue in envOptions {
            let environment: [String: String]
            if let envValue {
                environment = ["WILTED_LIBRARY_SYNC": envValue]
            } else {
                environment = [:]
            }

            for facts in factsOptions {
                for fixture in fixtureOptions {
                    testCount += 1
                    let selection = Selection.select(environment: environment, facts: facts, fixtureMode: fixture)

                    // Assert engine is strictly libraryPublisher or none
                    XCTAssertTrue(
                        selection.engine == .libraryPublisher || selection.engine == .none,
                        "Engine must be libraryPublisher or none, was \(selection.engine)"
                    )

                    // Expected engine and reason matching former behavior where former .legacy is now .none
                    let expectedEngine: Selection.Engine
                    let expectedReason: Selection.Reason

                    if let envValue, !envValue.isEmpty {
                        if envValue == "1" {
                            expectedEngine = fixture ? .none : .libraryPublisher
                            expectedReason = fixture ? .fixture : .explicitOn
                        } else {
                            expectedEngine = .none
                            expectedReason = .explicitOff
                        }
                    } else {
                        if fixture {
                            expectedEngine = .none
                            expectedReason = .fixture
                        } else if facts.hostsTests {
                            expectedEngine = .none
                            expectedReason = .testHost
                        } else if !facts.compiledLive {
                            expectedEngine = .none
                            expectedReason = .nonLiveBuild
                        } else {
                            expectedEngine = .libraryPublisher
                            expectedReason = .liveDefault
                        }
                    }

                    XCTAssertEqual(
                        selection.engine, expectedEngine,
                        "Failed engine for env=\(String(describing: envValue)) facts=\(facts) fixture=\(fixture)"
                    )
                    XCTAssertEqual(
                        selection.reason, expectedReason,
                        "Failed reason for env=\(String(describing: envValue)) facts=\(facts) fixture=\(fixture)"
                    )
                    XCTAssertEqual(
                        selection,
                        Selection.select(environment: environment, facts: facts, fixtureMode: fixture),
                        "Relaunch with same inputs must produce identical selection"
                    )
                }
            }
        }

        XCTAssertEqual(testCount, 36, "The matrix must cover all 6 × 3 × 2 combinations")
    }

    func testAdmitsManagedTransport() {
        typealias Selection = WiltedMacLibraryRuntimeSelection
        let liveFacts = WiltedMacLibraryBuildFacts(compiledLive: true, hostsTests: false)

        let liveDefault = Selection.select(environment: [:], facts: liveFacts, fixtureMode: false)
        XCTAssertTrue(liveDefault.admits(managedTransport: true))
        XCTAssertFalse(liveDefault.admits(managedTransport: false), "the default never runs unmanaged")

        let explicitOn = Selection.select(environment: ["WILTED_LIBRARY_SYNC": "1"], facts: liveFacts, fixtureMode: false)
        XCTAssertTrue(explicitOn.admits(managedTransport: false), "an explicit 1 keeps today's unmanaged runs")
        XCTAssertTrue(explicitOn.admits(managedTransport: true))

        let explicitOff = Selection.select(environment: ["WILTED_LIBRARY_SYNC": "0"], facts: liveFacts, fixtureMode: false)
        XCTAssertFalse(explicitOff.admits(managedTransport: true))
        XCTAssertFalse(explicitOff.admits(managedTransport: false))
    }
}
