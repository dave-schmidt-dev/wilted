import SwiftUI
import UIKit

/// The playing episode's artwork as a soft wash across the top third of Now Playing, behind the title
/// and controls. It reads only the local artwork cache (never the network), so it appears with the
/// rest of the screen or not at all; with no artwork the page stays plain. It never takes a touch and
/// is hidden from VoiceOver, since the title already names the episode.
struct LibraryArtworkBackdrop: View {
    /// The most the artwork shows through. Pinned by `LibraryArtworkBackdropTests`: text keeps its
    /// 4.5:1 contrast (W-INV-010) over the worst pixel the artwork could put under it.
    static let opacity = 0.12
    /// How much of the screen's height the wash covers.
    static let heightFraction: CGFloat = 1.0 / 3.0

    let url: URL?
    var cache: LibraryArtworkCache = LibraryArtworkCache.shared
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geometry in
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height * Self.heightFraction)
                    .clipped()
                    .opacity(Self.opacity)
                    .mask(LinearGradient(colors: [.black, .black, .clear], startPoint: .top, endPoint: .bottom))
                    .accessibilityIdentifier("wilted-player-artwork-backdrop")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .task(id: url) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: LibraryArtworkCache.didCache)) { note in
            if let url, note.object as? URL == url { Task { await load() } }
        }
    }

    private func load() async {
        guard let url else { image = nil; return }
        if let data = cache.loadedData(for: url) { image = UIImage(data: data); return }
        let cache = cache
        let data = await Task.detached { cache.data(for: url) }.value
        // A newer episode cancelled this load while it read the disk: its image must not replace the new one.
        guard !Task.isCancelled else { return }
        image = data.flatMap { UIImage(data: $0) }
    }
}
