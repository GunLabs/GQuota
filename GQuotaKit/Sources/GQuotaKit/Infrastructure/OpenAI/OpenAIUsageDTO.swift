import Foundation

struct OpenAIUsageDTO: Decodable, Sendable {
    struct RateLimit: Decodable, Sendable {
        let primaryWindow: Window?
        let secondaryWindow: Window?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    struct Window: Decodable, Sendable {
        let limitWindowSeconds: Double?
        let resetAfterSeconds: Double?
        let resetAt: Double?
        let usedPercent: Double

        enum CodingKeys: String, CodingKey {
            case limitWindowSeconds = "limit_window_seconds"
            case resetAfterSeconds = "reset_after_seconds"
            case resetAt = "reset_at"
            case usedPercent = "used_percent"
        }
    }

    struct Credits: Decodable, Sendable {
        let balance: String?
        let hasCredits: Bool?

        enum CodingKeys: String, CodingKey {
            case balance
            case hasCredits = "has_credits"
        }
    }

    struct AdditionalRateLimit: Decodable, Sendable {
        let limitName: String?
        let meteredFeature: String?
        let rateLimit: RateLimit?

        enum CodingKeys: String, CodingKey {
            case limitName = "limit_name"
            case meteredFeature = "metered_feature"
            case rateLimit = "rate_limit"
        }
    }

    let planType: String?
    let rateLimit: RateLimit?
    let additionalRateLimits: [AdditionalRateLimit]?
    let credits: Credits?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case additionalRateLimits = "additional_rate_limits"
        case credits
    }
}
