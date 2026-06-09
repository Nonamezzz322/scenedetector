import Foundation
import AuthenticationServices
import CryptoKit
import AppKit
import Security   // SecRandomCopyBytes for the PKCE verifier

/// OAuth 2.0 + PKCE for cloud providers, with no third-party dependencies.
/// Uses ASWebAuthenticationSession for the browser hand-off and the Keychain
/// for token storage. One refresh/access token set per provider.
@MainActor
final class OAuthManager: NSObject, ObservableObject {
    static let shared = OAuthManager()

    /// Published connection state, keyed by provider. Drives the UI.
    @Published private(set) var connected: [CloudProvider: Bool] = [:]

    private var session: ASWebAuthenticationSession?  // retained while presenting
    // Redirect URI + callback scheme are per-provider (see CloudProvider): Dropbox uses our
    // `sceneshot://` scheme, Google uses its reversed-client-id scheme.

    private override init() {
        super.init()
        for p in CloudProvider.allCases {
            connected[p] = (TokenSet.load(for: p) != nil)
        }
    }

    func isConnected(_ provider: CloudProvider) -> Bool { connected[provider] ?? false }

    // MARK: - Connect (interactive)

    /// Runs the full authorization-code-with-PKCE flow and stores tokens.
    func connect(_ provider: CloudProvider) async throws {
        guard provider.isConfigured else { throw CloudError.notConfigured(provider) }

        let verifier = Self.makeCodeVerifier()
        let challenge = Self.codeChallenge(for: verifier)

        var comps = URLComponents(string: provider.authorizeEndpoint)!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: provider.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: provider.redirectURI),
            URLQueryItem(name: "scope", value: provider.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ] + provider.extraAuthorizeQuery

        guard let authURL = comps.url else { throw CloudError.authFailed(L("Некоректний URL авторизації.", "Некорректный URL авторизации.", "Invalid authorization URL.")) }

        let callbackURL = try await present(authURL, scheme: provider.callbackScheme)
        guard let code = Self.queryValue("code", in: callbackURL) else {
            if let err = Self.queryValue("error", in: callbackURL) {
                throw CloudError.authFailed(err)
            }
            throw CloudError.authFailed(L("Не отримали код авторизації.", "Не получили код авторизации.", "Didn't receive an authorization code."))
        }

        let tokens = try await exchangeCode(code, verifier: verifier, provider: provider)
        tokens.save(for: provider)
        connected[provider] = true
    }

    func disconnect(_ provider: CloudProvider) {
        TokenSet.delete(for: provider)
        connected[provider] = false
    }

    // MARK: - Access token (refreshing)

    /// Returns a currently-valid access token, refreshing if expired.
    func validAccessToken(_ provider: CloudProvider) async throws -> String {
        guard var tokens = TokenSet.load(for: provider) else {
            throw CloudError.notConnected(provider)
        }
        if tokens.isExpired {
            tokens = try await refresh(tokens, provider: provider)
            tokens.save(for: provider)
        }
        return tokens.accessToken
    }

    // MARK: - Token network calls

    private func exchangeCode(_ code: String, verifier: String, provider: CloudProvider) async throws -> TokenSet {
        let form = [
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": verifier,
            "client_id": provider.clientID,
            "redirect_uri": provider.redirectURI
        ]
        return try await postToken(form, provider: provider, existingRefresh: nil)
    }

    private func refresh(_ tokens: TokenSet, provider: CloudProvider) async throws -> TokenSet {
        guard let refresh = tokens.refreshToken else { throw CloudError.notConnected(provider) }
        let form = [
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": provider.clientID
        ]
        return try await postToken(form, provider: provider, existingRefresh: refresh)
    }

    /// POSTs the x-www-form-urlencoded token request and parses the JSON response.
    /// `existingRefresh` is carried over when the response omits a new refresh_token.
    private func postToken(_ form: [String: String], provider: CloudProvider, existingRefresh: String?) async throws -> TokenSet {
        var req = URLRequest(url: URL(string: provider.tokenEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form
            .map { "\(Self.formEscape($0.key))=\(Self.formEscape($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw CloudError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            let detail = String(data: data, encoding: .utf8)
            throw CloudError.http(status: status, detail: detail?.prefix(200).description)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String else {
            throw CloudError.badResponse(L("немає access_token", "нет access_token", "no access_token"))
        }
        let expiresIn = (obj["expires_in"] as? Double) ?? 3600
        let refresh = (obj["refresh_token"] as? String) ?? existingRefresh
        return TokenSet(
            accessToken: access,
            refreshToken: refresh,
            expiry: Date().addingTimeInterval(expiresIn - 60)  // 60s safety margin
        )
    }

    // MARK: - ASWebAuthenticationSession

    private func present(_ url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                if let error {
                    if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                        cont.resume(throwing: CloudError.authCancelled)
                    } else {
                        cont.resume(throwing: CloudError.authFailed(error.localizedDescription))
                    }
                    return
                }
                guard let callback else {
                    cont.resume(throwing: CloudError.authFailed(L("Порожня відповідь авторизації.", "Пустой ответ авторизации.", "Empty authorization response.")))
                    return
                }
                cont.resume(returning: callback)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                cont.resume(throwing: CloudError.authFailed(L("Не вдалося відкрити вікно авторизації.", "Не удалось открыть окно авторизации.", "Couldn't open the authorization window.")))
            }
        }
    }

    // MARK: - PKCE helpers

    private static func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64url(Data(bytes))
    }

    private static func codeChallenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return base64url(Data(hash))
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEscape(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
    }
}

extension OAuthManager: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Must be evaluated on the main thread; ASWebAuthenticationSession calls this on main.
        MainActor.assumeIsolated {
            NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        }
    }
}

/// Persisted token set (access + refresh + expiry) stored as JSON in the Keychain.
private struct TokenSet: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiry: Date

    var isExpired: Bool { Date() >= expiry }

    func save(for provider: CloudProvider) {
        guard let data = try? JSONEncoder().encode(self),
              let json = String(data: data, encoding: .utf8) else { return }
        TokenStore.set(json, account: provider.keychainAccount)
    }

    static func load(for provider: CloudProvider) -> TokenSet? {
        guard let json = TokenStore.get(account: provider.keychainAccount),
              let data = json.data(using: .utf8),
              let set = try? JSONDecoder().decode(TokenSet.self, from: data) else { return nil }
        return set
    }

    static func delete(for provider: CloudProvider) {
        TokenStore.delete(account: provider.keychainAccount)
    }
}
