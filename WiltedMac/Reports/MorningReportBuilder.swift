import CryptoKit
import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedProducer

/// One forecast period as the script reads it.
struct MorningReportForecastPeriod: Equatable, Sendable {
    let name: String
    let text: String
}

/// The recent news the builder may read: whether any feed is marked news, and the newest-first titles.
struct MorningReportHeadlines: Equatable, Sendable {
    var hasNewsFeeds: Bool
    var titles: [String]
}

/// What one build did.
enum MorningReportOutcome: Equatable, Sendable {
    case published(itemID: ItemID, title: String, durationSeconds: Double, headlineCount: Int, retired: [ItemID])
    /// No report was published; the previous one stays. `reason` is shown in Settings.
    case skipped(reason: String)
}

/// Where a build is, for the Mac activity area.
struct MorningReportProgress: Equatable, Sendable {
    let fraction: Double
    let detail: String
}

/// Builds the spoken morning report: today's forecast, then recent headlines from news feeds,
/// synthesized through the speech daemon and saved as a queued `report` item.
///
/// Length rule (300 s): headlines are trimmed until the estimate is under the limit; the real
/// duration (sample count over sample rate) is then checked, and an overlong result drops the last
/// headline and synthesizes again, at most three attempts. After that the forecast shrinks to its
/// first period for one more attempt. If it is still too long nothing is published and the previous
/// report stays.
struct MorningReportBuilder: Sendable {
    typealias Forecast = @Sendable (_ latitude: Double, _ longitude: Double) async throws -> [MorningReportForecastPeriod]
    typealias Coordinates = @Sendable () async -> (latitude: Double, longitude: Double)?
    typealias HeadlineSource = @Sendable (_ publishedSince: Date) async throws -> MorningReportHeadlines

    static let maximumSeconds = 300.0
    static let maximumHeadlines = 5
    static let maximumAttempts = 3
    /// Headlines older than this before the build are left out.
    static let headlineWindow: TimeInterval = 3600
    /// Spoken pace used only to estimate length before synthesizing (about 156 words a minute).
    static let wordsPerSecond = 2.6
    /// Conservative speech rate in characters, so text with few or no spaces still estimates long.
    static let charactersPerSecond = 20.0
    /// Bounds on untrusted text before it reaches the script: a headline title, a forecast period's
    /// name and text, the number of forecast periods, and the assembled script.
    static let maximumTitleCharacters = 1000
    static let maximumPeriodNameCharacters = 100
    static let maximumPeriodTextCharacters = 1500
    static let maximumPeriods = 14
    static let maximumScriptCharacters = 6000

    let store: LocalLibraryStore
    let synthesize: BookConversion.Synthesizer
    let coordinates: Coordinates
    let forecast: Forecast
    let headlines: HeadlineSource
    let calendar: Calendar
    /// Test seam: runs after the already-saved pre-check and before media is written, so a test can
    /// make two builds both pass the pre-check.
    let afterPrecheck: @Sendable () async -> Void

    init(
        store: LocalLibraryStore,
        synthesize: @escaping BookConversion.Synthesizer = BookConversion.daemonSynthesizer,
        coordinates: @escaping Coordinates,
        forecast: @escaping Forecast,
        headlines: HeadlineSource? = nil,
        calendar: Calendar = .current,
        afterPrecheck: @escaping @Sendable () async -> Void = {}
    ) {
        self.store = store
        self.synthesize = synthesize
        self.coordinates = coordinates
        self.forecast = forecast
        self.headlines = headlines ?? { since in try await Self.storeHeadlines(store, since: since) }
        self.calendar = calendar
        self.afterPrecheck = afterPrecheck
    }

    // MARK: Script

