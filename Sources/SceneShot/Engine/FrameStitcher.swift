import Foundation
import AppKit

/// Combines several frames into a single image, left-to-right in the given order.
/// All frames are scaled to a common height (the median of the inputs) so vertical
/// and horizontal frames line up cleanly.
enum FrameStitcher {
    /// Writes the combined image to `dest`. Returns the URL on success, nil otherwise.
    @discardableResult
    static func stitch(_ urls: [URL], to dest: URL, format: ImageFormat, spacing: CGFloat = 8) -> URL? {
        let images = urls.compactMap { NSImage(contentsOf: $0) }.filter { $0.size.width > 0 && $0.size.height > 0 }
        guard !images.isEmpty else { return nil }

        // Common height = median input height (robust to one odd frame).
        let heights = images.map { $0.size.height }.sorted()
        let targetH = heights[heights.count / 2]

        var scaled: [(image: NSImage, width: CGFloat)] = []
        var totalW: CGFloat = 0
        for img in images {
            let w = img.size.width * (targetH / img.size.height)
            scaled.append((img, w))
            totalW += w
        }
        totalW += spacing * CGFloat(images.count - 1)

        let canvas = NSImage(size: NSSize(width: ceil(totalW), height: ceil(targetH)))
        canvas.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: ceil(totalW), height: ceil(targetH)).fill()
        var x: CGFloat = 0
        for s in scaled {
            s.image.draw(in: NSRect(x: x, y: 0, width: s.width, height: targetH),
                         from: .zero, operation: .sourceOver, fraction: 1.0)
            x += s.width + spacing
        }
        canvas.unlockFocus()

        guard let tiff = canvas.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        let type: NSBitmapImageRep.FileType = (format == .png) ? .png : .jpeg
        let props: [NSBitmapImageRep.PropertyKey: Any] = format == .png ? [:] : [.compressionFactor: 0.9]
        guard let data = rep.representation(using: type, properties: props) else { return nil }
        do { try data.write(to: dest); return dest } catch { return nil }
    }
}
