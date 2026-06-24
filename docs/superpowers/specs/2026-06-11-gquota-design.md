# GQuota 设计文档

> macOS 菜单栏 AI 额度监控 App — 同时查看 Claude / OpenAI(Codex) / Gemini / Grok 等多家提供商的订阅配额与 API 用量。

- **状态**：设计已确认，已过 plan-eng-review（含 codex 外部第二意见），待用户最终审阅
- **日期**：2026-06-11
- **平台**：仅 macOS（13 Ventura+）
- **目录**：仓库根目录
- **工作名**：GQuota
- **定位**：个人自用工具（详见第 13 节法律/ToS 与定位）

---

## 1. 目标与范围

### 1.1 产品定位

一款常驻 macOS 菜单栏的轻量工具。菜单栏图标以「多柱微型条」实时显示各家 AI 提供商最紧张窗口的用量，点开是一个下拉面板，逐家展示进度条、计划档位、重置时间。核心使用场景是「随时瞄一眼，知道哪家额度快用完了」。

### 1.2 核心原则

- **轻量常驻**：原生、无运行时、低内存占用，契合菜单栏小工具定位。
- **隐私优先 + 不伤害宿主 CLI**：所有凭证与 token 仅在本机内存处理，绝不写回 CLI 凭证文件、绝不上传任何网络。磁盘缓存只存展示数据、**绝不含 token**；日志/崩溃报告对 token 脱敏。监控工具绝不能反过来弄坏被监控的 CLI（见第 7 节刷新策略）。
- **失败优雅**：本质是「读他人凭证、调他人非公开接口」，失败是常态。单家失败绝不拖垮其他家；UI 永远不崩、永远显示可用信息（缓存值 + 状态标记）。
- **精确 vs 估算明确区分**：不同数据源精度不同，UI 必须逐窗标明官方精确值还是本地估算（见第 4.1 节数据模型的 per-window confidence）。

### 1.3 MVP 范围（方案 A · 绿灯先行）

第一版**只做 OpenAI + Gemini 的订阅配额**——两家数据源全绿、凭证明文零门槛、无 Keychain 弹窗、接口结构完整且已在研究中验证。但协议与调度层从一开始就按「容纳四家」设计（D1 已确认完整骨架），后续接入是纯增量。

分批路线：

| 批次 | 内容 | 关键挑战 |
|---|---|---|
| **Phase 0（spike，先行）** | 真凭证验证 OpenAI/Gemini 接口可跑通 + 抓真实 JSON 形状 + 验 refresh token 是否轮转 | 去掉「私有接口漂移 / 刷新弄坏 CLI」两大主风险 |
| **批次 1（MVP）** | OpenAI + Gemini 订阅配额 | 跑通统一 `UsageProbe` 架构、菜单栏多柱 UI、轮询/缓存 |
| **批次 2** | Claude 订阅配额 | Keychain 读取、激进限流防护、token 刷新 |
| **批次 3** | API key 用量/花费侧 | OpenAI Admin API、xAI Management API（均需高权限 key） |
| **批次 4（可选）** | Grok 订阅估算 | 本地日志 token 估算（无官方源） |

### 1.4 明确不做（YAGNI）

- 不做独立窗口 Dashboard、不做历史趋势长图（形态定为纯菜单栏）。
- 不做 Grok 订阅配额的「精确」展示（无官方源，仅批次 4 做估算且明确标注）。
- 不做 Gemini API key 用量（AI Studio 无程序化接口；GCP Monitoring 路线对菜单栏 App 过重）。
- 不把凭证写回 CLI 文件、不做跨设备同步、不做云端账户。
- **MVP 不主动刷新 token**（见第 7 节，OV2 决定）。
- **MVP 不做签名/公证/Sparkle**（本地 ad-hoc 构建，见第 12 节，A4 决定）。

---

## 2. 可行性矩阵（研究结论）

经过对四家提供商的本地凭证、用量接口、开源工具做法的并行研究（含真实接口探测），结论如下。🟢 直接可做 / 🟡 可做但有估算或高权限/限流约束 / 🔴 基本拿不到。

| 提供商 | 订阅配额（5h/周窗口） | API key 用量/花费 |
|---|---|---|
| **OpenAI**（Codex/ChatGPT） | 🟢 `backend-api/wham/usage` 实测 200，一次返回 5h + 周 + 每模型 used_percent + reset_at + credits；凭证 `~/.codex/auth.json` 明文 0600，计划类型直接写在 access_token JWT 的 `chatgpt_plan_type` claim | 🟡 官方 Usage/Cost API 精确，但强制 Admin key + org owner，个人订阅用不了 |
| **Gemini**（CLI/AI Studio） | 🟢 `v1internal:retrieveUserQuota`（须先 `loadCodeAssist` 拿 project）返回每模型 `remainingFraction` + `resetTime`；凭证 `~/.gemini/oauth_creds.json` 明文 | 🔴 AI Studio key 无任何用量接口（仅网页 dashboard）；GCP Monitoring 路线门槛过高 |
| **Claude**（Anthropic） | 🟡 `GET api.anthropic.com/api/oauth/usage` 官方级精确（Claude Code statusline 自用），返回 `five_hour`/`seven_day` 的 utilization + resets_at。但①凭证在 **Keychain**（服务名 `Claude Code-credentials`，读取弹授权框）②**限流极激进**：30–60s 轮询即触发持久 429，可卡 30h+ | 🟡 Admin Usage/Cost API（`/v1/organizations/usage_report/messages`、`/cost_report`）精确，但仅限有 Organization 的账号 + `sk-ant-admin` key |
| **Grok**（xAI） | 🔴 无官方订阅配额 API，消费端限额仅存于 Grok UI，只能解析 `~/.grok/sessions/*/updates.jsonl` 估算 token（无重置窗口、无官方上限） | 🟢 官方 Management API（`management-api.x.ai`）精确返回预付费余额 + 按模型/日花费时序，但需高权限 Management key + team_id |

