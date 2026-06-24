import GQuotaKit
@testable import GQuota
import XCTest

final class ProviderRowTests: XCTestCase {
    func testExactUsagePresentationUsesSeveritySymbolPercentAndSemanticAccessibility() {
        let snapshot = makeSnapshot(
            providerID: .openai,
            window: UsageWindow(
                label: "5 小时窗口",
                measure: .usedFraction(0.92),
                resetsAt: Date(timeIntervalSince1970: 1_700_003_600),
                confidence: .exact,
                detail: nil
            ),
            state: .ok
        )

        let presentation = ProviderRowPresentation(
            snapshot: snapshot,
            referenceDate: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(presentation.providerName, "OpenAI")
        XCTAssertEqual(presentation.statusText, "● 92%")
        XCTAssertEqual(presentation.progressValue, 0.92, accuracy: 1e-9)
        XCTAssertTrue(presentation.accessibilityLabel.contains("OpenAI，5 小时窗口已用 92%"))
        XCTAssertFalse(presentation.accessibilityLabel.contains("估算"))
    }

    func testPresentationUsesTightestWindowWhenLaterWindowIsMoreSevere() {
        let snapshot = makeSnapshot(
            providerID: .openai,
            windows: [
                UsageWindow(
                    label: "5 小时窗口",
                    measure: .usedFraction(0.20),
                    resetsAt: nil,
                    confidence: .exact,
                    detail: nil
                ),
                UsageWindow(
                    label: "周限额",
                    measure: .usedFraction(0.92),
                    resetsAt: nil,
                    confidence: .exact,
                    detail: nil
                )
            ],
            state: .ok
        )

        let presentation = ProviderRowPresentation(
            snapshot: snapshot,
            referenceDate: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(presentation.statusText, "● 92%")
        XCTAssertEqual(presentation.progressValue, 0.92, accuracy: 1e-9)
        XCTAssertEqual(presentation.detailText, "周限额")
        XCTAssertTrue(presentation.accessibilityLabel.contains("OpenAI，周限额已用 92%"))
    }

    func testEstimatedStaleUsageAddsEstimateAndStaleMarkers() {
        let snapshot = makeSnapshot(
            providerID: .gemini,
            window: UsageWindow(
                label: "gemini-2.5-pro",
                measure: .remainingFraction(0.25),
                resetsAt: nil,
                confidence: .estimated,
                detail: nil
            ),
            state: .stale(since: Date(timeIntervalSince1970: 1_699_999_000))
        )

        let presentation = ProviderRowPresentation(
            snapshot: snapshot,
            referenceDate: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(presentation.statusText, "◐ ~75% · 陈旧")
        XCTAssertEqual(presentation.progressValue, 0.75, accuracy: 1e-9)
        XCTAssertTrue(presentation.accessibilityLabel.contains("估算"))
        XCTAssertTrue(presentation.accessibilityLabel.contains("数据陈旧"))
    }

    func testNeedsAuthPresentationUsesExplicitStateLabel() {
        let snapshot = makeSnapshot(providerID: .gemini, window: nil, state: .needsAuth)

        let presentation = ProviderRowPresentation(
            snapshot: snapshot,
            referenceDate: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(presentation.providerName, "Gemini")
        XCTAssertEqual(presentation.statusText, "未检测到登录")
        XCTAssertEqual(presentation.progressValue, 0)
        XCTAssertEqual(presentation.accessibilityLabel, "Gemini，未检测到登录")
    }

    func testCopilotPresentationUsesCopilotDisplayName() {
        let snapshot = makeSnapshot(
            providerID: .copilot,
            window: UsageWindow(
                label: "Premium 请求",
                measure: .usedFraction(0.58),
                resetsAt: nil,
                confidence: .exact,
                detail: "Individual Pro"
            ),
            state: .ok
        )

        let presentation = ProviderRowPresentation(
            snapshot: snapshot,
            referenceDate: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(presentation.providerName, "Copilot")
        XCTAssertEqual(presentation.statusText, "○ 58%")
        XCTAssertEqual(presentation.detailText, "Premium 请求 · Individual Pro")
        XCTAssertTrue(presentation.accessibilityLabel.contains("Copilot，Premium 请求已用 58%"))
    }

    func testRateLimitedPreservedUsageRemainsDisplayableWithStateContext() {
        let snapshot = makeSnapshot(
            providerID: .openai,
            window: UsageWindow(
                label: "5 小时窗口",
                measure: .usedFraction(0.72),
                resetsAt: nil,
                confidence: .exact,
                detail: nil
            ),
            state: .rateLimited(retryAfter: Date(timeIntervalSince1970: 1_700_003_600))
        )

        let presentation = ProviderRowPresentation(
            snapshot: snapshot,
            referenceDate: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(presentation.statusText, "◐ 72% · 限流")
        XCTAssertEqual(presentation.progressValue, 0.72, accuracy: 1e-9)
        XCTAssertTrue(presentation.detailText?.contains("5 小时窗口") == true)
        XCTAssertTrue(presentation.detailText?.contains("限流中") == true)
        XCTAssertTrue(presentation.accessibilityLabel.contains("OpenAI，5 小时窗口已用 72%"))
        XCTAssertTrue(presentation.accessibilityLabel.contains("限流中"))
    }

    func testUnavailablePreservedUsageRemainsDisplayableWithReason() {
        let snapshot = makeSnapshot(
            providerID: .gemini,
            window: UsageWindow(
                label: "gemini-2.5-pro",
                measure: .remainingFraction(0.25),
                resetsAt: nil,
                confidence: .exact,
                detail: nil
            ),
            state: .unavailable(reason: "temporary")
        )

        let presentation = ProviderRowPresentation(
            snapshot: snapshot,
            referenceDate: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(presentation.statusText, "◐ 75% · 不可用")
        XCTAssertEqual(presentation.progressValue, 0.75, accuracy: 1e-9)
        XCTAssertTrue(presentation.detailText?.contains("temporary") == true)
        XCTAssertTrue(presentation.accessibilityLabel.contains("Gemini，gemini-2.5-pro已用 75%"))
        XCTAssertTrue(presentation.accessibilityLabel.contains("不可用"))
    }

    private func makeSnapshot(
        providerID: ProviderID,
        window: UsageWindow?,
        state: ProbeState
    ) -> UsageSnapshot {
        makeSnapshot(providerID: providerID, windows: window.map { [$0] } ?? [], state: state)
    }

    private func makeSnapshot(
        providerID: ProviderID,
        windows: [UsageWindow],
        state: ProbeState
    ) -> UsageSnapshot {
        UsageSnapshot(
            providerID: providerID,
            windows: windows,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            state: state
        )
    }
}
