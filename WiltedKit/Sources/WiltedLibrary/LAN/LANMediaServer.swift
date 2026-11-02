import Foundation
import Network
import OSLog
import WiltedDomain

private let serverLog = Logger(subsystem: "com.zerodelta.wilted", category: "LAN")

/// Which network interface the listener (or client) may use. Production leaves it `.any` with peer-to-peer
/// off (the TLS profile already sets that); tests pin it to loopback.
public enum LANInterfaceBinding: Sendable, Equatable {
    case any
    case loopback
    case interfaceType(NWInterface.InterfaceType)

    func apply(to parameters: NWParameters) {
        switch self {
        case .any: break
        case .loopback: parameters.requiredInterfaceType = .loopback
        case let .interfaceType(type): parameters.requiredInterfaceType = type
        }
    }
}

/// The three time limits on a LAN connection, in seconds. Tests shorten them; production uses `standard`.
public struct LANDeadlines: Sendable, Equatable {
    /// From connection start to a completed TLS handshake.
    public var handshake: TimeInterval
    /// Longest wait for the next byte moved, request or audio.
    public var idle: TimeInterval
    /// The whole connection, handshake to last byte.
    public var overall: TimeInterval

    public init(handshake: TimeInterval = 10, idle: TimeInterval = 15, overall: TimeInterval = 600) {
        self.handshake = handshake
        self.idle = idle
        self.overall = overall
    }

    public static let standard = LANDeadlines()
}

/// A prepared file the Mac can serve: where it is, and the identity the Mac's records give it.
public struct LANServedFile: Sendable, Equatable {
    public let fileURL: URL
    public let revisionID: RevisionID
    public let contentHash: String
    public let byteCount: Int64

    public init(fileURL: URL, revisionID: RevisionID, contentHash: String, byteCount: Int64) {
        self.fileURL = fileURL
        self.revisionID = revisionID
        self.contentHash = contentHash
        self.byteCount = byteCount
    }
}

/// The source closure's answer for one request.
public enum LANSourceAnswer: Sendable, Equatable {
    /// The Mac's ready revision for the entry. The server compares its identity with the request's.
    case ready(LANServedFile)
    case notReady
    case refused
}

/// Supplies the file for a request. The Mac app backs it with `WiltedMacReadyAudioSource` (read-only,
/// W-INV-005); the server reads nothing else and never prepares audio. Keep it quick: the connection's
/// idle limit runs while it works.
public typealias LANMediaSource = @Sendable (LANMediaRequest) async -> LANSourceAnswer

