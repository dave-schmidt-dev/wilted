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
#if DEBUG
        if arguments.contains("--wilted-listener-pixel-fixture") {
            initialModel = WiltedListenerAppModel.makePixelFixture(state: pixelFixtureState ?? .library)
        } else if arguments.contains("--wilted-listener-mvp-fixture") {
            initialModel = ListenerMVPFixture.makeModel()
        } else {
            initialModel = WiltedListenerAppModel.makeDefault()
        }
#else
        if arguments.contains("--wilted-listener-pixel-fixture") {
            initialModel = WiltedListenerAppModel.makePixelFixture(state: pixelFixtureState ?? .library)
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
#if DEBUG
            let mvpFixtureMode = arguments.contains("--wilted-listener-mvp-fixture")
#endif
            let pixelAppearance: ColorScheme? = arguments.contains("--wilted-listener-pixel-appearance=light")
                ? .light
                : arguments.contains("--wilted-listener-pixel-appearance=dark")
                    ? .dark
                    : nil
            let fixture = WiltedPreviewFixture.fromLaunchArguments(arguments)
            let fixtureMode = arguments.contains("--wilted-ui-smoke")
                || arguments.contains("--wilted-ui-fixture-playing")
            let initialSelection: WiltedNavigation = arguments.contains("--wilted-listener-pixel-downloads")
                ? .downloads
                : arguments.contains("--wilted-listener-pixel-settings") ? .settings : .library
            Group {
#if DEBUG
                if mvpFixtureMode {
                    // The MVP journey deliberately hosts the shipping listener
                    // views directly. It must never route through Shared's
                    // preview shells, which have no listener behavior.
                    ListenerMVPFixture(model: model)
                } else {
                    shippingRootView(
                        initialSelection: initialSelection,
                        fixture: fixture,
                        fixtureMode: fixtureMode
                    )
                }
#else
                shippingRootView(
                    initialSelection: initialSelection,
                    fixture: fixture,
                    fixtureMode: fixtureMode
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
                guard !pixelFixtureMode, !mvpFixtureMode else { return }
#else
                guard !pixelFixtureMode else { return }
#endif
                Task { await model.install(remoteCommands: MediaPlayerRemoteCommands()) }
            }
            .task {
#if DEBUG
                guard !pixelFixtureMode, !mvpFixtureMode else { return }
#else
                guard !pixelFixtureMode else { return }
#endif
                await model.start()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            let arguments = ProcessInfo.processInfo.arguments
#if DEBUG
            guard !arguments.contains("--wilted-listener-pixel-fixture"),
                  !arguments.contains("--wilted-listener-mvp-fixture") else {
                return
            }
#else
            guard !arguments.contains("--wilted-listener-pixel-fixture") else { return }
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

    private func shippingRootView(
        initialSelection: WiltedNavigation,
        fixture: WiltedPreviewFixture,
        fixtureMode: Bool
    ) -> some View {
        WiltedRootView(
            initialSelection: initialSelection,
            fixture: fixture,
            iOSLibrary: fixtureMode
                ? AnyView(WiltedLibraryShell(fixture: fixture))
                : AnyView(WiltedListenerLibraryView(model: model)),
            iOSDownloads: fixtureMode
                ? AnyView(WiltedDownloadsShell())
                : AnyView(WiltedListenerDownloadsView(model: model)),
            iOSSettings: fixtureMode
                ? AnyView(WiltedSettingsShell())
                : AnyView(WiltedListenerSettingsView(model: model))
        )
    }
}
