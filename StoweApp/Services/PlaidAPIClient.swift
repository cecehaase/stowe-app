import Foundation

/// Talks to the Ledgerline backend, which holds the Plaid secret and access tokens.
/// The app never sees an access token — only link tokens and trimmed transactions.
struct PlaidAPIClient {
    enum APIError: LocalizedError {
        case missingBaseURL
        case server(status: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .missingBaseURL: "LEDGERLINE_API_URL is not set in Info.plist."
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

    /// Stable per-install identifier sent as `X-User-ID`.
    /// TODO: replace with real authentication before shipping.
    static var userID: String {
        let key = "ledgerlineUserID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    // MARK: Endpoints

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

    private func post<Body: Encodable, Result: Decodable>(_ path: String, body: Body) async throws -> Result {
        guard let baseURL else { throw APIError.missingBaseURL }
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userID, forHTTPHeaderField: "X-User-ID")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw APIError.server(status: status, message: String(decoding: data, as: UTF8.self))
        }
        return try JSONDecoder().decode(Result.self, from: data)
    }
}
