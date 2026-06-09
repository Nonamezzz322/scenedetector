import Foundation

/// Supported cloud providers and their OAuth/endpoint configuration.
enum CloudProvider: String, CaseIterable, Identifiable {
    case dropbox
    case gdrive

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dropbox: return "Dropbox"
        case .gdrive:  return "Google Drive"
        }
    }

    /// Public client id (app key). Empty when the provider isn't configured.
    var clientID: String {
        switch self {
        case .dropbox: return Secrets.dropboxAppKey
        case .gdrive:  return Secrets.googleClientID
        }
    }

    var isConfigured: Bool { !clientID.isEmpty }

    /// Keychain account under which this provider's tokens are stored.
    var keychainAccount: String { "oauth.\(rawValue)" }

    // MARK: OAuth endpoints

    var authorizeEndpoint: String {
        switch self {
        case .dropbox: return "https://www.dropbox.com/oauth2/authorize"
        case .gdrive:  return "https://accounts.google.com/o/oauth2/v2/auth"
        }
    }

    var tokenEndpoint: String {
        switch self {
        case .dropbox: return "https://api.dropboxapi.com/oauth2/token"
        case .gdrive:  return "https://oauth2.googleapis.com/token"
        }
    }

    var scope: String {
        switch self {
        case .dropbox: return "files.metadata.read files.content.read sharing.read"
        case .gdrive:  return "https://www.googleapis.com/auth/drive.readonly"
        }
    }

    /// Extra query items appended to the authorize URL to force a refresh token.
    var extraAuthorizeQuery: [URLQueryItem] {
        switch self {
        case .dropbox:
            return [URLQueryItem(name: "token_access_type", value: "offline")]
        case .gdrive:
            return [
                URLQueryItem(name: "access_type", value: "offline"),
                URLQueryItem(name: "prompt", value: "consent")
            ]
        }
    }

    /// Custom URL scheme ASWebAuthenticationSession listens for on the OAuth callback.
    /// Dropbox accepts our own `sceneshot` scheme (registered in its App Console);
    /// Google (iOS client) requires the reversed-client-id scheme, e.g.
    /// `com.googleusercontent.apps.<id>`. ASWebAuthenticationSession intercepts the
    /// callback by scheme, so no Info.plist registration is needed for it.
    var callbackScheme: String {
        switch self {
        case .dropbox:
            return "sceneshot"
        case .gdrive:
            let id = clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
            return "com.googleusercontent.apps.\(id)"
        }
    }

    /// Full redirect URI sent in the authorize/token requests.
    var redirectURI: String {
        switch self {
        case .dropbox: return "sceneshot://oauth"
        case .gdrive:  return "\(callbackScheme):/oauth"   // reversed-client-id scheme, single-slash path
        }
    }
}

/// One remote item (a video file) inside a cloud folder.
struct CloudItem: Identifiable, Equatable {
    let id: String          // provider-unique id (Dropbox: path_lower; Drive: file id)
    let name: String
    let sizeBytes: Int64?
    let pathLower: String?  // Dropbox: path within the shared link
    let thumbnailLink: String?  // Drive: direct thumbnail URL (Dropbox fetches via API)

    var isVideo: Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return VideoValidation.videoExtensions.contains(ext)
    }

    var sizeText: String? {
        guard let b = sizeBytes, b > 0 else { return nil }
        let mb = Double(b) / 1_048_576
        return mb >= 1 ? String(format: "%.1f \(L("МБ", "МБ", "MB"))", mb)
                       : String(format: "%.0f \(L("КБ", "КБ", "KB"))", Double(b) / 1024)
    }
}

/// A listed cloud folder: the originating share URL plus its video items.
struct CloudFolder {
    let provider: CloudProvider
    let shareURL: String
    let items: [CloudItem]
}

/// Typed cloud errors with human-facing Russian messages.
enum CloudError: LocalizedError {
    case notConfigured(CloudProvider)
    case notConnected(CloudProvider)
    case authCancelled
    case authFailed(String)
    case http(status: Int, detail: String?)
    case rateLimited(retryAfter: Int?)
    case network(String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let p):
            return L("\(p.displayName) не налаштовано у цій збірці (немає app key).",
                     "\(p.displayName) не настроен в этой сборке (нет app key).",
                     "\(p.displayName) is not configured in this build (no app key).")
        case .notConnected(let p):
            return L("Підключіть \(p.displayName), щоб відкрити це посилання.",
                     "Подключите \(p.displayName), чтобы открыть эту ссылку.",
                     "Connect \(p.displayName) to open this link.")
        case .authCancelled:
            return L("Авторизацію скасовано.", "Авторизация отменена.", "Authorization cancelled.")
        case .authFailed(let m):
            return L("Не вдалося авторизуватися: \(m)", "Не удалось авторизоваться: \(m)", "Authorization failed: \(m)")
        case .http(let status, let detail):
            if status == 401 { return L("Доступ закінчився. Перепідключіть акаунт.", "Доступ истёк. Переподключите аккаунт.", "Access expired. Reconnect the account.") }
            return L("Помилка сервера (\(status)).", "Ошибка сервера (\(status)).", "Server error (\(status)).") + (detail.map { " \($0)" } ?? "")
        case .rateLimited:
            return L("Забагато запитів. Зачекайте трохи й повторіть.", "Слишком много запросов. Подождите немного и повторите.", "Too many requests. Wait a bit and retry.")
        case .network(let m):
            return L("Мережа недоступна: \(m)", "Сеть недоступна: \(m)", "Network unavailable: \(m)")
        case .badResponse(let m):
            return L("Неочікувана відповідь сервісу: \(m)", "Неожиданный ответ сервиса: \(m)", "Unexpected service response: \(m)")
        }
    }
}
