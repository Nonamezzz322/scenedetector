import Foundation

/// Editing-rhythm metrics for one video.
struct SceneMetrics: Equatable {
    let duration: Double
    let cuts: Int
    let cutsPerMin: Double
    let avgShot: Double      // average shot length (ASL), seconds
    let medianShot: Double
    let minShot: Double
    let maxShot: Double
    let hookLen: Double      // time to the first scene change (opening shot hold)
}

/// Computes editing metrics WITHOUT writing frames: runs the same scene-detect
/// filter as SceneExtractor but discards video output (`-f null`), collecting only
/// the cut timestamps. Much cheaper than a full frame extraction.
final class SceneAnalyzer {
    private var running: FFmpeg.Running?
    private var cancelled = false

    func cancel() {
        cancelled = true
        running?.cancel()
    }

    func analyze(
        source: Source,
        threshold: Double,
        duration: Double?,
        onProgress: @escaping (Double) -> Void
    ) async throws -> SceneMetrics {
        cancelled = false

        var args = ["-hide_banner", "-nostats"]
        if source.isRemote {
            args += ["-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "5"]
        }
        args += ["-i", source.ffmpegInput,
                 "-vf", "select=gt(scene\\,\(Self.fmt(threshold))),showinfo",
                 "-an", "-progress", "pipe:1", "-f", "null", "-"]

        var times: [Double] = []
        let lock = NSLock()

        let result: ProcessResult = try await withCheckedThrowingContinuation { cont in
            self.running = FFmpeg.shared.launch(
                .ffmpeg,
                args: args,
                onStdoutLine: { line in
                    if let p = SceneExtractor.parseProgress(line, duration: duration) { onProgress(p) }
                },
                onStderrLine: { line in
                    if let t = SceneExtractor.parsePTS(line) { lock.lock(); times.append(t); lock.unlock() }
                },
                completion: { res in
                    switch res {
                    case .success(let r): cont.resume(returning: r)
                    case .failure(let e): cont.resume(throwing: e)
                    }
                }
            )
        }

        if cancelled { throw CancellationError() }
        guard result.exitCode == 0 else {
            throw FFmpegError.failed(code: result.exitCode, stderr: result.stderr)
        }
        return Self.metrics(cutTimes: times, duration: duration)
    }

    static func metrics(cutTimes: [Double], duration: Double?) -> SceneMetrics {
        let sorted = cutTimes.sorted()
        let dur = (duration.map { $0 > 0 ? $0 : nil } ?? nil) ?? (sorted.last ?? 0)
        let cuts = sorted.count

        // Shot lengths = gaps between [0, cut1, cut2, …, duration].
        var bounds = [0.0]
        bounds.append(contentsOf: sorted.filter { $0 > 0 && $0 < dur })
        bounds.append(dur)
        var shots = zip(bounds, bounds.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }
        if shots.isEmpty { shots = [max(dur, 0.0001)] }

        let avg = dur > 0 ? dur / Double(shots.count) : 0
        let sortedShots = shots.sorted()
        let median: Double
        let mid = sortedShots.count / 2
        if sortedShots.count % 2 == 0 {
            median = (sortedShots[mid - 1] + sortedShots[mid]) / 2
        } else {
            median = sortedShots[mid]
        }
        let cutsPerMin = dur > 0 ? Double(cuts) / (dur / 60.0) : 0
        let hook = sorted.first ?? dur

        return SceneMetrics(
            duration: dur,
            cuts: cuts,
            cutsPerMin: cutsPerMin,
            avgShot: avg,
            medianShot: median,
            minShot: sortedShots.first ?? dur,
            maxShot: sortedShots.last ?? dur,
            hookLen: hook
        )
    }

    private static func fmt(_ v: Double) -> String { String(format: "%g", v) }
}
