import Foundation

struct GeminiOAuth: Decodable {
    let access_token: String?
    let refresh_token: String?
    let expiry_date: Double?
}

struct GeminiRefreshResponse: Decodable {
    let access_token: String
    let expires_in: Int?
}

struct GeminiOAuthClient: Sendable {
    let clientID: String
    let clientSecret: String

    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Self? {
        guard let clientID = clean(environment["GQUOTA_GEMINI_OAUTH_CLIENT_ID"]),
              let clientSecret = clean(environment["GQUOTA_GEMINI_OAUTH_CLIENT_SECRET"])
        else {
            return nil
        }

        return Self(clientID: clientID, clientSecret: clientSecret)
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 用 refresh_token 向 Google OAuth2 换取新的 access_token。
/// client_id / client_secret 不进源码；公开构建可通过环境变量注入。
/// 使用 curl 子进程而非 URLSession，避免 GUI app 内 ATS/缓存导致的静默失败。
struct GeminiTokenRefresher {
    private let oauthClient: GeminiOAuthClient?
    private let curl: @Sendable (String) -> String?

    init(
        oauthClient: GeminiOAuthClient? = GeminiOAuthClient.fromEnvironment(),
        curl: @escaping @Sendable (String) -> String? = Self.runCurl
    ) {
        self.oauthClient = oauthClient
        self.curl = curl
    }

    func refresh(refreshToken: String) async -> String? {
        guard let oauthClient else {
            return nil
        }

        let params: [(String, String)] = [
            ("client_id", oauthClient.clientID),
            ("client_secret", oauthClient.clientSecret),
            ("refresh_token", refreshToken),
            ("grant_type", "refresh_token"),
        ]
        let body = params.map { key, value in
            "\(key)=\(Self.formEncode(value))"
        }.joined(separator: "&")

        let output = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            Task.detached { [curl] in
                let result = curl(body)
                continuation.resume(returning: result)
            }
        }

        guard let output,
              let data = output.data(using: .utf8),
              let refreshed = try? JSONDecoder().decode(GeminiRefreshResponse.self, from: data)
        else { return nil }

        return refreshed.access_token
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func runCurl(body: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = [
            "-s", "-X", "POST",
            "https://oauth2.googleapis.com/token",
            "--data", body,
        ]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
