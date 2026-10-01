@preconcurrency import Intents

/// The Intents extension's entry point: spoken play requests ("Hey Siri", the car's Siri button) come
/// through `INPlayMediaIntent`; every request is handed to the app, which owns the downloaded episodes
/// and the player. The car screen shows no Siri button (no assistant cell is configured).
final class IntentHandler: INExtension {
    override func handler(for intent: INIntent) -> Any {
        intent is INPlayMediaIntent ? PlayMediaExtensionHandler() : self
    }
}
