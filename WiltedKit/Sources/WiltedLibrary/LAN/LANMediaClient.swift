import Foundation
import Network
import OSLog
import WiltedDomain

private let clientLog = Logger(subsystem: "com.zerodelta.wilted", category: "LAN")

/// Fetches a prepared revision straight from a nearby source and returns a local file only after it has
/// been checked against the offer. The LAN client is the first implementation; fakes stand in for it in
/// the phone's fallback tests.
public protocol DirectMediaSource: Sendable {
    /// - Parameters:
    ///   - offset: the longest prefix of an existing partial file the caller trusts. The client resumes from
    ///     `min(offset, bytes on disk)`; 0 starts over.
    ///   - progress: cumulative bytes of the file on disk, the resumed prefix included, never decreasing.
    /// - Returns: a file whose size and SHA-256 match `offer`. A file that does not match is deleted and
    ///   never returned.
    func fetch(
        _ offer: LibraryMediaOffer, from offset: Int64, progress: @escaping MediaProgressHandler
    ) async throws -> URL
}

/// What the client is waiting on, so a surface can say it in words (INV-1: no silent waits).
public enum LANMediaPhase: Sendable, Equatable {
    /// Browsing is the caller's; this is the TCP and TLS handshake with endpoint `index` of `count`.
    case connecting(index: Int, count: Int)
    case requesting
    case downloading
    /// A dropped connection is being resumed from the bytes already on disk.
    case resuming
    /// The finished file is being checked against the offer.
    case verifying
}

/// Why a direct fetch delivered nothing, by cause. None carries key bytes or a network address.
public enum LANMediaError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The offer is not one the direct path fetches (not prepared, no certified hash, over the cap).
    case invalidOffer
    /// This process is already fetching that revision.
    case partialInUse
    case noEndpoints
    /// No endpoint completed a handshake: a refused key (a neighbour's Mac, a removed phone), a held
    /// gate, or nothing listening.
    case handshakeFailed
    /// A connection negotiated something other than the one allowed profile.
    case unexpectedNegotiation
    case timedOut(LANMediaPhase)
    /// The Mac answered with that status.
    case busy, notReady, different, refused
    /// Two connections in a row ended early. The partial file is kept for a later try.
    case connectionDropped(receivedBytes: Int64)
    /// The Mac sent something this client does not accept. The partial file is deleted.
    case protocolViolation
    /// The finished file's size or hash is not the offer's. The partial file is deleted.
    case mismatch
    case storage(String)

    public var description: String {
        switch self {
        case .invalidOffer: "invalid offer"
        case .partialInUse: "partial file in use"
        case .noEndpoints: "no endpoints"
        case .handshakeFailed: "handshake failed"
        case .unexpectedNegotiation: "unexpected TLS profile"
        case let .timedOut(phase): "timed out (\(phase))"
        case .busy: "busy"
        case .notReady: "not ready"
        case .different: "different revision"
        case .refused: "refused"
        case let .connectionDropped(bytes): "connection dropped after \(bytes) bytes"
        case .protocolViolation: "protocol violation"
        case .mismatch: "size or hash mismatch"
        case let .storage(text): "storage: \(text)"
        }
    }
}

/// The phone's side of the direct transfer: connects to the Mac over TLS-PSK, asks for one revision from a
/// byte offset, streams it into a `LANPartialFile`, resumes once after a drop, and verifies byte count and
/// SHA-256 against the offer before returning anything (W-INV-007).
///
/// Candidate `endpoints` are tried in order. A handshake failure (`.waiting` or `.failed` before `.ready`,
/// which is how a wrong key shows) moves to the next candidate and does not use up the resume; only a
/// connection that was working and then ended early does.
public final class LANMediaClient: DirectMediaSource {
    private let endpoints: [NWEndpoint]
    private let peer: LANTLSPeer
    private let partialDirectory: URL
    private let binding: LANInterfaceBinding
    private let deadlines: LANDeadlines
    private let chunkBytes: Int
    private let onPhase: @Sendable (LANMediaPhase) -> Void

