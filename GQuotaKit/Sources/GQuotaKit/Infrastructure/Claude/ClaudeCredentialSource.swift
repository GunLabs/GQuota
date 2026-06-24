import Foundation
import Security

/// Claude 凭证来源（只读）。返回 `claudeAiOauth` 外层 JSON 字节；无凭证返回 nil。绝不写回。
public protocol ClaudeCredentialSource: Sendable {
    func read() throws -> Data?
}

/// 生产实现：先读 macOS Keychain 通用密码（service `Claude Code-credentials`，account = 系统用户名），
/// 不可用时回退明文文件 `~/.claude/.credentials.json`。
///
/// 注：读取 Keychain 会触发授权弹窗；实际弹窗行为与频次需真机验收（spec 第 10 节 spike 5），
/// 无法在 headless/CI 验证，故本类型不做单测，逻辑测试通过注入 `ClaudeCredentialSource` 替身完成。
public struct KeychainClaudeCredentialSource: ClaudeCredentialSource {
    private let service: String
    private let account: String
    private let fileReader: CredentialReader

    public init(
        service: String = "Claude Code-credentials",
        account: String = NSUserName(),
        fileReader: CredentialReader = FileCredentialReader()
    ) {
        self.service = service
        self.account = account
        self.fileReader = fileReader
    }

    public func read() throws -> Data? {
        if let keychainData = Self.readKeychain(service: service, account: account) {
            return keychainData
        }
        // 回退明文文件（Keychain 不可用 / SSH / headless）。
        return try? fileReader.read(relativePath: ".claude/.credentials.json")
    }

    private static func readKeychain(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return data
    }
}
