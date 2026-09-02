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

    /// What a Keychain lookup actually established.
    ///
    /// The three cases are not interchangeable, and collapsing them is how a
    /// connected user gets logged out: `absent` is a fact worth caching,
    /// `unavailable` is a failure that must be retried rather than recorded.
    enum Lookup: Equatable {
        /// A token is there.
        case found(String)
        /// The Keychain answered, and there is no such item.
        case absent
        /// The Keychain could not answer — access denied, no interaction
        /// allowed, a locked keychain. Says nothing about whether a token
        /// exists.
        case unavailable(OSStatus)
    }

    static func lookup() -> Lookup {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let token = String(data: data, encoding: .utf8) else { return .absent }
            return .found(token)
        case errSecItemNotFound:
            return .absent
        default:
            return .unavailable(status)
        }
    }

    static func load() -> String? {
        if case .found(let token) = lookup() { return token }
        return nil
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

/// Every Keychain operation `SpotifyAccount` performs, behind one injectable
/// seam.
///
/// **All three, not just the read.** An earlier version injected only
/// `lookup` and left `save`/`delete` calling the real Keychain — and a unit
/// test exercising `disconnect()` deleted the developer's own live refresh
/// token (2026-09-01). A partial seam is worse than none: it reads as safe
/// while still reaching the real credential store.
struct SpotifyTokenStorage {
    var lookup: () -> SpotifyTokenStore.Lookup
    var save: (String) -> Void
    var delete: () -> Void

    static let keychain = SpotifyTokenStorage(
        lookup: SpotifyTokenStore.lookup,
        save: SpotifyTokenStore.save,
        delete: SpotifyTokenStore.delete)

    /// A store that never touches the Keychain. The default for tests, so
    /// reaching the real one has to be a deliberate act.
    static func inMemory(_ token: String? = nil) -> SpotifyTokenStorage {
        final class Box: @unchecked Sendable { var token: String? }
        let box = Box()
        box.token = token
        return SpotifyTokenStorage(
            lookup: { box.token.map { .found($0) } ?? .absent },
            save: { box.token = $0 },
            delete: { box.token = nil })
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

    /// PopNotch's own Spotify application, built in and identical for every
    /// install.
    ///
    /// **This is not a secret and is meant to be here.** Under PKCE the Client
    /// ID is public by design: it identifies the *application* to Spotify and
    /// is sent in the clear in the browser's authorize URL, where any user can
    /// read it. The client *secret* is the credential that must never ship in
    /// a distributed app, and this flow deliberately has none — the code
    /// exchange is authenticated by the PKCE verifier instead, which is
    /// generated fresh per authorization and never leaves the machine.
    ///
    /// It was a per-user settings field until v4. That was a category error:
    /// it identifies PopNotch, not the person using it, so asking each user to
    /// register their own developer app was asking them to do the developer's
    /// paperwork — and a fresh install, which had no ID at all, simply could
    /// not connect.
    @ObservationIgnored static let clientID = "290ab45ba19d43599f66bb341cb33c77"

    private(set) var isConnected: Bool
    private(set) var lastError: String?

    @ObservationIgnored private var accessToken: String?
    @ObservationIgnored private var accessExpiry = Date.distantPast
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var pendingVerifier: String?
    @ObservationIgnored private var pendingState: String?

    /// Where the connected flag is cached, so launch does not have to ask
    /// the Keychain. Nil in tests that do not care.
    @ObservationIgnored private let settings: SettingsStore?

    init(settings: SettingsStore? = nil,
         storage: SpotifyTokenStorage = .keychain) {
        self.settings = settings
        self.storage = storage

        // The point of the flag: a user with no account touches the Keychain
        // zero times at launch, and a connected one touches it only when a
        // Web API call actually needs a token.
        if let cached = settings?.settings.spotifyAccountConnected {
            self.isConnected = cached
            return
        }

        // Nil flag: an upgrade from v6 or earlier, or a fresh install whose
        // settings were never written. Both must ask the Keychain exactly
        // once — the Keychain outlives the app bundle, so a reinstalled or
        // upgraded app can hold a live token with brand-new settings, and
        // assuming "not connected" here would log that user out.
        switch storage.lookup() {
        case .found:
            self.isConnected = true
            settings?.update { $0.spotifyAccountConnected = true }
            Self.logger.notice("No cached Spotify flag; Keychain says connected")
        case .absent:
            self.isConnected = false
            settings?.update { $0.spotifyAccountConnected = false }
            Self.logger.notice("No cached Spotify flag; Keychain says no account")
        case .unavailable(let status):
            // The Keychain refused to answer — a denied prompt, a locked
            // keychain, no interaction allowed. This says NOTHING about
            // whether a token exists, so it is deliberately not cached:
            // recording `false` here would permanently log out a connected
            // user, and because a cached flag is never re-checked, they
            // would never get the prompt again to recover. Leaving the flag
            // nil costs one retry next launch and cannot lose an account.
            self.isConnected = false
            Self.logger.error("Keychain unavailable (OSStatus \(status, privacy: .public)); leaving the connected flag unrecorded so the next launch retries")
        }
    }

    @ObservationIgnored private let storage: SpotifyTokenStorage

    /// Records the connected state in both places at once, so the cached
    /// flag can never drift from what the Keychain holds.
    private func setConnected(_ connected: Bool) {
        isConnected = connected
        settings?.update { $0.spotifyAccountConnected = connected }
    }

    // MARK: - Authorization

    func beginAuthorization() {
        let clientID = Self.clientID
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
        storage.delete()
        accessToken = nil
        accessExpiry = .distantPast
        setConnected(false)
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
                Task { @MainActor [weak self] in
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
                storage.save(refresh)
            }
            setConnected(true)
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
        // The second gate. Callers already check `accountConnected`, but this
        // makes the guarantee structural: a disconnected account cannot reach
        // the Keychain from here however it is called.
        guard isConnected else { return nil }
        let lookup = storage.lookup()
        guard case .found(let refresh) = lookup else {
            // The cached flag and the Keychain disagree. Only a definitive
            // `absent` corrects it — the token really is gone, so claiming
            // "connected" would leave a UI offering an account that cannot
            // work. `unavailable` is left alone: it says nothing, and
            // recording it would log out a user whose Keychain was merely
            // locked. (Observed 2026-09-01: a deleted item left the flag
            // reading connected with no token behind it.)
            if case .absent = lookup {
                Self.logger.notice("Cached flag said connected but the token is gone; correcting")
                setConnected(false)
            }
            return nil
        }
        let clientID = Self.clientID

        do {
            let token = try await postToken(
                form: "grant_type=refresh_token&refresh_token=\(refresh)&client_id=\(clientID)"
            )
            accessToken = token.access_token
            accessExpiry = Date().addingTimeInterval(token.expires_in - 60)
            if let newRefresh = token.refresh_token {
                storage.save(newRefresh)
            }
            return token.access_token
        } catch {
            Self.logger.error("Token refresh failed; treating as disconnected")
            disconnect()
            return nil
        }
    }
}
