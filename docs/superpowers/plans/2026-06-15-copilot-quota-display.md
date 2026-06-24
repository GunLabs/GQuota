# GitHub Copilot Quota Display Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add GitHub Copilot personal quota display to GQuota's macOS menu bar app.

**Architecture:** Add Copilot as a new `UsageProbe` provider without changing the existing OpenAI/Gemini/Claude probes. Token discovery is isolated in a Copilot infrastructure file, response parsing is isolated in a DTO/mapper file, and app/UI changes only wire `.copilot` into the existing provider ordering, menu bar segments, panel rows, cache, polling, and notification logic.

**Tech Stack:** Swift 6, SwiftPM, Swift Testing, XCTest, SwiftUI/AppKit, `URLSession`, GitHub Copilot internal user API.

---

## Scope Check

The approved spec is one subsystem: a single new provider integrated into the existing GQuota provider architecture. It does not include organization/enterprise Copilot metrics, GitHub web billing scraping, token refresh, or a new login flow.

Implementation should happen directly on `main` in the current repository; do not create a branch or worktree.

## File Structure

- Create: `docs/superpowers/plans/2026-06-15-copilot-spike-findings.md` — sanitized result of the one-time Copilot endpoint spike.
- Create: `GQuotaKit/Tests/GQuotaKitTests/Fixtures/copilot-user.json` — sanitized fixture matching the personal quota response shape.
- Create: `GQuotaKit/Sources/GQuotaKit/Infrastructure/Copilot/CopilotUsageDTO.swift` — DTOs, flexible numeric decoding, and response-to-`UsageWindow` mapping.
- Create: `GQuotaKit/Sources/GQuotaKit/Infrastructure/Copilot/CopilotTokenSource.swift` — read-only token discovery from env, `gh auth token`, Copilot config JSON, and GitHub CLI hosts YAML.
- Create: `GQuotaKit/Sources/GQuotaKit/Infrastructure/Copilot/CopilotProbe.swift` — `UsageProbe` implementation and request construction.
- Create: `GQuotaKit/Tests/GQuotaKitTests/CopilotUsageMapperTests.swift` — parser and quota direction tests.
- Create: `GQuotaKit/Tests/GQuotaKitTests/CopilotTokenSourceTests.swift` — token source priority and parsing tests.
- Create: `GQuotaKit/Tests/GQuotaKitTests/CopilotProbeTests.swift` — fetch, headers, status mapping, retry-after, and parse-failure tests.
- Modify: `GQuotaKit/Sources/GQuotaKit/Domain/ProviderID.swift` — add `.copilot` before creating `CopilotProbe`.
- Modify: `GQuotaKit/Sources/GQuotaKit/Infrastructure/Shared/AuthenticatedRequest.swift` — allow provider-specific auth and parse failure reasons while preserving existing defaults.
- Modify: `GQuota/AppModel.swift` — instantiate `CopilotProbe`, include `.copilot` in configured providers, intervals, backoff caps, display name.
- Modify: `GQuota/MenuBarPanel.swift` — update the all-auth-missing hint so it covers Copilot and GitHub token login paths.
- Modify: `GQuota/ProviderRow.swift` — display name for `.copilot`.
- Modify: `GQuota/AppModelTests.swift` — update provider ordering/menu bar expectations and add Copilot critical alert coverage.
- Modify: `GQuota/MenuBarPanelTests.swift` — cover the updated all-auth-missing hint.
- Modify: `GQuota/ProviderRowTests.swift` — add Copilot presentation display name coverage.
- Modify: `README.md` — mention Copilot credential sources and private endpoint risk.

---

### Task 0: Copilot endpoint spike

**Files:**
- Create: `docs/superpowers/plans/2026-06-15-copilot-spike-findings.md`

- [ ] **Step 1: Run a safe local spike without printing token values**

Run from repository root:

```bash
python3 - <<'PY'
import json
import os
import subprocess
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

def clean(value):
    value = (value or "").strip()
    return value or None

def token_from_env():
    for key in ("COPILOT_GITHUB_TOKEN", "GITHUB_TOKEN", "GH_TOKEN"):
        value = clean(os.environ.get(key))
        if value:
            return key, value
    return None, None

def token_from_gh():
    try:
        proc = subprocess.run(
            ["gh", "auth", "token"],
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except Exception:
        return None, None
    if proc.returncode != 0:
        return None, None
    return "gh auth token", clean(proc.stdout)

def sanitize(value):
    if isinstance(value, dict):
        sanitized = {}
        for key, child in value.items():
            lower = key.lower()
            if "token" in lower or lower in {"email", "login", "name"}:
                sanitized[key] = "<redacted>"
            else:
                sanitized[key] = sanitize(child)
        return sanitized
    if isinstance(value, list):
        return [sanitize(child) for child in value]
    return value

source, token = token_from_env()
if not token:
    source, token = token_from_gh()

result = {
    "checked_at": datetime.now(timezone.utc).isoformat(),
    "token_source": source or "none",
    "http_status": None,
    "has_quota_snapshots": False,
    "has_quota_reset_date": False,
    "has_copilot_plan": False,
    "note": "",
}

sanitized_path = Path("/tmp/gquota-copilot-user-sanitized.json")
if not token:
    result["note"] = "No token found from env or gh auth token."
else:
    request = urllib.request.Request(
        "https://api.github.com/copilot_internal/user",
        headers={
            "Authorization": f"token {token}",
            "Accept": "application/json",
            "Editor-Version": "vscode/1.96.2",
            "Editor-Plugin-Version": "copilot-chat/0.26.7",
            "User-Agent": "GitHubCopilotChat/0.26.7",
            "X-Github-Api-Version": "2025-04-01",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            result["http_status"] = response.status
            body = response.read()
    except urllib.error.HTTPError as error:
        result["http_status"] = error.code
        body = error.read()
    except Exception as error:
        result["note"] = f"Request failed: {type(error).__name__}"
        body = b""

    if body:
        try:
            data = json.loads(body)
            sanitized = sanitize(data)
            result["has_quota_snapshots"] = isinstance(data.get("quota_snapshots"), dict)
            result["has_quota_reset_date"] = "quota_reset_date" in data
            result["has_copilot_plan"] = "copilot_plan" in data
            sanitized_path.write_text(json.dumps(sanitized, indent=2, ensure_ascii=False) + "\n")
        except Exception:
            result["note"] = "Response body was not JSON."

finding = Path("docs/superpowers/plans/2026-06-15-copilot-spike-findings.md")
finding.parent.mkdir(parents=True, exist_ok=True)
finding.write_text(
    "# Copilot endpoint spike findings\n\n"
    f"- Checked at: `{result['checked_at']}`\n"
    f"- Token source: `{result['token_source']}`\n"
    f"- HTTP status: `{result['http_status']}`\n"
    f"- Response has `quota_snapshots`: `{result['has_quota_snapshots']}`\n"
    f"- Response has `quota_reset_date`: `{result['has_quota_reset_date']}`\n"
    f"- Response has `copilot_plan`: `{result['has_copilot_plan']}`\n"
    f"- Sanitized response path: `{sanitized_path if sanitized_path.exists() else 'not written'}`\n"
    f"- Note: `{result['note'] or 'none'}`\n",
    encoding="utf-8",
)
print(finding.read_text(encoding="utf-8"))
PY
```

