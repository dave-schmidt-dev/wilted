import Foundation
import SwiftUI
import WiltedDomain
import WiltedLibrary

/// One Larder row, already resolved to display strings.
struct LibraryRow: Identifiable, Equatable, Sendable {
    let id: ItemID
    let title: String
    let showTitle: String
    let durationText: String?
    /// The duration in seconds, for the shortest-first sort; nil when the feed gave none.
    var durationSeconds: Double?
    let removal: LibraryRemoval
    let publishedAt: Date
    /// "Retired on Mac" or "Dismissed on Mac"; nil while the entry is live.
    let removalText: String?
    /// "Paused on Mac at mm:ss (as of hh:mm)" from the Mac's last checkpoint for this entry.
    let checkpointText: String?
    /// True when some device has started the episode and it is not completed; the only rows
    /// that offer Mark done.
    var isStarted: Bool = false
    /// When the episode was marked completed on any device; nil while it is not.
    var completedAt: Date?
    /// The episode notes the Mac published; searched, never shown in the row.
    var summary: String = ""
    /// Artwork location as published by the Mac; nil when the episode has none.
    var artworkURL: URL?
    /// The show's own artwork (from its source), for lists of shows; nil when the Mac published none.
    var showArtworkURL: URL?
    /// Where Play should begin: the Mac's last observed position, nil to begin at the start.
    var resumeSeconds: Double?
    /// The episode's own web page, as the Mac published it from the feed's `<link>`; nil when the
    /// feed had none. Never the feed address.
    var episodeLink: URL?
    /// What the entry is; the kind filter reads it. An unknown kind is kept and listed under All.
    var kind: LibraryKind = .podcastEpisode
    /// An audiobook volume's chapters in start order; empty for every other kind.
    var chapters: [AudiobookChapter] = []
    /// Raw backing identities for a coherent logical display row; never cache keys.
    var memberIDs: [ItemID] = []
    /// Raw-member display reports, independent of the selected media backing.
    var preparationAnnotations: [LibraryPreparationAnnotation] = []
    /// Set only by an existing offer/cache projection, never by a preparation report.
    var hasPreparedMedia = false
    var isPreparationOnly: Bool { !preparationAnnotations.isEmpty && !hasPreparedMedia }
}

extension LibraryRow {
    /// Raw reports default to read-only; every media-backed presentation uses this projection.
    func withMediaAvailability(offered: Set<ItemID>, onPhone: Set<ItemID>) -> LibraryRow {
        var row = self
        row.hasPreparedMedia = !preparationAnnotations.isEmpty && (offered.contains(id) || onPhone.contains(id))
        return row
    }

    /// The show as a row names it: the trimmed title, or "Show unknown" when the feed gave none.
    var showLabel: String {
        let show = showTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return show.isEmpty ? "Show unknown" : show
    }

    /// The total duration as a row names it, "Unknown" when the feed gave none.
    var durationLabel: String { durationText ?? "Unknown" }

    /// Line two of a Larder row, "Show - duration". `namesShow` is false for a row under a feed section
    /// header, which already names the show, so the line keeps only the duration.
    func showAndDurationText(namesShow: Bool = true) -> String {
        namesShow ? "\(showLabel) - \(durationLabel)" : durationLabel
    }

    /// Line three of a Larder row: the publication date alone, "Oct 3, 2026".
    var publicationDateText: String { LibraryDateFormat.day(publishedAt) }

    /// The row's facts as one string, "Show - duration - date", for callers that need them in a single line.
    func detailText(namesShow: Bool = true) -> String {
        "\(showAndDurationText(namesShow: namesShow)) - \(publicationDateText)"
    }
}

/// Fixed-format clock and duration text, so labels do not shift with the device locale.
/// The dates the Larder, episode detail and Settings show. They follow the device's time zone; only the
/// DEBUG pixel fixture sets `timeZone`, so a baseline does not move with the host or daylight saving.
enum LibraryDateFormat {
    nonisolated(unsafe) static var timeZone: TimeZone = .autoupdatingCurrent

    /// "Oct 3, 2026".
    static func day(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(timeZone: timeZone).month(.abbreviated).day().year())
    }

    /// "Oct 3, 2026 at 8:00 AM".
    static func dayAndTime(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: timeZone))
    }
}