    /// The text to speak. Pure, so length rules are testable without audio.
    static func script(
        date: Date, calendar: Calendar, forecast: [MorningReportForecastPeriod]?, headlines: [String],
        hasNewsFeeds: Bool, weatherMissing: String = "the forecast is not available"
    ) -> String {
        let forecast = forecast.map { periods in
            periods.prefix(maximumPeriods).map {
                MorningReportForecastPeriod(
                    name: String($0.name.prefix(maximumPeriodNameCharacters)), text: String($0.text.prefix(maximumPeriodTextCharacters)))
            }
        }
        let headlines = headlines.map { String($0.prefix(maximumTitleCharacters)) }
        var parts = ["Good morning. Here is your report for \(dayText(date, calendar: calendar))."]
        if let forecast, !forecast.isEmpty {
            parts.append("The weather. " + forecast.map { "\($0.name): \($0.text)" }.joined(separator: " "))
        } else {
            parts.append("The weather is not included, because \(weatherMissing).")
        }
        if !hasNewsFeeds {
            parts.append("No news feeds are set up, so there are no headlines.")
        } else if headlines.isEmpty {
            parts.append("There are no new headlines.")
        } else {
            parts.append("The headlines. " + headlines.map { $0.hasSuffix(".") ? $0 : $0 + "." }.joined(separator: " "))
        }
        return String(parts.joined(separator: " ").prefix(maximumScriptCharacters))
    }

    /// Estimated speaking time of `text` in seconds.
    static func estimatedSeconds(_ text: String) -> Double {
        max(Double(text.split(whereSeparator: \.isWhitespace).count) / wordsPerSecond, Double(text.count) / charactersPerSecond)
    }

    static func title(for date: Date, calendar: Calendar) -> String { "Morning report, \(dayText(date, calendar: calendar, weekday: false))" }