**关键洞察**：① 没有任何一家在「订阅」与「API」两侧用同一套凭证/接口。② **OpenAI 给的是 used_percent（越高用得越多），Gemini 给的是 remainingFraction（越高剩得越多），语义相反**——数据模型必须显式区分（见第 4.1）。③ 「实测 200」只证明接口此刻存在，不等于产品长期可行；私有接口随时可能改 schema/header/auth/反滥用，这是产品的根本风险，靠契约测试检测漂移 + 分发前必须有更新交付通道应对（见第 9、12 节）。

---

## 3. 技术栈

**SwiftUI + AppKit 原生**（MenuBarExtra 为主，NSStatusItem + NSPopover / MenuBarExtraAccess 兜底）。

选型理由：本需求四个核心动作——菜单栏显示用量、轻量下拉面板、读本机凭证文件 + Keychain、并发轮询多个 HTTPS 接口——全部命中原生舒适区，无任何跨平台/Web 渲染需求；5–15MB 无运行时契合「轻量常驻」；同类成功开源 App（ClaudeBar、CodexBar）几乎全是 Swift，是该细分场景的事实标准，有充足可参考代码。已对比并淘汰：Electron（100MB+/150–300MB 内存，违背轻量诉求）、Tauri 2（菜单栏需手动拼装 + WebView 公证坑）、纯 Rust（富面板成本高、相对原生无净收益）。

**关键库/能力**：

- SwiftUI `MenuBarExtra`（macOS 13+，菜单栏入口 + window 样式下拉面板）
- `MenuBarExtraAccess`（orchetect，绕过 MenuBarExtra 已知局限：拿底层 NSStatusItem、绑定 presentation 状态）；必要时降到 `NSStatusItem + NSPopover` 全自控
- `Security.framework`（Keychain Services，批次 2 读 Claude OAuth token）
- `Foundation`：`FileManager` + `Codable`/`JSONDecoder`（读解析 JSON 与逐行 JSONL）
- `URLSession`（async/await）+ `TaskGroup`/`async let`（并发轮询）
- `Network` `NWPathMonitor`（网络可达性门控，见第 7 节）
- `AppKit` `NSWorkspace` 睡眠/唤醒通知（生命周期门控，见第 7 节）
- `Task.sleep`/`DispatchSourceTimer`（定时轮询）
- `ServiceManagement` `SMAppService`（开机自启动；MVP 可后置）
- `Sparkle 2`（自动更新，EdDSA 签名 appcast；**MVP 不做**，分发阶段引入）
- 分发：Developer ID 签名 + `notarytool` 公证 +（可选）GitHub Release / Homebrew cask（**MVP 不做**，见第 12 节）

**工具链**：Xcode + Swift Package Manager；Swift 6（结构化并发）。

---

## 4. 架构

### 4.1 核心抽象：`UsageProbe` 协议 + 语义明确的数据模型

所有提供商统一到一个协议背后。加一家新提供商 = 写一个新 Probe，UI 与调度层完全不动。

数据模型经 OV3 修订：用枚举显式区分 used/remaining 语义、支持 credits 与未知分母、**每窗口**带 confidence（精确/估算），取代原先有损的 `utilization: Double` + snapshot 级 `isEstimated`。

```swift
protocol UsageProbe {
    var providerID: ProviderID { get }            // .openai / .gemini / .claude / .xai
    var displayName: String { get }
    func fetch() async throws -> UsageSnapshot     // 拉一次最新额度
}

enum ProviderID: String, CaseIterable {
    case openai, gemini, claude, xai
}

struct UsageSnapshot {
    let providerID: ProviderID
    let windows: [UsageWindow]      // 一家可能有多个窗口（5h / 周 / 每模型 / credits）
    let fetchedAt: Date
    let state: ProbeState
}

struct UsageWindow {
    let label: String               // "5 小时窗口" / "周限额" / "Pro 模型" / "Credits 余额"
    let measure: UsageMeasure       // 显式语义，避免方向性 bug
    let resetsAt: Date?
    let confidence: Confidence      // 逐窗：精确 / 估算（取代 snapshot 级 isEstimated）
    let detail: String?             // "Plus 档" 等
}

// 显式表达 used vs remaining vs 余额，杜绝「剩 31% 显成用 31%」
enum UsageMeasure {
    case usedFraction(Double)        // 0–1，越高用得越多（OpenAI used_percent）
    case remainingFraction(Double)   // 0–1，越高剩得越多（Gemini remainingFraction）
    case creditsBalance(amount: Decimal, currency: String)  // xAI 预付费余额
    case unknownDenominator(used: Double)                    // 有用量无上限
}

enum Confidence { case exact, estimated }

enum ProbeState {
    case ok
    case stale(since: Date)         // 有缓存值但已过期/接口暂不可用（含 token 过期未刷新）
    case needsAuth                  // 凭证缺失
    case rateLimited(retryAfter: Date?)
    case unavailable(reason: String)
}
```

