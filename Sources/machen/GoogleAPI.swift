import Foundation

/// Date conversions between Google's wire formats and local dates.
enum GDate {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parseDateTime(_ s: String) -> Date? {
        iso.date(from: s) ?? isoFractional.date(from: s)
    }

    /// Parses the "yyyy-MM-dd" prefix as a local calendar day (all-day events, task due dates).
    static func parseDay(_ s: String) -> Date? {
        let parts = s.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func dayString(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 1, c.day ?? 1)
    }

    static func dateTimeString(_ d: Date) -> String {
        iso.string(from: d)
    }

    /// Google Tasks stores only the date part of `due`, always as midnight UTC.
    static func taskDueString(_ d: Date) -> String {
        dayString(d) + "T00:00:00.000Z"
    }
}

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

/// Authorized JSON requests against Google REST APIs, for one account.
@MainActor
final class GoogleAPI {
    /// The account's access token; asked for a fresh one (`true`) after Google rejects a request.
    private let token: (_ forceRefresh: Bool) async throws -> String
    private let session = URLSession(configuration: .ephemeral)

    init(token: @escaping (_ forceRefresh: Bool) async throws -> String) {
        self.token = token
    }

    func get<T: Decodable>(_ url: URL) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await send("GET", url))
    }

    /// `body` is serialized with JSONSerialization so `NSNull()` can clear fields in PATCH requests.
    @discardableResult
    func send(_ method: String, _ url: URL, body: [String: Any]? = nil, retryOnAuthFailure: Bool = true) async throws -> Data {
        let token = try await token(!retryOnAuthFailure)
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