    private static func dayText(_ date: Date, calendar: Calendar, weekday: Bool = true) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = weekday ? "EEEE, MMMM d" : "MMMM d"
        return formatter.string(from: date)
    }

    // MARK: Build

    /// Builds and publishes one report. Never throws: every failure becomes `.skipped(reason:)`.
    func build(
        now: Date = Date(), progress: @escaping @Sendable (MorningReportProgress) -> Void = { _ in }
    ) async -> MorningReportOutcome {
        func report(_ fraction: Double, _ detail: String) { progress(MorningReportProgress(fraction: fraction, detail: detail)) }
        do {
            report(0.02, "Gathering the forecast")
            var forecastPeriods: [MorningReportForecastPeriod]?
            var missing: [String] = []
            if let place = await coordinates() {
                do { forecastPeriods = try await forecast(place.latitude, place.longitude) } catch is CancellationError {
                    throw CancellationError()
                } catch { missing.append("the forecast could not be fetched") }
            } else {
                missing.append("no location is set")
            }
            try Task.checkCancellation()
            report(0.1, "Gathering headlines")
            let news = try await headlines(now.addingTimeInterval(-Self.headlineWindow))
            if forecastPeriods == nil, !news.hasNewsFeeds {
                return .skipped(reason: "No report built: \(missing.first ?? "no forecast"), and no news feeds are set up.")
            }
            var titles = Array(news.titles.prefix(Self.maximumHeadlines))
            let full = forecastPeriods
            func script(_ forecast: [MorningReportForecastPeriod]?) -> String {
                Self.script(date: now, calendar: calendar, forecast: forecast, headlines: titles, hasNewsFeeds: news.hasNewsFeeds,
                    weatherMissing: missing.first ?? "the forecast is not available")
            }
            while !titles.isEmpty, Self.estimatedSeconds(script(full)) >= Self.maximumSeconds { titles.removeLast() }

            var text = script(full)
            var attempt = 0
            var lastSeconds = 0.0
            var shortened = false
            while true {
                try Task.checkCancellation()
                attempt += 1
                report(0.15 + 0.6 * Double(min(attempt, 4)) / 4, "Speaking the report (attempt \(attempt))")
                let spoken = text
                let speech = try await Self.blocking { [synthesize] in try synthesize(spoken, { Task.isCancelled }) }
                guard speech.sampleRate > 0, !speech.samples.isEmpty else {
                    return .skipped(reason: "No report built: the speech engine returned no audio.")
                }
                lastSeconds = Double(speech.samples.count) / Double(speech.sampleRate)
                if lastSeconds <= Self.maximumSeconds {
                    return try await publish(speech, text: text, now: now, headlineCount: titles.count, report: report)
                }
                if !shortened {
                    if attempt < Self.maximumAttempts, !titles.isEmpty {
                        titles.removeLast()
                    } else if let full, full.count > 1 {
                        shortened = true
                    } else {
                        break
                    }
                } else {
                    break
                }
                text = script(shortened ? full.map { Array($0.prefix(1)) } : full)
            }
            return .skipped(reason: "No report published: the audio ran \(Int(lastSeconds.rounded())) s, over the "
                + "\(Int(Self.maximumSeconds)) s limit. The previous report stays.")
        } catch is CancellationError {
            return .skipped(reason: "The report was cancelled.")
        } catch {
            return .skipped(reason: "No report published: \(error.localizedDescription)")
        }
    }

    private func publish(
        _ speech: SpeechSynthesisResult, text: String, now: Date, headlineCount: Int,
        report: (Double, String) -> Void
    ) async throws -> MorningReportOutcome {
        report(0.8, "Saving the audio")
        let day = Self.dayText(now, calendar: calendar)
        let itemID = try LocalLibraryStore.reportItemID(script: text, day: day)
        // A report already saved for this ID stays; writing media for it would leave an unreferenced file.
        if try await store.hasMorningReport(itemID) {
            return .skipped(reason: "Today's report was already built; it stays.")
        }
        await afterPrecheck()
        let media = store.mediaDirectory
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let destination = media.appendingPathComponent("report-\(itemID.rawValue)-\(UUID().uuidString).m4a")
        store.inFlightMedia.begin(destination)
        defer { store.inFlightMedia.end(destination) }
        var saved = false
        defer { if !saved { try? FileManager.default.removeItem(at: destination) } }
        let samples = speech.samples, rate = speech.sampleRate
        let duration = try await Self.blocking { try MorningReportAudio.write(samples: samples, sampleRate: rate, to: destination) }
        let size = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        let hash = try MediaHash.sha256Hex(fileAt: destination)
        let textHash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        let createdAt = now
        let revision = try AudioRevision(
            itemID: itemID,
            revisionID: RevisionID.derive(
                extractedTextSHA256: textHash, voiceID: BookConversion.daemonDefaultVoice, synthesisSettingsCanonicalJSON: "{}",
                audioFormatCanonicalJSON: "{\"container\":\"m4a\",\"source\":\"morning-report\"}"),
            durationSeconds: duration, byteCount: size, contentHash: "sha256:\(hash)",
            mediaType: AudioAssembler.mediaType, createdAt: Timestamp(createdAt), schemaVersion: 1)
        let title = Self.title(for: now, calendar: calendar)
        report(0.92, "Adding to the library")
        let outcome = try await store.saveMorningReport(MorningReportSave(
            itemID: itemID, revision: revision, mediaURL: destination, title: title, createdAt: createdAt))
        // A concurrent build saved this ID first: the deferred cleanup deletes the file just written.
        guard case .saved(let retired) = outcome else {
            return .skipped(reason: "Today's report was already built; it stays.")
        }
        saved = true
        report(1, "Report ready")
        return .published(itemID: itemID, title: title, durationSeconds: duration, headlineCount: headlineCount, retired: retired)
    }

    // MARK: Headlines

    /// Titles of articles from news feeds published since `cutoff`, newest first.
    static func storeHeadlines(_ store: LocalLibraryStore, since cutoff: Date) async throws -> MorningReportHeadlines {
        let snapshot = try await store.podcastLibrarySnapshot()
        var news = Set<ItemID>()
        for feed in snapshot.articleFeeds where try await store.isNews(feedID: feed.itemID) { news.insert(feed.itemID) }
        let fresh = snapshot.articles.filter { article in
            !article.isDeleted && snapshot.feedIDByArticle[article.itemID].map(news.contains) == true
                && (article.publishedTime ?? article.createdAt).date >= cutoff
        }.sorted { ($0.publishedTime ?? $0.createdAt).date > ($1.publishedTime ?? $1.createdAt).date }
        return MorningReportHeadlines(hasNewsFeeds: !news.isEmpty, titles: fresh.map(\.title))
    }

    // MARK: Helpers

    private static func blocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached { try work() }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
