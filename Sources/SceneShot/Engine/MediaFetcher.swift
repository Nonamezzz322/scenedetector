import Foundation

enum MediaFetchError: LocalizedError {
    case failed(stderr: String)
    case noFile

    var errorDescription: String? {
        switch self {
        case .failed:
            return L("Не вдалося завантажити відео за посиланням. Можливо, контент приватний, потребує входу в акаунт, або посилання/модуль yt-dlp застаріли.",
                     "Не удалось скачать видео по ссылке. Возможно, контент приватный, требует входа в аккаунт, или ссылка/модуль yt-dlp устарели.",
                     "Could not download the video. The content may be private, require sign-in, or the link/yt-dlp module may be outdated.")
        case .noFile:
            return L("Завантаження не дало відеофайлу.", "Скачивание не дало видеофайла.", "The download produced no video file.")
        }
    }
}

/// Downloads the video behind a page URL (TikTok, Instagram Reels, YouTube, YouTube Shorts)
/// to a temp file using the bundled yt-dlp, which itself uses the bundled ffmpeg for merging.
/// Mirrors the other engines: launch via the shared runner, parse progress, support cancel.
final class MediaFetcher {
    private var running: FFmpeg.Running?
    private var cancelled = false
    private var workDir: URL?

    func cancel() {
        cancelled = true
        running?.cancel()
    }

    static var isAvailable: Bool { FFmpeg.shared.toolURL(.ytdlp) != nil }

    func fetch(pageURL: String, onProgress: @escaping (Double) -> Void) async throws -> URL {
        cancelled = false
        guard FFmpeg.shared.toolURL(.ytdlp) != nil else { throw FFmpegError.toolMissing("yt-dlp") }

        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sceneshot-dl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        workDir = outDir

        var args: [String] = []
        // Point yt-dlp at our bundled ffmpeg/ffprobe so the user needs nothing installed.
        if let ff = FFmpeg.shared.toolURL(.ffmpeg) {
            args += ["--ffmpeg-location", ff.deletingLastPathComponent().path]
        }
        args += [
            "--no-playlist",
            "--no-warnings",
            "--no-part",
            "--newline",                                   // progress on its own lines
            "-f", "mp4/bestvideo*+bestaudio/best",
            "--merge-output-format", "mp4",
            "-o", outDir.appendingPathComponent("%(id)s.%(ext)s").path,
            pageURL
        ]

        let result: ProcessResult = try await withCheckedThrowingContinuation { cont in
            self.running = FFmpeg.shared.launch(
                .ytdlp,
                args: args,
                onStdoutLine: { line in if let p = Self.parseProgress(line) { onProgress(p) } },
                onStderrLine: { line in if let p = Self.parseProgress(line) { onProgress(p) } },
                completion: { res in
                    switch res {
                    case .success(let r): cont.resume(returning: r)
                    case .failure(let e): cont.resume(throwing: e)
                    }
                }
            )
        }

        if cancelled {
            try? FileManager.default.removeItem(at: outDir)
            throw CancellationError()
        }
        guard result.exitCode == 0 else {
            try? FileManager.default.removeItem(at: outDir)
            throw MediaFetchError.failed(stderr: result.stderr)
        }

        let files = (try? FileManager.default.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil)) ?? []
        guard let media = files.first(where: { VideoValidation.isVideoFile($0) }) ?? files.first else {
            try? FileManager.default.removeItem(at: outDir)
            throw MediaFetchError.noFile
        }
        return media   // caller owns the file (and its temp dir); delete after use
    }

    /// Parses yt-dlp `--newline` progress: `[download]  12.3% of ...`.
    static func parseProgress(_ line: String) -> Double? {
        guard let dl = line.range(of: "[download]") else { return nil }
        let tail = line[dl.upperBound...]
        guard let pct = tail.range(of: "%") else { return nil }
        let num = tail[tail.startIndex..<pct.lowerBound].trimmingCharacters(in: .whitespaces)
        if let v = Double(num) { return max(0, min(1, v / 100)) }
        return nil
    }
}
