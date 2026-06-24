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
        credentialReader: any CredentialReader = FileCredentialReader(),
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
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 10) {
        self.timeout = timeout
    }

    public func run(_ executable: String, arguments: [String]) async throws -> String {
        let timeout = timeout
        return try await Task.detached {
            try runSynchronously(executable, arguments: arguments, timeout: timeout)
        }.value
    }

    private func runSynchronously(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments

        // GUI apps launch with a minimal PATH that omits /usr/local/bin and Homebrew paths.
        // Augment so tools like `gh` installed via Homebrew or pkg can be found.
        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["/usr/local/bin", "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/bin", "/bin"]
        let existingPath = env["PATH"] ?? ""
        let pathParts = existingPath.split(separator: ":").map(String.init)
        let merged = extraPaths.filter { !pathParts.contains($0) } + pathParts
        env["PATH"] = merged.joined(separator: ":")
        process.environment = env

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            termination.signal()
        }

        try process.run()
        let milliseconds = max(0, Int(timeout * 1_000))
        if termination.wait(timeout: .now() + .milliseconds(milliseconds)) == .timedOut {
            process.terminate()
            _ = termination.wait(timeout: .now() + .seconds(1))
            throw CredentialError.notFound
        }

        guard process.terminationStatus == 0 else {
            throw CredentialError.notFound
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private actor TokenLookupRace {
    private var continuation: CheckedContinuation<String?, Never>?
    private var commandTask: Task<String?, Never>?
    private var timeoutTask: Task<Void, Never>?

    func start(
        timeout: Duration,
        operation: @escaping @Sendable () async -> String?,
        continuation: CheckedContinuation<String?, Never>
    ) {
        self.continuation = continuation

        let commandTask = Task<String?, Never> {
            await operation()
        }
        self.commandTask = commandTask

        timeoutTask = Task.detached {
            try? await Task.sleep(for: timeout)
            await self.complete(nil, cancelCommand: true)
        }

        Task.detached {
            let token = await commandTask.value
            await self.complete(token, cancelCommand: false)
        }
    }

    private func complete(_ token: String?, cancelCommand: Bool) {
        guard let continuation else {
            return
        }

        self.continuation = nil
        if cancelCommand {
            commandTask?.cancel()
        }
        timeoutTask?.cancel()
        continuation.resume(returning: token)
    }
}

public struct GitHubCLITokenSource: CopilotTokenSource {
    private let runner: any CommandRunner
    private let timeout: Duration

    public init(runner: any CommandRunner = ProcessCommandRunner(), timeout: Duration = .seconds(10)) {
        self.runner = runner
        self.timeout = timeout
    }

    public func token() async -> String? {
        let runner = runner
        let timeout = timeout

        return await withCheckedContinuation { continuation in
            let race = TokenLookupRace()
            Task {
                await race.start(
                    timeout: timeout,
                    operation: {
                        guard let output = try? await runner.run("gh", arguments: ["auth", "token"]) else {
                            return nil
                        }

                        return EnvironmentCopilotTokenSource.clean(output)
                    },
                    continuation: continuation
                )
            }
        }
    }
}

public struct FileCopilotTokenSource: CopilotTokenSource {
    private let credentialReader: any CredentialReader
    private let jsonPaths = [
        ".config/github-copilot/apps.json",
        ".config/github-copilot/hosts.json",
    ]
    private let yamlPaths = [
        ".config/gh/hosts.yml",
    ]

    public init(credentialReader: any CredentialReader = FileCredentialReader()) {
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
