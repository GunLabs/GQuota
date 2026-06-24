# GQuota MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 一个仅 macOS 的菜单栏 App，常驻显示 OpenAI(Codex) 与 Gemini 订阅配额的「多柱微型条」，点开是逐家进度条面板，凭证只读、不主动刷新、失败优雅降级。

**Architecture:** 可测核心做成 SwiftPM 包 `GQuotaKit`（Domain 模型 + Application 调度/缓存 + Infrastructure 各 provider Probe），用 `swift test` 全量单测；UI（MenuBarExtra + 彩色 NSImage 渲染）是薄薄的 Xcode app target，依赖 `GQuotaKit`。所有 provider 统一到 `UsageProbe` 协议背后，加一家=写一个 Probe。MVP 不主动刷新 token（过期标 `.stale`），凭证只读不写回。

**Tech Stack:** Swift 6（结构化并发）、SwiftPM、Swift Testing（`import Testing`）、SwiftUI `MenuBarExtra` + AppKit `NSImage`、`URLSession`、`Network.NWPathMonitor`、`AppKit.NSWorkspace`。

**Source spec:** `docs/superpowers/specs/2026-06-11-gquota-design.md`（已过 plan-eng-review + plan-design-review）。

---

## 文件结构

```
ai-analytics/
├── GQuotaKit/                          # SwiftPM 包（可测核心）
│   ├── Package.swift
│   ├── Sources/GQuotaKit/
│   │   ├── Domain/
│   │   │   ├── ProviderID.swift
│   │   │   ├── UsageMeasure.swift
│   │   │   ├── Confidence.swift
│   │   │   ├── ProbeState.swift
│   │   │   ├── UsageWindow.swift
│   │   │   ├── UsageSnapshot.swift
│   │   │   └── UsageProbe.swift
│   │   ├── Application/
│   │   │   ├── Severity.swift          # normalizedSeverity + tier + 设计 token
│   │   │   ├── Clock.swift             # 可注入时钟
│   │   │   ├── SnapshotCache.swift
│   │   │   ├── PollScheduler.swift
│   │   │   └── UsageCoordinator.swift
│   │   └── Infrastructure/
│   │       ├── Shared/
│   │       │   ├── HTTPClient.swift
│   │       │   ├── JWTDecoder.swift
│   │       │   ├── CredentialReader.swift
│   │       │   └── AuthenticatedRequest.swift
│   │       ├── OpenAI/
│   │       │   ├── CodexAuth.swift
│   │       │   ├── OpenAIUsageDTO.swift
│   │       │   └── OpenAIProbe.swift
│   │       └── Gemini/
│   │           ├── GeminiOAuth.swift
│   │           ├── GeminiQuotaDTO.swift
│   │           └── GeminiProbe.swift
│   └── Tests/GQuotaKitTests/
│       ├── Fixtures/                   # Phase 0 抓取的真实 JSON
│       ├── DomainTests.swift
│       ├── SeverityTests.swift
│       ├── JWTDecoderTests.swift
│       ├── CredentialReaderTests.swift
│       ├── HTTPClientTests.swift
│       ├── AuthenticatedRequestTests.swift
│       ├── OpenAIProbeTests.swift
│       ├── GeminiProbeTests.swift
│       ├── SnapshotCacheTests.swift
│       ├── PollSchedulerTests.swift
│       └── UsageCoordinatorTests.swift
├── GQuota/                             # Xcode app target（UI，薄）
│   ├── GQuotaApp.swift
│   ├── AppModel.swift
│   ├── MenuBarIconRenderer.swift
│   ├── MenuBarLabel.swift
│   ├── MenuBarPanel.swift
│   ├── ProviderRow.swift
│   ├── Info.plist                      # LSUIElement = true
│   └── GQuota.entitlements             # 关闭沙箱
└── docs/superpowers/...
```

**注**：`GQuota/` 这个 Xcode 工程在 Task 13 用 Xcode GUI 创建（命令行无法可靠生成 .xcodeproj），其余任务全部在 `GQuotaKit/` 包内用 `swift test` 驱动。

---

## Task 0: Phase 0 Spike（探索，非 TDD）

> 目的：在写任何骨架前，用**你自己的真实凭证**确认两个非公开接口能跑通、抓真实 JSON 形状落成测试 fixture、并验证 refresh token 是否轮转（决定后续能否恢复主动刷新）。这是 spec 第 10 节的前置去风险步骤。

**Files:**
- Create: `GQuotaKit/Tests/GQuotaKitTests/Fixtures/openai-wham-usage.json`
- Create: `GQuotaKit/Tests/GQuotaKitTests/Fixtures/gemini-loadCodeAssist.json`
- Create: `GQuotaKit/Tests/GQuotaKitTests/Fixtures/gemini-retrieveUserQuota.json`
- Create: `docs/superpowers/plans/phase0-spike-findings.md`

- [ ] **Step 1: 抓 OpenAI wham/usage 真实响应**

读取本机 access_token 并打接口（替换 `$TOKEN`/`$ACCT` 为 `~/.codex/auth.json` 里的 `tokens.access_token` 与 `tokens.account_id`）：

```bash
TOKEN=$(python3 -c "import json;print(json.load(open('$HOME/.codex/auth.json'))['tokens']['access_token'])")
ACCT=$(python3 -c "import json;print(json.load(open('$HOME/.codex/auth.json'))['tokens']['account_id'])")
curl -s https://chatgpt.com/backend-api/wham/usage \
  -H "Authorization: Bearer $TOKEN" \
  -H "chatgpt-account-id: $ACCT" \
  -H "User-Agent: GQuota/0.1" | tee GQuotaKit/Tests/GQuotaKitTests/Fixtures/openai-wham-usage.json | python3 -m json.tool
```

Expected: HTTP 200，JSON 含 5h/周窗 used_percent + reset_at + 每模型 + credits。记录真实字段名（实现时以此为准）。若 401 → token 过期，先 `codex` 跑一次刷新再重试。

- [ ] **Step 2: 抓 Gemini loadCodeAssist + retrieveUserQuota**

```bash
GTOKEN=$(python3 -c "import json;print(json.load(open('$HOME/.gemini/oauth_creds.json'))['access_token'])")
curl -s -X POST "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist" \
  -H "Authorization: Bearer $GTOKEN" -H "Content-Type: application/json" \
  -d '{"metadata":{"ideType":"GEMINI_CLI","pluginType":"GEMINI"}}' \
  | tee GQuotaKit/Tests/GQuotaKitTests/Fixtures/gemini-loadCodeAssist.json | python3 -m json.tool
# 从上一步输出取 cloudaicompanionProject 填入下面 PROJECT
PROJECT="<从 loadCodeAssist 响应里复制 cloudaicompanionProject>"
curl -s -X POST "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota" \
  -H "Authorization: Bearer $GTOKEN" -H "Content-Type: application/json" \
  -d "{\"project\":\"$PROJECT\"}" \
  | tee GQuotaKit/Tests/GQuotaKitTests/Fixtures/gemini-retrieveUserQuota.json | python3 -m json.tool
```

Expected: loadCodeAssist 返回 `cloudaicompanionProject` + `currentTier`；retrieveUserQuota 返回 `buckets[]`（每个含 `remainingFraction`/`resetTime`/`modelId`）。记录字段名。

- [ ] **Step 3: 验证 refresh token 是否轮转**

```bash
# 记录当前 refresh token
BEFORE=$(python3 -c "import json;print(json.load(open('$HOME/.codex/auth.json'))['tokens']['refresh_token'])")
# 用 codex 触发一次自身刷新（正常使用一次），然后比对
echo "运行一次 codex 命令使其刷新 token，然后回来按回车"; read
AFTER=$(python3 -c "import json;print(json.load(open('$HOME/.codex/auth.json'))['tokens']['refresh_token'])")
[ "$BEFORE" = "$AFTER" ] && echo "OpenAI: refresh token 不轮转(可安全恢复主动刷新)" || echo "OpenAI: refresh token 轮转(MVP 必须不刷新)"
```

对 Gemini 重复同样比对 `~/.gemini/oauth_creds.json` 的 `refresh_token`。

- [ ] **Step 4: 记录结论**

把三项结论（接口字段、是否拿到 project、refresh 是否轮转）写入 `docs/superpowers/plans/phase0-spike-findings.md`。**脱敏**：fixture 里把真实 token/email/project id 替换成假值（如 `proj-FAKE123`、`user@example.com`），只保留结构与数值。

- [ ] **Step 5: Commit**

```bash
git add GQuotaKit/Tests/GQuotaKitTests/Fixtures docs/superpowers/plans/phase0-spike-findings.md
git commit -m "chore: phase 0 spike — capture OpenAI/Gemini usage fixtures + refresh rotation finding"
```

---

## Task 1: SwiftPM 包脚手架

**Files:**
- Create: `GQuotaKit/Package.swift`
- Create: `GQuotaKit/Sources/GQuotaKit/Placeholder.swift`
- Create: `GQuotaKit/Tests/GQuotaKitTests/SmokeTests.swift`

