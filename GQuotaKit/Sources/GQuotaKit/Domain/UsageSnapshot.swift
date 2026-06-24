import Foundation

public struct UsageSnapshot: Sendable, Equatable {
    public let providerID: ProviderID
    public let windows: [UsageWindow]
    public let fetchedAt: Date
    public let state: ProbeState

    public init(providerID: ProviderID, windows: [UsageWindow],
                fetchedAt: Date, state: ProbeState) {
        self.providerID = providerID
        self.windows = windows
        self.fetchedAt = fetchedAt
        self.state = state
    }
}
