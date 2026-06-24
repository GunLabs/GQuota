import Foundation

struct GeminiQuotaDTO: Decodable {
    struct Bucket: Decodable {
        let modelId: String
        let remainingFraction: Double
        let resetTime: String?
        let tokenType: String?
    }

    let buckets: [Bucket]
}

struct GeminiLoadCodeAssistDTO: Decodable {
    let cloudaicompanionProject: String?
    let currentTier: Tier?

    struct Tier: Decodable {
        let id: String?
        let name: String?
    }
}