Expected: command prints a markdown findings document. It must not print any token value.

- [ ] **Step 2: Commit the spike findings**

Run:

```bash
git add docs/superpowers/plans/2026-06-15-copilot-spike-findings.md
git commit -m "docs: record Copilot quota endpoint spike" -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

Expected: commit succeeds with one new findings file.

---

### Task 1: Copilot usage DTO and mapper

**Files:**
- Create: `GQuotaKit/Tests/GQuotaKitTests/Fixtures/copilot-user.json`
- Create: `GQuotaKit/Tests/GQuotaKitTests/CopilotUsageMapperTests.swift`
- Create: `GQuotaKit/Sources/GQuotaKit/Infrastructure/Copilot/CopilotUsageDTO.swift`

- [ ] **Step 1: Add the sanitized fixture**

Create `GQuotaKit/Tests/GQuotaKitTests/Fixtures/copilot-user.json`:

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
      "percent_remaining": "90"
    },
    "completions": {
      "percent_remaining": 100
    }
  },
  "monthly_quotas": {
    "legacy": 100
  },
  "limited_user_quotas": {
    "legacy": 25
  }
}
```

- [ ] **Step 2: Write failing mapper tests**

Create `GQuotaKit/Tests/GQuotaKitTests/CopilotUsageMapperTests.swift`:

```swift
import Foundation
import Testing
@testable import GQuotaKit

private func copilotFixtureData(_ name: String = "copilot-user") throws -> Data {
    let url = try #require(Bundle.module.url(
        forResource: name,
        withExtension: "json",
        subdirectory: "Fixtures"
    ))
    return try Data(contentsOf: url)
}

@Test func copilotMapper_parsesFixturePercentRemainingAsUsedFraction() throws {
    let windows = try CopilotUsageMapper.parse(copilotFixtureData())

    #expect(windows.count == 3)

    let premium = try #require(windows.first { $0.label == "Premium 请求" })
    #expect(premium.measure == .usedFraction(0.58))
    #expect(premium.confidence == .exact)
    #expect(premium.resetsAt == ISO8601DateFormatter().date(from: "2026-07-01T00:00:00Z"))
    #expect(premium.detail == "Individual Pro")

    let chat = try #require(windows.first { $0.label == "Chat" })
    #expect(chat.measure == .usedFraction(0.10))
    #expect(chat.detail == "Individual Pro")

    let completions = try #require(windows.first { $0.label == "Completions" })
    #expect(completions.measure == .usedFraction(0.0))
}

@Test func copilotMapper_usesEntitlementAndRemainingWhenPercentIsMissing() throws {
    let json = """
    {
      "copilot_plan": "business",
      "quota_reset_date": "2026-07-01T00:00:00Z",
      "quota_snapshots": {
        "premium_interactions": {
          "entitlement": "300",
          "remaining": "75"
        }
      }
    }
    """

    let windows = try CopilotUsageMapper.parse(Data(json.utf8))

    #expect(windows.count == 1)
    #expect(windows[0].label == "Premium 请求")
    #expect(windows[0].measure == .usedFraction(0.75))
    #expect(windows[0].detail == "Business")
}

@Test func copilotMapper_usesMonthlyAndLimitedFallbackWhenSnapshotsAreMissing() throws {
    let json = """
    {
      "copilot_plan": "individual_pro",
      "quota_reset_date": "2026-07-01T00:00:00Z",
      "monthly_quotas": {
        "chat": "300",
        "completions": 100
      },
      "limited_user_quotas": {
        "chat": "60",
        "completions": 100
      }
    }
    """

    let windows = try CopilotUsageMapper.parse(Data(json.utf8))

    #expect(windows.count == 2)
    #expect(windows.first { $0.label == "Chat" }?.measure == .usedFraction(0.80))
    #expect(windows.first { $0.label == "Completions" }?.measure == .usedFraction(0.0))
}

@Test func copilotMapper_clampsInvalidPercentages() throws {
    let json = """
    {
      "quota_snapshots": {
        "premium_interactions": { "percent_remaining": -20 },
        "chat": { "percent_remaining": 150 }
      }
    }
    """

    let windows = try CopilotUsageMapper.parse(Data(json.utf8))

    #expect(windows.first { $0.label == "Premium 请求" }?.measure == .usedFraction(1.0))
    #expect(windows.first { $0.label == "Chat" }?.measure == .usedFraction(0.0))
}

@Test func copilotMapper_throwsWhenNoUsableQuotaExists() throws {
    let json = #"{"copilot_plan":"individual_pro","quota_snapshots":{"premium_interactions":{}}}"#

    #expect(throws: CopilotUsageParseError.noUsableQuota) {
        try CopilotUsageMapper.parse(Data(json.utf8))
    }
}
```

- [ ] **Step 3: Run the mapper tests and verify they fail**

Run:

```bash
cd GQuotaKit && swift test --filter CopilotUsageMapperTests
```

Expected: FAIL because `CopilotUsageMapper` and `CopilotUsageParseError` do not exist.

