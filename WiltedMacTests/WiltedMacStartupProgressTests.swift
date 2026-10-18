import Foundation
import AppKit
import SwiftUI
import XCTest
import WiltedDomain
@_spi(Testing) import WiltedProducer
@testable import WiltedMac

@MainActor
final class WiltedMacStartupProgressTests: XCTestCase {
    func testNativeLoaderUsesRealReadinessAndPreservesActionableFailure() async throws {
        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("motif-startup"),
                                   storeBootstrap: { try LocalLibraryStore(url: $0) },
                                   preferences: WiltedMacTestPreferences.ephemeral())
        XCTAssertNotNil(model.startupState.loadingStep)
        let loading = try WiltedMacHeadless.render(
            WiltedMacRootView(model: model),
            size: CGSize(width: 760, height: 420))
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        XCTAssertEqual(model.startupState, .ready, "the loader has no artificial minimum duration")
        let ready = try WiltedMacHeadless.render(WiltedMacRootView(model: model), size: CGSize(width: 760, height: 420))
        XCTAssertNotEqual(loading.representation(using: .png, properties: [:]), ready.representation(using: .png, properties: [:]))
        model.startupState = .failed(WiltedMacStartupFailure(message: "Fixture library needs recovery", detail: nil,
                                                           recoveryCopyURL: nil, canRetry: true))
        let recovery = try WiltedMacHeadless.render(WiltedMacRootView(model: model), size: CGSize(width: 760, height: 420))
        XCTAssertGreaterThan(WiltedMacHeadless.distinctColorCount(in: recovery), 8)
        XCTAssertNotEqual(loading.representation(using: .png, properties: [:]), recovery.representation(using: .png, properties: [:]))
        for (name, image) in [("startup-loading", loading), ("startup-ready", ready), ("startup-recovery", recovery)] {
            let attachment = XCTAttachment(data: try XCTUnwrap(image.representation(using: .png, properties: [:])),
                                           uniformTypeIdentifier: "public.png")
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WiltedMac/Views/WiltedMacRootView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(source.contains("case .loading:\n                startupLoading"))
        XCTAssertTrue(source.contains("case .ready:\n                readyRoot"))
        XCTAssertTrue(source.contains("WiltedLoadingMotif()"))
        XCTAssertFalse(source.contains("startupMotifProgress"), "counts never drive an indeterminate dash")
        XCTAssertEqual(WiltedMacHeadless.occurrences(of: "Text(model.startupStepLabel)", in: source), 1,
                       "the phase/count text supplies one accessible status")
        XCTAssertTrue(source.contains("startupRecovery(failure)"))
        XCTAssertTrue(source.contains("model.retryStoreBootstrap()"))
    }

