import AppIntents
import Foundation
import WiltedLibrary

/// A speed Siri can be asked for. An App Shortcut phrase may only carry an `AppEnum` or `AppEntity`
/// parameter, so the speeds the player offers (`LibraryPlayer.rates`) are cases here. The raw value is
/// hundredths, the planner's `supportedSpeeds` and `LibraryPlayer.rates` are kept equal by a test.
enum SpeedOption: Int, AppEnum, CaseIterable {
    case threeQuarters = 75
    case normal = 100
    case oneAndAQuarter = 125
    case oneAndAHalf = 150
    case oneAndThreeQuarters = 175
    case double = 200

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Speed")
    static let caseDisplayRepresentations: [SpeedOption: DisplayRepresentation] = [
        .threeQuarters: DisplayRepresentation(title: "0.75", synonyms: ["three quarters", "point seven five"]),
        .normal: DisplayRepresentation(title: "1", synonyms: ["normal", "regular", "one times"]),
        .oneAndAQuarter: DisplayRepresentation(title: "1.25", synonyms: ["one and a quarter", "one point two five"]),
        .oneAndAHalf: DisplayRepresentation(title: "1.5", synonyms: ["one and a half", "one point five"]),
        .oneAndThreeQuarters: DisplayRepresentation(title: "1.75", synonyms: ["one and three quarters", "one point seven five"]),
        .double: DisplayRepresentation(title: "2", synonyms: ["double", "twice"]),
    ]

    var rate: Double { Double(rawValue) / 100 }
}

/// A sleep timer length, the end of the episode, or off. Presets, because phrases cannot carry a free number.
enum SleepTimerOption: Int, AppEnum, CaseIterable {
    case off = 0
    case endOfEpisode = -1
    case five = 5
    case ten = 10
    case fifteen = 15
    case twenty = 20
    case thirty = 30
    case fortyFive = 45
    case sixty = 60
    case ninety = 90

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Sleep timer")
    // Titles read after "Put Wilted to sleep ...", so the spoken form is a whole phrase.
    static let caseDisplayRepresentations: [SleepTimerOption: DisplayRepresentation] = [
        .off: DisplayRepresentation(title: "off", synonyms: ["cancel", "stop", "none"]),
        .endOfEpisode: DisplayRepresentation(
            title: "at the end of the episode",
            synonyms: ["end of episode", "at the end of this episode", "after this episode", "when this episode ends"]),
        .five: DisplayRepresentation(title: "in 5 minutes", synonyms: ["5 minutes", "five minutes"]),
        .ten: DisplayRepresentation(title: "in 10 minutes", synonyms: ["10 minutes", "ten minutes"]),
        .fifteen: DisplayRepresentation(title: "in 15 minutes", synonyms: ["15 minutes", "fifteen minutes"]),
        .twenty: DisplayRepresentation(title: "in 20 minutes", synonyms: ["20 minutes", "twenty minutes"]),
        .thirty: DisplayRepresentation(title: "in 30 minutes", synonyms: ["30 minutes", "thirty minutes", "half an hour"]),
        .fortyFive: DisplayRepresentation(title: "in 45 minutes", synonyms: ["45 minutes", "forty five minutes"]),
        .sixty: DisplayRepresentation(title: "in 60 minutes", synonyms: ["60 minutes", "an hour", "in an hour", "one hour"]),
        .ninety: DisplayRepresentation(title: "in 90 minutes", synonyms: ["90 minutes", "an hour and a half"]),
    ]

    var request: VoiceSleepTimer {
        switch self {
        case .off: .off
        case .endOfEpisode: .endOfEpisode
        default: .minutes(rawValue)
        }
    }
}

struct TimeLeftIntent: AppIntent {
    static let title: LocalizedStringResource = "How much is left"
    static let description = IntentDescription("Says how much of the playing episode is left, at the current speed.")
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog { try await speak(.timeLeft) }
}

struct SetSpeedIntent: AppIntent {
    static let title: LocalizedStringResource = "Set speed"
    static let description = IntentDescription("Sets the playback speed, now and for the episodes that follow.")

    @Parameter(title: "Speed") var speed: SpeedOption

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        try await speak(.setSpeed(speed.rate))
    }
}

struct SleepTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Sleep"
    static let description = IntentDescription("Pauses playback after 5 to 90 minutes or at the end of the episode, or turns the sleep off.")

    // Off by default so the phrases that name no time ("Cancel the Wilted sleep") cancel it.
    @Parameter(title: "When", default: .off) var option: SleepTimerOption

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        try await speak(.sleepTimer(option.request))
    }
}
