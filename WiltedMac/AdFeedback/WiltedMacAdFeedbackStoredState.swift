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
        let currentResult = read(url)
        let archiveResult = read(archiveURL)
        var failure: String?

        var current: WiltedMacAdFeedbackStoredState?
        switch currentResult {
        case .missing:
            break
        case .readable(let state):
            current = state
        case .corrupt:
            if !preserve(url) {
                failure = "A corrupt ad-feedback file could not be preserved; new writes are paused."
            }
        case .unsupported:
            if preserve(url) {
                failure = "An unsupported ad-feedback file was preserved; new writes are paused."
            } else {
                failure = "An unsupported ad-feedback file could not be preserved; new writes are paused."
            }
        case .inaccessible:
            failure = "An unreadable ad-feedback file could not be preserved; new writes are paused."
        }

        var archived: WiltedMacAdFeedbackStoredState?
        switch archiveResult {
        case .missing:
            break
        case .readable(let state):
            archived = state
        case .corrupt, .unsupported:
            if preserve(archiveURL) {
                failure = "A previous ad-feedback archive could not be read; new writes are paused."
            } else {
                failure = "A previous ad-feedback archive could not be preserved; new writes are paused."
            }
        case .inaccessible:
            failure = "A previous ad-feedback archive could not be read; new writes are paused."
        }

        if case .corrupt = currentResult, archived != nil {
            failure = "A saved ad-feedback archive was recovered after current-file corruption; new writes are paused."
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

    private enum ReadResult {
        case missing
        case readable(WiltedMacAdFeedbackStoredState)
        case corrupt
        case unsupported
        case inaccessible
    }

    private static func read(_ url: URL) -> ReadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let bytes = try? Data(contentsOf: url) else { return .inaccessible }
        guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let version = object["version"] as? Int else { return .corrupt }
        guard version == 1 || version == 2 else { return .unsupported }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(Self.self, from: bytes),
              (state.version != 2 || state.handledActions != nil),
              Set(state.entries.map(\.id)).count == state.entries.count,
              Set((state.handledActions ?? []).map(\.actionID)).count == (state.handledActions ?? []).count
        else { return .corrupt }
        return .readable(state)
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

    private static func preserve(_ source: URL) -> Bool {
        let base = source.appendingPathExtension("unreadable")
        let target = FileManager.default.fileExists(atPath: base.path)
            ? source.appendingPathExtension("unreadable-\(UUID().uuidString)") : base
        do {
            try FileManager.default.moveItem(at: source, to: target)
            return true
        } catch {
            return false
        }
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
