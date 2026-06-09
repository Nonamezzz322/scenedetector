import Foundation

/// Video platforms whose page URLs require an extractor (yt-dlp) rather than a direct file URL.
enum SocialPlatform: String {
    case youtube = "YouTube"
    case youtubeShorts = "YouTube Shorts"
    case tiktok = "TikTok"
    case instagram = "Instagram"
}

enum SocialLink {
    /// Classifies a pasted URL as a known social/video-platform link, or nil if it's something else.
    static func detect(_ text: String) -> SocialPlatform? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host?.lowercased() else { return nil }
        let path = url.path.lowercased()

        if host.contains("youtube.com") || host.contains("youtu.be") || host.contains("youtube-nocookie.com") {
            return path.contains("/shorts/") ? .youtubeShorts : .youtube
        }
        if host.contains("tiktok.com") {           // incl. vm.tiktok.com / vt.tiktok.com short links
            return .tiktok
        }
        if host.contains("instagram.com") {         // /reel/, /reels/, /p/, /tv/
            return .instagram
        }
        return nil
    }
}
