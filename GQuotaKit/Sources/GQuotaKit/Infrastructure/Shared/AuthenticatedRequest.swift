import Foundation

/// 编排结果。`.ok` 携带解析出的窗口；其余对应 ProbeState 的非 ok 分支。
public enum AuthOutcome: Sendable, Equatable {
    case ok([UsageWindow])
    case stale
    case needsAuth
    case rateLimited(retryAfter: Date?)
    case unavailable(reason: String)
}

public enum AuthenticatedRequest {
    /// 共享认证请求编排。MVP：过期 token -> .stale（不刷新，spec 7/OV2）。
    public static func run(
        provider: ProviderID,
        accessToken: String?,
        isExpired: Bool,
        request: (String) -> URLRequest,
        client: HTTPClient,
        now: @escaping @Sendable () -> Date = Date.init,
        parseFailureReason: String = "Parse failed",
        authFailureReason: String? = nil,
        parse: (Data) throws -> [UsageWindow]
    ) async -> AuthOutcome {
        guard let token = accessToken else { return .needsAuth }
        if isExpired { return .stale }

        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await client.send(request(token))
        } catch {
            return .stale
        }

        switch http.statusCode {
        case 200..<300:
            do {
                let windows = try parse(data)
                return .ok(windows)
            } catch {
                return .unavailable(reason: parseFailureReason)
            }
        case 401:
            if let authFailureReason {
                return .unavailable(reason: authFailureReason)
            }
            return .needsAuth
        case 403:
            if provider == .copilot, let retryAfter = RetryAfterParser.parse(from: http, now: now()) {
                return .rateLimited(retryAfter: retryAfter)
            }
            if let authFailureReason {
                return .unavailable(reason: authFailureReason)
            }
            return .needsAuth
        case 429:
            return .rateLimited(retryAfter: RetryAfterParser.parse(from: http, now: now()))
        default:
            return .unavailable(reason: "HTTP \(http.statusCode)")
        }
    }
}
