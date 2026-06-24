import Foundation

public struct CopilotProbe: UsageProbe {
    public let providerID: ProviderID = .copilot
    public let displayName = "Copilot"

    private let tokenSource: any CopilotTokenSource
    private let client: HTTPClient
    private let now: @Sendable () -> Date

    public init(
        tokenSource: any CopilotTokenSource = DefaultCopilotTokenSource(),
        client: HTTPClient = URLSessionHTTPClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.tokenSource = tokenSource
        self.client = client
        self.now = now
    }

    public func fetch() async throws -> UsageSnapshot {
        let fetchedAt = now()
        guard let token = await tokenSource.token() else {
            return UsageSnapshot(providerID: providerID, windows: [], fetchedAt: fetchedAt, state: .needsAuth)
        }

        let outcome = await AuthenticatedRequest.run(
            provider: providerID,
            accessToken: token,
            isExpired: false,
            request: Self.usageRequest,
            client: client,
            now: { fetchedAt },
            parseFailureReason: "Copilot 响应格式已变化",
            authFailureReason: "Copilot token 被拒绝",
            parse: Self.parse
        )

        return snapshot(from: outcome, fetchedAt: fetchedAt)
    }

    public static func parse(_ data: Data) throws -> [UsageWindow] {
        try CopilotUsageMapper.parse(data)
    }

    private static func usageRequest(accessToken: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.github.com/copilot_internal/user")!)
        request.setValue("token \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("vscode/1.96.2", forHTTPHeaderField: "Editor-Version")
        request.setValue("copilot-chat/0.26.7", forHTTPHeaderField: "Editor-Plugin-Version")
        request.setValue("GitHubCopilotChat/0.26.7", forHTTPHeaderField: "User-Agent")
        request.setValue("2025-04-01", forHTTPHeaderField: "X-Github-Api-Version")
        return request
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
}
