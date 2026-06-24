import AppKit
import GQuotaKit
import SwiftUI

struct MenuBarPanel: View {
    enum ContentState: Equatable {
        case coldStart
        case allAuthMissing
        case providers
    }

    static let allAuthMissingTitle = "未检测到已登录的 CLI/IDE"
    static let allAuthMissingHint = "登录 codex / gemini / claude / gh 或 GitHub Copilot CLI/IDE 后，这里会显示额度"

    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()

            switch Self.contentState(for: model.snapshots) {
            case .coldStart:
                coldStartView
            case .allAuthMissing:
                allAuthMissingView
            case .providers:
                providerRows
            }

            Divider()
            footer
        }
        .padding(12)
        .frame(width: 292)
    }

    static func contentState(for snapshots: [UsageSnapshot]) -> ContentState {
        guard snapshots.isEmpty == false else { return .coldStart }

        if snapshots.allSatisfy({ snapshot in
            if case .needsAuth = snapshot.state {
                return true
            }

            return false
        }) {
            return .allAuthMissing
        }

        return .providers
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("GQuota")
                .font(.system(size: 13, weight: .semibold))

            Spacer()

            Text(updatedText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var coldStartView: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)

            Text("首次检测中…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .accessibilityLabel("首次检测中")
        }
        .padding(.vertical, 8)
    }

    private var allAuthMissingView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.allAuthMissingTitle)
                .font(.system(size: 12, weight: .semibold))

            Text(Self.allAuthMissingHint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var providerRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.snapshots, id: \.providerID) { snapshot in
                ProviderRow(snapshot: snapshot)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                model.refreshNow()
            } label: {
                Label("立即刷新", systemImage: "arrow.clockwise")
            }
            .help("立即刷新")

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("退出", systemImage: "xmark.circle")
            }
            .help("退出")
        }
        .font(.system(size: 11))
        .buttonStyle(.borderless)
    }

    private var updatedText: String {
        guard let lastUpdated = model.lastUpdated else {
            return "尚未更新"
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "\(formatter.localizedString(for: lastUpdated, relativeTo: Date())) 更新"
    }
}
