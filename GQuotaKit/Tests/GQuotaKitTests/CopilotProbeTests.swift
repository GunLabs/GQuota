import Foundation
import Testing
@testable import GQuotaKit

private func copilotFixtureData() throws -> Data {
    let url = try #require(Bundle.module.url(
        forResource: "copilot-user",
        withExtension: "json",
        subdirectory: "Fixtures"
    ))
    return try Data(contentsOf: url)
}

private struct StaticCopilotTokenSource: CopilotTokenSource {
    let value: String?

    func token() async -> String? {
        value
    }
}

private final class CopilotCapturingHTTPClient: HTTPClient, @unchecked Sendable {
    struct Response: Sendable {
        let status: Int
        let body: Data
        let headers: [String: String]

        init(status: Int, body: Data, headers: [String: String] = [:]) {
            self.status = status
            self.body = body
            self.headers = headers
        }
    }

    private actor Store {
        var requests: [URLRequest] = []
        var index = 0

        func append(_ request: URLRequest) {
            requests.append(request)
        }

        func next(from responses: [Response]) -> Response {
            let response = responses[min(index, responses.count - 1)]
            index += 1
            return response
        }
    }

    private let responses: [Response]
    private let store = Store()

    init(responses: [Response]) {
        self.responses = responses
    }

    var requests: [URLRequest] {
        get async { await store.requests }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await store.append(request)
        let response = await store.next(from: responses)
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: nil,
            headerFields: response.headers
        )!
        return (response.body, http)
    }
}

@Suite("CopilotProbeTests")
struct CopilotProbeTests {
@Test func copilotProbe_fetchBuildsUsageRequestAndSnapshotsOk() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let client = CopilotCapturingHTTPClient(responses: [
        .init(status: 200, body: try copilotFixtureData()),
    ])
    let probe = CopilotProbe(
        tokenSource: StaticCopilotTokenSource(value: "github-token"),
        client: client,
        now: { now }
    )

    let snapshot = try await probe.fetch()
    let request = try #require(await client.requests.first)

    #expect(snapshot.providerID == .copilot)
    #expect(snapshot.state == .ok)
    #expect(snapshot.fetchedAt == now)
    #expect(snapshot.windows.first { $0.label == "Premium 请求" }?.measure == .usedFraction(0.58))
    #expect(probe.providerID == .copilot)
    #expect(probe.displayName == "Copilot")
    #expect(request.url?.absoluteString == "https://api.github.com/copilot_internal/user")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "token github-token")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(request.value(forHTTPHeaderField: "Editor-Version") == "vscode/1.96.2")
    #expect(request.value(forHTTPHeaderField: "Editor-Plugin-Version") == "copilot-chat/0.26.7")
    #expect(request.value(forHTTPHeaderField: "User-Agent") == "GitHubCopilotChat/0.26.7")
    #expect(request.value(forHTTPHeaderField: "X-Github-Api-Version") == "2025-04-01")
}

@Test func copilotProbe_missingTokenYieldsNeedsAuthWithoutRequest() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let client = CopilotCapturingHTTPClient(responses: [
        .init(status: 200, body: Data()),
    ])
    let probe = CopilotProbe(
        tokenSource: StaticCopilotTokenSource(value: nil),
        client: client,
        now: { now }
    )

    let snapshot = try await probe.fetch()

    #expect(snapshot.providerID == .copilot)
    #expect(snapshot.windows.isEmpty)
    #expect(snapshot.fetchedAt == now)
    #expect(snapshot.state == .needsAuth)
    #expect(await client.requests.isEmpty)
}

@Test func copilotProbe_rejectedTokenYieldsUnavailableReason() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let probe = CopilotProbe(
        tokenSource: StaticCopilotTokenSource(value: "rejected-token"),
        client: CopilotCapturingHTTPClient(responses: [.init(status: 403, body: Data())]),
        now: { now }
    )

    let snapshot = try await probe.fetch()

    #expect(snapshot.state == .unavailable(reason: "Copilot token 被拒绝"))
}

@Test func copilotProbe_429ParsesRetryAfter() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let probe = CopilotProbe(
        tokenSource: StaticCopilotTokenSource(value: "github-token"),
        client: CopilotCapturingHTTPClient(responses: [
            .init(status: 429, body: Data(), headers: ["Retry-After": "90"]),
        ]),
        now: { now }
    )

    let snapshot = try await probe.fetch()

    if case .rateLimited(let retryAfter) = snapshot.state {
        #expect(retryAfter == now.addingTimeInterval(90))
    } else {
        Issue.record("expected .rateLimited")
    }
}

@Test func copilotProbe_403WithRetryAfterYieldsRateLimited() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let probe = CopilotProbe(
        tokenSource: StaticCopilotTokenSource(value: "github-token"),
        client: CopilotCapturingHTTPClient(responses: [
            .init(status: 403, body: Data(), headers: ["Retry-After": "90"]),
        ]),
        now: { now }
    )

    let snapshot = try await probe.fetch()

    if case .rateLimited(let retryAfter) = snapshot.state {
        #expect(retryAfter == now.addingTimeInterval(90))
    } else {
        Issue.record("expected .rateLimited")
    }
}

@Test func copilotProbe_parseFailureUsesSchemaDriftReason() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let probe = CopilotProbe(
        tokenSource: StaticCopilotTokenSource(value: "github-token"),
        client: CopilotCapturingHTTPClient(responses: [
            .init(status: 200, body: Data(#"{"quota_snapshots":{"premium_interactions":{}}}"#.utf8)),
        ]),
        now: { now }
    )

    let snapshot = try await probe.fetch()

    #expect(snapshot.state == .unavailable(reason: "Copilot 响应格式已变化"))
}
}
