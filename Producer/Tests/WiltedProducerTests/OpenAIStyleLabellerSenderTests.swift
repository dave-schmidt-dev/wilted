import Foundation
import Testing
@testable import WiltedProducer

@Suite("OpenAI-style labeller sender", .serialized)
struct OpenAIStyleLabellerSenderTests {
    private static let key = "test-openai-key-not-real"

    // MARK: - Success and request shape

    @Test func sendsExactOpenAIRequest() async throws {
        OpenAIStyleStubProtocol.reset([
            .respond(status: 200, headers: ["Content-Type": "text/event-stream"]),
            .send(sseChunk(content: "ok")),
            .send(Data("data: [DONE]\n\n".utf8)),
        ])
        let prompt = "label this openai episode"
        let request = LabellerRequest(prompt: prompt, modelID: "gpt-4o", reasoningLevel: "high")
        let client = makeClient(target: .openAI)
        _ = try await client.send(request, onRequestStarted: {}, onProgress: { _ in })

        let capturedRequests = OpenAIStyleStubProtocol.requests
        #expect(capturedRequests.count == 1)
        let captured = try #require(capturedRequests.first)
        #expect(captured.method == "POST")
        #expect(captured.url == OpenAIStyleLabellerSender.openAIEndpoint)
        #expect(captured.headers["Authorization"] == "Bearer \(Self.key)")
        #expect(captured.headers["Content-Type"] == "application/json")
        #expect(captured.headers["Accept"] == "text/event-stream")
        #expect(captured.headers["User-Agent"] == "wilted-ad-labeller/1")

        let body = try #require(try JSONSerialization.jsonObject(with: captured.body) as? [String: Any])
        #expect(Set(body.keys) == ["model", "messages", "reasoning_effort", "stream", "stream_options"])
        #expect(body["model"] as? String == "gpt-4o")
        #expect(body["reasoning_effort"] as? String == "high")
        #expect(body["stream"] as? Bool == true)
        #expect((body["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true)

        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
        #expect(messages[0]["content"] as? String == prompt)

        let bodyString = String(decoding: captured.body, as: UTF8.self)
        #expect(!bodyString.contains(Self.key), "key leaked into body")
    }

    @Test func sendsExactOpenRouterRequest() async throws {
        OpenAIStyleStubProtocol.reset([
            .respond(status: 200, headers: ["Content-Type": "text/event-stream"]),
            .send(sseChunk(content: "ok")),
            .send(Data("data: [DONE]\n\n".utf8)),
        ])
        let prompt = "label this openrouter episode"
        let request = LabellerRequest(prompt: prompt, modelID: "meta-llama/llama-3.3-70b-instruct", reasoningLevel: "medium")
        let client = makeClient(target: .openRouter)
        _ = try await client.send(request, onRequestStarted: {}, onProgress: { _ in })

        let capturedRequests = OpenAIStyleStubProtocol.requests
        #expect(capturedRequests.count == 1)
        let captured = try #require(capturedRequests.first)
        #expect(captured.method == "POST")
        #expect(captured.url == OpenAIStyleLabellerSender.openRouterEndpoint)
        #expect(captured.headers["Authorization"] == "Bearer \(Self.key)")
        #expect(captured.headers["Content-Type"] == "application/json")
        #expect(captured.headers["Accept"] == "text/event-stream")
        #expect(captured.headers["User-Agent"] == "wilted-ad-labeller/1")

        let body = try #require(try JSONSerialization.jsonObject(with: captured.body) as? [String: Any])
        #expect(Set(body.keys) == ["model", "messages", "reasoning", "stream", "stream_options"])
        #expect(body["model"] as? String == "meta-llama/llama-3.3-70b-instruct")
        let reasoning = try #require(body["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == "medium")
        #expect(body["stream"] as? Bool == true)
        #expect((body["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true)

        let bodyString = String(decoding: captured.body, as: UTF8.self)
        #expect(!bodyString.contains(Self.key), "key leaked into body")
    }

