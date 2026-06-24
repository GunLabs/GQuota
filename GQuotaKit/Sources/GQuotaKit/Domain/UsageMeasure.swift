import Foundation

/// 显式表达额度语义，杜绝「剩 31% 显成用 31%」的方向性 bug。
public enum UsageMeasure: Sendable, Equatable {
    case usedFraction(Double)        // 0-1，越高用得越多（OpenAI used_percent）
    case remainingFraction(Double)   // 0-1，越高剩得越多（Gemini remainingFraction）
    case creditsBalance(amount: Decimal, currency: String)  // xAI 预付费余额
    case unknownDenominator(used: Double)                    // 有用量无上限
}
