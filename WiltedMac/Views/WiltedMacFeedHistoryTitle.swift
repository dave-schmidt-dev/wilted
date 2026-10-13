import SwiftUI

/// One History row's episode name: the title button and the info popover it
/// opens. History kept only the identity and facts the stored row carried, so
/// the popover resolves the episode's notes and transcript through the model
/// as it opens. Off the list and feed details both render this row, so the two
/// surfaces stay the same.
struct WiltedMacFeedHistoryTitle: View {
    let model: WiltedMacModel
    let record: WiltedMacFeedHistoryRecord
    @State private var isPresented = false

    var body: some View {
        WiltedMacEpisodeNotesTitle(
            id: record.id,
            title: record.presentation.title,
            prefix: "wilted-feed-history",
            isPresented: $isPresented
        ) {
            WiltedMacEpisodeInfoPopoverContent(
                id: record.id,
                seed: nil,
                prefix: "wilted-feed-history",
                source: model.episodeInfoSource(id: record.id, showTitle: record.feedTitle),
                initialSection: .notes,
                actions: { EmptyView() }
            )
        }
    }
}
