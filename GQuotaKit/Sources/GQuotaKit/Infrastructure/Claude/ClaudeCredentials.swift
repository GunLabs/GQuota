import Foundation

/// `Claude Code-credentials`（Keychain）/ `~/.claude/.credentials.json` 的子集。
struct ClaudeCredentials: Decodable, Sendable, Equatable {
    struct OAuth: Decodable, Sendable, Equatable {
        let accessToken: String?
        let refreshToken: String?
        let expiresAt: Double?            // 毫秒 epoch
        let subscriptionType: String?     // "pro" | "max"
    }

    let claudeAiOauth: OAuth
}
