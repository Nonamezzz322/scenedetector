import Foundation
import AppKit

enum ImageFormat: String, CaseIterable {
    case jpg
    case png
    var ext: String { rawValue }
}

struct ExtractParams {
    var threshold: Double = 0.30      // 0..1, lower = more frames
    var format: ImageFormat = .jpg
    var jpegQuality: Int = 3          // 2..31, lower = better quality
    var maxWidth: Int = 0             // 0 = keep original width
    var minInterval: Double = 0       // seconds between kept frames, 0 = off
    var maxFrames: Int = 0            // 0 = no cap
    var filenameTemplate: String = "scene_{index}_{time}"
    var sourceName: String = "video"
    var dedup: Bool = true            // drop frames too similar to an already-kept one
    var settleDelay: Double = 0.4     // capture this many seconds AFTER a change (0 = at the change)
    var rejectLowDetail: Bool = true  // drop near-black / low-contrast / transition-haze frames
}

struct FrameRef: Identifiable, Equatable {
    let index: Int
    let time: Double
    let url: URL
    var id: String { url.path }
}

enum ExtractOutcome {
    case done(count: Int, outputDir: URL, frames: [FrameRef])
    case empty(outputDir: URL)
    case cancelled
}

/// Builds and runs the ffmpeg scene-detection command, streaming progress and
/// collecting per-frame timestamps. Supports cancellation.
final class SceneExtractor {
    private var running: FFmpeg.Running?
    private var cancelled = false

    func cancel() {
        cancelled = true
        running?.cancel()
    }

