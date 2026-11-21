import Foundation

/// A sender that, on every request, reads the chosen provider from preferences,
/// creates the matching sender via `LabellerSenderFactory.make` using that provider's
/// own key slot, and sends.
///
/// Changes to provider preferences take effect on the next request without app relaunch.
/// If a command-line tool is unavailable or unusable, throws
/// `LabellerFailure.commandLineToolUnavailable(provider:)` so nothing is sent and the
/// pipeline reports the plain reason. It never falls back to another provider.
public struct ConfiguredLabellerSender: LabellerSending {
    public typealias Factory = @Sendable (AdLabellerProvider) throws -> any LabellerSending

    public let preferences: AdLabellerPreferences
    public let keyStore: (any LabellerKeyStoring)?
    private let factory: Factory

    public init(
        preferences: AdLabellerPreferences,
        keyStore: (any LabellerKeyStoring)? = nil,
        factory: (@Sendable (AdLabellerProvider) throws -> any LabellerSending)? = nil
    ) {
        self.preferences = preferences
        self.keyStore = keyStore
        if let factory {
            self.factory = factory
        } else {
            self.factory = { provider in
                try LabellerSenderFactory.make(provider: provider, keyStore: keyStore)
            }
        }
    }

    public func send(
        _ request: LabellerRequest,
        onRequestStarted: @escaping @Sendable () -> Void,
        onProgress: @escaping @Sendable (LabellerProgress) -> Void
    ) async throws -> LabellerResponse {
        let provider = preferences.provider
        guard preferences.isAcknowledged(provider) else {
            throw LabellerFailure.providerNotAccepted(provider: provider)
        }
        let sender: any LabellerSending
        do {
            sender = try factory(provider)
        } catch let refusal as LabellerCommandLineRefusal {
            throw LabellerFailure.commandLineToolUnavailable(provider: refusal.provider)
        }
        return try await sender.send(request, onRequestStarted: onRequestStarted, onProgress: onProgress)
    }
}
