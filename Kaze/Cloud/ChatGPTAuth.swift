import CryptoKit
import Foundation
import Network
import Security

/// A signed-in ChatGPT connection. Lives only in the Keychain.
nonisolated struct ChatGPTCredentials: Codable, Sendable {
    /// Issued to this install by dynamic client registration on first sign-in.
    var clientId: String
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var subject: String
    var email: String?
    var name: String?
}

nonisolated enum ChatGPTError: LocalizedError {
    case discoveryFailed
    case cancelled
    case callbackFailed
    case stateMismatch
    case denied(String)
    case registrationIncomplete
    case tokenExchangeFailed(String)
    case invalidIdentity
    case notSignedIn
    case sessionExpired
    case requestFailed(Int, String)
    case noModels
    case incompleteResponse

    var errorDescription: String? {
        switch self {
        case .discoveryFailed: "Couldn't reach ChatGPT sign-in. Check your connection."
        case .cancelled: "Sign-in was cancelled."
        case .callbackFailed: "The sign-in page couldn't return to Kaze. Try again."
        case .stateMismatch: "Sign-in came back from an unexpected page. Try again."
        case .denied(let reason): "ChatGPT sign-in was declined (\(reason))."
        case .registrationIncomplete: "ChatGPT didn't finish registering Kaze. Try signing in again."
        case .tokenExchangeFailed(let detail): "ChatGPT sign-in failed: \(detail)"
        case .invalidIdentity: "ChatGPT returned an identity Kaze couldn't verify. Sign in again."
        case .notSignedIn: "Sign in with ChatGPT first."
        case .sessionExpired: "Your ChatGPT session expired. Sign in again."
        case .requestFailed(let status, let detail): "ChatGPT request failed (\(status)): \(detail)"
        case .noModels: "Your ChatGPT plan doesn't offer any models to apps."
        case .incompleteResponse: "ChatGPT stopped before finishing."
        }
    }
}

