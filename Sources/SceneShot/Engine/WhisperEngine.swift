import Foundation

enum TranscriptLanguage: String, CaseIterable, Identifiable {
    case auto, uk, ru, en
    var id: String { rawValue }
    var display: String {
        switch self {
        case .auto: return "Авто"
        case .uk:   return "Українська"
        case .ru:   return "Русский"
        case .en:   return "English"
        }
    }
    /// Value passed to whisper-cli's -l flag (the ggml-base model is multilingual, uk included).
    var flag: String { rawValue }   // "auto" | "uk" | "ru" | "en"
}

struct TranscribeParams {
    var language: TranscriptLanguage = .auto
    var writeTxt = true
    var writeSrt = true
}

struct TranscriptFiles {
    let txt: URL?
    let srt: URL?
    let text: String
    var language: String?   // effective language (forced, or whisper's auto-detected)
}

enum TranscribeOutcome {
    case done(dir: URL, files: TranscriptFiles)
    case empty(dir: URL)
    case cancelled
}

/// Runs whisper.cpp (whisper-cli) to transcribe a Source to TXT + SRT.
/// Mirrors SceneExtractor: transcode → run the bundled tool via the shared
/// deadlock-safe runner → parse progress from stderr → collect outputs.
final class WhisperEngine {
    private let audio = AudioExtractor()
    private var running: FFmpeg.Running?
    private var cancelled = false

    func cancel() {
        cancelled = true
        audio.cancel()
        running?.cancel()
    }

    /// True only when both the whisper-cli binary and the model are bundled.
    static var isAvailable: Bool {
        FFmpeg.shared.toolURL(.whisper) != nil && modelURL != nil
    }

    static var modelURL: URL? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let u = res.appendingPathComponent("Models", isDirectory: true)
                   .appendingPathComponent("ggml-base.bin")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Threads: min(physical cores, 8) — over-subscribing past physical cores hurts whisper.
    static var threads: Int {
        var count: Int = 0
        var size = MemoryLayout<Int>.size
        if sysctlbyname("hw.physicalcpu", &count, &size, nil, 0) != 0 || count <= 0 {
            count = ProcessInfo.processInfo.activeProcessorCount
        }
        return max(1, min(count, 8))
    }

    func transcribe(
        source: Source,
        info: MediaInfo,
        outputDir: URL,
        params: TranscribeParams,
        durationSeconds: Double?,
        onProgress: @escaping (Double) -> Void
    ) async throws -> TranscribeOutcome {
        cancelled = false
        guard FFmpeg.shared.toolURL(.whisper) != nil else { throw FFmpegError.toolMissing("whisper-cli") }
        guard let model = Self.modelURL else { throw FFmpegError.toolMissing("ggml-base.bin") }
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        // 1) Transcode to 16 kHz mono s16le WAV (first ~15% of the bar).
        let wav = try await audio.extract(source: source, info: info, durationSeconds: durationSeconds,
                                          onProgress: { p in onProgress(p * 0.15) })
        defer { try? FileManager.default.removeItem(at: wav) }
        if cancelled { return .cancelled }

        // 2) Run whisper-cli. -of takes a basename WITHOUT extension.
        let base = outputDir.appendingPathComponent("transcript").path
        var args = ["-m", model.path, "-f", wav.path, "-l", params.language.flag,
                    "-of", base, "-t", String(Self.threads), "-pp"]
        if params.writeTxt { args.append("-otxt") }
        if params.writeSrt { args.append("-osrt") }

        let dur = info.durationSeconds
        // Written only by the (serial) stderr reader; read after the process exits.
        var detectedLang: String?
        let result: ProcessResult = try await withCheckedThrowingContinuation { cont in
            self.running = FFmpeg.shared.launch(
                .whisper,
                args: args,
                onStdoutLine: { line in
                    if let p = Self.parseProgress(line, duration: dur) { onProgress(0.15 + p * 0.85) }
                },
                onStderrLine: { line in
                    if let p = Self.parseProgress(line, duration: dur) { onProgress(0.15 + p * 0.85) }
                    if let l = Self.parseDetectedLanguage(line) { detectedLang = l }
                },
                completion: { res in
                    switch res {
                    case .success(let r): cont.resume(returning: r)
                    case .failure(let e): cont.resume(throwing: e)
                    }
                }
            )
        }
        running = nil

        if cancelled { return .cancelled }
        guard result.exitCode == 0 else {
            throw FFmpegError.failed(code: result.exitCode, stderr: result.stderr)
        }

        let txtURL = outputDir.appendingPathComponent("transcript.txt")
        let srtURL = outputDir.appendingPathComponent("transcript.srt")
        let txtExists = FileManager.default.fileExists(atPath: txtURL.path)
        let srtExists = FileManager.default.fileExists(atPath: srtURL.path)
        let text = (try? String(contentsOf: txtURL, encoding: .utf8)) ?? ""

        // No speech: a 0-exit run with an empty/whitespace TXT.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .empty(dir: outputDir)
        }
        let effectiveLang = params.language == .auto ? detectedLang : params.language.rawValue
        let files = TranscriptFiles(
            txt: txtExists ? txtURL : nil,
            srt: srtExists ? srtURL : nil,
            text: text,
            language: effectiveLang)
        return .done(dir: outputDir, files: files)
    }

    // MARK: - Progress parsing

    /// Primary: `whisper_print_progress_callback: progress = N%`.
    /// Fallback: a segment-timestamp `[hh:mm:ss.fff --> …]` start ÷ duration.
    static func parseProgress(_ line: String, duration: Double?) -> Double? {
        if let r = line.range(of: "progress =") {
            let tail = line[r.upperBound...].drop(while: { $0 == " " })
            let num = tail.prefix(while: { $0.isNumber })
            if let n = Double(num) { return max(0, min(1, n / 100)) }
        }
        if let duration, duration > 0, let open = line.range(of: "[") {
            let seg = line[open.upperBound...]
            if let arrow = seg.range(of: " -->") {
                let start = String(seg[seg.startIndex..<arrow.lowerBound]).trimmingCharacters(in: .whitespaces)
                if let s = parseSrtTime(start) { return max(0, min(1, s / duration)) }
            }
        }
        return nil
    }

    /// Parses whisper.cpp's stderr line `… auto-detected language: ru (p = …)` → "ru".
    static func parseDetectedLanguage(_ line: String) -> String? {
        guard let r = line.range(of: "auto-detected language:") else { return nil }
        let code = line[r.upperBound...].drop(while: { $0 == " " }).prefix(while: { $0.isLetter })
        return code.isEmpty ? nil : String(code).lowercased()
    }

    /// Parses `hh:mm:ss.fff` or `hh:mm:ss,mmm` to seconds.
    static func parseSrtTime(_ s: String) -> Double? {
        let norm = s.replacingOccurrences(of: ",", with: ".")
        let parts = norm.split(separator: ":")
        guard parts.count == 3,
              let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + sec
    }
}
