import Foundation
import Testing
@testable import WiltedProducer

private struct ArticleDNSFixture: ArticleAddressResolving {
    let answers: [String: [String]]

    func addresses(for host: String) async throws -> [String] {
        answers[host] ?? []
    }
}

private actor ArticleTransferFixture: PinnedArticleTransferring {
    private var responses: [Data]
    private(set) var requests: [PinnedArticleTransferRequest] = []

    init(_ responses: [Data]) { self.responses = responses }

    func transfer(_ request: PinnedArticleTransferRequest) async throws -> Data {
        requests.append(request)
        guard !responses.isEmpty else { throw PublicHTTPSArticleError.transferFailed }
        return responses.removeFirst()
    }
}

private func response(_ status: Int, headers: String = "", body: String = "") -> Data {
    Data("HTTP/1.1 \(status) Test\r\n\(headers)\r\n\(body)".utf8)
}

private struct CancelledArticleTransfer: PinnedArticleTransferring {
    func transfer(_ request: PinnedArticleTransferRequest) async throws -> Data {
        withUnsafeCurrentTask { $0?.cancel() }
        throw PublicHTTPSArticleError.transferFailed
    }
}

@Suite("Pinned public HTTPS article transport")
struct PublicHTTPSArticleTransportTests {
    @Test func cancelledTransferReportsCancellationInsteadOfArticleFailure() async {
        let transport = PublicHTTPSArticleTransport(
            resolver: ArticleDNSFixture(answers: ["news.example": ["1.1.1.1"]]),
            transferClient: CancelledArticleTransfer()
        )
        let task = Task {
            try await transport.load(URL(string: "https://news.example/story")!, maximumBytes: 128) { _ in }
        }
        switch await task.result {
        case let .failure(error): #expect(error is CancellationError)
        case .success: Issue.record("Cancelled transfer unexpectedly returned article bytes")
        }
    }

    @Test(arguments: [
        "0.0.0.0", "10.1.2.3", "100.64.0.1", "127.0.0.1", "169.254.2.3",
        "172.31.2.3", "192.0.0.1", "192.0.2.1", "192.168.0.1", "198.18.0.1",
        "198.51.100.2", "203.0.113.1", "224.0.0.1", "240.0.0.1", "::", "::1",
        "fc00::1", "fe80::1", "2001:db8::1", "2002::1", "64:ff9b::7f00:1"
    ])
    func deniesPrivateAndReservedAddresses(address: String) {
        #expect(!PublicHTTPSArticleTransport.isPublicAddress(address))
    }

    @Test(arguments: ["8.8.8.8", "1.1.1.1", "2606:4700:4700::1111", "2001:4860:4860::8888"])
    func allowsPublicUnicastAddresses(address: String) {
        #expect(PublicHTTPSArticleTransport.isPublicAddress(address))
    }

    @Test func refusesMixedPublicAndPrivateDnsAnswersBeforeContact() async throws {
        let transfer = ArticleTransferFixture([response(200, body: "<article>text</article>")])
        let transport = PublicHTTPSArticleTransport(
            resolver: ArticleDNSFixture(answers: ["news.example": ["8.8.8.8", "127.0.0.1"]]),
            transferClient: transfer
        )

        do {
            _ = try await transport.load(URL(string: "https://news.example/story")!, maximumBytes: 128) { _ in }
            Issue.record("Mixed DNS answers must be rejected")
        } catch let error as PublicHTTPSArticleError {
            #expect(error == .unsafeAddress)
        }
        #expect(await transfer.requests.isEmpty)
    }

    @Test func pinsEachRedirectToValidatedIpAndRejectsPrivateRedirectBeforeContact() async throws {
        let transfer = ArticleTransferFixture([
            response(302, headers: "Location: https://private.example/story\r\n"),
            response(200, body: "<article>never reached</article>")
        ])
        let transport = PublicHTTPSArticleTransport(
            resolver: ArticleDNSFixture(answers: [
                "news.example": ["1.1.1.1"],
                "private.example": ["169.254.169.254"]
            ]),
            transferClient: transfer
        )

        do {
            _ = try await transport.load(URL(string: "https://news.example/story")!, maximumBytes: 128) { _ in }
            Issue.record("Private redirect targets must be rejected")
        } catch let error as PublicHTTPSArticleError {
            #expect(error == .unsafeAddress)
        }
        let requests = await transfer.requests
        #expect(requests.count == 1)
        #expect(requests.first?.host == "news.example")
        #expect(requests.first?.address == "1.1.1.1")
    }

    @Test func redirectsUsePinnedValidatedHostAndReturnOnlyTheFinalBody() async throws {
        let transfer = ArticleTransferFixture([
            response(302, headers: "Location: https://cdn.example/full\r\n"),
            response(200, headers: "Content-Type: text/html; charset=utf-8\r\n", body: "<article>full article</article>")
        ])
        let transport = PublicHTTPSArticleTransport(
            resolver: ArticleDNSFixture(answers: [
                "news.example": ["8.8.8.8"],
                "cdn.example": ["2606:4700:4700::1111"]
            ]),
            transferClient: transfer
        )

        let body = try await transport.load(URL(string: "https://news.example/story")!, maximumBytes: 128) { _ in }
        #expect(String(decoding: body, as: UTF8.self) == "<article>full article</article>")
        let requests = await transfer.requests
        #expect(requests.count == 2)
        #expect(requests[0].address == "8.8.8.8")
        #expect(requests[1].host == "cdn.example")
        #expect(requests[1].address == "2606:4700:4700::1111")
    }

    @Test(arguments: [
        "http://news.example/story", "https://user@news.example/story", "https://news.example:8443/story"
    ])
    func rejectsUnsafeUrlFormsBeforeResolving(url: String) async throws {
        let transfer = ArticleTransferFixture([])
        let resolver = ArticleDNSFixture(answers: [:])
        let transport = PublicHTTPSArticleTransport(resolver: resolver, transferClient: transfer)
        do {
            _ = try await transport.load(URL(string: url)!, maximumBytes: 128) { _ in }
            Issue.record("Unsafe URL form must be rejected")
        } catch let error as PublicHTTPSArticleError {
            #expect(error == .invalidURL)
        }
        #expect(await transfer.requests.isEmpty)
    }

    @Test func enforcesBodyLimitAndRejectsUnexpectedContentTypes() async throws {
        let largeBody = ArticleTransferFixture([response(200, body: String(repeating: "x", count: 20))])
        let largeTransport = PublicHTTPSArticleTransport(
            resolver: ArticleDNSFixture(answers: ["news.example": ["8.8.8.8"]]), transferClient: largeBody
        )
        do {
            _ = try await largeTransport.load(URL(string: "https://news.example/story")!, maximumBytes: 8) { _ in }
            Issue.record("Oversized body must be rejected")
        } catch let error as PublicHTTPSArticleError {
            #expect(error == .responseTooLarge)
        }

        let binary = ArticleTransferFixture([
            response(200, headers: "Content-Type: application/octet-stream\r\n", body: "binary")
        ])
        let binaryTransport = PublicHTTPSArticleTransport(
            resolver: ArticleDNSFixture(answers: ["news.example": ["8.8.8.8"]]), transferClient: binary
        )
        do {
            _ = try await binaryTransport.load(URL(string: "https://news.example/story")!, maximumBytes: 128) { _ in }
            Issue.record("Non-document response types must be rejected")
        } catch let error as PublicHTTPSArticleError {
            #expect(error == .invalidResponse)
        }
    }
}
