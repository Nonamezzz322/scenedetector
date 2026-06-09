import SwiftUI
import AppKit

/// Enumerates a competitor source (channel/profile/hashtag/search) into entries,
/// manages selection and thumbnails.
@MainActor
final class CompetitorModel: ObservableObject {
    @Published var entries: [RemoteEntry] = []
    @Published var selected: Set<String> = []
    @Published var loading = false
    @Published var loadError: String?
    @Published var label = ""

    private var thumbs: [String: NSImage] = [:]

    func enumerate(_ input: String, limit: Int) async {
        entries = []; selected = []; loadError = nil; thumbs = [:]
        label = Self.label(for: input)
        loading = true
        defer { loading = false }
        do {
            entries = try await MediaEnumerator().enumerate(input, limit: limit)
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? L("Не вдалося отримати перелік.", "Не удалось получить список.", "Couldn't fetch the list.")
        }
    }

    var gridEntries: [GridEntry] {
        entries.map { e in
            var sub = ""
            if let d = e.durationSec { sub = Self.timeText(d) }
            if let u = e.uploader, !u.isEmpty { sub += sub.isEmpty ? u : " · \(u)" }
            return GridEntry(id: e.id, name: e.title, subtitle: sub.isEmpty ? nil : sub,
                             source: .remoteVideo(url: e.url, title: e.title))
        }
    }

    func thumbnail(for entry: GridEntry) async -> NSImage? {
        if let c = thumbs[entry.id] { return c }
        guard let e = entries.first(where: { $0.id == entry.id }),
              let s = e.thumbnailURL, let u = URL(string: s),
              let (data, _) = try? await URLSession.shared.data(from: u),
              let img = NSImage(data: data) else { return nil }
        thumbs[entry.id] = img
        return img
    }

    func selectAll() { selected = Set(entries.map { $0.id }) }
    func clear() { selected = [] }
    var selectedEntries: [RemoteEntry] { entries.filter { selected.contains($0.id) } }

    static func timeText(_ s: Double) -> String {
        let t = Int(s.rounded()); return String(format: "%d:%02d", t / 60, t % 60)
    }
    private static func label(for input: String) -> String {
        if let host = URL(string: input)?.host { return host.replacingOccurrences(of: "www.", with: "") }
        return "competitors"
    }
}

struct CompetitorsView: View {
    @StateObject private var model = CompetitorModel()
    @StateObject private var analyzer = CompetitorAnalyzer()
    @ObservedObject private var loc = Loc.shared

