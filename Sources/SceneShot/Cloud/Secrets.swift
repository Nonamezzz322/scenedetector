import Foundation

/// Public OAuth client identifiers (app keys) baked into the app.
///
/// SECURITY: this is a PKCE *public* client. Only the public **app key / client id**
/// belongs here — it is an identifier, not a secret, and is safe to ship.
/// NEVER put a `client secret` here (PKCE does not use one; embedding it would be a leak).
/// Per-user tokens live ONLY in the Keychain (see Keychain.swift), never in code or logs.
///
/// To enable cloud features, register the apps and paste the keys below:
///   • Dropbox App Console (https://www.dropbox.com/developers/apps):
///       scoped app, enable PKCE, redirect URI `sceneshot://oauth`,
///       scopes: files.metadata.read, files.content.read, sharing.read
///   • Google Cloud Console: enable Drive API, OAuth client of type **iOS**, bundle id
///       com.example.sceneshot, scope drive.readonly (Testing mode + test users is fine).
///       Google uses the reversed-client-id scheme for the redirect (derived in CloudProvider),
///       NOT `sceneshot://`.
enum Secrets {
    /// Dropbox App key (public identifier). Empty = Dropbox disabled in UI.
    static let dropboxAppKey = "caoxzo0sn6m78t9"

    /// Google OAuth client id (public identifier). Empty = Google Drive disabled in UI.
    static let googleClientID = "79060345100-jber185m5n7vtgu29v0pt3qvieg2dgab.apps.googleusercontent.com"

    static var hasDropbox: Bool { !dropboxAppKey.isEmpty }
    static var hasGoogle: Bool { !googleClientID.isEmpty }
}
