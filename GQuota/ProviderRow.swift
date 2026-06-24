import GQuotaKit
import SwiftUI

struct ProviderRow: View {
    let snapshot: UsageSnapshot

    private var presentation: ProviderRowPresentation {
        ProviderRowPresentation(snapshot: snapshot, referenceDate: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(presentation.providerName)
                    .font(.system(size: 13, weight: .semibold))

                Spacer(minLength: 8)

                Text(presentation.statusText)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }

            ProgressView(value: presentation.progressValue)
                .tint(statusColor)
                .controlSize(.small)
                .accessibilityHidden(true)

            if let detailText = presentation.detailText {
                Text(detailText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    private var statusColor: Color {
        guard presentation.usesSeverityColor else { return .secondary }

        let color = presentation.tier.colorRGB
        return Color(red: color.r, green: color.g, blue: color.b)
    }
}

struct ProviderRowPresentation: Equatable {
    let providerName: String
    let statusText: String
    let detailText: String?
    let progressValue: Double
    let tier: SeverityTier
    let usesSeverityColor: Bool
    let accessibilityLabel: String

    init(snapshot: UsageSnapshot, referenceDate: Date) {
        providerName = Self.displayName(for: snapshot.providerID)

        if let window = Self.tightestWindow(in: snapshot), Self.hasUsageValue(snapshot.state) {
            let severity = Severity.normalized(window.measure)
            let tier = Severity.tier(for: severity)
            let percent = Int((severity * 100).rounded())
            let percentText = "\(window.confidence == .estimated ? "~" : "")\(percent)%"
            let statusContext = Self.displayableStatusContext(for: snapshot.state)

            self.statusText = "\(tier.iconSymbol) \(percentText)\(statusContext.map { " · \($0)" } ?? "")"
            self.detailText = Self.detailText(
                for: window,
                state: snapshot.state,
                referenceDate: referenceDate
            )
            self.progressValue = severity
            self.tier = tier
            self.usesSeverityColor = true
            self.accessibilityLabel = Self.accessibilityLabel(
                providerName: providerName,
                window: window,
                percent: percent,
                state: snapshot.state,
                referenceDate: referenceDate
            )
        } else {
            let stateDescription = Self.stateDescription(
                snapshot.state,
                referenceDate: referenceDate
            )

            self.statusText = Self.stateStatusText(snapshot.state)
            self.detailText = Self.stateDetailText(snapshot.state, referenceDate: referenceDate)
            self.progressValue = 0
            self.tier = .ok
            self.usesSeverityColor = false
            self.accessibilityLabel = "\(providerName)，\(stateDescription)"
        }
    }

    private static func tightestWindow(in snapshot: UsageSnapshot) -> UsageWindow? {
        snapshot.windows.max {
            Severity.normalized($0.measure) < Severity.normalized($1.measure)
        }
    }

    private static func hasUsageValue(_ state: ProbeState) -> Bool {
        switch state {
        case .ok, .stale, .rateLimited, .unavailable:
            return true
        case .needsAuth:
            return false
        }
    }

    private static func detailText(
        for window: UsageWindow,
        state: ProbeState,
        referenceDate: Date
    ) -> String? {
        var parts = [window.label]

        if let detail = window.detail, detail.isEmpty == false {
            parts.append(detail)
        }

        if let resetsAt = window.resetsAt {
            parts.append("\(relativeString(for: resetsAt, relativeTo: referenceDate)) 重置")
        }

        if let stateDetail = displayableStateDetail(state, referenceDate: referenceDate) {
            parts.append(stateDetail)
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func accessibilityLabel(
        providerName: String,
        window: UsageWindow,
        percent: Int,
        state: ProbeState,
        referenceDate: Date
    ) -> String {
        var label = "\(providerName)，\(window.label)已用 \(percent)%"

        if window.confidence == .estimated {
            label += "，估算"
        }

        if let resetsAt = window.resetsAt {
            label += "，\(relativeString(for: resetsAt, relativeTo: referenceDate)) 重置"
        }

        if let stateDescription = displayableStateDescription(state, referenceDate: referenceDate) {
            label += "，\(stateDescription)"
        }

        return label
    }

    private static func displayableStatusContext(for state: ProbeState) -> String? {
        switch state {
        case .stale:
            return "陈旧"
        case .rateLimited:
            return "限流"
        case .unavailable:
            return "不可用"
        case .ok, .needsAuth:
            return nil
        }
    }

    private static func displayableStateDetail(
        _ state: ProbeState,
        referenceDate: Date
    ) -> String? {
        switch state {
        case .stale:
            return "数据陈旧 · 运行 CLI 刷新"
        case .rateLimited(let retryAfter):
            guard let retryAfter else { return "限流中" }
            return "限流中 · \(relativeString(for: retryAfter, relativeTo: referenceDate)) 可重试"
        case .unavailable(let reason):
            return "不可用 · \(reason)"
        case .ok, .needsAuth:
            return nil
        }
    }

    private static func displayableStateDescription(
        _ state: ProbeState,
        referenceDate: Date
    ) -> String? {
        switch state {
        case .stale:
            return "数据陈旧"
        case .rateLimited(let retryAfter):
            guard let retryAfter else { return "限流中" }
            return "限流中，\(relativeString(for: retryAfter, relativeTo: referenceDate)) 可重试"
        case .unavailable(let reason):
            return "不可用，\(reason)"
        case .ok, .needsAuth:
            return nil
        }
    }

    private static func stateStatusText(_ state: ProbeState) -> String {
        switch state {
        case .needsAuth:
            return "未检测到登录"
        case .rateLimited:
            return "限流中"
        case .unavailable:
            return "不可用"
        case .stale:
            return "数据陈旧"
        case .ok:
            return "—"
        }
    }

    private static func stateDetailText(_ state: ProbeState, referenceDate: Date) -> String? {
        switch state {
        case .rateLimited(let retryAfter):
            guard let retryAfter else { return nil }
            return "\(relativeString(for: retryAfter, relativeTo: referenceDate)) 可重试"
        case .unavailable(let reason):
            return reason
        case .stale:
            return "运行 CLI 刷新"
        case .ok, .needsAuth:
            return nil
        }
    }

    private static func stateDescription(_ state: ProbeState, referenceDate: Date) -> String {
        switch state {
        case .needsAuth:
            return "未检测到登录"
        case .rateLimited(let retryAfter):
            guard let retryAfter else { return "限流中" }
            return "限流中，\(relativeString(for: retryAfter, relativeTo: referenceDate)) 可重试"
        case .unavailable(let reason):
            return "不可用，\(reason)"
        case .stale:
            return "数据陈旧"
        case .ok:
            return "正常"
        }
    }

    private static func relativeString(for date: Date, relativeTo referenceDate: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: referenceDate)
    }

    private static func displayName(for providerID: ProviderID) -> String {
        switch providerID {
        case .openai:
            return "OpenAI"
        case .gemini:
            return "Gemini"
        case .claude:
            return "Claude"
        case .copilot:
            return "Copilot"
        }
    }
}