/// "Sign in with ChatGPT": OAuth 2.0 + OIDC with PKCE, dynamic client
/// registration, and a loopback redirect, so the user's ChatGPT plan pays
/// for Clean Up requests. Written against OpenAI's published protocol.
nonisolated enum ChatGPTOAuth {
    static let issuer = "https://auth.openai.com"
    static let resource = "https://api.openai.com/v1"
    static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    static let appName = "Kaze"
    private static let callbackPath = "/auth/callback"

    private struct Discovery: Decodable {
        let issuer: String
        let authorization_endpoint: String
        let token_endpoint: String
        let revocation_endpoint: String?
    }

    private static func discovery() async throws -> Discovery {
        let url = URL(string: "\(issuer)/.well-known/openid-configuration")!
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let config = try? JSONDecoder().decode(Discovery.self, from: data),
              config.issuer == issuer,
              [config.authorization_endpoint, config.token_endpoint].allSatisfy({ $0.hasPrefix(issuer + "/") })
        else { throw ChatGPTError.discoveryFailed }
        return config
    }

    // MARK: - Sign in

    /// Opens the browser for consent and waits for the redirect.
    static func signIn(previousClientId: String?, loginHint: String?, open: @escaping @Sendable (URL) -> Void) async throws -> ChatGPTCredentials {
        let config = try await discovery()
        let state = randomValue()
        let nonce = randomValue()
        let verifier = randomValue()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded

        let listener = try await LoopbackListener.start(path: callbackPath, state: state)
        defer { listener.stop() }
        let redirectURI = "http://127.0.0.1:\(listener.port)\(callbackPath)"

        var components = URLComponents(string: config.authorization_endpoint)!
        var query = [
            URLQueryItem(name: "client_id", value: previousClientId ?? "dynamic_agent_client"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "resource", value: resource),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
        ]
        if previousClientId == nil { query.append(URLQueryItem(name: "agent_name_hint", value: appName)) }
        if let loginHint { query.append(URLQueryItem(name: "login_hint", value: loginHint)) }
        components.queryItems = query
        open(components.url!)

        let callback = try await listener.result()
        if let error = callback["error"] { throw ChatGPTError.denied(error) }
        guard let code = callback["code"],
              let clientId = callback["client_id"] ?? previousClientId,
              clientId != "dynamic_agent_client",
              clientId.range(of: #"^[A-Za-z0-9_-]{1,200}$"#, options: .regularExpression) != nil
        else { throw ChatGPTError.registrationIncomplete }

        let token = try await tokenRequest(config.token_endpoint, [
            "grant_type": "authorization_code",
            "client_id": clientId,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI,
            "resource": resource,
        ])
        guard let idToken = token["id_token"] as? String else { throw ChatGPTError.invalidIdentity }
        let identity = try verifyIdentity(idToken, clientId: clientId, nonce: nonce)
        return try credentials(from: token, clientId: clientId, identity: identity, previousRefresh: nil)
    }

    static func refresh(_ previous: ChatGPTCredentials) async throws -> ChatGPTCredentials {
        guard let refreshToken = previous.refreshToken else { throw ChatGPTError.sessionExpired }
        let config = try await discovery()
        let token: [String: Any]
        do {
            token = try await tokenRequest(config.token_endpoint, [
                "grant_type": "refresh_token",
                "client_id": previous.clientId,
                "refresh_token": refreshToken,
                "resource": resource,
            ])
        } catch ChatGPTError.tokenExchangeFailed {
            throw ChatGPTError.sessionExpired
        }
        var identity = (subject: previous.subject, email: previous.email, name: previous.name)
        if let idToken = token["id_token"] as? String {
            let refreshed = try verifyIdentity(idToken, clientId: previous.clientId, nonce: nil)
            guard refreshed.subject == previous.subject else { throw ChatGPTError.invalidIdentity }
            identity = refreshed
        }
        return try credentials(from: token, clientId: previous.clientId, identity: identity, previousRefresh: refreshToken)
    }

    /// Ends the session at OpenAI. Best effort: local credentials are removed regardless.
    static func revoke(_ credentials: ChatGPTCredentials) async {
        guard let refreshToken = credentials.refreshToken,
              let config = try? await discovery(),
              let endpoint = config.revocation_endpoint.flatMap(URL.init(string:)) else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(["token": refreshToken, "token_type_hint": "refresh_token", "client_id": credentials.clientId])
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Helpers

    private static func tokenRequest(_ endpoint: String, _ fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formBody(fields)
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let detail = json["error_description"] as? String ?? json["error"] as? String ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
            throw ChatGPTError.tokenExchangeFailed(detail)
        }
        return json
    }

    private static func credentials(from token: [String: Any], clientId: String,
                                    identity: (subject: String, email: String?, name: String?),
                                    previousRefresh: String?) throws -> ChatGPTCredentials {
        guard let access = token["access_token"] as? String, !access.isEmpty,
              (token["token_type"] as? String)?.lowercased() == "bearer",
              let expiresIn = (token["expires_in"] as? NSNumber)?.doubleValue, expiresIn > 0
        else { throw ChatGPTError.tokenExchangeFailed("incomplete credentials") }
        if let scope = token["scope"] as? String, !scope.contains("chatgpt.tokens.use.direct") {
            throw ChatGPTError.denied("plan usage wasn't shared with Kaze")
        }
        return ChatGPTCredentials(
            clientId: clientId,
            accessToken: access,
            refreshToken: token["refresh_token"] as? String ?? previousRefresh,
            expiresAt: Date().addingTimeInterval(expiresIn),
            subject: identity.subject,
            email: identity.email,
            name: identity.name
        )
    }

    /// Checks the ID token's claims. It arrives directly from OpenAI's token
    /// endpoint over TLS, which OpenID Connect accepts in place of verifying
    /// the signature (Core §3.1.3.7).
    private static func verifyIdentity(_ idToken: String, clientId: String, nonce: String?) throws -> (subject: String, email: String?, name: String?) {
        let parts = idToken.split(separator: ".")
        guard parts.count == 3, let payload = Data(base64URLEncoded: String(parts[1])),
              let claims = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              claims["iss"] as? String == issuer,
              let subject = claims["sub"] as? String, !subject.isEmpty,
              let exp = (claims["exp"] as? NSNumber)?.doubleValue, exp > Date().timeIntervalSince1970 - 5
        else { throw ChatGPTError.invalidIdentity }
        let audience: [String] = (claims["aud"] as? [String]) ?? [(claims["aud"] as? String)].compactMap { $0 }
        guard audience.contains(clientId) else { throw ChatGPTError.invalidIdentity }
        if let azp = claims["azp"] as? String, azp != clientId { throw ChatGPTError.invalidIdentity }
        if let nonce, claims["nonce"] as? String != nonce { throw ChatGPTError.invalidIdentity }
        return (subject, claims["email"] as? String, claims["name"] as? String)
    }

    private static func randomValue() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded
    }

    private static func formBody(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)!
    }
}

