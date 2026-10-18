import Foundation

/// Talks to the Stowe backend, which holds the Plaid secret and access tokens.
/// Requests are authorized with the session from Sign in with Apple (`SessionKeychain`).
/// The app never sees an access token — only link tokens and trimmed transactions.
struct PlaidAPIClient {
    enum APIError: LocalizedError {
        case missingBaseURL
        /// No session, or the server rejected it (expired or account deleted). Sign in again.
        case signedOut
        case server(status: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .missingBaseURL: "LEDGERLINE_API_URL is not set in Info.plist."
            case .signedOut: "Please sign in again."
            case let .server(status, message): "Server error \(status): \(message)"
            }
        }
    }

    var baseURL: URL?
    var session: URLSession = .shared

    init(baseURL: URL? = PlaidAPIClient.configuredBaseURL) {
        self.baseURL = baseURL
    }

    static var configuredBaseURL: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "LEDGERLINE_API_URL") as? String).flatMap(URL.init(string:))
    }

    // MARK: Account

    /// Trades a Sign in with Apple identity token for a server session, saved to the Keychain.
    /// `nonce` is the raw value whose SHA-256 was set on the Apple ID request.
    func signIn(identityToken: String, nonce: String) async throws {
        struct Response: Decodable { let session_token: String }
        let r: Response = try await post("auth/apple", body: ["identity_token": identityToken, "nonce": nonce],
                                         authenticated: false)
        SessionKeychain.save(r.session_token)
    }

    /// Disconnects every bank at Plaid and deletes the account on the server.
    func deleteAccount() async throws {
        struct Response: Decodable { let ok: Bool }
        let _: Response = try await post("account/delete", body: [String: String]())
        SessionKeychain.delete()
    }

    // MARK: Plaid

    func createLinkToken() async throws -> String {
        struct Response: Decodable { let link_token: String }
        let r: Response = try await post("link/token", body: [String: String]())
        return r.link_token
    }

    func exchange(publicToken: String) async throws {
        struct Response: Decodable { let ok: Bool }
        let _: Response = try await post("link/exchange", body: ["public_token": publicToken])
    }

    func syncTransactions() async throws -> PlaidSyncResponse {
        try await post("transactions/sync", body: [String: String]())
    }

    // MARK: Plumbing

    private func post<Body: Encodable, Result: Decodable>(_ path: String, body: Body,
                                                          authenticated: Bool = true) async throws -> Result {
        guard let baseURL else { throw APIError.missingBaseURL }
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated {
            guard let token = SessionKeychain.token else { throw APIError.signedOut }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if authenticated && status == 401 {
            SessionKeychain.delete()
            throw APIError.signedOut
        }
        guard (200..<300).contains(status) else {
            throw APIError.server(status: status, message: String(decoding: data, as: UTF8.self))
        }
        return try JSONDecoder().decode(Result.self, from: data)
    }
}
