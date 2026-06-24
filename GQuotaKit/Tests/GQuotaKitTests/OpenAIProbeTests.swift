import Testing
import Foundation
@testable import GQuotaKit

private func fixtureData() throws -> Data {
    let url = try #require(Bundle.module.url(
        forResource: "openai-wham-usage",
        withExtension: "json",
        subdirectory: "Fixtures"
    ))
    return try Data(contentsOf: url)
}

private func jwt(payloadJSON: String) -> String {
    let payload = Data(payloadJSON.utf8).base64URLEncodedString()
    return "header.\(payload).signature"
}

private func temporaryDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func writeCodexAuth(baseDirectory: URL, accessToken: String, accountID: String = "acct-FAKE123") throws {
    let codexDirectory = baseDirectory.appendingPathComponent(".codex")
    try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
    let json = """
    {
      "tokens": {
        "access_token": "\(accessToken)",
        "account_id": "\(accountID)",
        "refresh_token": "refresh-token"
      }
    }
    """
    try Data(json.utf8).write(to: codexDirectory.appendingPathComponent("auth.json"))
}

private final class CapturingHTTPClient: HTTPClient, @unchecked Sendable {
    private actor RequestStore {
        var requests: [URLRequest] = []

        func append(_ request: URLRequest) {
            requests.append(request)
        }
    }

    private let body: Data
    private let status: Int
    private let store = RequestStore()

    init(status: Int = 200, body: Data) {
        self.status = status
        self.body = body
    }

    var requests: [URLRequest] {
        get async { await store.requests }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await store.append(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (body, response)
    }
}

@Test func parsesFixturePrimaryAndSecondaryWindows() throws {
    let windows = try OpenAIProbe.parse(fixtureData())

    #expect(windows.count == 4)

    let primary = try #require(windows.first { $0.label == "5 小时窗口" })
    #expect(primary.measure == .usedFraction(0.01))
    #expect(primary.confidence == .exact)
    #expect(primary.resetsAt == Date(timeIntervalSince1970: 1_781_211_364))

    let secondary = try #require(windows.first { $0.label == "周限额" })
    #expect(secondary.measure == .usedFraction(0.04))
    #expect(secondary.confidence == .exact)
    #expect(secondary.resetsAt == Date(timeIntervalSince1970: 1_781_758_208))

    let additionalPrimary = try #require(windows.first { $0.label == "GPT-5.3-Codex-Spark 5 小时窗口" })
    #expect(additionalPrimary.measure == .usedFraction(0))
    #expect(additionalPrimary.resetsAt == Date(timeIntervalSince1970: 1_781_212_050))

    let additionalSecondary = try #require(windows.first { $0.label == "GPT-5.3-Codex-Spark 周限额" })
    #expect(additionalSecondary.measure == .usedFraction(0.09))
    #expect(additionalSecondary.resetsAt == Date(timeIntervalSince1970: 1_781_230_146))
}

@Test func primaryAndSecondaryLabelsComeFromFieldIdentity() throws {
    let json = """
    {
      "plan_type": "pro",
      "rate_limit": {
        "primary_window": {
          "limit_window_seconds": 604800,
          "reset_after_seconds": 120,
          "reset_at": 1781211364,
          "used_percent": 12
        },
        "secondary_window": {
          "limit_window_seconds": 18000,
          "reset_after_seconds": 240,
          "reset_at": 1781758208,
          "used_percent": 34
        }
      },
      "credits": { "balance": "10", "has_credits": true }
    }
    """

    let windows = try OpenAIProbe.parse(Data(json.utf8))

    #expect(windows.count == 2)
    #expect(windows[0].label == "5 小时窗口")
    #expect(windows[0].measure == .usedFraction(0.12))
    #expect(windows[1].label == "周限额")
    #expect(windows[1].measure == .usedFraction(0.34))
}

@Test func missingSecondaryStillParsesPrimary() throws {
    let json = """
    {
      "plan_type": "pro",
      "rate_limit": {
        "primary_window": {
          "limit_window_seconds": 18000,
          "reset_after_seconds": 120,
          "reset_at": 1781211364,
          "used_percent": 25
        }
      }
    }
    """

    let windows = try OpenAIProbe.parse(Data(json.utf8))

    #expect(windows.count == 1)
    #expect(windows[0].label == "5 小时窗口")
    #expect(windows[0].measure == .usedFraction(0.25))
    #expect(windows[0].resetsAt == Date(timeIntervalSince1970: 1_781_211_364))
    #expect(windows[0].confidence == .exact)
}

@Test func additionalRateLimitWindowsContributeToTightestSeverity() throws {
    let json = """
    {
      "plan_type": "pro",
      "rate_limit": {
        "primary_window": {
          "limit_window_seconds": 18000,
          "reset_at": 1781211364,
          "used_percent": 12
        },
        "secondary_window": {
          "limit_window_seconds": 604800,
          "reset_at": 1781758208,
          "used_percent": 34
        }
      },
      "additional_rate_limits": [
        {
          "limit_name": "GPT-5.3-Codex-Spark",
          "metered_feature": "codex_bengalfox",
          "rate_limit": {
            "primary_window": {
              "limit_window_seconds": 18000,
              "reset_at": 1781212050,
              "used_percent": 97
            }
          }
        }
      ],
      "credits": { "balance": "0", "has_credits": false }
    }
    """

    let windows = try OpenAIProbe.parse(Data(json.utf8))
    let snapshot = UsageSnapshot(
        providerID: .openai,
        windows: windows,
        fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
        state: .ok
    )

    #expect(windows.contains { $0.label == "GPT-5.3-Codex-Spark 5 小时窗口" })
    #expect(UsageCoordinator.tightestSeverity([snapshot]) == 0.97)
}

@Test func zeroCreditsWithoutCreditEntitlementDoesNotCreateDangerWindow() throws {
    let json = """
    {
      "plan_type": "pro",
      "rate_limit": {
        "primary_window": {
          "limit_window_seconds": 18000,
          "reset_at": 1781211364,
          "used_percent": 12
        }
      },
      "credits": { "balance": "0", "has_credits": false }
    }
    """

    let windows = try OpenAIProbe.parse(Data(json.utf8))

    #expect(windows.count == 1)
    #expect(windows.allSatisfy {
        if case .creditsBalance = $0.measure {
            return false
        }
        return true
    })
}

