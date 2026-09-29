import Foundation
import Observation
import SpikeCloudKit
import SpikeCore
import SwiftUI

/// Which side of the handoff probe this host plays.
enum SpikeRole: String, Sendable {
    /// Mac: publishes a playback checkpoint every 5 s.
    case publisher
    /// iPhone: subscribes for silent pushes and records what arrives.
    case observer
}

/// One planned transfer: payload size and repetition index.
struct SpikeTransferPlan: Sendable, Equatable {
    let megabytes: Int
    let repetition: Int

    /// 20, 60 and 120 MB three times each, then 250 MB once.
    static let matrix: [SpikeTransferPlan] =
        [20, 60, 120].flatMap { size in (1...3).map { SpikeTransferPlan(megabytes: size, repetition: $0) } }
        + [SpikeTransferPlan(megabytes: 250, repetition: 1)]
}

/// Drives the spike: transfer matrix, handoff loop, teardown, and the JSON report.
@MainActor
@Observable
final class SpikeRunner {
    static let shared = SpikeRunner()
    static let handoffCadence: Duration = .seconds(5)

    private(set) var logLines: [String] = []
    private(set) var status = "idle"
    private(set) var transferRunning = false
    private(set) var handoffRunning = false
    private(set) var reportURL: URL?

    private let context = SpikeCloudKitContext()
    private let handoffProbe: CloudKitHandoffProbe
    private var report: SpikeReport
    private var transferTask: Task<Void, Never>?
    private var handoffTask: Task<Void, Never>?
    private let reportFileName: String

    private init() {
        handoffProbe = CloudKitHandoffProbe(context: context)
        let device = Self.deviceName()
        report = SpikeReport(device: device)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let safeDevice = device.filter { $0.isLetter || $0.isNumber }
        reportFileName = "spike-report-\(safeDevice)-\(stamp).json"
    }

    func log(_ line: String) {
        logLines.append("\(Date().formatted(date: .omitted, time: .standard)) \(line)")
        if logLines.count > 400 { logLines.removeFirst(logLines.count - 400) }
    }

    /// Entry point for the host's remote-notification handler.
    func handlePush() async {
        log("push received")
        await handoffProbe.handlePush()
    }

    // MARK: Transfer matrix

    func startTransfers() {
        guard !transferRunning else { return }
        transferRunning = true
        transferTask = Task { [weak self] in
            await self?.runMatrix()
            self?.transferRunning = false
        }
    }

    func cancelTransfers() {
        transferTask?.cancel()
    }

    private func runMatrix() async {
        let strategies: [any TransferStrategy] = [
            SingleAssetStrategy(context: context),
            ChunkedAssetStrategy(context: context),
            UbiquityDriveStrategy(),
        ]
        var eagerProbeDone = false
        for strategy in strategies {
            for plan in SpikeTransferPlan.matrix {
                if Task.isCancelled { status = "cancelled"; return }
                status = "\(strategy.name) \(plan.megabytes) MB #\(plan.repetition)"
                let recordName = await runOne(strategy: strategy, plan: plan)
                if !eagerProbeDone, strategy is SingleAssetStrategy, let recordName {
                    eagerProbeDone = true
                    await runEagerProbe(recordName: recordName)
                }
            }
        }
        status = "transfers done"
        writeReport()
    }

    /// Uploads then downloads one payload. Returns the handle id when the upload succeeded.
    private func runOne(strategy: any TransferStrategy, plan: SpikeTransferPlan) async -> String? {
        let file: URL
        do {
            file = try Self.makePayload(megabytes: plan.megabytes)
        } catch {
            log("payload creation failed: \(error)")
            report.notes.append("payload \(plan.megabytes) MB failed: \(error)")
            return nil
        }
        defer { try? FileManager.default.removeItem(at: file) }

        let label = "\(strategy.name) \(plan.megabytes) MB #\(plan.repetition)"
        let upload = await strategy.upload(file: file) { [weak self] bytes in
            Task { @MainActor in self?.status = "\(label) up \(bytes / 1_048_576) MB" }
        }
        report.measurements.append(upload.measurement)
        log("\(label) upload: \(Self.describe(upload.measurement))")
        writeReport()

        guard let handle = upload.handle else { return nil }
        let download = await strategy.download(handle: handle) { [weak self] bytes in
            Task { @MainActor in self?.status = "\(label) down \(bytes / 1_048_576) MB" }
        }
        report.measurements.append(download)
        log("\(label) download: \(Self.describe(download))")
        writeReport()
        return handle.id
    }

    private func runEagerProbe(recordName: String) async {
        status = "eager-fetch probe"
        let result = await EagerFetchProbe(context: context).run(recordName: recordName)
        if let data = try? Self.jsonEncoder.encode(result), let text = String(data: data, encoding: .utf8) {
            report.notes.append("eager-fetch: \(text)")
        }
        log("eager-fetch probe done (error: \(result.errorText ?? "none"))")
        writeReport()
    }

