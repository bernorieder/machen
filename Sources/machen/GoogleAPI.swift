import Foundation

struct APIError: LocalizedError {
    let status: Int
    let message: String

    var errorDescription: String? { "Google API error \(status): \(message)" }
}

enum Endpoint {
    static func calendar(_ path: String..., query: [String: String?] = [:]) -> URL {
        url("https://www.googleapis.com/calendar/v3", path, query)
    }

    static func tasks(_ path: String..., query: [String: String?] = [:]) -> URL {
        url("https://tasks.googleapis.com/tasks/v1", path, query)
    }

    private static func url(_ base: String, _ path: [String], _ query: [String: String?]) -> URL {
        var c = URLComponents(string: base)!
        c.percentEncodedPath += "/" + path.map(\.pathEscaped).joined(separator: "/")
        let items = query.compactMap { key, value in
            value.map { URLQueryItem(name: key, value: $0.formEscaped) }
        }
        if !items.isEmpty { c.percentEncodedQueryItems = items }
        return c.url!
    }
}

/// Authorized JSON requests against Google REST APIs.
@MainActor
final class GoogleAPI {
    private let auth: GoogleAuth
    private let session = URLSession(configuration: .ephemeral)

    init(auth: GoogleAuth) {
        self.auth = auth
    }

    func get<T: Decodable>(_ url: URL) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await send("GET", url))
    }

    /// `body` is serialized with JSONSerialization so `NSNull()` can clear fields in PATCH requests.
    @discardableResult
    func send(_ method: String, _ url: URL, body: [String: Any]? = nil, retryOnAuthFailure: Bool = true) async throws -> Data {
        let token = try await auth.accessToken(forceRefresh: !retryOnAuthFailure)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401, retryOnAuthFailure {
            return try await send(method, url, body: body, retryOnAuthFailure: false)
        }
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error?.message
            throw APIError(status: status, message: message ?? HTTPURLResponse.localizedString(forStatusCode: status))
        }
        return data
    }

    private struct ErrorBody: Decodable {
        struct Inner: Decodable { let message: String? }
        let error: Inner?
    }
}
