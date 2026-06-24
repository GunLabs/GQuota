# TODOS

本文件只记录仍开放、需真机验收或需外部前置条件的事项。已完成的历史复审项压缩归档在底部；详细背景见 `docs/superpowers/specs/2026-06-11-gquota-design.md` 与对应 `docs/superpowers/plans/` 文件。

## 现在仍开放

### 开源前置

- [ ] **开源前安全检查**：2026-06-24 已做本地 `rg`/git history 初扫并安装/运行 `gitleaks`。当前源码中的 Gemini OAuth client secret 已移除；剩余：决定是否重写 git history 中的旧 secret 命中、author email 和历史个人路径。
- [x] **README 开源定位**：已明确这是个人自用、非官方、依赖非公开 provider endpoints 的工具；说明 token 只读、本地处理、无后端上传，以及接口/账号风险。
- [x] **License / 贡献边界**：已添加 MIT `LICENSE`、`CONTRIBUTING.md`，贡献边界和安全报告要求已写入 README / SECURITY。
- [x] **分发声明**：已说明开源代码不等于提供签名构建或自动更新；若未来提供二进制分发，再单独处理 Developer ID、公证、Sparkle 和 ToS/账号风险复审。

### 主动 Token 刷新

- [ ] **OpenAI 主动刷新**：继续保持过期后 `.stale`，不要在一次样本的 Phase 0 结论上直接启用。需要更充分验证 refresh token 不轮转，否则可能把用户的 CLI 登录弄坏。
- [ ] **刷新策略文档对齐**：Gemini 当前已有过期后静默刷新路径和专门测试；旧设计/计划文档仍保留 MVP 阶段「OpenAI/Gemini 一律不刷新」的历史表述，后续需要补一段“当前实现差异”说明。

### 真机验收

- [ ] **Claude 轮询验收**：用 Xcode `Command-R` 跑起来，确认面板显示 Claude 行、多柱菜单栏图标在不同菜单栏背景下可读、VoiceOver 读出 Claude，并观察 5min 轮询不触发 429。
- [ ] **告警通知验收**：真机确认首启授权框、某家额度新进 danger 档（>90%）时收到 macOS 通知；VoiceOver 播报仍不受通知开关影响。

## 需要外部前置条件

- [ ] **Grok / xAI**：暂跳过。只有在用户开通 xAI 开发者 API 并提供 Management key + team_id 后，才重启 `GrokProbe`；消费端 SuperGrok / X Premium 没有官方额度 API，本地日志也缺少可估算的 `updates.jsonl`。
- [ ] **批次 3：OpenAI/Claude Admin 用量/花费侧**：未开始；需要 org admin key，高权限凭证处理需单独设计。

## 已归档完成项

- **2026-06-12 P2/P3 复审项已闭环**：NWPathMonitor 顺序化、refresh 去重/缓存合流、Gemini 请求体安全构造、OpenAI 过期→stale fetch 级测试、P3 清理、`RetryAfterParser` 扩展测试、`GQuota.entitlements` 显式关闭 sandbox、严重度跨档 VoiceOver 播报。
- **Claude 批次 2 代码接入已完成**：`ClaudeProbe`、`ClaudeCredentialSource`（Keychain `Claude Code-credentials` + 文件回退）、DTO、fixture 单测、实时轮询接入、独立轮询间隔与退避、429 `retry-after` 尊重。
- **Claude spike 已完成**：`/api/oauth/usage` 单次真实凭证探测 HTTP 200；校准了 `resets_at` 小数秒、`extra_usage` 可空字段、Keychain 读取链路。
- **告警 / 系统通知后端已完成**：新进 danger 档时投递 `UNUserNotifications`，per-provider 30min 冷却，首启请求授权，并复用 `newlyCritical` 做 VoiceOver 播报。