    // MARK: Handoff

    func startHandoff(role: SpikeRole) {
        guard !handoffRunning else { return }
        handoffRunning = true
        log("handoff \(role.rawValue) started, cadence 5 s")
        handoffTask = Task { [weak self] in
            switch role {
            case .publisher: await self?.publishLoop()
            case .observer: await self?.observeLoop()
            }
            self?.handoffRunning = false
        }
    }

    func stopHandoff() {
        handoffTask?.cancel()
    }

    private func publishLoop() async {
        var sequence = 0
        let started = Date()
        while !Task.isCancelled {
            sequence += 1
            let publishedAt = Date()
            do {
                try await handoffProbe.publish(
                    position: publishedAt.timeIntervalSince(started), sequence: sequence, publishedAt: publishedAt
                )
                log("published #\(sequence)")
            } catch {
                log("publish #\(sequence) failed: \(error)")
            }
            report.clockOffset = ClockOffset(samples: handoffProbe.clockOffsetSamples)
            writeReport()
            try? await Task.sleep(for: Self.handoffCadence)
        }
    }

    private func observeLoop() async {
        do {
            try await handoffProbe.installSubscription()
            log("subscription installed")
        } catch {
            log("subscription failed: \(error)")
        }
        let stream = handoffProbe.observe()
        let collector = Task { [weak self] in
            for await observation in stream {
                guard let self else { return }
                report.handoffs.append(observation)
                log("observed #\(observation.value.sequence) raw latency \(String(format: "%.2f", observation.rawLatencySeconds)) s")
                writeReport()
            }
        }
        // Foreground fallback at the same cadence; pushes arrive through `handlePush()`.
        while !Task.isCancelled {
            await handoffProbe.fetchLatest()
            try? await Task.sleep(for: Self.handoffCadence)
        }
        handoffProbe.finish()
        collector.cancel()
    }

    // MARK: Teardown and report

    func teardown() {
        Task { [weak self] in
            guard let self else { return }
            status = "teardown"
            let result = await SpikeZoneTeardown(context: context).run()
            if let data = try? Self.jsonEncoder.encode(result), let text = String(data: data, encoding: .utf8) {
                report.notes.append("teardown: \(text)")
            }
            log("teardown: zone deleted \(result.zoneDeleted), subscriptions \(result.deletedSubscriptionIDs.count), errors \(result.errors.count)")
            status = result.isClean ? "teardown clean" : "teardown finished with errors"
            writeReport()
        }
    }

    /// Writes the JSON report to the app's Documents directory.
    @discardableResult
    func writeReport() -> URL? {
        report.generatedAt = Date()
        do {
            let directory = try FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            let url = directory.appendingPathComponent(reportFileName)
            try report.write(to: url)
            reportURL = url
            return url
        } catch {
            log("report write failed: \(error)")
            return nil
        }
    }

    // MARK: Helpers

    private static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static func describe(_ measurement: SpikeCore.Measurement) -> String {
        if let error = measurement.errorText { return "FAILED \(error)" }
        let rate = measurement.bytesPerSecond.map { String(format: "%.1f MB/s", $0 / 1_048_576) } ?? "n/a"
        return String(format: "%.1f s, %@, %d progress calls", measurement.wallSeconds, rate, measurement.progressCallbackCount)
    }

    private static func deviceName() -> String {
        #if os(macOS)
        return Host.current().localizedName ?? "mac"
        #else
        return UIDevice.current.name
        #endif
    }

    /// Writes an incompressible payload of `megabytes` MiB, one MiB at a time to keep memory flat.
    private static func makePayload(megabytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spike-\(UUID().uuidString).bin")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<megabytes {
            var block = Data(count: 1_048_576)
            block.withUnsafeMutableBytes { raw in
                for index in stride(from: 0, to: raw.count, by: 8) {
                    raw.storeBytes(of: generator.next(), toByteOffset: index, as: UInt64.self)
                }
            }
            try handle.write(contentsOf: block)
        }
        return url
    }
}

/// Single screen shared by both hosts.
struct SpikeRunnerView: View {
    let runner: SpikeRunner
    let role: SpikeRole

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transport spike: \(role.rawValue)").font(.headline)
            Text(runner.status).font(.subheadline).foregroundStyle(.secondary)
            HStack {
                Button(runner.transferRunning ? "Cancel transfers" : "Run transfers") {
                    runner.transferRunning ? runner.cancelTransfers() : runner.startTransfers()
                }
                Button(runner.handoffRunning ? "Stop handoff" : "Start handoff (\(role.rawValue))") {
                    runner.handoffRunning ? runner.stopHandoff() : runner.startHandoff(role: role)
                }
            }
            HStack {
                Button("Write report") { runner.writeReport() }
                Button("Teardown", role: .destructive) { runner.teardown() }
            }
            if let url = runner.reportURL {
                Text(url.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            }
            ScrollView {
                Text(runner.logLines.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding()
    }
}
