import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Loads a folder (local or cloud) into grid entries and manages selection + thumbnails.
@MainActor
final class FolderBatchModel: ObservableObject {
    @Published var entries: [GridEntry] = []
    @Published var selected: Set<String> = []
    @Published var loading = false
    @Published var loadError: String?
    @Published var label: String = ""           // folder name, used for the output subfolder

    private var thumbs: [String: NSImage] = [:]
    private var dropboxShare: String?
    private var cloudItems: [String: CloudItem] = [:]

    var hasContent: Bool { !entries.isEmpty }

    func reset() {
        entries = []; selected = []; loadError = nil; thumbs = [:]
        dropboxShare = nil; cloudItems = [:]; label = ""
    }

    // MARK: Local folder

    func loadLocalFolder(_ url: URL) {
        reset()
        label = url.lastPathComponent
        loading = true
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey],
                                                    options: [.skipsHiddenFiles])) ?? []
        var found: [GridEntry] = []
        for file in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where VideoValidation.isVideoFile(file) {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }
            found.append(GridEntry(
                id: file.path,
                name: file.lastPathComponent,
                subtitle: size.map { Self.sizeText(Int64($0)) },
                source: .local(file)))
        }
        entries = found
        loading = false
        if found.isEmpty { loadError = L("У цій папці немає відеофайлів.", "В этой папке нет видеофайлов.", "No video files in this folder.") }
    }

    // MARK: Dropbox folder

    func loadDropboxFolder(_ shareURL: String) async {
        reset()
        label = "Dropbox"
        loading = true
        defer { loading = false }
        do {
            let items = try await DropboxClient().listFolder(sharedLink: shareURL)
            dropboxShare = shareURL
            applyCloud(items, makeSource: { .dropbox(shareURL: shareURL, pathLower: $0.pathLower) })
            if items.isEmpty { loadError = L("У папці Dropbox немає відео.", "В папке Dropbox нет видео.", "No videos in the Dropbox folder.") }
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? L("Не вдалося прочитати папку Dropbox.", "Не удалось прочитать папку Dropbox.", "Couldn't read the Dropbox folder.")
        }
    }

    // MARK: Google Drive folder

    func loadGDriveFolder(id: String) async {
        reset()
        label = "Google Drive"
        loading = true
        defer { loading = false }
        do {
            let items = try await GoogleDriveClient().listFolder(folderId: id)
            applyCloud(items, makeSource: { .gdrive(fileId: $0.id) })
            if items.isEmpty { loadError = L("У папці Google Drive немає відео.", "В папке Google Drive нет видео.", "No videos in the Google Drive folder.") }
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? L("Не вдалося прочитати папку Google Drive.", "Не удалось прочитать папку Google Drive.", "Couldn't read the Google Drive folder.")
        }
    }

    private func applyCloud(_ items: [CloudItem], makeSource: (CloudItem) -> BatchSource) {
        var found: [GridEntry] = []
        for item in items {
            cloudItems[item.id] = item
            found.append(GridEntry(
                id: item.id, name: item.name, subtitle: item.sizeText,
                source: makeSource(item)))
        }
        entries = found
    }

    // MARK: Thumbnails

    func thumbnail(for entry: GridEntry) async -> NSImage? {
        if let cached = thumbs[entry.id] { return cached }
        var image: NSImage?
        switch entry.source {
        case .local(let url):
            image = await LocalThumb.generate(url)
        case .dropbox(let share, _):
            if let item = cloudItems[entry.id] {
                image = await DropboxClient().videoThumbnail(for: item, sharedLink: share)
            }
        case .gdrive:
            if let item = cloudItems[entry.id] {
                image = await GoogleDriveClient().thumbnail(for: item)
            }
        case .remoteVideo:
            image = nil   // not used in the folder grid (Competitors tab handles its own thumbnails)
        }
        if let image { thumbs[entry.id] = image }
        return image
    }

    // MARK: Selection

    func selectAll() { selected = Set(entries.map { $0.id }) }
    func clearSelection() { selected = [] }

    var selectedItems: [BatchItem] {
        entries.filter { selected.contains($0.id) }
            .map { BatchItem(id: $0.id, name: $0.name, source: $0.source) }
    }

    private static func sizeText(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb >= 1 ? String(format: "%.1f \(L("МБ", "МБ", "MB"))", mb) : String(format: "%.0f \(L("КБ", "КБ", "KB"))", Double(bytes) / 1024)
    }
}

