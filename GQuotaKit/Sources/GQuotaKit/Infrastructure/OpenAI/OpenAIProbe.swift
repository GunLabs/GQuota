import Foundation

public struct OpenAIProbe: UsageProbe {
    public let providerID: ProviderID = .openai
    public let displayName = "OpenAI"

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
        let auth = readAuth()
        let accessToken = auth?.tokens.accessToken
        let accountID = auth?.tokens.accountID

        let outcome = await AuthenticatedRequest.run(
            provider: providerID,
            accessToken: accessToken,
            isExpired: accessToken.map { Self.isExpired($0, now: fetchedAt) } ?? false,
            request: { token in
                Self.whamUsageRequest(accessToken: token, accountID: accountID)
            },
            client: client,
            now: { fetchedAt },
            parse: Self.parse
        )

        return snapshot(from: outcome, fetchedAt: fetchedAt)
    }

    static func parse(_ data: Data) throws -> [UsageWindow] {
        let dto = try JSONDecoder().decode(OpenAIUsageDTO.self, from: data)
        var windows: [UsageWindow] = []

        if let primary = dto.rateLimit?.primaryWindow {
            windows.append(window(from: primary, label: "5 小时窗口"))
        }

        if let secondary = dto.rateLimit?.secondaryWindow {
            windows.append(window(from: secondary, label: "周限额"))
        }

        for additional in dto.additionalRateLimits ?? [] {
            let limitName = normalizedLimitName(additional.limitName)

            if let primary = additional.rateLimit?.primaryWindow {
                windows.append(window(
                    from: primary,
                    label: "\(limitName) 5 小时窗口",
                    detail: additional.meteredFeature
                ))
            }

            if let secondary = additional.rateLimit?.secondaryWindow {
                windows.append(window(
                    from: secondary,
                    label: "\(limitName) 周限额",
                    detail: additional.meteredFeature
                ))
            }
        }

        return windows
    }

    static func planType(fromAccessToken token: String) -> String? {
        guard let claims = try? JWTDecoder.decodePayload(token) else { return nil }
        return claims["chatgpt_plan_type"] as? String
    }

    static func isExpired(_ token: String, now: Date) -> Bool {
        guard let claims = try? JWTDecoder.decodePayload(token) else { return false }
        guard let exp = claims["exp"] else { return false }

        let seconds: Double?
        if let value = exp as? Double {
            seconds = value
        } else if let value = exp as? Int {
            seconds = Double(value)
        } else if let value = exp as? String {
            seconds = Double(value)
        } else {
            seconds = nil
        }

        guard let seconds else { return false }
        return Date(timeIntervalSince1970: seconds) <= now
    }

    private func readAuth() -> CodexAuth? {
        guard let data = try? credentialReader.read(relativePath: ".codex/auth.json") else {
            return nil
        }
        return try? JSONDecoder().decode(CodexAuth.self, from: data)
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

    private static func whamUsageRequest(accessToken: String, accountID: String?) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID {
            request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
        }
        request.setValue("GQuota/0.1", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func window(
        from dto: OpenAIUsageDTO.Window,
        label: String,
        detail: String? = nil
    ) -> UsageWindow {
        UsageWindow(
            label: label,
            measure: .usedFraction(dto.usedPercent / 100),
            resetsAt: dto.resetAt.map { Date(timeIntervalSince1970: $0) },
            confidence: .exact,
            detail: detail
        )
    }

    private static func normalizedLimitName(_ limitName: String?) -> String {
        let trimmed = limitName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "附加限额" : trimmed
    }
}
