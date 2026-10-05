import SwiftUI

/// The Apple Watch remote: a Now Playing screen and an Up Next queue rendered
/// from the last snapshot the iPhone published.
///
/// The Watch plays no audio and stores no library state; it only renders what
/// the phone sends and forwards its commands back through the session client.
@main
struct WiltedWatchApp: App {
    @State private var session: WatchSessionClient

    init() {
        _session = State(initialValue: WatchSessionClient(model: WatchViewModel()))
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView(model: session.model)
                .task { session.start() }
        }
    }
}

/// The Watch remote's two screens, paged by a `TabView`.
struct WatchRootView: View {
    /// The state both screens render and control.
    let model: WatchViewModel

    var body: some View {
        TabView {
            NavigationStack {
                NowPlayingView(model: model)
            }
            NavigationStack {
                UpNextView(model: model)
            }
        }
    }
}
