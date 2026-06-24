import Testing
import Foundation
@testable import GQuotaKit

@Test func backoffDoublesOnFailureToCap() {
    var b = Backoff(base: 120, cap: 600)
    #expect(b.current == 120)
    b.recordFailure(); #expect(b.current == 240)
    b.recordFailure(); #expect(b.current == 480)
    b.recordFailure(); #expect(b.current == 600)
}

@Test func backoffResetsOnSuccess() {
    var b = Backoff(base: 120, cap: 600)
    b.recordFailure(); b.recordFailure()
    b.recordSuccess()
    #expect(b.current == 120)
}

@Test func gateBlocksWhenAsleep() {
    let gate = PollGate(asleep: true, networkUp: true)
    #expect(gate.shouldPoll == false)
}

@Test func gateBlocksWhenNetworkDown() {
    let gate = PollGate(asleep: false, networkUp: false)
    #expect(gate.shouldPoll == false)
}

@Test func gateAllowsWhenAwakeAndOnline() {
    let gate = PollGate(asleep: false, networkUp: true)
    #expect(gate.shouldPoll == true)
}

@Test func respectsRetryAfterOverBackoff() {
    let b = Backoff(base: 120, cap: 600)
    let retry = Date(timeIntervalSince1970: 1000)
    let next = b.nextFireDate(now: Date(timeIntervalSince1970: 100), retryAfter: retry)
    #expect(next == retry)
}
