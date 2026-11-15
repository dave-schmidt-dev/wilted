import Foundation
import WiltedCloudKit
import WiltedDomain
import WiltedLibrary
import WiltedProducer
import XCTest
@testable import WiltedMac

final class WiltedMacActivitySummaryTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1700000000)

    private func mockTime(_ date: Date) -> String {
        "4:31 PM"
    }

    private func makeInput(
        headline: String = "All changes in iCloud",
        tone: WiltedStatusTone = .neutral,
        deviceChangesRead: String = "Today at 2:15 PM",
        media: WiltedMacMediaActivity? = nil,
        uploadingTitle: String? = nil,
        requestLine: String? = nil,
        directDownloadsOn: Bool = true,
        preparing: Int = 0,
        preparationWaiting: Int = 0,
        automationStatus: String = "Idle"
    ) -> WiltedMacActivitySummary.Input {
        WiltedMacActivitySummary.Input(
            headline: headline,
            tone: tone,
            deviceChangesRead: deviceChangesRead,
            media: media,
            uploadingTitle: uploadingTitle,
            requestLine: requestLine,
            directDownloadsOn: directDownloadsOn,
            preparing: preparing,
            preparationWaiting: preparationWaiting,
            automationStatus: automationStatus
        )
    }

    // 1. Group titles and row order
    func testGroupTitlesAndRowOrder() {
        let input = makeInput(
            media: WiltedMacMediaActivity(preupload: nil, requestsQueued: 0),
            requestLine: "iCloud: 5 req/min"
        )
        let summary = WiltedMacActivitySummary.make(input, time: mockTime)

        XCTAssertEqual(summary.groups.count, 2)
        XCTAssertEqual(summary.groups[0].title, "iCloud")
        XCTAssertEqual(summary.groups[0].rows.map(\.id), [
            "library",
            "device-changes",
            "uploaded-ahead",
            "requests",
            "rate",
            "direct"
        ])

        XCTAssertEqual(summary.groups[1].title, "This Mac")
        XCTAssertEqual(summary.groups[1].rows.map(\.id), [
            "preparation",
            "automation"
        ])
    }

    // 2. Uploaded ahead: Waiting for library sync when media is nil or preupload is nil
    func testUploadedAheadWaitingForLibrarySync() {
        let inputNilMedia = makeInput(media: nil)
        let summary1 = WiltedMacActivitySummary.make(inputNilMedia, time: mockTime)
        let row1 = summary1.groups[0].rows.first { $0.id == "uploaded-ahead" }
        XCTAssertEqual(row1?.value, "Waiting for library sync")
        XCTAssertEqual(row1?.tone, .neutral)

        let inputNilPreupload = makeInput(media: WiltedMacMediaActivity(preupload: nil, requestsQueued: 0))
        let summary2 = WiltedMacActivitySummary.make(inputNilPreupload, time: mockTime)
        let row2 = summary2.groups[0].rows.first { $0.id == "uploaded-ahead" }
        XCTAssertEqual(row2?.value, "Waiting for library sync")
        XCTAssertEqual(row2?.tone, .neutral)
    }

    // 3. Uploaded ahead: Stopped until library sync restarts (preupload.isStopped)
    func testUploadedAheadStoppedUntilLibrarySyncRestarts() {
        let preupload = WiltedMacMediaActivity.Preupload(
            targetCount: 10,
            uploadedCount: 5,
            isStopped: true
        )
        let input = makeInput(media: WiltedMacMediaActivity(preupload: preupload, requestsQueued: 0))
        let summary = WiltedMacActivitySummary.make(input, time: mockTime)
        let row = summary.groups[0].rows.first { $0.id == "uploaded-ahead" }
        XCTAssertEqual(row?.value, "Stopped until library sync restarts")
        XCTAssertEqual(row?.tone, .neutral)
    }

    // 4. Uploaded ahead: Paused until TIME: iCloud storage is full (caution tone)
    func testUploadedAheadPausedStorageFullCarriesCautionTone() {
        let preupload = WiltedMacMediaActivity.Preupload(
            targetCount: 10,
            uploadedCount: 3,
            pausedUntil: fixedDate,
            pauseReason: .storageFull
        )
        let input = makeInput(media: WiltedMacMediaActivity(preupload: preupload, requestsQueued: 0))
        let summary = WiltedMacActivitySummary.make(input) { _ in "10:22 PM" }
        let row = summary.groups[0].rows.first { $0.id == "uploaded-ahead" }
        XCTAssertEqual(row?.value, "Paused until 10:22 PM: iCloud storage is full")
        XCTAssertEqual(row?.tone, .caution)
    }

    // 5. Uploaded ahead: Retrying at TIME (preupload.pauseReason == .retrying)
    func testUploadedAheadRetryingAtTime() {
        let preupload = WiltedMacMediaActivity.Preupload(
            targetCount: 10,
            uploadedCount: 3,
            pausedUntil: fixedDate,
            pauseReason: .retrying
        )
        let input = makeInput(media: WiltedMacMediaActivity(preupload: preupload, requestsQueued: 0))
        let summary = WiltedMacActivitySummary.make(input) { _ in "4:31 PM" }
        let row = summary.groups[0].rows.first { $0.id == "uploaded-ahead" }
        XCTAssertEqual(row?.value, "Retrying at 4:31 PM")
        XCTAssertEqual(row?.tone, .neutral)
    }

    // 6. Uploaded ahead: Sending K of M: Title (uploadingID present with non-nil title)
    func testUploadedAheadSendingWithTitle() {
        let preupload = WiltedMacMediaActivity.Preupload(
            targetCount: 10,
            uploadedCount: 3,
            uploadingID: "ep-4"
        )
        let input = makeInput(
            media: WiltedMacMediaActivity(preupload: preupload, requestsQueued: 0),
            uploadingTitle: "Episode Four"
        )
        let summary = WiltedMacActivitySummary.make(input, time: mockTime)
        let row = summary.groups[0].rows.first { $0.id == "uploaded-ahead" }
        XCTAssertEqual(row?.value, "Sending 4 of 10: Episode Four")
        XCTAssertEqual(row?.tone, .neutral)
    }

    // 7. Uploaded ahead: Sending K of M without title fallback
    func testUploadedAheadSendingWithoutTitleFallback() {
        let preupload = WiltedMacMediaActivity.Preupload(
            targetCount: 10,
            uploadedCount: 0,
            uploadingID: "ep-1"
        )
        let input = makeInput(
            media: WiltedMacMediaActivity(preupload: preupload, requestsQueued: 0),
            uploadingTitle: nil
        )
        let summary = WiltedMacActivitySummary.make(input, time: mockTime)
        let row = summary.groups[0].rows.first { $0.id == "uploaded-ahead" }
        XCTAssertEqual(row?.value, "Sending 1 of 10")
        XCTAssertEqual(row?.tone, .neutral)
    }

    // 8. Uploaded ahead: Nothing to upload (targetCount == 0)
    func testUploadedAheadNothingToUpload() {
        let preupload = WiltedMacMediaActivity.Preupload(
            targetCount: 0,
            uploadedCount: 0
        )
        let input = makeInput(media: WiltedMacMediaActivity(preupload: preupload, requestsQueued: 0))
        let summary = WiltedMacActivitySummary.make(input, time: mockTime)
        let row = summary.groups[0].rows.first { $0.id == "uploaded-ahead" }
        XCTAssertEqual(row?.value, "Nothing to upload")
        XCTAssertEqual(row?.tone, .neutral)
    }

    // 9. Uploaded ahead: N of M in iCloud (normal completed or idle state)
    func testUploadedAheadNOfMInICloud() {
        let preupload = WiltedMacMediaActivity.Preupload(
            targetCount: 10,
            uploadedCount: 7
        )
        let input = makeInput(media: WiltedMacMediaActivity(preupload: preupload, requestsQueued: 0))
        let summary = WiltedMacActivitySummary.make(input, time: mockTime)
        let row = summary.groups[0].rows.first { $0.id == "uploaded-ahead" }
        XCTAssertEqual(row?.value, "7 of 10 in iCloud")
        XCTAssertEqual(row?.tone, .neutral)
    }

    // 10. Uploaded ahead: Set aside count appended (", N set aside")
    func testUploadedAheadSetAsideAppended() {
        let preupload = WiltedMacMediaActivity.Preupload(
            targetCount: 10,
            uploadedCount: 7,
            setAsideCount: 2
        )
        let input = makeInput(media: WiltedMacMediaActivity(preupload: preupload, requestsQueued: 0))
        let summary = WiltedMacActivitySummary.make(input, time: mockTime)
        let row = summary.groups[0].rows.first { $0.id == "uploaded-ahead" }
        XCTAssertEqual(row?.value, "7 of 10 in iCloud, 2 set aside")
    }

    // 11. Uploaded ahead: Precedence check (isStopped outranks storageFull pause, uploadingID, and targetCount)
    func testUploadedAheadPrecedence() {
        // isStopped outranks pausedUntil with storageFull
        let stoppedAndPaused = WiltedMacMediaActivity.Preupload(
            targetCount: 10,
            uploadedCount: 2,
            uploadingID: "ep-3",
            pausedUntil: fixedDate,
            pauseReason: .storageFull,
            setAsideCount: 1,
            isStopped: true
        )
        let input1 = makeInput(
            media: WiltedMacMediaActivity(preupload: stoppedAndPaused, requestsQueued: 0),
            uploadingTitle: "Ep 3"
        )
        let summary1 = WiltedMacActivitySummary.make(input1, time: mockTime)
        let row1 = summary1.groups[0].rows.first { $0.id == "uploaded-ahead" }
        XCTAssertEqual(row1?.value, "Stopped until library sync restarts, 1 set aside")
        XCTAssertEqual(row1?.tone, .neutral)

        // pausedUntil with storageFull outranks uploadingID
        let pausedAndUploading = WiltedMacMediaActivity.Preupload(
            targetCount: 10,
            uploadedCount: 2,
            uploadingID: "ep-3",
            pausedUntil: fixedDate,
            pauseReason: .storageFull,
            setAsideCount: 0,
            isStopped: false
        )
        let input2 = makeInput(
            media: WiltedMacMediaActivity(preupload: pausedAndUploading, requestsQueued: 0),
            uploadingTitle: "Ep 3"
        )
        let summary2 = WiltedMacActivitySummary.make(input2, time: mockTime)
        let row2 = summary2.groups[0].rows.first { $0.id == "uploaded-ahead" }
        XCTAssertEqual(row2?.value, "Paused until 4:31 PM: iCloud storage is full")
        XCTAssertEqual(row2?.tone, .caution)

        // uploadingID outranks targetCount == 0 (if uploadingID is set)
        let uploadingZeroTargets = WiltedMacMediaActivity.Preupload(
            targetCount: 0,
            uploadedCount: 0,
            uploadingID: "ep-1",
            isStopped: false
        )
        let input3 = makeInput(
            media: WiltedMacMediaActivity(preupload: uploadingZeroTargets, requestsQueued: 0),
            uploadingTitle: "Quick Track"
        )
        let summary3 = WiltedMacActivitySummary.make(input3, time: mockTime)
        let row3 = summary3.groups[0].rows.first { $0.id == "uploaded-ahead" }
        XCTAssertEqual(row3?.value, "Sending 1 of 0: Quick Track")
    }

    // 12. Rate row: present without "iCloud: " prefix, and omitted when requestLine is nil
    func testRequestsRateRowPresenceAndOmission() {
        let inputWithPrefix = makeInput(requestLine: "iCloud: 12 ops/min, 0 throttled")
        let summary1 = WiltedMacActivitySummary.make(inputWithPrefix, time: mockTime)
        let row1 = summary1.groups[0].rows.first { $0.id == "rate" }
        XCTAssertNotNil(row1)
        XCTAssertEqual(row1?.label, "Requests")
        XCTAssertEqual(row1?.value, "12 ops/min, 0 throttled")

        let inputWithoutPrefix = makeInput(requestLine: "12 ops/min")
        let summary2 = WiltedMacActivitySummary.make(inputWithoutPrefix, time: mockTime)
        let row2 = summary2.groups[0].rows.first { $0.id == "rate" }
        XCTAssertEqual(row2?.value, "12 ops/min")

        let inputNil = makeInput(requestLine: nil)
        let summary3 = WiltedMacActivitySummary.make(inputNil, time: mockTime)
        XCTAssertFalse(summary3.groups[0].rows.contains { $0.id == "rate" })
    }

    // 13. iPhone requests: None queued vs N queued
    func testIPhoneRequestsRow() {
        let inputZero = makeInput(media: WiltedMacMediaActivity(preupload: nil, requestsQueued: 0))
        let summaryZero = WiltedMacActivitySummary.make(inputZero, time: mockTime)
        let rowZero = summaryZero.groups[0].rows.first { $0.id == "requests" }
        XCTAssertEqual(rowZero?.value, "None queued")

        let inputMultiple = makeInput(media: WiltedMacMediaActivity(preupload: nil, requestsQueued: 4))
        let summaryMultiple = WiltedMacActivitySummary.make(inputMultiple, time: mockTime)
        let rowMultiple = summaryMultiple.groups[0].rows.first { $0.id == "requests" }
        XCTAssertEqual(rowMultiple?.value, "4 queued")
    }

    // 14. Direct downloads: On vs Off
    func testDirectDownloadsRow() {
        let inputOn = makeInput(directDownloadsOn: true)
        let summaryOn = WiltedMacActivitySummary.make(inputOn, time: mockTime)
        let rowOn = summaryOn.groups[0].rows.first { $0.id == "direct" }
        XCTAssertEqual(rowOn?.value, "On")

        let inputOff = makeInput(directDownloadsOn: false)
        let summaryOff = WiltedMacActivitySummary.make(inputOff, time: mockTime)
        let rowOff = summaryOff.groups[0].rows.first { $0.id == "direct" }
        XCTAssertEqual(rowOff?.value, "Off")
    }

    // 15. Preparation: Idle, N preparing, N preparing, W waiting
    func testPreparationRow() {
        let inputIdle = makeInput(preparing: 0, preparationWaiting: 0)
        let summaryIdle = WiltedMacActivitySummary.make(inputIdle, time: mockTime)
        let rowIdle = summaryIdle.groups[1].rows.first { $0.id == "preparation" }
        XCTAssertEqual(rowIdle?.value, "Idle")

        let inputPreparing = makeInput(preparing: 1, preparationWaiting: 0)
        let summaryPrep = WiltedMacActivitySummary.make(inputPreparing, time: mockTime)
        let rowPrep = summaryPrep.groups[1].rows.first { $0.id == "preparation" }
        XCTAssertEqual(rowPrep?.value, "1 preparing")

        let inputWaiting = makeInput(preparing: 2, preparationWaiting: 3)
        let summaryWait = WiltedMacActivitySummary.make(inputWaiting, time: mockTime)
        let rowWait = summaryWait.groups[1].rows.first { $0.id == "preparation" }
        XCTAssertEqual(rowWait?.value, "2 preparing, 3 waiting")

        let waitingOnly = WiltedMacActivitySummary.make(makeInput(preparing: 0, preparationWaiting: 2), time: mockTime)
        XCTAssertEqual(waitingOnly.groups[1].rows.first { $0.id == "preparation" }?.value, "2 waiting")
    }

    // 16. That no row other than library carries sync failure text
    func testNoRowOtherThanLibraryCarriesSyncFailureText() {
        let failureHeadline = "Failed to sync library: Network connection offline"
        let input = makeInput(
            headline: failureHeadline,
            tone: .failure,
            media: WiltedMacMediaActivity(
                preupload: WiltedMacMediaActivity.Preupload(targetCount: 10, uploadedCount: 10),
                requestsQueued: 0
            ),
            requestLine: "5 req/min",
            automationStatus: "Periodic sync active"
        )
        let summary = WiltedMacActivitySummary.make(input, time: mockTime)

        let libraryRow = summary.groups[0].rows.first { $0.id == "library" }
        XCTAssertEqual(libraryRow?.value, failureHeadline)
        XCTAssertEqual(libraryRow?.tone, .failure)

        let allOtherRows = summary.groups.flatMap(\.rows).filter { $0.id != "library" }
        for row in allOtherRows {
            XCTAssertFalse(
                row.value.localizedCaseInsensitiveContains("Failed to sync library"),
                "Row \(row.id) contains sync failure text: \(row.value)"
            )
            XCTAssertNotEqual(row.tone, .failure, "Row \(row.id) carries failure tone")
        }
    }

    // 17. Headless model with media set to ten targets all uploaded returns "10 of 10 in iCloud"
    @MainActor
    func testHeadlessModelAllUploadedReturns10Of10InICloud() async {
        let model = await WiltedMacHeadless.model(self, ["--wilted-ui-fixture-ready"])
        model.librarySyncActivity.media = WiltedMacMediaActivity(
            preupload: WiltedMacMediaActivity.Preupload(
                targetCount: 10,
                uploadedCount: 10
            ),
            requestsQueued: 0
        )

        let summary = model.activitySummary
        let uploadedRow = summary.groups
            .first { $0.title == "iCloud" }?
            .rows
            .first { $0.id == "uploaded-ahead" }

        XCTAssertEqual(uploadedRow?.value, "10 of 10 in iCloud")
        XCTAssertEqual(uploadedRow?.tone, .neutral)
    }

    // 18. The model names the entry being sent by its Larder title
    @MainActor
    func testHeadlessModelNamesTheEpisodeBeingSent() async throws {
        let model = await WiltedMacHeadless.model(self, ["--wilted-ui-fixture-ready"])
        let episode = WiltedMacEpisode(
            id: "activity-sending", title: "The episode being sent", feedTitle: "A show", summary: "",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_699_000_000),
            publishedAt: nil, sourceDurationSeconds: 60, durationSeconds: 60,
            playbackSeconds: 0, downloadState: .notDownloaded
        )
        model.episodes.append(episode)
        model.librarySyncActivity.media = WiltedMacMediaActivity(
            preupload: WiltedMacMediaActivity.Preupload(targetCount: 3, uploadedCount: 1, uploadingID: episode.id),
            requestsQueued: 2
        )

        let rows = try XCTUnwrap(model.activitySummary.groups.first { $0.title == "iCloud" }?.rows)
        XCTAssertEqual(rows.first { $0.id == "uploaded-ahead" }?.value, "Sending 2 of 3: \(episode.title)")
        XCTAssertEqual(rows.first { $0.id == "requests" }?.value, "2 queued")
    }
}