    @Test func providerCheckCapsOutputOmitsReasoningAndAcceptsLengthFinish() async throws {
        for target in OpenAIStyleLabellerSender.Target.allCases {
            OpenAIStyleStubProtocol.reset([
                .respond(status: 200, headers: ["Content-Type": "text/event-stream"]),
                .send(sseChunk(finishReason: "length")),
                .send(Data("data: [DONE]\n\n".utf8)),
            ])
            let model = target == .openAI ? "gpt-4o-mini" : "openai/gpt-4o-mini"
            let response = try await makeClient(target: target).send(
                LabellerRequest(
                    prompt: "Reply OK.", modelID: model, reasoningLevel: "low", purpose: .providerCheck
                ),
                onRequestStarted: {},
                onProgress: { _ in }
            )

            #expect(response.text.isEmpty)
            let captured = try #require(OpenAIStyleStubProtocol.requests.first)
            let body = try #require(try JSONSerialization.jsonObject(with: captured.body) as? [String: Any])
            #expect(body["max_completion_tokens"] as? Int == (target == .openAI ? 1 : nil))
            #expect(body["max_tokens"] as? Int == (target == .openRouter ? 1 : nil))
            #expect(body["reasoning_effort"] == nil)
            #expect(body["reasoning"] == nil)
            let message = try #require((body["messages"] as? [[String: Any]])?.first)
            #expect(message["content"] as? String == "Reply OK.")
        }
    }

