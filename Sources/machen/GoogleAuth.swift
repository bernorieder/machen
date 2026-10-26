import AppKit
import CryptoKit
import Network

enum AuthError: LocalizedError {
    case missingClientID
    case denied(String)
    case stateMismatch
    case noRefreshToken
    case missingPermissions
    case notSignedIn
    case sessionExpired
    case timedOut
    case server(code: String, description: String)

    var errorDescription: String? {
        switch self {
        case .missingClientID: "Enter your Google OAuth client ID first."
        case .denied(let reason): "Google sign-in was not completed (\(reason))."
        case .stateMismatch: "The sign-in response didn't match this request. Please try again."
        case .noRefreshToken: "Google didn't return a refresh token. Remove machen at myaccount.google.com/permissions and sign in again."
        case .missingPermissions: "machen needs every permission it asks for: to see your list of calendars, to see and edit your events, and to see and edit your tasks. Please sign in again and allow all of them."
        case .notSignedIn: "Not signed in."
        case .sessionExpired: "The Google session expired. Sign in again in Settings → Sources."
        case .timedOut: "Sign-in timed out."
        case .server(let code, let description): "Google: \(description.isEmpty ? code : description)"
        }
    }
}

/// Google's OAuth 2.0 for installed apps: browser sign-in with PKCE and a loopback redirect, and
/// token refresh. The tokens themselves belong to each `GoogleAccount`.
@MainActor
final class GoogleAuth: ObservableObject {
    /// Only what machen uses. Not full calendar access, which would also allow sharing and
    /// deleting calendars.
    static let scopes = [
        // The calendars you're subscribed to, with their colours and default reminders
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
        // Seeing, adding, changing, moving and deleting events, also in calendars shared with you
        "https://www.googleapis.com/auth/calendar.events",
        // Seeing, adding, changing, completing and deleting tasks
        "https://www.googleapis.com/auth/tasks",
    ]
    /// Full calendar access, which machen 1.x asked for. It covers both calendar scopes above.
    private static let fullCalendarScope = "https://www.googleapis.com/auth/calendar"

    @Published var clientID: String {
        didSet { UserDefaults.standard.set(clientID, forKey: "clientID") }
    }
    @Published var clientSecret: String {
        didSet { UserDefaults.standard.set(clientSecret, forKey: "clientSecret") }
    }
    @Published private(set) var isSigningIn = false

    private var server: LoopbackServer?

    init() {
        clientID = UserDefaults.standard.string(forKey: "clientID") ?? ""
        clientSecret = UserDefaults.standard.string(forKey: "clientSecret") ?? ""
    }

    /// OAuth client built into the app by build.sh from Support/Config.local.plist; empty when absent.
    /// When present, users just sign in; otherwise they enter their own client first.
    static let bundledClientID = Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String ?? ""
    static let bundledClientSecret = Bundle.main.object(forInfoDictionaryKey: "GoogleClientSecret") as? String ?? ""

    var hasBundledClient: Bool { !Self.bundledClientID.isEmpty }
    var canSignIn: Bool { !trimmedClientID.isEmpty }