- [ ] **Step 4: Implement DTO and mapper**

Create `GQuotaKit/Sources/GQuotaKit/Infrastructure/Copilot/CopilotUsageDTO.swift`:

```swift
import Foundation

public enum CopilotUsageParseError: Error, Equatable {
    case noUsableQuota
}

struct CopilotUsageDTO: Decodable, Sendable {
    struct QuotaSnapshots: Decodable, Sendable {
        let premiumInteractions: QuotaSnapshot?
        let chat: QuotaSnapshot?
        let completions: QuotaSnapshot?

        enum CodingKeys: String, CodingKey {
            case premiumInteractions = "premium_interactions"
            case chat
            case completions
        }
    }

    struct QuotaSnapshot: Decodable, Sendable {
        let percentRemaining: FlexibleDouble?
        let entitlement: FlexibleDouble?
        let remaining: FlexibleDouble?

        enum CodingKeys: String, CodingKey {
            case percentRemaining = "percent_remaining"
            case entitlement
            case remaining
        }
    }

    let copilotPlan: String?
    let quotaResetDate: String?
    let quotaSnapshots: QuotaSnapshots?
    let monthlyQuotas: [String: FlexibleDouble]?
    let limitedUserQuotas: [String: FlexibleDouble]?

    enum CodingKeys: String, CodingKey {
        case copilotPlan = "copilot_plan"
        case quotaResetDate = "quota_reset_date"
        case quotaSnapshots = "quota_snapshots"
        case monthlyQuotas = "monthly_quotas"
        case limitedUserQuotas = "limited_user_quotas"
    }
}

struct FlexibleDouble: Decodable, Sendable, Equatable {
    let value: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let value = try? container.decode(Double.self), value.isFinite {
            self.value = value
            return
        }

        if let string = try? container.decode(String.self),
           let value = Double(string),
           value.isFinite {
            self.value = value
            return
        }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Expected finite number or numeric string"
        )
    }
}

public enum CopilotUsageMapper {
    public static func parse(_ data: Data) throws -> [UsageWindow] {
        let dto = try JSONDecoder().decode(CopilotUsageDTO.self, from: data)
        let resetsAt = parseDate(dto.quotaResetDate)
        let detail = normalizedPlan(dto.copilotPlan)
        var windows: [UsageWindow] = []

        let snapshots: [(key: String, snapshot: CopilotUsageDTO.QuotaSnapshot?)] = [
            ("premium_interactions", dto.quotaSnapshots?.premiumInteractions),
            ("chat", dto.quotaSnapshots?.chat),
            ("completions", dto.quotaSnapshots?.completions),
        ]

        for entry in snapshots {
            guard let snapshot = entry.snapshot,
                  let usedFraction = usedFraction(from: snapshot)
            else { continue }

            windows.append(UsageWindow(
                label: label(for: entry.key),
                measure: .usedFraction(usedFraction),
                resetsAt: resetsAt,
                confidence: .exact,
                detail: detail
            ))
        }

        if windows.isEmpty {
            windows.append(contentsOf: fallbackWindows(
                monthlyQuotas: dto.monthlyQuotas ?? [:],
                limitedUserQuotas: dto.limitedUserQuotas ?? [:],
                resetsAt: resetsAt,
                detail: detail
            ))
        }

        guard windows.isEmpty == false else {
            throw CopilotUsageParseError.noUsableQuota
        }

        return windows
    }

    private static func fallbackWindows(
        monthlyQuotas: [String: FlexibleDouble],
        limitedUserQuotas: [String: FlexibleDouble],
        resetsAt: Date?,
        detail: String?
    ) -> [UsageWindow] {
        let preferredKeys = ["premium_interactions", "chat", "completions"]
        let sortedKeys = preferredKeys + monthlyQuotas.keys.sorted().filter { preferredKeys.contains($0) == false }

        return sortedKeys.compactMap { key in
            guard let monthly = monthlyQuotas[key]?.value,
                  let limited = limitedUserQuotas[key]?.value,
                  monthly > 0
            else { return nil }

            return UsageWindow(
                label: label(for: key),
                measure: .usedFraction(clamp(1 - limited / monthly)),
                resetsAt: resetsAt,
                confidence: .exact,
                detail: detail
            )
        }
    }

    private static func usedFraction(from snapshot: CopilotUsageDTO.QuotaSnapshot) -> Double? {
        if let percentRemaining = snapshot.percentRemaining?.value {
            return clamp((100 - percentRemaining) / 100)
        }

        guard let entitlement = snapshot.entitlement?.value,
              entitlement > 0,
              let remaining = snapshot.remaining?.value
        else { return nil }

        return clamp(1 - remaining / entitlement)
    }

    private static func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    private static func label(for key: String) -> String {
        switch key {
        case "premium_interactions":
            return "Premium 请求"
        case "chat":
            return "Chat"
        case "completions":
            return "Completions"
        default:
            return key
                .split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    private static func normalizedPlan(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.isEmpty == false
        else { return nil }

        return value
            .split { $0 == "_" || $0 == "-" || $0 == " " }
            .map { part in part.prefix(1).uppercased() + part.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }

        let standard = ISO8601DateFormatter()
        if let date = standard.date(from: value) {
            return date
        }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value)
    }
}
```

- [ ] **Step 5: Run the mapper tests and verify they pass**

Run:

```bash
cd GQuotaKit && swift test --filter CopilotUsageMapperTests
```

Expected: PASS for all `CopilotUsageMapperTests`.

- [ ] **Step 6: Commit mapper work**

Run:

```bash
git add GQuotaKit/Sources/GQuotaKit/Infrastructure/Copilot/CopilotUsageDTO.swift GQuotaKit/Tests/GQuotaKitTests/CopilotUsageMapperTests.swift GQuotaKit/Tests/GQuotaKitTests/Fixtures/copilot-user.json
git commit -m "feat: parse Copilot quota response" -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

Expected: commit succeeds.

---

### Task 2: Copilot token discovery

**Files:**
- Create: `GQuotaKit/Tests/GQuotaKitTests/CopilotTokenSourceTests.swift`
- Create: `GQuotaKit/Sources/GQuotaKit/Infrastructure/Copilot/CopilotTokenSource.swift`

- [ ] **Step 1: Write failing token source tests**

Create `GQuotaKit/Tests/GQuotaKitTests/CopilotTokenSourceTests.swift`:

```swift
import Foundation
import Testing
@testable import GQuotaKit

