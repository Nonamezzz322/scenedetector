import SwiftUI
import AppKit

/// Terminal outcome of an extraction run.
enum RunResult {
    case done(count: Int, dir: URL, frames: [FrameRef])
    case empty(dir: URL)
    case error(message: String, technical: String?)
    case cancelled
}

struct ResultsView: View {
    let result: RunResult
    let onRetryMoreSensitive: () -> Void
    @ObservedObject private var loc = Loc.shared

    var body: some View {
        switch result {
        case .done(let count, let dir, let frames):
            doneView(count: count, dir: dir, frames: frames)
        case .empty(let dir):
            emptyView(dir: dir)
        case .error(let message, let technical):
            errorView(message: message, technical: technical)
        case .cancelled:
            simple(loc.cancelledDot, icon: "xmark.circle", tint: .secondary)
        }
    }

    // MARK: - Done

    private func doneView(count: Int, dir: URL, frames: [FrameRef]) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(loc.framesDone(count)).bold()
            }
            if !frames.isEmpty { thumbnails(frames) }
            HStack {
                Button { NSWorkspace.shared.activateFileViewerSelecting([dir]) } label: {
                    Label(loc.showInFinder, systemImage: "folder")
                }
                Button { NSWorkspace.shared.open(dir) } label: {
                    Label(loc.openFolder, systemImage: "arrow.up.forward.app")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.08)))
    }

    private func thumbnails(_ frames: [FrameRef]) -> some View {
        let shown = Array(frames.prefix(12))
        // Fit (not fill) so the whole frame shows in its own aspect ratio — vertical
        // videos are no longer cropped; they letterbox inside a uniform cell.
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 150), spacing: 8)], spacing: 8) {
            ForEach(shown, id: \.index) { f in
                if let img = NSImage(contentsOf: f.url) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .frame(height: 120)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.06)))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
            }
        }
    }

    // MARK: - Empty

    private func emptyView(dir: URL) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.orange)
                Text(loc.noScenesTitle).bold()
            }
            Text(loc.retryHint)
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button { onRetryMoreSensitive() } label: {
                Label(loc.retryMoreSensitive, systemImage: "arrow.clockwise")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.08)))
    }

    // MARK: - Error

    private func errorView(message: String, technical: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(message).bold().fixedSize(horizontal: false, vertical: true)
            }
            if let technical, !technical.isEmpty {
                DisclosureGroup(loc.technicalLog) {
                    ScrollView {
                        Text(technical)
                            .font(.system(.caption2, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 120)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.08)))
    }

    private func simple(_ text: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

}
