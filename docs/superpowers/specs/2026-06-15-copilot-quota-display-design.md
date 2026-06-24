# GitHub Copilot 额度显示设计

> 在 GQuota 菜单栏中新增 GitHub Copilot 个人额度显示，复用现有 provider 架构、缓存、轮询、告警和 UI。

- **状态**：设计已确认，待用户审阅
- **日期**：2026-06-15
- **平台**：macOS 13+
- **范围**：个人自用；使用 GitHub 非公开个人额度接口和本机 OAuth token

---

## 1. 目标与非目标

目标是在现有 OpenAI / Gemini / Claude 额度显示之外，新增 GitHub Copilot 一行和一个菜单栏图标分段，让用户能快速看到 Copilot Premium / Chat / Completions 等窗口中最紧张的额度。

本功能保持 GQuota 的既有定位：本地只读凭证、直接请求 provider、失败优雅降级、缓存只存展示数据且不含 token。GitHub Copilot 个人即时额度没有适合个人菜单栏 App 的稳定官方 REST API；官方 Copilot usage metrics 主要面向组织/企业管理员和聚合报表。因此本设计采用公开实现广泛使用、但未公开文档化的个人接口 `GET https://api.github.com/copilot_internal/user`。

非目标：

- 不做组织/企业 Copilot metrics dashboard。
- 不做 GitHub 网页 billing cookie 抓取或预算列表展示。
- 不主动申请或刷新 GitHub token。
- 不把 token 写入 GQuota 缓存、日志或 fixture。

---

## 2. 推荐方案

采用“多来源 token 自动发现 + Copilot 私有用量接口”的方案：

1. 新增 `ProviderID.copilot`。
2. 新增 `CopilotProbe: UsageProbe`。
3. 新增只读 token source，按优先级尝试：
   - 环境变量：`COPILOT_GITHUB_TOKEN`、`GITHUB_TOKEN`、`GH_TOKEN`
   - `gh auth token`
   - `~/.config/github-copilot/apps.json`
   - `~/.config/github-copilot/hosts.json`
   - `~/.config/gh/hosts.yml`
4. 使用 token 请求 `https://api.github.com/copilot_internal/user`。
5. 将响应映射为现有 `UsageSnapshot` / `UsageWindow` / `UsageMeasure`。

备选方案已放弃：

- 只依赖 `gh auth token`：实现最简单，但 GUI App 环境下 PATH 不稳定，且没有安装或登录 `gh` 时零配置失败。
- 内置 GitHub device flow + Keychain：最自洽，但会引入新的授权 UX、token 存储和 scope 决策，超出本次“复用本机登录状态”的目标。

---

## 3. 数据模型与映射

`CopilotProbe` 的 `providerID` 为 `.copilot`，`displayName` 为 `Copilot`。

预期响应字段：

```json
{
  "copilot_plan": "individual_pro",
  "quota_reset_date": "2026-07-01T00:00:00Z",
  "quota_snapshots": {
    "premium_interactions": {
      "percent_remaining": 42,
      "entitlement": 300,
      "remaining": 126
    },
    "chat": {
      "percent_remaining": 90
    },
    "completions": {
      "percent_remaining": 100
    }
  },
  "monthly_quotas": {
    "chat": 300
  },
  "limited_user_quotas": {
    "chat": 270
  }
}
```

映射规则：

- `quota_snapshots.premium_interactions` → `UsageWindow(label: "Premium 请求")`
- `quota_snapshots.chat` → `UsageWindow(label: "Chat")`
- `quota_snapshots.completions` → `UsageWindow(label: "Completions")`
- `percent_remaining` → `UsageMeasure.usedFraction((100 - percent_remaining) / 100)`
- 如果没有 `percent_remaining`，但有 `entitlement` 和 `remaining`，则用 `1 - remaining / entitlement`
- 如果没有 `quota_snapshots`，但有 `monthly_quotas` + `limited_user_quotas`，则作为兼容 fallback 推导剩余额度
- `quota_reset_date` → 每个窗口的 `resetsAt`
- `copilot_plan` → 窗口 `detail`
- 所有窗口 `confidence` 为 `.exact`，但 spec 和 UI 文案保留“私有接口可能漂移”的错误状态

解析必须宽容字段缺失，但不能静默成功：如果没有任何可用窗口，返回 `.unavailable(reason: "Copilot 响应缺少可用额度")`。

---

## 4. 请求与鉴权

请求：

```http
GET https://api.github.com/copilot_internal/user
Authorization: token <github_oauth_token>
Accept: application/json
Editor-Version: vscode/1.96.2
Editor-Plugin-Version: copilot-chat/0.26.7
User-Agent: GitHubCopilotChat/0.26.7
X-Github-Api-Version: 2025-04-01
```