private enum TokenSourceTestError: Error {
    case commandFailed
}

private func temporaryCopilotDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func writeFile(baseDirectory: URL, relativePath: String, contents: String) throws {
    let url = baseDirectory.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(contents.utf8).write(to: url)
}

private struct StubCommandRunner: CommandRunner {
    let result: Result<String, Error>

    func run(_ executable: String, arguments: [String]) async throws -> String {
        #expect(executable == "gh")
        #expect(arguments == ["auth", "token"])
        return try result.get()
    }
}

private struct StubTokenSource: CopilotTokenSource {
    let value: String?

    func token() async -> String? {
        value
    }
}

@Test func environmentCopilotTokenSourceUsesConfiguredPriority() async {
    let source = EnvironmentCopilotTokenSource { key in
        [
            "GH_TOKEN": "gh-token",
            "GITHUB_TOKEN": "github-token",
            "COPILOT_GITHUB_TOKEN": "copilot-token",
        ][key]
    }

    #expect(await source.token() == "copilot-token")
}

@Test func githubCLITokenSourceTrimsOutputAndIgnoresEmptyOutput() async {
    let source = GitHubCLITokenSource(runner: StubCommandRunner(result: .success("  gh-token\n")))
    #expect(await source.token() == "gh-token")

    let empty = GitHubCLITokenSource(runner: StubCommandRunner(result: .success("\n")))
    #expect(await empty.token() == nil)
}

@Test func githubCLITokenSourceReturnsNilOnCommandFailure() async {
    let source = GitHubCLITokenSource(runner: StubCommandRunner(result: .failure(TokenSourceTestError.commandFailed)))
    #expect(await source.token() == nil)
}

@Test func fileCopilotTokenSourceReadsNestedAppsJson() async throws {
    let dir = try temporaryCopilotDirectory()
    try writeFile(
        baseDirectory: dir,
        relativePath: ".config/github-copilot/apps.json",
        contents: """
        {
          "github.com": {
            "user": "octocat",
            "oauth_token": "apps-token"
          }
        }
        """
    )

    let source = FileCopilotTokenSource(credentialReader: FileCredentialReader(baseDirectory: dir))
    #expect(await source.token() == "apps-token")
}

@Test func fileCopilotTokenSourceReadsHostsJsonWhenAppsJsonMissing() async throws {
    let dir = try temporaryCopilotDirectory()
    try writeFile(
        baseDirectory: dir,
        relativePath: ".config/github-copilot/hosts.json",
        contents: """
        {
          "github.com": {
            "access_token": "hosts-json-token"
          }
        }
        """
    )

    let source = FileCopilotTokenSource(credentialReader: FileCredentialReader(baseDirectory: dir))
    #expect(await source.token() == "hosts-json-token")
}

@Test func fileCopilotTokenSourceReadsGitHubCLIHostsYaml() async throws {
    let dir = try temporaryCopilotDirectory()
    try writeFile(
        baseDirectory: dir,
        relativePath: ".config/gh/hosts.yml",
        contents: """
        github.com:
          user: octocat
          oauth_token: yaml-token
        """
    )

    let source = FileCopilotTokenSource(credentialReader: FileCredentialReader(baseDirectory: dir))
    #expect(await source.token() == "yaml-token")
}

@Test func compositeCopilotTokenSourceStopsAtFirstNonEmptyToken() async {
    let source = CompositeCopilotTokenSource(sources: [
        StubTokenSource(value: nil),
        StubTokenSource(value: "first-token"),
        StubTokenSource(value: "second-token"),
    ])

    #expect(await source.token() == "first-token")
}
```

- [ ] **Step 2: Run token source tests and verify they fail**

Run:

```bash
cd GQuotaKit && swift test --filter CopilotTokenSourceTests
```

Expected: FAIL because `CopilotTokenSource`, `CommandRunner`, and concrete source types do not exist.

- [ ] **Step 3: Implement token discovery**

Create `GQuotaKit/Sources/GQuotaKit/Infrastructure/Copilot/CopilotTokenSource.swift`:

```swift
import Foundation

public protocol CopilotTokenSource: Sendable {
    func token() async -> String?
}

public struct CompositeCopilotTokenSource: CopilotTokenSource {
    private let sources: [any CopilotTokenSource]

    public init(sources: [any CopilotTokenSource]) {
        self.sources = sources
    }

    public func token() async -> String? {
        for source in sources {
            if let token = await source.token() {
                return token
            }
        }

        return nil
    }
}

public struct DefaultCopilotTokenSource: CopilotTokenSource {
    private let source: CompositeCopilotTokenSource

    public init(
        credentialReader: CredentialReader = FileCredentialReader(),
        commandRunner: any CommandRunner = ProcessCommandRunner()
    ) {
        self.source = CompositeCopilotTokenSource(sources: [
            EnvironmentCopilotTokenSource(),
            GitHubCLITokenSource(runner: commandRunner),
            FileCopilotTokenSource(credentialReader: credentialReader),
        ])
    }

    public func token() async -> String? {
        await source.token()
    }
}

public struct EnvironmentCopilotTokenSource: CopilotTokenSource {
    private let environment: @Sendable (String) -> String?
    private let keys = ["COPILOT_GITHUB_TOKEN", "GITHUB_TOKEN", "GH_TOKEN"]

    public init(environment: @escaping @Sendable (String) -> String? = { ProcessInfo.processInfo.environment[$0] }) {
        self.environment = environment
    }

    public func token() async -> String? {
        for key in keys {
            if let token = Self.clean(environment(key)) {
                return token
            }
        }

        return nil
    }

    static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

public protocol CommandRunner: Sendable {
    func run(_ executable: String, arguments: [String]) async throws -> String
}

public struct ProcessCommandRunner: CommandRunner {
    public init() {}

    public func run(_ executable: String, arguments: [String]) async throws -> String {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments

            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()

            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                throw CredentialError.notFound
            }

            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        }.value
    }
}

