import Foundation

public enum ProbeState: Sendable, Equatable {
    case ok
    case stale(since: Date)              // 有缓存但已过期/接口暂不可用（含 token 过期未刷新）
    case needsAuth                       // 凭证缺失
    case rateLimited(retryAfter: Date?)
    case unavailable(reason: String)
}
