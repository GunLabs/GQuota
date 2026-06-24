import Foundation

enum RetryAfterParser {
    static func parse(from response: HTTPURLResponse, now: Date) -> Date? {
        parse(headerValue(from: response), now: now)
    }

    static func parse(_ value: String?, now: Date) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.isEmpty == false
        else {
            return nil
        }

        if let seconds = TimeInterval(value), seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return formatter.date(from: value)
    }

    private static func headerValue(from response: HTTPURLResponse) -> String? {
        for (key, value) in response.allHeaderFields {
            guard String(describing: key).lowercased() == "retry-after" else {
                continue
            }

            return String(describing: value)
        }

        return nil
    }
}
