import Foundation

/// Memory + disk cache. Disk persistence stores display data only and never tokens.
public actor SnapshotCache {
    private var memory: [ProviderID: UsageSnapshot] = [:]
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func put(_ snapshot: UsageSnapshot) {
        memory[snapshot.providerID] = snapshot
        persist(snapshot)
    }

    public func get(_ id: ProviderID) -> UsageSnapshot? {
        memory[id]
    }

    public func all() -> [UsageSnapshot] {
        ProviderID.allCases.compactMap { memory[$0] }
    }

    public func loadFromDisk() {
        for id in ProviderID.allCases {
            let url = directory.appendingPathComponent("\(id.rawValue).json")
            guard let data = try? Data(contentsOf: url),
                  let dto = try? JSONDecoder().decode(CachedSnapshot.self, from: data),
                  ProviderID(rawValue: dto.provider) == id else {
                continue
            }
            memory[id] = dto.toSnapshot(providerID: id)
        }
    }

    private func persist(_ snapshot: UsageSnapshot) {
        let dto = CachedSnapshot(snapshot)
        guard let data = try? JSONEncoder().encode(dto) else { return }
        try? data.write(to: directory.appendingPathComponent("\(snapshot.providerID.rawValue).json"))
    }
}

struct CachedSnapshot: Codable {
    enum Kind: String, Codable {
        case used
        case remaining
        case credits
        case unknown
    }

    struct Win: Codable {
        let label: String
        let kind: Kind
        let value: Double
        let amount: Decimal?
        let currency: String?
        let resetsAt: Date?
        let estimated: Bool
        let detail: String?
    }

    let provider: String
    let windows: [Win]
    let fetchedAt: Date

    init(_ snapshot: UsageSnapshot) {
        provider = snapshot.providerID.rawValue
        fetchedAt = snapshot.fetchedAt
        windows = snapshot.windows.map { window in
            let kind: Kind
            let value: Double
            let amount: Decimal?
            let currency: String?

            switch window.measure {
            case .usedFraction(let fraction):
                kind = .used
                value = fraction
                amount = nil
                currency = nil
            case .remainingFraction(let fraction):
                kind = .remaining
                value = fraction
                amount = nil
                currency = nil
            case .creditsBalance(let balance, let code):
                kind = .credits
                value = 0
                amount = balance
                currency = code
            case .unknownDenominator(let used):
                kind = .unknown
                value = used
                amount = nil
                currency = nil
            }

            return Win(
                label: window.label,
                kind: kind,
                value: value,
                amount: amount,
                currency: currency,
                resetsAt: window.resetsAt,
                estimated: window.confidence == .estimated,
                detail: window.detail
            )
        }
    }

    func toSnapshot(providerID: ProviderID) -> UsageSnapshot {
        let restoredWindows = windows.map { window in
            let measure: UsageMeasure

            switch window.kind {
            case .used:
                measure = .usedFraction(window.value)
            case .remaining:
                measure = .remainingFraction(window.value)
            case .credits:
                measure = .creditsBalance(
                    amount: window.amount ?? 0,
                    currency: window.currency ?? "USD"
                )
            case .unknown:
                measure = .unknownDenominator(used: window.value)
            }

            return UsageWindow(
                label: window.label,
                measure: measure,
                resetsAt: window.resetsAt,
                confidence: window.estimated ? .estimated : .exact,
                detail: window.detail
            )
        }

        return UsageSnapshot(
            providerID: providerID,
            windows: restoredWindows,
            fetchedAt: fetchedAt,
            state: .stale(since: fetchedAt)
        )
    }
}
