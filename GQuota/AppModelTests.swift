import GQuotaKit
@testable import GQuota
import XCTest

final class AppModelTests: XCTestCase {
    func testCriticalAnnouncementFiresWhenProviderCrossesIntoDanger() {
        let previous = [makeSnapshot(providerID: .openai, measures: [.usedFraction(0.50)])]
        let current = [makeSnapshot(providerID: .openai, measures: [.usedFraction(0.95)])]

        XCTAssertEqual(
            AppModel.criticalAnnouncements(previous: previous, current: current),
            ["OpenAI 已用 95%"]
        )
    }

    func testCriticalAnnouncementDoesNotRepeatWhenAlreadyDanger() {
        let previous = [makeSnapshot(providerID: .openai, measures: [.usedFraction(0.92)])]
        let current = [makeSnapshot(providerID: .openai, measures: [.usedFraction(0.96)])]

        XCTAssertEqual(AppModel.criticalAnnouncements(previous: previous, current: current), [])
    }

    func testCriticalAnnouncementIgnoresNonDangerAndNeedsAuth() {
        let current = [
            makeSnapshot(providerID: .openai, measures: [.usedFraction(0.50)]),
            makeSnapshot(providerID: .gemini, measures: [], state: .needsAuth)
        ]

        XCTAssertEqual(AppModel.criticalAnnouncements(previous: [], current: current), [])
    }

    func testNewlyCriticalCarriesProviderID() {
        let alerts = AppModel.newlyCritical(
            previous: [makeSnapshot(providerID: .claude, measures: [.usedFraction(0.50)])],
            current: [makeSnapshot(providerID: .claude, measures: [.usedFraction(0.95)])]
        )
        XCTAssertEqual(alerts, [AppModel.CriticalAlert(providerID: .claude, message: "Claude 已用 95%")])
    }

    func testCopilotCriticalAnnouncementUsesCopilotDisplayName() {
        let alerts = AppModel.newlyCritical(
            previous: [makeSnapshot(providerID: .copilot, measures: [.usedFraction(0.50)])],
            current: [makeSnapshot(providerID: .copilot, measures: [.usedFraction(0.95)])]
        )

        XCTAssertEqual(alerts, [AppModel.CriticalAlert(providerID: .copilot, message: "Copilot 已用 95%")])
    }