    func extract(
        source: Source,
        outputDir: URL,
        params: ExtractParams,
        durationSeconds: Double?,
        onProgress: @escaping (Double) -> Void
    ) async throws -> ExtractOutcome {
        cancelled = false
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let pattern = outputDir.appendingPathComponent("scene_%05d.\(params.format.ext)").path

        var args = ["-hide_banner", "-nostats"]
        if source.isRemote {
            args += ["-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "5"]
        }
        args += ["-i", source.ffmpegInput]
        args += ["-vf", Self.buildFilter(params)]
        args += ["-fps_mode", "vfr"]
        if params.format == .jpg {
            args += ["-q:v", String(params.jpegQuality)]
        }
        // We cap AFTER post-processing (dedup / low-detail rejection), else ffmpeg's hard cap
        // could stop before later distinct scenes. Only cap in ffmpeg when nothing post-processes.
        let postProcess = params.dedup || params.rejectLowDetail
        if params.maxFrames > 0 && !postProcess {
            args += ["-frames:v", String(params.maxFrames)]
        }
        args += ["-progress", "pipe:1", "-y", pattern]

        var times: [Double] = []
        let lock = NSLock()

        let result: ProcessResult = try await withCheckedThrowingContinuation { cont in
            self.running = FFmpeg.shared.launch(
                .ffmpeg,
                args: args,
                onStdoutLine: { line in
                    if let p = Self.parseProgress(line, duration: durationSeconds) {
                        onProgress(p)
                    }
                },
                onStderrLine: { line in
                    if let t = Self.parsePTS(line) {
                        lock.lock(); times.append(t); lock.unlock()
                    }
                },
                completion: { res in
                    switch res {
                    case .success(let r): cont.resume(returning: r)
                    case .failure(let e): cont.resume(throwing: e)
                    }
                }
            )
        }

        if cancelled { return .cancelled }
        guard result.exitCode == 0 else {
            throw FFmpegError.failed(code: result.exitCode, stderr: result.stderr)
        }

        let files = (try? FileManager.default.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == params.format.ext && $0.lastPathComponent.hasPrefix("scene_") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

        if files.isEmpty { return .empty(outputDir: outputDir) }

        // The ffmpeg process has exited and its output readers are done,
        // so `times` is fully populated and safe to read here without locking.
        let collected = times
        // Pair frames with timestamps and a detail/sharpness score.
        var scored: [(url: URL, time: Double, detail: Double)] = files.enumerated().map { i, f in
            (f, i < collected.count ? collected[i] : 0, Self.detailScore(f))
        }

        // Drop near-black / low-contrast / transition-haze frames (absolute floor + relative outliers).
        if params.rejectLowDetail && scored.count > 1 {
            let sortedDetails = scored.map { $0.detail }.sorted()
            let median = sortedDetails[sortedDetails.count / 2]
            let floor = max(0.008, 0.2 * median)
            let kept = scored.filter { $0.detail >= floor }
            if !kept.isEmpty {                       // never reject everything
                for r in scored where r.detail < floor { try? FileManager.default.removeItem(at: r.url) }
                scored = kept
            }
        }

        // Cross-frame dedup: keep a set of DISTINCT scenes; among near-duplicates keep the SHARPEST
        // (so a settled scene wins over a soft/half-faded transition frame of the same shot).
        if params.dedup {
            scored = Self.dedupDistinct(scored, threshold: params.threshold)
        }
        if params.maxFrames > 0 && scored.count > params.maxFrames {
            for c in scored[params.maxFrames...] { try? FileManager.default.removeItem(at: c.url) }
            scored = Array(scored.prefix(params.maxFrames))
        }
        if scored.isEmpty { return .empty(outputDir: outputDir) }

        var frames: [FrameRef] = []
        frames.reserveCapacity(scored.count)
        for (i, c) in scored.enumerated() {
            let finalURL = Self.renamed(file: c.url, index: i + 1, time: c.time, params: params, in: outputDir)
            frames.append(FrameRef(index: i + 1, time: c.time, url: finalURL))
        }
        return .done(count: frames.count, outputDir: outputDir, frames: frames)
    }

    // MARK: - Filenames

    /// Renames a raw `scene_NNNNN` file to the user's template; returns the final URL.
    private static func renamed(file: URL, index: Int, time: Double, params: ExtractParams, in dir: URL) -> URL {
        let name = fileName(index: index, time: time, template: params.filenameTemplate,
                            source: params.sourceName, ext: params.format.ext)
        var dest = dir.appendingPathComponent(name)
        if dest == file { return file }
        if FileManager.default.fileExists(atPath: dest.path) {
            let stem = (name as NSString).deletingPathExtension
            dest = dir.appendingPathComponent("\(stem)-\(index).\(params.format.ext)")
        }
        do {
            try FileManager.default.moveItem(at: file, to: dest)
            return dest
        } catch {
            return file
        }
    }

    static func fileName(index: Int, time: Double, template: String, source: String, ext: String) -> String {
        let total = Int(time.rounded())
        let timeStr = String(format: "%02d-%02d-%02d", total / 3600, (total % 3600) / 60, total % 60)
        var s = template.isEmpty ? "scene_{index}_{time}" : template
        s = s.replacingOccurrences(of: "{index}", with: String(format: "%04d", index))
        s = s.replacingOccurrences(of: "{time}", with: timeStr)
        s = s.replacingOccurrences(of: "{name}", with: sanitize(source))
        s = sanitize(s)
        if s.isEmpty { s = String(format: "scene_%04d", index) }
        return s + "." + ext
    }

    private static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return s.components(separatedBy: bad).joined(separator: "_")
    }

    // MARK: - Command building

    /// Builds the -vf value. Commas INSIDE expressions are escaped as `\,`
    /// (Swift literal `\\,`); the comma that SEPARATES filters stays unescaped.
    static func buildFilter(_ p: ExtractParams) -> String {
        let thr = fmt(p.threshold)
        let selectExpr: String
        if p.settleDelay > 0 {
            // Capture `delay` seconds AFTER each scene change — the SETTLED scene, not the
            // start-of-effect frame. A select state machine (st/ld): on the first change it
            // arms a timer (t+delay) without selecting; it selects once the timer elapses, and
            // ignores further changes while armed (so a fade-in's many spikes yield one frame).
            let d = fmt(p.settleDelay)
            let arm = "st(0\\,t+\(d))*0"
            let sm = "if(lte(ld(0)\\,0)\\,if(gt(scene\\,\(thr))\\,\(arm)\\,0)\\,if(gte(t\\,ld(0))\\,st(0\\,0)+1\\,if(gt(scene\\,\(thr))\\,\(arm)\\,0)))"
            selectExpr = "eq(n\\,0)+(\(sm))"
        } else {
            // Classic: select at the change itself, optionally gated by a minimum interval.
            var sceneExpr = "gt(scene\\,\(thr))"
            if p.minInterval > 0 {
                sceneExpr += "*(isnan(prev_selected_t)+gte(t-prev_selected_t\\,\(fmt(p.minInterval))))"
            }
            selectExpr = "eq(n\\,0)+(\(sceneExpr))"
        }
        // `eq(n,0)` always keeps the opening frame. `+` is logical-or in ffmpeg's select.
        var chain = "select=\(selectExpr)"
        if p.maxWidth > 0 {
            chain += ",scale=min(\(p.maxWidth)\\,iw):-2"
        }
        chain += ",showinfo"
        return chain
    }

    private static func fmt(_ v: Double) -> String {
        String(format: "%g", v)
    }

    // MARK: - Output parsing

    static func parseProgress(_ line: String, duration: Double?) -> Double? {
        guard let duration, duration > 0, line.hasPrefix("out_time=") else { return nil }
        let value = String(line.dropFirst("out_time=".count))
        guard let secs = parseHMS(value) else { return nil }
        return max(0, min(1, secs / duration))
    }

    static func parseHMS(_ s: String) -> Double? {
        let parts = s.split(separator: ":")
        guard parts.count == 3,
              let h = Double(parts[0]),
              let m = Double(parts[1]),
              let sec = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + sec
    }

    static func parsePTS(_ line: String) -> Double? {
        guard let r = line.range(of: "pts_time:") else { return nil }
        let token = line[r.upperBound...].prefix { !$0.isWhitespace }
        return Double(token)
    }

    // MARK: - Distinct-scene dedup

    /// Keeps only frames whose perceptual difference from EVERY already-kept frame is
    /// ≥ a cutoff derived from the sensitivity. Too-similar frames are deleted from disk.
    /// The first frame is always kept. Difference is a normalized dHash Hamming distance (0…1).
    ///
    /// Note: dHash distances run on a smaller scale than ffmpeg's scene metric (genuinely
    /// different shots are typically ~0.15–0.45 apart, near-duplicates < ~0.12), so the
    /// sensitivity threshold is mapped onto that scale (×0.5): the default 0.30 → ~0.15,
    /// the standard near-duplicate line. Higher sensitivity → smaller cutoff → keeps more.
    static func dedupDistinct(_ candidates: [(url: URL, time: Double, detail: Double)], threshold: Double) -> [(url: URL, time: Double, detail: Double)] {
        // Cutoff on a normalized 0…1 scale. With Vision's scaling this works out to a raw-distance
        // cutoff ≈ the sensitivity (near-duplicates < 0.3, distinct shots > 0.6); with the dHash
        // fallback it lands at the standard near-duplicate line (~0.15 for the default 0.30).
        let cutoff = min(0.45, max(0.02, threshold * 0.5))
        var kept: [(url: URL, time: Double, detail: Double)] = []
        var sigs: [FrameSignature?] = []
        for c in candidates {
            let s = FrameSimilarity.signature(c.url)
            // Nearest already-kept frame.
            var nearest = -1
            var nearestDist = Double.greatestFiniteMagnitude
            if let s {
                for (i, ks) in sigs.enumerated() {
                    if let ks, let d = FrameSimilarity.distance(ks, s), d < nearestDist { nearestDist = d; nearest = i }
                }
            }
            if nearest >= 0 && nearestDist < cutoff {
                // Near-duplicate: keep whichever frame is sharper.
                if c.detail > kept[nearest].detail {
                    try? FileManager.default.removeItem(at: kept[nearest].url)
                    kept[nearest] = c; sigs[nearest] = s
                } else {
                    try? FileManager.default.removeItem(at: c.url)
                }
            } else {
                kept.append(c); sigs.append(s)
            }
        }
        return kept
    }

    /// A 0…1 detail/sharpness proxy: mean absolute gradient of a 64×48 grayscale downscale.
    /// Near-black / uniform / low-contrast (transition-haze) frames score ~0; textured frames higher.
    static func detailScore(_ url: URL) -> Double {
        guard let img = NSImage(contentsOf: url),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 1 }
        let w = 64, h = 48
        var px = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 1 }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0.0, count = 0
        for r in 0..<h { for c in 0..<(w - 1) { sum += abs(Double(px[r * w + c]) - Double(px[r * w + c + 1])); count += 1 } }
        for r in 0..<(h - 1) { for c in 0..<w { sum += abs(Double(px[r * w + c]) - Double(px[(r + 1) * w + c])); count += 1 } }
        return count > 0 ? (sum / Double(count)) / 255.0 : 0
    }

    /// 64-bit difference hash: downscale to 9×8 grayscale, compare horizontally adjacent pixels.
    static func dHash(_ url: URL) -> UInt64? {
        guard let img = NSImage(contentsOf: url),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = 9, h = 8
        var px = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var hash: UInt64 = 0
        var bit: UInt64 = 0
        for row in 0..<h {
            for col in 0..<(w - 1) {
                if px[row * w + col] < px[row * w + col + 1] { hash |= (1 << bit) }
                bit += 1
            }
        }
        return hash
    }

    static func normalizedHamming(_ a: UInt64, _ b: UInt64) -> Double {
        Double((a ^ b).nonzeroBitCount) / 64.0
    }
}
