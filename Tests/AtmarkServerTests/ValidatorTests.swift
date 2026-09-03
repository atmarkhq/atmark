import Foundation
import MCP
import AtmarkCore
import Testing

@testable import AtmarkServer

@Suite("Bearer validation")
struct ValidatorTests {
    private static let store = TokenStore.local(token: "good-token")
    private static let validator = AtmarkBearerValidator(store: store)
    private static let context = HTTPValidationContext(httpMethod: "POST")

    private static func request(authorization: String?) -> HTTPRequest {
        HTTPRequest(
            method: "POST",
            headers: authorization.map { ["Authorization": $0] } ?? [:],
            body: nil,
            path: "/mcp"
        )
    }

    @Test("a correct token passes")
    func acceptsGoodToken() {
        #expect(Self.validator.validate(Self.request(authorization: "Bearer good-token"), context: Self.context) == nil)
    }

    @Test("the scheme is matched case-insensitively per RFC 7235")
    func schemeIsCaseInsensitive() {
        #expect(Self.validator.validate(Self.request(authorization: "bearer good-token"), context: Self.context) == nil)
    }

    @Test("a wrong or missing token is 401", arguments: [
        nil, "", "Bearer", "Bearer ", "Bearer wrong-token", "good-token",
        "Basic good-token", "Bearer good-token extra",
    ] as [String?])
    func rejectsBadToken(authorization: String?) {
        let response = Self.validator.validate(Self.request(authorization: authorization), context: Self.context)
        #expect(response?.statusCode == 401)
    }

    @Test("rejection reveals nothing about why")
    func rejectionIsOpaque() {
        let response = Self.validator.validate(Self.request(authorization: "Bearer wrong-token"), context: Self.context)
        let body = String(decoding: response?.bodyData ?? Data(), as: UTF8.self)
        // Nothing for something guessing to work with, and no WWW-Authenticate
        // challenge, since there is no authorization server to negotiate with.
        #expect(!body.contains("good-token"))
        #expect(response?.headers["WWW-Authenticate"] == nil)
    }

    @Test("token extraction handles the forms a client actually sends")
    func extraction() {
        #expect(AtmarkBearerValidator.bearerToken(in: Self.request(authorization: "Bearer abc")) == "abc")
        #expect(AtmarkBearerValidator.bearerToken(in: Self.request(authorization: "BEARER abc")) == "abc")
        #expect(AtmarkBearerValidator.bearerToken(in: Self.request(authorization: nil)) == nil)
        #expect(AtmarkBearerValidator.bearerToken(in: Self.request(authorization: "abc")) == nil)
    }
}

@Suite("Token store and generation")
struct TokenStoreTests {
    @Test("the local store provisions one token that can do everything")
    func localStore() {
        let store = TokenStore.local(token: "t")
        #expect(store.identity(for: "t")?.capabilities == .all)
        #expect(store.identity(for: "other") == nil)
        #expect(store.labels == ["local"])
    }

    @Test("generated tokens are 256 bits of hex and do not repeat")
    func generation() {
        let tokens = (0..<64).map { _ in Token.generate() }
        #expect(tokens.allSatisfy { $0.count == 64 })
        #expect(tokens.allSatisfy { $0.allSatisfy(\.isHexDigit) })
        #expect(Set(tokens).count == tokens.count)
    }

    @Test("labels never expose the tokens themselves")
    func labelsAreSafe() {
        let store = TokenStore(["secret-value": TokenIdentity(label: "local", capabilities: .all)])
        #expect(!store.labels.contains("secret-value"))
    }
}