    /// - Parameters:
    ///   - peer: this phone's PSK and identity for the Mac (`LANPairingKey`).
    ///   - partialDirectory: the cache's `Partial` folder.
    ///   - onPhase: called when the client starts a new kind of wait.
    public init(
        endpoints: [NWEndpoint], peer: LANTLSPeer, partialDirectory: URL, binding: LANInterfaceBinding = .any,
        deadlines: LANDeadlines = .standard, chunkBytes: Int = 1 << 20,
        onPhase: @escaping @Sendable (LANMediaPhase) -> Void = { _ in }
    ) {
        self.endpoints = endpoints
        self.peer = peer
        self.partialDirectory = partialDirectory
        self.binding = binding
        self.deadlines = deadlines
        self.chunkBytes = max(1, chunkBytes)
        self.onPhase = onPhase
    }

    public func fetch(
        _ offer: LibraryMediaOffer, from offset: Int64, progress: @escaping MediaProgressHandler
    ) async throws -> URL {
        guard LANPartialFile.isFetchable(offer), let revision = offer.revisionID else { throw LANMediaError.invalidOffer }
        guard !endpoints.isEmpty else { throw LANMediaError.noEndpoints }
        let partial: LANPartialFile
        do { partial = try LANPartialFile.open(in: partialDirectory, for: offer) } catch let error as LANPartialFileError {
            throw Self.map(error)
        }
        defer {
            // A fetch that got nothing leaves no empty file behind; one that got bytes keeps them to resume.
            if partial.size == 0 { partial.discard() }
            partial.close()
        }
        do { try partial.truncate(to: max(0, offset)) } catch let error as LANPartialFileError { throw Self.map(error) }

        let control = LANFetchControl()
        let overall = DispatchWorkItem { control.stop(timedOut: true) }
        DispatchQueue.global().asyncAfter(deadline: .now() + deadlines.overall, execute: overall)
        defer { overall.cancel() }

        let transfer = Transfer(
            offer: offer, revision: revision, partial: partial, control: control, progress: progress)
        try await withTaskCancellationHandler {
            var resumed = false
            while partial.size < offer.byteCount {
                try control.check()
                if try await self.attempt(transfer) == .complete { break }
                // The connection ended early. Keep what arrived, and resume once.
                try control.check()
                guard !resumed else { throw LANMediaError.connectionDropped(receivedBytes: partial.size) }
                resumed = true
                self.onPhase(.resuming)
            }
        } onCancel: { control.stop(timedOut: false) }

        try control.check()
        onPhase(.verifying)
        do { return try await partial.verifiedURL() } catch let error as LANPartialFileError { throw Self.map(error) }
    }

    // MARK: One attempt

    private enum AttemptEnd { case complete, dropped }

    private struct Transfer {
        let offer: LibraryMediaOffer
        let revision: RevisionID
        let partial: LANPartialFile
        let control: LANFetchControl
        let progress: MediaProgressHandler
    }

    /// Connects to the first candidate that completes a handshake, then requests and receives. A connection
    /// that was working and ended early is `.dropped`; every other failure throws.
    private func attempt(_ transfer: Transfer) async throws -> AttemptEnd {
        var lastFailure: LANMediaError = .handshakeFailed
        for (index, endpoint) in endpoints.enumerated() {
            try transfer.control.check()
            onPhase(.connecting(index: index, count: endpoints.count))
            let connection = try LANClientConnection(
                endpoint: endpoint, peer: peer, binding: binding, deadlines: deadlines, control: transfer.control)
            defer { connection.cancel() }
            do { try await connection.connect() } catch let error as LANMediaError {
                try transfer.control.check()
                guard error == .handshakeFailed else { throw error }
                lastFailure = error
                continue
            }
            do { return try await transferBytes(over: connection, transfer) } catch let error as LANMediaError {
                // A cancel or the overall deadline closes the connection too; `check()` names those.
                try transfer.control.check()
                if case .connectionDropped = error { return .dropped }
                if case .timedOut = error { return .dropped }
                throw error
            }
        }
        throw lastFailure
    }

