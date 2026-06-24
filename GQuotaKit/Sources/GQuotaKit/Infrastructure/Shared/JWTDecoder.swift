import Foundation

public enum JWTError: Error, Equatable { case malformed }

public enum JWTDecoder {
    /// 解 JWT 第二段（payload），不验签——仅用于本地读自己 token 的 claim。
    public static func decodePayload(_ jwt: String) throws -> [String: Any] {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, let data = Data(base64URLEncoded: String(parts[1])) else {
            throw JWTError.malformed
        }
        do {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw JWTError.malformed
            }
            return obj
        } catch {
            throw JWTError.malformed
        }
    }
}

extension Data {
    init?(base64URLEncoded s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b.append("=") }
        guard let d = Data(base64Encoded: b) else { return nil }
        self = d
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
