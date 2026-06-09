import Foundation

struct MediaInfo {
    var durationSeconds: Double?
    var width: Int?
    var height: Int?
    var codec: String?
    var fps: Double?
    var hasAudio: Bool = false
    var audioCodec: String?

    var resolutionText: String? {
        guard let w = width, let h = height else { return nil }
        return "\(w)×\(h)"
    }

    var durationText: String? {
        guard let d = durationSeconds, d.isFinite, d >= 0 else { return nil }
        let total = Int(d.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%02d:%02d", m, s)
    }
}

enum MediaProbe {
    /// Runs ffprobe on a local path or remote URL and parses key metadata.
    static func probe(_ input: String) async throws -> MediaInfo {
        let args = [
            "-v", "error",
            "-print_format", "json",
            "-show_entries",
            "format=duration:stream=index,codec_type,codec_name,width,height,avg_frame_rate",
            input
        ]
        let result = try await FFmpeg.shared.run(.ffprobe, args: args)
        guard result.exitCode == 0, let data = result.stdout.data(using: .utf8) else {
            throw FFmpegError.failed(code: result.exitCode, stderr: result.stderr)
        }
        return parse(data)
    }

    static func parse(_ data: Data) -> MediaInfo {
        var info = MediaInfo()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return info
        }
        if let format = root["format"] as? [String: Any],
           let dur = format["duration"] as? String {
            info.durationSeconds = Double(dur)
        }
        if let streams = root["streams"] as? [[String: Any]] {
            if let v = streams.first(where: { ($0["codec_type"] as? String) == "video" }) {
                info.width = v["width"] as? Int
                info.height = v["height"] as? Int
                info.codec = v["codec_name"] as? String
                if let afr = v["avg_frame_rate"] as? String {
                    info.fps = parseFraction(afr)
                }
            }
            // Audio presence for the transcription flow — no extra ffprobe call needed,
            // the existing args already return audio streams.
            if let a = streams.first(where: { ($0["codec_type"] as? String) == "audio" }) {
                info.hasAudio = true
                info.audioCodec = a["codec_name"] as? String
            }
        }
        return info
    }

    private static func parseFraction(_ s: String) -> Double? {
        let parts = s.split(separator: "/")
        if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d != 0 {
            return n / d
        }
        return Double(s)
    }
}