    private func transferBytes(over connection: LANClientConnection, _ transfer: Transfer) async throws -> AttemptEnd {
        let offer = transfer.offer, partial = transfer.partial
        onPhase(.requesting)
        let request = LANMediaRequest(
            entryID: offer.entryID, revisionID: transfer.revision, contentHash: offer.contentHash,
            byteCount: offer.byteCount, offset: partial.size)
        try await connection.send(try request.encoded())

        guard let prefix = try await connection.receive(exactly: LANFrameCodec.prefixBytes) else { return .dropped }
        guard let length = try? LANFrameCodec.payloadLength(prefix: prefix), length > 0 else {
            throw LANMediaError.protocolViolation
        }
        guard let payload = try await connection.receive(exactly: length) else { return .dropped }
        let header: LANMediaHeader
        do { header = try LANMediaHeader.decode(frame: prefix + payload) } catch { throw LANMediaError.protocolViolation }
        switch header.status {
        case .ok: break
        case .busy: throw LANMediaError.busy
        case .notReady: throw LANMediaError.notReady
        case .different: throw LANMediaError.different
        case .refused: throw LANMediaError.refused
        }
        // The Mac must be serving exactly the revision the offer names; anything else is not ours to keep.
        guard header.revisionID == transfer.revision, header.contentHash == offer.contentHash,
              header.byteCount == offer.byteCount else { throw LANMediaError.different }

        onPhase(.downloading)
        var reported = partial.size
        transfer.progress(reported)
        var finished = false
        while partial.size < offer.byteCount {
            let want = Int(min(Int64(chunkBytes), offer.byteCount - partial.size))
            let chunk = try await connection.receive(minimum: 1, maximum: want)
            // A read with a minimum of one byte returns data, or the end of the stream.
            if chunk.data.isEmpty { return .dropped }
            do { try partial.append(chunk.data) } catch let error as LANPartialFileError { throw Self.map(error) }
            finished = chunk.isComplete
            if partial.size - reported >= 256 * 1024 || partial.size == offer.byteCount {
                reported = partial.size
                transfer.progress(reported)
            }
        }
        // Exactly the requested bytes have arrived. Anything after them is a protocol violation, and the
        // file cannot be trusted.
        if !finished, let extra = try? await connection.receive(minimum: 1, maximum: 1, idle: 2), !extra.data.isEmpty {
            partial.discard()
            throw LANMediaError.protocolViolation
        }
        return .complete
    }

    private static func map(_ error: LANPartialFileError) -> LANMediaError {
        switch error {
        case .invalidOffer, .overrun: .invalidOffer
        case .inUse: .partialInUse
        case .mismatch: .mismatch
        case let .storage(text): .storage(text)
        }
    }
}

// MARK: - Shared stop state

/// Cancellation and the overall deadline for one fetch, shared by its connections. A cancel or overall
/// timeout closes the current connection at once, so no read waits on a dead transfer.
final class LANFetchControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var overallTimedOut = false
    private var connections: [LANClientConnection] = []

    var isStopped: Bool { lock.withLock { stopped } }

    func stop(timedOut: Bool) {
        let open = lock.withLock { () -> [LANClientConnection] in
            stopped = true
            overallTimedOut = overallTimedOut || timedOut
            return connections
        }
        open.forEach { $0.cancel() }
    }

    func register(_ connection: LANClientConnection) {
        let alreadyStopped = lock.withLock { () -> Bool in
            connections.append(connection)
            return stopped
        }
        if alreadyStopped { connection.cancel() }
    }

    func check() throws {
        let (stopped, overall) = lock.withLock { (self.stopped, overallTimedOut) }
        if overall { throw LANMediaError.timedOut(.downloading) }
        if stopped { throw CancellationError() }
    }
}

// MARK: - Connection

