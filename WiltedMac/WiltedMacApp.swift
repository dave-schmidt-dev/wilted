import AppKit
import Foundation
import SwiftUI
import WiltedProducer

@main
struct WiltedMacApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: WiltedMacModel
    @FocusedValue(\.wiltedLarderSearchFocus) private var focusLarderSearch: (() -> Void)?
    /// Owns `applicationShouldTerminate`, so a normal quit drains local work
    /// before the process exits (see `WiltedMacTerminationCoordinator`).
    @NSApplicationDelegateAdaptor(WiltedMacAppDelegate.self) private var appDelegate

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let model = Self.makeLaunchModel(arguments: arguments)
        _model = State(initialValue: model)
        // Tests and fixtures are excluded because they have their own temporary state and their own archive instances.
        if !WiltedMacModel.hostsTests && !WiltedMacModel.isFixtureLaunch(arguments: arguments) {
            WiltedMacLogArchive.startForLaunch(stateDirectory: model.libraryURL.deletingLastPathComponent())
        }
        WiltedMacAppDelegate.windowLifecycleTrace = WiltedMacTerminationJournal.windowLifecycleTraceForLaunch(
            arguments: arguments,
            isFixture: WiltedMacModel.isFixtureLaunch(arguments: arguments) && !WiltedMacModel.hostsTests
        )
        WiltedMacAppDelegate.installTermination(
            for: model, arguments: arguments, hostsTests: WiltedMacModel.hostsTests
        )
    }

    /// Builds the model used by the app composition root. Keeping this small
    /// seam lets the hosted-app regression test inspect the exact launch path.
    @MainActor
    static func makeLaunchModel(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        preferences: UserDefaults = .standard
    ) -> WiltedMacModel {
        // The system integration is built here and nowhere else. It is
        // process-global state, so the app is the only context in which owning
        // the machine's Now Playing widget and its media keys is correct.
        //
        // A fixture run drives the app with synthetic audio, so it is given
        // neither: a UI test would otherwise leave its episode sitting in the
        // menu bar after the run, with the machine's media keys pointed at a
        // process that has exited.
        //
        // The unit-test host is this same app bundle, so a test run launches
        // this initialiser too. It is excluded for the same reason and one
        // more: the test host has its own temporary library, and publishing
        // it would put a synthetic test episode into the menu bar under a
        // process XCTest is about to kill.
        let hostsTests = WiltedMacModel.hostsTests
        let ownsSystemPlayback = !hostsTests && !WiltedMacModel.isFixtureLaunch(arguments: arguments)
        let model = WiltedMacModel(
            arguments: arguments,
            // Hosted XCTest launches this composition root against the
            // owner's normal library. Tests inject a fingerprint into their
            // own isolated model when exercising migration; the host must
            // never rewrite that daily-driver store or start bulk recovery.
            // Resolution is deliberately not forced here. It memory-maps the
            // worker and hashes two Python source trees; doing that in `init`
            // put it on the main thread ahead of the first frame. The model
            // awaits this at its fingerprint step instead.
            pipelineFingerprintResolution: Self.pipelineFingerprintResolutionForLaunch(
                hostsTests: hostsTests
            ),
            nowPlayingSink: ownsSystemPlayback ? MediaPlayerNowPlayingSink() : nil,
            remoteCommandSource: ownsSystemPlayback ? MediaPlayerRemoteCommandSource() : nil,
            preferences: preferences
        )
        return model
    }

    /// Hosted unit tests launch the real app bundle against temporary state.
    /// They must not activate a production migration.
    static func pipelineFingerprintForLaunch(
        hostsTests: Bool,
        resolvedFingerprint: String?
    ) -> String? {
        hostsTests ? nil : resolvedFingerprint
    }

    /// The same rule, deferred: a hosted test run resolves nothing at all, so
    /// it neither migrates the owner's store nor pays for the hash.
    static func pipelineFingerprintResolutionForLaunch(
        hostsTests: Bool
    ) -> @Sendable () async -> String? {
        if hostsTests {
            return { nil }
        }
        return { await PodcastPreparationPipeline.resolveSemanticFingerprintOffMainPath() }
    }

    @MainActor private static var didTraceFixtureSceneEvaluation = false

    @MainActor
    private static func recordFixtureSceneEvaluation() {
        guard let trace = WiltedMacAppDelegate.windowLifecycleTrace,
              !didTraceFixtureSceneEvaluation else { return }
        didTraceFixtureSceneEvaluation = true
        trace.record("scene-body-evaluated")
    }

    var body: some Scene {
        let _ = Self.recordFixtureSceneEvaluation()
        WindowGroup {
            WiltedMacRootView(model: model)
                // Scene phase reports that the windows went away, which is
                // not the same event as quitting and must not stop the audio.
                // A normal quit already drained in `applicationShouldTerminate`;
                // this remains for paths that skip it (a hosted test run).
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.willTerminateNotification
                )) { _ in
                    model.pauseForQuit()
                }
                .onAppear {
                    if WiltedMacModel.isFixtureLaunch(arguments: ProcessInfo.processInfo.arguments) {
                        Self.placeFixtureWindowOnPrimaryScreen()
                    }
                }
        }
        .commands {
            CommandGroup(after: .textEditing) {
                Button("Find…") {
                    WiltedMacAppDelegate.windowLifecycleTrace?.recordWindowLifecycle(
                        focusLarderSearch == nil ? "find-command-action-missing" : "find-command-action-present",
                        application: NSApplication.shared
                    )
                    focusLarderSearch?()
                }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(focusLarderSearch == nil)
            }
            // New opens the Add sheet (B6.2 Task 3.1); the toolbar Add button carries no shortcut of its own.
            CommandGroup(replacing: .newItem) {
                Button("Add\u{2026}") { model.presentAddSheet() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            // The sidebar is a column of the window, not a split view, so the
            // system's Toggle Sidebar has nothing to act on: this is the
            // command, with the same ⌃⌘S.
            CommandGroup(replacing: .sidebar) {
                Button(model.sidebarToggleTitle) { model.toggleSidebar() }
                    .keyboardShortcut("s", modifiers: [.control, .command])
            }
            // The accepted Clear for retained view state: forget the Feeds selection, the Larder
            // filter and search, scroll positions and drafts.
            CommandGroup(after: .sidebar) {
                Button("Clear Saved View") { model.clearNavigationState() }
                    .disabled(!model.hasRetainedNavigationState)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                // Symmetric with the checkpoint below. Hiding the app
                // checkpoints and stops the ticker, and without this a window
                // left open past the first focus dip would never tick again for
                // the rest of the process, which is the one case the ticker
                // exists for. It is idempotent and guarded on a loaded store, so
                // an early .active before bootstrap does nothing and launch
                // still starts it.
                model.startAutomationTicker()
            } else if phase == .background || phase == .inactive {
                model.checkpointForBackground()
            }
        }
    }

    /// Puts a fixture run's window wholly on the screen that owns the menu bar.
    /// WindowGroup can invoke the root view before AppKit attaches the window,
    /// so this retries on the main queue for at most five seconds.
    @MainActor
    private static func placeFixtureWindowOnPrimaryScreen(attemptsRemaining: Int = 100) {
        guard let window = NSApplication.shared.windows.first,
              let screen = NSScreen.screens.first else {
            guard attemptsRemaining > 0 else {
                WiltedMacAppDelegate.windowLifecycleTrace?.recordWindowLifecycle(
                    "fixture-placement-exhausted", application: NSApplication.shared
                )
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) {
                Self.placeFixtureWindowOnPrimaryScreen(attemptsRemaining: attemptsRemaining - 1)
            }
            return
        }

        let visible = screen.visibleFrame
        var frame = window.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin = CGPoint(
            x: visible.midX - frame.width / 2,
            y: visible.midY - frame.height / 2
        )
        window.setFrame(frame, display: true)
        WiltedMacAppDelegate.windowLifecycleTrace?.recordWindowLifecycle(
            "fixture-placement-succeeded", application: NSApplication.shared
        )
    }
}
