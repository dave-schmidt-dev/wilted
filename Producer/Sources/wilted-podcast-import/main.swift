import Foundation
import WiltedDomain
import WiltedProducer

// Brings an Apple Podcasts library's subscriptions into a Wilted library store.
//
// Nothing personal is compiled in: every feed URL and episode identity is read
// at run time from the Apple Podcasts database the operator points at. The tool
// downloads no media. It writes feeds, subscriptions, and the seed episodes the
// listener has not finished with, then prints a report of exactly what it did.

struct Options {
    var storeURL: URL?
    var sourceURL = ApplePodcastsLibrary.defaultURL
    var dryRun = false
    var reportURL: URL?
}

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: wilted-podcast-import --store <library.sqlite> [--source <MTLibrary.sqlite>]
                                 [--dry-run] [--report <path>]

      --store    Wilted library store to write. Quit Wilted first.
      --source   Apple Podcasts database to read. Defaults to the group container.
      --dry-run  Load and report every feed without writing to the store.
      --report   Write the report to this path as well as stdout.

    """.utf8))
    exit(2)
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())
    while let argument = arguments.first {
        arguments.removeFirst()
        func value(_ name: String) -> String {
            guard let next = arguments.first else {
                FileHandle.standardError.write(Data("missing value for \(name)\n".utf8))
                usage()
            }
            arguments.removeFirst()
            return next
        }
        switch argument {
        case "--store": options.storeURL = URL(fileURLWithPath: value("--store"))
        case "--source": options.sourceURL = URL(fileURLWithPath: value("--source"))
        case "--report": options.reportURL = URL(fileURLWithPath: value("--report"))
        case "--dry-run": options.dryRun = true
        case "-h", "--help": usage()
        default:
            FileHandle.standardError.write(Data("unknown argument: \(argument)\n".utf8))
            usage()
        }
    }
    if !options.dryRun && options.storeURL == nil { usage() }
    return options
}

struct FeedOutcome {
    let title: String
    let feedURL: String
    var status = "ok"
    var detail = ""
    var episodesInFeed = 0
    var undatedInFeed = 0
    var droppedByCeiling = 0
    var seedRequested = 0
    var seedMatched = 0
    var seedRebuilt = 0
    var seedUnavailable: [String] = []
    var playedSkipped = 0
}

func render(_ outcomes: [FeedOutcome], dryRun: Bool) -> String {
    func total(_ keyPath: KeyPath<FeedOutcome, Int>) -> Int {
        outcomes.reduce(0) { $0 + $1[keyPath: keyPath] }
    }
    var lines = ["# Wilted podcast import\(dryRun ? " (dry run)" : "")", ""]
    lines.append("| Feed | Status | Feed episodes | Undated | Dropped | Seeded | Rebuilt | Wanted | Played skipped | Feed URL |")
    lines.append("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    for outcome in outcomes {
        lines.append("| \(outcome.title.replacingOccurrences(of: "|", with: "\\|")) | \(outcome.status) "
            + "| \(outcome.episodesInFeed) | \(outcome.undatedInFeed) | \(outcome.droppedByCeiling) "
            + "| \(outcome.seedMatched) | \(outcome.seedRebuilt) | \(outcome.seedRequested) "
            + "| \(outcome.playedSkipped) | `\(outcome.feedURL)` |")
    }
    let loaded = outcomes.filter { $0.status == "ok" }
    let unavailable = outcomes.flatMap(\.seedUnavailable)
        + outcomes.filter { $0.status != "ok" }.flatMap { outcome in
            (0..<outcome.seedRequested).map { _ in outcome.title }
        }
    lines.append("")
    lines.append("- feeds: \(outcomes.count), loaded: \(loaded.count), not loaded: \(outcomes.count - loaded.count)")
    lines.append("- seed episodes wanted: \(total(\.seedRequested)), matched in the feed: \(total(\.seedMatched))"
        + ", rebuilt from Apple: \(total(\.seedRebuilt)), unavailable: \(unavailable.count)")
    lines.append("- already played, deliberately skipped: \(total(\.playedSkipped))")
    lines.append("- undated feed episodes: \(total(\.undatedInFeed))"
        + ", back-catalogue episodes past the feed ceiling: \(total(\.droppedByCeiling))")
    lines.append("- media downloaded: 0 (this tool never downloads audio)")
    for outcome in outcomes where outcome.status != "ok" {
        lines.append("- \(outcome.title): \(outcome.status) \(outcome.detail)")
    }
    for title in outcomes.flatMap(\.seedUnavailable) { lines.append("- unavailable episode: \(title)") }
    return lines.joined(separator: "\n") + "\n"
}

let options = parseOptions()
let appleFeeds: [ApplePodcastsLibrary.Feed]
do { appleFeeds = try ApplePodcastsLibrary.read(at: options.sourceURL) }
catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}

var store: LocalLibraryStore?
if let storeURL = options.storeURL {
    do { store = try LocalLibraryStore(url: storeURL) }
    catch {
        FileHandle.standardError.write(Data("cannot open the Wilted store: \(error)\n".utf8))
        exit(1)
    }
}

let client = PodcastFeedClient()
var outcomes: [FeedOutcome] = []

for feed in appleFeeds {
    var outcome = FeedOutcome(title: feed.title, feedURL: feed.feedURL)
    outcome.seedRequested = feed.unfinished.count
    outcome.playedSkipped = feed.playedCount

    guard let url = URL(string: feed.feedURL), url.scheme?.lowercased() == "https", url.host != nil else {
        outcome.status = "skipped"
        outcome.detail = "Apple Podcasts holds no public feed URL for it"
        outcomes.append(outcome)
        FileHandle.standardError.write(Data("import.feed name=\(feed.title) status=skipped\n".utf8))
        continue
    }

    FileHandle.standardError.write(Data("import.feed name=\(feed.title) status=loading\n".utf8))
    do {
        let loaded = try await client.load(url)
        outcome.episodesInFeed = loaded.episodes.count
        outcome.undatedInFeed = loaded.episodes.filter { $0.publishedTime == nil }.count
        outcome.droppedByCeiling = loaded.droppedEpisodeCount

        let wanted = Set(feed.unfinished.map(\.guid))
        var seeds = loaded.episodes.filter { $0.rssGUID.map(wanted.contains) == true }
        outcome.seedMatched = seeds.count

        // Whatever the feed no longer carries is rebuilt from Apple's own row,
        // so a bonus item or an episode past the publisher's window is not
        // silently lost.
        let matched = Set(seeds.compactMap(\.rssGUID))
        for episode in feed.unfinished where !matched.contains(episode.guid) {
            do {
                seeds.append(try ApplePodcastsLibrary.rebuild(episode, into: loaded.feed, createdAt: Date()))
                outcome.seedRebuilt += 1
            } catch {
                outcome.seedUnavailable.append(episode.title)
            }
        }

        if let store, !options.dryRun {
            try await store.save(feed: loaded.feed)
            try await store.save(subscription: PodcastSubscription(
                feedID: loaded.feed.itemID, subscribedAt: Timestamp(Date()), enabled: true
            ))
            for episode in seeds { try await store.save(episode: episode) }
        }
    } catch {
        outcome.status = "failed"
        outcome.detail = "\(error)"
    }
    FileHandle.standardError.write(Data("import.feed name=\(feed.title) status=\(outcome.status)\n".utf8))
    outcomes.append(outcome)
}

let report = render(outcomes, dryRun: options.dryRun)
print(report, terminator: "")
if let reportURL = options.reportURL {
    try? FileManager.default.createDirectory(
        at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try? report.write(to: reportURL, atomically: true, encoding: .utf8)
}
