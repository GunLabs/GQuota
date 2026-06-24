import Foundation

/// Exponential backoff as a pure value type.
public struct Backoff: Sendable {
    public let base: TimeInterval
    public let cap: TimeInterval
    public private(set) var current: TimeInterval

    public init(base: TimeInterval, cap: TimeInterval) {
        self.base = base
        self.cap = cap
        self.current = base
    }

    public mutating func recordFailure() {
        current = min(cap, current * 2)
    }

    public mutating func recordSuccess() {
        current = base
    }

    public func nextFireDate(now: Date, retryAfter: Date?) -> Date {
        if let retryAfter, retryAfter > now {
            return retryAfter
        }

        return now.addingTimeInterval(current)
    }
}

/// Polling gate for sleep pause and network reachability readiness.
public struct PollGate: Sendable {
    public let asleep: Bool
    public let networkUp: Bool

    public init(asleep: Bool, networkUp: Bool) {
        self.asleep = asleep
        self.networkUp = networkUp
    }

    public var shouldPoll: Bool {
        !asleep && networkUp
    }
}
