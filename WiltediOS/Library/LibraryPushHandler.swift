@preconcurrency import Intents
import Foundation
import UIKit

/// The silent-push routing the runtime needs. `LibraryPushHandler` is the production implementation;
/// tests hand the runtime a fake to count attachments and drive an early push.
@MainActor
protocol LibraryPushHandling: AnyObject {
    /// Installs the fetch to run on a silent push; replays one that arrived early.
    func attach(_ onSilentPush: @escaping @MainActor () async -> Bool)
    /// Runs the fetch a silent push asks for and reports whether anything changed.
    func receiveSilentPush() async -> UIBackgroundFetchResult
}

/// Routes silent CloudKit pushes to the library model.
///
/// The app root attaches the delegate with
/// `@UIApplicationDelegateAdaptor(LibraryPushAppDelegate.self)`; that is what lets a
/// SwiftUI app register for remote notifications and receive `didReceiveRemoteNotification`.
/// A push that lands before `LibraryRoot` has attached is remembered and replayed on attach.
@MainActor
final class LibraryPushHandler: LibraryPushHandling {
    static let shared = LibraryPushHandler()

    private var onSilentPush: (@MainActor () async -> Bool)?
    private var pushWaiting = false

    /// Installs the fetch to run on a silent push; replays one that arrived early.
    func attach(_ onSilentPush: @escaping @MainActor () async -> Bool) {
        self.onSilentPush = onSilentPush
        guard pushWaiting else { return }
        pushWaiting = false
        Task { _ = await onSilentPush() }
    }

    /// Runs the fetch a silent push asks for and reports whether anything changed.
    func receiveSilentPush() async -> UIBackgroundFetchResult {
        guard let onSilentPush else {
            pushWaiting = true
            return .noData
        }
        return await onSilentPush() ? .newData : .noData
    }
}

/// Registers for remote notifications and forwards silent pushes to `LibraryPushHandler`.
@MainActor
final class LibraryPushAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        startBackgroundEntryPoints()
        return true
    }

    /// A background launch for a silent push or a Watch message has no scene, so the shared runtime
    /// attaches its push handler and Watch session here. A fixture launch and the XCTest host keep
    /// the lazy runtime unbuilt, exactly as the rest of the launch path does.
    private func startBackgroundEntryPoints() {
        guard NSClassFromString("XCTestCase") == nil else { return }
        #if DEBUG
        guard LibraryUITestFixture.scenario() == nil else { return }
        #endif
        LibraryRuntime.shared.bootstrapBackgroundEntryPoints()
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        await LibraryPushHandler.shared.receiveSilentPush()
    }

    /// The Intents extension answers `.handleInApp`; the app then plays the request itself, so playback
    /// runs in the app (an extension's lifespan is short), through the shared player.
    func application(
        _ application: UIApplication, handle intent: INIntent, completionHandler: @escaping (INIntentResponse) -> Void
    ) {
        guard let play = intent as? INPlayMediaIntent else {
            completionHandler(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
            return
        }
        nonisolated(unsafe) let complete = completionHandler
        Task { complete(await PlayMediaIntentHandler().handle(intent: play)) }
    }

    /// SiriKit media requests are also handled in the app itself when no extension is in the way.
    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        intent is INPlayMediaIntent ? PlayMediaIntentHandler() : nil
    }
}
