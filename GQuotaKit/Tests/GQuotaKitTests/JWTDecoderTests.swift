import Testing
import Foundation
@testable import GQuotaKit

@Test func decodesPayloadClaim() throws {
    // header.payload.signature；payload = {"chatgpt_plan_type":"plus","x":1}
    let payloadJSON = #"{"chatgpt_plan_type":"plus","x":1}"#
    let b64 = Data(payloadJSON.utf8).base64URLEncodedString()
    let jwt = "aaa.\(b64).bbb"
    let claims = try JWTDecoder.decodePayload(jwt)
    #expect(claims["chatgpt_plan_type"] as? String == "plus")
}

@Test func malformedJWTThrows() {
    #expect(throws: JWTError.malformed) { try JWTDecoder.decodePayload("not-a-jwt") }
}

@Test func invalidJSONPayloadThrowsMalformed() {
    let b64 = Data("not json".utf8).base64URLEncodedString()
    let jwt = "aaa.\(b64).bbb"
    #expect(throws: JWTError.malformed) { try JWTDecoder.decodePayload(jwt) }
}

@Test func emptyPayloadSegmentThrowsMalformed() {
    let fallbackPayload = Data(#"{"x":1}"#.utf8).base64URLEncodedString()
    let jwt = "aaa..\(fallbackPayload)"
    #expect(throws: JWTError.malformed) { try JWTDecoder.decodePayload(jwt) }
}

@Test func nonObjectJSONPayloadThrowsMalformed() {
    let b64 = Data(#"["not","an","object"]"#.utf8).base64URLEncodedString()
    let jwt = "aaa.\(b64).bbb"
    #expect(throws: JWTError.malformed) { try JWTDecoder.decodePayload(jwt) }
}
