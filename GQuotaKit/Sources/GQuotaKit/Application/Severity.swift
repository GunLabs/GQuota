import Foundation

/// 严重度档位：色盲双通道的「第二通道」来源（图标符号）。
public enum SeverityTier: Sendable, Equatable {
    case ok, warn, danger

    /// 非颜色的形状符号，保证黑白/色盲下可辨（spec 8.4）。
    public var iconSymbol: String {
        switch self {
        case .ok: return "○"
        case .warn: return "◐"
        case .danger: return "●"
        }
    }

    /// 设计 token：严重度色阶（RGB 0-1）。深/浅菜单栏均配描边/背板保证对比度（spec 8.5）。
    public var colorRGB: (r: Double, g: Double, b: Double) {
        switch self {
        case .ok: return (0.18, 0.80, 0.44)      // 绿
        case .warn: return (0.95, 0.61, 0.07)    // 橙
        case .danger: return (0.90, 0.22, 0.21)  // 红
        }
    }
}

public enum Severity {
    /// 阈值常量（无魔法数，spec 4.4）。
    public static let warnThreshold = 0.70
    public static let dangerThreshold = 0.90

    /// 把任意 measure 折算成 0=空闲 ... 1=用满 的「紧张度」。集中一处，杜绝方向性 bug。
    public static func normalized(_ measure: UsageMeasure) -> Double {
        switch measure {
        case .usedFraction(let u): return clamp(u)
        case .remainingFraction(let r): return clamp(1 - r)
        case .unknownDenominator(let used): return clamp(used)
        case .creditsBalance(let amount, _): return amount > 0 ? 0 : 1
        }
    }

    public static func tier(for severity: Double) -> SeverityTier {
        if severity >= dangerThreshold { return .danger }
        if severity >= warnThreshold { return .warn }
        return .ok
    }

    private static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
}
