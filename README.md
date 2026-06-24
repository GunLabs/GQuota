# GQuota

macOS 菜单栏 AI 额度监控工具（个人自用）。它读取本机 Codex / Gemini / Claude / GitHub Copilot 的登录状态，查询并展示你自己的订阅配额。

## 开源状态

这个仓库计划开放源码，定位仍是个人自用和自助构建，不提供官方签名二进制、不承诺自动更新，也不代表 OpenAI、Google、Anthropic、GitHub 或 xAI 的官方支持。

本项目采用 MIT License，见 [LICENSE](LICENSE)。

## 本地构建运行

1. 先在本机登录 `codex`、`gemini`、`claude`、`gh` 或 GitHub Copilot CLI/IDE。
2. 用 Xcode 打开 `GQuota.xcodeproj`。
3. 选择 `GQuota` scheme，直接运行（Command-R）。

这是本地 ad-hoc Mac app。MVP 不启用 App Sandbox，因为需要读取本机 CLI/IDE 凭证；也不包含 Developer ID 签名、公证、Sparkle 自动更新或 Mac App Store 分发流程。

Gemini 过期 token 的静默刷新不会在源码中内置 OAuth client secret。如需启用该刷新路径，可在运行环境中提供 `GQUOTA_GEMINI_OAUTH_CLIENT_ID` 和 `GQUOTA_GEMINI_OAUTH_CLIENT_SECRET`；未提供时 Gemini token 过期会降级为数据陈旧，等待用户通过 Gemini CLI 自行刷新。

## 隐私与定位

- 仅读取本机 `~/.codex`、`~/.gemini`、Claude Keychain 或 `~/.claude/.credentials.json`、GitHub Copilot 配置（`~/.config/github-copilot`）、GitHub CLI 凭证（`gh auth token` / `~/.config/gh`）或环境变量中的凭证，用来查询当前用户自己的额度。
- token 仅用于直接调用 OpenAI / Google / Anthropic / GitHub provider API 查询额度；不会写回 CLI/IDE 凭证文件、写入缓存或日志，也不会发送到任何 GQuota 后端、非 provider 服务或第三方后端。
- 磁盘缓存只应包含展示数据，不应包含 token。
- 查询依赖 OpenAI / Google / Anthropic / GitHub 的非公开 provider endpoints，接口、鉴权或 schema 都可能随时失效。
- 这是非官方工具。使用非公开接口和本机 OAuth 凭证可能违反相关服务条款或触发风控；请自行评估账号风险。
- 开源代码不等于分发成品。若未来提供二进制构建，需要单独处理 Developer ID 签名、公证、更新交付和 ToS/账号风险复审。

## 贡献边界

见 [CONTRIBUTING.md](CONTRIBUTING.md)。简要原则：欢迎修复解析、测试、文档和本地隐私问题；不接受会上传凭证、集中代理用户请求、绕过 provider 风控或批量抓取非本人账号数据的改动。

## 测试

核心包：

```bash
cd GQuotaKit && swift test
```

App / Xcode：

```bash
xcodebuild -project GQuota.xcodeproj -scheme GQuota -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
```
