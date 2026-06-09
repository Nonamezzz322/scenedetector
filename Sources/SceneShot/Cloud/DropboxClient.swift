import Foundation
import AppKit

/// Dropbox API client: list a shared folder, fetch thumbnails, download files.
/// All requests carry a fresh Bearer token from OAuthManager; 401/429/network
/// map to typed CloudError with Russian messages.
struct DropboxClient {
    private let provider = CloudProvider.dropbox

    // MARK: - List a shared folder

    /// Returns the video items inside a Dropbox shared-folder link (handles pagination).
    func listFolder(sharedLink: String) async throws -> [CloudItem] {
        var items: [CloudItem] = []
        var arg: [String: Any] = ["path": "", "shared_link": ["url": sharedLink]]
        var endpoint = "https://api.dropboxapi.com/2/files/list_folder"

        while true {
            let data = try await rpc(endpoint, json: arg)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CloudError.badResponse("list_folder")
            }
            if let entries = obj["entries"] as? [[String: Any]] {
                for e in entries where (e[".tag"] as? String) == "file" {
                    let name = (e["name"] as? String) ?? ""
                    // For shared-link listings Dropbox returns path_lower = null (the files aren't in
                    // the viewer's namespace). get_shared_link_file / get_thumbnail_v2 still need a
                    // path RELATIVE to the link; since list_folder is non-recursive, that's "/<name>".
                    let lower = e["path_lower"] as? String
                    let rel = (lower?.isEmpty == false) ? lower! : "/" + name
                    let size = (e["size"] as? NSNumber)?.int64Value
                    let item = CloudItem(
                        id: rel,
                        name: name,
                        sizeBytes: size,
                        pathLower: rel,
                        thumbnailLink: nil
                    )
                    if item.isVideo { items.append(item) }
                }
            }
            guard (obj["has_more"] as? Bool) == true, let cursor = obj["cursor"] as? String else { break }
            arg = ["cursor": cursor]
            endpoint = "https://api.dropboxapi.com/2/files/list_folder/continue"
        }
        return items
    }

    // MARK: - Thumbnail

    /// A preview for a video item. Dropbox's get_thumbnail_v2 only supports image files, so for
    /// videos we range-download the first few MB and decode the first frame with bundled ffmpeg.
    func videoThumbnail(for item: CloudItem, sharedLink: String) async -> NSImage? {
        guard let partial = try? await downloadRange(sharedLink: sharedLink, pathLower: item.pathLower,
                                                     maxBytes: 5_000_000) else { return nil }
        defer { try? FileManager.default.removeItem(at: partial) }
        return await LocalThumb.firstFrame(partial)
    }

    /// Fetches a JPEG thumbnail via get_thumbnail_v2 (images only), or nil if unavailable.
    func thumbnail(for item: CloudItem, sharedLink: String) async -> NSImage? {
        guard let rel = item.pathLower else { return nil }
        let arg: [String: Any] = [
            "resource": [".tag": "shared_link", "url": sharedLink, "path": rel],
            "format": "jpeg",
            "size": "w256h256",
            "mode": "fitone_bestfit"
        ]
        guard let data = try? await content("https://content.dropboxapi.com/2/files/get_thumbnail_v2", arg: arg),
              let image = NSImage(data: data) else { return nil }
        return image
    }

    /// Downloads the first `maxBytes` of a shared file (HTTP Range) to a temp file.
    func downloadRange(sharedLink: String, pathLower: String?, maxBytes: Int) async throws -> URL {
        var arg: [String: Any] = ["url": sharedLink]
        if let pathLower { arg["path"] = pathLower }
        let token = try await OAuthManager.shared.validAccessToken(provider)
        var req = URLRequest(url: URL(string: "https://content.dropboxapi.com/2/sharing/get_shared_link_file")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(Self.apiArg(arg), forHTTPHeaderField: "Dropbox-API-Arg")
        req.setValue("bytes=0-\(maxBytes - 1)", forHTTPHeaderField: "Range")

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("sceneshot-dbxprev-\(UUID().uuidString).mp4")
        let (tmp, response) = try await URLSession.shared.download(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: tmp)
            throw CloudError.http(status: http.statusCode, detail: nil)
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    // MARK: - Download

    /// Downloads a shared file to a temp URL. For a folder link, pass `pathLower`
    /// of the inner item; for a single file link, pass nil.
    func downloadSharedFile(sharedLink: String, pathLower: String?, suggestedName: String,
                            onProgress: ((Double) -> Void)? = nil) async throws -> URL {
        var arg: [String: Any] = ["url": sharedLink]
        if let pathLower { arg["path"] = pathLower }

        let token = try await OAuthManager.shared.validAccessToken(provider)
        var req = URLRequest(url: URL(string: "https://content.dropboxapi.com/2/sharing/get_shared_link_file")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(Self.apiArg(arg), forHTTPHeaderField: "Dropbox-API-Arg")

        let ext = (suggestedName as NSString).pathExtension.isEmpty ? "mp4" : (suggestedName as NSString).pathExtension
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("sceneshot-dbx-\(UUID().uuidString).\(ext)")

        let (tmp, response): (URL, URLResponse)
        do {
            (tmp, response) = try await URLSession.shared.download(for: req)
        } catch {
            throw CloudError.network(error.localizedDescription)
        }
        // On error the JSON reason is written to the downloaded temp file — read it so the
        // real Dropbox error_summary surfaces instead of a bare status code.
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let body = try? Data(contentsOf: tmp)
            try? FileManager.default.removeItem(at: tmp)
            try Self.throwIfError(status: http.statusCode,
                                  retryAfter: http.value(forHTTPHeaderField: "Retry-After"), body: body)
        }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
        } catch {
            throw CloudError.network(error.localizedDescription)
        }
        onProgress?(1.0)
        return dest
    }

    // MARK: - Request plumbing

    /// JSON-RPC style call: parameters in the JSON body.
    private func rpc(_ urlString: String, json: [String: Any]) async throws -> Data {
        let token = try await OAuthManager.shared.validAccessToken(provider)
        var req = URLRequest(url: URL(string: urlString)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: json)
        return try await send(req)
    }

    /// Content call: parameters in the Dropbox-API-Arg header, binary body in response.
    private func content(_ urlString: String, arg: [String: Any]) async throws -> Data {
        let token = try await OAuthManager.shared.validAccessToken(provider)
        var req = URLRequest(url: URL(string: urlString)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(Self.apiArg(arg), forHTTPHeaderField: "Dropbox-API-Arg")
        return try await send(req)
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw CloudError.network(error.localizedDescription)
        }
        try Self.checkStatus(response, body: data)
        return data
    }

    private static func checkStatus(_ response: URLResponse, body: Data?) throws {
        guard let http = response as? HTTPURLResponse else { return }
        try throwIfError(status: http.statusCode,
                         retryAfter: http.value(forHTTPHeaderField: "Retry-After"), body: body)
    }

    private static func throwIfError(status: Int, retryAfter: String?, body: Data?) throws {
        if (200...299).contains(status) { return }
        if status == 429 { throw CloudError.rateLimited(retryAfter: retryAfter.flatMap { Int($0) }) }
        throw CloudError.http(status: status, detail: detailText(body))
    }

    /// Pulls Dropbox's machine-readable `error_summary` out of a JSON error body.
    private static func detailText(_ body: Data?) -> String? {
        guard let body, !body.isEmpty else { return nil }
        if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let summary = obj["error_summary"] as? String {
            return summary.trimmingCharacters(in: CharacterSet(charactersIn: "/. "))
        }
        return String((String(data: body, encoding: .utf8) ?? "").prefix(200))
    }

    /// Serializes the Dropbox-API-Arg value with non-ASCII escaped to \uXXXX
    /// (HTTP headers must be ASCII; Cyrillic filenames would otherwise break it).
    private static func apiArg(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        var out = ""
        for scalar in json.unicodeScalars {
            if scalar.value < 0x80 {
                out.unicodeScalars.append(scalar)
            } else {
                for u in String(scalar).utf16 {
                    out += String(format: "\\u%04x", u)
                }
            }
        }
        return out
    }
}
