import Foundation
import AppKit

/// One analyzed competitor video: editing metrics plus optional transcript stats.
struct VideoMetrics: Identifiable, Equatable {
    let id: String
    let name: String
    let url: String
    let uploader: String?
    let metrics: SceneMetrics
    var transcriptWords: Int?
    var language: String?
    var framesCount: Int?
    var outputDir: URL?
}

struct CompetitorSummary {
    let rows: [VideoMetrics]
    let failures: [BatchFailure]
    let outputDir: URL
    /// Set-wide averages for the header.
    var avgShotAll: Double {
        let v = rows.map { $0.metrics.avgShot }.filter { $0 > 0 }
        return v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count)
    }
    var avgCutsPerMin: Double {
        let v = rows.map { $0.metrics.cutsPerMin }
        return v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count)
    }
    var avgHook: Double {
        let v = rows.map { $0.metrics.hookLen }
        return v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count)
    }
}

/// Downloads selected competitor videos and computes editing metrics (and optional
/// frames/transcript) for each. Mirrors BatchProcessor: observable status, overall
/// progress, cancellation, error isolation. Produces a CSV "creative intelligence" report.
@MainActor
final class CompetitorAnalyzer: ObservableObject {
    @Published private(set) var statuses: [String: BatchItemStatus] = [:]
    @Published private(set) var overall: Double = 0
    @Published private(set) var currentIndex = 0
    @Published private(set) var total = 0
    @Published private(set) var running = false
    @Published private(set) var summary: CompetitorSummary?

    private var cancelled = false
    private var fetcher: MediaFetcher?
    private var analyzer: SceneAnalyzer?
    private var extractor: SceneExtractor?
    private var whisper: WhisperEngine?

    func status(for id: String) -> BatchItemStatus { statuses[id] ?? .waiting }

    func cancel() {
        cancelled = true
        fetcher?.cancel(); analyzer?.cancel(); extractor?.cancel(); whisper?.cancel()
    }

