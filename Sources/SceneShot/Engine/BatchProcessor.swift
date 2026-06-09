import Foundation
import AppKit

/// Where a batch item's bytes come from.
enum BatchSource: Equatable {
    case local(URL)
    case dropbox(shareURL: String, pathLower: String?)
    case gdrive(fileId: String)
    case remoteVideo(url: String, title: String)   // a social/page video, fetched via yt-dlp
}

/// One queued video in a batch run.
struct BatchItem: Identifiable, Equatable {
    let id: String
    let name: String          // display + output subfolder name
    let source: BatchSource
}

/// Per-item progress state, observed by the UI.
enum BatchItemStatus: Equatable {
    case waiting
    case downloading(Double)
    case processing(Double)
    case done
    case failed(String)
    case cancelled
}

struct BatchFailure: Identifiable {
    let id = UUID()
    let name: String
    let message: String
}

/// Per-video result of a batch run: extracted frames staged for the user to pick from.
struct BatchVideoResult: Identifiable {
    let id: String
    let name: String
    let outputDir: URL          // where selected frames (and transcript) are saved
    var stagedFrames: [FrameRef]
    var stagingDir: URL?
}

struct BatchSummary {
    let doneCount: Int
    let failures: [BatchFailure]
    let outputDir: URL
    var videoResults: [BatchVideoResult] = []
}

/// Runs frame extraction (and, later, transcription) over a list of selected
/// videos, one subfolder per video. Errors are isolated: one failure does not
/// stop the queue. Observable so the «Папка» tab can render live status.
@MainActor
final class BatchProcessor: ObservableObject {
    /// True once the whisper-cli binary and model are bundled.
    static var transcriptionAvailable: Bool { WhisperEngine.isAvailable }

    @Published private(set) var statuses: [String: BatchItemStatus] = [:]
    @Published private(set) var overall: Double = 0
    @Published private(set) var currentIndex = 0
    @Published private(set) var total = 0
    @Published private(set) var running = false
    @Published private(set) var summary: BatchSummary?

    private var cancelled = false
    private var extractor: SceneExtractor?
    private var whisper: WhisperEngine?
    private var downloader: Downloader?

    func status(for id: String) -> BatchItemStatus { statuses[id] ?? .waiting }

    /// Clears a finished run's results so the UI returns to the input/selection stage.
    func reset() {
        guard !running else { return }
        summary = nil; statuses = [:]; overall = 0; currentIndex = 0; total = 0
    }

    func cancel() {
        cancelled = true
        extractor?.cancel()
        whisper?.cancel()
        downloader?.cancel()
    }

    func run(items: [BatchItem], doFrames: Bool, doTranscribe: Bool,
             language: TranscriptLanguage = .auto,
             params: ExtractParams, baseOutputDir: URL) {
        guard !running, !items.isEmpty else { return }
        cancelled = false
        running = true
        summary = nil
        total = items.count
        currentIndex = 0
        overall = 0
        statuses = Dictionary(uniqueKeysWithValues: items.map { ($0.id, .waiting) })

        Task {
            var doneCount = 0
            var failures: [BatchFailure] = []
            var videoResults: [BatchVideoResult] = []

            for (index, item) in items.enumerated() {
                if cancelled { break }
                currentIndex = index
                do {
                    let vr = try await process(item, index: index, doFrames: doFrames,
                                               doTranscribe: doTranscribe, language: language, params: params,
                                               baseOutputDir: baseOutputDir)
                    videoResults.append(vr)
                    statuses[item.id] = .done
                    doneCount += 1
                } catch is CancellationError {
                    statuses[item.id] = .cancelled
                    break
                } catch {
                    if cancelled { statuses[item.id] = .cancelled; break }
                    let msg = (error as? LocalizedError)?.errorDescription ?? L("Помилка обробки.", "Ошибка обработки.", "Processing error.")
                    statuses[item.id] = .failed(msg)
                    failures.append(BatchFailure(name: item.name, message: msg))
                }
                overall = Double(index + 1) / Double(max(1, items.count))
            }

            // Mark any not-yet-touched items (after cancel) as cancelled.
            if cancelled {
                for item in items where statuses[item.id] == .waiting {
                    statuses[item.id] = .cancelled
                }
            }
            running = false
            summary = BatchSummary(doneCount: doneCount, failures: failures, outputDir: baseOutputDir, videoResults: videoResults)
        }
    }

    // MARK: - One item

