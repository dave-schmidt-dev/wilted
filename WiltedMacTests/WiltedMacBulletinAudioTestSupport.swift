import AVFoundation
import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedProducer
import WiltedWeather
@testable import WiltedMac

enum BulletinAudioTestError: Error {
    case renderFailed
    case statusTimedOut
    case invalidNWSResponse
}

struct BulletinAudioPublishedFile: Sendable {
    let offer: LibraryStoryAudioOffer
    let bytes: Data
}

struct BulletinAudioTransportSnapshot: Sendable {
    let statusHistory: [LibraryListenNextStatus]
    let audio: [BulletinAudioPublishedFile]
    let ownerChecks: [String]
}

actor BulletinAudioTransportRecorder: LibraryStoryAudioTransport {
    private let validOwner: String
    private var history: [LibraryListenNextStatus] = []
    private var statusesByID: [String: LibraryListenNextStatus] = [:]
    private var audioFiles: [BulletinAudioPublishedFile] = []
    private var checkedOwners: [String] = []

    init(owner: String) { validOwner = owner }

    func publishStoryAudio(offer: LibraryStoryAudioOffer, fileURL: URL, expectedOwner: String) async throws {
        try checkOwner(expectedOwner)
        audioFiles.append(BulletinAudioPublishedFile(offer: offer, bytes: try Data(contentsOf: fileURL)))
    }

    func fetchStoryAudio(
        _ offer: LibraryStoryAudioOffer, expectedOwner: String,
        progress: @escaping MediaProgressHandler
    ) async throws -> URL {
        try checkOwner(expectedOwner)
        throw LibraryTransportError.transport("Fetch is not used by the Mac request renderer test.")
    }

    func removeStoryAudio(_ offer: LibraryStoryAudioOffer, expectedOwner: String) async throws {
        try checkOwner(expectedOwner)
        audioFiles.removeAll { $0.offer == offer }
    }

    func publishListenNextStatus(_ status: LibraryListenNextStatus, expectedOwner: String) async throws {
        try checkOwner(expectedOwner)
        history.append(status)
        statusesByID[status.requestID] = status
    }

    func listenNextStatuses(
        requestIDs: Set<String>, expectedOwner: String
    ) async throws -> [LibraryListenNextStatus] {
        try checkOwner(expectedOwner)
        return requestIDs.compactMap { statusesByID[$0] }
    }

    func snapshot() -> BulletinAudioTransportSnapshot {
        BulletinAudioTransportSnapshot(statusHistory: history, audio: audioFiles, ownerChecks: checkedOwners)
    }

    private func checkOwner(_ owner: String) throws {
        checkedOwners.append(owner)
        guard owner == validOwner else { throw LibraryTransportError.ownershipViolation("Unexpected owner token.") }
    }
}

actor BulletinAudioAuthority {
    private let currentOwner: String
    private let currentGeneration: UInt64

    init(owner: String, generation: UInt64) {
        currentOwner = owner
        currentGeneration = generation
    }

    func owner() -> String { currentOwner }
    func generation() -> UInt64 { currentGeneration }
}

actor BulletinAudioNWSResponseTransport: NWSTransport {
    private let responseBody: Data
    private var receivedRequests: [URLRequest] = []

    init(body: Data) { responseBody = body }

    func send(_ request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        receivedRequests.append(request)
        guard responseBody.count <= maximumBytes, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil) else {
            throw BulletinAudioTestError.invalidNWSResponse
        }
        return (responseBody, response)
    }

    func requests() -> [URLRequest] { receivedRequests }
}

func nwsAlertBody(id: String, now: Date) throws -> Data {
    func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
    let sent = now.addingTimeInterval(-60)
    let effective = now.addingTimeInterval(-60)
    let onset = now.addingTimeInterval(-30)
    let ends = now.addingTimeInterval(1_800)
    let expires = now.addingTimeInterval(3_600)
    return try JSONSerialization.data(withJSONObject: [
        "id": "https://api.weather.gov/alerts/\(id)",
        "properties": [
            "id": id,
            "event": "Severe Thunderstorm Warning",
            "areaDesc": "Test County",
            "severity": "Severe",
            "urgency": "Immediate",
            "certainty": "Likely",
            "messageType": "Alert",
            "headline": "Severe Thunderstorm Warning issued November 25 at 9:25PM EST until November 25 at 10:00PM EST by NWS Example Office",
            "description": "A dangerous storm is moving through Test County.",
            "instruction": "Move indoors now. Stay away from windows.",
            "sent": iso8601(sent),
            "effective": iso8601(effective),
            "onset": iso8601(onset),
            "ends": iso8601(ends),
            "expires": iso8601(expires)
        ]
    ])
}

actor BulletinAudioRenderRecorder {
    private(set) var calls: [(text: String, voice: ApprovedReadingVoiceID)] = []

    @discardableResult
    func record(text: String, voice: ApprovedReadingVoiceID) -> Int {
        calls.append((text, voice))
        return calls.count
    }

    func value() -> [(text: String, voice: ApprovedReadingVoiceID)] { calls }
}

actor BulletinAudioRenderGate {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pauseUntilReleased() async {
        started = true
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

@MainActor
final class BulletinAudioDecisionHost: WiltedMacDecisionHost {
    var decisionQueue: [ItemID] { [] }
    func decisionState(of entryID: ItemID) -> WiltedMacDecisionEntryState { .unknown }
    func keepEntry(_ entryID: ItemID) async -> Bool { false }
    func skipEntry(_ entryID: ItemID) async -> Bool { false }
    func markEntryDone(_ entryID: ItemID) async -> Bool { false }
    func removeEntryFromLarder(_ entryID: ItemID) async -> Bool { false }
    func restoreEntry(_ entryID: ItemID) async -> Bool { false }
    func moveQueueEntry(from source: Int, to destination: Int, resulting: [ItemID]) async -> Bool { false }
    func subscribeFeed(_ url: URL) async -> WiltedMacAddResult { .failed }
    func addArticleLink(_ url: URL) async -> WiltedMacAddResult { .failed }
    func addLink(_ url: URL) async -> WiltedMacAddResult { .failed }
}

func writeSilentAAC(to url: URL) throws {
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 44_100,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 64_000
    ]
    let audioFile = try AVAudioFile(
        forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: 4_410)!
    buffer.frameLength = buffer.frameCapacity
    if let samples = buffer.floatChannelData?.pointee {
        for frame in 0..<Int(buffer.frameLength) { samples[frame] = 0 }
    }
    try audioFile.write(from: buffer)
}
