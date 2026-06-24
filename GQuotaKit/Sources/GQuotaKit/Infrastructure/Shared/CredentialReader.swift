import Foundation

public enum CredentialError: Error, Equatable {
    case notFound
    case unreadable
}

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
        do {
            return try Data(contentsOf: url)
        } catch {
            throw CredentialError.unreadable
        }
    }
}
