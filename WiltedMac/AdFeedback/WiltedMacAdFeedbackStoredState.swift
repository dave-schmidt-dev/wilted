import Foundation

/// Versioned inbox data and recovery for an older app's quarantined receipt store.
struct WiltedMacAdFeedbackStoredState: Codable {
    struct Recovery {
        let entries: [WiltedMacAdFeedbackEntry]
        let handledActions: [WiltedMacAdFeedbackActionReceipt]
        let failure: String?
    }

    let version: Int
    let entries: [WiltedMacAdFeedbackEntry]
    let handledActions: [WiltedMacAdFeedbackActionReceipt]?

    private enum CodingKeys: String, CodingKey { case version, entries, handledActions }

    init(entries: [WiltedMacAdFeedbackEntry], handledActions: [WiltedMacAdFeedbackActionReceipt]) {
        version = handledActions.isEmpty ? 1 : 2
        self.entries = entries
        self.handledActions = handledActions.isEmpty ? nil : handledActions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        entries = try container.decode([WiltedMacAdFeedbackEntry].self, forKey: .entries)
        handledActions = try container.decodeIfPresent(
            [WiltedMacAdFeedbackActionReceipt].self, forKey: .handledActions
        )
    }

    static func recover(from url: URL) -> Recovery {
        let archiveURL = url.appendingPathExtension("unreadable")
        let current = read(url)
        let archived = read(archiveURL)
        var failure: String?

        if current == nil && FileManager.default.fileExists(atPath: url.path) {
            preserve(url)
            failure = "An unsupported ad-feedback file was preserved; new writes are paused."
        }
        if archived == nil && FileManager.default.fileExists(atPath: archiveURL.path) {
            preserve(archiveURL)
            failure = "A previous ad-feedback archive could not be read; new writes are paused."
        }

        let needsMerge = current != nil && archived != nil
            && (current!.version == 2 || archived!.version == 2)
        guard needsMerge else {
            let selected = current ?? archived
            return canonical(selected?.entries ?? [], selected?.handledActions ?? [], failure: failure)
        }

        let active = current!
        let backup = archived!
        var entries = Dictionary(uniqueKeysWithValues: backup.entries.map { ($0.id, $0) })
        for item in active.entries {
            var item = item
            if item.handledAt == nil { item.handledAt = entries[item.id]?.handledAt }
            entries[item.id] = item
        }
        var receipts = Dictionary(uniqueKeysWithValues: backup.handledActions?.map { ($0.actionID, $0) } ?? [])
        for receipt in active.handledActions ?? [] {
            if let prior = receipts[receipt.actionID], prior != receipt {
                failure = "A saved replay receipt conflicts with its archive; new writes are paused."
                continue
            }
            receipts[receipt.actionID] = receipt
        }
        return canonical(
            Array(entries.values), Array(receipts.values), failure: failure
        )
    }

    private static func read(_ url: URL) -> WiltedMacAdFeedbackStoredState? {
        guard let bytes = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(Self.self, from: bytes),
              state.version == 1 || state.version == 2,
              (state.version != 2 || state.handledActions != nil),
              Set(state.entries.map(\.id)).count == state.entries.count,
              Set((state.handledActions ?? []).map(\.actionID)).count == (state.handledActions ?? []).count
        else { return nil }
        return state
    }

    private static func canonical(
        _ source: [WiltedMacAdFeedbackEntry], _ receipts: [WiltedMacAdFeedbackActionReceipt],
        failure: String?
    ) -> Recovery {
        let entries: [WiltedMacAdFeedbackEntry] = source.map { sourceEntry in
            var entry = sourceEntry
            if entry.review == WiltedMacAdFeedbackEntry.Review.pending {
                entry.review = WiltedMacAdFeedbackEntry.Review.accepted
            }
            return entry
        }.sorted {
            $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt
        }
        return Recovery(entries: entries, handledActions: receipts.sorted { $0.actionID < $1.actionID },
                        failure: failure)
    }

    private static func preserve(_ source: URL) {
        let base = source.appendingPathExtension("unreadable")
        let target = FileManager.default.fileExists(atPath: base.path)
            ? source.appendingPathExtension("unreadable-\(UUID().uuidString)") : base
        try? FileManager.default.moveItem(at: source, to: target)
    }
}

enum WiltedMacAdFeedbackStoreRecoveryError: LocalizedError {
    case writesPaused(String)
    case durabilityUnconfirmed

    var errorDescription: String? {
        switch self {
        case .writesPaused(let message): message
        case .durabilityUnconfirmed: "The handled action is queued until its receipt is durably saved."
        }
    }
}
