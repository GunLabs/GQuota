import Foundation

/// `GET api.anthropic.com/api/oauth/usage` 响应子集。
/// 字段名按研究记录（utilization 0-100，resets_at ISO8601）；真实结构待 Phase 0 spike 4 确认。
struct ClaudeUsageDTO: Decodable, Sendable {
    struct Window: Decodable, Sendable {
        let utilization: Double
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    struct ExtraUsage: Decodable, Sendable {
        let isEnabled: Bool?
        let utilization: Double?

        enum CodingKeys: String, CodingKey {
            case isEnabled = "is_enabled"
            case utilization
        }
    }

    let fiveHour: Window?
    let sevenDay: Window?
    let sevenDayOpus: Window?
    let sevenDaySonnet: Window?
    let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case extraUsage = "extra_usage"
    }
}
