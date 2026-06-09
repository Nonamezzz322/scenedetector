import Foundation

/// One listed remote video (from a channel/profile/playlist/hashtag/search).
struct RemoteEntry: Identifiable, Equatable {
    let id: String
    let title: String
    let url: String           // usable yt-dlp input for the actual download
    let durationSec: Double?
    let thumbnailURL: String?
    let uploader: String?
}

enum EnumerateError: LocalizedError {
    case toolMissing
    case empty
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .toolMissing:
            return L("Модуль yt-dlp не зібрано (Scripts/fetch-ytdlp.sh).",
                     "Модуль yt-dlp не собран (Scripts/fetch-ytdlp.sh).",
                     "yt-dlp module not built (Scripts/fetch-ytdlp.sh).")
        case .empty:
            return L("Нічого не знайдено. Можливо, контент приватний, потребує входу або посилання застаріле.",
                     "Ничего не найдено. Возможно, контент приватный, требует входа или ссылка устарела.",
                     "Nothing found. The content may be private, require sign-in, or the link may be outdated.")
        case .failed(let m):
            return L("Не вдалося отримати перелік: \(m)", "Не удалось получить список: \(m)", "Could not fetch the list: \(m)")
        }
    }
}

/// Lists videos behind a channel/profile/playlist/hashtag URL (or a search query)
/// using the bundled yt-dlp in flat-playlist mode — fast, no per-video resolve.
final class MediaEnumerator {
    static var isAvailable: Bool { FFmpeg.shared.toolURL(.ytdlp) != nil }

    func enumerate(_ input: String, limit: Int) async throws -> [RemoteEntry] {
        guard FFmpeg.shared.toolURL(.ytdlp) != nil else { throw EnumerateError.toolMissing }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EnumerateError.empty }

        // A bare query (not a URL) → treat as a YouTube search.
        let target: String
        if trimmed.lowercased().hasPrefix("http") || trimmed.contains("://") {
            target = trimmed
        } else {
            target = "ytsearch\(max(1, limit)):\(trimmed)"
        }

        let args = ["--flat-playlist", "--dump-single-json", "--no-warnings",
                    "--playlist-end", String(max(1, limit)), target]

        let result: ProcessResult
        do {
            result = try await FFmpeg.shared.run(.ytdlp, args: args)
        } catch {
            throw EnumerateError.failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        guard result.exitCode == 0 else {
            throw EnumerateError.failed(Self.shortError(result.stderr))
        }
        guard let data = result.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EnumerateError.empty
        }

        var entries: [RemoteEntry] = []
        if let list = obj["entries"] as? [[String: Any]] {
            for e in list { if let entry = Self.parse(e) { entries.append(entry) } }
        } else if let single = Self.parse(obj) {
            entries.append(single)
        }
        if entries.isEmpty { throw EnumerateError.empty }
        return entries
    }

    private static func parse(_ e: [String: Any]) -> RemoteEntry? {
        // Skip non-video rows (e.g. nested playlist sections) without an id.
        let id = (e["id"] as? String) ?? (e["url"] as? String) ?? ""
        guard !id.isEmpty else { return nil }
        let title = (e["title"] as? String) ?? (e["uploader"] as? String) ?? id
        let url = (e["webpage_url"] as? String) ?? (e["url"] as? String) ?? id
        let duration = (e["duration"] as? Double) ?? (e["duration"] as? NSNumber)?.doubleValue
        let uploader = (e["uploader"] as? String) ?? (e["channel"] as? String)
        var thumb = e["thumbnail"] as? String
        if thumb == nil, let thumbs = e["thumbnails"] as? [[String: Any]] {
            thumb = (thumbs.last?["url"] as? String) ?? (thumbs.first?["url"] as? String)
        }
        return RemoteEntry(id: id, title: title, url: url,
                           durationSec: duration, thumbnailURL: thumb, uploader: uploader)
    }

    private static func shortError(_ stderr: String) -> String {
        // Surface the most useful yt-dlp ERROR line.
        if let line = stderr.split(separator: "\n").first(where: { $0.contains("ERROR") }) {
            return String(line.prefix(200))
        }
        return String(stderr.suffix(200))
    }
}
