public protocol UsageProbe: Sendable {
    var providerID: ProviderID { get }
    var displayName: String { get }
    func fetch() async throws -> UsageSnapshot
}
