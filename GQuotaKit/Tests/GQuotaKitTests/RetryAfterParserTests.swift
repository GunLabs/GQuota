import Testing
import Foundation
@testable import GQuotaKit

private let now = Date(timeIntervalSince1970: 1_700_000_000)

@Test func retryAfter_parsesDeltaSeconds() {
    #expect(RetryAfterParser.parse("120", now: now) == now.addingTimeInterval(120))
}

@Test func retryAfter_parsesHTTPDate() {
    // 用与解析器一致的 formatter 生成 header，规避手写星期几出错；断言能精确解析回原 Date。
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let expected = calendar.date(from: DateComponents(
        year: 2026, month: 10, day: 21, hour: 7, minute: 28, second: 0
    ))!

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
    let header = formatter.string(from: expected)

    #expect(RetryAfterParser.parse(header, now: now) == expected)
}

@Test func retryAfter_negativeDeltaIsRejected() {
    #expect(RetryAfterParser.parse("-5", now: now) == nil)
}

@Test func retryAfter_emptyOrWhitespaceIsNil() {
    #expect(RetryAfterParser.parse("", now: now) == nil)
    #expect(RetryAfterParser.parse("   ", now: now) == nil)
}

@Test func retryAfter_nilIsNil() {
    #expect(RetryAfterParser.parse(nil, now: now) == nil)
}

@Test func retryAfter_malformedIsNil() {
    #expect(RetryAfterParser.parse("not-a-date", now: now) == nil)
}
