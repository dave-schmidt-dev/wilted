import SwiftUI
import WiltedLibrary

/// Commands for the headline under the pointer, including when the feed refreshes mid-menu.
struct WiltedMacTickerStoryMenu: View {
    let model: WiltedMacModel
    let snapshot: LibraryHeadlineStory

    var body: some View {
        let catalog = model.headlineCatalogState
        let story = WiltedMacHeadlineTickerSelection.currentStory(matching: snapshot, in: catalog.projection)
        if let link = WiltedHeadlineStoryCard.readableLink(story.link) {
            Link("Read story", destination: link)
        }
        WiltedMacTickerAddToLarder(model: model, story: story)
        Button(story.isSaved ? "Remove from Notebook" : "Save to Notebook") {
            catalog.setSaved(story, isSaved: !story.isSaved)
        }
        .disabled(catalog.isActionInProgress)
    }
}

struct WiltedMacTickerAddToLarder: View {
    let model: WiltedMacModel
    let story: LibraryHeadlineStory

    var body: some View {
        let link = WiltedHeadlineStoryCard.readableLink(story.link)
        Button("Add to Larder") {
            if let link { model.addArticle(from: link.absoluteString) }
        }
        .disabled(link?.scheme?.lowercased() != "https" || model.preparation?.phase.isTerminal == false)
        .accessibilityIdentifier("wilted-ticker-add-to-larder-\(story.id)")
    }
}
