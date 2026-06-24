import Testing
import Foundation
@testable import GQuotaKit

private func geminiFixtureData(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(
        forResource: name,
        withExtension: "json",
        subdirectory: "Fixtures"
    ))
    return try Data(contentsOf: url)
}

private func temporaryGeminiDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private final class LockedString: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    func set(_ value: String) {
        lock.lock()
        storage = value
        lock.unlock()
    }

    func get() -> String {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private func writeGeminiOAuth(
    baseDirectory: URL,
    accessToken: String? = "gemini-access-token",
    expiryDate: Double = 4_102_444_800_000
) throws {
    let geminiDirectory = baseDirectory.appendingPathComponent(".gemini")
    try FileManager.default.createDirectory(at: geminiDirectory, withIntermediateDirectories: true)

    let accessTokenField = accessToken.map { #""access_token": "\#($0)","# } ?? ""
    let json = """
    {
      \(accessTokenField)
      "refresh_token": "gemini-refresh-token",
      "expiry_date": \(expiryDate)
    }
    """
    try Data(json.utf8).write(to: geminiDirectory.appendingPathComponent("oauth_creds.json"))
}

private final class GeminiCapturingHTTPClient: HTTPClient, @unchecked Sendable {
    private actor Store {
        var requests: [URLRequest] = []

        func append(_ request: URLRequest) {
            requests.append(request)
        }
    }

    private let responses: MockHTTPClient
    private let store = Store()

    init(responses: [MockHTTPClient.Stub]) {
        self.responses = MockHTTPClient(responses: responses)
    }

    var requests: [URLRequest] {
        get async { await store.requests }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await store.append(request)
        return try await responses.send(request)
    }
}

private final class GeminiHeaderHTTPClient: HTTPClient, @unchecked Sendable {
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
        var index = 0

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

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
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

@Test func geminiProbeTests_parsesFixtureBucketsAsRemainingFraction() throws {
    let windows = try GeminiProbe.parse(geminiFixtureData("gemini-retrieveUserQuota"))

    #expect(windows.count == 4)

    let pro = try #require(windows.first { $0.label == "gemini-2.5-pro" })
    #expect(pro.measure == .remainingFraction(1.0))
    #expect(pro.confidence == .exact)
    #expect(pro.resetsAt == ISO8601DateFormatter().date(from: "2026-06-12T16:10:30Z"))
    #expect(pro.detail == nil)
}

// dummy-100% 二级启发式已移除（会误报合法新用户），故对应的 looksLikeDummy 单测一并删除。
// project 一级防线由 geminiProbeTests_missingProjectYieldsUnavailable 覆盖。

@Test func geminiProbeTests_fetchLoadsProjectThenRetrievesQuota() async throws {
    let dir = try temporaryGeminiDirectory()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    try writeGeminiOAuth(baseDirectory: dir)
    let client = GeminiCapturingHTTPClient(responses: [
        .init(status: 200, body: try geminiFixtureData("gemini-loadCodeAssist")),
        .init(status: 200, body: try geminiFixtureData("gemini-retrieveUserQuota")),
    ])

    let probe = GeminiProbe(
        credentialReader: FileCredentialReader(baseDirectory: dir),
        client: client,
        now: { now }
    )

    let snapshot = try await probe.fetch()
    let requests = await client.requests

    #expect(snapshot.providerID == .gemini)
    #expect(snapshot.state == .ok)
    #expect(snapshot.fetchedAt == now)
    #expect(snapshot.windows.count == 4)
    #expect(probe.providerID == .gemini)
    #expect(probe.displayName == "Gemini")

    #expect(requests.count == 2)
    #expect(requests[0].url?.absoluteString == "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")
    #expect(requests[0].httpMethod == "POST")
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer gemini-access-token")
    #expect(requests[0].value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(requests[1].url?.absoluteString == "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")
    #expect(requests[1].httpMethod == "POST")
    #expect(String(data: requests[1].httpBody ?? Data(), encoding: .utf8) == #"{"project":"proj-FAKE123"}"#)
}

@Test func geminiProbeTests_fetchAcceptsAllFullBucketsWhenProjectLoaded() async throws {
    let dir = try temporaryGeminiDirectory()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    try writeGeminiOAuth(baseDirectory: dir)
    let allFullQuota = Data("""
    {
      "buckets": [
        { "modelId": "gemini-2.5-flash", "remainingFraction": 1.0, "resetTime": "2026-06-12T16:08:51Z", "tokenType": "REQUESTS" },
        { "modelId": "gemini-2.5-pro", "remainingFraction": 1.0, "resetTime": "2026-06-12T16:10:30Z", "tokenType": "REQUESTS" }
      ]
    }
    """.utf8)
    let client = GeminiCapturingHTTPClient(responses: [
        .init(status: 200, body: try geminiFixtureData("gemini-loadCodeAssist")),
        .init(status: 200, body: allFullQuota),
    ])

    let probe = GeminiProbe(
        credentialReader: FileCredentialReader(baseDirectory: dir),
        client: client,
        now: { now }
    )

    let snapshot = try await probe.fetch()

    #expect(snapshot.providerID == .gemini)
    #expect(snapshot.state == .ok)
    #expect(snapshot.fetchedAt == now)
    #expect(snapshot.windows.count == 2)
    #expect(snapshot.windows.allSatisfy { $0.measure == .remainingFraction(1.0) })
}

@Test func geminiProbeTests_fetch429ParsesRetryAfterDeltaSeconds() async throws {
    let dir = try temporaryGeminiDirectory()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    try writeGeminiOAuth(baseDirectory: dir)
    let client = GeminiHeaderHTTPClient(responses: [
        .init(status: 200, body: try geminiFixtureData("gemini-loadCodeAssist")),
        .init(status: 429, body: Data(), headers: ["Retry-After": "90"]),
    ])

    let probe = GeminiProbe(
        credentialReader: FileCredentialReader(baseDirectory: dir),
        client: client,
        now: { now }
    )

    let snapshot = try await probe.fetch()

    if case .rateLimited(let retryAfter) = snapshot.state {
        #expect(retryAfter == now.addingTimeInterval(90))
    } else {
        Issue.record("expected .rateLimited")
    }
}

@Test func geminiProbeTests_missingCredsYieldsNeedsAuth() async throws {
    let dir = try temporaryGeminiDirectory()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let probe = GeminiProbe(
        credentialReader: FileCredentialReader(baseDirectory: dir),
        client: MockHTTPClient(responses: [.init(status: 200, body: Data())]),
        now: { now }
    )

    let snapshot = try await probe.fetch()

    #expect(snapshot.providerID == .gemini)
    #expect(snapshot.windows.isEmpty)
    #expect(snapshot.fetchedAt == now)
    #expect(snapshot.state == .needsAuth)
}

@Test func geminiProbeTests_missingProjectYieldsUnavailable() async throws {
    let dir = try temporaryGeminiDirectory()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    try writeGeminiOAuth(baseDirectory: dir)
    let probe = GeminiProbe(
        credentialReader: FileCredentialReader(baseDirectory: dir),
        client: MockHTTPClient(responses: [.init(status: 200, body: Data(#"{"cloudaicompanionProject":""}"#.utf8))]),
        now: { now }
    )

    let snapshot = try await probe.fetch()

    #expect(snapshot.providerID == .gemini)
    #expect(snapshot.windows.isEmpty)
    #expect(snapshot.fetchedAt == now)
    #expect(snapshot.state == .unavailable(reason: "需配置 GCP 项目"))
}

// project 加载成功后，配额接口的错误码分支（Gemini 语义独立于 OpenAI）。

@Test func geminiProbeTests_quota403YieldsCodeAssistUnavailable() async throws {
    let dir = try temporaryGeminiDirectory()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    try writeGeminiOAuth(baseDirectory: dir)
    let client = GeminiHeaderHTTPClient(responses: [
        .init(status: 200, body: try geminiFixtureData("gemini-loadCodeAssist")),
        .init(status: 403, body: Data()),
    ])

    let probe = GeminiProbe(
        credentialReader: FileCredentialReader(baseDirectory: dir),
        client: client,
        now: { now }
    )

    let snapshot = try await probe.fetch()

    #expect(snapshot.windows.isEmpty)
    #expect(snapshot.state == .unavailable(reason: "Code Assist 未启用"))
}

@Test func geminiProbeTests_quota401YieldsNeedsAuth() async throws {
    let dir = try temporaryGeminiDirectory()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    try writeGeminiOAuth(baseDirectory: dir)
    let client = GeminiHeaderHTTPClient(responses: [
        .init(status: 200, body: try geminiFixtureData("gemini-loadCodeAssist")),
        .init(status: 401, body: Data()),
    ])

    let probe = GeminiProbe(
        credentialReader: FileCredentialReader(baseDirectory: dir),
        client: client,
        now: { now }
    )

    let snapshot = try await probe.fetch()

    #expect(snapshot.state == .needsAuth)
}

@Test func geminiProbeTests_quota500YieldsUnavailableWithStatus() async throws {
    let dir = try temporaryGeminiDirectory()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    try writeGeminiOAuth(baseDirectory: dir)
    let client = GeminiHeaderHTTPClient(responses: [
        .init(status: 200, body: try geminiFixtureData("gemini-loadCodeAssist")),
        .init(status: 500, body: Data()),
    ])

    let probe = GeminiProbe(
        credentialReader: FileCredentialReader(baseDirectory: dir),
        client: client,
        now: { now }
    )

    let snapshot = try await probe.fetch()

    #expect(snapshot.state == .unavailable(reason: "HTTP 500"))
}

@Test func geminiProbeTests_retrieveUserQuotaBodyEscapesProject() throws {
    // project 来自服务端响应，若含引号/反斜杠必须被安全转义（用 JSONSerialization 而非字符串插值）。
    let request = GeminiProbe.retrieveUserQuotaRequest(accessToken: "t", project: #"a"b\c"#)
    let body = try #require(request.httpBody)
    let obj = try JSONSerialization.jsonObject(with: body) as? [String: String]
    #expect(obj?["project"] == #"a"b\c"#)
}

@Test func geminiProbeTests_retrieveUserQuotaBodyRoundTripsNormalProject() throws {
    let request = GeminiProbe.retrieveUserQuotaRequest(accessToken: "t", project: "proj-FAKE123")
    #expect(String(data: request.httpBody ?? Data(), encoding: .utf8) == #"{"project":"proj-FAKE123"}"#)
}

@Test func geminiTokenRefresher_returnsNilWhenOAuthClientIsMissing() async {
    let refresher = GeminiTokenRefresher(oauthClient: nil) { _ in
        Issue.record("curl should not be called without OAuth client config")
        return nil
    }

    let token = await refresher.refresh(refreshToken: "refresh-token")

    #expect(token == nil)
}

@Test func geminiTokenRefresher_buildsEncodedCurlBodyAndParsesAccessToken() async {
    let capturedBody = LockedString()
    let refresher = GeminiTokenRefresher(
        oauthClient: GeminiOAuthClient(clientID: "client id", clientSecret: "secret+value&x")
    ) { body in
        capturedBody.set(body)
        return #"{"access_token":"new-access-token","expires_in":3600}"#
    }

    let token = await refresher.refresh(refreshToken: "refresh token")
    let body = capturedBody.get()

    #expect(token == "new-access-token")
    #expect(body.contains("client_id=client%20id"))
    #expect(body.contains("client_secret=secret%2Bvalue%26x"))
    #expect(body.contains("refresh_token=refresh%20token"))
    #expect(body.contains("grant_type=refresh_token"))
}
