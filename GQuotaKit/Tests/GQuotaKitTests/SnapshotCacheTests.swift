import Testing
import Foundation
@testable import GQuotaKit

private func snap(_ p: ProviderID) -> UsageSnapshot {
    .init(providerID: p, windows: [], fetchedAt: Date(timeIntervalSince1970: 1), state: .ok)
}

@Test func memoryRoundTrip() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let cache = SnapshotCache(directory: dir)
    await cache.put(snap(.openai))
    let got = await cache.get(.openai)
    #expect(got?.providerID == .openai)
}

@Test func diskPersistenceSurvivesNewInstance() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let c1 = SnapshotCache(directory: dir)
    await c1.put(snap(.gemini))
    let c2 = SnapshotCache(directory: dir)
    await c2.loadFromDisk()
    #expect(await c2.get(.gemini)?.providerID == .gemini)
}

@Test func corruptDiskFileIsIgnored() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? Data("not json".utf8).write(to: dir.appendingPathComponent("openai.json"))
    let cache = SnapshotCache(directory: dir)
    await cache.loadFromDisk()
    #expect(await cache.get(.openai) == nil)
}

@Test func providerMismatchDiskFileIsIgnored() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let json = """
    {
      "provider": "openai",
      "windows": [],
      "fetchedAt": 1000
    }
    """
    try Data(json.utf8).write(to: dir.appendingPathComponent("gemini.json"))

    let cache = SnapshotCache(directory: dir)
    await cache.loadFromDisk()

    #expect(await cache.get(.gemini) == nil)
}

@Test func diskPersistencePreservesDisplayWindowsAndMarksStale() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let fetchedAt = Date(timeIntervalSince1970: 1_000)
    let resetsAt = Date(timeIntervalSince1970: 2_000)
    let snapshot = UsageSnapshot(
        providerID: .copilot,
        windows: [
            UsageWindow(
                label: "Used",
                measure: .usedFraction(0.42),
                resetsAt: resetsAt,
                confidence: .estimated,
                detail: "daily cap"
            ),
            UsageWindow(
                label: "Remaining",
                measure: .remainingFraction(0.31),
                resetsAt: nil,
                confidence: .exact,
                detail: nil
            ),
            UsageWindow(
                label: "Credits",
                measure: .creditsBalance(amount: Decimal(string: "12.34")!, currency: "USD"),
                resetsAt: nil,
                confidence: .exact,
                detail: "prepaid balance"
            )
        ],
        fetchedAt: fetchedAt,
        state: .ok
    )

    let c1 = SnapshotCache(directory: dir)
    await c1.put(snapshot)

    let c2 = SnapshotCache(directory: dir)
    await c2.loadFromDisk()
    let restored = await c2.get(.copilot)

    #expect(restored?.providerID == .copilot)
    #expect(restored?.state == .stale(since: fetchedAt))
    #expect(restored?.windows.count == 3)
    #expect(restored?.windows[0].label == "Used")
    #expect(restored?.windows[0].measure == .usedFraction(0.42))
    #expect(restored?.windows[0].resetsAt == resetsAt)
    #expect(restored?.windows[0].confidence == .estimated)
    #expect(restored?.windows[0].detail == "daily cap")
    #expect(restored?.windows[1].measure == .remainingFraction(0.31))
    #expect(restored?.windows[2].label == "Credits")
    #expect(restored?.windows[2].detail == "prepaid balance")

    if case .creditsBalance(let amount, let currency) = restored?.windows[2].measure {
        #expect(amount == Decimal(string: "12.34")!)
        #expect(currency == "USD")
    } else {
        Issue.record("Expected restored credits balance")
    }
}

@Test func diskPersistenceDoesNotWriteCredentialKeywords() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let cache = SnapshotCache(directory: dir)
    let snapshot = UsageSnapshot(
        providerID: .copilot,
        windows: [
            UsageWindow(
                label: "Credits",
                measure: .creditsBalance(amount: Decimal(string: "12.34")!, currency: "USD"),
                resetsAt: nil,
                confidence: .exact,
                detail: "prepaid balance"
            )
        ],
        fetchedAt: Date(timeIntervalSince1970: 1_000),
        state: .ok
    )

    await cache.put(snapshot)

    let json = try String(contentsOf: dir.appendingPathComponent("copilot.json"), encoding: .utf8)
    #expect(!json.contains("token"))
    #expect(!json.contains("access_token"))
    #expect(!json.contains("refresh_token"))
    #expect(!json.contains("Bearer"))
}