> UI 统一通过一个 `normalizedSeverity(_ measure:) -> Double`（0=空闲, 1=满）把不同 measure 折算成「紧张度」用于柱高/颜色，转换逻辑集中一处并单测（见第 9 节）。

### 4.2 分层结构（Clean Architecture，每层可独立测试）

```
┌─ Presentation ── SwiftUI MenuBarExtra
│   ├ MenuBarIconRenderer  多柱微型条 NSImage 渲染（见第 8.1 渲染契约）
│   └ 下拉面板：各 provider 一行进度条 + 计划档位 + 重置时间 + 精确/估算标记
├─ Application ─── UsageCoordinator（轮询调度 + 缓存 + 聚合）
│   ├ PollScheduler   定时触发 + 指数退避 + 睡眠/唤醒 + 网络可达性门控（第 7 节）
│   └ SnapshotCache   内存 + 磁盘缓存（仅展示数据，无 token），429/离线回退展示
├─ Domain ──────── UsageProbe 协议 + UsageSnapshot/Window/Measure 模型（纯 Swift，零依赖）
└─ Infrastructure ─ 各 provider 的具体实现 + 共享层
    ├ OpenAIProbe        读 ~/.codex/auth.json → wham/usage
    ├ GeminiProbe        读 ~/.gemini/oauth_creds.json → loadCodeAssist + retrieveUserQuota
    ├ AuthenticatedRequest  共享编排：读凭证 → 查过期 → 请求 → 状态映射（第 4.4）
    ├ CredentialReader   FileManager(明文) / Security.framework(Keychain，批次 2)
    └ HTTPClient         URLSession 封装 + 统一 User-Agent + JWTDecoder
```

### 4.3 文件组织（按功能组织，小文件优先）

```
GQuota/
├── App/                    GQuotaApp.swift, AppDelegate.swift
├── Domain/                 UsageProbe.swift, UsageSnapshot.swift, UsageWindow.swift,
│                           UsageMeasure.swift, ProviderID.swift, ProbeState.swift
├── Application/            UsageCoordinator.swift, PollScheduler.swift, SnapshotCache.swift,
│                           Severity.swift（normalizedSeverity + 阈值常量）
├── Infrastructure/
│   ├── OpenAI/             OpenAIProbe.swift, CodexAuthReader.swift, OpenAIUsageDTO.swift
│   ├── Gemini/             GeminiProbe.swift, GeminiOAuthReader.swift, GeminiQuotaDTO.swift
│   └── Shared/             HTTPClient.swift, AuthenticatedRequest.swift,
│                           CredentialReader.swift, JWTDecoder.swift
├── Presentation/           MenuBarLabel.swift, MenuBarIconRenderer.swift,
│                           MenuBarPanel.swift, ProviderRow.swift, SettingsView.swift
└── Resources/              Assets, Info.plist, GQuota.entitlements（非沙箱，见第 12 节）
```

第一版只实现 `OpenAIProbe` 与 `GeminiProbe`；`Domain`、`Application`、`Presentation` 全部按四家设计。

### 4.4 共享认证编排 `AuthenticatedRequest`（C1）

「读凭证 → 查过期 → 请求 → 映射 ProbeState」的逻辑抽成一个共享模板，每个 Probe 只提供 endpoint + parser，杜绝四份重复。

```
AuthenticatedRequest.run(creds, request, parser):
  1. creds 缺失 → .needsAuth
  2. access_token 过期 → MVP: 返回 .stale（不刷新，见第 7 节）；批次≥1 spike 验证后再加刷新钩子
  3. 发请求（注入 Bearer + 必要 header + User-Agent）
  4. 200 → parser → .ok ；401 → .needsAuth ；429 → .rateLimited(retryAfter)
     5xx/超时/离线 → 抛错（上层保留缓存标 .stale）；解析失败 → .unavailable
```

魔法数（轮询间隔、退避上限、紧张度阈值如 90%）统一放 `Severity.swift` / 配置常量，不内联散落（遵循「无魔法数」规范）。

---

## 5. 数据流

### 5.1 一次轮询周期

```
PollScheduler 触发（已过睡眠/可达性门控）
   → Probe.fetch()  →  AuthenticatedRequest.run(...)
        → CredentialReader 读凭证（过期 → MVP 不刷新，标 .stale）
        → HTTPClient 请求用量接口（注入 User-Agent）
        → 解析 JSON → 映射成 UsageSnapshot（per-window measure + confidence）
   → 成功：写入 SnapshotCache（内存 + 磁盘，无 token）→ 通知 UI 刷新
   → 失败：保留旧 Snapshot，标记 ProbeState → UI 降级展示
```

