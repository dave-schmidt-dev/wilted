import AppKit
import Foundation
import SwiftUI
import WiltedDomain
import WiltedLibrary
import WiltedProducer
import XCTest
@testable import WiltedMac

@MainActor
extension WiltedMacEpisodeIdentityReviewTests {
    func testIdenticalMetadataAndGUIDsStillHaveUniqueSharedMemberLabels() async throws {
        typealias Candidate = WiltedMacEpisodeIdentityReviewModel.Candidate
        let members = ["first-123456", "second-123456", "third-789abc"].map {
            Candidate(id: $0, title: "Same Episode", rssGUID: "identical-guid",
                      publishedAt: created, durationSeconds: 3_600)
        }
        let labels = WiltedMacEpisodeIdentityReviewModel.memberLabels(for: members)
        XCTAssertEqual(Set(labels.values).count, 3)
        XCTAssertTrue(try XCTUnwrap(labels[members[0].id]).contains("#first-123456"))
        XCTAssertTrue(try XCTUnwrap(labels[members[1].id]).contains("#second-123456"))
        XCTAssertTrue(try XCTUnwrap(labels[members[2].id]).contains("#789abc"))

        let fixture = try await makeFixture("same-title-approval", sameTitle: true)
        let review = makeReview(fixture)
        await review.load()
        await review.selectPair(first: fixture.first.rawValue, second: fixture.second.rawValue,
                                representative: fixture.first.rawValue)
        await review.reviewPair()
        let firstLabel = review.pickerLabel(for: fixture.first.rawValue)
        let secondLabel = review.pickerLabel(for: fixture.second.rawValue)
        XCTAssertNotEqual(firstLabel, secondLabel)
        XCTAssertTrue(review.approvalSummary.contains("\(firstLabel): stored copy kept"))
        XCTAssertTrue(review.approvalSummary.contains("\(secondLabel): stored copy kept"))
    }

    func testEvidenceLabelsUsePlainOwnerWording() throws {
        let revision = try RevisionID(rawValue: "rev-abc")
        XCTAssertEqual(
            WiltedMacEpisodeIdentityReviewLayout.audioFingerprintLabel("sha256:abc"),
            "Audio fingerprint sha256:abc"
        )
        XCTAssertEqual(
            WiltedMacEpisodeIdentityReviewLayout.audioFingerprintLabel(nil),
            "No completed original download"
        )
        XCTAssertEqual(
            WiltedMacEpisodeIdentityReviewLayout.preparedVersionLabel(revision),
            "Prepared version rev-abc"
        )
        XCTAssertEqual(
            WiltedMacEpisodeIdentityReviewLayout.preparedVersionLabel(nil),
            "Not prepared"
        )
        let labels = [
            WiltedMacEpisodeIdentityReviewLayout.audioFingerprintLabel("sha256:abc"),
            WiltedMacEpisodeIdentityReviewLayout.audioFingerprintLabel(nil),
            WiltedMacEpisodeIdentityReviewLayout.preparedVersionLabel(revision),
            WiltedMacEpisodeIdentityReviewLayout.preparedVersionLabel(nil),
        ]
        for label in labels {
            XCTAssertFalse(label.localizedCaseInsensitiveContains("proof"), label)
            XCTAssertFalse(label.localizedCaseInsensitiveContains("revision"), label)
        }
    }

    // MARK: - Headless sheet rendering