struct FolderBatchView: View {
    @StateObject private var model = FolderBatchModel()
    @StateObject private var processor = BatchProcessor()
    @ObservedObject private var oauth = OAuthManager.shared
    @ObservedObject private var loc = Loc.shared

    @State private var folderLink = ""
    @State private var connecting = false
    @State private var connectError: String?

    @AppStorage("batchDoFrames") private var doFrames = true
    @AppStorage("batchDoTranscribe") private var doTranscribe = false
    @AppStorage("tx_language") private var languageRaw = TranscriptLanguage.auto.rawValue

    // Shared frame settings (same keys as the «Кадры» tab).
    @AppStorage("threshold") private var threshold = 0.30
    @AppStorage("minInterval") private var minInterval = 0.0
    @AppStorage("format") private var formatRaw = ImageFormat.jpg.rawValue
    @AppStorage("jpegQuality") private var jpegQuality = 3
    @AppStorage("maxWidth") private var maxWidth = 0
    @AppStorage("maxFrames") private var maxFrames = 0
    @AppStorage("outputFolderPath") private var outputFolderPath = ""
    @AppStorage("filenameTemplate") private var filenameTemplate = "scene_{index}_{time}"
    @AppStorage("dedupScenes") private var dedupScenes = true
    @AppStorage("settleDelay") private var settleDelay = 0.4
    @AppStorage("rejectLowDetail") private var rejectLowDetail = true
    @AppStorage("stitchFrames") private var batchStitch = true