    @Test func streamsMultiChunkAnswerWithUsageAndProgress() async throws {
        let chunk1 = sseChunk(content: #"{"breaks":["#)
        let chunk2 = sseChunk(content: "]}")
        let usageChunk = sseChunk(finishReason: "stop", usage: [
            "prompt_tokens": 15, "completion_tokens": 25,
            "completion_tokens_details": ["reasoning_tokens": 7],
        ])
        let done = Data("data: [DONE]\n\n".utf8)
        OpenAIStyleStubProtocol.reset([
            .respond(status: 200, headers: ["Content-Type": "text/event-stream"]),
            .send(chunk1), .send(chunk2), .send(usageChunk), .send(done),
        ])

        let started = Counter()
        let progress = ProgressRecorder()
        let response = try await makeClient(target: .openAI).send(
            LabellerRequest(prompt: "find", modelID: "m", reasoningLevel: "low"),
            onRequestStarted: { started.increment() },
            onProgress: { progress.append($0) }
        )

        #expect(response.text == #"{"breaks":[]}"#)
        #expect(response.usage == LabellerUsage(promptTokens: 15, completionTokens: 25, reasoningTokens: 7))
        #expect(response.requestCount == 1)
        #expect(started.value == 1)
        #expect(!progress.values.isEmpty)
    }

    @Test func acceptsANonStreamedJSONBody() async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": #"{"breaks":[]}"#], "finish_reason": "stop"]],
            "usage": ["prompt_tokens": 5, "completion_tokens": 8,
                      "completion_tokens_details": ["reasoning_tokens": 3]],
        ])
        OpenAIStyleStubProtocol.reset([
            .respond(status: 200, headers: ["Content-Type": "application/json"]),
            .send(body),
        ])
        let response = try await makeClient(target: .openRouter).send(
            LabellerRequest(prompt: "find", modelID: "m", reasoningLevel: "low"),
            onRequestStarted: {},
            onProgress: { _ in }
        )
        #expect(response.text == #"{"breaks":[]}"#)
        #expect(response.usage == LabellerUsage(promptTokens: 5, completionTokens: 8, reasoningTokens: 3))
    }

    // MARK: - Failure mapping

    @Test func mapsHTTPFailures() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let auth = Data(#"{"error":{"type":"invalid_api_key","message":"Invalid key"}}"#.utf8)
        let budget = Data(#"{"error":{"type":"insufficient_quota","message":"Quota exceeded"}}"#.utf8)
        let model = Data(#"{"error":{"type":"model_not_found","message":"The model does not exist"}}"#.utf8)

        #expect(OpenAIStyleLabellerSender.failure(status: 401, headers: [:], body: auth, now: now) == .keyRejected)
        #expect(OpenAIStyleLabellerSender.failure(status: 403, headers: [:], body: auth, now: now) == .keyRejected)
        #expect(OpenAIStyleLabellerSender.failure(status: 402, headers: [:], body: Data(), now: now) == .usageLimit)
        #expect(OpenAIStyleLabellerSender.failure(status: 429, headers: ["Retry-After": "45"], body: Data(), now: now)
                == .rateLimited(retryAfter: 45))
        #expect(OpenAIStyleLabellerSender.failure(status: 429, headers: [:], body: budget, now: now) == .usageLimit)
        #expect(OpenAIStyleLabellerSender.failure(status: 404, headers: [:], body: Data(), now: now) == .modelUnavailable)
        #expect(OpenAIStyleLabellerSender.failure(status: 400, headers: [:], body: model, now: now) == .modelUnavailable)
        #expect(OpenAIStyleLabellerSender.failure(status: 500, headers: [:], body: Data(), now: now) == .temporary)
        #expect(OpenAIStyleLabellerSender.failure(status: 503, headers: [:], body: Data(), now: now) == .temporary)
    }

    @Test func refusesCrossHostAndSameHostRedirects() async throws {
        for targetURL in ["https://evil.example.test/leak", "https://api.openai.com/redirected", "http://api.openai.com/v1/chat/completions"] {
            OpenAIStyleStubProtocol.reset([.redirect(URL(string: targetURL)!)])
            do {
                _ = try await makeClient(target: .openAI).send(
                    LabellerRequest(prompt: "p", modelID: "m", reasoningLevel: "l"),
                    onRequestStarted: {},
                    onProgress: { _ in }
                )
                Issue.record("expected redirect refusal for \(targetURL)")
            } catch {
                #expect(error as? LabellerFailure == .temporary)
            }
            #expect(OpenAIStyleStubProtocol.requests.count == 1)
        }
    }

    @Test func replyPastSizeCapIsRefusedAsUnusable() async throws {
        OpenAIStyleStubProtocol.reset([
            .respond(status: 200, headers: ["Content-Type": "text/event-stream"]),
            .send(Data(repeating: 0x20, count: 8 * 1_024 * 1_024 + 1)),
        ])
        do {
            _ = try await makeClient(target: .openAI).send(
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
        OpenAIStyleStubProtocol.reset([])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenAIStyleStubProtocol.self]
        let keyless = OpenAIStyleLabellerSender(
            target: .openAI,
            keyStore: InMemoryLabellerKeyStore(key: nil, provider: .openAIKey),
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
        #expect(OpenAIStyleStubProtocol.requests.isEmpty)
    }

    @Test func failuresNeverExposeKey() async throws {
        let auth = Data(#"{"error":{"type":"invalid_api_key","message":"Bad key"}}"#.utf8)
        OpenAIStyleStubProtocol.reset([.respond(status: 401, headers: [:]), .send(auth)])
        do {
            _ = try await makeClient(target: .openAI).send(
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
        let body = Data(#"{"error":{"type":"invalid_request_error","message":"Something wrong"}}"#.utf8)
        let detail = OpenAIStyleLabellerSender.failureDetail(status: 400, body: body)
        #expect(detail == LabellerFailureDetail(status: 400, errorType: "invalid_request_error"))
        #expect(!String(describing: detail).contains("Something wrong"))
    }

    // MARK: - Helpers

    private func makeClient(target: OpenAIStyleLabellerSender.Target) -> OpenAIStyleLabellerSender {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenAIStyleStubProtocol.self]
        return OpenAIStyleLabellerSender(
            target: target,
            keyStore: InMemoryLabellerKeyStore(key: Self.key, provider: target.provider),
            configuration: configuration
        )
    }

    private func sseChunk(content: String? = nil, finishReason: String? = nil, usage: [String: Any]? = nil) -> Data {
        var delta: [String: Any] = [:]
        if let content { delta["content"] = content }
        var choice: [String: Any] = ["delta": delta]
        if let finishReason { choice["finish_reason"] = finishReason }
        var object: [String: Any] = ["choices": [choice]]
        if let usage { object["usage"] = usage }
        let json = try! JSONSerialization.data(withJSONObject: object)
        return Data("data: ".utf8) + json + Data("\n\n".utf8)
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

private final class OpenAIStyleStubProtocol: URLProtocol, @unchecked Sendable {
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
        guard let host = request.url?.host else { return false }
        return host == "api.openai.com" || host == "openrouter.ai"
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