public struct GitHubCLITokenSource: CopilotTokenSource {
    private let runner: any CommandRunner

    public init(runner: any CommandRunner = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func token() async -> String? {
        guard let output = try? await runner.run("gh", arguments: ["auth", "token"]) else {
            return nil
        }

        return EnvironmentCopilotTokenSource.clean(output)
    }
}

public struct FileCopilotTokenSource: CopilotTokenSource {
    private let credentialReader: CredentialReader
    private let jsonPaths = [
        ".config/github-copilot/apps.json",
        ".config/github-copilot/hosts.json",
    ]
    private let yamlPaths = [
        ".config/gh/hosts.yml",
    ]

    public init(credentialReader: CredentialReader = FileCredentialReader()) {
        self.credentialReader = credentialReader
    }

    public func token() async -> String? {
        for path in jsonPaths {
            guard let data = try? credentialReader.read(relativePath: path) else { continue }
            if let token = JSONTokenExtractor.token(from: data) {
                return token
            }
        }

        for path in yamlPaths {
            guard let data = try? credentialReader.read(relativePath: path),
                  let text = String(data: data, encoding: .utf8)
            else { continue }
            if let token = YAMLTokenExtractor.oauthToken(from: text) {
                return token
            }
        }

        return nil
    }
}

private enum JSONTokenExtractor {
    static func token(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        return token(from: object)
    }

    private static func token(from object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            for key in ["oauth_token", "access_token", "token"] {
                if let token = EnvironmentCopilotTokenSource.clean(dictionary[key] as? String) {
                    return token
                }
            }

            for value in dictionary.values {
                if let token = token(from: value) {
                    return token
                }
            }
        }

        if let array = object as? [Any] {
            for value in array {
                if let token = token(from: value) {
                    return token
                }
            }
        }

        return nil
    }
}

private enum YAMLTokenExtractor {
    static func oauthToken(from text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("oauth_token:") else { continue }
            let value = String(trimmed.dropFirst("oauth_token:".count))
            return EnvironmentCopilotTokenSource.clean(value)
        }

        return nil
    }
}
```

- [ ] **Step 4: Run token source tests and verify they pass**

Run:

```bash
cd GQuotaKit && swift test --filter CopilotTokenSourceTests
```

Expected: PASS for all `CopilotTokenSourceTests`.

- [ ] **Step 5: Commit token discovery work**

Run:

```bash
git add GQuotaKit/Sources/GQuotaKit/Infrastructure/Copilot/CopilotTokenSource.swift GQuotaKit/Tests/GQuotaKitTests/CopilotTokenSourceTests.swift
git commit -m "feat: discover Copilot tokens locally" -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

Expected: commit succeeds.

---

### Task 3: Copilot probe and provider-specific failure messages

**Files:**
- Modify: `GQuotaKit/Sources/GQuotaKit/Domain/ProviderID.swift`
- Create: `GQuotaKit/Tests/GQuotaKitTests/CopilotProbeTests.swift`
- Create: `GQuotaKit/Sources/GQuotaKit/Infrastructure/Copilot/CopilotProbe.swift`
- Modify: `GQuotaKit/Sources/GQuotaKit/Infrastructure/Shared/AuthenticatedRequest.swift`

- [ ] **Step 1: Write failing probe tests**

Create `GQuotaKit/Tests/GQuotaKitTests/CopilotProbeTests.swift`:

```swift
import Foundation
import Testing
@testable import GQuotaKit

private func copilotFixtureData() throws -> Data {
    let url = try #require(Bundle.module.url(
        forResource: "copilot-user",
        withExtension: "json",
        subdirectory: "Fixtures"
    ))
    return try Data(contentsOf: url)
}

private struct StaticCopilotTokenSource: CopilotTokenSource {
    let value: String?

    func token() async -> String? {
        value
    }
}

private final class CopilotCapturingHTTPClient: HTTPClient, @unchecked Sendable {
    struct Response: Sendable {
        let status: Int
        let body: Data
        let headers: [String: String]

        init(status: Int, body: Data, headers: [String: String] = [:]) {
            self.status = status
            self.body = body
            self.headers = headers
        }
    }

    private actor Store {
        var requests: [URLRequest] = []
        var index = 0

        func append(_ request: URLRequest) {
            requests.append(request)
        }

        func next(from responses: [Response]) -> Response {
            let response = responses[min(index, responses.count - 1)]
            index += 1
            return response
        }
    }

    private let responses: [Response]
    private let store = Store()

    init(responses: [Response]) {
        self.responses = responses
    }

    var requests: [URLRequest] {
        get async { await store.requests }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await store.append(request)
        let response = await store.next(from: responses)
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: nil,
            headerFields: response.headers
        )!
        return (response.body, http)
    }
}

@Test func copilotProbe_fetchBuildsUsageRequestAndSnapshotsOk() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let client = CopilotCapturingHTTPClient(responses: [
        .init(status: 200, body: try copilotFixtureData()),
    ])
    let probe = CopilotProbe(
        tokenSource: StaticCopilotTokenSource(value: "github-token"),
        client: client,
        now: { now }
    )

    let snapshot = try await probe.fetch()
    let request = try #require(await client.requests.first)

    #expect(snapshot.providerID == .copilot)
    #expect(snapshot.state == .ok)
    #expect(snapshot.fetchedAt == now)
    #expect(snapshot.windows.first { $0.label == "Premium 请求" }?.measure == .usedFraction(0.58))
    #expect(probe.providerID == .copilot)
    #expect(probe.displayName == "Copilot")
    #expect(request.url?.absoluteString == "https://api.github.com/copilot_internal/user")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "token github-token")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(request.value(forHTTPHeaderField: "Editor-Version") == "vscode/1.96.2")
    #expect(request.value(forHTTPHeaderField: "Editor-Plugin-Version") == "copilot-chat/0.26.7")
    #expect(request.value(forHTTPHeaderField: "User-Agent") == "GitHubCopilotChat/0.26.7")
    #expect(request.value(forHTTPHeaderField: "X-Github-Api-Version") == "2025-04-01")
}

@Test func copilotProbe_missingTokenYieldsNeedsAuthWithoutRequest() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let client = CopilotCapturingHTTPClient(responses: [
        .init(status: 200, body: Data()),
    ])
    let probe = CopilotProbe(
        tokenSource: StaticCopilotTokenSource(value: nil),
        client: client,
        now: { now }
    )

    let snapshot = try await probe.fetch()

    #expect(snapshot.providerID == .copilot)
    #expect(snapshot.windows.isEmpty)
    #expect(snapshot.fetchedAt == now)
    #expect(snapshot.state == .needsAuth)
    #expect(await client.requests.isEmpty)
}

@Test func copilotProbe_rejectedTokenYieldsUnavailableReason() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let probe = CopilotProbe(
        tokenSource: StaticCopilotTokenSource(value: "rejected-token"),
        client: CopilotCapturingHTTPClient(responses: [.init(status: 403, body: Data())]),
        now: { now }
    )

    let snapshot = try await probe.fetch()

    #expect(snapshot.state == .unavailable(reason: "Copilot token 被拒绝"))
}

@Test func copilotProbe_429ParsesRetryAfter() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let probe = CopilotProbe(
        tokenSource: StaticCopilotTokenSource(value: "github-token"),
        client: CopilotCapturingHTTPClient(responses: [
            .init(status: 429, body: Data(), headers: ["Retry-After": "90"]),
        ]),
        now: { now }
    )

    let snapshot = try await probe.fetch()

    if case .rateLimited(let retryAfter) = snapshot.state {
        #expect(retryAfter == now.addingTimeInterval(90))
    } else {
        Issue.record("expected .rateLimited")
    }
}

@Test func copilotProbe_parseFailureUsesSchemaDriftReason() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let probe = CopilotProbe(
        tokenSource: StaticCopilotTokenSource(value: "github-token"),
        client: CopilotCapturingHTTPClient(responses: [
            .init(status: 200, body: Data(#"{"quota_snapshots":{"premium_interactions":{}}}"#.utf8)),
        ]),
        now: { now }
    )

    let snapshot = try await probe.fetch()

    #expect(snapshot.state == .unavailable(reason: "Copilot 响应格式已变化"))
}
```

