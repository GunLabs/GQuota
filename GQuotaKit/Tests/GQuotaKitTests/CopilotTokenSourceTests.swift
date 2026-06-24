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

private struct SlowCommandRunner: CommandRunner {
    func run(_ executable: String, arguments: [String]) async throws -> String {
        try await Task.sleep(for: .seconds(60))
        return "late-token"
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

@Test func compositeCopilotTokenSourceFallsBackWhenGitHubCLICommandTimesOut() async {
    let source = CompositeCopilotTokenSource(sources: [
        GitHubCLITokenSource(runner: SlowCommandRunner(), timeout: .milliseconds(10)),
        StubTokenSource(value: "fallback-token"),
    ])

    #expect(await source.token() == "fallback-token")
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
