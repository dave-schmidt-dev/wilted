import SwiftUI
import UIKit
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

@MainActor
final class LibraryPreparationStatusTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)
    private let clock = LibraryClockFormat(timeZone: TimeZone(identifier: "UTC")!)
    private func id(_ raw: String) -> ItemID { try! ItemID(rawValue: raw) }

    private func status(_ state: LibraryPreparationStatus.State = .active, stage: String = "ads.detect.calls",
                        fraction: Double? = 0.25) throws -> LibraryPreparationStatus {
        try LibraryPreparationStatus(attemptID: "generation-3-2", state: state, stage: stage,
            detail: "Checking advertisements. 4 requests, 0 failed.", fraction: fraction, updatedAt: date)
    }

    private func entry(_ raw: String, status: LibraryPreparationStatus? = nil,
                       group: LibraryEpisodeAssociation? = nil) throws -> LibraryEntry {
        try LibraryEntry(id: id(raw), kind: .podcastEpisode, sourceID: id("show"), title: "Episode \(raw)",
            summary: "Episode notes", publishedAt: date, durationSeconds: 600,
            episodeAssociation: group, preparationStatus: status)
    }

    private func snapshot(_ entries: [LibraryEntry], queue: [String]) throws -> LibrarySnapshot {
        var content = LibrarySnapshot()
        content.sources[id("show")] = LibrarySource(id: id("show"), kind: .podcastFeed, title: "The Show")
        for entry in entries { content.entries[entry.id] = entry }
        for (index, raw) in queue.enumerated() {
            content.slots[id(raw)] = try QueueSlot(entryID: id(raw), sortKey: Double(index))
        }
        return content
    }

    private func group() -> LibraryEpisodeAssociation {
        LibraryEpisodeAssociation(groupID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            representativeID: id("a"), memberIDs: [id("a"), id("b")], associationVersion: 1, isTerminal: false)
    }

    private func project(_ content: LibrarySnapshot) -> [LibraryRow] {
        let raw = LibraryRowBuilder.rows(content: content, checkpoints: [:], clock: clock)
        return LibraryRowBuilder.logicalRows(raw, content: content, checkpoints: [:], clock: clock,
            started: [], groupsByMember: LibraryRowBuilder.associationsByMember(in: content))
    }

    func testEveryCurrentStateAppearsWithoutMediaAndNeverEntersMediaFiltersOrPlayback() throws {
        let fixture = try LibraryViewFixture()
        defer { fixture.tearDown() }
        let model = fixture.model
        for state in [LibraryPreparationStatus.State.queued, .active, .failed, .cancelled] {
            model.decisionContent = try snapshot([entry("a", status: status(state))], queue: ["a"])
            model.rebuildRows()
            model.filter = .all
            let row = try XCTUnwrap(model.visibleRows.first)
            XCTAssertEqual(row.id, id("a"))
            XCTAssertEqual(row.preparationAnnotations.first?.status.state, state)
            XCTAssertTrue(row.isPreparationOnly)
            XCTAssertTrue(try XCTUnwrap(model.logicalRow(for: row.id)).isPreparationOnly, "detail uses the same restriction")
            XCTAssertEqual(row.detailText(), "The Show - 10:00 - \(LibraryDateFormat.day(date))")
            XCTAssertTrue(model.readyOffers.isEmpty)
            XCTAssertTrue(model.preparedIDs.offered.isEmpty)
            XCTAssertTrue(model.preparedIDs.onPhone.isEmpty)
            XCTAssertTrue(model.playOrderRows.isEmpty)
            XCTAssertEqual(model.preparedCount, 1, "an All-only search result is not an empty Larder")
            model.filter = .available
            XCTAssertTrue(model.visibleRows.isEmpty)
            model.filter = .onPhone
            XCTAssertTrue(model.visibleRows.isEmpty)
            XCTAssertTrue(model.mediaRuns.isEmpty)
        }
    }

    func testStatusClearRemovalAndQueueWithdrawalWinAndSearchStillWorks() throws {
        let fixture = try LibraryViewFixture()
        defer { fixture.tearDown() }
        let model = fixture.model
        let active = try entry("a", status: status())
        model.decisionContent = try snapshot([active], queue: ["a"])
        model.rebuildRows()
        model.searchText = "missing"
        XCTAssertTrue(model.visibleRows.isEmpty)
        model.searchText = "Episode notes"
        XCTAssertEqual(model.visibleRows.map(\.id), [id("a")])
        model.decisionContent = try snapshot([active.with(removal: .retired)], queue: ["a"])
        model.rebuildRows()
        XCTAssertTrue(model.visibleRows.isEmpty)
        model.decisionContent = try snapshot([active], queue: [])
        model.rebuildRows()
        XCTAssertTrue(model.visibleRows.isEmpty)
        model.decisionContent = try snapshot([entry("a")], queue: ["a"])
        model.rebuildRows()
        XCTAssertTrue(model.visibleRows.isEmpty, "a cleared producer report cannot leave a stale status row")
        XCTAssertTrue(model.queued[0].preparationAnnotations.isEmpty)
    }

    func testAbsentAndUnsupportedStatusRetainOldPreparedBehavior() throws {
        let value = try entry("a", status: status())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        var report = try XCTUnwrap(object["preparationStatus"] as? [String: Any])
        report["version"] = 999
        object["preparationStatus"] = report
        let decoded = try JSONDecoder().decode(LibraryEntry.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.preparationStatus)
        let fixture = try LibraryViewFixture()
        defer { fixture.tearDown() }
        fixture.model.decisionContent = try snapshot([decoded], queue: ["a"])
        fixture.model.rebuildRows()
        XCTAssertTrue(fixture.model.visibleRows.isEmpty)
        fixture.model.media[id("a")] = .onPhone
        let row = try XCTUnwrap(fixture.model.visibleRows.first)
        XCTAssertFalse(row.isPreparationOnly)
        XCTAssertTrue(row.preparationAnnotations.isEmpty)
        XCTAssertEqual(fixture.model.playOrderRows.map(\.id), [id("a")])
    }

    func testOtherCopyStatusIsIndependentOfBackingAndConflictsStayInRawMemberOrder() throws {
        let fixture = try LibraryViewFixture()
        defer { fixture.tearDown() }
        let model = fixture.model
        let association = group()
        let active = try status()
        model.decisionContent = try snapshot([entry("a", group: association), entry("b", status: active, group: association)],
                                             queue: ["a", "b"])
        model.rebuildRows()
        let sole = try XCTUnwrap(model.visibleRows.first)
        XCTAssertEqual(sole.id, id("a"))
        XCTAssertEqual(sole.preparationAnnotations.map(\.memberID), [id("b")])
        XCTAssertTrue(sole.preparationAnnotations[0].text.hasPrefix("Other copy: Preparing on Mac"))
        XCTAssertEqual(model.backingEntryID(for: id("a")), id("a"), "status cannot select media backing")
        model.media[id("a")] = .onPhone
        XCTAssertFalse(try XCTUnwrap(model.visibleRows.first).isPreparationOnly)
        XCTAssertEqual(model.backingEntryID(for: id("a")), id("a"))
        let failed = try status(.failed)
        let values = try [entry("a", status: failed, group: association), entry("b", status: active, group: association)]
        for queue in [["a", "b"], ["b", "a"]] {
            let rows = project(try snapshot(Array(values.reversed()), queue: queue))
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows[0].preparationAnnotations.map(\.memberID), [id("a"), id("b")])
            XCTAssertEqual(rows[0].preparationAnnotations.map(\.status), [failed, active])
            XCTAssertNil(rows[0].preparationAnnotations[0].progress)
            XCTAssertEqual(rows[0].preparationAnnotations[1].progress, 0.25)
        }
    }

    func testIncompleteGroupFallsBackToRawAndWithdrawnMemberReportIsExcluded() throws {
        let association = group()
        let b = try entry("b", status: status(), group: association)
        let missing = project(try snapshot([b], queue: ["b"]))
        XCTAssertEqual(missing.map(\.id), [id("b")])
        XCTAssertFalse(missing[0].preparationAnnotations[0].isOtherCopy)
        let content = try snapshot([entry("a", group: association), b], queue: ["a"])
        XCTAssertTrue(project(content)[0].preparationAnnotations.isEmpty)
    }

    func testPendingDisplayUsesCurrentReportsAndClearRatherThanRetainedStatus() async throws {
        await HostedAccessibility.prepare()
        let fixture = try LibraryViewFixture()
        defer { fixture.tearDown() }
        let model = fixture.model
        let old = try snapshot([entry("a", status: status(.failed))], queue: ["a"])
        model.completedDisplayContent = old
        model.completedDisplayRows = LibraryRowBuilder.rows(content: old, checkpoints: [:], clock: clock)
        model.decisionContent = try snapshot([entry("a", status: status()), entry("b", status: status()),
            entry("c", status: status())], queue: ["a", "b", "c"])
        model.rebuildRows()
        // A current transfer retains its existing cancel action, while C stays status-only.
        model.media[id("b")] = .requested(since: date)
        let rows = model.visibleRows
        XCTAssertEqual(Set(rows.map(\.id)), [id("a"), id("b"), id("c")])
        XCTAssertEqual(try XCTUnwrap(rows.first { $0.id == id("a") }).preparationAnnotations.first?.status.state, .active)
        XCTAssertFalse(try XCTUnwrap(rows.first { $0.id == id("a") }).isPreparationOnly)
        XCTAssertFalse(try XCTUnwrap(rows.first { $0.id == id("b") }).isPreparationOnly)
        XCTAssertTrue(try XCTUnwrap(rows.first { $0.id == id("c") }).isPreparationOnly)
        for row in rows {
            let detail = try XCTUnwrap(model.logicalRow(for: row.id))
            XCTAssertEqual(detail.isPreparationOnly, row.isPreparationOnly, "retained list/detail must agree in both directions")
        }
        let list = HostedView(NavigationStack { LibraryListView(model: model) })
        XCTAssertNotNil(list.element("wilted-library-media-get-a"))
        XCTAssertNotNil(list.element("wilted-library-media-cancel-b"))
        XCTAssertNil(list.element("wilted-library-media-get-c"))
        let retainedDetail = HostedView(NavigationStack { LibraryEpisodeDetailView(model: model, entryID: id("a")) })
        XCTAssertNotNil(retainedDetail.element("wilted-library-media-get-a"))
        let statusDetail = HostedView(NavigationStack { LibraryEpisodeDetailView(model: model, entryID: id("b")) })
        XCTAssertNotNil(statusDetail.element("wilted-library-media-cancel-b"))
        let onlyStatusDetail = HostedView(NavigationStack { LibraryEpisodeDetailView(model: model, entryID: id("c")) })
        XCTAssertNil(onlyStatusDetail.element("wilted-library-media-get-c"))
        model.filter = .available
        XCTAssertEqual(model.visibleRows.map(\.id), [id("a"), id("b")])
        // A retained on-phone copy remains usable in both projections.
        model.media[id("b")] = .onPhone
        model.filter = .all
        XCTAssertFalse(try XCTUnwrap(model.visibleRows.first { $0.id == id("b") }).isPreparationOnly)
        XCTAssertFalse(try XCTUnwrap(model.logicalRow(for: id("b"))).isPreparationOnly)
        XCTAssertEqual(model.playOrderRows.map(\.id), [id("b")])
        // Clearing current status cannot resurrect the failed retained report.
        model.decisionContent = try snapshot([entry("a"), entry("b", status: status())], queue: ["a", "b"])
        model.rebuildRows()
        XCTAssertTrue(try XCTUnwrap(model.logicalRow(for: id("a"))).preparationAnnotations.isEmpty)
        XCTAssertTrue(try XCTUnwrap(model.visibleRows.first { $0.id == id("a") }).preparationAnnotations.isEmpty)
    }

    func testUnknownStageIsGenericAndProgressAlwaysNamesItsStage() throws {
        let unknown = LibraryPreparationAnnotation(memberID: id("a"), status: try status(stage: "future-stage"))
        XCTAssertEqual(unknown.text, "Preparing on Mac · 25% of this stage")
        XCTAssertFalse(unknown.text.contains("advertisements"))
        XCTAssertTrue(unknown.accessibilityText.contains("Last reported"))
        XCTAssertEqual(unknown.lastReportedText, "Last reported \(LibraryDateFormat.dayAndTime(date))")
        for fraction in [-1.0, 1.01, Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertNil(try status(fraction: fraction).fraction, "malformed fractions are rejected by the contract")
        }
        XCTAssertEqual(try status(fraction: 0).fraction, 0)
        XCTAssertEqual(try status(fraction: 1).fraction, 1)
        let queued = LibraryPreparationAnnotation(memberID: id("a"), status: try status(.queued))
        XCTAssertEqual(queued.text, "Queued on Mac")
        XCTAssertNil(queued.progress)
        XCTAssertEqual(LibraryPreparationAnnotation(memberID: id("a"), status: try status(.cancelled)).text,
                       "Preparation cancelled on Mac")
    }

    func testProductionActionsRenderLightDarkAndLargeTextWithStatusAndNoMediaAuthority() async throws {
        await HostedAccessibility.prepare()
        let fixture = try LibraryViewFixture()
        defer { fixture.tearDown() }
        fixture.model.decisionContent = try snapshot([entry("a", status: status())], queue: ["a"])
        fixture.model.rebuildRows()
        let row = try XCTUnwrap(fixture.model.visibleRows.first)
        var mediaCalls = 0
        var playCalls = 0
        for scheme in [ColorScheme.light, .dark] {
            var standardHeight: CGFloat = 0
            for large in [false, true] {
                let content = LibraryEpisodeActions(row: row, media: .available,
                    onMedia: { _ in mediaCalls += 1 }, onPlay: { playCalls += 1 })
                    .environment(\.colorScheme, scheme)
                    .environment(\.dynamicTypeSize, large ? .accessibility3 : .large)
                    .padding(16).frame(width: 360)
                    .background(WiltedTheme.color(.card, scheme: scheme))
                let renderer = ImageRenderer(content: content)
                renderer.scale = 1
                let image = try XCTUnwrap(renderer.uiImage)
                XCTAssertEqual(image.size.width, 360)
                XCTAssertGreaterThan(image.size.height, 40)
                if large { XCTAssertGreaterThan(image.size.height, standardHeight) }
                else { standardHeight = image.size.height }
                let attachment = XCTAttachment(image: image)
                attachment.name = "preparation-actions-\(scheme)-\(large ? "large" : "standard")"
                attachment.lifetime = .keepAlways
                add(attachment)
                let host = HostedView(content, dark: scheme == .dark)
                let report = try XCTUnwrap(host.element("wilted-library-preparation-a"))
                XCTAssertEqual(report.label, row.preparationAnnotations[0].accessibilityText)
                XCTAssertFalse(report.isButton)
                XCTAssertTrue(host.elements().filter(\.isButton).isEmpty)
            }
        }
        XCTAssertEqual(mediaCalls, 0)
        XCTAssertEqual(playCalls, 0)
    }

    func testRealListVoiceOverAndDetailCompositionDoNotOfferStatusOnlyDownloadOrPlay() async throws {
        await HostedAccessibility.prepare()
        let fixture = try LibraryViewFixture()
        defer { fixture.tearDown() }
        fixture.model.decisionContent = try snapshot([entry("a", status: status())], queue: ["a"])
        fixture.model.rebuildRows()
        let raw = try XCTUnwrap(fixture.model.queued.first)
        let logical = try XCTUnwrap(fixture.model.logicalQueued.first)
        let detailRow = try XCTUnwrap(fixture.model.logicalRow(for: id("a")))
        let listed = try XCTUnwrap(fixture.model.visibleRows.first)
        for row in [raw, logical, detailRow, listed] {
            XCTAssertTrue(row.isPreparationOnly, "every producer-row entry point defaults to read-only")
            let actions = HostedView(LibraryEpisodeActions(row: row, media: .available, onPlay: {},
                decisionActions: [.markDone, .removeFromLarder]))
            XCTAssertTrue(actions.elements().filter(\.isButton).isEmpty)
            XCTAssertNotNil(actions.element("wilted-library-preparation-a"))
        }
        let host = HostedView(NavigationStack { LibraryListView(model: fixture.model, onPlay: { _ in XCTFail("no play authority") }) })
        let title = try XCTUnwrap(host.element("wilted-library-title-a"))
        XCTAssertFalse(title.customActionNames.contains("Download"))
        XCTAssertFalse(title.customActionNames.contains("Play"))
        XCTAssertNotNil(host.element("wilted-library-preparation-a"))
        XCTAssertNil(host.element("wilted-library-media-get-a"))
        let detail = HostedView(NavigationStack { LibraryEpisodeDetailView(model: fixture.model, entryID: id("a")) })
        XCTAssertNotNil(detail.element("wilted-library-preparation-a"))
        XCTAssertNil(detail.element("wilted-library-media-get-a"))
        XCTAssertTrue(fixture.model.mediaRuns.isEmpty)
    }

    func testPreparedAndTransferringRowsKeepProductionMediaControls() async throws {
        await HostedAccessibility.prepare()
        let fixture = try LibraryViewFixture()
        defer { fixture.tearDown() }
        fixture.model.decisionContent = try snapshot([entry("a", status: status())], queue: ["a"])
        fixture.model.rebuildRows()
        fixture.model.media[id("a")] = .requested(since: date)
        let transferring = try XCTUnwrap(fixture.model.visibleRows.first)
        XCTAssertFalse(transferring.isPreparationOnly)
        let host = HostedView(LibraryEpisodeActions(row: transferring, media: .requested(since: date)))
        XCTAssertNotNil(host.element("wilted-library-media-cancel-a"))
        XCTAssertNotNil(host.element("wilted-library-preparation-a"))
        fixture.model.media[id("a")] = .onPhone
        let cached = try XCTUnwrap(fixture.model.visibleRows.first)
        let cachedHost = HostedView(LibraryEpisodeActions(row: cached, media: .onPhone, onPlay: {}))
        XCTAssertNotNil(cachedHost.element("wilted-library-play-a"))
        XCTAssertNotNil(cachedHost.element("wilted-library-media-remove-a"))
    }
}
