import Foundation

struct CodexAuth: Sendable, Equatable {
    struct Tokens: Decodable, Sendable, Equatable {
        let accessToken: String?
        let accountID: String?
        let refreshToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case accountID = "account_id"
            case refreshToken = "refresh_token"
        }
    }

    let tokens: Tokens
}

extension CodexAuth: Decodable {}
