import Testing
import Foundation
@testable import GQuotaKit

@Test func readsExistingJSONFile() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("auth.json")
    try #"{"k":"v"}"#.data(using: .utf8)!.write(to: file)

    let reader = FileCredentialReader(baseDirectory: dir)
    let data = try reader.read(relativePath: "auth.json")
    let obj = try JSONSerialization.jsonObject(with: data) as? [String: String]
    #expect(obj?["k"] == "v")
}

@Test func missingFileThrowsNotFound() {
    let reader = FileCredentialReader(baseDirectory: FileManager.default.temporaryDirectory)
    #expect(throws: CredentialError.notFound) {
        try reader.read(relativePath: "does-not-exist-\(UUID()).json")
    }
}
