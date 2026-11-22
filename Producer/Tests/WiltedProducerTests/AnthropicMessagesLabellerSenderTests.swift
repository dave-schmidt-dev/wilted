import Foundation
import Testing
@testable import WiltedProducer

@Suite("Anthropic Messages labeller sender", .serialized)
struct AnthropicMessagesLabellerSenderTests {
    private static let key = "test-anthropic-key-not-real"

    // MARK: - Success and request shape

    @Test func sendsExactAnthropicRequest() async throws {
        AnthropicStubProtocol.reset([
            .respond(status: 200, headers: ["Content-Type": "text/event-stream"]),
            .send(sseEvent("message_start", data: #"{"type":"message_start","message":{"usage":{"input_tokens":10,"output_tokens":1}}}"#)),
            .send(sseEvent("content_block_delta", data: #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"ok"}}"#)),
            .send(sseEvent("message_delta", data: #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":12}}"#)),
            .send(sseEvent("message_stop", data: #"{"type":"message_stop"}"#)),
        ])

        let prompt = "label this anthropic episode"
        let request = LabellerRequest(prompt: prompt, modelID: "claude-sonnet-5-5", reasoningLevel: "medium")
        let client = makeClient()
        _ = try await client.send(request, onRequestStarted: {}, onProgress: { _ in })

        let capturedRequests = AnthropicStubProtocol.requests
        #expect(capturedRequests.count == 1)
        let captured = try #require(capturedRequests.first)
        #expect(captured.method == "POST")
        #expect(captured.url == AnthropicMessagesLabellerSender.endpoint)
        #expect(captured.headers["x-api-key"] == Self.key)
        #expect(captured.headers["anthropic-version"] == "2023-06-01")
        #expect(captured.headers["Content-Type"] == "application/json")
        #expect(captured.headers["Accept"] == "text/event-stream")
        #expect(captured.headers["User-Agent"] == "wilted-ad-labeller/1")

        let body = try #require(try JSONSerialization.jsonObject(with: captured.body) as? [String: Any])
        #expect(Set(body.keys) == ["model", "max_tokens", "messages", "output_config", "stream"])
        #expect(body["model"] as? String == "claude-sonnet-5-5")
        #expect(body["max_tokens"] as? Int == 16_384)
        #expect(body["stream"] as? Bool == true)

        let outputConfig = try #require(body["output_config"] as? [String: Any])
        #expect(outputConfig["effort"] as? String == "medium")

        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
        #expect(messages[0]["content"] as? String == prompt)

        let bodyString = String(decoding: captured.body, as: UTF8.self)
        #expect(!bodyString.contains(Self.key), "key leaked into body")
    }

    @Test func thinkingLevelMapsToEffort() {
        for level in ["low", "medium", "high", "xhigh", "max"] {
            #expect(AnthropicMessagesLabellerSender.outputConfig(for: level)
                == AnthropicMessagesLabellerSender.AnthropicOutputConfig(effort: level))
        }
        #expect(AnthropicMessagesLabellerSender.outputConfig(for: "default") == nil)
        #expect(AnthropicMessagesLabellerSender.outputConfig(for: "  ") == nil)
        #expect(AnthropicMessagesLabellerSender.maxTokens == 16_384)
    }

    @Test func streamsMultiChunkAnswerWithUsageAndProgress() async throws {
        AnthropicStubProtocol.reset([
            .respond(status: 200, headers: ["Content-Type": "text/event-stream"]),
            .send(sseEvent("message_start", data: #"{"type":"message_start","message":{"usage":{"input_tokens":20,"output_tokens":2}}}"#)),
            .send(sseEvent("content_block_delta", data: #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"{\"breaks\":"}}"#)),
            .send(sseEvent("content_block_delta", data: #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"[]}"}}"#)),
            .send(sseEvent("message_delta", data: #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":30}}"#)),
            .send(sseEvent("message_stop", data: #"{"type":"message_stop"}"#)),
        ])

        let started = Counter()
        let progress = ProgressRecorder()
        let response = try await makeClient().send(
            LabellerRequest(prompt: "find", modelID: "claude-sonnet-5-5", reasoningLevel: "low"),
            onRequestStarted: { started.increment() },
            onProgress: { progress.append($0) }
        )

        #expect(response.text == #"{"breaks":[]}"#)
        #expect(response.usage == LabellerUsage(promptTokens: 20, completionTokens: 30))
        #expect(response.requestCount == 1)
        #expect(started.value == 1)
        #expect(!progress.values.isEmpty)
    }

    @Test func acceptsANonStreamedJSONBody() async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "type": "message",
            "content": [
                ["type": "thinking", "thinking": "ignoring thinking block"],
                ["type": "text", "text": #"{"breaks":[]}"#]
            ],
            "stop_reason": "end_turn",
            "usage": ["input_tokens": 15, "output_tokens": 25]
        ])
        AnthropicStubProtocol.reset([
            .respond(status: 200, headers: ["Content-Type": "application/json"]),
            .send(body),
        ])
        let response = try await makeClient().send(
            LabellerRequest(prompt: "find", modelID: "claude-sonnet-5-5", reasoningLevel: "low"),
            onRequestStarted: {},
            onProgress: { _ in }
        )
        #expect(response.text == #"{"breaks":[]}"#)
        #expect(response.usage == LabellerUsage(promptTokens: 15, completionTokens: 25))
    }

    // MARK: - Failure mapping

    @Test func mapsHTTPFailures() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let auth = Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid key"}}"#.utf8)
        let permission = Data(#"{"type":"error","error":{"type":"permission_error","message":"not allowed"}}"#.utf8)
        let notFound = Data(#"{"type":"error","error":{"type":"not_found_error","message":"model not found"}}"#.utf8)
        let rateLimit = Data(#"{"type":"error","error":{"type":"rate_limit_error","message":"rate limited"}}"#.utf8)
        let credit = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"Your credit balance is too low"}}"#.utf8)
        let overloaded = Data(#"{"type":"error","error":{"type":"overloaded_error","message":"overloaded"}}"#.utf8)

        #expect(AnthropicMessagesLabellerSender.failure(status: 401, headers: [:], body: auth, now: now) == .keyRejected)
        #expect(AnthropicMessagesLabellerSender.failure(status: 403, headers: [:], body: permission, now: now) == .keyRejected)
        #expect(AnthropicMessagesLabellerSender.failure(status: 404, headers: [:], body: notFound, now: now) == .modelUnavailable)
        #expect(AnthropicMessagesLabellerSender.failure(status: 429, headers: ["Retry-After": "30"], body: rateLimit, now: now)
                == .rateLimited(retryAfter: 30))
        #expect(AnthropicMessagesLabellerSender.failure(status: 402, headers: [:], body: Data(), now: now) == .usageLimit)
        #expect(AnthropicMessagesLabellerSender.failure(status: 400, headers: [:], body: credit, now: now) == .usageLimit)
        #expect(AnthropicMessagesLabellerSender.failure(status: 400, headers: [:], body: notFound, now: now) == .modelUnavailable)
        #expect(AnthropicMessagesLabellerSender.failure(status: 529, headers: [:], body: overloaded, now: now) == .temporary)
        #expect(AnthropicMessagesLabellerSender.failure(status: 500, headers: [:], body: Data(), now: now) == .temporary)
        #expect(AnthropicMessagesLabellerSender.failure(status: 503, headers: [:], body: Data(), now: now) == .temporary)
    }

    @Test func refusesCrossHostAndSameHostRedirects() async throws {
        for targetURL in ["https://evil.example.test/anthropic", "https://api.anthropic.com/redirected", "http://api.anthropic.com/v1/messages"] {
            AnthropicStubProtocol.reset([.redirect(URL(string: targetURL)!)])
            do {
                _ = try await makeClient().send(
                    LabellerRequest(prompt: "p", modelID: "m", reasoningLevel: "l"),
                    onRequestStarted: {},
                    onProgress: { _ in }
                )
                Issue.record("expected redirect refusal for \(targetURL)")
            } catch {
                #expect(error as? LabellerFailure == .temporary)
            }
            #expect(AnthropicStubProtocol.requests.count == 1)
        }
    }

    @Test func replyPastSizeCapIsRefusedAsUnusable() async throws {
        AnthropicStubProtocol.reset([
            .respond(status: 200, headers: ["Content-Type": "text/event-stream"]),
            .send(Data(repeating: 0x20, count: 8 * 1_024 * 1_024 + 1)),
        ])
        do {
            _ = try await makeClient().send(
                LabellerRequest(prompt: "p", modelID: "m", reasoningLevel: "l"),
                onRequestStarted: {},
                onProgress: { _ in }
            )
            Issue.record("expected oversized reply refusal")
        } catch {
            #expect(error as? LabellerFailure == .unusableAnswer)
        }
    }

    @Test func missingKeyIsRejectedWithoutRequest() async throws {
        AnthropicStubProtocol.reset([])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnthropicStubProtocol.self]
        let keyless = AnthropicMessagesLabellerSender(
            keyStore: InMemoryLabellerKeyStore(key: nil, provider: .anthropicKey),
            configuration: configuration
        )
        let started = Counter()
        do {
            _ = try await keyless.send(
                LabellerRequest(prompt: "p", modelID: "m", reasoningLevel: "l"),
                onRequestStarted: { started.increment() },
                onProgress: { _ in }
            )
            Issue.record("expected keyRejected")
        } catch {
            #expect(error as? LabellerFailure == .keyRejected)
        }
        #expect(started.value == 0)
        #expect(AnthropicStubProtocol.requests.isEmpty)
    }

    @Test func failuresNeverExposeKey() async throws {
        let auth = Data(#"{"type":"error","error":{"type":"authentication_error","message":"Invalid key"}}"#.utf8)
        AnthropicStubProtocol.reset([.respond(status: 401, headers: [:]), .send(auth)])
        do {
            _ = try await makeClient().send(
                LabellerRequest(prompt: "p", modelID: "m", reasoningLevel: "l"),
                onRequestStarted: {},
                onProgress: { _ in }
            )
            Issue.record("expected keyRejected")
        } catch {
            #expect(error as? LabellerFailure == .keyRejected)
            let desc = "\(error)"
            #expect(!desc.contains(Self.key))
        }
    }

    @Test func failureDetailExtractsErrorType() {
        let body = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"Invalid input"}}"#.utf8)
        let detail = AnthropicMessagesLabellerSender.failureDetail(status: 400, body: body)
        #expect(detail == LabellerFailureDetail(status: 400, errorType: "invalid_request_error"))
        #expect(!String(describing: detail).contains("Invalid input"))
    }

    // MARK: - Helpers

    private func makeClient() -> AnthropicMessagesLabellerSender {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnthropicStubProtocol.self]
        return AnthropicMessagesLabellerSender(
            keyStore: InMemoryLabellerKeyStore(key: Self.key, provider: .anthropicKey),
            configuration: configuration
        )
    }

    private func sseEvent(_ event: String, data: String) -> Data {
        Data("event: \(event)\ndata: \(data)\n\n".utf8)
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

private final class AnthropicStubProtocol: URLProtocol, @unchecked Sendable {
    enum Step {
        case redirect(URL)
        case respond(status: Int, headers: [String: String])
        case send(Data)
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

    static func reset(_ script: [Step]) {
        lock.withLock {
            steps = script
            captured = []
        }
    }

    static var requests: [CapturedRequest] { lock.withLock { captured } }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.anthropic.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.extractBody(from: request)
        Self.lock.withLock {
            Self.captured.append(CapturedRequest(
                method: request.httpMethod,
                url: request.url,
                headers: request.allHTTPHeaderFields ?? [:],
                body: body
            ))
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
            }
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func extractBody(from request: URLRequest) -> Data {
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
