import AppKit
import Foundation
import Observation
import os

/// The model the app's one window shows. A normal launch builds one and keeps
/// it for the life of the process; only a UI-test fixture session replaces it.
@MainActor
@Observable
final class WiltedMacModelHost {
    private(set) var model: WiltedMacModel
    /// Changes with each replacement, so the window rebuilds its view state
    /// instead of carrying the previous fixture's selection and sheets over.
    private(set) var generation = 0

    init(model: WiltedMacModel) { self.model = model }

    fileprivate func replace(with model: WiltedMacModel) {
        self.model = model
        generation += 1
    }
}

#if DEBUG
/// Lets one fixture launch serve every Mac UI journey, so a `make native-ui`
/// run takes the screen once instead of relaunching the app per journey.
///
/// Debug builds only, and inert unless the launch is a fixture launch that
/// names an owned session directory with `--wilted-ui-fixture-session <dir>`.
/// The runner then writes `fixture-switch-<n>.json` (`{"arguments": [...]}`)
/// into that directory; the app closes its current model the way a quit
/// drains it, builds a fresh one from those arguments, and answers with
/// `fixture-switch-<n>.ack`. Each request must name a fixture state directory
/// beside the session directory, so the hook cannot reach any other library.
///
/// When the runner names a ledger in `WILTED_UI_LAUNCH_LEDGER`, the session
/// appends one `launch` line per process and one `switch` line per fixture,
/// so the gate can prove how many times a run took the screen.
@MainActor
final class WiltedMacFixtureSession {
    static let argument = "--wilted-ui-fixture-session"
    static let ledgerVariable = "WILTED_UI_LAUNCH_LEDGER"
    private static let ledgerFilename = "wilted-ui-app-launches.jsonl"
    private static let logger = Logger(subsystem: "com.zerodelta.wilted.mac", category: "FixtureSession")
    /// The one session of this process; nil for every launch that did not ask.
    private static var current: WiltedMacFixtureSession?

    private let directory: URL
    private let host: WiltedMacModelHost
    private let ledger: WiltedMacTerminationJournal?
    private var handled = 0
    private var switching = false

    private init(directory: URL, host: WiltedMacModelHost) {
        self.directory = directory
        self.host = host
        ledger = Self.ledgerForLaunch().map { WiltedMacTerminationJournal(url: $0) }
    }

    /// Starts polling when this launch asked for a session and owns its directory.
    static func startIfRequested(arguments: [String], host: WiltedMacModelHost) {
        guard current == nil, !WiltedMacModel.hostsTests,
              WiltedMacModel.isFixtureLaunch(arguments: arguments),
              let index = arguments.firstIndex(of: argument), arguments.indices.contains(index + 1),
              let directory = ownedDirectory(URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
        else { return }
        let session = WiltedMacFixtureSession(directory: directory, host: host)
        current = session
        let pid = ProcessInfo.processInfo.processIdentifier
        session.ledger?.record("launch", values: ["pid": String(pid)])
        logger.notice("fixture session launch pid=\(pid, privacy: .public)")
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { session.poll() }
        }
        // Common modes, so a request still lands while a menu is tracking.
        RunLoop.main.add(timer, forMode: .common)
    }

    /// The runner's ledger: an absolute path to the fixed filename inside an
    /// existing canonical directory, or nil.
    private static func ledgerForLaunch() -> URL? {
        guard let path = ProcessInfo.processInfo.environment[ledgerVariable], path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let parent = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard url.lastPathComponent == ledgerFilename,
              parent == parent.resolvingSymlinksInPath().standardizedFileURL,
              FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return url
    }

    /// A canonical, existing `wilted-` directory, or nil.
    private static func ownedDirectory(_ candidate: URL) -> URL? {
        let canonical = candidate.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard canonical == candidate.resolvingSymlinksInPath().standardizedFileURL,
              canonical.lastPathComponent.hasPrefix("wilted-"),
              FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return canonical
    }

    private func poll() {
        guard !switching else { return }
        let generation = handled + 1
        let request = directory.appendingPathComponent("fixture-switch-\(generation).json")
        guard FileManager.default.fileExists(atPath: request.path) else { return }
        switching = true
        Task { @MainActor in
            let failure = await self.perform(request)
            self.acknowledge(generation, failure: failure)
            self.handled = generation
            self.switching = false
        }
    }

    /// Replaces the window's model, or returns why the request was refused.
    private func perform(_ request: URL) async -> String? {
        guard let data = try? Data(contentsOf: request),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arguments = object["arguments"] as? [String] else {
            return "the request is not a JSON object with an arguments array"
        }
        guard WiltedMacModel.isFixtureLaunch(arguments: arguments) else {
            return "the requested arguments do not describe a fixture"
        }
        guard let state = WiltedMacModel.fixtureStateDirectoryOverride(arguments: arguments),
              let owned = Self.ownedDirectory(state),
              owned.deletingLastPathComponent() == directory.deletingLastPathComponent(),
              owned != directory else {
            return "the fixture state directory must be an existing sibling of the session directory"
        }
        let previous = host.model
        // The quit path's own drain, then the fixture teardown: playback,
        // tickers, downloads and library work all stop before the next model opens.
        try? await previous.drainLocalWorkForTermination()
        await previous.closeNetworkWorkForTermination()
        await previous.close()
        WiltedMacModel.playlistWriteHookForTesting = nil
        let next = WiltedMacApp.makeLaunchModel(arguments: arguments)
        WiltedMacAppDelegate.windowLifecycleTrace = WiltedMacTerminationJournal.windowLifecycleTraceForLaunch(
            arguments: arguments, isFixture: true
        )
        WiltedMacAppDelegate.installTermination(for: next, arguments: arguments, hostsTests: false)
        host.replace(with: next)
        // A journaled fixture records its readiness the way a fresh launch does.
        WiltedMacAppDelegate.onLaunch?()
        return nil
    }

    private func acknowledge(_ generation: Int, failure: String?) {
        var answer: [String: Any] = [
            "generation": generation,
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
        ]
        if let failure { answer["error"] = failure }
        let url = directory.appendingPathComponent("fixture-switch-\(generation).ack")
        if let data = try? JSONSerialization.data(withJSONObject: answer, options: [.sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
        ledger?.record("switch", values: ["generation": String(generation), "refused": String(failure != nil)])
        Self.logger.notice(
            "fixture session switch generation=\(generation, privacy: .public) refused=\(failure != nil, privacy: .public)"
        )
    }
}
#endif
