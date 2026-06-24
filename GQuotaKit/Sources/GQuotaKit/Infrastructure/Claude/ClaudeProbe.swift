import Foundation

public struct ClaudeProbe: UsageProbe {
    public let providerID: ProviderID = .claude
    public let displayName = "Claude"

    private let credentialSource: ClaudeCredentialSource
    private let client: HTTPClient
    private let now: @Sendable () -> Date
    private let userAgent: String

    public init(
        credentialSource: ClaudeCredentialSource = KeychainClaudeCredentialSource(),
        client: HTTPClient = URLSessionHTTPClient(),
        now: @escaping @Sendable () -> Date = Date.init,
        userAgent: String = "claude-code/1.0.0"
    ) {
        self.credentialSource = credentialSource
        self.client = client
        self.now = now
        self.userAgent = userAgent
    }

    public func fetch() async throws -> UsageSnapshot {
        let fetchedAt = now()
        let oauth = readCredentials()
        let accessToken = oauth?.accessToken
        let subscriptionType = oauth?.subscriptionType

        let outcome = await AuthenticatedRequest.run(
            provider: providerID,
            accessToken: accessToken,
            isExpired: oauth.map { Self.isExpired($0, now: fetchedAt) } ?? false,
            request: { token in Self.usageRequest(accessToken: token, userAgent: userAgent) },
            client: client,
            now: { fetchedAt },
            parse: { try Self.parse($0, subscriptionType: subscriptionType) }
        )

        return snapshot(from: outcome, fetchedAt: fetchedAt)
    }

    static func parse(_ data: Data, subscriptionType: String?) throws -> [UsageWindow] {
        let dto = try JSONDecoder().decode(ClaudeUsageDTO.self, from: data)
        var windows: [UsageWindow] = []

        func append(_ window: ClaudeUsageDTO.Window?, label: String, detail: String?) {
            guard let window else { return }
            windows.append(UsageWindow(
                label: label,
                measure: .usedFraction(window.utilization / 100),
                resetsAt: Self.parseISO8601(window.resetsAt),
                confidence: .exact,
                detail: detail
            ))
        }

        append(dto.fiveHour, label: "5 小时窗口", detail: subscriptionType.map { $0.capitalized })
        append(dto.sevenDay, label: "周限额", detail: nil)
        append(dto.sevenDayOpus, label: "周限额 · Opus", detail: nil)
        append(dto.sevenDaySonnet, label: "周限额 · Sonnet", detail: nil)

        if let extra = dto.extraUsage, extra.isEnabled == true, let utilization = extra.utilization {
            windows.append(UsageWindow(
                label: "额外用量",
                measure: .usedFraction(utilization / 100),
                resetsAt: nil,
                confidence: .exact,
                detail: nil
            ))
        }

        return windows
    }

    /// Claude 的 resets_at 带小数秒（如 `...:59.614364+00:00`），默认 ISO8601 选项解析不了，
    /// 先试带小数秒、再回退普通 internet date-time。（spike 4 实测格式）
    static func parseISO8601(_ string: String?) -> Date? {
        guard let string else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    static func isExpired(_ oauth: ClaudeCredentials.OAuth, now: Date) -> Bool {
        guard let expiresAt = oauth.expiresAt else { return false }
        return Date(timeIntervalSince1970: expiresAt / 1_000) <= now
    }

    private func readCredentials() -> ClaudeCredentials.OAuth? {
        guard let data = (try? credentialSource.read()) ?? nil else { return nil }
        return try? JSONDecoder().decode(ClaudeCredentials.self, from: data).claudeAiOauth
    }

    private func snapshot(from outcome: AuthOutcome, fetchedAt: Date) -> UsageSnapshot {
        switch outcome {
        case .ok(let windows):
            return UsageSnapshot(providerID: providerID, windows: windows, fetchedAt: fetchedAt, state: .ok)
        case .stale:
            return UsageSnapshot(providerID: providerID, windows: [], fetchedAt: fetchedAt, state: .stale(since: fetchedAt))
        case .needsAuth:
            return UsageSnapshot(providerID: providerID, windows: [], fetchedAt: fetchedAt, state: .needsAuth)
        case .rateLimited(let retryAfter):
            return UsageSnapshot(providerID: providerID, windows: [], fetchedAt: fetchedAt, state: .rateLimited(retryAfter: retryAfter))
        case .unavailable(let reason):
            return UsageSnapshot(providerID: providerID, windows: [], fetchedAt: fetchedAt, state: .unavailable(reason: reason))
        }
    }

    private static func usageRequest(accessToken: String, userAgent: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}