    private var trimmedClientID: String {
        (hasBundledClient ? Self.bundledClientID : clientID).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var trimmedSecret: String {
        (hasBundledClient ? Self.bundledClientSecret : clientSecret).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Signs in in the browser and returns the tokens of the account the user picked. `hint`, an
    /// address, preselects that account; otherwise Google asks which one, so another can be added.
    func signIn(hint: String? = nil) async throws -> TokenSet {
        guard !trimmedClientID.isEmpty else { throw AuthError.missingClientID }
        isSigningIn = true
        defer { isSigningIn = false }

        server?.stop()
        let server = try LoopbackServer()
        self.server = server
        defer { server.stop() }

        let port = try await server.start()
        let redirect = "http://127.0.0.1:\(port)"
        let verifier = Self.randomToken(32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomToken(16)

        var query = [
            "client_id": trimmedClientID,
            "redirect_uri": redirect,
            "response_type": "code",
            "scope": Self.scopes.joined(separator: " "),
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "state": state,
            "access_type": "offline",
            "prompt": "select_account consent",
        ]
        if let hint, !hint.isEmpty { query["login_hint"] = hint }
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.percentEncodedQueryItems = query.map { URLQueryItem(name: $0.key, value: $0.value.formEscaped) }
        NSWorkspace.shared.open(components.url!)

        let params = try await server.waitForCallback(timeout: 300)
        if let error = params["error"] { throw AuthError.denied(error) }
        guard params["state"] == state, let code = params["code"] else { throw AuthError.stateMismatch }

        var form = [
            "code": code,
            "client_id": trimmedClientID,
            "redirect_uri": redirect,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ]
        if !trimmedSecret.isEmpty { form["client_secret"] = trimmedSecret }
        let response = try await tokenRequest(form)
        guard let refresh = response.refresh_token else { throw AuthError.noRefreshToken }
        // Google lets people untick single permissions on its consent screen
        if let granted = response.scope.map({ Set($0.split(separator: " ").map(String.init)) }),
           !Self.scopes.allSatisfy({ granted.contains($0) || ($0.hasPrefix(Self.fullCalendarScope + ".")
                                                               && granted.contains(Self.fullCalendarScope)) }) {
            throw AuthError.missingPermissions
        }
        return TokenSet(accessToken: response.access_token,
                        refreshToken: refresh,
                        expiry: Date().addingTimeInterval(response.expires_in))
    }

    func cancelSignIn() {
        server?.stop()
    }

    /// Revokes machen's access to the account `refreshToken` belongs to.
    func revoke(_ refreshToken: String) {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("token=\(refreshToken.formEscaped)".utf8)
        URLSession.shared.dataTask(with: req).resume()
    }

    /// New tokens for `current`. Google answers `invalid_grant` when the sign-in is no longer valid.
    func refreshed(_ current: TokenSet) async throws -> TokenSet {
        var form = [
            "client_id": trimmedClientID,
            "refresh_token": current.refreshToken,
            "grant_type": "refresh_token",
        ]
        if !trimmedSecret.isEmpty { form["client_secret"] = trimmedSecret }
        let response = try await tokenRequest(form)
        return TokenSet(accessToken: response.access_token,
                        refreshToken: response.refresh_token ?? current.refreshToken,
                        expiry: Date().addingTimeInterval(response.expires_in))
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Double
        let refresh_token: String?
        /// The permissions granted, separated by spaces.
        let scope: String?
    }

    private struct TokenErrorResponse: Decodable {
        let error: String
        let error_description: String?
    }

    private func tokenRequest(_ form: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(form.map { "\($0.key)=\($0.value.formEscaped)" }.joined(separator: "&").utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        if (response as? HTTPURLResponse)?.statusCode == 200 {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        }
        let err = try? JSONDecoder().decode(TokenErrorResponse.self, from: data)
        throw AuthError.server(code: err?.error ?? "http_error",
                               description: err?.error_description ?? String(decoding: data, as: UTF8.self))
    }

    private static func randomToken(_ byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return Data(bytes).base64URL
    }
}

/// Tiny HTTP listener on 127.0.0.1 that captures the OAuth redirect.
@MainActor
final class LoopbackServer {
    private let listener: NWListener
    private var portContinuation: CheckedContinuation<UInt16, Error>?
    private var callbackContinuation: CheckedContinuation<[String: String], Error>?
    private var pendingResult: Result<[String: String], Error>?

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: params)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            portContinuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.stateChanged(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: .main)
        }
    }

    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        if let pendingResult { return try pendingResult.get() }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            self?.finish(.failure(AuthError.timedOut))
        }
        return try await withCheckedThrowingContinuation { callbackContinuation = $0 }
    }

    func stop() {
        listener.cancel()
        finish(.failure(CancellationError()))
    }

    private func stateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            portContinuation?.resume(returning: listener.port?.rawValue ?? 0)
            portContinuation = nil
        case .failed(let error):
            portContinuation?.resume(throwing: error)
            portContinuation = nil
            finish(.failure(error))
        case .cancelled:
            // Stopped (sign-in cancelled) before the listener was ready
            portContinuation?.resume(throwing: CancellationError())
            portContinuation = nil
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            Task { @MainActor in self?.respond(on: connection, request: data) }
        }
    }

    private func respond(on connection: NWConnection, request data: Data?) {
        let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let target = request.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first ?? ""
        var params: [String: String] = [:]
        for item in URLComponents(string: "http://127.0.0.1\(target)")?.queryItems ?? [] {
            params[item.name] = item.value ?? ""
        }
        let isCallback = params["code"] != nil || params["error"] != nil

        let message = params["error"] == nil
            ? "<h2>machen is connected.</h2><p>You can close this tab and click the menu bar icon.</p>"
            : "<h2>machen isn't connected.</h2><p>Sign-in was cancelled or not allowed. You can close this tab and try again from the menu bar icon.</p>"
        let body = isCallback ? "<html><body style=\"font-family:-apple-system;padding:40px\">\(message)</body></html>" : ""
        let status = isCallback ? "200 OK" : "404 Not Found"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })

        if isCallback { finish(.success(params)) }
    }

    private func finish(_ result: Result<[String: String], Error>) {
        if let callbackContinuation {
            self.callbackContinuation = nil
            callbackContinuation.resume(with: result)
        } else if pendingResult == nil {
            pendingResult = result
        }
    }
}