    @State private var query = ""
    @AppStorage("comp_limit") private var limit = 24
    @AppStorage("comp_frames") private var doFrames = false
    @AppStorage("comp_transcribe") private var doTranscribe = false
    @AppStorage("tx_language") private var languageRaw = TranscriptLanguage.auto.rawValue
    @AppStorage("threshold") private var threshold = 0.30
    @AppStorage("outputFolderPath") private var outputFolderPath = ""
    @State private var csvNotice = false

    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"; return f
    }()

    var body: some View {
        VStack(spacing: 14) {
            header
            ScrollView {
                VStack(spacing: 14) {
                    inputSection
                    if !MediaEnumerator.isAvailable {
                        Text(loc.ytdlpMissing).font(.caption).foregroundStyle(.orange)
                    }
                    if model.loading { ProgressView(loc.loadingList).controlSize(.small) }
                    if let e = model.loadError { Text(e).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center) }
                    if !model.entries.isEmpty { selectionBar; toggles; grid }
                    if analyzer.running { runningSection }
                    if let s = analyzer.summary, !analyzer.running { resultsSection(s) }
                }
                .padding(.horizontal, 2)
            }
            if !model.entries.isEmpty && !analyzer.running { runBar }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 620)
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text(loc.tabCompetitors).font(.largeTitle).bold()
            Text(loc.competitorsSubtitle).foregroundStyle(.secondary)
        }
    }

    private var inputSection: some View {
        HStack(spacing: 8) {
            TextField(loc.competitorInputPlaceholder, text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { find() }
                .disabled(model.loading || analyzer.running)
            Stepper("\(loc.limitLabel): \(limit)", value: $limit, in: 1...100)
                .fixedSize()
            Button(loc.find) { find() }
                .disabled(model.loading || analyzer.running || query.trimmingCharacters(in: .whitespaces).isEmpty || !MediaEnumerator.isAvailable)
        }
    }

    private var selectionBar: some View {
        HStack {
            Text(loc.selectedOf(model.selected.count, model.entries.count)).font(.callout)
            Spacer()
            Button(loc.selectAll) { model.selectAll() }.disabled(analyzer.running || model.selected.count == model.entries.count)
            Button(loc.clearAll) { model.clear() }.disabled(analyzer.running || model.selected.isEmpty)
        }
    }

    private var toggles: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.square.fill").foregroundStyle(.tint)
                Text(loc.metricsToggle).bold()
                Text(loc.metricsAlwaysOn).font(.caption2).foregroundStyle(.secondary)
            }
            Toggle(loc.doFrames, isOn: $doFrames).disabled(analyzer.running)
            Toggle(loc.doTranscribe, isOn: $doTranscribe)
                .disabled(analyzer.running || !WhisperEngine.isAvailable)
            if doTranscribe && WhisperEngine.isAvailable {
                HStack {
                    Text(loc.languageLabel).font(.caption)
                    Picker("", selection: $languageRaw) {
                        Text(loc.langAuto).tag(TranscriptLanguage.auto.rawValue)
                        Text(loc.langUk).tag(TranscriptLanguage.uk.rawValue)
                        Text(loc.langRu).tag(TranscriptLanguage.ru.rawValue)
                        Text(loc.langEn).tag(TranscriptLanguage.en.rawValue)
                    }.labelsHidden().pickerStyle(.segmented).frame(maxWidth: 320)
                }
            }
            Text(loc.metricsHint).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private var grid: some View {
        ThumbGridView(entries: model.gridEntries, selected: $model.selected,
                      disabled: analyzer.running, thumbnail: { await model.thumbnail(for: $0) })
    }

    private var runningSection: some View {
        VStack(spacing: 8) {
            Text(loc.processingOf(analyzer.currentIndex + 1, analyzer.total)).font(.caption).foregroundStyle(.secondary)
            ProgressView(value: analyzer.overall).progressViewStyle(.linear)
            Button(loc.cancel) { analyzer.cancel() }
        }
        .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    private func resultsSection(_ s: CompetitorSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(loc.summary(s.rows.count, s.failures.count)).font(.headline)
            if !s.rows.isEmpty {
                Text("\(loc.setAverage): \(loc.colASL) \(String(format: "%.1f", s.avgShotAll))s · \(loc.colCutsMin) \(String(format: "%.1f", s.avgCutsPerMin)) · \(loc.colHook) \(String(format: "%.1f", s.avgHook))s")
                    .font(.caption).foregroundStyle(.secondary)
            }
            metricsTable(s)
            ForEach(s.failures) { f in Text("• \(f.name): \(f.message)").font(.caption).foregroundStyle(.red) }
            HStack(spacing: 10) {
                Button { exportCSV(s) } label: { Label(csvNotice ? loc.csvSaved : loc.exportCSV, systemImage: csvNotice ? "checkmark" : "tablecells") }
                    .disabled(s.rows.isEmpty)
                Button { NSWorkspace.shared.activateFileViewerSelecting([s.outputDir]) } label: { Label(loc.openFolder, systemImage: "folder") }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
    }

    private func metricsTable(_ s: CompetitorSummary) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(loc.colVideo).frame(maxWidth: .infinity, alignment: .leading)
                Group {
                    Text(loc.colDuration); Text(loc.colCuts); Text(loc.colCutsMin); Text(loc.colASL); Text(loc.colHook)
                    if doTranscribe { Text(loc.colWords) }
                }.frame(width: 56, alignment: .trailing)
            }
            .font(.caption2.bold()).foregroundStyle(.secondary)
            .padding(.vertical, 4)
            Divider()
            ForEach(s.rows) { r in
                HStack(spacing: 6) {
                    Text(r.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                    Group {
                        Text(CompetitorModel.timeText(r.metrics.duration))
                        Text("\(r.metrics.cuts)")
                        Text(String(format: "%.1f", r.metrics.cutsPerMin))
                        Text(String(format: "%.1f", r.metrics.avgShot))
                        Text(String(format: "%.1f", r.metrics.hookLen))
                        if doTranscribe { Text(r.transcriptWords.map(String.init) ?? "—") }
                    }.frame(width: 56, alignment: .trailing).monospacedDigit()
                }
                .font(.caption)
                .padding(.vertical, 3)
                Divider()
            }
        }
    }

    private var runBar: some View {
        Button { runAnalysis() } label: {
            Label(loc.analyzeSelected(model.selected.count), systemImage: "chart.bar.doc.horizontal").frame(maxWidth: .infinity)
        }
        .controlSize(.large).buttonStyle(.pressableProminent)
        .disabled(model.selected.isEmpty)
    }

    // MARK: - Actions

    private func find() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        Task { await model.enumerate(q, limit: limit) }
    }

    private func runAnalysis() {
        let entries = model.selectedEntries
        guard !entries.isEmpty else { return }
        csvNotice = false
        analyzer.run(entries: entries, doFrames: doFrames, doTranscribe: doTranscribe,
                     language: TranscriptLanguage(rawValue: languageRaw) ?? .auto,
                     threshold: threshold, baseOutputDir: makeOutputDir())
    }

    private func exportCSV(_ s: CompetitorSummary) {
        if analyzer.exportCSV(s) != nil {
            csvNotice = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { csvNotice = false }
        }
    }

    private func makeOutputDir() -> URL {
        let stamp = Self.stamp.string(from: Date())
        let label = model.label.isEmpty ? "competitors" : model.label
        let base: URL
        if !outputFolderPath.isEmpty {
            base = URL(fileURLWithPath: outputFolderPath, isDirectory: true)
        } else {
            let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
            base = movies.appendingPathComponent("SceneShot", isDirectory: true)
        }
        return base.appendingPathComponent("\(label)-competitors-\(stamp)", isDirectory: true)
    }
}
