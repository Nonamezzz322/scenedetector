import Foundation

enum AudioExtractError: LocalizedError {
    case noAudio
    var errorDescription: String? {
        switch self {
        case .noAudio: return L("У файлі немає звукової доріжки — транскрибувати нічого.",
                                "В файле нет звуковой дорожки — транскрибировать нечего.",
                                "The file has no audio track — nothing to transcribe.")
        }
    }
}

/// Turns any Source into a whisper.cpp-ready WAV (16 kHz, mono, PCM s16le) in a
/// temp file. Mirrors SceneExtractor: builds args, launches via FFmpeg.shared,
/// reuses SceneExtractor.parseProgress, supports cancellation. The caller owns
/// the returned file and must delete it after use.
final class AudioExtractor {
    private var running: FFmpeg.Running?
    private var cancelled = false

    func cancel() {
        cancelled = true
        running?.cancel()
    }

    func extract(
        source: Source,
        info: MediaInfo,
        durationSeconds: Double?,
        onProgress: @escaping (Double) -> Void
    ) async throws -> URL {
        cancelled = false
        // Pre-flight: fail fast on silent video instead of wasting an ffmpeg pass.
        guard info.hasAudio else { throw AudioExtractError.noAudio }

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("sceneshot-audio-\(UUID().uuidString).wav")

        var args = ["-hide_banner", "-nostats", "-nostdin"]
        if source.isRemote {
            args += ["-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "5"]
        }
        args += ["-i", source.ffmpegInput,
                 "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le",
                 "-progress", "pipe:1", "-y", out.path]

        let result: ProcessResult = try await withCheckedThrowingContinuation { cont in
            self.running = FFmpeg.shared.launch(
                .ffmpeg,
                args: args,
                onStdoutLine: { line in
                    if let p = SceneExtractor.parseProgress(line, duration: durationSeconds) {
                        onProgress(p)
                    }
                },
                onStderrLine: nil,
                completion: { res in
                    switch res {
                    case .success(let r): cont.resume(returning: r)
                    case .failure(let e): cont.resume(throwing: e)
                    }
                }
            )
        }

        if cancelled {
            try? FileManager.default.removeItem(at: out)
            throw CancellationError()
        }
        guard result.exitCode == 0 else {
            try? FileManager.default.removeItem(at: out)
            throw FFmpegError.failed(code: result.exitCode, stderr: result.stderr)
        }
        return out
    }
}
