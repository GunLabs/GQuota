import Testing
import Foundation
@testable import GQuotaKit

private func win(_ s: Double) -> [UsageWindow] {
    [UsageWindow(label: "w", measure: .usedFraction(s), resetsAt: nil, confidence: .exact, detail: nil)]
}

private enum ParseError: Error {
    case malformed
}

private struct HeaderHTTPClient: HTTPClient {
    let status: Int
    let headers: [String: String]

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        )!
        return (Data(), response)
    }
}

@Test func missingCredsYieldsNeedsAuth() async {
    let outcome = await AuthenticatedRequest.run(
        provider: .openai,
        accessToken: nil,
        isExpired: false,
        request: { _ in URLRequest(url: URL(string: "https://x.test")!) },
        client: MockHTTPClient(responses: [.init(status: 200, body: Data())]),
        parse: { _ in win(0.5) }
    )
    #expect(outcome == .needsAuth)
}

@Test func expiredTokenYieldsStaleNotRefresh() async {
    let outcome = await AuthenticatedRequest.run(
        provider: .openai, accessToken: "t", isExpired: true,
        request: { _ in URLRequest(url: URL(string: "https://x.test")!) },
        client: MockHTTPClient(responses: [.init(status: 200, body: Data())]),
        parse: { _ in win(0.5) }
    )
    if case .stale = outcome {} else { Issue.record("expected .stale, got \(outcome)") }
}

@Test func ok200ParsesWindows() async {
    var requestToken: String?
    let outcome = await AuthenticatedRequest.run(
        provider: .openai, accessToken: "t", isExpired: false,
        request: { token in
            requestToken = token
            return URLRequest(url: URL(string: "https://x.test")!)
        },
        client: MockHTTPClient(responses: [.init(status: 200, body: Data("{}".utf8))]),
        parse: { _ in win(0.72) }
    )
    #expect(outcome == .ok(win(0.72)))
    #expect(requestToken == "t")
}

@Test func http401YieldsNeedsAuth() async {
    let outcome = await AuthenticatedRequest.run(
        provider: .openai, accessToken: "t", isExpired: false,
        request: { _ in URLRequest(url: URL(string: "https://x.test")!) },
        client: MockHTTPClient(responses: [.init(status: 401, body: Data())]),
        parse: { _ in win(0.5) }
    )
    #expect(outcome == .needsAuth)
}

@Test func http403YieldsNeedsAuth() async {
    let outcome = await AuthenticatedRequest.run(
        provider: .openai, accessToken: "t", isExpired: false,
        request: { _ in URLRequest(url: URL(string: "https://x.test")!) },
        client: MockHTTPClient(responses: [.init(status: 403, body: Data())]),
        parse: { _ in win(0.5) }
    )
    #expect(outcome == .needsAuth)
}

@Test func http429YieldsRateLimited() async {
    let outcome = await AuthenticatedRequest.run(
        provider: .openai, accessToken: "t", isExpired: false,
        request: { _ in URLRequest(url: URL(string: "https://x.test")!) },
        client: MockHTTPClient(responses: [.init(status: 429, body: Data())]),
        parse: { _ in win(0.5) }
    )
    if case .rateLimited = outcome {} else { Issue.record("expected .rateLimited") }
}

@Test func http429ParsesRetryAfterDeltaSeconds() async {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let outcome = await AuthenticatedRequest.run(
        provider: .openai,
        accessToken: "t",
        isExpired: false,
        request: { _ in URLRequest(url: URL(string: "https://x.test")!) },
        client: HeaderHTTPClient(status: 429, headers: ["Retry-After": "120"]),
        now: { now },
        parse: { _ in win(0.5) }
    )

    if case .rateLimited(let retryAfter) = outcome {
        #expect(retryAfter == now.addingTimeInterval(120))
    } else {
        Issue.record("expected .rateLimited")
    }
}

@Test func http500YieldsUnavailable() async {
    let outcome = await AuthenticatedRequest.run(
        provider: .openai, accessToken: "t", isExpired: false,
        request: { _ in URLRequest(url: URL(string: "https://x.test")!) },
        client: MockHTTPClient(responses: [.init(status: 500, body: Data())]),
        parse: { _ in win(0.5) }
    )
    #expect(outcome == .unavailable(reason: "HTTP 500"))
}

@Test func clientThrowYieldsStale() async {
    let outcome = await AuthenticatedRequest.run(
        provider: .openai, accessToken: "t", isExpired: false,
        request: { _ in URLRequest(url: URL(string: "https://x.test")!) },
        client: MockHTTPClient(responses: []),
        parse: { _ in win(0.5) }
    )
    if case .stale = outcome {} else { Issue.record("expected .stale, got \(outcome)") }
}

@Test func parserThrowYieldsUnavailable() async {
    let outcome = await AuthenticatedRequest.run(
        provider: .openai, accessToken: "t", isExpired: false,
        request: { _ in URLRequest(url: URL(string: "https://x.test")!) },
        client: MockHTTPClient(responses: [.init(status: 200, body: Data("{}".utf8))]),
        parse: { _ in throw ParseError.malformed }
    )
    #expect(outcome == .unavailable(reason: "Parse failed"))
}
