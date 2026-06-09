import Foundation
import AppKit

/// Google Drive API client: list a folder, fetch thumbnails, download files.
/// Mirrors DropboxClient — Bearer token from OAuthManager, typed CloudError.
struct GoogleDriveClient {
    private let provider = CloudProvider.gdrive

    // MARK: - List a folder

    func listFolder(folderId: String) async throws -> [CloudItem] {
        var items: [CloudItem] = []
        var pageToken: String? = nil

        repeat {
            var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            let q = "'\(folderId)' in parents and mimeType contains 'video/' and trashed = false"
            comps.queryItems = [
                URLQueryItem(name: "q", value: q),
                URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,size,thumbnailLink,mimeType)"),
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "includeItemsFromAllDrives", value: "true")
            ]
            if let pageToken { comps.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken)) }

            let data = try await get(comps.url!)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CloudError.badResponse("files.list")
            }
            if let files = obj["files"] as? [[String: Any]] {
                for f in files {
                    let name = (f["name"] as? String) ?? ""
                    let id = (f["id"] as? String) ?? name
                    let size = (f["size"] as? String).flatMap { Int64($0) }
                    let thumb = f["thumbnailLink"] as? String
                    let item = CloudItem(id: id, name: name, sizeBytes: size, pathLower: nil, thumbnailLink: thumb)
                    if item.isVideo { items.append(item) }
                }
            }
            pageToken = obj["nextPageToken"] as? String
        } while pageToken != nil

        return items
    }

    // MARK: - Thumbnail

    func thumbnail(for item: CloudItem) async -> NSImage? {
        guard let link = item.thumbnailLink, let url = URL(string: link) else { return nil }
        guard let data = try? await get(url), let image = NSImage(data: data) else { return nil }
        return image
    }

    // MARK: - Download

    func download(fileId: String, suggestedName: String, onProgress: ((Double) -> Void)? = nil) async throws -> URL {
        let token = try await OAuthManager.shared.validAccessToken(provider)
        var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(fileId)")!
        comps.queryItems = [
            URLQueryItem(name: "alt", value: "media"),
            URLQueryItem(name: "supportsAllDrives", value: "true")
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let ext = (suggestedName as NSString).pathExtension.isEmpty ? "mp4" : (suggestedName as NSString).pathExtension
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("sceneshot-gdrive-\(UUID().uuidString).\(ext)")

        let (tmp, response): (URL, URLResponse)
        do {
            (tmp, response) = try await URLSession.shared.download(for: req)
        } catch {
            throw CloudError.network(error.localizedDescription)
        }
        try Self.checkStatus(response, body: nil)
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

    private func get(_ url: URL) async throws -> Data {
        let token = try await OAuthManager.shared.validAccessToken(provider)
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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
        switch http.statusCode {
        case 200...299:
            return
        case 429:
            let retry = (http.value(forHTTPHeaderField: "Retry-After")).flatMap { Int($0) }
            throw CloudError.rateLimited(retryAfter: retry)
        default:
            let detail = body.flatMap { String(data: $0, encoding: .utf8) }?.prefix(200).description
            throw CloudError.http(status: http.statusCode, detail: detail)
        }
    }
}