- [ ] **Step 1: 写 Package.swift**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GQuotaKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "GQuotaKit", targets: ["GQuotaKit"]),
    ],
    targets: [
        .target(name: "GQuotaKit"),
        .testTarget(
            name: "GQuotaKitTests",
            dependencies: ["GQuotaKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
```

- [ ] **Step 2: 占位源文件（让包能编译）**

`GQuotaKit/Sources/GQuotaKit/Placeholder.swift`:

```swift
// Placeholder so the target compiles before real sources land. Remove in Task 2.
enum GQuotaKitVersion { static let value = "0.1.0" }
```

- [ ] **Step 3: 冒烟测试**

`GQuotaKit/Tests/GQuotaKitTests/SmokeTests.swift`:

```swift
import Testing
@testable import GQuotaKit

@Test func packageCompilesAndVersionPresent() {
    #expect(GQuotaKitVersion.value == "0.1.0")
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cd GQuotaKit && swift test`
Expected: PASS（1 test）。若 Fixtures 资源报错，确认 Task 0 已创建 `Tests/GQuotaKitTests/Fixtures/` 目录（至少一个文件）。

- [ ] **Step 5: Commit**

```bash
git add GQuotaKit/Package.swift GQuotaKit/Sources GQuotaKit/Tests/GQuotaKitTests/SmokeTests.swift
git commit -m "chore: scaffold GQuotaKit SwiftPM package"
```

---

## Task 2: Domain 模型

**Files:**
- Create: `GQuotaKit/Sources/GQuotaKit/Domain/ProviderID.swift`
- Create: `GQuotaKit/Sources/GQuotaKit/Domain/UsageMeasure.swift`
- Create: `GQuotaKit/Sources/GQuotaKit/Domain/Confidence.swift`
- Create: `GQuotaKit/Sources/GQuotaKit/Domain/ProbeState.swift`
- Create: `GQuotaKit/Sources/GQuotaKit/Domain/UsageWindow.swift`
- Create: `GQuotaKit/Sources/GQuotaKit/Domain/UsageSnapshot.swift`
- Create: `GQuotaKit/Sources/GQuotaKit/Domain/UsageProbe.swift`
- Delete: `GQuotaKit/Sources/GQuotaKit/Placeholder.swift`
- Test: `GQuotaKit/Tests/GQuotaKitTests/DomainTests.swift`

- [ ] **Step 1: 写失败测试**

`GQuotaKit/Tests/GQuotaKitTests/DomainTests.swift`:

```swift
import Testing
import Foundation
@testable import GQuotaKit

@Test func usageMeasureDistinguishesUsedVsRemaining() {
    let used = UsageMeasure.usedFraction(0.72)
    let remaining = UsageMeasure.remainingFraction(0.31)
    // 语义不同：used 0.72 = 用了 72%；remaining 0.31 = 剩 31%（即用了 69%）
    if case .usedFraction(let u) = used { #expect(u == 0.72) } else { Issue.record("wrong case") }
    if case .remainingFraction(let r) = remaining { #expect(r == 0.31) } else { Issue.record("wrong case") }
}

@Test func snapshotHoldsWindowsAndState() {
    let w = UsageWindow(label: "5 小时窗口", measure: .usedFraction(0.5),
                        resetsAt: nil, confidence: .exact, detail: "Plus")
    let snap = UsageSnapshot(providerID: .openai, windows: [w],
                             fetchedAt: Date(timeIntervalSince1970: 0), state: .ok)
    #expect(snap.providerID == .openai)
    #expect(snap.windows.count == 1)
    #expect(snap.state == .ok)
}

@Test func providerIDCoversFourProviders() {
    #expect(ProviderID.allCases.count == 4)
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd GQuotaKit && swift test --filter DomainTests`
Expected: FAIL，编译错误「cannot find 'UsageMeasure' in scope」等。

- [ ] **Step 3: 写实现**

`Domain/ProviderID.swift`:

```swift
public enum ProviderID: String, CaseIterable, Sendable, Codable {
    case openai, gemini, claude, xai
}
```

`Domain/UsageMeasure.swift`:

```swift
import Foundation

/// 显式表达额度语义，杜绝「剩 31% 显成用 31%」的方向性 bug。
public enum UsageMeasure: Sendable, Equatable {
    case usedFraction(Double)        // 0–1，越高用得越多（OpenAI used_percent）
    case remainingFraction(Double)   // 0–1，越高剩得越多（Gemini remainingFraction）
    case creditsBalance(amount: Decimal, currency: String)  // xAI 预付费余额
    case unknownDenominator(used: Double)                    // 有用量无上限
}
```

`Domain/Confidence.swift`:

```swift
public enum Confidence: Sendable, Equatable { case exact, estimated }
```

`Domain/ProbeState.swift`:

```swift
import Foundation

public enum ProbeState: Sendable, Equatable {
    case ok
    case stale(since: Date)              // 有缓存但已过期/接口暂不可用（含 token 过期未刷新）
    case needsAuth                       // 凭证缺失
    case rateLimited(retryAfter: Date?)
    case unavailable(reason: String)
}
```

`Domain/UsageWindow.swift`:

```swift
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
```

`Domain/UsageSnapshot.swift`:

```swift
import Foundation

public struct UsageSnapshot: Sendable, Equatable {
    public let providerID: ProviderID
    public let windows: [UsageWindow]
    public let fetchedAt: Date
    public let state: ProbeState

    public init(providerID: ProviderID, windows: [UsageWindow],
                fetchedAt: Date, state: ProbeState) {
        self.providerID = providerID
        self.windows = windows
        self.fetchedAt = fetchedAt
        self.state = state
    }
}
```

`Domain/UsageProbe.swift`:

```swift
public protocol UsageProbe: Sendable {
    var providerID: ProviderID { get }
    var displayName: String { get }
    func fetch() async throws -> UsageSnapshot
}
```

然后删除占位文件：

```bash
rm GQuotaKit/Sources/GQuotaKit/Placeholder.swift
```

并把 `SmokeTests.swift` 里对 `GQuotaKitVersion` 的引用改为对 `ProviderID` 的存在性检查，避免编译失败：

```swift
import Testing
@testable import GQuotaKit

@Test func packageCompiles() { #expect(ProviderID.allCases.isEmpty == false) }
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cd GQuotaKit && swift test`
Expected: PASS（DomainTests 3 个 + smoke）。

- [ ] **Step 5: Commit**

```bash
git add GQuotaKit/Sources/GQuotaKit/Domain GQuotaKit/Tests/GQuotaKitTests/DomainTests.swift GQuotaKit/Tests/GQuotaKitTests/SmokeTests.swift
git commit -m "feat(domain): UsageProbe protocol + semantic UsageMeasure model"
```

---

## Task 3: Severity（紧张度折算 + 档位 + 设计 token）

**Files:**
- Create: `GQuotaKit/Sources/GQuotaKit/Application/Severity.swift`
- Test: `GQuotaKit/Tests/GQuotaKitTests/SeverityTests.swift`

- [ ] **Step 1: 写失败测试**

`GQuotaKit/Tests/GQuotaKitTests/SeverityTests.swift`:

```swift
import Testing
@testable import GQuotaKit

@Test func usedFractionMapsDirectly() {
    #expect(Severity.normalized(.usedFraction(0.9)) == 0.9)
}

@Test func remainingFractionInverts() {
    // 剩 0.31 → 用了 0.69
    #expect(abs(Severity.normalized(.remainingFraction(0.31)) - 0.69) < 1e-9)
}

@Test func unknownDenominatorPassesUsed() {
    #expect(Severity.normalized(.unknownDenominator(used: 0.4)) == 0.4)
}

@Test func creditsBalanceIsLowSeverityWhenPositive() {
    // 余额型无「百分比」，余额>0 视为低紧张度(0)；耗尽视为高(1)
    #expect(Severity.normalized(.creditsBalance(amount: 10, currency: "USD")) == 0)
    #expect(Severity.normalized(.creditsBalance(amount: 0, currency: "USD")) == 1)
}

@Test func tierThresholds() {
    #expect(Severity.tier(for: 0.50) == .ok)
    #expect(Severity.tier(for: 0.75) == .warn)
    #expect(Severity.tier(for: 0.92) == .danger)
}

@Test func tierHasDistinctIconPerLevel() {
    // 色盲双通道：每档有不同图标符号
    let icons = Set([SeverityTier.ok, .warn, .danger].map(\.iconSymbol))
    #expect(icons.count == 3)
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd GQuotaKit && swift test --filter SeverityTests`
Expected: FAIL，「cannot find 'Severity'」。

- [ ] **Step 3: 写实现**

`Application/Severity.swift`:

```swift
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

    /// 设计 token：严重度色阶（RGB 0–1）。深/浅菜单栏均配描边/背板保证对比度（spec 8.5）。
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

    /// 把任意 measure 折算成 0=空闲 … 1=用满 的「紧张度」。集中一处，杜绝方向性 bug。
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
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cd GQuotaKit && swift test --filter SeverityTests`
Expected: PASS（6 个）。

- [ ] **Step 5: Commit**

```bash
git add GQuotaKit/Sources/GQuotaKit/Application/Severity.swift GQuotaKit/Tests/GQuotaKitTests/SeverityTests.swift
git commit -m "feat(app): Severity normalization + tier + colorblind-safe icon/color tokens"
```

---

## Task 4: JWTDecoder

**Files:**
- Create: `GQuotaKit/Sources/GQuotaKit/Infrastructure/Shared/JWTDecoder.swift`
- Test: `GQuotaKit/Tests/GQuotaKitTests/JWTDecoderTests.swift`

- [ ] **Step 1: 写失败测试**

`GQuotaKit/Tests/GQuotaKitTests/JWTDecoderTests.swift`:

```swift
import Testing
import Foundation
@testable import GQuotaKit

@Test func decodesPayloadClaim() throws {
    // header.payload.signature；payload = {"chatgpt_plan_type":"plus","x":1}
    let payloadJSON = #"{"chatgpt_plan_type":"plus","x":1}"#
    let b64 = Data(payloadJSON.utf8).base64URLEncodedString()
    let jwt = "aaa.\(b64).bbb"
    let claims = try JWTDecoder.decodePayload(jwt)
    #expect(claims["chatgpt_plan_type"] as? String == "plus")
}

@Test func malformedJWTThrows() {
    #expect(throws: (any Error).self) { try JWTDecoder.decodePayload("not-a-jwt") }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd GQuotaKit && swift test --filter JWTDecoderTests`
Expected: FAIL，「cannot find 'JWTDecoder'」「cannot find 'base64URLEncodedString'」。

- [ ] **Step 3: 写实现**

`Infrastructure/Shared/JWTDecoder.swift`:

```swift
import Foundation

public enum JWTError: Error, Equatable { case malformed }

public enum JWTDecoder {
    /// 解 JWT 第二段（payload），不验签——仅用于本地读自己 token 的 claim。
    public static func decodePayload(_ jwt: String) throws -> [String: Any] {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2, let data = Data(base64URLEncoded: String(parts[1])) else {
            throw JWTError.malformed
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JWTError.malformed
        }
        return obj
    }
}

extension Data {
    init?(base64URLEncoded s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+")
                 .replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b.append("=") }
        guard let d = Data(base64Encoded: b) else { return nil }
        self = d
    }
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cd GQuotaKit && swift test --filter JWTDecoderTests`
Expected: PASS（2 个）。

- [ ] **Step 5: Commit**

```bash
git add GQuotaKit/Sources/GQuotaKit/Infrastructure/Shared/JWTDecoder.swift GQuotaKit/Tests/GQuotaKitTests/JWTDecoderTests.swift
git commit -m "feat(infra): base64url JWT payload decoder"
```

---

## Task 5: CredentialReader

**Files:**
- Create: `GQuotaKit/Sources/GQuotaKit/Infrastructure/Shared/CredentialReader.swift`
- Test: `GQuotaKit/Tests/GQuotaKitTests/CredentialReaderTests.swift`

- [ ] **Step 1: 写失败测试**

`GQuotaKit/Tests/GQuotaKitTests/CredentialReaderTests.swift`:

```swift
import Testing
import Foundation
@testable import GQuotaKit

@Test func readsExistingJSONFile() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("auth.json")
    try #"{"k":"v"}"#.data(using: .utf8)!.write(to: file)

    let reader = FileCredentialReader(baseDirectory: dir)
    let data = try reader.read(relativePath: "auth.json")
    let obj = try JSONSerialization.jsonObject(with: data) as? [String: String]
    #expect(obj?["k"] == "v")
}

@Test func missingFileThrowsNotFound() {
    let reader = FileCredentialReader(baseDirectory: FileManager.default.temporaryDirectory)
    #expect(throws: CredentialError.notFound) {
        try reader.read(relativePath: "does-not-exist-\(UUID()).json")
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd GQuotaKit && swift test --filter CredentialReaderTests`
Expected: FAIL，「cannot find 'FileCredentialReader'」。

- [ ] **Step 3: 写实现**

`Infrastructure/Shared/CredentialReader.swift`:

```swift
import Foundation

public enum CredentialError: Error, Equatable { case notFound, unreadable }

public protocol CredentialReader: Sendable {
    /// 相对 baseDirectory 读文件原始字节。绝不写回。
    func read(relativePath: String) throws -> Data
}

public struct FileCredentialReader: CredentialReader {
    private let baseDirectory: URL
    /// 默认 = 用户 home（~）。测试时注入临时目录。
    public init(baseDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.baseDirectory = baseDirectory
    }
    public func read(relativePath: String) throws -> Data {
        let url = baseDirectory.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CredentialError.notFound
        }
        do { return try Data(contentsOf: url) }
        catch { throw CredentialError.unreadable }
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cd GQuotaKit && swift test --filter CredentialReaderTests`
Expected: PASS（2 个）。

- [ ] **Step 5: Commit**

```bash
git add GQuotaKit/Sources/GQuotaKit/Infrastructure/Shared/CredentialReader.swift GQuotaKit/Tests/GQuotaKitTests/CredentialReaderTests.swift
git commit -m "feat(infra): read-only file credential reader with injectable base dir"
```

---

## Task 6: HTTPClient（含 URLProtocol mock）

**Files:**
- Create: `GQuotaKit/Sources/GQuotaKit/Infrastructure/Shared/HTTPClient.swift`
- Test: `GQuotaKit/Tests/GQuotaKitTests/HTTPClientTests.swift`

- [ ] **Step 1: 写失败测试**

`GQuotaKit/Tests/GQuotaKitTests/HTTPClientTests.swift`:

```swift
import Testing
import Foundation
@testable import GQuotaKit

@Test func mockClientReturnsStubbedResponse() async throws {
    let client = MockHTTPClient(responses: [
        .init(status: 200, body: Data(#"{"ok":true}"#.utf8))
    ])
    let (data, resp) = try await client.send(URLRequest(url: URL(string: "https://x.test/u")!))
    #expect(resp.statusCode == 200)
    #expect(String(data: data, encoding: .utf8) == #"{"ok":true}"#)
}

@Test func mockClientReplaysSequence() async throws {
    let client = MockHTTPClient(responses: [
        .init(status: 401, body: Data()),
        .init(status: 200, body: Data("ok".utf8)),
    ])
    let r1 = try await client.send(URLRequest(url: URL(string: "https://x.test")!))
    let r2 = try await client.send(URLRequest(url: URL(string: "https://x.test")!))
    #expect(r1.1.statusCode == 401)
    #expect(r2.1.statusCode == 200)
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd GQuotaKit && swift test --filter HTTPClientTests`
Expected: FAIL，「cannot find 'MockHTTPClient'」。

- [ ] **Step 3: 写实现**

`Infrastructure/Shared/HTTPClient.swift`:

```swift
import Foundation

public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await session.data(for: request)
        guard let http = resp as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

/// 测试替身：按序回放预设响应（线程安全用 actor 内部计数）。
public final class MockHTTPClient: HTTPClient, @unchecked Sendable {
    public struct Stub: Sendable { public let status: Int; public let body: Data
        public init(status: Int, body: Data) { self.status = status; self.body = body } }
    private let responses: [Stub]
    private let lock = NSLock()
    private var index = 0
    public init(responses: [Stub]) { self.responses = responses }
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock(); defer { lock.unlock() }
        let stub = responses[min(index, responses.count - 1)]
        index += 1
        let http = HTTPURLResponse(url: request.url!, statusCode: stub.status,
                                   httpVersion: nil, headerFields: nil)!
        return (stub.body, http)
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cd GQuotaKit && swift test --filter HTTPClientTests`
Expected: PASS（2 个）。

- [ ] **Step 5: Commit**

```bash
git add GQuotaKit/Sources/GQuotaKit/Infrastructure/Shared/HTTPClient.swift GQuotaKit/Tests/GQuotaKitTests/HTTPClientTests.swift
git commit -m "feat(infra): HTTPClient protocol + URLSession impl + sequence mock"
```

---

## Task 7: AuthenticatedRequest（共享认证编排）

> spec 4.4 + C1 + OV2：读凭证 → 查过期 → 请求 → 映射 ProbeState。**MVP 过期→`.stale`，不刷新**。每个 Probe 只提供 endpoint 构造与 parser。

**Files:**
- Create: `GQuotaKit/Sources/GQuotaKit/Infrastructure/Shared/AuthenticatedRequest.swift`
- Test: `GQuotaKit/Tests/GQuotaKitTests/AuthenticatedRequestTests.swift`

- [ ] **Step 1: 写失败测试**

`GQuotaKit/Tests/GQuotaKitTests/AuthenticatedRequestTests.swift`:

```swift
import Testing
import Foundation
@testable import GQuotaKit

private func win(_ s: Double) -> [UsageWindow] {
    [UsageWindow(label: "w", measure: .usedFraction(s), resetsAt: nil, confidence: .exact, detail: nil)]
}

@Test func missingCredsYieldsNeedsAuth() async {
    let outcome = await AuthenticatedRequest.run(
        provider: .openai,
        accessToken: nil,                       // 无凭证
        isExpired: false,
        request: { _ in URLRequest(url: URL(string: "https://x.test")!) },
        client: MockHTTPClient(responses: [.init(status: 200, body: Data())]),
        parse: { _ in win(0.5) }
    )
    #expect(outcome == .needsAuth)
}

@Test func expiredTokenYieldsStaleNotRefresh() async {
    let outcome = await AuthenticatedRequest.run(
        provider: .openai, accessToken: "t", isExpired: true,
        request: { _ in URLRequest(url: URL(string: "https://x.test")!) },
        client: MockHTTPClient(responses: [.init(status: 200, body: Data())]),
        parse: { _ in win(0.5) }
    )
    if case .stale = outcome {} else { Issue.record("expected .stale, got \(outcome)") }
}

@Test func ok200ParsesWindows() async {
    let outcome = await AuthenticatedRequest.run(
        provider: .openai, accessToken: "t", isExpired: false,
        request: { _ in URLRequest(url: URL(string: "https://x.test")!) },
        client: MockHTTPClient(responses: [.init(status: 200, body: Data("{}".utf8))]),
        parse: { _ in win(0.72) }
    )
    #expect(outcome == .ok(win(0.72)))
}

@Test func http401YieldsNeedsAuth() async {
    let outcome = await AuthenticatedRequest.run(
        provider: .openai, accessToken: "t", isExpired: false,
        request: { _ in URLRequest(url: URL(string: "https://x.test")!) },
        client: MockHTTPClient(responses: [.init(status: 401, body: Data())]),
        parse: { _ in win(0.5) }
    )
    #expect(outcome == .needsAuth)
}

@Test func http429YieldsRateLimited() async {
    let outcome = await AuthenticatedRequest.run(
        provider: .openai, accessToken: "t", isExpired: false,
        request: { _ in URLRequest(url: URL(string: "https://x.test")!) },
        client: MockHTTPClient(responses: [.init(status: 429, body: Data())]),
        parse: { _ in win(0.5) }
    )
    if case .rateLimited = outcome {} else { Issue.record("expected .rateLimited") }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd GQuotaKit && swift test --filter AuthenticatedRequestTests`
Expected: FAIL，「cannot find 'AuthenticatedRequest'」。

- [ ] **Step 3: 写实现**

`Infrastructure/Shared/AuthenticatedRequest.swift`:

```swift
import Foundation

/// 编排结果。`.ok` 携带解析出的窗口；其余对应 ProbeState 的非 ok 分支。
public enum AuthOutcome: Sendable, Equatable {
    case ok([UsageWindow])
    case stale
    case needsAuth
    case rateLimited(retryAfter: Date?)
    case unavailable(reason: String)
}

public enum AuthenticatedRequest {
    /// 共享认证请求编排。MVP：过期 token → .stale（不刷新，spec 7/OV2）。
    public static func run(
        provider: ProviderID,
        accessToken: String?,
        isExpired: Bool,
        request: (String) -> URLRequest,
        client: HTTPClient,
        parse: (Data) throws -> [UsageWindow]
    ) async -> AuthOutcome {
        guard let token = accessToken else { return .needsAuth }
        if isExpired { return .stale }            // MVP 不主动刷新
        do {
            let (data, http) = try await client.send(request(token))
            switch http.statusCode {
            case 200..<300:
                let windows = try parse(data)
                return .ok(windows)
            case 401, 403:
                return .needsAuth
            case 429:
                return .rateLimited(retryAfter: nil)
            default:
                return .unavailable(reason: "HTTP \(http.statusCode)")
            }
        } catch {
            // 网络/超时/离线：上层保留缓存并标 stale
            return .stale
        }
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cd GQuotaKit && swift test --filter AuthenticatedRequestTests`
Expected: PASS（5 个）。

- [ ] **Step 5: Commit**

```bash
git add GQuotaKit/Sources/GQuotaKit/Infrastructure/Shared/AuthenticatedRequest.swift GQuotaKit/Tests/GQuotaKitTests/AuthenticatedRequestTests.swift
git commit -m "feat(infra): shared AuthenticatedRequest orchestration (MVP no-refresh)"
```

---

## Task 8: OpenAIProbe

**Files:**
- Create: `GQuotaKit/Sources/GQuotaKit/Infrastructure/OpenAI/CodexAuth.swift`
- Create: `GQuotaKit/Sources/GQuotaKit/Infrastructure/OpenAI/OpenAIUsageDTO.swift`
- Create: `GQuotaKit/Sources/GQuotaKit/Infrastructure/OpenAI/OpenAIProbe.swift`
- Test: `GQuotaKit/Tests/GQuotaKitTests/OpenAIProbeTests.swift`

> 注：DTO 字段名以 Task 0 抓到的真实 `openai-wham-usage.json` 为准。下方按 spec 描述（5h/周 used_percent + reset_at）写，若 Phase 0 字段不同，**以 fixture 为准同步改 DTO 与测试**。

- [ ] **Step 1: 写失败测试**

`GQuotaKit/Tests/GQuotaKitTests/OpenAIProbeTests.swift`:

```swift
import Testing
import Foundation
@testable import GQuotaKit

@Test func parsesFiveHourAndWeeklyWindows() throws {
    let json = """
    {"five_hour":{"used_percent":72,"reset_at":1781190000},
     "weekly":{"used_percent":34,"reset_at":1781600000}}
    """
    let windows = try OpenAIProbe.parse(Data(json.utf8))
    #expect(windows.count == 2)
    if case .usedFraction(let f) = windows[0].measure { #expect(abs(f - 0.72) < 1e-9) }
    else { Issue.record("expected usedFraction") }
    #expect(windows[0].confidence == .exact)
}

@Test func missingWeeklyStillParsesFiveHour() throws {
    let json = #"{"five_hour":{"used_percent":10,"reset_at":0}}"#
    let windows = try OpenAIProbe.parse(Data(json.utf8))
    #expect(windows.count == 1)
}

@Test func planTypeReadFromJWT() throws {
    let payload = Data(#"{"chatgpt_plan_type":"pro"}"#.utf8).base64URLEncodedString()
    let plan = OpenAIProbe.planType(fromAccessToken: "a.\(payload).b")
    #expect(plan == "pro")
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd GQuotaKit && swift test --filter OpenAIProbeTests`
Expected: FAIL，「cannot find 'OpenAIProbe'」。

- [ ] **Step 3: 写实现**

`Infrastructure/OpenAI/CodexAuth.swift`:

```swift
import Foundation

/// `~/.codex/auth.json` 的子集。
struct CodexAuth: Decodable {
    struct Tokens: Decodable {
        let access_token: String?
        let account_id: String?
        let refresh_token: String?
    }
    let tokens: Tokens?
}
```

`Infrastructure/OpenAI/OpenAIUsageDTO.swift`:

```swift
import Foundation

/// wham/usage 响应子集。字段名以 Phase 0 fixture 为准。
struct OpenAIUsageDTO: Decodable {
    struct Window: Decodable { let used_percent: Double; let reset_at: Double? }
    let five_hour: Window?
    let weekly: Window?
}
```

`Infrastructure/OpenAI/OpenAIProbe.swift`:

```swift
import Foundation

public struct OpenAIProbe: UsageProbe {
    public let providerID: ProviderID = .openai
    public let displayName = "OpenAI"

    private let reader: CredentialReader
    private let client: HTTPClient
    private let now: () -> Date

    public init(reader: CredentialReader = FileCredentialReader(),
                client: HTTPClient = URLSessionHTTPClient(),
                now: @escaping () -> Date = Date.init) {
        self.reader = reader
        self.client = client
        self.now = now
    }

    public func fetch() async throws -> UsageSnapshot {
        let auth = try? JSONDecoder().decode(
            CodexAuth.self, from: try reader.read(relativePath: ".codex/auth.json"))
        let token = auth?.tokens?.access_token
        let acct = auth?.tokens?.account_id ?? ""

        let outcome = await AuthenticatedRequest.run(
            provider: .openai,
            accessToken: token,
            isExpired: Self.isExpired(token, now: now()),
            request: { t in
                var r = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
                r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
                r.setValue(acct, forHTTPHeaderField: "chatgpt-account-id")
                r.setValue("GQuota/0.1", forHTTPHeaderField: "User-Agent")
                return r
            },
            client: client,
            parse: Self.parse
        )
        return Self.snapshot(from: outcome, now: now())
    }

    static func snapshot(from outcome: AuthOutcome, now: Date) -> UsageSnapshot {
        switch outcome {
        case .ok(let w): return .init(providerID: .openai, windows: w, fetchedAt: now, state: .ok)
        case .stale: return .init(providerID: .openai, windows: [], fetchedAt: now, state: .stale(since: now))
        case .needsAuth: return .init(providerID: .openai, windows: [], fetchedAt: now, state: .needsAuth)
        case .rateLimited(let r): return .init(providerID: .openai, windows: [], fetchedAt: now, state: .rateLimited(retryAfter: r))
        case .unavailable(let reason): return .init(providerID: .openai, windows: [], fetchedAt: now, state: .unavailable(reason: reason))
        }
    }

    /// 解析 wham/usage → 窗口（精确值）。
    static func parse(_ data: Data) throws -> [UsageWindow] {
        let dto = try JSONDecoder().decode(OpenAIUsageDTO.self, from: data)
        var out: [UsageWindow] = []
        if let h = dto.five_hour {
            out.append(.init(label: "5 小时窗口", measure: .usedFraction(h.used_percent / 100),
                             resetsAt: h.reset_at.map { Date(timeIntervalSince1970: $0) },
                             confidence: .exact, detail: nil))
        }
        if let w = dto.weekly {
            out.append(.init(label: "周限额", measure: .usedFraction(w.used_percent / 100),
                             resetsAt: w.reset_at.map { Date(timeIntervalSince1970: $0) },
                             confidence: .exact, detail: nil))
        }
        return out
    }

    static func planType(fromAccessToken jwt: String) -> String? {
        (try? JWTDecoder.decodePayload(jwt))?["chatgpt_plan_type"] as? String
    }

    /// 用 JWT exp 判断过期；解不出按未过期处理（让接口去判 401）。
    static func isExpired(_ token: String?, now: Date) -> Bool {
        guard let token, let claims = try? JWTDecoder.decodePayload(token),
              let exp = claims["exp"] as? Double else { return false }
        return now.timeIntervalSince1970 >= exp
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cd GQuotaKit && swift test --filter OpenAIProbeTests`
Expected: PASS（3 个）。

- [ ] **Step 5: Commit**

```bash
git add GQuotaKit/Sources/GQuotaKit/Infrastructure/OpenAI GQuotaKit/Tests/GQuotaKitTests/OpenAIProbeTests.swift
git commit -m "feat(openai): OpenAIProbe — auth.json → wham/usage → windows"
```

---

## Task 9: GeminiProbe（含 dummy-100% 检测 [CRITICAL]）

**Files:**
- Create: `GQuotaKit/Sources/GQuotaKit/Infrastructure/Gemini/GeminiOAuth.swift`
- Create: `GQuotaKit/Sources/GQuotaKit/Infrastructure/Gemini/GeminiQuotaDTO.swift`
- Create: `GQuotaKit/Sources/GQuotaKit/Infrastructure/Gemini/GeminiProbe.swift`
- Test: `GQuotaKit/Tests/GQuotaKitTests/GeminiProbeTests.swift`

> 字段名以 Phase 0 的 `gemini-retrieveUserQuota.json` 为准。

- [ ] **Step 1: 写失败测试**

`GQuotaKit/Tests/GQuotaKitTests/GeminiProbeTests.swift`:

```swift
import Testing
import Foundation
@testable import GQuotaKit

@Test func parsesBucketsAsRemainingFraction() throws {
    let json = """
    {"buckets":[
      {"modelId":"gemini-2.5-pro","remainingFraction":0.31,"resetTime":"2026-06-12T08:00:00Z"},
      {"modelId":"gemini-2.5-flash","remainingFraction":0.88,"resetTime":"2026-06-12T08:00:00Z"}
    ]}
    """
    let windows = try GeminiProbe.parse(Data(json.utf8))
    #expect(windows.count == 2)
    if case .remainingFraction(let f) = windows.first(where: { $0.label.contains("pro") || $0.label.contains("Pro") })?.measure ?? .usedFraction(0) {
        #expect(abs(f - 0.31) < 1e-9)
    }
}

@Test func dummyAllHundredPercentIsDetected() {
    // project 缺失征兆：所有 bucket remainingFraction == 1.0
    let json = """
    {"buckets":[
      {"modelId":"a","remainingFraction":1.0,"resetTime":"2026-06-12T08:00:00Z"},
      {"modelId":"b","remainingFraction":1.0,"resetTime":"2026-06-12T08:00:00Z"}
    ]}
    """
    #expect(GeminiProbe.looksLikeDummy(Data(json.utf8)) == true)
}

@Test func realDataIsNotDummy() {
    let json = #"{"buckets":[{"modelId":"a","remainingFraction":0.5,"resetTime":"2026-06-12T08:00:00Z"}]}"#
    #expect(GeminiProbe.looksLikeDummy(Data(json.utf8)) == false)
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd GQuotaKit && swift test --filter GeminiProbeTests`
Expected: FAIL，「cannot find 'GeminiProbe'」。

- [ ] **Step 3: 写实现**

`Infrastructure/Gemini/GeminiOAuth.swift`:

```swift
import Foundation

/// `~/.gemini/oauth_creds.json` 子集。
struct GeminiOAuth: Decodable {
    let access_token: String?
    let refresh_token: String?
    let expiry_date: Double?      // 毫秒 epoch
}
```

`Infrastructure/Gemini/GeminiQuotaDTO.swift`:

```swift
import Foundation

struct GeminiQuotaDTO: Decodable {
    struct Bucket: Decodable {
        let modelId: String
        let remainingFraction: Double
        let resetTime: String?
    }
    let buckets: [Bucket]
}

struct GeminiLoadCodeAssistDTO: Decodable {
    let cloudaicompanionProject: String?
    let currentTier: Tier?
    struct Tier: Decodable { let id: String? }
}
```

`Infrastructure/Gemini/GeminiProbe.swift`:

```swift
import Foundation

public struct GeminiProbe: UsageProbe {
    public let providerID: ProviderID = .gemini
    public let displayName = "Gemini"

    private let reader: CredentialReader
    private let client: HTTPClient
    private let now: () -> Date

    public init(reader: CredentialReader = FileCredentialReader(),
                client: HTTPClient = URLSessionHTTPClient(),
                now: @escaping () -> Date = Date.init) {
        self.reader = reader; self.client = client; self.now = now
    }

    public func fetch() async throws -> UsageSnapshot {
        let creds = try? JSONDecoder().decode(
            GeminiOAuth.self, from: try reader.read(relativePath: ".gemini/oauth_creds.json"))
        guard let token = creds?.access_token else {
            return .init(providerID: .gemini, windows: [], fetchedAt: now(), state: .needsAuth)
        }
        if isExpired(creds) {
            return .init(providerID: .gemini, windows: [], fetchedAt: now(), state: .stale(since: now()))
        }
        // 1) loadCodeAssist 拿 project
        guard let project = try? await loadProject(token: token), !project.isEmpty else {
            return .init(providerID: .gemini, windows: [], fetchedAt: now(),
                         state: .unavailable(reason: "需配置 GCP 项目"))
        }
        // 2) retrieveUserQuota
        var req = URLRequest(url: URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["project": project])
        do {
            let (data, http) = try await client.send(req)
            switch http.statusCode {
            case 200..<300:
                if Self.looksLikeDummy(data) {
                    return .init(providerID: .gemini, windows: [], fetchedAt: now(),
                                 state: .unavailable(reason: "需配置 GCP 项目"))
                }
                return .init(providerID: .gemini, windows: try Self.parse(data),
                             fetchedAt: now(), state: .ok)
            case 401: return .init(providerID: .gemini, windows: [], fetchedAt: now(), state: .needsAuth)
            case 403: return .init(providerID: .gemini, windows: [], fetchedAt: now(),
                                   state: .unavailable(reason: "Code Assist 未启用"))
            case 429: return .init(providerID: .gemini, windows: [], fetchedAt: now(), state: .rateLimited(retryAfter: nil))
            default: return .init(providerID: .gemini, windows: [], fetchedAt: now(),
                                  state: .unavailable(reason: "HTTP \(http.statusCode)"))
            }
        } catch {
            return .init(providerID: .gemini, windows: [], fetchedAt: now(), state: .stale(since: now()))
        }
    }

    private func loadProject(token: String) async throws -> String? {
        var req = URLRequest(url: URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(
            withJSONObject: ["metadata": ["ideType": "GEMINI_CLI", "pluginType": "GEMINI"]])
        let (data, http) = try await client.send(req)
        guard (200..<300).contains(http.statusCode) else { return nil }
        return try? JSONDecoder().decode(GeminiLoadCodeAssistDTO.self, from: data).cloudaicompanionProject
    }

    private func isExpired(_ creds: GeminiOAuth?) -> Bool {
        guard let ms = creds?.expiry_date else { return false }
        return now().timeIntervalSince1970 >= ms / 1000
    }

    /// 多模型归并：每模型一窗，按 modelId 标签。
    static func parse(_ data: Data) throws -> [UsageWindow] {
        let dto = try JSONDecoder().decode(GeminiQuotaDTO.self, from: data)
        let fmt = ISO8601DateFormatter()
        return dto.buckets.map { b in
            UsageWindow(label: b.modelId,
                        measure: .remainingFraction(b.remainingFraction),
                        resetsAt: b.resetTime.flatMap { fmt.date(from: $0) },
                        confidence: .exact, detail: nil)
        }
    }

    /// project 缺失时接口返回全 1.0 的假数据。全部 remainingFraction==1.0 且 ≥2 桶 → 视为 dummy。
    static func looksLikeDummy(_ data: Data) -> Bool {
        guard let dto = try? JSONDecoder().decode(GeminiQuotaDTO.self, from: data),
              dto.buckets.count >= 2 else { return false }
        return dto.buckets.allSatisfy { $0.remainingFraction == 1.0 }
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cd GQuotaKit && swift test --filter GeminiProbeTests`
Expected: PASS（3 个，含 CRITICAL 的 dummy 检测）。

- [ ] **Step 5: Commit**

```bash
git add GQuotaKit/Sources/GQuotaKit/Infrastructure/Gemini GQuotaKit/Tests/GQuotaKitTests/GeminiProbeTests.swift
git commit -m "feat(gemini): GeminiProbe — loadCodeAssist + retrieveUserQuota + dummy-100% detection"
```

---

## Task 10: Clock + SnapshotCache

**Files:**
- Create: `GQuotaKit/Sources/GQuotaKit/Application/Clock.swift`
- Create: `GQuotaKit/Sources/GQuotaKit/Application/SnapshotCache.swift`
- Test: `GQuotaKit/Tests/GQuotaKitTests/SnapshotCacheTests.swift`

- [ ] **Step 1: 写失败测试**

`GQuotaKit/Tests/GQuotaKitTests/SnapshotCacheTests.swift`:

```swift
import Testing
import Foundation
@testable import GQuotaKit

private func snap(_ p: ProviderID) -> UsageSnapshot {
    .init(providerID: p, windows: [], fetchedAt: Date(timeIntervalSince1970: 1), state: .ok)
}

@Test func memoryRoundTrip() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = SnapshotCache(directory: dir)
    await cache.put(snap(.openai))
    let got = await cache.get(.openai)
    #expect(got?.providerID == .openai)
}

@Test func diskPersistenceSurvivesNewInstance() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let c1 = SnapshotCache(directory: dir)
    await c1.put(snap(.gemini))
    let c2 = SnapshotCache(directory: dir)
    await c2.loadFromDisk()
    #expect(await c2.get(.gemini)?.providerID == .gemini)
}

@Test func corruptDiskFileIsIgnored() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? Data("not json".utf8).write(to: dir.appendingPathComponent("openai.json"))
    let cache = SnapshotCache(directory: dir)
    await cache.loadFromDisk()                 // 不崩
    #expect(await cache.get(.openai) == nil)
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd GQuotaKit && swift test --filter SnapshotCacheTests`
Expected: FAIL，「cannot find 'SnapshotCache'」。

- [ ] **Step 3: 写实现**

> `UsageSnapshot` 需可 Codable 落盘。但 `UsageMeasure`/`ProbeState` 含关联值——为磁盘缓存定义一个**只存展示数据、绝不含 token** 的 `CachedSnapshot` DTO（spec 7：磁盘缓存无 token）。

`Application/Clock.swift`:

```swift
import Foundation

public protocol Clock: Sendable { func now() -> Date }
public struct SystemClock: Clock { public init() {}; public func now() -> Date { Date() } }

public final class FakeClock: Clock, @unchecked Sendable {
    private let lock = NSLock(); private var current: Date
    public init(_ start: Date = Date(timeIntervalSince1970: 0)) { current = start }
    public func now() -> Date { lock.lock(); defer { lock.unlock() }; return current }
    public func advance(by seconds: TimeInterval) { lock.lock(); current += seconds; lock.unlock() }
}
```

`Application/SnapshotCache.swift`:

```swift
import Foundation

/// 内存 + 磁盘缓存。磁盘只存展示数据，绝不含 token（spec 7）。
public actor SnapshotCache {
    private var memory: [ProviderID: UsageSnapshot] = [:]
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func put(_ snapshot: UsageSnapshot) {
        memory[snapshot.providerID] = snapshot
        persist(snapshot)
    }

    public func get(_ id: ProviderID) -> UsageSnapshot? { memory[id] }
    public func all() -> [UsageSnapshot] { ProviderID.allCases.compactMap { memory[$0] } }

    public func loadFromDisk() {
        for id in ProviderID.allCases {
            let url = directory.appendingPathComponent("\(id.rawValue).json")
            guard let data = try? Data(contentsOf: url),
                  let dto = try? JSONDecoder().decode(CachedSnapshot.self, from: data) else { continue }
            memory[id] = dto.toSnapshot()
        }
    }

    private func persist(_ snapshot: UsageSnapshot) {
        let dto = CachedSnapshot(snapshot)
        guard let data = try? JSONEncoder().encode(dto) else { return }
        try? data.write(to: directory.appendingPathComponent("\(snapshot.providerID.rawValue).json"))
    }
}

/// 落盘 DTO：仅展示字段，无 token。
struct CachedSnapshot: Codable {
    enum Kind: String, Codable { case used, remaining, creditsZero, creditsPositive, unknown }
    struct Win: Codable { let label: String; let kind: Kind; let value: Double
        let resetsAt: Date?; let estimated: Bool; let detail: String? }
    let provider: String
    let windows: [Win]
    let fetchedAt: Date

    init(_ s: UsageSnapshot) {
        provider = s.providerID.rawValue
        fetchedAt = s.fetchedAt
        windows = s.windows.map { w in
            let (kind, value): (Kind, Double)
            switch w.measure {
            case .usedFraction(let v): (kind, value) = (.used, v)
            case .remainingFraction(let v): (kind, value) = (.remaining, v)
            case .unknownDenominator(let v): (kind, value) = (.unknown, v)
            case .creditsBalance(let amt, _): (kind, value) = (amt > 0 ? .creditsPositive : .creditsZero, 0)
            }
            return Win(label: w.label, kind: kind, value: value, resetsAt: w.resetsAt,
                       estimated: w.confidence == .estimated, detail: w.detail)
        }
    }

    func toSnapshot() -> UsageSnapshot {
        let id = ProviderID(rawValue: provider) ?? .openai
        let ws: [UsageWindow] = windows.map { w in
            let measure: UsageMeasure
            switch w.kind {
            case .used: measure = .usedFraction(w.value)
            case .remaining: measure = .remainingFraction(w.value)
            case .unknown: measure = .unknownDenominator(used: w.value)
            case .creditsPositive: measure = .creditsBalance(amount: 1, currency: "USD")
            case .creditsZero: measure = .creditsBalance(amount: 0, currency: "USD")
            }
            return UsageWindow(label: w.label, measure: measure, resetsAt: w.resetsAt,
                               confidence: w.estimated ? .estimated : .exact, detail: w.detail)
        }
        // 从磁盘恢复的都标 stale（重启后先显旧值再后台刷新）。
        return UsageSnapshot(providerID: id, windows: ws, fetchedAt: fetchedAt, state: .stale(since: fetchedAt))
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cd GQuotaKit && swift test --filter SnapshotCacheTests`
Expected: PASS（3 个）。

- [ ] **Step 5: Commit**

```bash
git add GQuotaKit/Sources/GQuotaKit/Application/Clock.swift GQuotaKit/Sources/GQuotaKit/Application/SnapshotCache.swift GQuotaKit/Tests/GQuotaKitTests/SnapshotCacheTests.swift
git commit -m "feat(app): token-free disk SnapshotCache + injectable Clock"
```

---

## Task 11: PollScheduler（退避 + 睡眠/唤醒 + 可达性门控）

**Files:**
- Create: `GQuotaKit/Sources/GQuotaKit/Application/PollScheduler.swift`
- Test: `GQuotaKit/Tests/GQuotaKitTests/PollSchedulerTests.swift`

> 把退避算法与「是否允许轮询」的门控逻辑抽成纯函数，单测纯逻辑；真实 NSWorkspace/NWPathMonitor 订阅放 app 层（Task 16）通过回调驱动。

- [ ] **Step 1: 写失败测试**

`GQuotaKit/Tests/GQuotaKitTests/PollSchedulerTests.swift`:

```swift
import Testing
import Foundation
@testable import GQuotaKit

@Test func backoffDoublesOnFailureToCap() {
    var b = Backoff(base: 120, cap: 600)
    #expect(b.current == 120)
    b.recordFailure(); #expect(b.current == 240)
    b.recordFailure(); #expect(b.current == 480)
    b.recordFailure(); #expect(b.current == 600)   // capped
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
    var b = Backoff(base: 120, cap: 600)
    let retry = Date(timeIntervalSince1970: 1000)
    let next = b.nextFireDate(now: Date(timeIntervalSince1970: 100), retryAfter: retry)
    #expect(next == retry)   // 429 retry-after 优先
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd GQuotaKit && swift test --filter PollSchedulerTests`
Expected: FAIL，「cannot find 'Backoff'」。

- [ ] **Step 3: 写实现**

`Application/PollScheduler.swift`:

```swift
import Foundation

/// 指数退避（纯值类型，易测）。
public struct Backoff: Sendable {
    public let base: TimeInterval
    public let cap: TimeInterval
    public private(set) var current: TimeInterval
    public init(base: TimeInterval, cap: TimeInterval) {
        self.base = base; self.cap = cap; self.current = base
    }
    public mutating func recordFailure() { current = min(cap, current * 2) }
    public mutating func recordSuccess() { current = base }
    public func nextFireDate(now: Date, retryAfter: Date?) -> Date {
        if let retryAfter, retryAfter > now { return retryAfter }   // 429 优先
        return now.addingTimeInterval(current)
    }
}

/// 轮询门控：睡眠暂停 + 网络未就绪不发（spec 7 / A2）。
public struct PollGate: Sendable {
    public let asleep: Bool
    public let networkUp: Bool
    public init(asleep: Bool, networkUp: Bool) { self.asleep = asleep; self.networkUp = networkUp }
    public var shouldPoll: Bool { !asleep && networkUp }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cd GQuotaKit && swift test --filter PollSchedulerTests`
Expected: PASS（6 个）。

- [ ] **Step 5: Commit**

```bash
git add GQuotaKit/Sources/GQuotaKit/Application/PollScheduler.swift GQuotaKit/Tests/GQuotaKitTests/PollSchedulerTests.swift
git commit -m "feat(app): Backoff + PollGate (sleep/reachability) pure logic"
```

---

## Task 12: UsageCoordinator（失败隔离 + 聚合）

**Files:**
- Create: `GQuotaKit/Sources/GQuotaKit/Application/UsageCoordinator.swift`
- Test: `GQuotaKit/Tests/GQuotaKitTests/UsageCoordinatorTests.swift`

- [ ] **Step 1: 写失败测试**

`GQuotaKit/Tests/GQuotaKitTests/UsageCoordinatorTests.swift`:

```swift
import Testing
import Foundation
@testable import GQuotaKit

private struct Boom: Error, Sendable {}

private struct StubProbe: UsageProbe {
    let providerID: ProviderID
    let displayName: String
    let result: Result<UsageSnapshot, Boom>     // Sendable error → StubProbe 是 Sendable
    func fetch() async throws -> UsageSnapshot { try result.get() }
}

@Test func oneProbeFailureDoesNotBlockOthers() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = SnapshotCache(directory: dir)
    let ok = UsageSnapshot(providerID: .gemini, windows: [], fetchedAt: Date(timeIntervalSince1970: 1), state: .ok)
    let coord = UsageCoordinator(
        probes: [
            StubProbe(providerID: .openai, displayName: "OpenAI", result: .failure(Boom())),
            StubProbe(providerID: .gemini, displayName: "Gemini", result: .success(ok)),
        ],
        cache: cache, clock: FakeClock())
    await coord.refreshAll()
    #expect(await cache.get(.gemini)?.state == .ok)        // 成功家落缓存
    let openai = await cache.get(.openai)
    if case .unavailable = openai?.state {} else { Issue.record("failed probe should be .unavailable") }
}

@Test func tightestSeverityAcrossProviders() {
    let a = UsageSnapshot(providerID: .openai, windows: [
        .init(label: "w", measure: .usedFraction(0.4), resetsAt: nil, confidence: .exact, detail: nil)],
        fetchedAt: Date(), state: .ok)
    let b = UsageSnapshot(providerID: .gemini, windows: [
        .init(label: "w", measure: .remainingFraction(0.1), resetsAt: nil, confidence: .exact, detail: nil)],  // 用了 90%
        fetchedAt: Date(), state: .ok)
    #expect(abs(UsageCoordinator.tightestSeverity([a, b]) - 0.9) < 1e-9)
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd GQuotaKit && swift test --filter UsageCoordinatorTests`
Expected: FAIL，「cannot find 'UsageCoordinator'」。

- [ ] **Step 3: 写实现**

`Application/UsageCoordinator.swift`:

```swift
import Foundation

public actor UsageCoordinator {
    private let probes: [any UsageProbe]
    private let cache: SnapshotCache
    private let clock: Clock

    public init(probes: [any UsageProbe], cache: SnapshotCache, clock: Clock = SystemClock()) {
        self.probes = probes; self.cache = cache; self.clock = clock
    }

    /// 并发刷新所有家；单家抛错独立兜底为 .unavailable，绝不拖垮其他家。
    public func refreshAll() async {
        await withTaskGroup(of: UsageSnapshot.self) { group in
            for probe in probes {
                group.addTask {
                    do { return try await probe.fetch() }
                    catch {
                        return UsageSnapshot(providerID: probe.providerID, windows: [],
                                             fetchedAt: self.clock.now(),
                                             state: .unavailable(reason: "\(error)"))
                    }
                }
            }
            for await snap in group { await cache.put(snap) }
        }
    }

    /// 跨家最紧张的窗口严重度（菜单栏图标用）。无数据返回 0。
    public static func tightestSeverity(_ snapshots: [UsageSnapshot]) -> Double {
        snapshots.flatMap(\.windows).map { Severity.normalized($0.measure) }.max() ?? 0
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cd GQuotaKit && swift test --filter UsageCoordinatorTests`
Expected: PASS（2 个）。

- [ ] **Step 5: 全量回归**

Run: `cd GQuotaKit && swift test`
Expected: 全绿（约 30+ tests）。

- [ ] **Step 6: Commit**

```bash
git add GQuotaKit/Sources/GQuotaKit/Application/UsageCoordinator.swift GQuotaKit/Tests/GQuotaKitTests/UsageCoordinatorTests.swift
git commit -m "feat(app): UsageCoordinator — concurrent refresh, failure isolation, severity aggregation"
```

---

## Task 13: Xcode app 工程 + 非沙箱 entitlements

> 命令行无法可靠生成 .xcodeproj，此任务在 Xcode GUI 操作。产物提交到 git。

**Files:**
- Create: `GQuota.xcodeproj`（Xcode 生成）
- Create: `GQuota/Info.plist`、`GQuota/GQuota.entitlements`

- [ ] **Step 1: 新建 App 工程**

Xcode → File → New → Project → macOS → App。Product Name `GQuota`，Interface SwiftUI，Language Swift，存到仓库根 `ai-analytics/`。

- [ ] **Step 2: 加 GQuotaKit 本地包依赖**

Xcode → File → Add Package Dependencies → Add Local → 选 `GQuotaKit/` 目录 → 把 `GQuotaKit` library 加到 GQuota target。

- [ ] **Step 3: 设为菜单栏 accessory App**

`GQuota/Info.plist` 增加：

```xml
<key>LSUIElement</key>
<true/>
```

（隐藏 Dock 图标，纯菜单栏。）

- [ ] **Step 4: 关闭 App Sandbox（否则读不到 ~/.codex、~/.gemini）**

Target → Signing & Capabilities → 删除 App Sandbox capability（若默认带）。确认 `GQuota/GQuota.entitlements` 不含 `com.apple.security.app-sandbox` 或其为 `false`。签名用 "Sign to Run Locally"（ad-hoc，无需账号）。

- [ ] **Step 5: 构建确认能读家目录**

在 `GQuotaApp.swift` 临时加一行验证（稍后删）：

```swift
import GQuotaKit
// 临时：构建运行后控制台应打印 true（说明非沙箱能读到 ~/.codex）
let _probe = print(FileManager.default.fileExists(
    atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json").path))
```

Run（⌘R）。Expected: 控制台打印 `true`（若你已登录 codex）。确认后删除这行临时代码。

- [ ] **Step 6: Commit**

```bash
git add GQuota GQuota.xcodeproj
git commit -m "chore: Xcode app target — menu bar accessory, sandbox disabled, links GQuotaKit"
```

---

## Task 14: MenuBarIconRenderer（多柱微型条，彩色 non-template）

**Files:**
- Create: `GQuota/MenuBarIconRenderer.swift`
- Test: `GQuota/MenuBarIconRendererTests`（Xcode 单元测试 target，仅测纯函数布局）

> 渲染本身（NSImage 像素）走视觉手动验收（spec T1）；只把「severity→柱布局/颜色档」纯函数单测。

- [ ] **Step 1: 写失败测试（Xcode test target）**

新建 Unit Test target `GQuotaTests`（若 Task 13 未建）。`GQuota/MenuBarIconRendererTests.swift`:

```swift
import XCTest
import GQuotaKit
@testable import GQuota

final class MenuBarIconRendererTests: XCTestCase {
    func testBarHeightsMapSeverity() {
        let bars = MenuBarIconRenderer.bars(for: [0.2, 0.95])
        XCTAssertEqual(bars.count, 2)
        XCTAssertEqual(bars[0].heightFraction, 0.2, accuracy: 1e-9)
        XCTAssertEqual(bars[1].tier, .danger)   // 0.95 → danger
    }
    func testEmptyProducesNeutralPlaceholder() {
        let bars = MenuBarIconRenderer.bars(for: [])
        XCTAssertTrue(bars.isEmpty)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Xcode ⌘U（或 `xcodebuild test -scheme GQuota`）。Expected: FAIL，未定义 `MenuBarIconRenderer`。

- [ ] **Step 3: 写实现**

`GQuota/MenuBarIconRenderer.swift`:

```swift
import AppKit
import GQuotaKit

enum MenuBarIconRenderer {
    struct Bar { let heightFraction: Double; let tier: SeverityTier }

    /// 纯函数：severity 数组 → 每柱高度+档位。
    static func bars(for severities: [Double]) -> [Bar] {
        severities.map { Bar(heightFraction: min(1, max(0, $0)), tier: Severity.tier(for: $0)) }
    }

    /// 彩色 non-template NSImage：每家一柱，高度=severity，颜色=档位 token，加描边保证三背景对比度（spec 8.1）。
    static func image(for severities: [Double], appearance: NSAppearance) -> NSImage {
        let bars = bars(for: severities)
        let w = max(8, CGFloat(bars.count) * 6); let h: CGFloat = 16
        let img = NSImage(size: NSSize(width: w, height: h))
        img.isTemplate = false                              // 彩色：不可用 template
        img.lockFocus()
        for (i, bar) in bars.enumerated() {
            let x = CGFloat(i) * 6 + 1
            let barH = max(2, CGFloat(bar.heightFraction) * (h - 2))
            let rect = NSRect(x: x, y: 1, width: 4, height: barH)
            let (r, g, b) = bar.tier.colorRGB
            NSColor(calibratedRed: r, green: g, blue: b, alpha: 1).setFill()
            let path = NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1)
            path.fill()
            NSColor.black.withAlphaComponent(0.25).setStroke()   // 描边保证浅色菜单栏对比度
            path.lineWidth = 0.5; path.stroke()
        }
        img.unlockFocus()
        return img
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Xcode ⌘U。Expected: PASS（2 个）。

- [ ] **Step 5: Commit**

```bash
git add GQuota/MenuBarIconRenderer.swift GQuota/MenuBarIconRendererTests.swift
git commit -m "feat(ui): MenuBarIconRenderer — multi-bar colored non-template icon"
```

---

## Task 15: AppModel + MenuBarExtra + 面板

**Files:**
- Create: `GQuota/AppModel.swift`
- Create: `GQuota/GQuotaApp.swift`（替换 Xcode 默认）
- Create: `GQuota/MenuBarPanel.swift`
- Create: `GQuota/ProviderRow.swift`

- [ ] **Step 1: AppModel（@MainActor 状态 + 轮询循环 + 生命周期/可达性门控）**

`GQuota/AppModel.swift`:

```swift
import SwiftUI
import AppKit
import Network
import GQuotaKit

@MainActor
final class AppModel: ObservableObject {
    @Published var snapshots: [UsageSnapshot] = []
    @Published var lastUpdated: Date?

    private let coordinator: UsageCoordinator
    private let cache: SnapshotCache
    private var asleep = false
    private var networkUp = true
    private let monitor = NWPathMonitor()
    private var backoff = Backoff(base: 180, cap: 600)   // 3 分钟基准
    private var loopTask: Task<Void, Never>?

    init() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GQuota")
        let cache = SnapshotCache(directory: dir)
        self.cache = cache
        self.coordinator = UsageCoordinator(
            probes: [OpenAIProbe(), GeminiProbe()], cache: cache)
        subscribeLifecycle()
        subscribeReachability()
        start()                                                  // 在 init 启动，避免依赖 Scene 级 .task
    }

    func start() {
        Task { await cache.loadFromDisk(); await render() }      // 冷启动先显磁盘缓存
        loopTask = Task { await pollLoop() }
    }

    func refreshNow() { Task { await refresh() } }

    private func pollLoop() async {
        while !Task.isCancelled {
            if PollGate(asleep: asleep, networkUp: networkUp).shouldPoll {
                await refresh()
            }
            try? await Task.sleep(for: .seconds(backoff.current))
        }
    }

    private func refresh() async {
        await coordinator.refreshAll()
        await render()
        let anyFail = snapshots.contains { if case .unavailable = $0.state { return true }; if case .rateLimited = $0.state { return true }; return false }
        if anyFail { backoff.recordFailure() } else { backoff.recordSuccess() }
    }

    private func render() async {
        snapshots = await cache.all()
        lastUpdated = snapshots.compactMap { if case .ok = $0.state { return $0.fetchedAt }; return nil }.max()
    }

    var severities: [Double] {
        ProviderID.allCases.compactMap { id in
            snapshots.first { $0.providerID == id }
        }.map { UsageCoordinator.tightestSeverity([$0]) }
    }

    private func subscribeLifecycle() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.asleep = true }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.asleep = false; self?.refreshNow() }   // 唤醒后（网络就绪门控仍把关）刷新
    }

    private func subscribeReachability() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.networkUp = (path.status == .satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "gquota.netmonitor"))
    }
}
```

- [ ] **Step 2: GQuotaApp + MenuBarExtra**

`GQuota/GQuotaApp.swift`:

```swift
import SwiftUI
import GQuotaKit

@main
struct GQuotaApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel(model: model)
        } label: {
            // 多柱图标（彩色 non-template）。MenuBarExtra label 接受 Image。
            // label 读 model.severities（派生自 @Published snapshots）→ 模型变更时自动重绘。
            Image(nsImage: MenuBarIconRenderer.image(
                for: model.severities,
                appearance: NSApp.effectiveAppearance))
        }
        .menuBarExtraStyle(.window)        // window 样式 = 自定义下拉面板
    }
}
```

> 轮询循环在 `AppModel.init()` 启动（已在 Task 15 Step 1），无需 Scene 级 `.task`。`@StateObject` 在 App 构造时创建一次。

- [ ] **Step 3: 面板 + 行（双通道严重度 + VoiceOver + 空态）**

`GQuota/ProviderRow.swift`:

```swift
import SwiftUI
import GQuotaKit

struct ProviderRow: View {
    let snapshot: UsageSnapshot

    private var primary: UsageWindow? { snapshot.windows.first }
    private var severity: Double { primary.map { Severity.normalized($0.measure) } ?? 0 }
    private var tier: SeverityTier { Severity.tier(for: severity) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(displayName).font(.system(size: 13, weight: .semibold))
                Spacer()
                statusText
            }
            ProgressView(value: severity)
                .tint(color)
                .accessibilityHidden(true)   // 进度条装饰；语义在行 label 上
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)   // VoiceOver（spec 8.4 / D3）
    }

    private var displayName: String {
        switch snapshot.providerID {
        case .openai: return "OpenAI"; case .gemini: return "Gemini"
        case .claude: return "Claude"; case .xai: return "Grok"
        }
    }

    @ViewBuilder private var statusText: some View {
        switch snapshot.state {
        case .ok, .stale:
            if let w = primary {
                // 双通道：图标符号 + 百分比文字 + 颜色（spec 8.4 / D2）
                Text("\(tier.iconSymbol) \(percentText(w))")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(color)
            } else { Text("—").foregroundStyle(.secondary) }
        case .needsAuth: Text("未检测到登录").font(.system(size: 11)).foregroundStyle(.secondary)
        case .rateLimited: Text("限流中").font(.system(size: 11)).foregroundStyle(.secondary)
        case .unavailable(let r): Text(r).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func percentText(_ w: UsageWindow) -> String {
        let used = Int((Severity.normalized(w.measure) * 100).rounded())
        let prefix = w.confidence == .estimated ? "~" : ""
        let stale = { if case .stale = snapshot.state { return " · 陈旧" }; return "" }()
        return "\(prefix)\(used)%\(stale)"
    }

    private var color: Color {
        let (r, g, b) = tier.colorRGB
        return Color(red: r, green: g, blue: b)
    }

    private var accessibilityLabel: String {
        guard let w = primary, case .ok = snapshot.state else {
            return "\(displayName)，\(stateDescription)"
        }
        let used = Int((Severity.normalized(w.measure) * 100).rounded())
        var s = "\(displayName)，\(w.label)已用 \(used)%"
        if w.confidence == .estimated { s += "（估算）" }
        if let reset = w.resetsAt {
            s += "，\(RelativeDateTimeFormatter().localizedString(for: reset, relativeTo: Date())) 重置"
        }
        return s
    }

    private var stateDescription: String {
        switch snapshot.state {
        case .needsAuth: return "未检测到登录"
        case .stale: return "数据陈旧"
        case .rateLimited: return "限流中"
        case .unavailable(let r): return r
        case .ok: return "正常"
        }
    }
}
```

`GQuota/MenuBarPanel.swift`:

```swift
import SwiftUI
import GQuotaKit

struct MenuBarPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("GQuota").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(updatedText).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Divider()

            if model.snapshots.isEmpty {
                // 冷启动空态（spec 8.3 / D5）
                Text("首次检测中…").font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else if model.snapshots.allSatisfy({ if case .needsAuth = $0.state { return true }; return false }) {
                // 全空态：引导
                VStack(alignment: .leading, spacing: 4) {
                    Text("未检测到已登录的 CLI").font(.system(size: 12))
                    Text("在终端运行 codex / gemini 登录后，这里会显示额度")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(.vertical, 6)
            } else {
                ForEach(model.snapshots, id: \.providerID) { ProviderRow(snapshot: $0) }
            }

            Divider()
            HStack {
                Button("立即刷新") { model.refreshNow() }
                Spacer()
                Button("退出") { NSApplication.shared.terminate(nil) }
            }.font(.system(size: 11))
        }
        .padding(12)
        .frame(width: 280)
    }

    private var updatedText: String {
        guard let t = model.lastUpdated else { return "尚未更新" }
        return "\(RelativeDateTimeFormatter().localizedString(for: t, relativeTo: Date())) 更新"
    }
}
```

- [ ] **Step 4: 构建运行 + 手动验收**

Run（⌘R）。Expected:
- 菜单栏出现多柱图标（OpenAI/Gemini 各一柱，颜色随用量）。
- 点开面板：两家各一行进度条 + `图标符号 百分比`；未登录家显「未检测到登录」。
- 无 Dock 图标。

- [ ] **Step 5: 无障碍 + 三背景手动验收（spec T1/T10/T11）**

- 系统设置切浅色/深色，确认柱在两种菜单栏下都看得清。
- 开 VoiceOver（⌘F5），聚焦菜单栏项与每行，确认读出「OpenAI，5 小时窗口已用 72%，… 重置」。
- 系统设置 → 辅助功能 → 显示 → 色彩滤镜开「灰度」，确认靠图标符号(○◐●)+数字仍能区分严重度。

- [ ] **Step 6: Commit**

```bash
git add GQuota/AppModel.swift GQuota/GQuotaApp.swift GQuota/MenuBarPanel.swift GQuota/ProviderRow.swift
git commit -m "feat(ui): MenuBarExtra panel — dual-channel severity, VoiceOver labels, empty states, lifecycle/reachability polling"
```

---

## Task 16: 收尾（README + 首启说明 + 最终回归）

**Files:**
- Create: `README.md`
- Modify: `GQuota/MenuBarPanel.swift`（首启隐私说明，可选）

- [ ] **Step 1: 写 README（自用构建说明 + 隐私/ToS 定位）**

`README.md`:

```markdown
# GQuota

macOS 菜单栏 AI 额度监控（个人自用）。常驻菜单栏显示 OpenAI(Codex) 与 Gemini 订阅配额的多柱微型条。

## 构建运行（本地 ad-hoc）
1. 已登录 `codex` 与/或 `gemini` CLI。
2. 打开 `GQuota.xcodeproj`，⌘R。

## 隐私与定位
- 仅读取本机 `~/.codex`、`~/.gemini` 凭证查询你自己的额度；token 仅内存处理，绝不写回 CLI、绝不上传网络。
- 依赖各家**非公开接口**，可能随时失效。个人自用工具，默认不公开分发；分发前须重新评估各家 ToS（见 spec 第 13 节）。

## 单元测试
`cd GQuotaKit && swift test`
```

- [ ] **Step 2: 全量回归（核心包）**

Run: `cd GQuotaKit && swift test`
Expected: 全绿。

- [ ] **Step 3: 构建 app 测试**

Run: `xcodebuild -scheme GQuota -destination 'platform=macOS' test`（或 Xcode ⌘U）
Expected: app 单测（IconRenderer）通过 + 构建成功。

- [ ] **Step 4: Commit**

```bash
git add README.md GQuota
git commit -m "docs: README with local-build + privacy/ToS positioning"
```

---

## 验收清单（对照 spec 实现任务）

- T1 Phase 0 spike → Task 0
- T2 数据模型语义 → Task 2
- T3 AuthenticatedRequest（不刷新）→ Task 7
- T4 PollScheduler 睡眠/可达性/退避 → Task 11 + Task 15
- T5 Gemini dummy-100% 检测 [CRIT] → Task 9
- T6 MenuBarIconRenderer 彩色 non-template → Task 14
- T7 entitlements 关沙箱 + ad-hoc 构建 → Task 13
- T8 隐私（磁盘缓存无 token + 首启说明）→ Task 10（CachedSnapshot 无 token）+ Task 16
- T9 SnapshotCache SWR + 磁盘损坏回退 → Task 10
- T10 严重度双通道 → Task 3（Severity）+ Task 15（ProviderRow）
- T11 VoiceOver 标签 → Task 15
- T12 设计 token → Task 3（SeverityTier.colorRGB/iconSymbol）
- T13 冷启/全空/部分空三态 → Task 15（MenuBarPanel）
