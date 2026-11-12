import Foundation
import Security
import Testing
@testable import WiltedProducer

@Suite("Labeller client", .serialized)
struct LabellerClientTests {
    private static let key = "test-key-not-real"

    // MARK: - Success and request shape

    @Test func streamsMultiChunkAnswerWithUsageAndProgress() async throws {
        let chunk1 = sseChunk(content: #"{"breaks":["#)
        let chunk2 = sseChunk(reasoning: "thinking")
        let chunk3 = sseChunk(content: "]}")
        let keepAlive = Data(": keep-alive\n\n".utf8)
        let usageChunk = sseChunk(finishReason: "stop", usage: [
            "prompt_tokens": 12, "completion_tokens": 34,
            "completion_tokens_details": ["reasoning_tokens": 5],
        ])
        let done = Data("data: [DONE]\n\n".utf8)
        let totalBytes = chunk1.count + chunk2.count + chunk3.count + keepAlive.count + usageChunk.count + done.count
        LabellerStubProtocol.reset([
            .respond(status: 200, headers: ["Content-Type": "text/event-stream"]),
            .send(chunk1), .send(chunk2), .send(chunk3), .send(keepAlive), .send(usageChunk), .send(done),
        ])

        let started = Counter()
        let progress = ProgressRecorder()
        let response = try await client().send(request(), onRequestStarted: { started.increment() }) {
            progress.append($0)
        }

        #expect(response.text == #"{"breaks":[]}"#)
        #expect(response.usage == LabellerUsage(promptTokens: 12, completionTokens: 34, reasoningTokens: 5))
        #expect(response.requestCount == 1)
        #expect(started.value == 1)
        #expect(!progress.values.isEmpty)
        #expect(progress.values.last == LabellerProgress(bytesReceived: totalBytes, answerCharacters: 13))
    }

    @Test func sendsExactlyOneWellFormedRequestPerCall() async throws {
        LabellerStubProtocol.reset([
            .respond(status: 200, headers: ["Content-Type": "text/event-stream"]),
            .send(sseChunk(content: "ok")),
            .send(Data("data: [DONE]\n\n".utf8)),
        ])
        let prompt = "label this episode"
        let labellerRequest = LabellerRequest(prompt: prompt, modelID: "test-model", reasoningLevel: "medium")
        _ = try await client().send(labellerRequest, onRequestStarted: {}, onProgress: { _ in })
        _ = try await client().send(labellerRequest, onRequestStarted: {}, onProgress: { _ in })

        let requests = LabellerStubProtocol.requests
        #expect(requests.count == 2)
        for captured in requests {
            #expect(captured.method == "POST")
            #expect(captured.url == LabellerClient.endpoint)
            #expect(captured.headers["Authorization"] == "Bearer \(Self.key)")
            #expect(captured.headers["Content-Type"] == "application/json")
            #expect(captured.headers["Accept"] == "text/event-stream")
            #expect(captured.headers["User-Agent"] == "wilted-ad-labeller/1")
            #expect(UUID(uuidString: captured.headers["x-opencode-session"] ?? "") != nil)
            let body = try #require(try JSONSerialization.jsonObject(with: captured.body) as? [String: Any])
            #expect(Set(body.keys) == ["model", "messages", "reasoning_effort", "stream", "stream_options"])
            #expect(body["model"] as? String == "test-model")
            #expect(body["reasoning_effort"] as? String == "medium")
            #expect(body["stream"] as? Bool == true)
            #expect((body["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true)
            let messages = try #require(body["messages"] as? [[String: Any]])
            #expect(messages.count == 1)
            #expect(messages[0]["role"] as? String == "user")
            #expect(messages[0]["content"] as? String == prompt)
        }
        let first = try #require(requests.first?.headers["x-opencode-session"])
        let second = try #require(requests.last?.headers["x-opencode-session"])
        #expect(first != second)
    }

    @Test func acceptsANonStreamedJSONBody() async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": #"{"breaks":[]}"#], "finish_reason": "stop"]],
            "usage": ["prompt_tokens": 3, "completion_tokens": 4,
                      "opencode": ["tokens": ["reasoning": 9]]],
        ])
        LabellerStubProtocol.reset([
            .respond(status: 200, headers: ["Content-Type": "application/json"]),
            .send(body),
        ])
        let response = try await client().send(request(), onRequestStarted: {}, onProgress: { _ in })
        #expect(response.text == #"{"breaks":[]}"#)
        #expect(response.usage == LabellerUsage(promptTokens: 3, completionTokens: 4, reasoningTokens: 9))
    }

    // MARK: - Failure mapping

    @Test func mapsHTTPFailures() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let auth = Data(#"{"error":{"type":"authentication_error","message":"Invalid credential"}}"#.utf8)
        let authWrapped = Data(#"{"type":"error","error":{"type":"authentication_error","message":"Invalid credential"}}"#.utf8)
        let budget = Data(#"{"error":{"type":"rate_limit_error","message":"Monthly budget exceeded"}}"#.utf8)
        let quota = Data(#"{"error":{"type":"quota_exceeded","message":"Too many requests"}}"#.utf8)
        let model = Data(#"{"error":{"type":"invalid_request_error","message":"Model 'x' does not exist"}}"#.utf8)
        let missingSession = Data(#"{"type":"error","error":{"type":"MissingSessionID","message":"A session id is required"}}"#.utf8)

        #expect(LabellerClient.failure(status: 401, headers: [:], body: auth, now: now) == .keyRejected)
        #expect(LabellerClient.failure(status: 403, headers: [:], body: authWrapped, now: now) == .keyRejected)
        #expect(LabellerClient.failure(status: 402, headers: [:], body: Data(), now: now) == .usageLimit)
        #expect(LabellerClient.failure(status: 429, headers: ["Retry-After": "120"], body: Data(), now: now)
                == .rateLimited(retryAfter: 120))
        #expect(LabellerClient.failure(status: 429, headers: ["retry-after": "Tue, 14 Nov 2023 22:14:50 GMT"],
                                        body: Data(), now: now) == .rateLimited(retryAfter: 90))
        #expect(LabellerClient.failure(status: 429, headers: [:], body: Data(), now: now) == .rateLimited(retryAfter: nil))
        #expect(LabellerClient.failure(status: 429, headers: ["Retry-After": "soon"], body: Data(), now: now)
                == .rateLimited(retryAfter: nil))
        #expect(LabellerClient.failure(status: 429, headers: ["Retry-After": "-5"], body: Data(), now: now)
                == .rateLimited(retryAfter: 0))
        #expect(LabellerClient.failure(status: 429, headers: ["Retry-After": "60"], body: budget, now: now) == .usageLimit)
        #expect(LabellerClient.failure(status: 429, headers: [:], body: quota, now: now) == .usageLimit)
        #expect(LabellerClient.failure(status: 404, headers: [:], body: Data(), now: now) == .modelUnavailable)
        #expect(LabellerClient.failure(status: 400, headers: [:], body: model, now: now) == .modelUnavailable)
        #expect(LabellerClient.failure(status: 400, headers: [:], body: missingSession, now: now) == .temporary)
        #expect(LabellerClient.failure(status: 500, headers: [:], body: Data(), now: now) == .temporary)
        #expect(LabellerClient.failure(status: 503, headers: [:], body: Data(), now: now) == .temporary)
        #expect(LabellerClient.failure(status: 302, headers: [:], body: Data(), now: now) == .temporary)
    }

    @Test func refusesCrossHostRedirects() async throws {
        LabellerStubProtocol.reset([
            .redirect(URL(string: "https://evil.example.test/collect")!),
        ])
        do {
            _ = try await client().send(request(), onRequestStarted: {}, onProgress: { _ in })
            Issue.record("expected redirect refusal")
        } catch { #expect(error as? LabellerFailure == .temporary) }
        let requests = LabellerStubProtocol.requests
        #expect(requests.count == 1, "the second host received no request")
        #expect(requests.allSatisfy { $0.url?.host == "opencode.ai" })
    }

    @Test func refusesSameHostAndPlainHTTPRedirects() async throws {
        for target in ["https://opencode.ai/elsewhere", "http://opencode.ai/inference"] {
            LabellerStubProtocol.reset([.redirect(URL(string: target)!)])
            do {
                _ = try await client().send(request(), onRequestStarted: {}, onProgress: { _ in })
                Issue.record("expected redirect refusal for \(target)")
            } catch { #expect(error as? LabellerFailure == .temporary) }
            #expect(LabellerStubProtocol.requests.count == 1, "the redirect target received no request")
        }
    }

    @Test func aReplyPastTheSizeCapIsRefusedAsUnusable() async throws {
        LabellerStubProtocol.reset([
            .respond(status: 200, headers: ["Content-Type": "text/event-stream"]),
            .send(Data(repeating: 0x20, count: 8 * 1_024 * 1_024 + 1)),
        ])
        do {
            _ = try await client().send(request(), onRequestStarted: {}, onProgress: { _ in })
            Issue.record("expected the oversized reply to be refused")
        } catch { #expect(error as? LabellerFailure == .unusableAnswer) }
    }

    @Test func cancellationMidStreamThrowsCancellationError() async throws {
        let gate = AsyncGate()
        LabellerStubProtocol.reset([
            .respond(status: 200, headers: ["Content-Type": "text/event-stream"]),
            .send(sseChunk(content: "partial")),
            .hang,
        ], gate: gate)
        let task = Task {
            try await client().send(request(), onRequestStarted: {}, onProgress: { _ in })
        }
        await gate.wait()
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch { #expect(error is CancellationError) }
    }

    @Test func timeLimitFiresThroughTheInjectedTimer() async throws {
        LabellerStubProtocol.reset([
            .respond(status: 200, headers: ["Content-Type": "text/event-stream"]),
            .hang,
        ])
        let immediate: @Sendable (Duration) async throws -> Void = { _ in }
        do {
            _ = try await client(sleep: immediate).send(request(), onRequestStarted: {}, onProgress: { _ in })
            Issue.record("expected the time limit")
        } catch { #expect(error as? LabellerFailure == .temporary) }
    }

    @Test func aStreamCutBeforeDoneIsTemporaryAndAnEmptyAnswerIsUnusable() async throws {
        try await expectFailure([
            .respond(status: 200, headers: ["Content-Type": "text/event-stream"]),
            .send(sseChunk(content: "partial answer")),
        ], expected: .temporary)
        try await expectFailure([
            .respond(status: 200, headers: ["Content-Type": "text/event-stream"]),
            .send(sseChunk(finishReason: "stop")),
            .send(Data("data: [DONE]\n\n".utf8)),
        ], expected: .unusableAnswer)
        try await expectFailure([
            .respond(status: 200, headers: ["Content-Type": "text/event-stream"]),
            .send(sseChunk(content: "partial", finishReason: "length")),
            .send(Data("data: [DONE]\n\n".utf8)),
        ], expected: .unusableAnswer)
    }

    @Test func aMissingKeyIsRejectedWithoutAnyRequest() async throws {
        LabellerStubProtocol.reset([
            .respond(status: 200, headers: ["Content-Type": "text/event-stream"]),
            .send(Data("data: [DONE]\n\n".utf8)),
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LabellerStubProtocol.self]
        let keyless = LabellerClient(keyStore: InMemoryLabellerKeyStore(), configuration: configuration)
        let started = Counter()
        do {
            _ = try await keyless.send(request(), onRequestStarted: { started.increment() }, onProgress: { _ in })
            Issue.record("expected keyRejected")
        } catch { #expect(error as? LabellerFailure == .keyRejected) }
        #expect(started.value == 0)
        #expect(LabellerStubProtocol.requests.isEmpty)
    }

    @Test func failuresNeverExposeTheKey() async throws {
        let auth = Data(#"{"error":{"type":"authentication_error","message":"Invalid credential"}}"#.utf8)
        try await expectFailure([.respond(status: 401, headers: [:]), .send(auth)], expected: .keyRejected)
        try await expectFailure([.respond(status: 402, headers: [:]), .send(Data("{}".utf8))], expected: .usageLimit)
        try await expectFailure([.respond(status: 404, headers: [:]), .send(Data("{}".utf8))], expected: .modelUnavailable)
        try await expectFailure([.respond(status: 429, headers: ["Retry-After": "60"]), .send(Data("{}".utf8))],
                                expected: .rateLimited(retryAfter: 60))
        try await expectFailure([.respond(status: 500, headers: [:]), .send(Data("{}".utf8))], expected: .temporary)
    }

    // MARK: - Key stores

    @Test func inMemoryKeyStoreTrimsRefusesEmptyAndReplaces() throws {
        let store = InMemoryLabellerKeyStore()
        #expect(!store.hasKey())
        #expect(try store.read() == nil)
        #expect(throws: LabellerKeyStoreError.emptyKey) { try store.save(" \n\t ") }
        try store.save("  sk-test\n\n")
        #expect(try store.read() == "sk-test")
        #expect(store.hasKey())
        try store.save("second")
        #expect(try store.read() == "second")
        try store.remove()
        #expect(!store.hasKey())
        #expect(try store.read() == nil)
    }

    @Test func keychainQueriesUseADeviceOnlyDataProtectionItem() {
        let base = KeychainLabellerKeyStore.baseQuery(service: "svc")
        #expect(base[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(base[kSecAttrService as String] as? String == "svc")
        #expect(base[kSecAttrAccount as String] as? String == KeychainLabellerKeyStore.account)
        #expect(base[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(base[kSecUseDataProtectionKeychain as String] as? Bool == true)
        let add = KeychainLabellerKeyStore.addQuery(service: "svc", keyData: Data("k".utf8))
        #expect(add[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(add[kSecValueData as String] as? Data == Data("k".utf8))
        let read = KeychainLabellerKeyStore.readQuery(service: "svc")
        #expect(read[kSecReturnData as String] as? Bool == true)
        #expect(read[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
    }

    @Test func failureDetailKeepsOnlyTheStatusAndASanitisedType() {
        let auth = Data(#"{"error":{"type":"authentication_error","message":"Invalid credential"}}"#.utf8)
        let detail = LabellerClient.failureDetail(status: 401, body: auth)
        #expect(detail == LabellerFailureDetail(status: 401, errorType: "authentication_error"))
        #expect(!String(describing: detail).contains("Invalid credential"))

        let messy = Data(#"{"error":{"type":"bad type!<x>/y","message":"m"}}"#.utf8)
        #expect(LabellerClient.failureDetail(status: 403, body: messy).errorType == "badtypexy")
        let topLevel = Data(#"{"type":"overloaded_error"}"#.utf8)
        #expect(LabellerClient.failureDetail(status: 503, body: topLevel).errorType == "overloaded_error")
        #expect(LabellerClient.failureDetail(status: 500, body: Data("<html>oops</html>".utf8)).errorType == nil)
        #expect(LabellerClient.failureDetail(status: 500, body: Data()).errorType == nil)
        let long = Data(#"{"error":{"type":"\#(String(repeating: "a", count: 60))"}}"#.utf8)
        #expect(LabellerClient.failureDetail(status: 400, body: long).errorType?.count == 48)
    }

    @Test func aFailingResponseReportsTheDetailBeforeTheThrow() async throws {
        let body = Data(#"{"error":{"type":"model_restricted","message":"secret words"}}"#.utf8)
        LabellerStubProtocol.reset([
            .respond(status: 403, headers: ["Content-Type": "application/json"]),
            .send(body),
        ])
        let progress = ProgressRecorder()
        do {
            _ = try await client().send(request(), onRequestStarted: {}, onProgress: { progress.append($0) })
            Issue.record("expected a failure")
        } catch {
            #expect(error as? LabellerFailure == .keyRejected)
        }
        #expect(progress.values.last?.failure == LabellerFailureDetail(status: 403, errorType: "model_restricted"))
    }

    // MARK: - Helpers

    private func request() -> LabellerRequest {
        LabellerRequest(prompt: "label this", modelID: "test-model", reasoningLevel: "low")
    }

    private func client(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) -> LabellerClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LabellerStubProtocol.self]
        return LabellerClient(keyStore: InMemoryLabellerKeyStore(key: Self.key),
                              configuration: configuration, sleep: sleep)
    }

    private func expectFailure(_ script: [LabellerStubProtocol.Step], expected: LabellerFailure) async throws {
        LabellerStubProtocol.reset(script)
        do {
            _ = try await client().send(request(), onRequestStarted: {}, onProgress: { _ in })
            Issue.record("expected \(expected)")
        } catch {
            #expect(error as? LabellerFailure == expected)
            for description in [String(describing: error), "\(error)", (error as NSError).localizedDescription] {
                #expect(!description.contains(Self.key), "the key leaked into: \(description)")
            }
        }
    }

    /// One `data:` server-sent-event line, as the provider sends it.
    private func sseChunk(content: String? = nil, reasoning: String? = nil,
                          finishReason: String? = nil, usage: [String: Any]? = nil) -> Data {
        var delta: [String: Any] = [:]
        if let content { delta["content"] = content }
        if let reasoning { delta["reasoning_content"] = reasoning }
        var choice: [String: Any] = ["delta": delta]
        if let finishReason { choice["finish_reason"] = finishReason }
        var object: [String: Any] = ["choices": [choice]]
        if let usage { object["usage"] = usage }
        let json = try! JSONSerialization.data(withJSONObject: object)
        return Data("data: ".utf8) + json + Data("\n\n".utf8)
    }
}

/// Scripts responses and captures requests for the labeller endpoint. The suite is
/// serialized, so the shared script is reset before each call.
private final class LabellerStubProtocol: URLProtocol, @unchecked Sendable {
    enum Step {
        case redirect(URL)
        case respond(status: Int, headers: [String: String])
        case send(Data)
        case hang
    }

    struct CapturedRequest: Sendable {
        var method: String?
        var url: URL?
        var headers: [String: String]
        var body: Data
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var steps: [Step] = []
    private nonisolated(unsafe) static var captured: [CapturedRequest] = []
    private nonisolated(unsafe) static var hangGate: AsyncGate?

    static func reset(_ script: [Step], gate: AsyncGate? = nil) {
        lock.withLock {
            steps = script
            captured = []
            hangGate = gate
        }
    }

    static var requests: [CapturedRequest] { lock.withLock { captured } }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "opencode.ai"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.body(of: request)
        Self.lock.withLock {
            Self.captured.append(CapturedRequest(method: request.httpMethod, url: request.url,
                                            headers: request.allHTTPHeaderFields ?? [:], body: body))
        }
        let script = Self.lock.withLock { Self.steps }
        for step in script {
            switch step {
            case .redirect(let target):
                let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
                                               headerFields: ["Location": target.absoluteString])!
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
                return
            case .respond(let status, let headers):
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                               headerFields: headers)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            case .send(let data):
                client?.urlProtocol(self, didLoad: data)
            case .hang:
                if let gate = Self.lock.withLock({ Self.hangGate }) {
                    Task { await gate.open() }
                }
                return
            }
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLProtocol sees the body as a stream, not as `httpBody`.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let capacity = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: capacity)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LabellerProgress] = []
    var values: [LabellerProgress] { lock.withLock { storage } }
    func append(_ value: LabellerProgress) { lock.withLock { storage.append(value) } }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