`Authorization` 可在测试中同时覆盖 `token` 与 `Bearer` 格式，但实现默认使用公开实现中最常见的 `token <token>`。如果 401/403，状态映射为 `.needsAuth` 或 `.unavailable(reason: "Copilot token 被拒绝")`，不尝试刷新或修改任何凭证。

`gh auth token` 作为 token source 时通过非交互 subprocess 调用。命令失败、超时或输出为空时继续尝试后续来源，不阻塞其他 provider。

---

## 5. UI 与产品行为

App 接入点：

- `ProviderID.allCases` 增加 `.copilot`
- `AppModel` 的 probes 增加 `CopilotProbe()`
- `configuredProviders` 增加 `.copilot`
- `displayName(for:)` 增加 `Copilot`
- 菜单栏图标自动新增第四段
- 面板自动显示 Copilot 行
- >90% 系统通知与 VoiceOver 播报自动复用现有 `newlyCritical` 逻辑

展示行为：

- 有可用额度：显示最紧张窗口，例如 `⚠ 73%`，详情为 `Premium 请求 · Individual Pro · 下月 1 日重置`
- 无 token：显示 `未检测到登录`，详情提示运行 `gh auth login` 或登录 GitHub Copilot CLI / IDE
- token 被拒绝：显示 `不可用 · Copilot token 被拒绝`
- 限流：显示 `限流中` 并尊重 `Retry-After`
- schema 漂移：显示 `不可用 · Copilot 响应格式已变化`

Copilot 基准轮询间隔沿用 OpenAI/Gemini 的 180 秒；失败后使用现有 per-provider 指数退避，上限 600 秒。

---

## 6. 错误处理与隐私

错误处理遵循现有 provider 约定：

- Copilot 单家失败不能影响 OpenAI / Gemini / Claude。
- 网络错误、5xx、解析失败映射为 `.unavailable`，并由 `UsageCoordinator` 保留旧缓存窗口。
- 429 映射为 `.rateLimited(retryAfter:)`。
- 缺 token 映射为 `.needsAuth`。
- token 被拒绝不写回、不删除、不刷新凭证。

隐私要求：

- token 只在内存中使用。
- `SnapshotCache` 不存 token。
- 测试 fixture 必须脱敏，不能包含 token、用户名、邮箱或组织敏感信息。
- 日志和错误消息不能包含 token 或 token 文件原文。

---

## 7. 测试与验收

实施前先做一次 spike：

1. 在不打印 token 的前提下，从本机 token source 读取 token。
2. 请求 `copilot_internal/user`。
3. 记录 HTTP 状态、可用字段和脱敏后的 fixture。
4. 如果真实 token 返回 401/403，实施仍保留多来源 token 逻辑和手动环境变量路径，但 spec/plan 要记录该风险。

测试覆盖：

- `CopilotCredentialSourceTests`：env、`gh auth token`、`apps.json`、`hosts.json`、`gh/hosts.yml` 的解析优先级和失败 fallback
- `CopilotProbeTests`：200、401/403、429、5xx、无 token、无可用窗口、字段缺失 fallback
- DTO 解析测试：`percent_remaining`、`entitlement + remaining`、`monthly_quotas + limited_user_quotas`
- `ProviderID` / `AppModel` / `ProviderRowPresentation` 测试：排序、显示名、无 token 文案、使用百分比方向
- 回归测试：OpenAI/Gemini/Claude 现有行为不变

验证命令：

```bash
cd GQuotaKit && swift test
xcodebuild -project GQuota.xcodeproj -scheme GQuota -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
```

验收标准：

- 有有效 GitHub OAuth token 时，菜单栏和面板显示 Copilot 额度。
- 无 token 或 token 被拒绝时，只显示 Copilot 的认证/不可用状态，不影响其他 provider。
- 私有接口响应变化时，不崩溃、不误报成功，并保留旧缓存展示。

---

## 8. 实施边界

本功能是一个增量 provider 接入，不需要重做 UI 架构。主要变更范围限定在：

- `GQuotaKit/Sources/GQuotaKit/Domain/ProviderID.swift`
- `GQuotaKit/Sources/GQuotaKit/Infrastructure/Copilot/`
- `GQuota/AppModel.swift`
- `GQuota/ProviderRow.swift` 或相关 display name helper
- 对应测试文件与脱敏 fixture

如果 spike 发现 `copilot_internal/user` 当前不可用，计划应改为“先落 token source + DTO 契约测试骨架，UI 默认隐藏或显示不可用”，而不是引入网页 cookie 抓取。