UI 永远读 `SnapshotCache` 的最新可用值——**网络层与展示层完全解耦**，这是应对 Claude 限流的关键：429/过期时 UI 照常显示上次缓存值，仅加「数据陈旧」标记。App 重启时先显示磁盘缓存，再后台刷新（stale-while-revalidate）。

### 5.2 OpenAI 接入（`OpenAIProbe`，批次 1）

1. 读 `~/.codex/auth.json`（明文 0600）→ 取 `tokens.access_token` + `tokens.account_id`。
2. 计划类型直接 base64url 解 access_token JWT 的 `chatgpt_plan_type` claim（free/plus/pro），无需联网。
3. `GET backend-api/wham/usage`，带 `Authorization: Bearer <token>` + `chatgpt-account-id: <account_id>`。
4. 返回含 5h 窗 + 周窗 + 每模型 used_percent + reset_at + credits 余额 → 映射成多个 `UsageWindow`（5h/周 → `usedFraction`，credits → `creditsBalance`）。
5. access_token ~1h 过期 → **MVP 标 `.stale` + 提示「运行 codex 刷新」，不主动刷新**（见第 7 节）。

> 参考实现：wakamex/codex-cli-usage（注意旧的 `codex/usage` 已 403，实际用 `wham/usage`）、steipete/CodexBar。

### 5.3 Gemini 接入（`GeminiProbe`，批次 1）

1. 读 `~/.gemini/oauth_creds.json`（明文）→ 取 `access_token`/`refresh_token`/`expiry_date`；`settings.json` 判断 auth 类型；当前邮箱在 `google_accounts.json`（亦可 base64 解 id_token JWT）。
2. 先 `POST cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`（body `{"metadata":{"ideType":"GEMINI_CLI","pluginType":"GEMINI"}}`）拿 `cloudaicompanionProject` + tier。**必须拿到 project，否则配额返回假的 100%**。
3. `POST v1internal:retrieveUserQuota`（body `{"project":"<projectId>"}`）→ 返回 buckets：每模型 `remainingFraction` + `resetTime`。
4. 按 modelId 归并（Pro/Flash/Flash-Lite 取每模型最低 fraction）→ 映射成 `UsageWindow`（`remainingFraction`）。**dummy 100% 防线 = project 一级防线**：拿不到/空 `cloudaicompanionProject` → `.unavailable("需配置 GCP 项目")`，绝不进配额查询。**修订（2026-06-12 最终复审 R1）**：不再用「全 bucket remainingFraction==1.0 即 dummy」的二级启发式——它会把「当天还没用过 Gemini 的合法新用户」误报成 unavailable。project 已成功加载时，全 100% 视为合法满额并正常显示。
5. access_token 过期 → **MVP 标 `.stale` + 提示「运行 gemini 刷新」，不主动刷新**（见第 7 节，规避 client_secret 提取与 refresh 轮转风险）。

> 参考实现：tddworks/ClaudeBar 的 `GeminiAPIProbe.swift`（完整跑通全流程）、steipete/CodexBar 的 `docs/gemini.md`（最权威接口对照表）。

### 5.4 Claude 接入（`ClaudeProbe`，批次 2 — 设计预留）

1. 从 Keychain 读 `Claude Code-credentials`（account = 系统用户名）→ 解 `claudeAiOauth.accessToken`/`refreshToken`/`expiresAt`/`subscriptionType`；回退文件 `~/.claude/.credentials.json`(600)。
2. `GET api.anthropic.com/api/oauth/usage`，带 `Authorization: Bearer <token>` + `anthropic-beta: oauth-2025-04-20` + `User-Agent: claude-code/<version>`。
3. 返回 `five_hour`/`seven_day`(/`_opus`/`_sonnet`)/`extra_usage` 的 utilization + resets_at → 映射成 `UsageWindow`（`usedFraction`）。
4. **限流防护（强制）**：轮询间隔 ≥ 5 分钟、指数退避、429 回退展示缓存值、access token 缓存复用。
5. 离线兜底/交叉校验：解析 `~/.claude/projects/*.jsonl` 的 usage 字段按 5h block 聚合（ccusage 做法，input_tokens 占位值=1 不准）。

---

## 6. 错误处理与降级

每个 Probe 把异常映射成 `ProbeState`，UI 永不崩、永远有话说。

| 失败场景 | 处理 | UI 表现 |
|---|---|---|
| 凭证文件不存在 / 未登录 CLI | `.needsAuth` | 该家小柱变灰 + 面板「未检测到 OpenAI 登录」 |
| access_token 过期（MVP 不刷新） | `.stale` | 旧值 + 「数据陈旧 · 运行 codex/gemini 刷新」 |
| 接口 429 限流（Claude 高发） | 保留缓存 + 指数退避加大间隔 | 旧值 + 「数据陈旧 · N 分钟前」灰标 |
| 接口 5xx / 超时 / 离线 | 保留缓存 + 下次轮询重试 | 同上，不打扰 |
| Gemini project 发现失败（假 100%） | 检测 dummy → `.unavailable` | 「需配置 GCP 项目」而非显示假 100% |
| Gemini 403 SERVICE_DISABLED | `.unavailable` | 「Code Assist 未启用」 |
| 接口字段变更（非公开接口下线/改版） | 解析失败 → `.unavailable` + 记日志（脱敏） | 该家「暂不可用」，其他家不受影响 |
| 磁盘缓存损坏 | 忽略损坏项 → 当作冷启动 | 首刷前短暂空白，随即后台拉取 |