    @State private var folderSelections: [String: [String]] = [:]   // videoId → ordered frame ids
    @State private var batchSaved = false
    @State private var savedFramesTotal = 0
    @State private var savingBatch = false

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"; return f
    }()

    var body: some View {
        VStack(spacing: 14) {
            header
            ScrollView {
                VStack(spacing: 14) {
                    inputSection
                    if model.loading { ProgressView(loc.loadingList).controlSize(.small) }
                    if let err = model.loadError {
                        Text(err).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
                    }
                    if model.hasContent && processor.summary == nil { selectionBar; actionToggles; grid }
                    if processor.running { runningSection }
                    if let summary = processor.summary, !processor.running {
                        if batchSaved { summarySection(summary) }
                        else { frameSelectionSection(summary) }
                    }
                }
                .padding(.horizontal, 2)
            }
            if model.hasContent && processor.summary == nil && !processor.running { runBar }
            if let summary = processor.summary, !processor.running, !batchSaved, hasStagedFrames(summary) {
                saveAllBar(summary)
            }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 620)
    }

    // MARK: Pieces

    private var header: some View {
        VStack(spacing: 4) {
            Text(loc.tabFolder).font(.largeTitle).bold()
            Text(loc.folderSubtitle).foregroundStyle(.secondary)
        }
    }

    private var inputSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                TextField(loc.folderLinkPlaceholder, text: $folderLink)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { loadFromLink() }
                    .disabled(model.loading || processor.running)
                Button(loc.openAction) { loadFromLink() }
                    .disabled(model.loading || processor.running || folderLink.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack(spacing: 10) {
                Button {
                    pickLocalFolder()
                } label: { Label(loc.chooseLocalFolder, systemImage: "folder") }
                    .disabled(model.loading || processor.running)
                Spacer()
                cloudConnectControls
            }
            if let connectError {
                Text(connectError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var cloudConnectControls: some View {
        HStack(spacing: 8) {
            if Secrets.hasDropbox {
                connectButton(.dropbox)
            }
            if Secrets.hasGoogle {
                connectButton(.gdrive)
            }
            if !Secrets.hasDropbox && !Secrets.hasGoogle {
                Text(loc.cloudNotConfigured)
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func connectButton(_ provider: CloudProvider) -> some View {
        Group {
            if oauth.isConnected(provider) {
                Button {
                    oauth.disconnect(provider)
                } label: { Label(loc.disconnectProvider(provider.displayName), systemImage: "checkmark.seal.fill") }
                    .foregroundStyle(.green)
            } else {
                Button {
                    connect(provider)
                } label: { Label(loc.connectProvider(provider.displayName), systemImage: "person.badge.key") }
                    .disabled(connecting)
            }
        }
        .controlSize(.small)
    }

    private var selectionBar: some View {
        HStack {
            Text(loc.selectedOf(model.selected.count, model.entries.count))
                .font(.callout)
            Spacer()
            Button(loc.selectAll) { model.selectAll() }
                .disabled(processor.running || model.selected.count == model.entries.count)
            Button(loc.clearAll) { model.clearSelection() }
                .disabled(processor.running || model.selected.isEmpty)
        }
    }

    private var actionToggles: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(loc.doFrames, isOn: $doFrames).disabled(processor.running)
            Toggle(loc.doTranscribe, isOn: $doTranscribe)
                .disabled(processor.running || !BatchProcessor.transcriptionAvailable)
            if !BatchProcessor.transcriptionAvailable {
                Text(loc.transcribeSoon)
                    .font(.caption2).foregroundStyle(.secondary)
            } else if doTranscribe {
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
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private var grid: some View {
        ThumbGridView(
            entries: model.entries,
            selected: $model.selected,
            disabled: processor.running,
            thumbnail: { await model.thumbnail(for: $0) }
        )
    }

    private var runningSection: some View {
        VStack(spacing: 8) {
            Text(loc.processingOf(processor.currentIndex + 1, processor.total))
                .font(.caption).foregroundStyle(.secondary)
            ProgressView(value: processor.overall).progressViewStyle(.linear)
            VStack(spacing: 4) {
                ForEach(model.entries.filter { model.selected.contains($0.id) }) { entry in
                    HStack {
                        statusIcon(processor.status(for: entry.id))
                        Text(entry.name).font(.caption).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(statusText(processor.status(for: entry.id)))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Button(loc.cancel) { processor.cancel() }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    private func summarySection(_ summary: BatchSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(loc.savedFrames(savedFramesTotal) + (batchStitch ? " " + loc.stitchedSaved : "")).font(.headline)
            }
            ForEach(summary.failures) { f in
                Text("• \(f.name): \(f.message)").font(.caption).foregroundStyle(.red)
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([summary.outputDir])
            } label: { Label(loc.openOutputFolder, systemImage: "folder") }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.08)))
    }

    /// Per-video frame selection after a batch run — one section per video.
    private func frameSelectionSection(_ summary: BatchSummary) -> some View {
        let staged = summary.videoResults.filter { !$0.stagedFrames.isEmpty }
        return VStack(alignment: .leading, spacing: 12) {
            Text(loc.summary(summary.doneCount, summary.failures.count)).font(.headline)
            ForEach(summary.failures) { f in
                Text("• \(f.name): \(f.message)").font(.caption).foregroundStyle(.red)
            }
            if staged.isEmpty {
                Button { NSWorkspace.shared.activateFileViewerSelecting([summary.outputDir]) } label: {
                    Label(loc.openOutputFolder, systemImage: "folder")
                }
            } else {
                Text(loc.selectFramesHint).font(.caption).foregroundStyle(.secondary)
                ForEach(staged) { vr in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(vr.name).font(.callout).bold().lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(loc.selectedOf((folderSelections[vr.id] ?? []).count, vr.stagedFrames.count))
                                .font(.caption2).foregroundStyle(.secondary)
                            Button(loc.selectAll) { folderSelections[vr.id] = vr.stagedFrames.map { $0.id } }
                                .controlSize(.small)
                            Button(loc.clearAll) { folderSelections[vr.id] = [] }
                                .controlSize(.small)
                        }
                        FrameSelectGrid(frames: vr.stagedFrames, order: bindingForVideo(vr.id))
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.05)))
                }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private func saveAllBar(_ summary: BatchSummary) -> some View {
        Button { saveAllFrames(summary) } label: {
            HStack(spacing: 8) {
                if savingBatch { ProgressView().controlSize(.small).tint(.white) }
                Label(loc.saveSelectedFrames(totalSelected), systemImage: "square.and.arrow.down")
            }.frame(maxWidth: .infinity)
        }
        .controlSize(.large).buttonStyle(.pressableProminent)
        .disabled(totalSelected == 0 || savingBatch)
    }

    private func hasStagedFrames(_ summary: BatchSummary) -> Bool {
        summary.videoResults.contains { !$0.stagedFrames.isEmpty }
    }

    private var totalSelected: Int { folderSelections.values.reduce(0) { $0 + $1.count } }

    private func bindingForVideo(_ id: String) -> Binding<[String]> {
        Binding(get: { folderSelections[id] ?? [] }, set: { folderSelections[id] = $0 })
    }

    private func saveAllFrames(_ summary: BatchSummary) {
        guard !savingBatch else { return }
        let format = ImageFormat(rawValue: formatRaw) ?? .jpg
        let stitchOn = batchStitch
        // Snapshot per-video jobs (output dir + selected URLs in click order).
        var jobs: [(out: URL, urls: [URL])] = []
        for vr in summary.videoResults where !vr.stagedFrames.isEmpty {
            let order = folderSelections[vr.id] ?? []
            guard !order.isEmpty else { continue }
            let byId = Dictionary(uniqueKeysWithValues: vr.stagedFrames.map { ($0.id, $0) })
            let urls = order.compactMap { byId[$0]?.url }
            if !urls.isEmpty { jobs.append((vr.outputDir, urls)) }
        }
        guard !jobs.isEmpty else { return }
        let stagingDirs = summary.videoResults.compactMap { $0.stagingDir }
        let outBase = summary.outputDir

        savingBatch = true
        Task { @MainActor in
            await Task.detached(priority: .userInitiated) {
                for job in jobs {
                    try? FileManager.default.createDirectory(at: job.out, withIntermediateDirectories: true)
                    for u in job.urls {
                        let dest = job.out.appendingPathComponent(u.lastPathComponent)
                        try? FileManager.default.removeItem(at: dest)
                        try? FileManager.default.copyItem(at: u, to: dest)
                    }
                }
            }.value
            if stitchOn {
                for job in jobs {
                    FrameStitcher.stitch(job.urls, to: job.out.appendingPathComponent("combined.\(format.ext)"), format: format)
                }
            }
            for d in stagingDirs { try? FileManager.default.removeItem(at: d) }
            savedFramesTotal = jobs.reduce(0) { $0 + $1.urls.count }
            savingBatch = false
            batchSaved = true
            NSWorkspace.shared.activateFileViewerSelecting([outBase])
        }
    }

    private var runBar: some View {
        Button {
            runBatch()
        } label: {
            Label(loc.processSelected(model.selected.count), systemImage: "play.fill")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.pressableProminent)
        .disabled(model.selected.isEmpty || !anyActionEnabled)
    }

    private var anyActionEnabled: Bool {
        (doFrames) || (doTranscribe && BatchProcessor.transcriptionAvailable)
    }

    @ViewBuilder
    private func statusIcon(_ status: BatchItemStatus) -> some View {
        switch status {
        case .waiting:           Image(systemName: "clock").foregroundStyle(.secondary)
        case .downloading, .processing: ProgressView().controlSize(.small)
        case .done:              Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .cancelled:         Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }

    private func statusText(_ status: BatchItemStatus) -> String {
        switch status {
        case .waiting:               return loc.statusWaiting
        case .downloading(let p):    return loc.statusDownloading(Int(p * 100))
        case .processing(let p):     return loc.statusProcessing(Int(p * 100))
        case .done:                  return loc.statusDone
        case .failed(let m):         return m
        case .cancelled:             return loc.statusCancelled
        }
    }

    // MARK: Actions

    private func loadFromLink() {
        connectError = nil
        resetBatchState()
        switch CloudLink.detect(folderLink) {
        case .dropboxFolder(let url):
            if Secrets.hasDropbox && !oauth.isConnected(.dropbox) {
                model.reset(); model.loadError = L("Підключіть Dropbox, щоб відкрити папку.", "Подключите Dropbox, чтобы открыть папку.", "Connect Dropbox to open the folder.")
                return
            }
            Task { await model.loadDropboxFolder(url.absoluteString) }
        case .gdriveFolder(let id, _):
            if Secrets.hasGoogle && !oauth.isConnected(.gdrive) {
                model.reset(); model.loadError = L("Підключіть Google Drive, щоб відкрити папку.", "Подключите Google Drive, чтобы открыть папку.", "Connect Google Drive to open the folder.")
                return
            }
            Task { await model.loadGDriveFolder(id: id) }
        case .dropboxFile, .gdriveFile:
            model.reset(); model.loadError = L("Це посилання на файл. Відкрийте його у вкладці «Кадри».", "Это ссылка на файл. Откройте её во вкладке «Кадры».", "This is a file link. Open it in the Frames tab.")
        case .plainRemote, .unknown:
            model.reset(); model.loadError = L("Потрібне посилання на папку Dropbox або Google Drive.", "Нужна ссылка на папку Dropbox или Google Drive.", "A Dropbox or Google Drive folder link is required.")
        }
    }

    private func pickLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        resetBatchState()
        model.loadLocalFolder(url)
    }

    /// Clears a finished run (results, selections, staged temp dirs) so a new folder shows.
    private func resetBatchState() {
        if let s = processor.summary {
            for vr in s.videoResults { if let d = vr.stagingDir { try? FileManager.default.removeItem(at: d) } }
        }
        processor.reset()
        folderSelections = [:]; batchSaved = false; savedFramesTotal = 0
    }

    private func connect(_ provider: CloudProvider) {
        connecting = true
        connectError = nil
        Task {
            defer { connecting = false }
            do { try await oauth.connect(provider) }
            catch is CancellationError { }
            catch {
                if case CloudError.authCancelled = error { return }
                connectError = (error as? LocalizedError)?.errorDescription ?? L("Не вдалося підключитися.", "Не удалось подключиться.", "Couldn't connect.")
            }
        }
    }

    private func runBatch() {
        let items = model.selectedItems
        guard !items.isEmpty else { return }
        folderSelections = [:]; batchSaved = false; savedFramesTotal = 0
        let outDir = makeBatchOutputDir()
        var params = ExtractParams()
        params.threshold = threshold
        params.minInterval = minInterval
        params.format = ImageFormat(rawValue: formatRaw) ?? .jpg
        params.jpegQuality = jpegQuality
        params.maxWidth = max(0, maxWidth)
        params.maxFrames = max(0, maxFrames)
        params.filenameTemplate = filenameTemplate
        params.dedup = dedupScenes
        params.settleDelay = max(0, settleDelay)
        params.rejectLowDetail = rejectLowDetail
        processor.run(items: items, doFrames: doFrames, doTranscribe: doTranscribe,
                      language: TranscriptLanguage(rawValue: languageRaw) ?? .auto,
                      params: params, baseOutputDir: outDir)
    }

    private func makeBatchOutputDir() -> URL {
        let stamp = Self.stampFormatter.string(from: Date())
        let labelPart = model.label.isEmpty ? "batch" : model.label
        let base: URL
        if !outputFolderPath.isEmpty {
            base = URL(fileURLWithPath: outputFolderPath, isDirectory: true)
        } else {
            let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
            base = movies.appendingPathComponent("SceneShot", isDirectory: true)
        }
        return base.appendingPathComponent("\(labelPart)-batch-\(stamp)", isDirectory: true)
    }
}