/// Serves prepared audio to the owner's phones over TLS-PSK (design: Track A).
///
/// Concurrency: every piece of mutable state is confined to one serial `queue`. The listener, every
/// connection and every timer run on it, and the public `async` methods hop onto it, so no lock is needed
/// and no callback can race another. `@unchecked Sendable` rests on that discipline. File reads are
/// 1 MiB at a time on the same queue; with at most two transfers that is not a bottleneck, and it keeps
/// one chunk in flight per connection (backpressure comes from `send` completion).
///
/// Admission, in order:
/// 1. A connection that arrives while the account gate is held (`isHeld`) is cancelled before any
///    handshake. A listener with no phones does not exist.
/// 2. After the handshake it must pass `LANTLSProfile.validate(metadata:)`. Only then does it count
///    against the limit: the first `maximumActiveTransfers` hold a slot; any further one is read, answered
///    `busy` and closed. Sockets that never finish the handshake hold no slot.
/// 3. The hold check runs again after the request is read and once more right before the first audio byte.
///
/// `cancelAll()` ends every connection at once (DS-3: the account gate closing, the quit drain).
public final class LANMediaServer: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var binding: LANInterfaceBinding
        public var deadlines: LANDeadlines
        public var maximumActiveTransfers: Int
        /// Bound on connections in any state, so a flood of half-open sockets stays bounded.
        public var maximumConnections: Int
        public var chunkBytes: Int
        /// Bonjour advertisement, set by the Mac app (3.1); nil in tests.
        public var service: NWListener.Service?
        public var requestedPort: NWEndpoint.Port?

        public init(
            binding: LANInterfaceBinding = .any, deadlines: LANDeadlines = .standard,
            maximumActiveTransfers: Int = 2, maximumConnections: Int = 8, chunkBytes: Int = 1 << 20,
            service: NWListener.Service? = nil, requestedPort: NWEndpoint.Port? = nil
        ) {
            self.binding = binding
            self.deadlines = deadlines
            self.maximumActiveTransfers = max(1, maximumActiveTransfers)
            self.maximumConnections = max(self.maximumActiveTransfers, maximumConnections)
            self.chunkBytes = max(1, chunkBytes)
            self.service = service
            self.requestedPort = requestedPort
        }
    }

    public enum ServerError: Error, Equatable, Sendable {
        case listenerFailed(String)
        case startTimedOut
    }

    /// What one finished connection did, for tests and the notice-level log line.
    struct TransferRecord: Equatable, Sendable {
        let request: LANMediaRequest?
        let status: LANMediaHeader.Status?
        let bytesSent: Int64
    }

    private let configuration: Configuration
    private let isHeld: @Sendable () -> Bool
    private let source: LANMediaSource
    private let onListenerFailure: @Sendable (ServerError) -> Void
    private let queue = DispatchQueue(label: "com.zerodelta.wilted.lan.server")

    // Everything below is confined to `queue`.
    private var peers: [LANTLSPeer] = []
    private var listener: NWListener?
    private var generation = 0
    private var currentPort: UInt16?
    private var sessions: [Int: Session] = [:]
    private var nextSessionID = 0
    /// The most recent ended transfers, newest last, capped at `recordLimit` so a peer that keeps
    /// reconnecting cannot grow the server's memory.
    private var records: [TransferRecord] = []
    static let recordLimit = 32
    private var admitted = 0

    private var cutHook: (@Sendable (_ request: LANMediaRequest, _ bytesSent: Int64) -> Bool)?

    /// Test seam (internal): asked after each audio chunk is sent; `true` cuts that connection at once.
    /// Not for use from the source or hold closures, which run on or wait for the server queue.
    var shouldCut: (@Sendable (_ request: LANMediaRequest, _ bytesSent: Int64) -> Bool)? {
        get { queue.sync { cutHook } }
        set { queue.sync { cutHook = newValue } }
    }

    public init(
        configuration: Configuration = Configuration(),
        isHeld: @escaping @Sendable () -> Bool,
        source: @escaping LANMediaSource,
        onListenerFailure: @escaping @Sendable (ServerError) -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.isHeld = isHeld
        self.source = source
        self.onListenerFailure = onListenerFailure
    }

    // MARK: Public control

    /// Starts listening for `peers` and returns the port, or nil for an empty key set (no listener exists
    /// without phones to serve). Replaces any earlier listener.
    @discardableResult
    public func start(peers: [LANTLSPeer]) async throws -> UInt16? {
        try await applyPeers(peers, forceRestart: true).port
    }

    /// Applies a changed key set. The listener's keys are fixed when it starts, so a change restarts it,
    /// and every open connection is cancelled with it: a key that was removed ("Stop direct downloads for
    /// this iPhone") must stop at once, not at the end of its transfer. Returns the port (nil when no
    /// phones remain) and whether a restart happened; an unchanged set restarts nothing.
    @discardableResult
    public func updatePeers(_ peers: [LANTLSPeer]) async throws -> (port: UInt16?, restarted: Bool) {
        try await applyPeers(peers, forceRestart: false)
    }

    /// Ends every active connection at once, and keeps listening. Returns when all are cancelled.
    public func cancelAll() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.endAllSessions()
                continuation.resume()
            }
        }
    }

    /// Cancels the listener and every connection.
    public func stop() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.generation += 1
                self.listener?.cancel()
                self.listener = nil
                self.currentPort = nil
                self.peers = []
                self.endAllSessions()
                continuation.resume()
            }
        }
    }

    /// The observers below (`port`, `activeTransferCount`, `connectionCount`) read the server queue
    /// synchronously: call them from outside the server's own callbacks (the source and hold closures).

    /// The port now listening, or nil.
    public var port: UInt16? { queue.sync { currentPort } }

    /// Connections that passed the handshake and hold a transfer slot.
    public var activeTransferCount: Int { queue.sync { sessions.values.filter(\.holdsSlot).count } }

    /// Connections in any state.
    public var connectionCount: Int { queue.sync { sessions.count } }

    /// How many connections reached the request stage since the server started (tests).
    var admittedCount: Int { queue.sync { admitted } }

    /// The last `recordLimit` ended transfers (tests).
    var transferRecords: [TransferRecord] { queue.sync { records } }

    // MARK: Listener

    private func applyPeers(_ new: [LANTLSPeer], forceRestart: Bool) async throws -> (port: UInt16?, restarted: Bool) {
        let parameters: NWParameters?
        if new.isEmpty {
            parameters = nil
        } else {
            let built = try LANTLSProfile.serverParameters(peers: new)
            configuration.binding.apply(to: built)
            parameters = built
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let unchanged = Set(self.peers.map(PeerKey.init)) == Set(new.map(PeerKey.init))
                if !forceRestart, unchanged, (self.listener != nil) == (parameters != nil) {
                    continuation.resume(returning: (self.currentPort, false))
                    return
                }
                self.restartLocked(peers: new, parameters: parameters) { result in
                    continuation.resume(with: result.map { ($0, true) })
                }
            }
        }
    }

    private func restartLocked(
        peers new: [LANTLSPeer], parameters: NWParameters?, completion: @escaping @Sendable (Result<UInt16?, Error>) -> Void
    ) {
        generation += 1
        let mine = generation
        listener?.cancel()
        listener = nil
        currentPort = nil
        endAllSessions()
        peers = new
        guard let parameters else {
            completion(.success(nil))
            return
        }
        do {
            let listener = try NWListener(using: parameters, on: configuration.requestedPort ?? .any)
            listener.service = configuration.service
            self.listener = listener
            let startup = StartupGate(completion)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.generation == mine else { connection.cancel(); return }
                self.admit(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, self.generation == mine else { return }
                switch state {
                case .ready:
                    self.currentPort = listener.port?.rawValue
                    startup.finish(.success(self.currentPort))
                case let .failed(error):
                    serverLog.error("LAN listener failed: \(error.debugDescription, privacy: .public)")
                    let failure = ServerError.listenerFailed(error.debugDescription)
                    if !startup.finish(.failure(failure)) { self.onListenerFailure(failure) }
                    self.listener?.cancel()
                    self.listener = nil
                    self.currentPort = nil
                    self.endAllSessions()
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + configuration.deadlines.handshake) { [weak self] in
                guard let self, self.generation == mine else { return }
                if startup.finish(.failure(ServerError.startTimedOut)) {
                    self.listener?.cancel()
                    self.listener = nil
                }
            }
            listener.start(queue: queue)
        } catch {
            completion(.failure(error))
        }
    }

    // MARK: Connections

    private final class Session: @unchecked Sendable {
        let id: Int
        let connection: NWConnection
        var holdsSlot = false
        var isReady = false
        var request: LANMediaRequest?
        var status: LANMediaHeader.Status?
        var handle: FileHandle?
        var bytesSent: Int64 = 0
        var task: Task<Void, Never>?
        var handshakeTimer: DispatchWorkItem?
        var idleTimer: DispatchWorkItem?
        var overallTimer: DispatchWorkItem?
        var isEnded = false

        init(id: Int, connection: NWConnection) {
            self.id = id
            self.connection = connection
        }
    }

    private func admit(_ connection: NWConnection) {
        guard !isHeld(), sessions.count < configuration.maximumConnections else {
            connection.cancel()
            return
        }
        nextSessionID += 1
        let session = Session(id: nextSessionID, connection: connection)
        sessions[session.id] = session
        connection.stateUpdateHandler = { [weak self, weak session] state in
            guard let self, let session, !session.isEnded else { return }
            self.handleState(state, of: session)
        }
        session.handshakeTimer = schedule(configuration.deadlines.handshake, for: session)
        session.overallTimer = schedule(configuration.deadlines.overall, for: session)
        connection.start(queue: queue)
    }

    private func handleState(_ state: NWConnection.State, of session: Session) {
        switch state {
        case .ready:
            guard !session.isReady else { return }
            let metadata = session.connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
            guard (try? LANTLSProfile.validate(metadata: metadata)) != nil, !isHeld() else {
                end(session)
                return
            }
            session.isReady = true
            session.handshakeTimer?.cancel()
            session.handshakeTimer = nil
            session.holdsSlot = sessions.values.filter(\.holdsSlot).count < configuration.maximumActiveTransfers
            admitted += 1
            touch(session)
            readRequest(session)
        case .waiting, .failed, .cancelled:
            end(session)
        default:
            break
        }
    }

    private func readRequest(_ session: Session) {
        receiveExactly(LANFrameCodec.prefixBytes, on: session) { [weak self] prefix in
            guard let self, let length = try? LANFrameCodec.payloadLength(prefix: prefix), length > 0 else {
                self?.end(session)
                return
            }
            self.receiveExactly(length, on: session) { [weak self] payload in
                guard let self else { return }
                var frame = prefix
                frame.append(payload)
                guard let request = try? LANMediaRequest.decode(frame: frame) else {
                    self.end(session)
                    return
                }
                session.request = request
                self.answer(request, on: session)
            }
        }
    }

    private func receiveExactly(_ count: Int, on session: Session, _ body: @escaping @Sendable (Data) -> Void) {
        session.connection.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, _, error in
            guard let self, !session.isEnded else { return }
            guard error == nil, let data, data.count == count else {
                self.end(session)
                return
            }
            self.touch(session)
            body(data)
        }
    }

    private func answer(_ request: LANMediaRequest, on session: Session) {
        guard session.holdsSlot else {
            reply(.busy, to: request, on: session)
            return
        }
        guard !isHeld() else {
            reply(.refused, to: request, on: session)
            return
        }
        let source = source
        session.task = Task { [weak self] in
            let answer = await source(request)
            guard !Task.isCancelled, let self else { return }
            self.queue.async {
                guard !session.isEnded else { return }
                self.respond(to: request, with: answer, on: session)
            }
        }
    }

    private func respond(to request: LANMediaRequest, with answer: LANSourceAnswer, on session: Session) {
        switch answer {
        case .notReady: reply(.notReady, to: request, on: session)
        case .refused: reply(.refused, to: request, on: session)
        case let .ready(file):
            guard file.revisionID == request.revisionID, file.contentHash == request.contentHash,
                  file.byteCount == request.byteCount else {
                reply(.different, to: request, on: session, file: file)
                return
            }
            guard let handle = open(file) else {
                reply(.refused, to: request, on: session)
                return
            }
            // The last gate check before any audio byte (DS-3).
            guard !isHeld() else {
                try? handle.close()
                reply(.refused, to: request, on: session)
                return
            }
            session.handle = handle
            stream(file, from: request.offset, request: request, on: session)
        }
    }

    /// The file, if it is a regular file of exactly the recorded size inside the cap. Nothing else is read.
    private func open(_ file: LANServedFile) -> FileHandle? {
        guard file.byteCount > 0, file.byteCount <= LANFrameCodec.maximumByteCount,
              let values = try? file.fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, Int64(values.fileSize ?? -1) == file.byteCount else { return nil }
        return try? FileHandle(forReadingFrom: file.fileURL)
    }

    // MARK: Sending

    private func reply(
        _ status: LANMediaHeader.Status, to request: LANMediaRequest, on session: Session, file: LANServedFile? = nil
    ) {
        session.status = status
        let header = LANMediaHeader(
            status: status, revisionID: file?.revisionID ?? request.revisionID,
            contentHash: file?.contentHash ?? request.contentHash, byteCount: file?.byteCount ?? 0)
        guard let frame = try? header.encoded() else {
            end(session)
            return
        }
        send(frame, on: session) { [weak self] in self?.finishStream(session) }
    }

    private func stream(_ file: LANServedFile, from offset: Int64, request: LANMediaRequest, on session: Session) {
        let header = LANMediaHeader(
            status: .ok, revisionID: file.revisionID, contentHash: file.contentHash, byteCount: file.byteCount)
        guard let frame = try? header.encoded() else {
            end(session)
            return
        }
        session.status = .ok
        // An offset at the end is a complete file: the header is the whole answer.
        let last = offset >= file.byteCount
        send(frame, on: session) { [weak self] in
            if last { self?.finishStream(session) } else { self?.sendChunk(file, at: offset, request: request, on: session) }
        }
    }

    private func sendChunk(_ file: LANServedFile, at position: Int64, request: LANMediaRequest, on session: Session) {
        guard !session.isEnded, let handle = session.handle else { return }
        let remaining = file.byteCount - position
        let data: Data
        do {
            try handle.seek(toOffset: UInt64(position))
            data = try handle.read(upToCount: Int(min(Int64(configuration.chunkBytes), remaining))) ?? Data()
        } catch {
            end(session)
            return
        }
        guard !data.isEmpty else {
            end(session)
            return
        }
        let next = position + Int64(data.count)
        let isLast = next >= file.byteCount
        send(data, on: session) { [weak self] in
            guard let self, !session.isEnded else { return }
            session.bytesSent += Int64(data.count)
            if isLast {
                self.finishStream(session)
            } else if self.cutHook?(request, session.bytesSent) == true {
                self.end(session)
            } else {
                self.sendChunk(file, at: next, request: request, on: session)
            }
        }
    }

    /// Closes the write side after the last byte (the phone then sees the end of the stream), then waits.
    /// The data and the end of stream are separate sends: a large send marked final was observed to
    /// deliver nothing.
    private func finishStream(_ session: Session) {
        guard !session.isEnded else { return }
        session.connection.send(
            content: nil, contentContext: .finalMessage, isComplete: true,
            completion: .contentProcessed { [weak self] _ in
                guard let self, !session.isEnded else { return }
                self.linger(session)
            })
    }

    /// The connection is not cancelled at once after the last byte: a cancel can discard bytes still in the
    /// send buffer, and the phone would lose the tail of the file. It ends when the phone closes its side,
    /// or after a short linger.
    private func linger(_ session: Session) {
        guard !session.isEnded else { return }
        session.idleTimer?.cancel()
        session.idleTimer = schedule(min(configuration.deadlines.idle, 3), for: session)
        session.connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, _, _ in
            guard let self, !session.isEnded else { return }
            self.end(session)
        }
    }

    private func send(_ data: Data, on session: Session, then done: @escaping @Sendable () -> Void) {
        touch(session)
        session.connection.send(
            content: data, contentContext: .defaultMessage, isComplete: false,
            completion: .contentProcessed { [weak self] error in
                guard let self, !session.isEnded else { return }
                guard error == nil else {
                    self.end(session)
                    return
                }
                self.touch(session)
                done()
            })
    }

    // MARK: Lifecycle and deadlines

    private func schedule(_ seconds: TimeInterval, for session: Session) -> DispatchWorkItem {
        let item = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session else { return }
            serverLog.notice("LAN connection ended by its deadline")
            self.end(session)
        }
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
        return item
    }

    /// Restarts the idle clock. Armed only once the handshake is done.
    private func touch(_ session: Session) {
        guard !session.isEnded else { return }
        session.idleTimer?.cancel()
        session.idleTimer = schedule(configuration.deadlines.idle, for: session)
    }

    private func end(_ session: Session) {
        guard !session.isEnded else { return }
        session.isEnded = true
        session.handshakeTimer?.cancel()
        session.idleTimer?.cancel()
        session.overallTimer?.cancel()
        session.task?.cancel()
        try? session.handle?.close()
        session.handle = nil
        session.connection.stateUpdateHandler = nil
        session.connection.cancel()
        sessions[session.id] = nil
        if session.isReady {
            records = Self.appending(TransferRecord(request: session.request, status: session.status, bytesSent: session.bytesSent), to: records)
            serverLog.notice("LAN transfer ended: \(session.bytesSent, privacy: .public) bytes sent")
        }
    }

    /// `records` with `record` added, dropping the oldest past `recordLimit`.
    static func appending(_ record: TransferRecord, to records: [TransferRecord]) -> [TransferRecord] {
        Array((records + [record]).suffix(recordLimit))
    }

    private func endAllSessions() {
        for session in Array(sessions.values) { end(session) }
    }

    // MARK: Helpers

    private struct PeerKey: Hashable {
        let identity: Data
        let psk: Data
        init(_ peer: LANTLSPeer) {
            identity = peer.identity
            psk = peer.psk
        }
    }

    /// Resumes the start completion exactly once.
    private final class StartupGate: @unchecked Sendable {
        private let lock = NSLock()
        private var completion: (@Sendable (Result<UInt16?, Error>) -> Void)?

        init(_ completion: @escaping @Sendable (Result<UInt16?, Error>) -> Void) { self.completion = completion }

        /// True when this call delivered the result.
        @discardableResult
        func finish(_ result: Result<UInt16?, Error>) -> Bool {
            let pending = lock.withLock { () -> (@Sendable (Result<UInt16?, Error>) -> Void)? in
                defer { completion = nil }
                return completion
            }
            pending?(result)
            return pending != nil
        }
    }
}
