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
        _model = StateObject(
            wrappedValue: arguments.contains("--wilted-listener-pixel-fixture")
                ? WiltedListenerAppModel.makePixelFixture(state: pixelFixtureState ?? .library)
                : WiltedListenerAppModel.makeDefault()
        )
    }

    var body: some Scene {
        WindowGroup {
            let arguments = ProcessInfo.processInfo.arguments
            let pixelFixtureMode = arguments.contains("--wilted-listener-pixel-fixture")
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
                : .library
            WiltedRootView(
                initialSelection: initialSelection,
                fixture: fixture,
                iOSLibrary: fixtureMode
                    ? AnyView(WiltedLibraryShell(fixture: fixture))
                    : AnyView(WiltedListenerLibraryView(model: model)),
                iOSDownloads: fixtureMode
                    ? AnyView(WiltedDownloadsShell())
                    : AnyView(WiltedListenerDownloadsView(model: model))
            )
            .preferredColorScheme(pixelAppearance)
            .onAppear {
                // The pixel fixture must remain account- and device-free. Its
                // real listener views are rendered from deterministic state,
                // without installing Media Player command handlers that would
                // otherwise report a local-library failure.
                guard !pixelFixtureMode else { return }
                Task { await model.install(remoteCommands: MediaPlayerRemoteCommands()) }
            }
            .task {
                guard !pixelFixtureMode else { return }
                await model.start()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard !ProcessInfo.processInfo.arguments.contains("--wilted-listener-pixel-fixture") else {
                return
            }
            Task {
                switch phase {
                case .background: await model.enterBackground()
                case .active: await model.resumeForeground()
                default: break
                }
            }
        }
    }
}