    func run(entries: [RemoteEntry], doFrames: Bool, doTranscribe: Bool,
             language: TranscriptLanguage, threshold: Double, baseOutputDir: URL) {
        guard !running, !entries.isEmpty else { return }
        cancelled = false
        running = true
        summary = nil
        total = entries.count
        currentIndex = 0
        overall = 0
        statuses = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, .waiting) })

        Task {
            var rows: [VideoMetrics] = []
            var failures: [BatchFailure] = []

            for (index, entry) in entries.enumerated() {
                if cancelled { break }
                currentIndex = index
                do {
                    let row = try await analyze(entry, doFrames: doFrames, doTranscribe: doTranscribe,
                                                language: language, threshold: threshold, baseOutputDir: baseOutputDir)
                    statuses[entry.id] = .done
                    rows.append(row)
                } catch is CancellationError {
                    statuses[entry.id] = .cancelled
                    break
                } catch {
                    if cancelled { statuses[entry.id] = .cancelled; break }
                    let msg = (error as? LocalizedError)?.errorDescription ?? L("Помилка аналізу.", "Ошибка анализа.", "Analysis error.")
                    statuses[entry.id] = .failed(msg)
                    failures.append(BatchFailure(name: entry.title, message: msg))
                }
                overall = Double(index + 1) / Double(max(1, entries.count))
            }
            if cancelled {
                for e in entries where statuses[e.id] == .waiting { statuses[e.id] = .cancelled }
            }
            running = false
            summary = CompetitorSummary(rows: rows, failures: failures, outputDir: baseOutputDir)
        }
    }

    // MARK: - One entry

    private func analyze(_ entry: RemoteEntry, doFrames: Bool, doTranscribe: Bool,
                         language: TranscriptLanguage, threshold: Double, baseOutputDir: URL) async throws -> VideoMetrics {
        // 1) Download.
        statuses[entry.id] = .downloading(0)
        let mf = MediaFetcher(); fetcher = mf
        let local = try await mf.fetch(pageURL: entry.url, onProgress: { [weak self] p in
            Task { @MainActor in self?.statuses[entry.id] = .downloading(p) }
        })
        fetcher = nil
        defer { try? FileManager.default.removeItem(at: local.deletingLastPathComponent()) }
        if cancelled { throw CancellationError() }

        statuses[entry.id] = .processing(0)
        let info = try? await MediaProbe.probe(local.path)
        let duration = info?.durationSeconds ?? entry.durationSec

        // 2) Editing metrics (no frames written).
        let sa = SceneAnalyzer(); analyzer = sa
        let metrics = try await sa.analyze(source: .file(local), threshold: threshold, duration: duration,
                                           onProgress: { [weak self] p in
            Task { @MainActor in self?.statuses[entry.id] = .processing(p * (doFrames || doTranscribe ? 0.5 : 1.0)) }
        })
        analyzer = nil
        if cancelled { throw CancellationError() }

        var outputDir: URL?
        var framesCount: Int?
        var words: Int?
        var lang: String?

        if doFrames || doTranscribe {
            let dir = baseOutputDir.appendingPathComponent(Self.sanitize(entry.title), isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            outputDir = dir

            // 3) Optional frames.
            if doFrames {
                var p = ExtractParams()
                p.threshold = threshold
                p.sourceName = Self.sanitize(entry.title)
                let ex = SceneExtractor(); extractor = ex
                let outcome = try await ex.extract(source: .file(local), outputDir: dir, params: p,
                                                   durationSeconds: duration, onProgress: { _ in })
                extractor = nil
                if case .done(let count, _, _) = outcome { framesCount = count }
                if case .cancelled = outcome { throw CancellationError() }
            }
            // 4) Optional transcript.
            if doTranscribe && WhisperEngine.isAvailable {
                var tp = TranscribeParams(); tp.language = language
                let we = WhisperEngine(); whisper = we
                let outcome = try await we.transcribe(source: .file(local), info: info ?? MediaInfo(),
                                                      outputDir: dir, params: tp, durationSeconds: duration,
                                                      onProgress: { _ in })
                whisper = nil
                if case .done(_, let files) = outcome {
                    words = files.text.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
                }
                lang = language == .auto ? nil : language.rawValue
                if case .cancelled = outcome { throw CancellationError() }
            }
        }

        return VideoMetrics(id: entry.id, name: entry.title, url: entry.url, uploader: entry.uploader,
                            metrics: metrics, transcriptWords: words, language: lang,
                            framesCount: framesCount, outputDir: outputDir)
    }

    // MARK: - CSV

    /// Writes report.csv into the output dir and returns its URL.
    @discardableResult
    func exportCSV(_ summary: CompetitorSummary) -> URL? {
        var csv = "name,url,uploader,duration_s,cuts,cuts_per_min,avg_shot_s,median_shot_s,hook_s,words,language\n"
        for r in summary.rows {
            let cols = [
                r.name, r.url, r.uploader ?? "",
                String(format: "%.1f", r.metrics.duration),
                String(r.metrics.cuts),
                String(format: "%.2f", r.metrics.cutsPerMin),
                String(format: "%.2f", r.metrics.avgShot),
                String(format: "%.2f", r.metrics.medianShot),
                String(format: "%.2f", r.metrics.hookLen),
                r.transcriptWords.map(String.init) ?? "",
                r.language ?? ""
            ]
            csv += cols.map(Self.csvEscape).joined(separator: ",") + "\n"
        }
        let url = summary.outputDir.appendingPathComponent("report.csv")
        // UTF-8 BOM so Excel detects encoding (Cyrillic).
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(csv.data(using: .utf8) ?? Data())
        do { try data.write(to: url); return url } catch { return nil }
    }

    private static func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    private static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = name.components(separatedBy: bad).joined(separator: "_")
        let trimmed = String(cleaned.prefix(80)).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "video" : trimmed
    }
}
