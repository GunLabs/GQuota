import Foundation

public enum CopilotUsageParseError: Error, Equatable {
    case noUsableQuota
}

struct CopilotUsageDTO: Decodable, Sendable {
    struct QuotaSnapshots: Decodable, Sendable {
        let premiumInteractions: QuotaSnapshot?
        let chat: QuotaSnapshot?
        let completions: QuotaSnapshot?

        enum CodingKeys: String, CodingKey {
            case premiumInteractions = "premium_interactions"
            case chat
            case completions
        }
    }

    struct QuotaSnapshot: Decodable, Sendable {
        let percentRemaining: FlexibleDouble?
        let entitlement: FlexibleDouble?
        let remaining: FlexibleDouble?

        enum CodingKeys: String, CodingKey {
            case percentRemaining = "percent_remaining"
            case entitlement
            case remaining
        }
    }

    let copilotPlan: String?
    let quotaResetDate: String?
    let quotaSnapshots: QuotaSnapshots?
    let monthlyQuotas: [String: FlexibleDouble]?
    let limitedUserQuotas: [String: FlexibleDouble]?

    enum CodingKeys: String, CodingKey {
        case copilotPlan = "copilot_plan"
        case quotaResetDate = "quota_reset_date"
        case quotaSnapshots = "quota_snapshots"
        case monthlyQuotas = "monthly_quotas"
        case limitedUserQuotas = "limited_user_quotas"
    }
}

struct FlexibleDouble: Decodable, Sendable, Equatable {
    let value: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let value = try? container.decode(Double.self), value.isFinite {
            self.value = value
            return
        }

        if let string = try? container.decode(String.self),
           let value = Double(string),
           value.isFinite {
            self.value = value
            return
        }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Expected finite number or numeric string"
        )
    }
}

public enum CopilotUsageMapper {
    public static func parse(_ data: Data) throws -> [UsageWindow] {
        let dto = try JSONDecoder().decode(CopilotUsageDTO.self, from: data)
        let resetsAt = parseDate(dto.quotaResetDate)
        let detail = normalizedPlan(dto.copilotPlan)
        var windows: [UsageWindow] = []

        let snapshots: [(key: String, snapshot: CopilotUsageDTO.QuotaSnapshot?)] = [
            ("premium_interactions", dto.quotaSnapshots?.premiumInteractions),
            ("chat", dto.quotaSnapshots?.chat),
            ("completions", dto.quotaSnapshots?.completions),
        ]

        for entry in snapshots {
            guard let snapshot = entry.snapshot,
                  let usedFraction = usedFraction(from: snapshot)
            else { continue }

            windows.append(UsageWindow(
                label: label(for: entry.key),
                measure: .usedFraction(usedFraction),
                resetsAt: resetsAt,
                confidence: .exact,
                detail: detail
            ))
        }

        if windows.isEmpty {
            windows.append(contentsOf: fallbackWindows(
                monthlyQuotas: dto.monthlyQuotas ?? [:],
                limitedUserQuotas: dto.limitedUserQuotas ?? [:],
                resetsAt: resetsAt,
                detail: detail
            ))
        }

        guard windows.isEmpty == false else {
            throw CopilotUsageParseError.noUsableQuota
        }

        return windows
    }

    private static func fallbackWindows(
        monthlyQuotas: [String: FlexibleDouble],
        limitedUserQuotas: [String: FlexibleDouble],
        resetsAt: Date?,
        detail: String?
    ) -> [UsageWindow] {
        let preferredKeys = ["premium_interactions", "chat", "completions"]
        let sortedKeys = preferredKeys + monthlyQuotas.keys.sorted().filter { preferredKeys.contains($0) == false }

        return sortedKeys.compactMap { key in
            guard let monthly = monthlyQuotas[key]?.value,
                  let limited = limitedUserQuotas[key]?.value,
                  monthly > 0
            else { return nil }

            return UsageWindow(
                label: label(for: key),
                measure: .usedFraction(clamp(1 - limited / monthly)),
                resetsAt: resetsAt,
                confidence: .exact,
                detail: detail
            )
        }
    }

    private static func usedFraction(from snapshot: CopilotUsageDTO.QuotaSnapshot) -> Double? {
        if let percentRemaining = snapshot.percentRemaining?.value {
            return clamp((100 - percentRemaining) / 100)
        }

        guard let entitlement = snapshot.entitlement?.value,
              entitlement > 0,
              let remaining = snapshot.remaining?.value
        else { return nil }

        return clamp(1 - remaining / entitlement)
    }

    private static func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    private static func label(for key: String) -> String {
        switch key {
        case "premium_interactions":
            return "Premium 请求"
        case "chat":
            return "Chat"
        case "completions":
            return "Completions"
        default:
            return key
                .split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    private static func normalizedPlan(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.isEmpty == false
        else { return nil }

        return value
            .split { $0 == "_" || $0 == "-" || $0 == " " }
            .map { part in part.prefix(1).uppercased() + part.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }

        let standard = ISO8601DateFormatter()
        if let date = standard.date(from: value) {
            return date
        }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value)
    }
}
