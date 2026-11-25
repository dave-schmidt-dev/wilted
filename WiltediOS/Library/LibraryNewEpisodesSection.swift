import SwiftUI
import WiltedDomain
import WiltedLibrary

struct LibraryNewEpisodesSection: View {
    @ObservedObject var model: LibraryAppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var visibleCount = 25

    private var rows: [LibraryUndecidedEpisode] { Array(model.newEpisodeRows.prefix(visibleCount)) }

    @ViewBuilder
    var body: some View {
        Group {
            if !model.newEpisodeRows.isEmpty {
                Section {
                    if let notice = model.newEpisodeNotice ?? model.newEpisodeCapabilityText {
                        Text(notice)
                            .wiltedFont(.utility)
                            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                            .accessibilityIdentifier("wilted-library-new-episodes-notice")
                    }
                    ForEach(rows) { row in
                        episode(row)
                            .listRowSeparator(.visible)
                    }
                    if visibleCount < model.newEpisodeRows.count {
                        Button("Show 25 more new episodes") { visibleCount += 25 }
                            .accessibilityIdentifier("wilted-library-new-episodes-more")
                    }
                } header: {
                    Text("New episodes · \(model.newEpisodeRows.count)")
                        .accessibilityIdentifier("wilted-library-new-episodes-header")
                }
                .accessibilityIdentifier("wilted-library-new-episodes")
                .task { await model.ensureNewEpisodeCapability() }
            }
            if !model.unlistedNewEpisodeConflictNotices.isEmpty {
                Section {
                    ForEach(model.unlistedNewEpisodeConflictNotices) { notice in
                        conflictNotice(notice)
                    }
                } header: {
                    Text("Decision updates")
                        .accessibilityIdentifier("wilted-library-new-episode-updates-header")
                }
            }
        }
    }

    @ViewBuilder
    private func episode(_ row: LibraryUndecidedEpisode) -> some View {
        let entry = row.entry
        let source = model.decisionContent.sources[entry.sourceID]?.title
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            Text(entry.title)
                .wiltedFont(.body)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("wilted-library-new-episode-title-\(row.id.rawValue)")
            HStack(spacing: WiltedTheme.Spacing.small) {
                if let source, !source.isEmpty {
                    Text(source)
                }
                Text(LibraryDateFormat.day(entry.publishedAt))
            }
            .wiltedFont(.utility)
            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            if !entry.summary.isEmpty {
                Text(entry.summary)
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let status = model.newEpisodeStatus(for: row) {
                VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                    Text(status)
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityIdentifier("wilted-library-new-episode-status-\(row.id.rawValue)")
                    if model.newEpisodeConflictStates[row.id] != nil {
                        Button("Dismiss") { model.dismissNewEpisodeConflict(row.id) }
                            .wiltedFont(.utility)
                            .accessibilityIdentifier("wilted-library-new-episode-conflict-dismiss-\(row.id.rawValue)")
                    }
                }
            }
            HStack(spacing: WiltedTheme.Spacing.small) {
                choiceButton(.keep, row: row)
                choiceButton(.skip, row: row)
            }
        }
        .padding(.vertical, WiltedTheme.Spacing.small)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-library-new-episode-\(row.id.rawValue)")
    }

    private func conflictNotice(_ notice: LibraryNewEpisodeConflictNotice) -> some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            HStack(alignment: .firstTextBaseline) {
                Text(notice.title ?? "Episode")
                    .wiltedFont(.body)
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: WiltedTheme.Spacing.small)
                Button("Dismiss") { model.dismissNewEpisodeConflict(notice.entryID) }
                    .wiltedFont(.utility)
                    .accessibilityIdentifier("wilted-library-new-episode-conflict-dismiss-\(notice.entryID.rawValue)")
            }
            Text(LibraryAppModel.newEpisodeConflictText(notice.state))
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .accessibilityIdentifier("wilted-library-new-episode-conflict-\(notice.entryID.rawValue)")
        }
        .padding(.vertical, WiltedTheme.Spacing.small)
    }

    private func choiceButton(_ choice: LibraryNewEpisodeDecision, row: LibraryUndecidedEpisode) -> some View {
        Button {
            Task { await model.chooseNewEpisode(choice, entryID: row.id) }
        } label: {
            Label(choice == .keep ? "Keep" : "Skip", systemImage: choice == .keep ? "checkmark" : "xmark")
                .frame(maxWidth: .infinity, minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .disabled(model.pendingNewEpisodeDecision(for: row.id) != nil || model.newEpisodeCapabilityText != nil)
        .accessibilityIdentifier("wilted-library-new-episode-\(choice.rawValue)-\(row.id.rawValue)")
    }
}
