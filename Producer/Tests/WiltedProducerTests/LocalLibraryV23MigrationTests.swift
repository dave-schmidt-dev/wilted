import Foundation
import SwiftData
import XCTest
import WiltedDomain
import WiltedLibrary
@testable import WiltedProducer

final class LocalLibraryV23MigrationTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeURL() -> URL {
        OwnedTestTemp.root.appendingPathComponent("wilted-v23-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("library.sqlite")
    }

    private func writeV22Store(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try autoreleasepool {
            let schema = Schema(versionedSchema: LocalLibrarySchemaV22.self)
            let container = try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none),
            ])
            let context = ModelContext(container)
            context.insert(LocalLibrarySchemaV14Models.LifetimeStatisticsTrackingRecord(startedAt: origin, schemaVersion: 22))
            context.insert(LocalLibrarySchemaV14Models.LifetimeStatisticsSummaryRecord(state: .ready, updatedAt: origin))
            context.insert(LocalLibrarySchemaV22Models.WorkTicketRecord(WorkTicket(
                kind: .podcastPreparation, subjectID: "retained-ticket", requestSequence: 9,
                state: .pending, requestedAt: Timestamp(origin), updatedAt: Timestamp(origin)
            )))
            try context.save()
        }
    }

    func testV22RowsMigrateToV23AndNotebookWritesSurviveRelaunch() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeV22Store(at: url)
        XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: url), .known(22))
        let before = try LocalLibraryStore.tableRowCounts(at: url)

        let scope = try NotebookLocalScope(ownerToken: "owner-a", deviceID: "migration-device")
        let entry = try LibraryNotebookEntry(
            id: ItemID(rawValue: "migrated-notebook-item"),
            sourceItemID: ItemID(rawValue: "migrated-episode"),
            sourceRevision: RevisionID(rawValue: "migrated-revision"), sourceTitle: "Retained episode",
            sourceURL: URL(string: "https://podcasts.example.test/episode")!,
            startSeconds: 3, endSeconds: 11, textExcerpt: "A cue from the source.", capturedOn: .mac
        )
        var store: LocalLibraryStore? = try LocalLibraryStore(url: url)
        let migratedVersion = await store?.schemaVersion
        XCTAssertEqual(migratedVersion, .v23)
        XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: url), .known(23))
        let migratedTickets = try await store?.workTickets()
        XCTAssertEqual(migratedTickets?.first?.subjectID, "retained-ticket")
        XCTAssertEqual(try LocalLibraryStore.tableRowCounts(at: url).filter { before[$0.key] != nil }
            .mapValues { $0 }, before, "every pre-migration entity keeps its row count")
        _ = try await store?.saveNotebookEntry(entry, in: scope)
        store = nil

        let relaunched = try LocalLibraryStore(url: url)
        let relaunchedEntries = try await relaunched.notebookEntries(in: scope)
        XCTAssertEqual(relaunchedEntries, [entry])
        XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: url), .known(23))
    }

    func testV22OpenGuardRefusesAV23StoreAfterNotebookWrite() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeV22Store(at: url)
        let scope = try NotebookLocalScope(ownerToken: "owner-a", deviceID: "migration-device")
        let entry = try LibraryNotebookEntry(
            id: ItemID(rawValue: "downgrade-notebook-item"),
            sourceItemID: ItemID(rawValue: "downgrade-episode"),
            sourceRevision: RevisionID(rawValue: "downgrade-revision"), sourceTitle: "Entry",
            sourceURL: URL(string: "https://podcasts.example.test/episode")!,
            startSeconds: 3, endSeconds: 11, textExcerpt: "Retained after upgrade.", capturedOn: .mac
        )
        var current: LocalLibraryStore? = try LocalLibraryStore(url: url)
        _ = try await current?.saveNotebookEntry(entry, in: scope)
        current = nil
        let counts = try LocalLibraryStore.tableRowCounts(at: url)

        let oldBuildResult = try LocalLibraryStore.diskSchemaVersion(
            at: url,
            recognizedThroughVersion: 22
        )
        guard case .unrecognized = oldBuildResult else {
            return XCTFail("a V22 LocalLibraryStore must refuse V23 before constructing a SwiftData container")
        }

        XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: url), .known(23))
        XCTAssertEqual(try LocalLibraryStore.tableRowCounts(at: url), counts)
        let currentAgain = try LocalLibraryStore(url: url)
        let recoveredEntries = try await currentAgain.notebookEntries(in: scope)
        XCTAssertEqual(recoveredEntries, [entry])
    }
}