**关键原则**：单家失败独立 try/catch，绝不拖垮其他家；凭证与 token 只在内存处理，绝不写回 CLI 文件、绝不上传网络；日志/崩溃报告对 token 脱敏。

---

## 7. 轮询、缓存与刷新策略

- 每家**独立轮询间隔**，默认保守：OpenAI/Gemini 2–5 分钟；Claude（批次 2）≥ 5 分钟 + 指数退避。
- **生命周期门控（A2）**：PollScheduler 订阅 `NSWorkspace` willSleep/didWake——睡眠暂停轮询、唤醒后**延迟到网络就绪再轮询**；`NWPathMonitor` 检测可达性，网络未就绪不发请求。规避唤醒瞬间无谓请求与 Claude 限流误触。
- **MVP 不主动刷新 token（OV2）**：access_token 过期 → 标 `.stale` + 提示用户运行对应 CLI 刷新。原因：若 provider 轮转 refresh token，GQuota 刷新后不写回，会让 CLI 存的旧 token 失效、把用户从 CLI 登出——监控工具绝不能弄坏被监控的 CLI。**「refresh token 是否轮转」列为 Phase 0 spike**，验证安全后再决定是否在后续批次恢复主动刷新（届时 `AuthenticatedRequest` 第 2 步加刷新钩子即可，纯增量）。
- 凭证只读；绝不写回 CLI 凭证文件。
- `SnapshotCache` 磁盘持久化**仅存展示数据（measure/resetsAt/label/fetchedAt），绝不含任何 token**；App 重启瞬间显示上次数据，再后台刷新。
- 退避算法：失败后间隔翻倍至上限；429 带 retry-after 则尊重之；恢复成功后重置为基准间隔。

---

## 8. UI 规格

### 8.1 菜单栏图标（多柱微型条）+ 渲染契约（A1）

- 每家一根小竖柱，高度 = `normalizedSeverity`（0→满），颜色随紧张度变（绿 → 橙 → 红）。
- MVP 两根柱（OpenAI、Gemini），架构容纳至四根。
- **渲染契约**：彩色柱**不能用 template image**（template 仅单色）。用 **non-template 彩色 `NSImage`**，由 `MenuBarIconRenderer` 在每次快照更新后重绘：
  - 柱加**描边 / 半透明背板**，保证在**浅色菜单栏、深色菜单栏、壁纸着色**三种背景下均有对比度。
  - 监听 `NSApp.effectiveAppearance`（及菜单栏外观）变化时重绘。
  - 渲染在后台线程生成位图、主线程赋值；复用缓冲、避免每次新建大对象。
  - 超阈值（如 90%，常量）的柱加红点/高亮提示。

### 8.2 下拉面板

- 顶部：App 名 + 「N 分钟前更新 ↻」+ 手动刷新。
- 每家一行：名称 + 主窗口百分比（粗体着色，按 measure 正确换算「已用/剩余」文案）+ 进度条；子行显示计划档位、重置时间、次要窗口百分比。
- **估算值（`confidence == .estimated`）逐窗加 `~` 前缀或「估算」标签**与精确值区分。
- `.stale` 状态显示「数据陈旧 · 运行 CLI 刷新」；`.needsAuth` 灰显。
- 未支持的提供商灰显「即将支持」占位。
- 底部：设置、立即刷新、退出。

### 8.3 空状态（D5）

| 状态 | 触发 | 菜单栏图标 | 面板 |
|---|---|---|---|
| **冷启动** | 刚打开、首次轮询未回、磁盘无缓存 | 中性占位（单色骨架柱，不上色） | 骨架行 + 「首次检测中…」 |
| **全空** | 一个 CLI 都未登录 | 中性占位图标 | 暖场文案 +「在终端运行 codex / gemini 登录后，这里会显示额度」 |
| **部分空** | 一家在用、一家未登录 | 在用家正常、未登录家灰柱 | 在用家正常行 + 未登录家「未检测到登录」 |

空状态是功能：给方向和下一步，不留空白转圈。

### 8.4 无障碍（D2/D3）

- **严重度双通道（绝不只用颜色）**：每档严重度同时用 颜色 + 图标形状（○ 安全 / ◐ 注意 / ● 危险，或 ⚠ 告警）+ 百分比文字。红绿色盲（约 8% 男性）与黑白显示下仍可辨。菜单栏柱高度本身是冗余编码；面板进度条与 >90% 告警必须补图标/文字。
- **VoiceOver**：菜单栏 `NSStatusItem` 与面板每行提供语义化 `accessibilityLabel`，例：「OpenAI，5 小时窗口已用 72%，1 小时 12 分后重置」；估算值在标签中明示「估算」。严重度跨档变化（如进入 >90%）发 accessibility 通知。
- 面板内可聚焦项支持键盘导航。

