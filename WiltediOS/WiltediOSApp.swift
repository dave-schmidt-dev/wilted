import Foundation
import SwiftUI
import WiltedListener

@main
struct WiltediOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: WiltedListenerAppModel

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let pixelFixtureState = arguments
            .first(where: { $0.hasPrefix("--wilted-listener-pixel-state=") })
            .flatMap { argument in
                ListenerPixelFixtureState(
                    rawValue: argument.replacingOccurrences(
                        of: "--wilted-listener-pixel-state=",
                        with: ""
                    )
                )
        }
        let initialModel: WiltedListenerAppModel
        let smokeFixtureMode = arguments.contains("--wilted-ui-smoke")
        let playingFixtureMode = arguments.contains("--wilted-ui-fixture-playing")
#if DEBUG
        if arguments.contains("--wilted-listener-pixel-fixture") {
            initialModel = WiltedListenerAppModel.makePixelFixture(state: pixelFixtureState ?? .library)
        } else if arguments.contains("--wilted-listener-mvp-fixture") {
            initialModel = ListenerMVPFixture.makeModel()
        } else if smokeFixtureMode || playingFixtureMode {
            initialModel = WiltedListenerAppModel.makePixelFixture(
                state: playingFixtureMode ? .nowPlaying : .library
            )
        } else {
            initialModel = WiltedListenerAppModel.makeDefault()
        }
#else
        if arguments.contains("--wilted-listener-pixel-fixture") {
            initialModel = WiltedListenerAppModel.makePixelFixture(state: pixelFixtureState ?? .library)
        } else if smokeFixtureMode || playingFixtureMode {
            initialModel = WiltedListenerAppModel.makePixelFixture(
                state: playingFixtureMode ? .nowPlaying : .library
            )
        } else {
            initialModel = WiltedListenerAppModel.makeDefault()
        }
#endif
        _model = StateObject(wrappedValue: initialModel)
    }

    var body: some Scene {
        WindowGroup {
            let arguments = ProcessInfo.processInfo.arguments
            let pixelFixtureMode = arguments.contains("--wilted-listener-pixel-fixture")
            let smokeFixtureMode = arguments.contains("--wilted-ui-smoke")
                || arguments.contains("--wilted-ui-fixture-playing")
#if DEBUG
            let mvpFixtureMode = arguments.contains("--wilted-listener-mvp-fixture")
#endif
            let pixelAppearance: ColorScheme? = arguments.contains("--wilted-listener-pixel-appearance=light")
                ? .light
                : arguments.contains("--wilted-listener-pixel-appearance=dark")
                    ? .dark
                    : nil
            // Downloads is a Library filter now, not a destination.
            let initialSelection: WiltedNavigation = arguments.contains("--wilted-listener-pixel-settings")
                    ? .settings
                    : arguments.contains("--wilted-listener-pixel-now-playing")
                        || arguments.contains("--wilted-ui-fixture-playing")
                        || arguments.contains("--wilted-listener-pixel-state=nowPlaying")
                        ? .nowPlaying
                        : .library
            Group {
#if DEBUG
                if mvpFixtureMode {
                    // The MVP journey deliberately hosts the shipping listener
                    // views directly. It must never route through Shared's
                    // preview shells, which have no listener behavior.
                    ListenerMVPFixture(model: model)
                } else {
                    shippingRootView(
                        initialSelection: initialSelection
                    )
                }
#else
                shippingRootView(
                    initialSelection: initialSelection
                )
#endif
            }
            .preferredColorScheme(pixelAppearance)
            .onAppear {
                // The pixel fixture must remain account- and device-free. Its
                // real listener views are rendered from deterministic state,
                // without installing Media Player command handlers that would
                // otherwise report a local-library failure.
#if DEBUG
                guard !pixelFixtureMode, !mvpFixtureMode, !smokeFixtureMode else { return }
#else
                guard !pixelFixtureMode, !smokeFixtureMode else { return }
#endif
                Task { await model.install(remoteCommands: MediaPlayerRemoteCommands()) }
            }
            .task {
#if DEBUG
                guard !pixelFixtureMode, !mvpFixtureMode, !smokeFixtureMode else { return }
#else
                guard !pixelFixtureMode, !smokeFixtureMode else { return }
#endif
                await model.start()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            let arguments = ProcessInfo.processInfo.arguments
#if DEBUG
            guard !arguments.contains("--wilted-listener-pixel-fixture"),
                  !arguments.contains("--wilted-listener-mvp-fixture"),
                  !arguments.contains("--wilted-ui-smoke"),
                  !arguments.contains("--wilted-ui-fixture-playing") else {
                return
            }
#else
            guard !arguments.contains("--wilted-listener-pixel-fixture"),
                  !arguments.contains("--wilted-ui-smoke"),
                  !arguments.contains("--wilted-ui-fixture-playing") else { return }
#endif
            Task {
                switch phase {
                case .background: await model.enterBackground()
                case .active: await model.resumeForeground()
                default: break
                }
            }
        }
    }

    private func shippingRootView(initialSelection: WiltedNavigation) -> some View {
        WiltedRootView(
            initialSelection: initialSelection,
            iOSLibrary: AnyView(WiltedListenerLibraryView(model: model)),
            iOSNowPlaying: AnyView(WiltedListenerNowPlayingView(model: model)),
            iOSSettings: AnyView(WiltedListenerSettingsView(model: model))
        )
    }
}
