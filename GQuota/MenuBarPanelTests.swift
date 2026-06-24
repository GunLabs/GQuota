import GQuotaKit
@testable import GQuota
import XCTest

final class MenuBarPanelTests: XCTestCase {
    func testContentStateDistinguishesColdStartAllAuthMissingAndProviderRows() {
        XCTAssertEqual(MenuBarPanel.contentState(for: []), .coldStart)

        XCTAssertEqual(
            MenuBarPanel.contentState(for: [
                makeSnapshot(providerID: .openai, state: .needsAuth),
                makeSnapshot(providerID: .gemini, state: .needsAuth)
            ]),
            .allAuthMissing
        )

        XCTAssertEqual(
            MenuBarPanel.contentState(for: [
                makeSnapshot(providerID: .openai, state: .ok, measures: [.usedFraction(0.25)]),
                makeSnapshot(providerID: .gemini, state: .needsAuth)
            ]),
            .providers
        )
    }

    func testAllAuthMissingHintMentionsCopilotLoginSources() {
        XCTAssertTrue(MenuBarPanel.allAuthMissingTitle.contains("CLI/IDE"))
        XCTAssertTrue(MenuBarPanel.allAuthMissingHint.contains("codex"))
        XCTAssertTrue(MenuBarPanel.allAuthMissingHint.contains("gemini"))
        XCTAssertTrue(MenuBarPanel.allAuthMissingHint.contains("claude"))
        XCTAssertTrue(MenuBarPanel.allAuthMissingHint.contains("gh"))
        XCTAssertTrue(MenuBarPanel.allAuthMissingHint.contains("GitHub Copilot"))
    }

    private func makeSnapshot(
        providerID: ProviderID,
        state: ProbeState,
        measures: [UsageMeasure] = []
    ) -> UsageSnapshot {
        UsageSnapshot(
            providerID: providerID,
            windows: measures.map {
                UsageWindow(
                    label: "Window",
                    measure: $0,
                    resetsAt: nil,
                    confidence: .exact,
                    detail: nil
                )
            },
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            state: state
        )
    }
}
