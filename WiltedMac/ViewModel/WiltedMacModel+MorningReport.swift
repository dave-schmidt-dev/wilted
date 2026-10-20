import Foundation
import Observation
import ObjectiveC
import OSLog

#if canImport(WiltedProducer)
import WiltedProducer
import WiltedWeather

/// When a report is due. Wilted only runs while open, so a run missed because the Mac slept or
/// the app was closed is made up if it is still within two hours of its time.
enum MorningReportSchedule {
    static let missedRunWindow: TimeInterval = 2 * 3600

    /// Today's scheduled moment for `time`, in the calendar's time zone.
    static func scheduledDate(on day: Date, at time: WiltedAutomationLocalTime, calendar: Calendar) -> Date? {
        calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day)
    }

    /// The day key stored once a run for that day has started.
    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Due when today's time has passed, no more than two hours ago, and today has not run yet.
    static func isDue(now: Date, time: WiltedAutomationLocalTime, lastRunDay: String?, calendar: Calendar) -> Bool {
        guard let scheduled = scheduledDate(on: now, at: time, calendar: calendar) else { return false }
        let elapsed = now.timeIntervalSince(scheduled)
        return elapsed >= 0 && elapsed <= missedRunWindow && lastRunDay != dayKey(now, calendar: calendar)
    }
}

/// What the Mac activity area and Settings show about the report.
enum WiltedMorningReportState: Equatable, Sendable {
    case idle
    case building(fraction: Double, detail: String)
    case published(title: String, at: Date)
    /// No report was published; `reason` is shown in Settings and the previous report stays.
    case notPublished(reason: String)

    var isBuilding: Bool {
        if case .building = self { return true }
        return false
    }

    /// The one Settings line under the daily report; nil before any run this launch.
    func caption(timeStyle: (Date) -> String = { $0.formatted(date: .abbreviated, time: .shortened) }) -> String? {
        switch self {
        case .idle: nil
        case let .building(fraction, detail): "Building… \(Int((fraction * 100).rounded()))% \(detail)"
        case let .published(_, at): "Last report: \(timeStyle(at))"
        case let .notPublished(reason): reason
        }
    }

    /// Build now needs the daily report on and no run in progress.
    static func buildNowDisabled(state: WiltedMorningReportState, reportEnabled: Bool) -> Bool {
        state.isBuilding || !reportEnabled
    }

    /// The Build now button's help text: why it is disabled, or what it does.
    static func buildNowHelp(state: WiltedMorningReportState, reportEnabled: Bool) -> String {
        if !reportEnabled { return "Turn on Daily report first" }
        if state.isBuilding { return "A report is being built" }
        return "Build today's report now"
    }
}

/// Runs the schedule while the app is open and holds the state. Owned by the model through an
/// associated object, so it ends with the model.
@MainActor
@Observable
final class WiltedMorningReportController {
    static let lastRunPreferenceKey = "wilted.morningReport.lastRunDay"
    static let tickSeconds: UInt64 = 60

    private(set) var state: WiltedMorningReportState = .idle
    @ObservationIgnored private weak var model: WiltedMacModel?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var running = false
    @ObservationIgnored private let logger = Logger(subsystem: "com.zerodelta.wilted.mac", category: "MorningReport")

    init(model: WiltedMacModel) { self.model = model }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: Self.tickSeconds * 1_000_000_000)
            }
        }
    }

    func stop() { loop?.cancel(); loop = nil }

    private func tick() async {
        guard let model, !running, model.automationSettings.reportEnabled else { return }
        let calendar = Calendar.current
        let now = Date()
        guard MorningReportSchedule.isDue(
            now: now, time: model.automationSettings.reportTime,
            lastRunDay: model.preferences.string(forKey: Self.lastRunPreferenceKey), calendar: calendar) else { return }
        await buildNow(now: now)
    }

    /// Builds one report now. The day is marked first, so a skipped run is not retried all window.
    func buildNow(now: Date = Date()) async {
        guard let model, !running else { return }
        guard let store = model.store else {
            state = .notPublished(reason: "No report built: the library is not open.")
            return
        }
        running = true
        defer { running = false }
        let calendar = Calendar.current
        model.preferences.set(MorningReportSchedule.dayKey(now, calendar: calendar), forKey: Self.lastRunPreferenceKey)
        state = .building(fraction: 0, detail: "Starting the morning report")
        let contact = model.automationSettings.nwsContact
        let location = model.bulletinHub.location
        let builder = MorningReportBuilder(
            store: store,
            coordinates: { await MainActor.run {
                location.coordinates.map { ($0.latitude, $0.longitude) }
            } },
            forecast: { latitude, longitude in
                let client = NWSClient(
                    appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
                    repositoryURL: "https://github.com/dave-schmidt-dev/wilted", contact: contact)
                return Self.todaysPeriods(try await client.forecast(lat: latitude, lon: longitude))
            },
            calendar: calendar)
        let outcome = await builder.build(now: now) { [weak self] step in
            Task { @MainActor in
                if case .building = self?.state { self?.state = .building(fraction: step.fraction, detail: step.detail) }
            }
        }
        switch outcome {
        case let .published(_, title, seconds, headlines, _):
            logger.info("report published: \(Int(seconds)) s, \(headlines) headlines")
            state = .published(title: title, at: now)
            await model.reloadLibraryRows()
        case let .skipped(reason):
            logger.notice("report not published: \(reason, privacy: .public)")
            state = .notPublished(reason: reason)
        }
    }

    /// Today's periods: through the first night period (all of them when there is none).
    nonisolated static func todaysPeriods(_ periods: [NWSForecastPeriod]) -> [MorningReportForecastPeriod] {
        let end = periods.firstIndex { !$0.isDaytime }.map { $0 + 1 } ?? periods.count
        return periods.prefix(end).map { MorningReportForecastPeriod(name: $0.name, text: $0.detailedForecast) }
    }
}

nonisolated(unsafe) private var morningReportControllerKey: UInt8 = 0

extension WiltedMacModel {
    var morningReport: WiltedMorningReportController {
        if let existing = objc_getAssociatedObject(self, &morningReportControllerKey) as? WiltedMorningReportController {
            return existing
        }
        let controller = WiltedMorningReportController(model: self)
        objc_setAssociatedObject(self, &morningReportControllerKey, controller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return controller
    }

    /// Starts the morning report schedule; called once the library store is open.
    func startMorningReportSchedule() { morningReport.start() }
}
#endif
