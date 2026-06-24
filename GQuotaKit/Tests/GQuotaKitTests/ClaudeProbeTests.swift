import Testing
import Foundation
@testable import GQuotaKit

private func claudeFixtureData() throws -> Data {
    let url = try #require(Bundle.module.url(
        forResource: "claude-oauth-usage",
        withExtension: "json",
        subdirectory: "Fixtures"
    ))
    return try Data(contentsOf: url)
}

private func claudeCredentials(expiresAt: Double = 4_102_444_800_000, subscriptionType: String = "max") -> Data {
    Data("""
    {
      "claudeAiOauth": {
        "accessToken": "sk-ant-oat01-FAKE",
        "refreshToken": "sk-ant-ort01-FAKE",
        "expiresAt": \(expiresAt),
        "subscriptionType": "\(subscriptionType)"
      }
    }
    """.utf8)
}

private struct StubClaudeSource: ClaudeCredentialSource {
    let data: Data?
    func read() throws -> Data? { data }
}

private final class ClaudeCapturingHTTPClient: HTTPClient, @unchecked Sendable {
    private actor Store {
        var requests: [URLRequest] = []
        func append(_ request: URLRequest) { requests.append(request) }
    }

    private let status: Int
    private let body: Data
    private let headers: [String: String]
    private let store = Store()

    init(status: Int = 200, body: Data = Data(), headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = headers
    }

    var requests: [URLRequest] { get async { await store.requests } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await store.append(request)
        let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        return (body, http)
    }
}

@Test func claudeProbe_parsesWindowsWithSubscriptionDetail() throws {
    let windows = try ClaudeProbe.parse(claudeFixtureData(), subscriptionType: "max")

    // five_hour + seven_day + seven_day_sonnet（opus 为 null；extra_usage utilization 为 null → 不出窗口）
    #expect(windows.count == 3)

    let fiveHour = try #require(windows.first { $0.label == "5 小时窗口" })
    #expect(fiveHour.measure == .usedFraction(0.63))
    #expect(fiveHour.confidence == .exact)
    #expect(fiveHour.detail == "Max")
    // resets_at 带小数秒（spike 4 实测格式），必须能解析（默认 ISO8601 选项会返回 nil）。
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    #expect(fiveHour.resetsAt == fractional.date(from: "2026-06-12T03:39:59.614364+00:00"))
    #expect(fiveHour.resetsAt != nil)

    let weekly = try #require(windows.first { $0.label == "周限额" })
    #expect(weekly.measure == .usedFraction(0.73))

    #expect(windows.contains { $0.label == "周限额 · Sonnet" })
    #expect(windows.contains { $0.label == "周限额 · Opus" } == false)
    #expect(windows.contains { $0.label == "额外用量" } == false)
}

@Test func claudeProbe_parsesFractionalSecondsResetTime() {
    #expect(ClaudeProbe.parseISO8601("2026-06-12T03:39:59.614364+00:00") != nil)
    #expect(ClaudeProbe.parseISO8601("2026-06-17T19:59:59Z") != nil)   // 无小数秒回退
    #expect(ClaudeProbe.parseISO8601(nil) == nil)
    #expect(ClaudeProbe.parseISO8601("garbage") == nil)
}

@Test func claudeProbe_fetchBuildsOAuthUsageRequestAndSnapshotsOk() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let client = ClaudeCapturingHTTPClient(status: 200, body: try claudeFixtureData())
    let probe = ClaudeProbe(
        credentialSource: StubClaudeSource(data: claudeCredentials()),
        client: client,
        now: { now },
        userAgent: "claude-code/9.9.9"
    )

    let snapshot = try await probe.fetch()
    let request = try #require(await client.requests.first)

    #expect(snapshot.providerID == .claude)
    #expect(snapshot.state == .ok)
    #expect(snapshot.fetchedAt == now)
    #expect(snapshot.windows.isEmpty == false)
    #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-ant-oat01-FAKE")
    #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
    #expect(request.value(forHTTPHeaderField: "User-Agent") == "claude-code/9.9.9")
}

@Test func claudeProbe_missingCredentialsYieldsNeedsAuth() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let client = ClaudeCapturingHTTPClient()
    let probe = ClaudeProbe(
        credentialSource: StubClaudeSource(data: nil),
        client: client,
        now: { now }
    )

    let snapshot = try await probe.fetch()

    #expect(snapshot.state == .needsAuth)
    #expect(snapshot.windows.isEmpty)
    #expect(await client.requests.isEmpty)
}

@Test func claudeProbe_expiredTokenYieldsStaleWithoutRequest() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let client = ClaudeCapturingHTTPClient(status: 200, body: try claudeFixtureData())
    // expiresAt 早于 now（毫秒）
    let probe = ClaudeProbe(
        credentialSource: StubClaudeSource(data: claudeCredentials(expiresAt: 1_699_999_999_000)),
        client: client,
        now: { now }
    )

    let snapshot = try await probe.fetch()

    #expect(snapshot.state == .stale(since: now))
    #expect(snapshot.windows.isEmpty)
    #expect(await client.requests.isEmpty)
}

@Test func claudeProbe_rateLimitedParsesRetryAfter() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let client = ClaudeCapturingHTTPClient(status: 429, body: Data(), headers: ["Retry-After": "300"])
    let probe = ClaudeProbe(
        credentialSource: StubClaudeSource(data: claudeCredentials()),
        client: client,
        now: { now }
    )

    let snapshot = try await probe.fetch()

    if case .rateLimited(let retryAfter) = snapshot.state {
        #expect(retryAfter == now.addingTimeInterval(300))
    } else {
        Issue.record("expected .rateLimited, got \(snapshot.state)")
    }
}
