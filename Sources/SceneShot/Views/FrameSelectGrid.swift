import SwiftUI
import AppKit

/// Grid of extracted frames the user picks from. Selection is ORDERED: each picked
/// frame shows a badge with its click position (1, 2, 3…). Tapping again deselects
/// (later badges renumber). Frames show full aspect — vertical videos aren't cropped.
struct FrameSelectGrid: View {
    let frames: [FrameRef]
    @Binding var order: [String]      // selected FrameRef.id (url.path) in click order
    var disabled: Bool = false

    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 170), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(frames) { f in
                let badge = order.firstIndex(of: f.id).map { $0 + 1 }
                FrameThumb(url: f.url, selected: badge != nil)
                    .overlay(alignment: .topLeading) {
                        if let badge {
                            Text("\(badge)")
                                .font(.caption.bold()).foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Color.accentColor))
                                .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                                .padding(5)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { toggle(f.id) }
            }
        }
        .opacity(disabled ? 0.5 : 1)
        .allowsHitTesting(!disabled)
    }

    private func toggle(_ id: String) {
        if let i = order.firstIndex(of: id) { order.remove(at: i) }
        else { order.append(id) }
    }
}

private struct FrameThumb: View {
    let url: URL
    let selected: Bool
    @State private var image: NSImage?

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.black.opacity(0.06))
            .frame(height: 130)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFit().padding(3)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.25),
                                  lineWidth: selected ? 3 : 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .task(id: url) { image = NSImage(contentsOf: url) }
    }
}
