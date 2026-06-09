import SwiftUI
import AppKit
import QuickLookThumbnailing

/// A unified grid row: a video from a local folder or a cloud folder.
struct GridEntry: Identifiable, Equatable {
    let id: String
    let name: String
    let subtitle: String?     // size text
    let source: BatchSource
}

/// Grid of video previews with checkboxes. Thumbnails load lazily per visible cell.
struct ThumbGridView: View {
    let entries: [GridEntry]
    @Binding var selected: Set<String>
    let disabled: Bool
    /// Async thumbnail provider supplied by the owner (cached there).
    let thumbnail: (GridEntry) async -> NSImage?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(entries) { entry in
                ThumbCell(
                    entry: entry,
                    isSelected: selected.contains(entry.id),
                    thumbnail: thumbnail
                ) {
                    if selected.contains(entry.id) { selected.remove(entry.id) }
                    else { selected.insert(entry.id) }
                }
                .disabled(disabled)
            }
        }
    }
}

private struct ThumbCell: View {
    let entry: GridEntry
    let isSelected: Bool
    let thumbnail: (GridEntry) async -> NSImage?
    let onToggle: () -> Void

    @State private var image: NSImage?
    @State private var loading = true

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.12))
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay {
                        if let image {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)   // show full frame, don't crop vertical
                        } else if loading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "film")
                                .font(.system(size: 26))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25),
                                          lineWidth: isSelected ? 2.5 : 1)
                    }

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.white.opacity(0.9))
                    .background(Circle().fill(Color.black.opacity(0.25)).padding(2))
                    .padding(6)
            }

            Text(entry.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let sub = entry.subtitle {
                Text(sub).font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        .task(id: entry.id) {
            loading = true
            image = await thumbnail(entry)
            loading = false
        }
    }
}

/// Generates a local thumbnail via QuickLook, falling back to a bundled-ffmpeg frame.
enum LocalThumb {
    static func generate(_ url: URL) async -> NSImage? {
        if let ql = await quicklook(url) { return ql }
        return await ffmpegFrame(url)
    }

    private static func quicklook(_ url: URL) async -> NSImage? {
        await withCheckedContinuation { (cont: CheckedContinuation<NSImage?, Never>) in
            let size = CGSize(width: 320, height: 180)
            let request = QLThumbnailGenerator.Request(
                fileAt: url, size: size, scale: 2.0, representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                if let rep {
                    cont.resume(returning: NSImage(cgImage: rep.cgImage, size: size))
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private static func ffmpegFrame(_ url: URL) async -> NSImage? {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("sceneshot-thumb-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: out) }
        let args = ["-hide_banner", "-nostats", "-ss", "1", "-i", url.path,
                    "-frames:v", "1", "-vf", "scale=320:-2", "-q:v", "4", "-y", out.path]
        guard let result = try? await FFmpeg.shared.run(.ffmpeg, args: args),
              result.exitCode == 0,
              let img = NSImage(contentsOf: out) else { return nil }
        return img
    }

    /// Grabs the FIRST decodable frame without seeking — works on partial/truncated files
    /// (e.g. a range-downloaded prefix of a remote video). Ignores exit code: a truncated
    /// input often makes ffmpeg exit non-zero even after writing a valid first frame.
    static func firstFrame(_ url: URL) async -> NSImage? {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("sceneshot-thumb-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: out) }
        let args = ["-hide_banner", "-nostats", "-i", url.path,
                    "-frames:v", "1", "-vf", "scale=320:-2", "-q:v", "4", "-y", out.path]
        _ = try? await FFmpeg.shared.run(.ffmpeg, args: args)
        return NSImage(contentsOf: out)
    }
}