    func testHeadlessSheetShowsLoadingEvidenceCapturedConsequencesAndBusyStatus() async throws {
        let fixture = try await makeFixture("render")
        try await seedKeptAndCompleted(fixture)
        let review = makeReview(fixture)

        let gate = ReviewGate()
        defer { Task { await gate.release() } }
        review.readHookForTesting = { await gate.pause() }
        let loading = Task { await review.load() }
        try await waitFor("review hook entered") { await gate.hasEntered }
        let loadingView = WiltedMacEpisodeIdentityReviewLayout(review: review, runRead: { _ in }, dismiss: {})
        let loadingText = try WiltedMacHeadless.recognizedText(loadingView, size: CGSize(width: 700, height: 900))
            .joined(separator: " ")
        XCTAssertTrue(loadingText.contains("Review Possible Duplicate"), loadingText)
        XCTAssertTrue(loadingText.localizedCaseInsensitiveContains("Checking this episode"), loadingText)
        review.readHookForTesting = nil
        await gate.release()
        await loading.value
        XCTAssertEqual(review.stage, .ready)

        // A delayed comparison shows the named busy status with the motif.
        let comparisonGate = ReviewGate()
        defer { Task { await comparisonGate.release() } }
        review.readHookForTesting = { await comparisonGate.pause() }
        let comparison = Task {
            await review.selectPair(
                first: fixture.first.rawValue, second: fixture.second.rawValue,
                representative: fixture.first.rawValue
            )
        }
        try await waitFor("review hook entered") { await comparisonGate.hasEntered }
        XCTAssertEqual(review.activity, .comparingPair)
        let busyView = WiltedMacEpisodeIdentityReviewLayout(review: review, runRead: { _ in }, dismiss: {})
        let busyText = try WiltedMacHeadless.recognizedText(busyView, size: CGSize(width: 700, height: 900))
            .joined(separator: " ")
        XCTAssertTrue(busyText.contains("Comparing the two episodes"), busyText)
        review.readHookForTesting = nil
        await comparisonGate.release()
        await comparison.value
        XCTAssertNil(review.activity)

        let evidenceView = WiltedMacEpisodeIdentityReviewLayout(review: review, runRead: { _ in }, dismiss: {})
        let evidenceText = try WiltedMacHeadless.recognizedText(evidenceView, size: CGSize(width: 700, height: 900))
            .joined(separator: " ")
        XCTAssertTrue(evidenceText.contains("Comparison evidence"), evidenceText)
        XCTAssertTrue(evidenceText.contains("Confirm Same Episode"), evidenceText)
        XCTAssertFalse(evidenceText.contains("proof"), evidenceText)
        XCTAssertFalse(evidenceText.contains("Prepared revision"), evidenceText)

        await review.reviewPair()
        XCTAssertNotNil(review.approvalPreview)
        // A tall owned render, so the Apply button below the long evidence is
        // actually inside the viewport instead of cropped.
        let previewView = WiltedMacEpisodeIdentityReviewLayout(review: review, runRead: { _ in }, dismiss: {})
        let previewText = try WiltedMacHeadless.recognizedText(previewView, size: CGSize(width: 700, height: 1_600))
            .joined(separator: " ")
        let bitmap = try WiltedMacHeadless.render(previewView, size: CGSize(width: 700, height: 1_600))
        let attachment = XCTAttachment(
            data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
            uniformTypeIdentifier: "public.png")
        attachment.name = "duplicate-review-captured-preview"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(previewText.contains("Apply Association"), previewText)
        XCTAssertTrue(previewText.contains("newest manual choice is Keep"), previewText)
        XCTAssertTrue(previewText.contains("holds queue slot 1 and is current"), previewText)
    }

    // MARK: - The Larder row path

    func testLarderRowAvailabilityOffersReviewOnlyForPodcastRows() async throws {
        let fixture = try await makeFixture("row-availability")
        let podcastRow = try XCTUnwrap(fixture.model.episodes.first { $0.id == fixture.first.rawValue })
        XCTAssertTrue(WiltedMacEpisodeIdentityReviewRequest.isAvailable(for: podcastRow))

        var withoutFeed = podcastRow
        withoutFeed.feedID = nil
        XCTAssertFalse(WiltedMacEpisodeIdentityReviewRequest.isAvailable(for: withoutFeed))

        var audiobook = podcastRow
        audiobook.audiobook = WiltedMacAudiobookDetails(
            author: "Reader", chapters: [], sourceFormat: "audio", volumeIndex: 1, volumeCount: 1
        )
        XCTAssertFalse(WiltedMacEpisodeIdentityReviewRequest.isAvailable(for: audiobook))
    }
}