- [ ] **Step 2: Run probe tests and verify they fail**

Run:

```bash
cd GQuotaKit && swift test --filter CopilotProbeTests
```

Expected: FAIL because `.copilot`, `CopilotProbe`, and provider-specific `AuthenticatedRequest.run` failure reasons do not exist.

- [ ] **Step 3: Add `.copilot` to provider identity**

Modify `GQuotaKit/Sources/GQuotaKit/Domain/ProviderID.swift` to:

```swift
public enum ProviderID: String, CaseIterable, Sendable, Codable {
    case openai, gemini, claude, copilot, xai
}
```

- [ ] **Step 4: Extend `AuthenticatedRequest.run` without changing existing callers**

Modify `GQuotaKit/Sources/GQuotaKit/Infrastructure/Shared/AuthenticatedRequest.swift` by replacing the `run` function with:

```swift
    public static func run(
        provider: ProviderID,
        accessToken: String?,
        isExpired: Bool,
        request: (String) -> URLRequest,
        client: HTTPClient,
        now: @escaping @Sendable () -> Date = Date.init,
        parseFailureReason: String = "Parse failed",
        authFailureReason: String? = nil,
        parse: (Data) throws -> [UsageWindow]
    ) async -> AuthOutcome {
        guard let token = accessToken else { return .needsAuth }
        if isExpired { return .stale }

        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await client.send(request(token))
        } catch {
            return .stale
        }

        switch http.statusCode {
        case 200..<300:
            do {
                let windows = try parse(data)
                return .ok(windows)
            } catch {
                return .unavailable(reason: parseFailureReason)
            }
        case 401, 403:
            if let authFailureReason {
                return .unavailable(reason: authFailureReason)
            }
            return .needsAuth
        case 429:
            return .rateLimited(retryAfter: RetryAfterParser.parse(from: http, now: now()))
        default:
            return .unavailable(reason: "HTTP \(http.statusCode)")
        }
    }
```

Existing OpenAI/Gemini/Claude calls compile because the new parameters have defaults.

- [ ] **Step 5: Implement `CopilotProbe`**

Create `GQuotaKit/Sources/GQuotaKit/Infrastructure/Copilot/CopilotProbe.swift`:

```swift
import Foundation

public struct CopilotProbe: UsageProbe {
    public let providerID: ProviderID = .copilot
    public let displayName = "Copilot"

    private let tokenSource: any CopilotTokenSource
    private let client: HTTPClient
    private let now: @Sendable () -> Date

    public init(
        tokenSource: any CopilotTokenSource = DefaultCopilotTokenSource(),
        client: HTTPClient = URLSessionHTTPClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.tokenSource = tokenSource
        self.client = client
        self.now = now
    }

    public func fetch() async throws -> UsageSnapshot {
        let fetchedAt = now()
        guard let token = await tokenSource.token() else {
            return UsageSnapshot(providerID: providerID, windows: [], fetchedAt: fetchedAt, state: .needsAuth)
        }

        let outcome = await AuthenticatedRequest.run(
            provider: providerID,
            accessToken: token,
            isExpired: false,
            request: Self.usageRequest,
            client: client,
            now: { fetchedAt },
            parseFailureReason: "Copilot 响应格式已变化",
            authFailureReason: "Copilot token 被拒绝",
            parse: Self.parse
        )

        return snapshot(from: outcome, fetchedAt: fetchedAt)
    }

    public static func parse(_ data: Data) throws -> [UsageWindow] {
        try CopilotUsageMapper.parse(data)
    }

    private static func usageRequest(accessToken: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.github.com/copilot_internal/user")!)
        request.setValue("token \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("vscode/1.96.2", forHTTPHeaderField: "Editor-Version")
        request.setValue("copilot-chat/0.26.7", forHTTPHeaderField: "Editor-Plugin-Version")
        request.setValue("GitHubCopilotChat/0.26.7", forHTTPHeaderField: "User-Agent")
        request.setValue("2025-04-01", forHTTPHeaderField: "X-Github-Api-Version")
        return request
    }

    private func snapshot(from outcome: AuthOutcome, fetchedAt: Date) -> UsageSnapshot {
        switch outcome {
        case .ok(let windows):
            return UsageSnapshot(providerID: providerID, windows: windows, fetchedAt: fetchedAt, state: .ok)
        case .stale:
            return UsageSnapshot(providerID: providerID, windows: [], fetchedAt: fetchedAt, state: .stale(since: fetchedAt))
        case .needsAuth:
            return UsageSnapshot(providerID: providerID, windows: [], fetchedAt: fetchedAt, state: .needsAuth)
        case .rateLimited(let retryAfter):
            return UsageSnapshot(providerID: providerID, windows: [], fetchedAt: fetchedAt, state: .rateLimited(retryAfter: retryAfter))
        case .unavailable(let reason):
            return UsageSnapshot(providerID: providerID, windows: [], fetchedAt: fetchedAt, state: .unavailable(reason: reason))
        }
    }
}
```