@Test func planTypeReadFromJWT() {
    let token = jwt(payloadJSON: #"{"chatgpt_plan_type":"plus","exp":4102444800}"#)

    #expect(OpenAIProbe.planType(fromAccessToken: token) == "plus")
}

@Test func malformedJWTIsTreatedAsNotExpired() {
    #expect(OpenAIProbe.isExpired("not-a-jwt", now: Date(timeIntervalSince1970: 4_102_444_800)) == false)
}

@Test func fetchBuildsWhamRequestAndSnapshotsOk() async throws {
    let dir = try temporaryDirectory()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let token = jwt(payloadJSON: #"{"chatgpt_plan_type":"pro","exp":4102444800}"#)
    try writeCodexAuth(baseDirectory: dir, accessToken: token)
    let client = CapturingHTTPClient(body: try fixtureData())

    let probe = OpenAIProbe(
        credentialReader: FileCredentialReader(baseDirectory: dir),
        client: client,
        now: { now }
    )

    let snapshot = try await probe.fetch()
    let request = try #require(await client.requests.first)

    #expect(snapshot.providerID == .openai)
    #expect(snapshot.state == .ok)
    #expect(snapshot.fetchedAt == now)
    #expect(snapshot.windows.isEmpty == false)
    #expect(probe.providerID == .openai)
    #expect(probe.displayName == "OpenAI")
    #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
    #expect(request.value(forHTTPHeaderField: "chatgpt-account-id") == "acct-FAKE123")
    #expect(request.value(forHTTPHeaderField: "User-Agent") == "GQuota/0.1")
}

@Test func fetchWithoutCodexAuthYieldsNeedsAuth() async throws {
    let dir = try temporaryDirectory()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let probe = OpenAIProbe(
        credentialReader: FileCredentialReader(baseDirectory: dir),
        client: MockHTTPClient(responses: [.init(status: 200, body: Data())]),
        now: { now }
    )

    let snapshot = try await probe.fetch()

    #expect(snapshot.providerID == .openai)
    #expect(snapshot.windows.isEmpty)
    #expect(snapshot.fetchedAt == now)
    #expect(snapshot.state == .needsAuth)
}

@Test func fetchWithExpiredTokenYieldsStaleWithoutRequest() async throws {
    // exp 早于 now → 过期。MVP 不刷新：应标 .stale 且根本不发请求（OV2）。
    let dir = try temporaryDirectory()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let expiredToken = jwt(payloadJSON: #"{"chatgpt_plan_type":"pro","exp":1699999999}"#)
    try writeCodexAuth(baseDirectory: dir, accessToken: expiredToken)
    let client = CapturingHTTPClient(body: try fixtureData())

    let probe = OpenAIProbe(
        credentialReader: FileCredentialReader(baseDirectory: dir),
        client: client,
        now: { now }
    )

    let snapshot = try await probe.fetch()

    #expect(snapshot.state == .stale(since: now))
    #expect(snapshot.windows.isEmpty)
    #expect(await client.requests.isEmpty)
}
