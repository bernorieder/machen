import AppKit
import CryptoKit
import Network

struct TokenSet: Codable {
    var accessToken: String
    var refreshToken: String
    var expiry: Date
}

enum AuthError: LocalizedError {
    case missingClientID
    case denied(String)
    case stateMismatch
    case noRefreshToken
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
        case .notSignedIn: "Not signed in."
        case .sessionExpired: "Your Google session expired. Please sign in again."
        case .timedOut: "Sign-in timed out."
        case .server(let code, let description): "Google: \(description.isEmpty ? code : description)"
        }
    }
}

/// OAuth 2.0 for installed apps: browser sign-in with PKCE and a loopback redirect.
@MainActor
final class GoogleAuth: ObservableObject {
    static let scopes = [
        "https://www.googleapis.com/auth/calendar",
        "https://www.googleapis.com/auth/tasks",
    ]

    @Published var clientID: String {
        didSet { UserDefaults.standard.set(clientID, forKey: "clientID") }
    }
    @Published var clientSecret: String {
        didSet { UserDefaults.standard.set(clientSecret, forKey: "clientSecret") }
    }
    @Published private(set) var isSignedIn: Bool
    @Published private(set) var isSigningIn = false

    private var tokens: TokenSet? {
        didSet {
            isSignedIn = tokens != nil
            if let tokens, let data = try? JSONEncoder().encode(tokens) {
                Keychain.set(data, for: "tokens")
            } else {
                Keychain.delete("tokens")
            }
        }
    }
    private var refreshTask: Task<TokenSet, Error>?
    private var server: LoopbackServer?

    init() {
        clientID = UserDefaults.standard.string(forKey: "clientID") ?? ""
        clientSecret = UserDefaults.standard.string(forKey: "clientSecret") ?? ""
        #if SCREENSHOTS
        // The screenshot tool isn't signed as machen, so reading the keychain would prompt.
        let stored: TokenSet? = nil
        #else
        let stored = Keychain.get("tokens").flatMap { try? JSONDecoder().decode(TokenSet.self, from: $0) }
        #endif
        tokens = stored
        isSignedIn = stored != nil
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

    func signIn() async throws {
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

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.percentEncodedQueryItems = [
            "client_id": trimmedClientID,
            "redirect_uri": redirect,
            "response_type": "code",
            "scope": Self.scopes.joined(separator: " "),
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "state": state,
            "access_type": "offline",
            "prompt": "consent",
        ].map { URLQueryItem(name: $0.key, value: $0.value.formEscaped) }
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
        tokens = TokenSet(accessToken: response.access_token,
                          refreshToken: refresh,
                          expiry: Date().addingTimeInterval(response.expires_in))
        NSApp.activate(ignoringOtherApps: true)
    }

    func cancelSignIn() {
        server?.stop()
    }

    func signOut() {
        if let token = tokens?.refreshToken {
            var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data("token=\(token.formEscaped)".utf8)
            URLSession.shared.dataTask(with: req).resume()
        }
        tokens = nil
    }

    /// Returns a valid access token, refreshing it when it is about to expire.
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let current = tokens else { throw AuthError.notSignedIn }
        if !forceRefresh, current.expiry > Date().addingTimeInterval(60) {
            return current.accessToken
        }
        if let refreshTask {
            return try await refreshTask.value.accessToken
        }
        let task = Task { try await self.refreshed(current) }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let new = try await task.value
            tokens = new
            return new.accessToken
        } catch AuthError.server(let code, _) where code == "invalid_grant" {
            tokens = nil
            throw AuthError.sessionExpired
        }
    }

    private func refreshed(_ current: TokenSet) async throws -> TokenSet {
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

        let body = isCallback
            ? "<html><body style=\"font-family:-apple-system;padding:40px\"><h2>machen is connected.</h2><p>You can close this tab and click the menu bar icon.</p></body></html>"
            : ""
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
