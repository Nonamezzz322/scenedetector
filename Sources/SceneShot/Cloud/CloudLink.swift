import Foundation

/// Classifies a pasted URL as a cloud file/folder link (Dropbox or Google Drive).
enum CloudLink: Equatable {
    case dropboxFile(URL)
    case dropboxFolder(URL)
    case gdriveFile(id: String, url: URL)
    case gdriveFolder(id: String, url: URL)
    case plainRemote(URL)   // a direct http(s) link, not a known cloud share
    case unknown

    var provider: CloudProvider? {
        switch self {
        case .dropboxFile, .dropboxFolder: return .dropbox
        case .gdriveFile, .gdriveFolder:   return .gdrive
        case .plainRemote, .unknown:       return nil
        }
    }

    var isFolder: Bool {
        switch self {
        case .dropboxFolder, .gdriveFolder: return true
        default: return false
        }
    }

    static func detect(_ text: String) -> CloudLink {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host?.lowercased() else { return .unknown }
        let path = url.path

        if host.contains("dropbox.com") {
            // Folder shares: /scl/fo/… or /sh/…   File shares: /scl/fi/… or /s/…
            if path.contains("/scl/fo/") || path.contains("/sh/") { return .dropboxFolder(url) }
            if path.contains("/scl/fi/") || path.contains("/s/")  { return .dropboxFile(url) }
            return .unknown
        }

        if host.contains("drive.google.com") || host.contains("docs.google.com") {
            if let r = path.range(of: "/folders/") {
                let id = extractID(String(path[r.upperBound...]))
                if !id.isEmpty { return .gdriveFolder(id: id, url: url) }
            }
            if let r = path.range(of: "/file/d/") {
                let id = extractID(String(path[r.upperBound...]))
                if !id.isEmpty { return .gdriveFile(id: id, url: url) }
            }
            // open?id=<ID>
            if let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "id" })?.value, !id.isEmpty {
                return path.contains("folder") ? .gdriveFolder(id: id, url: url) : .gdriveFile(id: id, url: url)
            }
            return .unknown
        }

        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return .plainRemote(url)
        }
        return .unknown
    }

    /// The leading path/id segment up to the next slash or query.
    private static func extractID(_ s: String) -> String {
        String(s.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
    }
}
