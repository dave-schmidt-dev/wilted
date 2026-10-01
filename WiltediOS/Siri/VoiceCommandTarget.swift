import Foundation
import WiltedLibrary

/// How far a performed action got. `queued` is for a Mac-side decision that could not be sent yet and
/// will be retried: true, but not done, so Siri must not say it is.
enum VoiceOutcome: Equatable {
    case done, queued, failed
}

/// What a voice command needs from the app: a snapshot to plan against and a way to carry out
/// the planned action. The App Intent shells depend only on this, so they can be exercised
/// without a library model or audio engine.
@MainActor
protocol VoiceCommandTarget: AnyObject {
    func voiceSnapshot() async -> VoiceSnapshot
    /// Carries out `action` and reports how far it got, so Siri never announces a success
    /// that did not happen.
    func perform(_ action: VoiceAction) async -> VoiceOutcome
}

/// Where the intents find the running app's target. By default it prepares the shared runtime (offline, never waits on a sync), which is the
/// same model, transport and player the phone and CarPlay use, and adapts it; tests replace
/// `provider` with a fake.
@MainActor
enum VoiceRuntime {
    static var provider: @MainActor () async -> (any VoiceCommandTarget)? = {
        let runtime = LibraryRuntime.shared
        await runtime.prepare()
        return LibraryVoiceTarget(model: runtime.model, player: runtime.player)
    }

    static func target() async -> (any VoiceCommandTarget)? { await provider() }
}

/// Plans a command and, unless it needs a confirmation the person declines, carries it out.
@MainActor
enum VoiceCommandRunner {
    static let unavailableDialog = "Open Wilted once, then try again."
    static let completedDialog = "Marked completed."
    static let queuedDialog = "Queued. It will go to your Mac when it's reachable."
    static let failedDialog = "That didn't work."

    /// Returns the line to speak. `confirm` is asked only for actions that need it and throws to
    /// decline; nothing has been performed by then.
    static func run(
        _ command: VoiceCommand,
        on target: (any VoiceCommandTarget)?,
        confirm: (String) async throws -> Void
    ) async throws -> String {
        guard let target else { return unavailableDialog }
        let plan = VoiceCommandPlanner.plan(command, snapshot: await target.voiceSnapshot())
        if plan.needsConfirmation {
            try await confirm(plan.dialog)
            switch await target.perform(plan.action) {
            case .done: return completedDialog
            case .queued: return queuedDialog
            case .failed: return failedDialog
            }
        }
        return await target.perform(plan.action) == .failed ? failedDialog : plan.dialog
    }
}