### 8.5 设计 Token（D4）

不引入完整 design system，定义一套最小 token，面板与图标统一取用：

- **严重度色阶（3 档 + 图标 + 双外观对比度）**：安全 `--sev-ok`（绿，○）/ 注意 `--sev-warn`（橙，◐）/ 危险 `--sev-danger`（红，●）；每档给出在浅色与深色菜单栏下均达 WCAG 对比度的具体值，菜单栏彩色柱配描边/背板（见 8.1）。
- **间距刻度**：4 / 8 / 12 / 16（面板内边距、行距统一取用）。
- **字体字重层级**：SF Pro 明确层级（provider 名 = semibold、百分比 = bold、子文案 = regular/secondary），不靠 system 默认凑数。
- 落地：`Severity.swift` 统一输出 `(color, iconTier, label)` 三元组，UI 各处只读此输出，杜绝 ad-hoc 取色。

---

## 9. 测试策略（对照 80% 覆盖率要求）

- **单元测试（重点）**：
  - 各 Probe 的响应解析——真实接口 JSON（Phase 0 抓取）存为 fixture，断言映射成 `UsageSnapshot`（边界：缺字段、null、**dummy 100% [CRITICAL]**、403、measure 语义正确）。
  - JWT claim 解码（OpenAI 计划类型）、token 过期判断、5h/周窗口聚合、Gemini 多模型 fraction 归并。
  - `normalizedSeverity` 折算（used/remaining/credits → 紧张度）——杜绝方向性 bug。
  - `SnapshotCache` 的 stale-while-revalidate + 磁盘损坏回退；`PollScheduler` 退避算法、睡眠/唤醒暂停恢复、可达性门控、429 尊重 retry-after（注入假时钟/假通知/假 path monitor，不依赖真实等待）。
  - `AuthenticatedRequest`：缺凭证→needsAuth、过期→stale、200→ok、401→needsAuth、429→rateLimited。
  - `MenuBarIconRenderer`：把「severity → 柱高/颜色档位/阈值」抽成**纯函数单测**（T1）。
- **集成测试**：`URLProtocol` mock 拦截 HTTP，模拟 200/401/429/5xx/超时全链路，验证 `ProbeState` 流转与缓存降级。
- **契约/快照测试**：Phase 0 抓到的真实接口结构固化为 fixture——接口字段变了测试先红，提醒维护（应对非公开接口漂移，这是产品主风险的早警）。
- **手动验收清单**：真实凭证下四象限（已登录/未登录/token 过期/限流）截图验证菜单栏多柱图标 + 面板；**彩色图标在浅/深/壁纸着色三种菜单栏背景下的可读性**走视觉手动验收（T1，不上像素快照，避免 flaky）。
- **无障碍验收**：色盲模拟（红绿/黑白）下严重度仍可辨（D2/T10）；VoiceOver 实读菜单栏项与每行标签（D3/T11）；冷启动/全空/部分空三态走查（D5/T13）。

网络层抽象为 `HTTPClient` 协议 + Probe 注入凭证 → 绝大多数逻辑无需真实账号即可测，这是达成 80% 覆盖率的前提。

---

## 10. 关键技术风险与前置 Spike（Phase 0）

**Phase 0 在搭骨架前先做（OV4），用真实凭证一次性去风险：**

1. **OpenAI/Gemini 接口能否用真凭证跑通**——实打 `wham/usage` 与 `loadCodeAssist`+`retrieveUserQuota`，抓真实 JSON 形状落成测试 fixture。验证「实测 200」对自己账号成立、确认字段。
2. **refresh token 是否轮转**——实测 OpenAI/Google 刷新一次后旧 refresh token 是否失效。决定后续批次能否安全恢复主动刷新；MVP 一律不刷新。
3. **Gemini project 发现**——确认 `loadCodeAssist` 在自己账号能拿到 `cloudaicompanionProject`，dummy 100% 检测分支可触达。

**后续批次的 spike：**

4. **Anthropic OAuth 端点限流是否真会卡死 App**（批次 2 前必验）— 轮询间隔下限、429 缓存降级、token 刷新链路。
5. **macOS Keychain 读取是否触发权限弹窗及频次**（批次 2）— 同进程同用户访问 `Claude Code-credentials` 的实际弹窗行为。OpenAI/Gemini 走明文文件无此问题。

---

## 11. 可借鉴的开源项目

| 项目 | 语言 | 可借鉴点 |
|---|---|---|
| **tddworks/ClaudeBar** | Swift | 架构首选：`UsageProbe` 协议 + 领域模型；`GeminiAPIProbe.swift` 完整跑通 loadCodeAssist→project→retrieveUserQuota→解析 buckets、别名归并、冷启动退避 |
| **steipete/CodexBar** | Swift | 接口权威文档 + 工程范本：`docs/gemini.md`（tier 分类、JWT 取 email）；Codex auth.json→wham/usage 实现；on-device 隐私设计 |
| **wakamex/codex-cli-usage** | Python | OpenAI 实现细节：auth.json→Bearer+chatgpt-account-id→usage、5h/7d 窗解析、daemon 300s 缓存节流 |
| **ryoppippi/ccusage** | TypeScript | 离线兜底标准：解析 `~/.claude/projects/*.jsonl`、按 5h block 聚合、流式去重（批次 2 交叉校验） |

