import AppKit
import Combine
import Foundation
import GQuotaKit
import Network
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshots: [UsageSnapshot] = []
    @Published private(set) var lastUpdated: Date?

    private let coordinator: UsageCoordinator
    private let cache: SnapshotCache
    private let monitor: NWPathMonitor
    private let monitorQueue = DispatchQueue(label: "gquota.netmonitor")
    private var asleep = false
    private var networkUp = true
    private var backoffs: [ProviderID: Backoff] = [:]
    private var nextDue: [ProviderID: Date] = [:]
    private var lastNotified: [ProviderID: Date] = [:]
    private static let notificationCooldown: TimeInterval = 1_800   // 30min，避免在 90% 附近抖动刷屏
    static let notificationsEnabledKey = "notificationsEnabled"
    private var loopTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var reachabilityTask: Task<Void, Never>?
    private var reachabilityContinuation: AsyncStream<Bool>.Continuation?
    private var lifecycleObservers: [ObserverToken] = []

    init() {
        UserDefaults.standard.register(defaults: [Self.notificationsEnabledKey: true])   // 告警默认开

        let cache = SnapshotCache(directory: Self.defaultCacheDirectory())
        self.cache = cache
        self.coordinator = UsageCoordinator(
            probes: [OpenAIProbe(), GeminiProbe(), ClaudeProbe(), CopilotProbe()],
            cache: cache
        )
        self.monitor = NWPathMonitor()

        for id in Self.configuredProviders {
            backoffs[id] = Backoff(base: Self.baseInterval(for: id), cap: Self.backoffCap(for: id))
            nextDue[id] = .distantPast      // 启动即到期，首轮立刻刷新
        }

        subscribeLifecycle()
        subscribeReachability()
        start()
    }

    deinit {
        loopTask?.cancel()
        refreshTask?.cancel()
        reachabilityTask?.cancel()
        reachabilityContinuation?.finish()
        monitor.cancel()
        for observer in lifecycleObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer.value)
        }
    }

    func start() {
        guard loopTask == nil else { return }

        // 请求本地通知授权（首启弹一次系统授权框；拒绝则静默不发通知）。
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        loopTask = Task { [weak self] in
            await self?.loadCachedSnapshots()
            await self?.pollLoop()
        }
    }

    func refreshNow() {
        Task { [weak self] in
            await self?.refreshAllConfiguredIfAllowed()
        }
    }

    var severities: [Double] {
        Self.severities(from: snapshots)
    }

    var menuBarIconSegments: [MenuBarIconSegment] {
        Self.menuBarIconSegments(from: snapshots)
    }

    var menuBarAccessibilityLabel: String {
        Self.menuBarAccessibilityLabel(from: snapshots)
    }

    nonisolated static func menuBarAccessibilityLabel(from snapshots: [UsageSnapshot]) -> String {
        if snapshots.isEmpty {
            return "GQuota，首次检测中"
        }

        let byProvider = Dictionary(snapshots.map { ($0.providerID, $0) }) { _, newest in newest }
        let configuredSnapshots = configuredProviders.compactMap { byProvider[$0] }

        if configuredSnapshots.isEmpty {
            return "GQuota，首次检测中"
        }

        if configuredSnapshots.allSatisfy(Self.isNeedsAuth) {
            return "GQuota，未检测到已登录的 CLI"
        }

        let parts = configuredProviders.map { providerID in
            let providerName = Self.displayName(for: providerID)
            guard let snapshot = byProvider[providerID] else {
                return "\(providerName) 未检测到登录"
            }

            guard hasDisplayableUsage(snapshot) else {
                return "\(providerName) \(stateDescription(for: snapshot.state))"
            }

            let percent = Int((UsageCoordinator.tightestSeverity([snapshot]) * 100).rounded())
            if let context = displayableStateContext(for: snapshot.state) {
                return "\(providerName) \(percent)% \(context)"
            }

            return "\(providerName) \(percent)%"
        }

        return "GQuota，" + parts.joined(separator: "，")
    }

    nonisolated static func severities(from snapshots: [UsageSnapshot]) -> [Double] {
        orderedSnapshots(snapshots).map { UsageCoordinator.tightestSeverity([$0]) }
    }

    nonisolated static func menuBarIconSegments(from snapshots: [UsageSnapshot]) -> [MenuBarIconSegment] {
        let byProvider = Dictionary(snapshots.map { ($0.providerID, $0) }) { _, newest in newest }
        let segments = configuredProviders.map { providerID -> MenuBarIconSegment in
            guard let snapshot = byProvider[providerID], hasDisplayableUsage(snapshot) else {
                return .neutral
            }

            return .usage(UsageCoordinator.tightestSeverity([snapshot]))
        }

        return segments.contains { segment in
            if case .usage = segment {
                return true
            }

            return false
        } ? segments : []
    }

    nonisolated static func shouldRefreshOnReachabilityChange(
        previousNetworkUp: Bool,
        newNetworkUp: Bool,
        asleep: Bool
    ) -> Bool {
        previousNetworkUp == false && newNetworkUp && asleep == false
    }

    struct CriticalAlert: Equatable, Sendable {
        let providerID: ProviderID
        let message: String
    }

    /// 哪些 provider「新进入危险档（>90%）」。仅在「上一轮不是 danger」时返回，避免每轮重复。
    nonisolated static func newlyCritical(
        previous: [UsageSnapshot],
        current: [UsageSnapshot]
    ) -> [CriticalAlert] {
        let previousByProvider = Dictionary(previous.map { ($0.providerID, $0) }) { _, newest in newest }

        return current.compactMap { snapshot -> CriticalAlert? in
            guard hasDisplayableUsage(snapshot) else { return nil }

            let severity = UsageCoordinator.tightestSeverity([snapshot])
            guard Severity.tier(for: severity) == .danger else { return nil }

            let wasDanger = previousByProvider[snapshot.providerID].map { previousSnapshot in
                hasDisplayableUsage(previousSnapshot)
                    && Severity.tier(for: UsageCoordinator.tightestSeverity([previousSnapshot])) == .danger
            } ?? false
            guard wasDanger == false else { return nil }

            let percent = Int((severity * 100).rounded())
            return CriticalAlert(
                providerID: snapshot.providerID,
                message: "\(displayName(for: snapshot.providerID)) 已用 \(percent)%"
            )
        }
    }

    /// VoiceOver 播报用（每次跨档都播报，无障碍主路径）。
    nonisolated static func criticalAnnouncements(
        previous: [UsageSnapshot],
        current: [UsageSnapshot]
    ) -> [String] {
        newlyCritical(previous: previous, current: current).map(\.message)
    }

    /// 系统通知用：跨档之外再加 per-provider 冷却，避免在阈值附近抖动刷屏。
    nonisolated static func shouldNotify(
        providerID: ProviderID,
        now: Date,
        lastNotified: [ProviderID: Date],
        cooldown: TimeInterval
    ) -> Bool {
        guard let last = lastNotified[providerID] else { return true }
        return now.timeIntervalSince(last) >= cooldown
    }

    /// 是否真正投递系统通知：用户开关（设置）+ 冷却共同决定。VoiceOver 播报不受此开关影响（无障碍）。
    nonisolated static func shouldPostNotification(
        enabled: Bool,
        providerID: ProviderID,
        now: Date,
        lastNotified: [ProviderID: Date],
        cooldown: TimeInterval
    ) -> Bool {
        enabled && shouldNotify(providerID: providerID, now: now, lastNotified: lastNotified, cooldown: cooldown)
    }

    /// 已到期、可刷新的 provider 集合（每家独立间隔）。
    nonisolated static func dueProviders(now: Date, nextDue: [ProviderID: Date]) -> Set<ProviderID> {
        Set(nextDue.filter { now >= $0.value }.keys)
    }

    /// 轮询循环下一次唤醒的延迟：睡到最早的 nextDue（夹在 [minimum, ...]）。
    nonisolated static func sleepDelay(
        now: Date,
        nextDue: [ProviderID: Date],
        minimum: TimeInterval = 30,
        fallback: TimeInterval = 180
    ) -> TimeInterval {
        guard let earliest = nextDue.values.min() else { return fallback }
        return max(minimum, earliest.timeIntervalSince(now))
    }

    nonisolated static func orderedSnapshots(_ snapshots: [UsageSnapshot]) -> [UsageSnapshot] {
        let byProvider = Dictionary(snapshots.map { ($0.providerID, $0) }) { _, newest in newest }
        return ProviderID.allCases.compactMap { byProvider[$0] }
    }

    private nonisolated static var configuredProviders: [ProviderID] {
        [.openai, .gemini, .claude, .copilot]
    }

    /// 每家基准轮询间隔。Claude 端点限流极激进（研究：30-60s 即锁 30h+），故 ≥5min。
    private nonisolated static func baseInterval(for id: ProviderID) -> TimeInterval {
        switch id {
        case .claude: return 300
        case .openai, .gemini, .copilot: return 180
        }
    }

    private nonisolated static func backoffCap(for id: ProviderID) -> TimeInterval {
        switch id {
        case .claude: return 1_800
        case .openai, .gemini, .copilot: return 600
        }
    }

    private static func defaultCacheDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GQuota", isDirectory: true)
    }

    private func loadCachedSnapshots() async {
        await cache.loadFromDisk()
        await render()
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            await refreshDueIfAllowed()

            let delay = Self.sleepDelay(now: Date(), nextDue: nextDue)
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func refreshDueIfAllowed() async {
        guard PollGate(asleep: asleep, networkUp: networkUp).shouldPoll else { return }
        let due = Self.dueProviders(now: Date(), nextDue: nextDue)
        guard due.isEmpty == false else { return }
        await refresh(due)
    }

    private func refreshAllConfiguredIfAllowed() async {
        guard PollGate(asleep: asleep, networkUp: networkUp).shouldPoll else { return }
        await refresh(Set(Self.configuredProviders))
    }

    /// 去重/合流：若已有 refresh 在飞（poll 循环、立即刷新连点、唤醒/网络恢复同时触发），
    /// 等它而不是再发一轮——避免重复网络请求与缓存 get-then-put 乱序回写致 UI 瞬时回退。
    private func refresh(_ providers: Set<ProviderID>) async {
        if let refreshTask {
            await refreshTask.value
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh(providers)
        }
        refreshTask = task
        defer { refreshTask = nil }
        await task.value
    }

    private func performRefresh(_ providers: Set<ProviderID>) async {
        await coordinator.refresh(providers)
        await render()

        // 每家独立更新退避与下次到期时间，尊重 429 的 retry-after。
        let now = Date()
        for id in providers {
            let snapshot = snapshots.first { $0.providerID == id }
            if let snapshot, Self.isBackoffFailure(snapshot) {
                backoffs[id]?.recordFailure()
            } else {
                backoffs[id]?.recordSuccess()
            }
            let retryAfter = snapshot.flatMap(Self.retryAfter(from:))
            nextDue[id] = backoffs[id]?.nextFireDate(now: now, retryAfter: retryAfter)
                ?? now.addingTimeInterval(Self.baseInterval(for: id))
        }
    }

    private func render() async {
        let cached = await cache.all()
        let updated = Self.orderedSnapshots(cached)
        let alerts = Self.newlyCritical(previous: snapshots, current: updated)
        snapshots = updated
        lastUpdated = snapshots.map(\.fetchedAt).max()

        let now = Date()
        let notificationsEnabled = UserDefaults.standard.bool(forKey: Self.notificationsEnabledKey)
        for alert in alerts {
            announceCritical(alert.message)   // VoiceOver：每次跨档都播报（无障碍，不受开关影响）
            if Self.shouldPostNotification(
                enabled: notificationsEnabled,
                providerID: alert.providerID,
                now: now,
                lastNotified: lastNotified,
                cooldown: Self.notificationCooldown
            ) {
                postNotification(alert)
                lastNotified[alert.providerID] = now
            }
        }
    }

    private func postNotification(_ alert: CriticalAlert) {
        let content = UNMutableNotificationContent()
        content.title = "GQuota"
        content.body = "\(alert.message) · 额度即将用尽"
        let request = UNNotificationRequest(
            identifier: "gquota.critical.\(alert.providerID.rawValue)",
            content: content,
            trigger: nil   // 立即投递
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func announceCritical(_ message: String) {
        // best-effort：菜单栏 App 无主窗口，向 NSApp 发 announcement。
        // 实际播报需在真机开 VoiceOver 验收（无法在 CI/headless 验证投递）。
        guard let app = NSApp else { return }
        NSAccessibility.post(
            element: app,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }

    private func subscribeLifecycle() {
        let notificationCenter = NSWorkspace.shared.notificationCenter

        lifecycleObservers.append(ObserverToken(
            notificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.asleep = true
                }
            }
        ))

        lifecycleObservers.append(ObserverToken(
            notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.asleep = false
                    self?.refreshNow()
                }
            }
        ))
    }

    private func subscribeReachability() {
        // 路径更新经 AsyncStream 串行交给单一消费者，保证按 monitorQueue 的发生顺序处理，
        // 避免「每事件 spawn 独立 Task」无序执行把 networkUp 写成陈旧值。
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        reachabilityContinuation = continuation

        monitor.pathUpdateHandler = { path in
            continuation.yield(path.status == .satisfied)
        }

        reachabilityTask = Task { [weak self] in
            for await isSatisfied in stream {
                await self?.handleReachability(isSatisfied)
            }
        }

        monitor.start(queue: monitorQueue)
    }

    private func handleReachability(_ isSatisfied: Bool) {
        let shouldRefresh = Self.shouldRefreshOnReachabilityChange(
            previousNetworkUp: networkUp,
            newNetworkUp: isSatisfied,
            asleep: asleep
        )
        networkUp = isSatisfied

        if shouldRefresh {
            refreshNow()
        }
    }

    private nonisolated static func isNeedsAuth(_ snapshot: UsageSnapshot) -> Bool {
        if case .needsAuth = snapshot.state {
            return true
        }

        return false
    }

    private nonisolated static func hasDisplayableUsage(_ snapshot: UsageSnapshot) -> Bool {
        guard snapshot.windows.isEmpty == false else { return false }

        switch snapshot.state {
        case .ok, .stale, .rateLimited, .unavailable:
            return true
        case .needsAuth:
            return false
        }
    }

    private static func isBackoffFailure(_ snapshot: UsageSnapshot) -> Bool {
        switch snapshot.state {
        case .rateLimited, .unavailable:
            return true
        case .ok, .stale, .needsAuth:
            return false
        }
    }

    private nonisolated static func retryAfter(from snapshot: UsageSnapshot) -> Date? {
        guard case .rateLimited(let retryAfter) = snapshot.state else { return nil }
        return retryAfter
    }

    private nonisolated static func displayableStateContext(for state: ProbeState) -> String? {
        switch state {
        case .rateLimited:
            return "限流中"
        case .unavailable:
            return "不可用"
        case .stale:
            return "数据陈旧"
        case .ok, .needsAuth:
            return nil
        }
    }

    private nonisolated static func stateDescription(for state: ProbeState) -> String {
        switch state {
        case .needsAuth:
            return "未检测到登录"
        case .rateLimited:
            return "限流中"
        case .unavailable:
            return "不可用"
        case .stale:
            return "数据陈旧"
        case .ok:
            return "无可显示额度"
        }
    }

    private nonisolated static func displayName(for providerID: ProviderID) -> String {
        switch providerID {
        case .openai:
            return "OpenAI"
        case .gemini:
            return "Gemini"
        case .claude:
            return "Claude"
        case .copilot:
            return "Copilot"
        }
    }
}

private struct ObserverToken: @unchecked Sendable {
    let value: NSObjectProtocol

    init(_ value: NSObjectProtocol) {
        self.value = value
    }
}