/// A one-shot HTTP listener on 127.0.0.1 that receives the OAuth redirect.
nonisolated final class LoopbackListener: @unchecked Sendable {
    private let listener: NWListener
    private let path: String
    private let state: String
    private let queue = DispatchQueue(label: "com.kaze.chatgpt.callback")
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var pending: Result<[String: String], Error>?
    private(set) var port: UInt16 = 0

    private init(listener: NWListener, path: String, state: String) {
        self.listener = listener
        self.path = path
        self.state = state
    }

    static func start(path: String, state: String) async throws -> LoopbackListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.acceptLocalOnly = true
        let nw = try NWListener(using: parameters)
        let instance = LoopbackListener(listener: nw, path: path, state: state)
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            var resumed = false
            nw.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    instance.port = nw.port?.rawValue ?? 0
                    ready.resume()
                case .failed:
                    resumed = true
                    ready.resume(throwing: ChatGPTError.callbackFailed)
                default:
                    break
                }
            }
            nw.newConnectionHandler = { connection in instance.handle(connection) }
            nw.start(queue: instance.queue)
        }
        return instance
    }

    /// Waits for the redirect's query parameters (up to 5 minutes).
    func result() async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    if let pending {
                        continuation.resume(with: pending)
                        self.pending = nil
                    } else {
                        self.continuation = continuation
                        queue.asyncAfter(deadline: .now() + 300) { [weak self] in
                            self?.finish(.failure(ChatGPTError.cancelled))
                        }
                    }
                }
            }
        } onCancel: {
            queue.async { [self] in finish(.failure(ChatGPTError.cancelled)) }
        }
    }

    func stop() {
        listener.cancel()
    }

    private func finish(_ result: Result<[String: String], Error>) {
        if let continuation {
            continuation.resume(with: result)
            self.continuation = nil
        } else if pending == nil {
            pending = result
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [self] data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let target = request.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            guard let components = URLComponents(string: "http://127.0.0.1\(target)"), components.path == path else {
                respond(connection, status: "404 Not Found", body: "Not found")
                return
            }
            var params: [String: String] = [:]
            for item in components.queryItems ?? [] { params[item.name] = item.value ?? "" }
            guard params["state"] == state else {
                respond(connection, status: "400 Bad Request", body: "This sign-in link doesn't match. Return to Kaze and try again.")
                return
            }
            let page = """
            <!doctype html><html lang="en"><meta charset="utf-8"><title>Kaze</title>
            <style>body{font:17px -apple-system,system-ui;max-width:30rem;margin:20vh auto;padding:24px;color:#1d1d1f}h1{font-size:24px}</style>
            <h1>You're connected</h1><p>Return to Kaze. You can close this tab.</p></html>
            """
            respond(connection, status: "200 OK", body: page, html: true)
            finish(.success(params))
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: String, html: Bool = false) {
        let payload = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(html ? "text/html" : "text/plain"); charset=utf-8\r\nContent-Length: \(payload.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// Stores the connection in the login Keychain.
nonisolated enum ChatGPTKeychain {
    private static let service = "com.fayazahmed.Kaze.chatgpt"
    private static let account = "connection"

    static func load() -> ChatGPTCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(ChatGPTCredentials.self, from: data)
    }

    static func save(_ credentials: ChatGPTCredentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if SecItemUpdate(match as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            SecItemAdd(match.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

nonisolated extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
