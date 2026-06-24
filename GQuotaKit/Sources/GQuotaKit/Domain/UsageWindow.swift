import Foundation

public struct UsageWindow: Sendable, Equatable {
    public let label: String
    public let measure: UsageMeasure
    public let resetsAt: Date?
    public let confidence: Confidence
    public let detail: String?

    public init(label: String, measure: UsageMeasure, resetsAt: Date?,
                confidence: Confidence, detail: String?) {
        self.label = label
        self.measure = measure
        self.resetsAt = resetsAt
        self.confidence = confidence
        self.detail = detail
    }
}
