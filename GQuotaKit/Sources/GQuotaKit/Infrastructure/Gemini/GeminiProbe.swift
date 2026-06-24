import Foundation

public struct GeminiProbe: UsageProbe {
    public let providerID: ProviderID = .gemini
    public let displayName = "Gemini"

    private let credentialReader: CredentialReader
    private let client: HTTPClient
    private let now: @Sendable () -> Date

    public init(
        credentialReader: CredentialReader = FileCredentialReader(),
        client: HTTPClient = URLSessionHTTPClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.credentialReader = credentialReader
        self.client = client
        self.now = now
    }

    public func fetch() async throws -> UsageSnapshot {
        let fetchedAt = now()
        guard let oauth = readOAuth(),
              let accessToken = oauth.access_token,
              accessToken.isEmpty == false
        else {
            return snapshot(state: .needsAuth, fetchedAt: fetchedAt)
        }

        // 若 access_token 过期且有 refresh_token，先静默刷新；刷新失败再返回 stale。
        let effectiveToken: String
        if Self.isExpired(oauth, now: fetchedAt) {
            guard let refreshToken = oauth.refresh_token,
                  let newToken = await GeminiTokenRefresher().refresh(refreshToken: refreshToken)
            else {
                return snapshot(state: .stale(since: fetchedAt), fetchedAt: fetchedAt)
            }
            effectiveToken = newToken
        } else {
            effectiveToken = accessToken
        }

        let loadData: Data
        let loadResponse: HTTPURLResponse
        do {
            (loadData, loadResponse) = try await client.send(Self.loadCodeAssistRequest(accessToken: effectiveToken))
        } catch {
            return snapshot(state: .stale(since: fetchedAt), fetchedAt: fetchedAt)
        }

        guard (200..<300).contains(loadResponse.statusCode),
              let project = try? Self.project(from: loadData),
              project.isEmpty == false
        else {
            return snapshot(state: .unavailable(reason: "需配置 GCP 项目"), fetchedAt: fetchedAt)
        }

        let quotaData: Data
        let quotaResponse: HTTPURLResponse
        do {
            (quotaData, quotaResponse) = try await client.send(Self.retrieveUserQuotaRequest(accessToken: effectiveToken, project: project))
        } catch {
            return snapshot(state: .stale(since: fetchedAt), fetchedAt: fetchedAt)
        }

        switch quotaResponse.statusCode {
        case 200..<300:
            do {
                let windows = try Self.parse(quotaData)
                return UsageSnapshot(providerID: providerID, windows: windows, fetchedAt: fetchedAt, state: .ok)
            } catch {
                return snapshot(state: .unavailable(reason: "Parse failed"), fetchedAt: fetchedAt)
            }
        case 401:
            return snapshot(state: .needsAuth, fetchedAt: fetchedAt)
        case 403:
            return snapshot(state: .unavailable(reason: "Code Assist 未启用"), fetchedAt: fetchedAt)
        case 429:
            return snapshot(
                state: .rateLimited(retryAfter: RetryAfterParser.parse(from: quotaResponse, now: fetchedAt)),
                fetchedAt: fetchedAt
            )
        default:
            return snapshot(state: .unavailable(reason: "HTTP \(quotaResponse.statusCode)"), fetchedAt: fetchedAt)
        }
    }

    static func parse(_ data: Data) throws -> [UsageWindow] {
        let dto = try JSONDecoder().decode(GeminiQuotaDTO.self, from: data)
        let formatter = ISO8601DateFormatter()

        return dto.buckets.map { bucket in
            UsageWindow(
                label: bucket.modelId,
                measure: .remainingFraction(bucket.remainingFraction),
                resetsAt: bucket.resetTime.flatMap { formatter.date(from: $0) },
                confidence: .exact,
                detail: nil
            )
        }
    }

    // dummy-100% 二级启发式（「全 bucket remainingFraction==1.0 即假数据」）已移除：
    // 它会把「当天还没用过 Gemini 的合法新用户」误报成 unavailable。
    // 真正的 dummy 风险（拿不到 project）由 fetch() 的 project 一级防线兜住
    // （空/缺 project → .unavailable("需配置 GCP 项目")）。决定见 spec 第 5.3 节。

    private static func isExpired(_ oauth: GeminiOAuth, now: Date) -> Bool {
        guard let expiryDate = oauth.expiry_date else { return false }
        return Date(timeIntervalSince1970: expiryDate / 1_000) <= now
    }

    private func readOAuth() -> GeminiOAuth? {
        guard let data = try? credentialReader.read(relativePath: ".gemini/oauth_creds.json") else {
            return nil
        }
        return try? JSONDecoder().decode(GeminiOAuth.self, from: data)
    }

    private func snapshot(state: ProbeState, fetchedAt: Date) -> UsageSnapshot {
        UsageSnapshot(providerID: providerID, windows: [], fetchedAt: fetchedAt, state: state)
    }

    private static func project(from data: Data) throws -> String? {
        let dto = try JSONDecoder().decode(GeminiLoadCodeAssistDTO.self, from: data)
        return dto.cloudaicompanionProject?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func loadCodeAssistRequest(accessToken: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"metadata":{"ideType":"GEMINI_CLI","pluginType":"GEMINI"}}"#.utf8)
        return request
    }

    // internal（非 private）以便单测直接验证 body 转义。
    static func retrieveUserQuotaRequest(accessToken: String, project: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 用 JSONSerialization 安全构造：project（来自服务端响应）若含引号/控制字符也会被正确转义。
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["project": project])
        return request
    }
}
