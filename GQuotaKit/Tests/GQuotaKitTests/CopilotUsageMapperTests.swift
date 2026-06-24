import Foundation
import Testing
@testable import GQuotaKit

private func copilotFixtureData(_ name: String = "copilot-user") throws -> Data {
    let url = try #require(Bundle.module.url(
        forResource: name,
        withExtension: "json",
        subdirectory: "Fixtures"
    ))
    return try Data(contentsOf: url)
}

@Test func copilotMapper_parsesFixturePercentRemainingAsUsedFraction() throws {
    let windows = try CopilotUsageMapper.parse(copilotFixtureData())

    #expect(windows.count == 3)

    let premium = try #require(windows.first { $0.label == "Premium 请求" })
    #expect(premium.measure == .usedFraction(0.58))
    #expect(premium.confidence == .exact)
    #expect(premium.resetsAt == ISO8601DateFormatter().date(from: "2026-07-01T00:00:00Z"))
    #expect(premium.detail == "Individual Pro")

    let chat = try #require(windows.first { $0.label == "Chat" })
    #expect(chat.measure == .usedFraction(0.10))
    #expect(chat.detail == "Individual Pro")

    let completions = try #require(windows.first { $0.label == "Completions" })
    #expect(completions.measure == .usedFraction(0.0))
}

@Test func copilotMapper_usesEntitlementAndRemainingWhenPercentIsMissing() throws {
    let json = """
    {
      "copilot_plan": "business",
      "quota_reset_date": "2026-07-01T00:00:00Z",
      "quota_snapshots": {
        "premium_interactions": {
          "entitlement": "300",
          "remaining": "75"
        }
      }
    }
    """

    let windows = try CopilotUsageMapper.parse(Data(json.utf8))

    #expect(windows.count == 1)
    #expect(windows[0].label == "Premium 请求")
    #expect(windows[0].measure == .usedFraction(0.75))
    #expect(windows[0].detail == "Business")
}

@Test func copilotMapper_usesMonthlyAndLimitedFallbackWhenSnapshotsAreMissing() throws {
    let json = """
    {
      "copilot_plan": "individual_pro",
      "quota_reset_date": "2026-07-01T00:00:00Z",
      "monthly_quotas": {
        "chat": "300",
        "completions": 100
      },
      "limited_user_quotas": {
        "chat": "60",
        "completions": 100
      }
    }
    """

    let windows = try CopilotUsageMapper.parse(Data(json.utf8))

    #expect(windows.count == 2)
    #expect(windows.first { $0.label == "Chat" }?.measure == .usedFraction(0.80))
    #expect(windows.first { $0.label == "Completions" }?.measure == .usedFraction(0.0))
}

@Test func copilotMapper_clampsInvalidPercentages() throws {
    let json = """
    {
      "quota_snapshots": {
        "premium_interactions": { "percent_remaining": -20 },
        "chat": { "percent_remaining": 150 }
      }
    }
    """

    let windows = try CopilotUsageMapper.parse(Data(json.utf8))

    #expect(windows.first { $0.label == "Premium 请求" }?.measure == .usedFraction(1.0))
    #expect(windows.first { $0.label == "Chat" }?.measure == .usedFraction(0.0))
}

@Test func copilotMapper_throwsWhenNoUsableQuotaExists() throws {
    let json = #"{"copilot_plan":"individual_pro","quota_snapshots":{"premium_interactions":{}}}"#

    #expect(throws: CopilotUsageParseError.noUsableQuota) {
        try CopilotUsageMapper.parse(Data(json.utf8))
    }
}
