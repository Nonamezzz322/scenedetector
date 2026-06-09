import Foundation
import Vision
import AppKit

/// Perceptual similarity between frames. Prefers Apple's Vision feature prints
/// (semantic, robust to compression/lighting); falls back to a dHash when Vision
/// is unavailable. A `signature` bundles whichever was computed so callers compare
/// like-with-like, and `distance` returns a normalized 0…1 difference.
struct FrameSignature {
    let featurePrint: VNFeaturePrintObservation?
    let hash: UInt64?   // dHash fallback
}

enum FrameSimilarity {
    /// Vision distances run on their own scale; this divisor maps them into ~0…1.
    /// Calibrated so genuinely different shots land well above typical sensitivity cutoffs.
    private static let visionScale: Float = 2.0

    static func signature(_ url: URL) -> FrameSignature? {
        if let fp = featurePrint(url) { return FrameSignature(featurePrint: fp, hash: nil) }
        if let h = SceneExtractor.dHash(url) { return FrameSignature(featurePrint: nil, hash: h) }
        return nil
    }

    /// Normalized difference (0 = identical, ~1 = very different). Returns nil if
    /// the two signatures used different methods (shouldn't happen within one run).
    static func distance(_ a: FrameSignature, _ b: FrameSignature) -> Double? {
        if let fa = a.featurePrint, let fb = b.featurePrint {
            var d: Float = 0
            do { try fa.computeDistance(&d, to: fb) } catch { return nil }
            return Double(min(1, max(0, d / visionScale)))
        }
        if let ha = a.hash, let hb = b.hash {
            return SceneExtractor.normalizedHamming(ha, hb)
        }
        return nil
    }

    private static func featurePrint(_ url: URL) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(url: url, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        return request.results?.first as? VNFeaturePrintObservation
    }
}
