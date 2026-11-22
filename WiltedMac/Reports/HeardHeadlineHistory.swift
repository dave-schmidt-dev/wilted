import Foundation

/// This Mac's recent headline speech starts. The hearing time controls local retention.
@MainActor
final class HeardHeadlineHistory {
    private struct Entry: Codable {
        let id: String
        let title: String
        let heardAt: Date
    }

    struct Snapshot: Sendable {
        fileprivate(set) var expiries: [String: Date] = [:]
        fileprivate(set) var stories = HeadlineStoryMemory()

        func allows(id: String, title: String, at time: Date) -> Bool {
            if let expiry = expiries[id], expiry > time { return false }
            return stories.verdict(for: title, at: time) != .duplicate
        }
    }

    private static let key = "wilted.bulletins.heardHeadlines"
    private let defaults: UserDefaults
    private var entries: [Entry]
    private var recent = Snapshot()

    init(defaults: UserDefaults, now: Date = Date()) {
        self.defaults = defaults
        entries = defaults.data(forKey: Self.key).flatMap {
            try? PropertyListDecoder().decode([Entry].self, from: $0)
        } ?? []
        if prune(at: now) { save() }
        rebuild()
    }

    func snapshot(at time: Date) -> Snapshot {
        if prune(at: time) {
            rebuild()
            save()
        }
        return recent
    }

    func record(id: String, title: String, at time: Date) {
        entries.removeAll { $0.id == id || time.timeIntervalSince($0.heardAt) >= HeadlineStoryMemory.retention }
        entries.append(Entry(id: id, title: title, heardAt: time))
        if entries.count > HeadlineStoryMemory.capacity {
            entries.removeFirst(entries.count - HeadlineStoryMemory.capacity)
        }
        rebuild()
        save()
    }

    private func prune(at time: Date) -> Bool {
        let originalCount = entries.count
        entries.removeAll { time.timeIntervalSince($0.heardAt) >= HeadlineStoryMemory.retention }
        return entries.count != originalCount
    }

    private func rebuild() {
        recent = Snapshot()
        for entry in entries {
            recent.expiries[entry.id] = entry.heardAt.addingTimeInterval(HeadlineStoryMemory.retention)
            recent.stories.remember(entry.title, at: entry.heardAt)
        }
    }

    private func save() {
        if let data = try? PropertyListEncoder().encode(entries) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