    private func process(_ item: BatchItem, index: Int, doFrames: Bool, doTranscribe: Bool,
                         language: TranscriptLanguage, params: ExtractParams, baseOutputDir: URL) async throws -> BatchVideoResult {
        let willTranscribe = doTranscribe && Self.transcriptionAvailable
        let bothActive = doFrames && willTranscribe
        var tempToClean: URL?
        defer {
            if let t = tempToClean {
                try? FileManager.default.removeItem(at: t)
                let p = t.deletingLastPathComponent()
                if p.lastPathComponent.hasPrefix("sceneshot-dl-") { try? FileManager.default.removeItem(at: p) }
            }
        }

        // 1) Resolve to a local file.
        let localURL: URL
        switch item.source {
        case .local(let url):
            localURL = url
        case .dropbox(let shareURL, let pathLower):
            statuses[item.id] = .downloading(0)
            let temp = try await DropboxClient().downloadSharedFile(
                sharedLink: shareURL, pathLower: pathLower, suggestedName: item.name,
                onProgress: { [weak self] p in Task { @MainActor in self?.statuses[item.id] = .downloading(p) } })
            tempToClean = temp
            localURL = temp
        case .gdrive(let fileId):
            statuses[item.id] = .downloading(0)
            let temp = try await GoogleDriveClient().download(
                fileId: fileId, suggestedName: item.name,
                onProgress: { [weak self] p in Task { @MainActor in self?.statuses[item.id] = .downloading(p) } })
            tempToClean = temp
            localURL = temp
        case .remoteVideo(let url, _):
            statuses[item.id] = .downloading(0)
            let temp = try await MediaFetcher().fetch(
                pageURL: url,
                onProgress: { [weak self] p in Task { @MainActor in self?.statuses[item.id] = .downloading(p) } })
            tempToClean = temp
            localURL = temp
        }
        if cancelled { throw CancellationError() }

        // 2) Per-video output subfolder (created lazily: now for transcript, on save for frames).
        let subdir = baseOutputDir.appendingPathComponent(Self.sanitize(item.name), isDirectory: true)

        statuses[item.id] = .processing(0)
        let info = try? await MediaProbe.probe(localURL.path)

        var staged: [FrameRef] = []
        var stagingDir: URL?

        // 3) Frames → STAGING (the user picks which to keep per video afterwards).
        if doFrames {
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("sceneshot-stage-\(UUID().uuidString)", isDirectory: true)
            var p = params
            p.sourceName = (item.name as NSString).deletingPathExtension
            let ex = SceneExtractor()
            extractor = ex
            let outcome = try await ex.extract(
                source: .file(localURL), outputDir: staging, params: p,
                durationSeconds: info?.durationSeconds,
                onProgress: { [weak self] frac in
                    let v = bothActive ? frac * 0.5 : frac
                    Task { @MainActor in self?.statuses[item.id] = .processing(v) }
                })
            extractor = nil
            switch outcome {
            case .done(_, _, let frames): staged = frames; stagingDir = staging
            case .cancelled: try? FileManager.default.removeItem(at: staging); throw CancellationError()
            case .empty: try? FileManager.default.removeItem(at: staging)
            }
        }

        // 4) Transcription → subfolder (saved immediately).
        if willTranscribe {
            try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
            var tp = TranscribeParams()
            tp.language = language
            let we = WhisperEngine()
            whisper = we
            let outcome = try await we.transcribe(
                source: .file(localURL), info: info ?? MediaInfo(), outputDir: subdir, params: tp,
                durationSeconds: info?.durationSeconds,
                onProgress: { [weak self] frac in
                    let v = bothActive ? 0.5 + frac * 0.5 : frac
                    Task { @MainActor in self?.statuses[item.id] = .processing(v) }
                })
            whisper = nil
            if case .cancelled = outcome { throw CancellationError() }
        } else if doTranscribe && !doFrames {
            throw CloudError.badResponse(L("Транскрипція недоступна — не зібрано модуль whisper.", "Транскрипция недоступна — не собран модуль whisper.", "Transcription unavailable — whisper module not built."))
        }

        return BatchVideoResult(id: item.id, name: item.name, outputDir: subdir,
                                stagedFrames: staged, stagingDir: stagingDir)
    }

    private static func sanitize(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = base.components(separatedBy: bad).joined(separator: "_")
        return cleaned.isEmpty ? "video" : cleaned
    }
}