    func testShouldNotifyRespectsCooldown() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // 首次（无记录）→ 通知
        XCTAssertTrue(AppModel.shouldNotify(providerID: .openai, now: now, lastNotified: [:], cooldown: 1_800))
        // 60s 前刚通知过 → 冷却中，不通知
        XCTAssertFalse(AppModel.shouldNotify(
            providerID: .openai, now: now,
            lastNotified: [.openai: now.addingTimeInterval(-60)], cooldown: 1_800
        ))
        // 超过冷却 → 再次通知
        XCTAssertTrue(AppModel.shouldNotify(
            providerID: .openai, now: now,
            lastNotified: [.openai: now.addingTimeInterval(-2_000)], cooldown: 1_800
        ))
    }

    func testShouldPostNotificationRespectsEnabledSwitch() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // 开关关 → 永不通知（即便冷却已过）
        XCTAssertFalse(AppModel.shouldPostNotification(
            enabled: false, providerID: .openai, now: now, lastNotified: [:], cooldown: 1_800
        ))
        // 开关开 + 首次 → 通知
        XCTAssertTrue(AppModel.shouldPostNotification(
            enabled: true, providerID: .openai, now: now, lastNotified: [:], cooldown: 1_800
        ))
        // 开关开 但冷却中 → 不通知
        XCTAssertFalse(AppModel.shouldPostNotification(
            enabled: true, providerID: .openai, now: now,
            lastNotified: [.openai: now.addingTimeInterval(-60)], cooldown: 1_800
        ))
    }

    func testSeveritiesFollowProviderIDOrderAndUseTightestWindow() {
        let snapshots = [
            makeSnapshot(providerID: .gemini, measures: [.remainingFraction(0.60)]),
            makeSnapshot(providerID: .openai, measures: [.usedFraction(0.20), .usedFraction(0.95)])
        ]

        XCTAssertEqual(AppModel.severities(from: snapshots), [0.95, 0.40])
    }

    func testMenuBarIconSegmentsUseNeutralPlaceholderForColdStartAndAllAuthMissing() {
        XCTAssertEqual(AppModel.menuBarIconSegments(from: []), [])

        XCTAssertEqual(
            AppModel.menuBarIconSegments(from: [
                makeSnapshot(providerID: .openai, state: .needsAuth),
                makeSnapshot(providerID: .gemini, state: .needsAuth)
            ]),
            []
        )
    }

    func testMenuBarIconSegmentsUseConfiguredProvidersAndNeutralMissingSlots() {
        // configuredProviders = [openai, gemini, claude, copilot] → 四个槽位。
        XCTAssertEqual(
            AppModel.menuBarIconSegments(from: [
                makeSnapshot(providerID: .openai, measures: [.usedFraction(0.80)]),
                makeSnapshot(providerID: .claude, measures: [.usedFraction(0.99)])
            ]),
            [.usage(0.80), .neutral, .usage(0.99), .neutral]   // gemini、copilot 缺失 → neutral
        )

        XCTAssertEqual(
            AppModel.menuBarIconSegments(from: [
                makeSnapshot(providerID: .openai, measures: [.usedFraction(0.25)]),
                makeSnapshot(providerID: .gemini, state: .needsAuth)
            ]),
            [.usage(0.25), .neutral, .neutral, .neutral]       // gemini needsAuth、claude/copilot 缺失 → neutral
        )
    }

    func testMenuBarIconSegmentsDisplayPreservedFailureWindows() {
        XCTAssertEqual(
            AppModel.menuBarIconSegments(from: [
                makeSnapshot(
                    providerID: .openai,
                    measures: [.usedFraction(0.72)],
                    state: .rateLimited(retryAfter: Date(timeIntervalSince1970: 1_700_000_300))
                ),
                makeSnapshot(
                    providerID: .gemini,
                    measures: [.remainingFraction(0.25)],
                    state: .unavailable(reason: "temporary")
                )
            ]),
            [.usage(0.72), .usage(0.75), .neutral, .neutral]   // claude、copilot 缺失 → neutral
        )
    }

    func testMenuBarAccessibilityLabelUsesStateTextForPartialEmptyProvider() {
        let label = AppModel.menuBarAccessibilityLabel(from: [
            makeSnapshot(providerID: .openai, measures: [.usedFraction(0.72)]),
            makeSnapshot(providerID: .gemini, state: .needsAuth)
        ])

        XCTAssertTrue(label.contains("OpenAI 72%"))
        XCTAssertTrue(label.contains("Gemini 未检测到登录"))
        XCTAssertFalse(label.contains("Gemini 0%"))
        XCTAssertTrue(label.contains("Claude 未检测到登录"))   // claude 已配置但无快照
        XCTAssertTrue(label.contains("Copilot 未检测到登录"))  // copilot 已配置但无快照
        XCTAssertFalse(label.contains("Grok"))                 // xai 未配置
    }

    func testMenuBarAccessibilityLabelKeepsStateContextForPreservedFailureWindows() {
        let label = AppModel.menuBarAccessibilityLabel(from: [
            makeSnapshot(
                providerID: .openai,
                measures: [.usedFraction(0.72)],
                state: .rateLimited(retryAfter: Date(timeIntervalSince1970: 1_700_000_300))
            ),
            makeSnapshot(
                providerID: .gemini,
                measures: [.remainingFraction(0.25)],
                state: .unavailable(reason: "temporary")
            )
        ])

        XCTAssertTrue(label.contains("OpenAI 72%"))
        XCTAssertTrue(label.contains("限流中"))
        XCTAssertTrue(label.contains("Gemini 75%"))
        XCTAssertTrue(label.contains("不可用"))
    }

    func testDueProvidersReturnsOnlyElapsed() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let due = AppModel.dueProviders(now: now, nextDue: [
            .openai: now.addingTimeInterval(-1),   // 已到期
            .gemini: now.addingTimeInterval(60),    // 未到期
            .claude: .distantPast                   // 已到期
        ])
        XCTAssertEqual(due, [.openai, .claude])
    }

    func testSleepDelaySleepsUntilEarliestDueWithMinimumFloor() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // 最早到期在 120s 后 → 睡 120s（高于最小值 30）
        XCTAssertEqual(
            AppModel.sleepDelay(now: now, nextDue: [
                .openai: now.addingTimeInterval(120),
                .claude: now.addingTimeInterval(300)
            ], minimum: 30, fallback: 180),
            120
        )
        // 最早到期已过 → 夹到最小值 30
        XCTAssertEqual(
            AppModel.sleepDelay(now: now, nextDue: [
                .openai: now.addingTimeInterval(-50)
            ], minimum: 30, fallback: 180),
            30
        )
    }

    func testReachabilityRefreshesOnlyWhenNetworkBecomesReadyWhileAwake() {
        XCTAssertTrue(
            AppModel.shouldRefreshOnReachabilityChange(
                previousNetworkUp: false,
                newNetworkUp: true,
                asleep: false
            )
        )
        XCTAssertFalse(
            AppModel.shouldRefreshOnReachabilityChange(
                previousNetworkUp: true,
                newNetworkUp: true,
                asleep: false
            )
        )
        XCTAssertFalse(
            AppModel.shouldRefreshOnReachabilityChange(
                previousNetworkUp: false,
                newNetworkUp: true,
                asleep: true
            )
        )
    }

    private func makeSnapshot(
        providerID: ProviderID,
        measures: [UsageMeasure] = [],
        state: ProbeState = .ok
    ) -> UsageSnapshot {
        UsageSnapshot(
            providerID: providerID,
            windows: measures.enumerated().map { index, measure in
                UsageWindow(
                    label: "Window \(index)",
                    measure: measure,
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
