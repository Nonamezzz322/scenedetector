import Foundation

/// A chosen video input: a local file or a direct remote URL.
enum Source: Equatable {
    case file(URL)
    case remote(URL)

    /// The string passed to ffmpeg/ffprobe as input (path for files, absolute URL for remote).
    var ffmpegInput: String {
        switch self {
        case .file(let u): return u.path
        case .remote(let u): return u.absoluteString
        }
    }

    var displayName: String {
        switch self {
        case .file(let u):
            return u.lastPathComponent
        case .remote(let u):
            let last = u.lastPathComponent
            return last.isEmpty ? (u.host ?? u.absoluteString) : last
        }
    }

    var isRemote: Bool {
        if case .remote = self { return true }
        return false
    }
}

struct ValidationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum VideoValidation {
    static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "webm", "mkv", "avi", "m2ts", "ts", "mpg", "mpeg"
    ]

    static func isVideoFile(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }

    /// Lightweight URL check. Full HEAD/content-type validation arrives in stage 6.
    static func remoteSource(from text: String) -> Result<Source, ValidationError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(ValidationError(message: L("Вставте посилання на відео.", "Вставьте ссылку на видео.", "Paste a video link.")))
        }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return .failure(ValidationError(message: L("Введіть коректне посилання (http/https).", "Введите корректную ссылку (http/https).", "Enter a valid link (http/https).")))
        }
        guard videoExtensions.contains(url.pathExtension.lowercased()) else {
            return .failure(ValidationError(message: L("Потрібне пряме посилання на відеофайл (.mp4/.mov/.webm…), а не сторінка сайту.", "Нужна прямая ссылка на видеофайл (.mp4/.mov/.webm…), а не страница сайта.", "A direct video-file link is required (.mp4/.mov/.webm…), not a web page.")))
        }
        return .success(.remote(url))
    }
}