- [ ] **Step 6: Run probe tests and verify they pass**

Run:

```bash
cd GQuotaKit && swift test --filter CopilotProbeTests
```

Expected: PASS for all `CopilotProbeTests`.

- [ ] **Step 7: Run existing provider tests to confirm default behavior is preserved**

Run:

```bash
cd GQuotaKit && swift test --filter OpenAIProbeTests && swift test --filter GeminiProbeTests && swift test --filter ClaudeProbeTests
```

Expected: PASS for all three provider test groups.

- [ ] **Step 8: Commit probe work**

Run:

```bash
git add GQuotaKit/Sources/GQuotaKit/Domain/ProviderID.swift GQuotaKit/Sources/GQuotaKit/Infrastructure/Shared/AuthenticatedRequest.swift GQuotaKit/Sources/GQuotaKit/Infrastructure/Copilot/CopilotProbe.swift GQuotaKit/Tests/GQuotaKitTests/CopilotProbeTests.swift
git commit -m "feat: add Copilot usage probe" -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

Expected: commit succeeds.

---

### Task 4: App and UI wiring

**Files:**
- Modify: `GQuota/AppModel.swift`
- Modify: `GQuota/MenuBarPanel.swift`
- Modify: `GQuota/ProviderRow.swift`
- Modify: `GQuota/AppModelTests.swift`
- Modify: `GQuota/MenuBarPanelTests.swift`
- Modify: `GQuota/ProviderRowTests.swift`

- [ ] **Step 1: Write failing app/UI tests**

Modify `GQuota/AppModelTests.swift`:

1. In `testMenuBarIconSegmentsUseConfiguredProvidersAndNeutralMissingSlots`, replace the comment and expectations with:

```swift
        // configuredProviders = [openai, gemini, claude, copilot] → 四个槽位。
        XCTAssertEqual(
            AppModel.menuBarIconSegments(from: [
                makeSnapshot(providerID: .openai, measures: [.usedFraction(0.80)]),
                makeSnapshot(providerID: .claude, measures: [.usedFraction(0.99)])
            ]),
            [.usage(0.80), .neutral, .usage(0.99), .neutral]   // gemini、copilot 缺失 → neutral
        )

        XCTAssertEqual(
            AppModel.menuBarIconSegments(from: [
                makeSnapshot(providerID: .openai, measures: [.usedFraction(0.25)]),
                makeSnapshot(providerID: .gemini, state: .needsAuth)
            ]),
            [.usage(0.25), .neutral, .neutral, .neutral]       // gemini needsAuth、claude/copilot 缺失 → neutral
        )
```

2. In `testMenuBarIconSegmentsDisplayPreservedFailureWindows`, replace the expected segments with:

```swift
            [.usage(0.72), .usage(0.75), .neutral, .neutral]   // claude、copilot 缺失 → neutral
```

3. In `testMenuBarAccessibilityLabelUsesStateTextForPartialEmptyProvider`, add:

```swift
        XCTAssertTrue(label.contains("Copilot 未检测到登录"))  // copilot 已配置但无快照
```

4. Add this test after `testNewlyCriticalCarriesProviderID`:

```swift
    func testCopilotCriticalAnnouncementUsesCopilotDisplayName() {
        let alerts = AppModel.newlyCritical(
            previous: [makeSnapshot(providerID: .copilot, measures: [.usedFraction(0.50)])],
            current: [makeSnapshot(providerID: .copilot, measures: [.usedFraction(0.95)])]
        )

        XCTAssertEqual(alerts, [AppModel.CriticalAlert(providerID: .copilot, message: "Copilot 已用 95%")])
    }