/// One `NWConnection`, wrapped for `async` use with the handshake, idle and cancel rules the design needs.
final class LANClientConnection: @unchecked Sendable {
    struct Chunk {
        let data: Data
        let isComplete: Bool
        /// The connection ended with an error rather than a clean close.
        let ended: Bool
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.zerodelta.wilted.lan.client")
    private let deadlines: LANDeadlines
    private let lock = NSLock()
    private var timedOutAt: LANMediaPhase?
    private var timer: DispatchWorkItem?
    private var isCancelled = false

    init(endpoint: NWEndpoint, peer: LANTLSPeer, binding: LANInterfaceBinding, deadlines: LANDeadlines, control: LANFetchControl) throws {
        let parameters: NWParameters
        do { parameters = try LANTLSProfile.clientParameters(psk: peer.psk, identity: peer.identity) } catch {
            throw LANMediaError.handshakeFailed
        }
        binding.apply(to: parameters)
        connection = NWConnection(to: endpoint, using: parameters)
        self.deadlines = deadlines
        control.register(self)
    }

    func cancel() {
        let first = lock.withLock { () -> Bool in
            defer { isCancelled = true }
            timer?.cancel()
            return !isCancelled
        }
        if first { connection.cancel() }
    }

    /// Completes only when the connection is `.ready` and passed `LANTLSProfile.validate(metadata:)`.
    /// `.waiting` or `.failed` first is a failed handshake: it is cancelled at once, never waited out.
    func connect() async throws {
        // The deadline cancels the connection, which reads as a failed handshake.
        arm(deadlines.handshake, phase: .connecting(index: 0, count: 1))
        defer { disarm() }
        let connection = connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once(continuation)
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
                    if (try? LANTLSProfile.validate(metadata: metadata)) != nil {
                        once.finish(.success(()))
                    } else {
                        once.finish(.failure(LANMediaError.unexpectedNegotiation))
                        self?.cancel()
                    }
                case .waiting, .failed:
                    once.finish(.failure(LANMediaError.handshakeFailed))
                    self?.cancel()
                case .cancelled:
                    once.finish(.failure(LANMediaError.handshakeFailed))
                default: break
                }
            }
            connection.start(queue: queue)
        }
        // From here on any path loss ends the connection, so a pending read fails instead of hanging.
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .waiting, .failed, .cancelled: self?.cancel()
            default: break
            }
        }
    }

    func send(_ data: Data) async throws {
        arm(deadlines.idle, phase: .downloading)
        defer { disarm() }
        let connection = connection
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
        } catch { throw lost() }
    }

    /// Exactly `count` bytes, or nil when the connection ended first.
    func receive(exactly count: Int) async throws -> Data? {
        let chunk = try await receive(minimum: count, maximum: count)
        return chunk.data.count == count ? chunk.data : nil
    }

    func receive(minimum: Int, maximum: Int, idle: TimeInterval? = nil) async throws -> Chunk {
        arm(idle ?? deadlines.idle, phase: .downloading)
        defer { disarm() }
        let connection = connection
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Chunk, Error>) in
            connection.receive(minimumIncompleteLength: minimum, maximumLength: maximum) { data, _, isComplete, error in
                if error != nil, (data ?? Data()).isEmpty {
                    continuation.resume(throwing: self.lost())
                } else {
                    continuation.resume(returning: Chunk(data: data ?? Data(), isComplete: isComplete, ended: error != nil))
                }
            }
        }
    }

    /// The error for a connection that ended under a read or write: a deadline, or a plain drop.
    private func lost() -> LANMediaError {
        if let phase = lock.withLock({ timedOutAt }) { return .timedOut(phase) }
        return .connectionDropped(receivedBytes: 0)
    }

    private func arm(_ seconds: TimeInterval, phase: LANMediaPhase) {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.timedOutAt = phase }
            clientLog.notice("LAN connection timed out")
            self.cancel()
        }
        lock.withLock {
            timer?.cancel()
            timer = item
        }
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func disarm() {
        lock.withLock {
            timer?.cancel()
            timer = nil
        }
    }

    /// Resumes a continuation exactly once; later state changes are ignored.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?

        init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }

        func finish(_ result: Result<Void, Error>) {
            let pending = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(with: result)
        }
    }
}