---

## 12. 分发与签名（A4）

- App 读家目录凭证文件（批次 2 还读别的 App 的 Keychain item）→ **无法启用 App Sandbox** → **永远上不了 Mac App Store**，只能 Developer ID 直签分发。
- `GQuota.entitlements` 明确**关闭沙箱**（否则读不到 `~/.codex`、`~/.gemini`）。
- **MVP = 本地 ad-hoc 构建**（Xcode 直接 build & run，零账号成本，先验证自用价值）。
- Developer ID 签名 + `notarytool` 公证 + Sparkle 自动更新**推迟到「想分发给别人」那一刻**。注意：因接口漂移是主风险，**一旦对外分发，快速更新交付（Sparkle）即从可选升级为必备**（codex Finding 2）。

---

## 13. 法律 / ToS 与定位（OV1）

- GQuota 读取本机 CLI 凭证、调用各家**非公开接口**、伪装 User-Agent。OpenAI / Google 的服务条款普遍禁止逆向工程、程序化提取凭证、伪装身份访问、绕过限流。
- **定位：个人自用工具**——只读使用者本人的账号、默认**不公开分发**。自用封号概率低但非零；一旦分发给他人，他人账号同样暴露在该风险下。
- **若未来要公开分发，必须单独重新评估** ToS 与封号风险，并在 UI 明确告知用户风险与「这是非官方、依赖私有接口」的事实。
- 凭证威胁模型（codex Finding 3）：只读已知路径、仅内存处理、磁盘缓存无 token、日志脱敏、不上传网络；首次运行向用户说明「将读取本机 CLI 凭证以查询额度」。

---

## 14. NOT in scope（本次明确不做，附理由）

- **Claude / Grok 接入**——批次 2/4，MVP 聚焦两家全绿数据源。
- **API key 用量/花费侧**——批次 3，需高权限 key，自用门槛高。
- **主动 token 刷新**——OV2，待 Phase 0 验证轮转行为后再议。
- **签名/公证/Sparkle/开机自启**——A4，分发阶段再做；MVP 本地构建。
- **独立窗口 / 历史趋势 / 告警通知**——形态定为纯菜单栏被动展示；告警留作 TODO。
- **像素快照测试**——T1，彩色图标走视觉手动验收，避免 flaky。
- **跨设备同步 / 云账户**——隐私优先，纯本地。

---

## 15. What already exists（复用 vs 重建）

- 全新仓库，无内部代码可复用。
- **外部复用（移植而非重造）**：ClaudeBar（架构与 Gemini 全流程）、CodexBar（接口文档与 OpenAI 实现）、ccusage（JSONL 离线解析，批次 2）。spec 已按「移植成熟方案」组织，未重复造轮子。
- 平台内建优先：MenuBarExtra（菜单栏）、URLSession/TaskGroup（并发轮询）、NWPathMonitor（可达性）、NSWorkspace（睡眠/唤醒）、Security.framework（Keychain）——均用系统能力，无第三方重实现。

---

## 16. 失败模式（每条新代码路径一种现实故障）

| 代码路径 | 现实故障 | 有测试? | 有错误处理? | 用户可见? |
|---|---|---|---|---|
| OpenAIProbe wham/usage | 接口 schema 变更 | 契约测试 | `.unavailable` | 「暂不可用」 |
| GeminiProbe project 发现 | 返回 dummy 100% | 是[CRIT] | dummy 检测→unavailable | 「需配置 GCP 项目」 |
| token 过期（MVP） | access_token 失效 | 是 | `.stale` | 「数据陈旧·刷新」 |
| PollScheduler 唤醒 | 网络未就绪即请求 | 是（假 path） | 可达性门控延迟 | 无（静默等待） |
| MenuBarIconRenderer | 深色菜单栏柱不可见 | 视觉手动验收 | 描边/背板 | 手动核对 |
| SnapshotCache 磁盘 | 缓存文件损坏 | 是 | 忽略→冷启动 | 短暂空白 |

无「无测试 + 无错误处理 + 静默」的关键缺口。

---

## 17. 并行化策略（实现阶段）

Phase 0 spike 完成后，批次 1 内有可并行车道：

| 车道 | 模块 | 依赖 |
|---|---|---|
| A | Domain + Application（协议/模型/Coordinator/Scheduler/Cache/Severity） | — |
| B | Infrastructure/OpenAI | A 的 Domain 协议 |
| C | Infrastructure/Gemini | A 的 Domain 协议 |
| D | Presentation（IconRenderer/Panel/Row） | A 的 Domain 模型 |

执行顺序：先做 A 的 Domain（协议+模型，半天），随后 **B / C / D 三条并行**（各依赖 Domain 接口，互不冲突），最后 A 的 Application 收口接线。Shared 层（HTTPClient/AuthenticatedRequest/JWTDecoder）属 A，B/C 依赖之，需先于 B/C 落地。

---