```

Modify `GQuota/ProviderRowTests.swift` by adding:

```swift
    func testCopilotPresentationUsesCopilotDisplayName() {
        let snapshot = makeSnapshot(
            providerID: .copilot,
            window: UsageWindow(
                label: "Premium 请求",
                measure: .usedFraction(0.58),
                resetsAt: nil,
                confidence: .exact,
                detail: "Individual Pro"
            ),
            state: .ok
        )

        let presentation = ProviderRowPresentation(
            snapshot: snapshot,
            referenceDate: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(presentation.providerName, "Copilot")
        XCTAssertEqual(presentation.statusText, "○ 58%")
        XCTAssertEqual(presentation.detailText, "Premium 请求 · Individual Pro")
        XCTAssertTrue(presentation.accessibilityLabel.contains("Copilot，Premium 请求已用 58%"))
    }
```

Modify `GQuota/MenuBarPanelTests.swift` by adding:

```swift
    func testAllAuthMissingHintMentionsCopilotLoginSources() {
        XCTAssertTrue(MenuBarPanel.allAuthMissingTitle.contains("CLI/IDE"))
        XCTAssertTrue(MenuBarPanel.allAuthMissingHint.contains("codex"))
        XCTAssertTrue(MenuBarPanel.allAuthMissingHint.contains("gemini"))
        XCTAssertTrue(MenuBarPanel.allAuthMissingHint.contains("claude"))
        XCTAssertTrue(MenuBarPanel.allAuthMissingHint.contains("gh"))
        XCTAssertTrue(MenuBarPanel.allAuthMissingHint.contains("GitHub Copilot"))
    }
```

- [ ] **Step 2: Run app/UI tests and verify they fail**

Run:

```bash
xcodebuild -project GQuota.xcodeproj -scheme GQuota -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO -only-testing:GQuotaTests/AppModelTests -only-testing:GQuotaTests/MenuBarPanelTests -only-testing:GQuotaTests/ProviderRowTests
```

Expected: FAIL because `.copilot` is not wired into app display names/provider ordering.

- [ ] **Step 3: Wire Copilot into `AppModel`**

In `GQuota/AppModel.swift`, update the coordinator probes:

```swift
        self.coordinator = UsageCoordinator(
            probes: [OpenAIProbe(), GeminiProbe(), ClaudeProbe(), CopilotProbe()],
            cache: cache
        )
```

Update configured providers:

```swift
    private nonisolated static var configuredProviders: [ProviderID] {
        [.openai, .gemini, .claude, .copilot]
    }
```

Update `baseInterval(for:)`:

```swift
    private nonisolated static func baseInterval(for id: ProviderID) -> TimeInterval {
        switch id {
        case .claude: return 300
        case .openai, .gemini, .copilot, .xai: return 180
        }
    }
```

Update `backoffCap(for:)`:

```swift
    private nonisolated static func backoffCap(for id: ProviderID) -> TimeInterval {
        switch id {
        case .claude: return 1_800
        case .openai, .gemini, .copilot, .xai: return 600
        }
    }
```

Update `displayName(for:)`:

```swift
    private nonisolated static func displayName(for providerID: ProviderID) -> String {
        switch providerID {
        case .openai:
            return "OpenAI"
        case .gemini:
            return "Gemini"
        case .claude:
            return "Claude"
        case .copilot:
            return "Copilot"
        case .xai:
            return "Grok"
        }
    }
```

- [ ] **Step 4: Update all-auth-missing panel copy**

In `GQuota/MenuBarPanel.swift`, add these static strings inside `struct MenuBarPanel` near `ContentState`:

```swift
    static let allAuthMissingTitle = "未检测到已登录的 CLI/IDE"
    static let allAuthMissingHint = "登录 codex / gemini / claude / gh 或 GitHub Copilot CLI/IDE 后，这里会显示额度"
```

Then update `allAuthMissingView` to use them:

```swift
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
```

- [ ] **Step 5: Wire Copilot into `ProviderRowPresentation`**

In `GQuota/ProviderRow.swift`, update `displayName(for:)`:

```swift
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
        case .xai:
            return "Grok"
        }
    }
```

- [ ] **Step 6: Run app/UI tests and verify they pass**

Run:

```bash
xcodebuild -project GQuota.xcodeproj -scheme GQuota -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO -only-testing:GQuotaTests/AppModelTests -only-testing:GQuotaTests/MenuBarPanelTests -only-testing:GQuotaTests/ProviderRowTests
```

Expected: PASS for `AppModelTests`, `MenuBarPanelTests`, and `ProviderRowTests`.

- [ ] **Step 7: Commit app/UI wiring**

Run:

```bash
git add GQuota/AppModel.swift GQuota/MenuBarPanel.swift GQuota/ProviderRow.swift GQuota/AppModelTests.swift GQuota/MenuBarPanelTests.swift GQuota/ProviderRowTests.swift
git commit -m "feat: show Copilot in GQuota UI" -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

Expected: commit succeeds.

---

### Task 5: Documentation and full verification

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update README**

Modify the top section of `README.md` to:

```markdown
# GQuota

macOS 菜单栏 AI 额度监控工具（个人自用）。它读取本机 Codex / Gemini / Claude / GitHub Copilot 的登录状态，查询并展示你自己的订阅配额。

## 本地构建运行

1. 先在本机登录 `codex`、`gemini`、`claude`、`gh` 或 GitHub Copilot CLI/IDE。
2. 用 Xcode 打开 `GQuota.xcodeproj`。
3. 选择 `GQuota` scheme，直接运行（Command-R）。

这是本地 ad-hoc Mac app。MVP 不启用 App Sandbox，因为需要读取本机 CLI/IDE 凭证；也不包含 Developer ID 签名、公证、Sparkle 自动更新或 Mac App Store 分发流程。

## 隐私与定位

- 仅读取本机 `~/.codex`、`~/.gemini`、Claude Keychain、`~/.config/github-copilot`、`~/.config/gh` 或环境变量中的凭证，用来查询当前用户自己的额度。
- token 仅用于直接调用 OpenAI / Google / Anthropic / GitHub provider API 查询额度；不会写回 CLI/IDE 凭证文件、写入缓存或日志，也不会发送到任何 GQuota 后端、非 provider 服务或第三方后端。
- 磁盘缓存只应包含展示数据，不应包含 token。
- 查询依赖 OpenAI / Google / Anthropic / GitHub 的非公开 provider endpoints，接口、鉴权或 schema 都可能随时失效。
- 默认定位为个人自用工具，不公开分发；分发给他人前必须重新评估相关 ToS、账号风险和更新交付机制。
```

Leave the existing test commands below this section unchanged.

- [ ] **Step 2: Commit README update**

Run:

```bash
git add README.md
git commit -m "docs: document Copilot quota support" -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

Expected: commit succeeds.

- [ ] **Step 3: Run full SwiftPM tests**

Run:

```bash
cd GQuotaKit && swift test
```

Expected: PASS.

- [ ] **Step 4: Run full Xcode tests**

Run:

```bash
xcodebuild -project GQuota.xcodeproj -scheme GQuota -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
```

Expected: PASS.

- [ ] **Step 5: Check final git state**

Run:

```bash
git --no-pager status --short
git --no-pager log --oneline -8
```

Expected: only intentional changes are committed, and the recent log includes commits for spike findings, parser, token discovery, probe, UI, and README.

---

## Notes for implementation reviewers

- The Copilot API is private. Treat schema drift as a normal provider failure, not as an app failure.
- Do not log token values or raw credential file contents.
- Do not add a GitHub login flow in this implementation.
- Keep `.xai` dormant; this plan only wires `.copilot`.
- Existing OpenAI/Gemini/Claude behavior must remain unchanged.
