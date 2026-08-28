import AppKit
import Network
import CryptoKit
import Observation
import os

/// PKCE primitives, pure and testable (RFC 7636).
enum PKCE {
    static func verifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Extracts the authorization code from the loopback HTTP request line,
    /// verifying the anti-forgery state. Pure for tests.
    static func authCode(fromRequestLine line: String, expectedState: String) -> String? {
        // "GET /callback?code=X&state=Y HTTP/1.1"
        guard let pathPart = line.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: String(pathPart)),
              components.path == "/callback" else { return nil }
        let items = components.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == expectedState else { return nil }
        return items.first(where: { $0.name == "code" })?.value
    }
}

/// The refresh token lives in the Keychain, never in UserDefaults.
enum SpotifyTokenStore {
    private static let service = "com.techie.PopNotch"
    private static let account = "spotify-refresh-token"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) {
        let data = Data(token.utf8)
        if SecItemUpdate(baseQuery as CFDictionary,
                         [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var query = baseQuery
            query[kSecValueData as String] = data
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// The user's Spotify account: official OAuth (PKCE) and the Web API calls
/// the notch uses. Endpoints recorded under hard rule 6 in PROJECT-CONTEXT.
///
/// The redirect is a one-shot HTTP listener on the loopback interface —
/// alive only during authorization, torn down the moment the code arrives
/// or after a timeout. No URL scheme, no Info.plist surgery.
@MainActor
@Observable
final class SpotifyAccount {

    @ObservationIgnored
    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "SpotifyAccount")

    @ObservationIgnored static let redirectPort: UInt16 = 7391
    @ObservationIgnored static let redirectURI = "http://127.0.0.1:7391/callback"
    @ObservationIgnored static let scopes = "user-read-playback-state user-library-read user-library-modify"

    private(set) var isConnected: Bool
    private(set) var lastError: String?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var accessToken: String?
    @ObservationIgnored private var accessExpiry = Date.distantPast
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var pendingVerifier: String?
    @ObservationIgnored private var pendingState: String?

    init(settings: SettingsStore) {
        self.settings = settings
        self.isConnected = SpotifyTokenStore.load() != nil
    }

    // MARK: - Authorization

    func beginAuthorization() {
        let clientID = settings.settings.spotifyClientID.trimmingCharacters(in: .whitespaces)
        guard !clientID.isEmpty else {
            lastError = "Paste your Spotify app's Client ID first."
            return
        }
        lastError = nil
        stopListener()

        let verifier = PKCE.verifier()
        let state = PKCE.base64URL(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))
        pendingVerifier = verifier
        pendingState = state

        do {
            try startListener(clientID: clientID)
        } catch {
            lastError = "Could not listen on port \(Self.redirectPort): \(error.localizedDescription)"
            return
        }

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            .init(name: "scope", value: Self.scopes),
            .init(name: "state", value: state),
        ]
        NSWorkspace.shared.open(components.url!)
        Self.logger.notice("Authorization started; browser opened")
    }

    func disconnect() {
        SpotifyTokenStore.delete()
        accessToken = nil
        accessExpiry = .distantPast
        isConnected = false
        Self.logger.notice("Disconnected")
    }

    private func startListener(clientID: String) throws {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.redirectPort)!)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let firstLine = request.components(separatedBy: "\r\n").first ?? ""
                let body = "<html><body style=\"font-family:sans-serif\">PopNotch is connected. You can close this tab.</body></html>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
                Task { @MainActor in
                    self?.handleCallback(requestLine: firstLine, clientID: clientID)
                }
            }
        }
        listener.start(queue: .main)
        self.listener = listener

        // Safety valve: never leave a port open past a stalled login.
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { [weak self] in
            self?.stopListener()
        }
    }

    private func stopListener() {
        listener?.cancel()
        listener = nil
    }

    private func handleCallback(requestLine: String, clientID: String) {
        guard let state = pendingState, let verifier = pendingVerifier,
              let code = PKCE.authCode(fromRequestLine: requestLine, expectedState: state)
        else {
            // Favicon requests and strays hit the listener too; ignore them.
            return
        }
        stopListener()
        pendingState = nil
        pendingVerifier = nil

        Task {
            await self.exchange(code: code, verifier: verifier, clientID: clientID)
        }
    }

    // MARK: - Tokens

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double
    }

    private func exchange(code: String, verifier: String, clientID: String) async {
        let form = [
            "grant_type=authorization_code",
            "code=\(code)",
            "redirect_uri=\(Self.redirectURI)",
            "client_id=\(clientID)",
            "code_verifier=\(verifier)",
        ].joined(separator: "&")

        do {
            let token = try await postToken(form: form)
            accessToken = token.access_token
            accessExpiry = Date().addingTimeInterval(token.expires_in - 60)
            if let refresh = token.refresh_token {
                SpotifyTokenStore.save(refresh)
            }
            isConnected = true
            lastError = nil
            Self.logger.notice("Connected to Spotify")
        } catch {
            lastError = "Login failed: \(error.localizedDescription)"
            Self.logger.error("Token exchange failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func postToken(form: String) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(form.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.userAuthenticationRequired)
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    /// A valid access token, refreshing via the stored refresh token when
    /// expired. Nil means not connected (or refresh revoked, which also
    /// flips isConnected off so the UI can show it).
    func validAccessToken() async -> String? {
        if let accessToken, Date() < accessExpiry { return accessToken }
        guard let refresh = SpotifyTokenStore.load() else { return nil }
        let clientID = settings.settings.spotifyClientID.trimmingCharacters(in: .whitespaces)
        guard !clientID.isEmpty else { return nil }

        do {
            let token = try await postToken(
                form: "grant_type=refresh_token&refresh_token=\(refresh)&client_id=\(clientID)"
            )
            accessToken = token.access_token
            accessExpiry = Date().addingTimeInterval(token.expires_in - 60)
            if let newRefresh = token.refresh_token {
                SpotifyTokenStore.save(newRefresh)
            }
            return token.access_token
        } catch {
            Self.logger.error("Token refresh failed; treating as disconnected")
            disconnect()
            return nil
        }
    }
}
