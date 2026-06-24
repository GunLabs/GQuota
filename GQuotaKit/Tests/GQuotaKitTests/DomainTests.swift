import Testing
import Foundation
@testable import GQuotaKit

@Suite("DomainTests")
struct DomainTests {
@Test func usageMeasureDistinguishesUsedVsRemaining() {
    let used = UsageMeasure.usedFraction(0.72)
    let remaining = UsageMeasure.remainingFraction(0.31)
    // 语义不同：used 0.72 = 用了 72%；remaining 0.31 = 剩 31%（即用了 69%）
    if case .usedFraction(let u) = used { #expect(u == 0.72) } else { Issue.record("wrong case") }
    if case .remainingFraction(let r) = remaining { #expect(r == 0.31) } else { Issue.record("wrong case") }
}

@Test func snapshotHoldsWindowsAndState() {
    let w = UsageWindow(label: "5 小时窗口", measure: .usedFraction(0.5),
                        resetsAt: nil, confidence: .exact, detail: "Plus")
    let snap = UsageSnapshot(providerID: .openai, windows: [w],
                             fetchedAt: Date(timeIntervalSince1970: 0), state: .ok)
    #expect(snap.providerID == .openai)
    #expect(snap.windows.count == 1)
    #expect(snap.state == .ok)
}

@Test func providerIDCoversFourProviders() {
    #expect(ProviderID.allCases == [.openai, .gemini, .claude, .copilot])
}
}
