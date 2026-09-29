import Foundation
import Testing
@testable import SpikeCore

private func makeSparseFile(in directory: URL, megabytes: Int) throws -> URL {
    let url = directory.appendingPathComponent("payload-\(megabytes)mb.bin")
    #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: UInt64(megabytes) * 1_048_576)
    return url
}

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SpikeCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test("fake strategy round-trips 20, 60 and 120 MB and the report JSON")
func fakeStrategyAndReportRoundTrip() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let strategy = InMemoryTransferStrategy()
    var measurements: [SpikeCore.Measurement] = []

    for megabytes in [20, 60, 120] {
        let file = try makeSparseFile(in: directory, megabytes: megabytes)
        let expected = Int64(megabytes) * 1_048_576
        let upload = await strategy.upload(file: file) { _ in }
        let handle = try #require(upload.handle)
        #expect(upload.measurement.succeeded)
        #expect(upload.measurement.bytes == expected)
        #expect(upload.measurement.progressCallbackCount == megabytes)
        #expect(handle.byteCount == expected)

        let download = await strategy.download(handle: handle) { _ in }
        #expect(download.succeeded)
        #expect(download.bytes == expected)
        #expect(download.direction == .download)
        measurements += [upload.measurement, download]
    }

    let samples = [
        ClockOffsetSample(
            publisherTimestamp: Date(timeIntervalSince1970: 1_000),
            serverModificationDate: Date(timeIntervalSince1970: 1_000.5)
        ),
    ]
    let observation = HandoffObservation(
        value: HandoffValue(position: 12.5, sequence: 3, publishedAt: Date(timeIntervalSince1970: 2_000.25)),
        receivedAt: Date(timeIntervalSince1970: 2_001.75)
    )
    let report = SpikeReport(
        generatedAt: Date(timeIntervalSince1970: 3_000.125),
        device: "fake",
        measurements: measurements,
        handoffs: [observation],
        clockOffset: ClockOffset(samples: samples),
        notes: ["fake run"]
    )

    let url = directory.appendingPathComponent("nested/report.json")
    try report.write(to: url)
    let decoded = try SpikeReport.read(from: url)
    #expect(decoded == report)
    #expect(decoded.measurements.count == 6)
    #expect(decoded.handoffs.first?.rawLatencySeconds == 1.5)
}

@Test("fake strategy reports failures as error text")
func fakeStrategyFailures() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = try makeSparseFile(in: directory, megabytes: 1)

    let failing = await InMemoryTransferStrategy(failUploads: true).upload(file: file) { _ in }
    #expect(failing.handle == nil)
    #expect(failing.measurement.errorText != nil)
    #expect(failing.measurement.bytesPerSecond == nil)

    let missing = await InMemoryTransferStrategy().download(
        handle: TransferHandle(id: "nope", byteCount: 1)
    ) { _ in }
    #expect(missing.errorText != nil)

    let absent = await InMemoryTransferStrategy().upload(
        file: directory.appendingPathComponent("absent.bin")
    ) { _ in }
    #expect(absent.handle == nil)
    #expect(absent.measurement.errorText != nil)
}

@Test("clock offset uses the median and corrects latency")
func clockOffsetSummary() throws {
    let base = Date(timeIntervalSince1970: 500)
    let samples = [0.2, 1.0, 0.4].map {
        ClockOffsetSample(publisherTimestamp: base, serverModificationDate: base.addingTimeInterval($0))
    }
    let offset = try #require(ClockOffset(samples: samples))
    #expect(offset.sampleCount == 3)
    #expect(abs(offset.minSeconds - 0.2) < 1e-4)
    #expect(abs(offset.medianSeconds - 0.4) < 1e-4)
    #expect(abs(offset.maxSeconds - 1.0) < 1e-4)
    #expect(abs(offset.correctedLatency(rawSeconds: 2.0) - 1.6) < 1e-4)
    #expect(ClockOffset(samples: []) == nil)

    let even = try #require(ClockOffset(samples: Array(samples.prefix(2))))
    #expect(abs(even.medianSeconds - 0.6) < 1e-4)
}

@Test("in-memory handoff probe delivers published values to observers")
func handoffProbeDelivers() async throws {
    let receive = Date(timeIntervalSince1970: 100.5)
    let probe = InMemoryHandoffProbe(now: { receive })
    let stream = probe.observe()
    let published = Date(timeIntervalSince1970: 100)

    try await probe.publish(position: 42, sequence: 1, publishedAt: published)
    try await probe.publish(position: 47, sequence: 2, publishedAt: published)
    probe.finish()

    var received: [HandoffObservation] = []
    for await observation in stream { received.append(observation) }
    #expect(received.map(\.value.sequence) == [1, 2])
    #expect(received.first?.value.position == 42)
    #expect(received.first?.rawLatencySeconds == 0.5)
}
