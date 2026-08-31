import MCP
import AtmarkCore

/// Rejects any request that does not present a known bearer token.
///
/// Deliberately not the SDK's `BearerTokenValidator`: that one implements OAuth
/// 2.1 resource-server semantics — metadata discovery, audience claims, scope
/// challenges — for tokens issued by an authorization server. Atmark's token is a
/// local secret in a 0600 file on the same machine. Borrowing the OAuth machinery
/// would mean implementing a discovery document and an audience model that
/// describe an authorization server that does not exist.
public struct AtmarkBearerValidator: HTTPRequestValidator {
    private let store: TokenStore

    public init(store: TokenStore) {
        self.store = store
    }

    public func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        guard let token = Self.bearerToken(in: request), store.identity(for: token) != nil else {
            // No hint about which half was wrong, and no WWW-Authenticate
            // challenge: there is nothing for a caller to negotiate, and a
            // distinguishing message would only help something guessing.
            return .error(
                statusCode: 401,
                .invalidRequest("Unauthorized"),
                sessionID: context.sessionID
            )
        }
        return nil
    }

    /// Extracts the token from an `Authorization: Bearer …` header.
    public static func bearerToken(in request: HTTPRequest) -> String? {
        guard let header = request.header("Authorization") else { return nil }
        let parts = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2,
              parts[0].lowercased() == "bearer"
        else { return nil }
        let token = parts[1].trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }
}