## 18. 实现任务（由本次审查综合）

- [ ] **T1 (P1)** — Phase 0 — 用真凭证实打 OpenAI/Gemini 接口、抓 JSON fixture、验 refresh 轮转
  - 来源：OV4 + 风险 spike；Verify：拿到真实 JSON 落 fixture，记录轮转结论
- [ ] **T2 (P1)** — Domain — `UsageMeasure` 枚举 + per-window `Confidence` 模型 + `normalizedSeverity`
  - 来源：OV3；Verify：方向性单测（剩 31% ≠ 用 31%）
- [ ] **T3 (P1)** — Shared — `AuthenticatedRequest` 共享编排（含 MVP 不刷新分支）
  - 来源：C1 + OV2；Verify：needsAuth/stale/ok/401/429 单测
- [ ] **T4 (P1)** — Application — `PollScheduler` 睡眠/唤醒 + 可达性门控 + 退避
  - 来源：A2；Verify：假时钟/假通知/假 path monitor 单测
- [ ] **T5 (P1)** — Gemini — dummy 100% 检测 [CRITICAL 回归级]
  - 来源：测试审查；Verify：dummy 输入→unavailable，绝不显示假 100%
- [ ] **T6 (P1)** — Presentation — `MenuBarIconRenderer` 彩色 non-template + 三背景对比度 + 重绘
  - 来源：A1；Verify：纯函数单测 + 三背景视觉手动验收
- [ ] **T7 (P2)** — App — `GQuota.entitlements` 关闭沙箱 + 本地 ad-hoc 构建跑通
  - 来源：A4；Verify：构建产物能读 ~/.codex、~/.gemini
- [ ] **T8 (P2)** — 隐私 — 日志/崩溃 token 脱敏 + 磁盘缓存无 token 断言 + 首启说明
  - 来源：OV1/Finding 3；Verify：缓存文件检视无 token，日志脱敏单测
- [ ] **T9 (P2)** — SnapshotCache — stale-while-revalidate + 磁盘损坏回退
  - 来源：测试审查；Verify：损坏文件→冷启动单测
- [ ] **T10 (P1)** — Presentation/Severity — 严重度双通道（颜色+图标档位+文字），杜绝纯颜色
  - 来源：D2；Verify：Severity 输出 (color,icon,label) 三元组单测；黑白/色盲模拟下可辨手动验收
- [ ] **T11 (P2)** — Presentation — VoiceOver accessibilityLabel（菜单栏项+每行）+ 跨档变化通知
  - 来源：D3；Verify：VoiceOver 实读「provider+窗口+已用/剩余+重置」；标签构造单测
- [ ] **T12 (P2)** — Design Tokens — 严重度色阶/间距/字重 token（Severity.swift 单一来源）
  - 来源：D4；Verify：面板与图标取色一致，深/浅菜单栏对比度达标
- [ ] **T13 (P2)** — Presentation — 冷启动/全空/部分空 三态
  - 来源：D5；Verify：无缓存冷启动显骨架、全空显引导文案

---

## 19. 开放问题（留待实现阶段）

- 多柱图标在四家时的可读性与点击区域（菜单栏宽度有限）。
- 是否需要「告警」（某家 > 90% 时系统通知），还是保持纯被动展示（候选 TODO）。
- 设置项范围：轮询间隔可调？开机自启默认开关？
- Phase 0 验出「refresh 不轮转」后，是否在批次 2 恢复主动刷新。

---

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Codex Review | `/codex review` | Independent 2nd opinion | 1 | issues_found | 6 findings, 4 accepted (OV1-OV4), 2 folded |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | CLEAR | 7 issues raised, 0 unresolved, 0 critical gaps |
| Design Review | `/plan-design-review` | UI/UX gaps | 1 | clean | score 6→9, 4 decisions (D2-D5) |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | — |

- **CODEX**: 6 findings. Accepted 4 as cross-model decisions — OV1 法律/ToS 节、OV2 反转 A3（MVP 不刷新 token）、OV3 重设 UsageWindow 数据模型、OV4 前置 Phase 0 spike。Finding 2（接口漂移→分发前必备更新交付）与 Finding 3（凭证威胁模型/日志脱敏）并入第 12/13 节。
- **CROSS-MODEL**: Eng review 4 项（A1 渲染契约、A2 生命周期门控、A3 刷新兜底、A4 分发姿态）+ C1（DRY 编排）+ T1（图标测试）；codex 补出 ToS 阻断、数据模型有损、刷新弄坏 CLI、过度架构四个 eng review 内部未捕获的盲点。A3 被 OV2 取代。
- **DESIGN**: 聚焦无障碍审查（工具型 UI，跳过营销 pass）。4 决策落入 spec 8.3-8.5 + T10-T13：D2 严重度双通道（色盲安全）、D3 VoiceOver 标签、D4 设计 token、D5 冷启/全空/部分空三态。初始 6/10 → 9/10。
- **UNRESOLVED**: 0。
- **VERDICT**: ENG + DESIGN CLEARED — 架构/测试/性能 + 设计无障碍审查通过，含 codex 外部第二意见，所有决策已落入 spec。可进入 writing-plans。