struct LibraryClockFormat: Sendable {
    let timeZone: TimeZone

    func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// `mm:ss`, or `h:mm:ss` from one hour up.
    static func duration(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let (hours, minutes, secs) = (total / 3600, total % 3600 / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }
}

/// Pure projection from mirrored content to rows.
enum LibraryRowBuilder {
    /// Queued entries in slot order. The phone shows no other entries: New, retired and
    /// dismissed episodes belong to the Mac.
    static func rows(
        content: LibrarySnapshot,
        checkpoints: [ItemID: ObservedPlayback],
        clock: LibraryClockFormat,
        started: Set<ItemID> = []
    ) -> [LibraryRow] {
        content.queue.compactMap { content.entries[$0.entryID] }.map {
            makeRow($0, content: content, checkpoints: checkpoints, clock: clock, started: started)
        }
    }

    static func associationsByMember(in content: LibrarySnapshot?) -> [ItemID: LibraryEpisodeAssociation] {
        guard let content else { return [:] }
        return Dictionary(LibraryEpisodeAssociation.coherentGroups(in: Array(content.entries.values)).flatMap { group in
            group.memberIDs.map { ($0, group) }
        }, uniquingKeysWith: { first, _ in first })
    }

    /// Folds presentation only. Raw slots, entries, preparation and checkpoints stay intact.
    static func logicalRows(_ rows: [LibraryRow], content: LibrarySnapshot, checkpoints: [ItemID: ObservedPlayback],
                            clock: LibraryClockFormat, started: Set<ItemID>,
                            groupsByMember: [ItemID: LibraryEpisodeAssociation]) -> [LibraryRow] {
        let startedIDs = Set(rows.filter(\.isStarted).map(\.id))
        var seen = Set<UUID>()
        return rows.compactMap { row in
            guard let group = groupsByMember[row.id] else { return row }
            guard !group.isTerminal, seen.insert(group.groupID).inserted,
                  let entry = content.entries[group.representativeID] else { return nil }
            var representative = makeRow(entry, content: content, checkpoints: checkpoints, clock: clock, started: started)
            representative.memberIDs = group.memberIDs
            representative.preparationAnnotations = group.memberIDs.sorted { $0.rawValue < $1.rawValue }.compactMap { id in
                content.entries[id].flatMap { preparationAnnotation($0, content: content, representativeID: group.representativeID) }
            }
            representative.isStarted = group.memberIDs.contains { startedIDs.contains($0) }
            return representative
        }
    }

    private static func makeRow(
        _ entry: LibraryEntry, content: LibrarySnapshot, checkpoints: [ItemID: ObservedPlayback],
        clock: LibraryClockFormat, started: Set<ItemID>
    ) -> LibraryRow {
        LibraryRow(
            id: entry.id,
            title: entry.title,
            showTitle: showTitle(entry, sources: content.sources),
            durationText: duration(entry).map(LibraryClockFormat.duration),
            durationSeconds: duration(entry),
            removal: entry.removal,
            publishedAt: entry.publishedAt,
            removalText: removalText(entry.removal),
            checkpointText: checkpoints[entry.id].map { checkpointText($0, clock: clock) },
            isStarted: started.contains(entry.id) && content.listening[entry.id]?.isCompleted != true,
            completedAt: content.listening[entry.id]?.completedAt,
            summary: entry.summary,
            artworkURL: artworkURL(entry.artworkRef),
            showArtworkURL: artworkURL(content.sources[entry.sourceID]?.artworkRef),
            resumeSeconds: resumeSeconds(checkpoints[entry.id], duration: entry.durationSeconds),
            episodeLink: (try? entry.podcastEpisodePayload().episodeLink)
                .flatMap { PodcastEpisode.isValidEpisodeLink($0) ? $0 : nil },
            kind: entry.kind,
            chapters: chapters(entry),
            preparationAnnotations: preparationAnnotation(entry, content: content, representativeID: entry.id).map { [$0] } ?? []
        )
    }

