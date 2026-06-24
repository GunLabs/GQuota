import Testing
import Foundation
@testable import GQuotaKit

@Test func mockClientReturnsStubbedResponse() async throws {
    let client = MockHTTPClient(responses: [
        .init(status: 200, body: Data(#"{"ok":true}"#.utf8))
    ])
    let (data, resp) = try await client.send(URLRequest(url: URL(string: "https://x.test/u")!))
    #expect(resp.statusCode == 200)
    #expect(String(data: data, encoding: .utf8) == #"{"ok":true}"#)
}

@Test func mockClientReplaysSequence() async throws {
    let client = MockHTTPClient(responses: [
        .init(status: 401, body: Data()),
        .init(status: 200, body: Data("ok".utf8)),
    ])
    let r1 = try await client.send(URLRequest(url: URL(string: "https://x.test")!))
    let r2 = try await client.send(URLRequest(url: URL(string: "https://x.test")!))
    let r3 = try await client.send(URLRequest(url: URL(string: "https://x.test")!))
    #expect(r1.1.statusCode == 401)
    #expect(r2.1.statusCode == 200)
    #expect(r3.1.statusCode == 200)
    #expect(String(data: r3.0, encoding: .utf8) == "ok")
}