    func testCountedRecoveryRendersActualCountsBesideIndeterminateArt() async throws {
        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("motif-counts"),
                                   storeBootstrap: { try LocalLibraryStore(url: $0) },
                                   preferences: WiltedMacTestPreferences.ephemeral())
        addTeardownBlock { await model.close() }
        model.startupState = .loading(attempt: 1, step: .recoveringWork(
            action: "closing interrupted requests", done: 2, total: 5))
        XCTAssertEqual(model.startupStepLabel, "Recovering 2 of 5 requests: closing interrupted requests.")
        let text = try WiltedMacHeadless.recognizedText(WiltedMacRootView(model: model),
                                                       size: CGSize(width: 760, height: 420)).joined(separator: " ")
        XCTAssertTrue(text.contains("2 of 5 requests"), text)
    }

    func testSeededRecoveryEmitsCountedProgressForEveryRepairKind() async throws {
        let directory = wiltedTemporaryDirectory("startup-progress")
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                let now = Timestamp(Date(timeIntervalSince1970: 1_700_020_000))
                let orphan = try ItemID(rawValue: "item-" + String(repeating: "a", count: 64))
                try await store.save(download: PodcastDownload(
                    episodeID: orphan, status: .failed, updatedAt: now, failureKind: .retryable
                ))

                var interrupted = try await store.issueWorkTicket(
                    kind: .podcastPreparation, subjectID: "interrupted", requestedAt: now
                )
                interrupted.state = .running
                try await store.upsertWorkTicket(interrupted)
                _ = try await store.issueWorkTicket(
                    kind: .articlePreparation, subjectID: "duplicate-a", resolvedItemID: "canonical",
                    requestedAt: now
                )
                _ = try await store.issueWorkTicket(
                    kind: .articlePreparation, subjectID: "duplicate-b", resolvedItemID: "canonical",
                    requestedAt: now
                )
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        var steps: [WiltedMacStartupStep] = []
        model.startupStepObserverForTesting = { steps.append($0) }

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        await Task.yield()
        await Task.yield()

        let recovery = steps.compactMap { step -> (String, Int, Int)? in
            guard case let .recoveringWork(action, done, total, _) = step else { return nil }
            return (action, done, total)
        }
        XCTAssertTrue(recovery.contains { $0.0 == "adopting downloads" && $0.1 == 1 && $0.2 == 1 })
        XCTAssertTrue(recovery.contains { $0.0 == "closing interrupted requests" && $0.1 == 1 && $0.2 == 1 })
        XCTAssertTrue(recovery.contains { $0.0 == "collapsing duplicate requests" && $0.1 == 1 && $0.2 == 1 })
        XCTAssertEqual(model.startupState, .ready)
    }

    func testTicketFailureRemainsVisibleWhileOtherTicketsRecover() async throws {
        let directory = wiltedTemporaryDirectory("startup-progress-error")
        LocalLibraryStore.workTicketReconciliationFailureForTesting = { step, subjectID in
            step == .adoptingDownloads && subjectID == "item-" + String(repeating: "b", count: 64)
        }
        defer { LocalLibraryStore.workTicketReconciliationFailureForTesting = nil }

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                let now = Timestamp(Date(timeIntervalSince1970: 1_700_020_100))
                for character in ["b", "c"] {
                    let itemID = try ItemID(rawValue: "item-" + String(repeating: character, count: 64))
                    try await store.save(download: PodcastDownload(
                        episodeID: itemID, status: .failed, updatedAt: now, failureKind: .retryable
                    ))
                }
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        var steps: [WiltedMacStartupStep] = []
        model.startupStepObserverForTesting = { steps.append($0) }

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        await Task.yield()
        await Task.yield()

        XCTAssertTrue(steps.contains { step in
            guard case let .recoveringWork(_, _, _, errors) = step else { return false }
            return errors.contains { $0.contains("item-" + String(repeating: "b", count: 64)) }
        })
        XCTAssertTrue(steps.contains { step in
            guard case let .recoveringWork(action, done, total, _) = step else { return false }
            return action == "adopting downloads" && done == 2 && total == 2
        })
        XCTAssertEqual(model.startupState, .ready)
    }

    func testRecoveryProgressCannotReplaceLoadingLibrary() async throws {
        let directory = wiltedTemporaryDirectory("startup-progress-order")
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                let itemID = try ItemID(rawValue: "item-" + String(repeating: "d", count: 64))
                try await store.save(download: PodcastDownload(
                    episodeID: itemID, status: .failed, updatedAt: Timestamp(Date()),
                    failureKind: .retryable
                ))
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        var steps: [WiltedMacStartupStep] = []
        model.startupStepObserverForTesting = { steps.append($0) }

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        await Task.yield()
        await Task.yield()

        guard let loadingIndex = steps.firstIndex(of: .loadingLibrary) else {
            return XCTFail("bootstrap never announced the library-loading step")
        }
        XCTAssertFalse(steps.dropFirst(loadingIndex + 1).contains { step in
            if case .recoveringWork = step { return true }
            return false
        })
        XCTAssertEqual(model.startupState, .ready)
    }
}
