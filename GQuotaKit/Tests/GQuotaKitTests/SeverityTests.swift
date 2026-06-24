import Testing
@testable import GQuotaKit

@Suite("SeverityTests")
struct SeverityTests {
    @Test func usedFractionMapsDirectly() {
        #expect(Severity.normalized(.usedFraction(0.9)) == 0.9)
    }

    @Test func remainingFractionInverts() {
        // 剩 0.31 -> 用了 0.69
        #expect(abs(Severity.normalized(.remainingFraction(0.31)) - 0.69) < 1e-9)
    }

    @Test func unknownDenominatorPassesUsed() {
        #expect(Severity.normalized(.unknownDenominator(used: 0.4)) == 0.4)
    }

    @Test func creditsBalanceIsLowSeverityWhenPositive() {
        // 余额型无「百分比」，余额>0 视为低紧张度(0)；耗尽视为高(1)
        #expect(Severity.normalized(.creditsBalance(amount: 10, currency: "USD")) == 0)
        #expect(Severity.normalized(.creditsBalance(amount: 0, currency: "USD")) == 1)
    }

    @Test func tierThresholds() {
        #expect(Severity.tier(for: 0.50) == .ok)
        #expect(Severity.tier(for: 0.75) == .warn)
        #expect(Severity.tier(for: 0.92) == .danger)
    }

    @Test func tierHasDistinctIconPerLevel() {
        // 色盲双通道：每档有不同图标符号
        let icons = Set([SeverityTier.ok, .warn, .danger].map(\.iconSymbol))
        #expect(icons.count == 3)
    }
}
