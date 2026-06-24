import Testing
import Foundation
@testable import GQuotaKit

private struct Boom: Error, Sendable {}

private struct StubProbe: UsageProbe {
    let providerID: ProviderID
    let displayName: String
    let result: Result<UsageSnapshot, Boom>

    func fetch() async throws -> UsageSnapshot { try result.get() }
}

private func window(_ value: Double = 0.72) -> UsageWindow {
    UsageWindow(
        label: "cached",
        measure: .usedFraction(value),
        resetsAt: Date(timeIntervalSince1970: 1_700_003_600),
        confidence: .exact,
        detail: "cached detail"
    )
}

@Test func oneProbeFailureDoesNotBlockOthers() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = SnapshotCache(directory: dir)
    let ok = UsageSnapshot(providerID: .gemini, windows: [], fetchedAt: Date(timeIntervalSince1970: 1), state: .ok)
    let coord = UsageCoordinator(
        probes: [
            StubProbe(providerID: .openai, displayName: "OpenAI", result: .failure(Boom())),
            StubProbe(providerID: .gemini, displayName: "Gemini", result: .success(ok)),
        ],
        cache: cache, clock: FakeClock()
    )

    await coord.refreshAll()

    #expect(await cache.get(.gemini)?.state == .ok)
    let openai = await cache.get(.openai)
    if case .unavailable = openai?.state {} else {
        Issue.record("failed probe should be .unavailable")
    }
}

@Test func refreshOnlyTouchesGivenProviders() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = SnapshotCache(directory: dir)
    let openaiOk = UsageSnapshot(providerID: .openai, windows: [], fetchedAt: Date(timeIntervalSince1970: 1), state: .ok)
    let geminiOk = UsageSnapshot(providerID: .gemini, windows: [], fetchedAt: Date(timeIntervalSince1970: 1), state: .ok)
    let coord = UsageCoordinator(
        probes: [
            StubProbe(providerID: .openai, displayName: "OpenAI", result: .success(openaiOk)),
            StubProbe(providerID: .gemini, displayName: "Gemini", result: .success(geminiOk)),
        ],
        cache: cache, clock: FakeClock()
    )

    await coord.refresh([.gemini])

    #expect(await cache.get(.gemini)?.state == .ok)   // 只刷了 gemini
    #expect(await cache.get(.openai) == nil)           // openai 未被触碰
}

@Test func staleRefreshPreservesCachedWindowsAndFetchedAt() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = SnapshotCache(directory: dir)
    let cachedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let refreshAt = Date(timeIntervalSince1970: 1_700_000_300)
    let cached = UsageSnapshot(
        providerID: .openai,
        windows: [window()],
        fetchedAt: cachedAt,
        state: .ok
    )
    await cache.put(cached)

    let coord = UsageCoordinator(
        probes: [
            StubProbe(
                providerID: .openai,
                displayName: "OpenAI",
                result: .success(UsageSnapshot(
                    providerID: .openai,
                    windows: [],
                    fetchedAt: refreshAt,
                    state: .stale(since: refreshAt)
                ))
            )
        ],
        cache: cache,
        clock: FakeClock()
    )

    await coord.refreshAll()

    let refreshed = await cache.get(.openai)
    #expect(refreshed?.windows == cached.windows)
    #expect(refreshed?.fetchedAt == cachedAt)
    #expect(refreshed?.state == .stale(since: refreshAt))
}

@Test func rateLimitedRefreshPreservesCachedWindowsAndFetchedAt() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = SnapshotCache(directory: dir)
    let cachedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let refreshAt = Date(timeIntervalSince1970: 1_700_000_300)
    let retryAfter = Date(timeIntervalSince1970: 1_700_000_900)
    let cached = UsageSnapshot(
        providerID: .openai,
        windows: [window(0.91)],
        fetchedAt: cachedAt,
        state: .ok
    )
    await cache.put(cached)

    let coord = UsageCoordinator(
        probes: [
            StubProbe(
                providerID: .openai,
                displayName: "OpenAI",
                result: .success(UsageSnapshot(
                    providerID: .openai,
                    windows: [],
                    fetchedAt: refreshAt,
                    state: .rateLimited(retryAfter: retryAfter)
                ))
            )
        ],
        cache: cache,
        clock: FakeClock()
    )

    await coord.refreshAll()

    let refreshed = await cache.get(.openai)
    #expect(refreshed?.windows == cached.windows)
    #expect(refreshed?.fetchedAt == cachedAt)
    #expect(refreshed?.state == .rateLimited(retryAfter: retryAfter))
}

@Test func unavailableRefreshPreservesCachedWindowsAndFetchedAt() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = SnapshotCache(directory: dir)
    let cachedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let refreshAt = Date(timeIntervalSince1970: 1_700_000_300)
    let cached = UsageSnapshot(
        providerID: .gemini,
        windows: [window(0.66)],
        fetchedAt: cachedAt,
        state: .ok
    )
    await cache.put(cached)

    let coord = UsageCoordinator(
        probes: [
            StubProbe(
                providerID: .gemini,
                displayName: "Gemini",
                result: .success(UsageSnapshot(
                    providerID: .gemini,
                    windows: [],
                    fetchedAt: refreshAt,
                    state: .unavailable(reason: "temporary")
                ))
            )
        ],
        cache: cache,
        clock: FakeClock()
    )

    await coord.refreshAll()

    let refreshed = await cache.get(.gemini)
    #expect(refreshed?.windows == cached.windows)
    #expect(refreshed?.fetchedAt == cachedAt)
    #expect(refreshed?.state == .unavailable(reason: "temporary"))
}

@Test func needsAuthRefreshDoesNotPreserveCachedWindows() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = SnapshotCache(directory: dir)
    let cached = UsageSnapshot(
        providerID: .openai,
        windows: [window()],
        fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
        state: .ok
    )
    let authSnapshot = UsageSnapshot(
        providerID: .openai,
        windows: [],
        fetchedAt: Date(timeIntervalSince1970: 1_700_000_300),
        state: .needsAuth
    )
    await cache.put(cached)

    let coord = UsageCoordinator(
        probes: [StubProbe(providerID: .openai, displayName: "OpenAI", result: .success(authSnapshot))],
        cache: cache,
        clock: FakeClock()
    )

    await coord.refreshAll()

    let refreshed = await cache.get(.openai)
    #expect(refreshed == authSnapshot)
}

@Test func tightestSeverityAcrossProviders() {
    let a = UsageSnapshot(providerID: .openai, windows: [
        .init(label: "w", measure: .usedFraction(0.4), resetsAt: nil, confidence: .exact, detail: nil)
    ], fetchedAt: Date(), state: .ok)
    let b = UsageSnapshot(providerID: .gemini, windows: [
        .init(label: "w", measure: .remainingFraction(0.1), resetsAt: nil, confidence: .exact, detail: nil)
    ], fetchedAt: Date(), state: .ok)

    #expect(abs(UsageCoordinator.tightestSeverity([a, b]) - 0.9) < 1e-9)
}
