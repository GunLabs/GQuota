import Foundation

public actor UsageCoordinator {
    private let probes: [any UsageProbe]
    private let cache: SnapshotCache
    private let clock: Clock

    public init(probes: [any UsageProbe], cache: SnapshotCache, clock: Clock = SystemClock()) {
        self.probes = probes
        self.cache = cache
        self.clock = clock
    }

    /// Concurrently refreshes all providers; a single probe failure is isolated as unavailable.
    public func refreshAll() async {
        await refresh(Set(probes.map(\.providerID)))
    }

    /// Concurrently refreshes only the given providers (per-provider polling cadence).
    /// A single probe failure is isolated as unavailable.
    public func refresh(_ providerIDs: Set<ProviderID>) async {
        let probes = self.probes.filter { providerIDs.contains($0.providerID) }
        guard probes.isEmpty == false else { return }
        let cache = self.cache
        let clock = self.clock

        await withTaskGroup(of: UsageSnapshot.self) { group in
            for probe in probes {
                group.addTask {
                    do {
                        return try await probe.fetch()
                    } catch {
                        return UsageSnapshot(
                            providerID: probe.providerID,
                            windows: [],
                            fetchedAt: clock.now(),
                            state: .unavailable(reason: "\(error)")
                        )
                    }
                }
            }

            for await snapshot in group {
                let cached = await cache.get(snapshot.providerID)
                await cache.put(Self.snapshotForCache(snapshot, preservingFrom: cached))
            }
        }
    }

    /// Returns the tightest normalized severity across all provider windows. Empty data is 0.
    public static func tightestSeverity(_ snapshots: [UsageSnapshot]) -> Double {
        snapshots.flatMap(\.windows).map { Severity.normalized($0.measure) }.max() ?? 0
    }

    private static func snapshotForCache(
        _ snapshot: UsageSnapshot,
        preservingFrom cached: UsageSnapshot?
    ) -> UsageSnapshot {
        guard let cached,
              cached.windows.isEmpty == false,
              snapshot.windows.isEmpty,
              shouldPreserveWindows(for: snapshot.state)
        else {
            return snapshot
        }

        return UsageSnapshot(
            providerID: snapshot.providerID,
            windows: cached.windows,
            fetchedAt: cached.fetchedAt,
            state: snapshot.state
        )
    }

    private static func shouldPreserveWindows(for state: ProbeState) -> Bool {
        switch state {
        case .stale, .rateLimited, .unavailable:
            return true
        case .ok, .needsAuth:
            return false
        }
    }
}