    /// Queue withdrawal, removal and terminal association win over any retained report.
    private static func preparationAnnotation(
        _ entry: LibraryEntry, content: LibrarySnapshot, representativeID: ItemID
    ) -> LibraryPreparationAnnotation? {
        guard entry.removal == .none, entry.episodeAssociation?.isTerminal != true,
              content.slots[entry.id] != nil, let status = entry.preparationStatus else { return nil }
        return LibraryPreparationAnnotation(memberID: entry.id, status: status,
            isOtherCopy: entry.id != representativeID)
    }

    /// The line a row and the player put under the title: the feed's name, or a book's author (a
    /// volume has no feed, so its row names who wrote it).
    static func showTitle(_ entry: LibraryEntry, sources: [ItemID: LibrarySource]) -> String {
        // A report has no source; its title already carries the date.
        if entry.kind == .report { return "Morning report" }
        guard entry.kind == .audiobook else { return sources[entry.sourceID]?.title ?? "Unknown show" }
        let author = audiobook(entry)?.author?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return author.isEmpty ? "Unknown author" : author
    }

    /// The entry's length; a volume whose entry carries none falls back to its payload's.
    private static func duration(_ entry: LibraryEntry) -> Double? {
        entry.durationSeconds ?? audiobook(entry).map(\.durationSeconds).flatMap { $0 > 0 ? $0 : nil }
    }

    /// A volume's chapters in start order, empty for a payload that cannot be read.
    static func chapters(_ entry: LibraryEntry) -> [AudiobookChapter] {
        (audiobook(entry)?.chapters ?? []).filter { $0.startSeconds.isFinite && $0.startSeconds >= 0 }
            .sorted { $0.startSeconds < $1.startSeconds }
    }

    private static func audiobook(_ entry: LibraryEntry) -> AudiobookPayload? {
        guard entry.kind == .audiobook else { return nil }
        return try? JSONDecoder().decode(AudiobookPayload.self, from: entry.payload)
    }

    /// Only web addresses load; anything else the Mac might publish shows the placeholder.
    static func artworkURL(_ reference: String?) -> URL? {
        reference.flatMap(URL.init(string:)).flatMap(webURL)
    }

    /// The address when it is http or https, otherwise nil.
    static func webURL(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return url
    }

    /// The Mac's last observed position, unless it is at the start or at the very end, where
    /// resuming would land after the last word and playing from the top is the useful choice.
    static func resumeSeconds(_ observed: ObservedPlayback?, duration: Double?) -> Double? {
        guard let position = observed?.record.positionSeconds, position.isFinite, position > 0 else { return nil }
        if let duration, duration > 0, position >= duration - 1 { return nil }
        return position
    }

    static func removalText(_ removal: LibraryRemoval) -> String? {
        switch removal {
        case .none: nil
        case .retired: "Retired on Mac"
        case .dismissed: "Dismissed on Mac"
        }
    }

    static func checkpointText(_ observed: ObservedPlayback, clock: LibraryClockFormat) -> String {
        let state = observed.record.isPlaying ? "Playing" : "Paused"
        let position = LibraryClockFormat.duration(observed.record.positionSeconds)
        return "\(state) on Mac at \(position) (as of \(clock.clock(observed.serverModifiedAt)))"
    }
}

/// A Larder row's two factual lines under the title, as on the Mac: "Show - duration", then the
/// publication date on its own line. Only the show yields space; the duration and the date stay whole.
/// The lines are separate accessibility elements, so VoiceOver reads the show and duration, then the date.
struct LibraryRowMetadataView: View {
    let row: LibraryRow
    let namesShow: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
            HStack(spacing: 0) {
                if row.kind == .report {
                    Image(systemName: "newspaper").accessibilityHidden(true).padding(.trailing, 4)
                }
                if namesShow {
                    Text(row.showLabel)
                        .lineLimit(1).truncationMode(.tail)
                    Text(" - ").fixedSize(horizontal: true, vertical: false)
                }
                Text(row.durationLabel)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(row.showAndDurationText(namesShow: namesShow))
            .accessibilityIdentifier("wilted-library-meta-\(row.id.rawValue)")
            Text(row.publicationDateText)
                .lineLimit(1)
                .accessibilityIdentifier("wilted-library-date-\(row.id.rawValue)")
        }
        .wiltedFont(.utility)
        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
    }
}
