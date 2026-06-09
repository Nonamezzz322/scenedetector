import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Unified «Видео» tab: one input, with checkboxes for frames and/or transcription
/// (like the Folder tab). Runs the selected actions on a single video into one folder.
struct VideoView: View {
    @State private var source: Source?
    @State private var info: MediaInfo?
    @State private var remoteSizeText: String?
    @State private var notice = ""
    @State private var noticeIsError = false
    @State private var probing = false
    @State private var urlText = ""
    @State private var dropTargeted = false

    @State private var working = false
    @State private var progress = 0.0
    @State private var phaseLabel = ""
    @State private var startTime: Date?
    @State private var userCancelled = false
    @State private var frameResult: RunResult?       // empty/error/cancelled only (done → staged)
    @State private var transcriptResult: TranscriptRunResult?
    @State private var translatingUk = false
    @State private var pendingUk: PendingUkTranslation?
    @State private var stagedFrames: [FrameRef] = [] // extracted, awaiting user selection
    @State private var stagingDir: URL?
    @State private var pendingOutputDir: URL?
    @State private var frameOrder: [String] = []     // selected frame ids in click order
    @State private var savedDir: URL?
    @State private var savedCount = 0
    @State private var saving = false
    @AppStorage("stitchFrames") private var stitch = true
    @AppStorage("translateUk") private var translateUk = false
    @State private var extractor = SceneExtractor()
    @State private var whisper = WhisperEngine()
    @State private var downloader = Downloader()
    @State private var cloudTemp: URL?
    @ObservedObject private var loc = Loc.shared

    // Actions (shared keys with the Folder/Competitors batch toggles where sensible).
    @AppStorage("vid_frames") private var doFrames = true
    @AppStorage("vid_transcribe") private var doTranscribe = false

    // Settings (set in the gear screen).
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
    @AppStorage("downloadFirst") private var downloadFirst = false
    @AppStorage("deleteSourcesAfter") private var deleteSourcesAfter = false
    @AppStorage("tx_language") private var txLanguage = TranscriptLanguage.auto.rawValue
    @AppStorage("tx_txt") private var txTxt = true
    @AppStorage("tx_srt") private var txSrt = true

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"; return f
    }()

    private var whisperReady: Bool { WhisperEngine.isAvailable }
    private var willTranscribe: Bool { doTranscribe && whisperReady }
    private var anyAction: Bool { doFrames || willTranscribe }

    var body: some View {
        VStack(spacing: 16) {
            header
            ScrollView {
                VStack(spacing: 16) {
                    dropZone
                    urlRow
                    if probing { ProgressView().controlSize(.small) }
                    if let source { sourceSummary(source) }
                    actions
                    if !notice.isEmpty {
                        Text(notice).font(.caption)
                            .foregroundStyle(noticeIsError ? .red : .secondary)
                            .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                    }
                    if !working {
                        if !stagedFrames.isEmpty && savedDir == nil { selectionSection }
                        if let savedDir { savedCard(savedDir) }
                        if let frameResult { ResultsView(result: frameResult, onRetryMoreSensitive: retryMoreSensitive) }
                        if let transcriptResult { TranscriptResultsView(result: transcriptResult) }
                        if translatingUk {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(loc.translatingUk).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
            bottomBar
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 620)
        .background(translatorHost)
    }

    /// Hosts the on-device translation task (0-size). Only present on macOS 15+ while a
    /// non-Ukrainian transcript awaits its Ukrainian translation.
    @ViewBuilder private var translatorHost: some View {
        if #available(macOS 15.0, *), let p = pendingUk {
            UkrainianTranslator(text: p.text, sourceLang: p.lang, onResult: { uk in finishTranslation(uk, p) })
                .id(p.id)
        }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(spacing: 4) {
            Text("SceneShot").font(.largeTitle).bold()
            Text(loc.videoSubtitle).foregroundStyle(.secondary)
        }
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: "film.stack").font(.system(size: 40)).foregroundStyle(.tint)
            Text(loc.dropVideo).foregroundStyle(.secondary)
            Button { pickMedia() } label: { Label(loc.chooseVideo, systemImage: "folder") }
                .controlSize(.large).disabled(probing || working)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 28)
        .background(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
            .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5)))
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(dropTargeted ? Color.accentColor.opacity(0.08) : Color.clear))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { handleDrop($0) }
    }

    private var urlRow: some View {
        HStack(spacing: 8) {
            TextField(loc.urlPlaceholder, text: $urlText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { loadFromURL() }
                .disabled(probing || working)
            Button(loc.load) { loadFromURL() }
                .disabled(probing || working || urlText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func sourceSummary(_ source: Source) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: source.isRemote ? "link" : "doc")
                Text(source.displayName).lineLimit(1).truncationMode(.middle)
            }.font(.callout)
            HStack(spacing: 14) {
                if let d = info?.durationText { Text("⏱ \(d)") }
                if let r = info?.resolutionText { Text("🖼 \(r)") }
                if info?.hasAudio == true { Text("🔊 \(loc.hasAudioShort)").foregroundStyle(.secondary) }
                else if info != nil { Text(loc.noAudioShort).foregroundStyle(.orange) }
                if let size = remoteSizeText { Text("⬇︎ \(size)").foregroundStyle(.secondary) }
            }.font(.caption)
        }
        .padding(10).frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(loc.doFrames, isOn: $doFrames).disabled(working)
            Toggle(loc.doTranscribe, isOn: $doTranscribe).disabled(working || !whisperReady)
            if doTranscribe && !whisperReady {
                Text(loc.modelMissing).font(.caption2).foregroundStyle(.orange)
            } else if willTranscribe {
                HStack {
                    Text(loc.languageLabel).font(.caption)
                    Picker("", selection: $txLanguage) {
                        Text(loc.langAuto).tag(TranscriptLanguage.auto.rawValue)
                        Text(loc.langUk).tag(TranscriptLanguage.uk.rawValue)
                        Text(loc.langRu).tag(TranscriptLanguage.ru.rawValue)
                        Text(loc.langEn).tag(TranscriptLanguage.en.rawValue)
                    }.labelsHidden().pickerStyle(.segmented).frame(maxWidth: 320)
                }
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    @ViewBuilder
    private var bottomBar: some View {
        if working {
            VStack(spacing: 8) {
                if !phaseLabel.isEmpty { Text(phaseLabel).font(.caption).foregroundStyle(.secondary) }
                ProgressView(value: progress).progressViewStyle(.linear)
                HStack {
                    Text("\(Int(progress * 100))%").font(.caption).monospacedDigit()
                    if let eta = etaText() { Text("· \(loc.remaining)\(eta)").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button(loc.cancel) { cancelAll() }
                }
            }
        } else {
            VStack(spacing: 4) {
                Button { process() } label: {
                    Label(loc.process, systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .controlSize(.large).buttonStyle(.pressableProminent)
                .disabled(source == nil || probing || !anyAction)
                if source != nil && !anyAction {
                    Text(loc.pickAtLeastOne).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var selectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(loc.selectFramesTitle).font(.headline)
            Text(loc.selectFramesHint).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(loc.selectAll) { frameOrder = stagedFrames.map { $0.id } }
                    .disabled(frameOrder.count == stagedFrames.count)
                Button(loc.clearAll) { frameOrder = [] }
                    .disabled(frameOrder.isEmpty)
                Spacer()
                Text(loc.selectedOf(frameOrder.count, stagedFrames.count)).font(.caption).foregroundStyle(.secondary)
            }
            FrameSelectGrid(frames: stagedFrames, order: $frameOrder)
            Button { saveSelected() } label: {
                HStack(spacing: 8) {
                    if saving { ProgressView().controlSize(.small).tint(.white) }
                    Label(loc.saveSelectedFrames(frameOrder.count), systemImage: "square.and.arrow.down")
                }.frame(maxWidth: .infinity)
            }
            .controlSize(.large).buttonStyle(.pressableProminent)
            .disabled(frameOrder.isEmpty || saving)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
    }

    private func savedCard(_ dir: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(loc.savedFrames(savedCount) + (stitch ? " " + loc.stitchedSaved : "")).bold()
            }
            Button { NSWorkspace.shared.activateFileViewerSelecting([dir]) } label: {
                Label(loc.openFolder, systemImage: "folder")
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.08)))
    }

    // MARK: - Input

    private func pickMedia() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .audio, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        clearCloudTemp()
        setSource(.file(url))
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first, provider.canLoadObject(ofClass: URL.self) else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            DispatchQueue.main.async {
                guard let url else { self.failInput(L("Не вдалося прочитати перетягнутий файл.", "Не удалось прочитать перетащенный файл.", "Couldn't read the dropped file.")); return }
                self.clearCloudTemp()
                self.setSource(.file(url))
            }
        }
        return true
    }

    private func loadFromURL() {
        clearCloudTemp()
        if let platform = SocialLink.detect(urlText) { resolveSocial(urlText, platform: platform); return }
        switch CloudLink.detect(urlText) {
        case .dropboxFile(let url): resolveDropboxFile(url)
        case .gdriveFile(let id, let url): resolveGDriveFile(id: id, url: url)
        case .dropboxFolder, .gdriveFolder:
            failInput(L("Це посилання на папку. Відкрийте його у вкладці «Папка».", "Это ссылка на папку. Откройте её во вкладке «Папка».", "This is a folder link. Open it in the Folder tab."))
        case .plainRemote, .unknown:
            switch VideoValidation.remoteSource(from: urlText) {
            case .success(let s): setSource(s)
            case .failure(let err): failInput(err.message)
            }
        }
    }

    private func resolveDropboxFile(_ shareURL: URL) {
        source = nil; info = nil; remoteSizeText = nil; resetResults()
        notice = L("Відкриваю посилання Dropbox…", "Открываю ссылку Dropbox…", "Opening Dropbox link…"); noticeIsError = false; probing = true
        Task {
            if OAuthManager.shared.isConnected(.dropbox) {
                do {
                    let temp = try await DropboxClient().downloadSharedFile(sharedLink: shareURL.absoluteString, pathLower: nil, suggestedName: shareURL.lastPathComponent)
                    await MainActor.run { self.cloudTemp = temp; self.notice = ""; self.setSource(.file(temp)) }
                } catch {
                    await MainActor.run { self.probing = false; self.noticeIsError = true
                        self.notice = (error as? LocalizedError)?.errorDescription ?? L("Не вдалося відкрити посилання Dropbox.", "Не удалось открыть ссылку Dropbox.", "Couldn't open the Dropbox link.") }
                }
            } else {
                await MainActor.run { self.notice = ""; self.setSource(.remote(Self.dropboxDirect(shareURL))) }
            }
        }
    }

    private func resolveGDriveFile(id: String, url: URL) {
        source = nil; info = nil; remoteSizeText = nil; resetResults()
        notice = L("Відкриваю посилання Google Drive…", "Открываю ссылку Google Drive…", "Opening Google Drive link…"); noticeIsError = false; probing = true
        Task {
            do {
                guard OAuthManager.shared.isConnected(.gdrive) else { throw CloudError.notConnected(.gdrive) }
                let temp = try await GoogleDriveClient().download(fileId: id, suggestedName: url.lastPathComponent)
                await MainActor.run { self.cloudTemp = temp; self.notice = ""; self.setSource(.file(temp)) }
            } catch {
                await MainActor.run { self.probing = false; self.noticeIsError = true
                    self.notice = (error as? LocalizedError)?.errorDescription ?? L("Не вдалося відкрити посилання Google Drive.", "Не удалось открыть ссылку Google Drive.", "Couldn't open the Google Drive link.") }
            }
        }
    }

    private func resolveSocial(_ pageURL: String, platform: SocialPlatform) {
        guard MediaFetcher.isAvailable else {
            failInput(L("Завантаження з \(platform.rawValue) недоступне — не зібрано модуль yt-dlp (Scripts/fetch-ytdlp.sh).", "Загрузка из \(platform.rawValue) недоступна — не собран модуль yt-dlp (Scripts/fetch-ytdlp.sh).", "Downloading from \(platform.rawValue) is unavailable — yt-dlp module not built (Scripts/fetch-ytdlp.sh)."))
            return
        }
        source = nil; info = nil; remoteSizeText = nil; resetResults()
        notice = L("Завантажую з \(platform.rawValue)…", "Скачиваю из \(platform.rawValue)…", "Downloading from \(platform.rawValue)…"); noticeIsError = false; probing = true
        Task {
            do {
                let temp = try await MediaFetcher().fetch(pageURL: pageURL, onProgress: { p in
                    Task { @MainActor in self.notice = L("Завантажую з \(platform.rawValue)… \(Int(p * 100))%", "Скачиваю из \(platform.rawValue)… \(Int(p * 100))%", "Downloading from \(platform.rawValue)… \(Int(p * 100))%") }
                })
                await MainActor.run { self.cloudTemp = temp; self.notice = ""; self.setSource(.file(temp)) }
            } catch {
                await MainActor.run { self.probing = false; self.noticeIsError = true
                    self.notice = (error as? LocalizedError)?.errorDescription ?? L("Не вдалося завантажити відео.", "Не удалось скачать видео.", "Couldn't download the video.") }
            }
        }
    }

    private func setSource(_ s: Source) {
        source = s; info = nil; remoteSizeText = nil; notice = ""; noticeIsError = false; resetResults()
        probing = true
        Task {
            do {
                if case .remote(let url) = s {
                    let remote = try await Downloader.validate(url)
                    await MainActor.run { self.remoteSizeText = remote.sizeText }
                }
                let probed = try await MediaProbe.probe(s.ffmpegInput)
                await MainActor.run {
                    self.info = probed; self.probing = false
                    if probed.durationSeconds == nil && probed.width == nil {
                        self.notice = L("Джерело прийнято, але метадані прочитати не вдалося.", "Источник принят, но метаданные прочитать не удалось.", "Source accepted, but metadata couldn't be read.")
                        self.noticeIsError = false
                    }
                }
            } catch {
                await MainActor.run {
                    self.probing = false; self.source = nil; self.noticeIsError = true
                    self.notice = (error as? LocalizedError)?.errorDescription ?? L("Помилка читання відео.", "Ошибка чтения видео.", "Error reading the video.")
                }
            }
        }
    }

    private func failInput(_ message: String) { noticeIsError = true; notice = message }

    private func resetResults() {
        frameResult = nil; transcriptResult = nil
        if let s = stagingDir { try? FileManager.default.removeItem(at: s) }
        stagingDir = nil; stagedFrames = []; frameOrder = []; pendingOutputDir = nil
        savedDir = nil; savedCount = 0
    }

    private var transcriptDone: Bool { if case .done = transcriptResult { return true }; return false }

    private func clearCloudTemp() {
        if let t = cloudTemp {
            try? FileManager.default.removeItem(at: t)
            let parent = t.deletingLastPathComponent()
            if parent.lastPathComponent.hasPrefix("sceneshot-dl-") { try? FileManager.default.removeItem(at: parent) }
        }
        cloudTemp = nil
    }

    private static func dropboxDirect(_ url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = comps.queryItems?.filter { $0.name != "dl" } ?? []
        items.append(URLQueryItem(name: "dl", value: "1"))
        comps.queryItems = items
        return comps.url ?? url
    }

    // MARK: - Processing

    private func process() {
        guard let source, anyAction else { return }
        let realOut = makeOutputDir(for: source)
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("sceneshot-stage-\(UUID().uuidString)", isDirectory: true)
        let duration = info?.durationSeconds
        let useDownloadFirst = source.isRemote && downloadFirst
        let both = doFrames && willTranscribe

        working = true; progress = 0; userCancelled = false; resetResults(); notice = ""
        startTime = Date()
        phaseLabel = useDownloadFirst ? loc.downloadingVideo : (doFrames ? loc.analyzing : loc.recognizing)

        Task {
            var temp: URL?
            var work = source
            var workInfo = info ?? MediaInfo()

            // Download-first (optional).
            if useDownloadFirst, case .remote(let url) = source {
                do {
                    let t = try await downloader.download(url) { p in Task { @MainActor in self.progress = p * 0.1 } }
                    temp = t; work = .file(t)
                    if workInfo.durationSeconds == nil { workInfo = (try? await MediaProbe.probe(t.path)) ?? workInfo }
                    await MainActor.run { self.progress = 0; self.startTime = Date() }
                } catch {
                    await MainActor.run { self.finishRun(); self.noticeIsError = true
                        self.notice = (error as? LocalizedError)?.errorDescription ?? L("Не вдалося завантажити відео.", "Не удалось скачать видео.", "Couldn't download the video.") }
                    return
                }
            }

            // Frames → STAGING (user picks which to keep afterwards; nothing saved yet).
            if doFrames && !userCancelled {
                await MainActor.run { self.phaseLabel = loc.analyzing }
                do {
                    let outcome = try await extractor.extract(source: work, outputDir: staging, params: currentExtractParams(for: source),
                        durationSeconds: duration, onProgress: { p in Task { @MainActor in self.progress = both ? p * 0.5 : p } })
                    await MainActor.run {
                        switch outcome {
                        case .done(_, _, let frames):
                            self.stagedFrames = frames; self.stagingDir = staging; self.pendingOutputDir = realOut; self.frameOrder = []
                        case .empty(let dir): self.frameResult = .empty(dir: dir)
                        case .cancelled: self.frameResult = .cancelled
                        }
                    }
                } catch {
                    await MainActor.run {
                        if self.userCancelled || error is CancellationError { self.frameResult = .cancelled }
                        else { let d = Self.describeFramesError(error); self.frameResult = .error(message: d.0, technical: d.1) }
                    }
                }
            }

            // Transcription → final output folder (no selection step).
            if willTranscribe && !userCancelled {
                await MainActor.run { self.phaseLabel = loc.recognizing }
                do {
                    let outcome = try await whisper.transcribe(source: work, info: workInfo, outputDir: realOut,
                        params: currentTranscribeParams(), durationSeconds: duration,
                        onProgress: { p in Task { @MainActor in self.progress = both ? 0.5 + p * 0.5 : p } })
                    await MainActor.run {
                        switch outcome {
                        case .done(let dir, let files):
                            let warning = SRTSanity.check(files.srt)
                            self.transcriptResult = .done(dir: dir, txt: files.txt, srt: files.srt, text: files.text, srtWarning: warning)
                            self.maybeTranslate(files: files, dir: dir, warning: warning)
                        case .empty(let dir): self.transcriptResult = .empty(dir: dir)
                        case .cancelled: self.transcriptResult = .cancelled
                        }
                    }
                } catch {
                    await MainActor.run {
                        if self.userCancelled || error is CancellationError { self.transcriptResult = .cancelled }
                        else { let d = Self.describeTranscribeError(error); self.transcriptResult = .error(message: d.0, technical: d.1) }
                    }
                }
            }

            if let t = temp { try? FileManager.default.removeItem(at: t) }
            await MainActor.run {
                self.finishRun()
                // Frames staged → wait for the user to pick + save. Otherwise we're done now.
                if self.stagedFrames.isEmpty {
                    if self.transcriptDone { NSWorkspace.shared.activateFileViewerSelecting([realOut]) }
                    self.cleanupSourceIfNeeded()
                }
            }
        }
    }

    /// Copies the user-selected frames (in click order) into the output folder, optionally
    /// stitching them into one image, then cleans up the staging dir.
    private func saveSelected() {
        guard !frameOrder.isEmpty, let realOut = pendingOutputDir, !saving else { return }
        let format = ImageFormat(rawValue: formatRaw) ?? .jpg
        let byId = Dictionary(uniqueKeysWithValues: stagedFrames.map { ($0.id, $0) })
        let selected = frameOrder.compactMap { byId[$0] }
        guard !selected.isEmpty else { return }
        let urls = selected.map { $0.url }
        let stitchOn = stitch
        let staging = stagingDir

        saving = true
        Task { @MainActor in
            // Copy off the main thread so the button's spinner animates.
            await Task.detached(priority: .userInitiated) {
                try? FileManager.default.createDirectory(at: realOut, withIntermediateDirectories: true)
                for u in urls {
                    let dest = realOut.appendingPathComponent(u.lastPathComponent)
                    try? FileManager.default.removeItem(at: dest)
                    try? FileManager.default.copyItem(at: u, to: dest)
                }
            }.value
            // Stitch on the main thread (NSImage rendering).
            if stitchOn {
                FrameStitcher.stitch(urls, to: realOut.appendingPathComponent("combined.\(format.ext)"), format: format)
            }
            if let s = staging { try? FileManager.default.removeItem(at: s) }
            savedCount = selected.count
            stagingDir = nil; stagedFrames = []; frameOrder = []
            savedDir = realOut
            saving = false
            NSWorkspace.shared.activateFileViewerSelecting([realOut])
            cleanupSourceIfNeeded()
        }
    }

    private func finishRun() { working = false; progress = 0; phaseLabel = ""; startTime = nil }
    private func cancelAll() { userCancelled = true; downloader.cancel(); extractor.cancel(); whisper.cancel() }

    private func retryMoreSensitive() {
        threshold = max(0.05, ((threshold - 0.10) * 100).rounded() / 100)
        process()
    }

    private func cleanupSourceIfNeeded() {
        guard deleteSourcesAfter, cloudTemp != nil else { return }
        clearCloudTemp(); source = nil; info = nil; remoteSizeText = nil
    }

    /// If the transcript isn't Ukrainian, kick off on-device translation (macOS 15+).
    private func maybeTranslate(files: TranscriptFiles, dir: URL, warning: String?) {
        guard translateUk, #available(macOS 15.0, *) else { return }
        guard let lang = files.language?.lowercased(), lang != "uk",
              !files.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        translatingUk = true
        pendingUk = PendingUkTranslation(text: files.text, lang: lang, dir: dir,
                                         txt: files.txt, srt: files.srt, warning: warning)
    }

    /// Appends the Ukrainian translation into the same TXT and updates the shown result.
    private func finishTranslation(_ uk: String?, _ p: PendingUkTranslation) {
        translatingUk = false
        pendingUk = nil
        guard let uk, !uk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let combined = p.text + "\n\n" + loc.ukSectionHeader + "\n" + uk
        if let txt = p.txt { try? combined.write(to: txt, atomically: true, encoding: .utf8) }
        transcriptResult = .done(dir: p.dir, txt: p.txt, srt: p.srt, text: combined, srtWarning: p.warning)
    }

    private func etaText() -> String? {
        guard let start = startTime, progress > 0.03 else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        let remaining = max(0, elapsed / progress - elapsed)
        let t = Int(remaining.rounded())
        let min = L("хв", "мин", "min"), sec = L("с", "с", "s")
        return t >= 60 ? "\(t / 60) \(min) \(t % 60) \(sec)" : "\(t) \(sec)"
    }

    private func currentExtractParams(for source: Source) -> ExtractParams {
        var p = ExtractParams()
        p.threshold = threshold; p.minInterval = minInterval
        p.format = ImageFormat(rawValue: formatRaw) ?? .jpg
        p.jpegQuality = jpegQuality; p.maxWidth = max(0, maxWidth); p.maxFrames = max(0, maxFrames)
        p.filenameTemplate = filenameTemplate
        p.dedup = dedupScenes
        p.settleDelay = max(0, settleDelay)
        p.rejectLowDetail = rejectLowDetail
        p.sourceName = (source.displayName as NSString).deletingPathExtension
        return p
    }

    private func currentTranscribeParams() -> TranscribeParams {
        var tp = TranscribeParams()
        tp.language = TranscriptLanguage(rawValue: txLanguage) ?? .auto
        tp.writeTxt = txTxt; tp.writeSrt = txSrt
        return tp
    }

    private func makeOutputDir(for source: Source) -> URL {
        let stamp = Self.stampFormatter.string(from: Date())
        let name = (source.displayName as NSString).deletingPathExtension
        let base: URL
        if !outputFolderPath.isEmpty {
            base = URL(fileURLWithPath: outputFolderPath, isDirectory: true)
        } else {
            let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
            base = movies.appendingPathComponent("SceneShot", isDirectory: true)
        }
        return base.appendingPathComponent("\(name)-\(stamp)", isDirectory: true)
    }

    private static func describeFramesError(_ error: Error) -> (String, String?) {
        if let ff = error as? FFmpegError, case .failed(_, let stderr) = ff {
            var message = ff.errorDescription ?? L("Помилка витягу.", "Ошибка извлечения.", "Extraction error.")
            if stderr.contains("received no packets") || stderr.contains("Invalid argument") || stderr.contains("Server returned") {
                message = L("Не вдалося прочитати потік за посиланням. Увімкніть «Спочатку завантажити» в налаштуваннях і повторіть.",
                            "Не удалось прочитать поток по ссылке. Включите «Сначала скачать» в настройках и повторите.",
                            "Couldn't read the stream from the link. Enable “Download first” in Settings and retry.")
            }
            return (message, stderr)
        }
        return ((error as? LocalizedError)?.errorDescription ?? L("Помилка витягу.", "Ошибка извлечения.", "Extraction error."), nil)
    }

    private static func describeTranscribeError(_ error: Error) -> (String, String?) {
        let generic = L("Помилка розпізнавання.", "Ошибка распознавания.", "Recognition error.")
        if let ae = error as? AudioExtractError { return (ae.errorDescription ?? generic, nil) }
        if let ff = error as? FFmpegError {
            if case .failed(_, let stderr) = ff { return (ff.errorDescription ?? generic, stderr) }
            return (ff.errorDescription ?? generic, nil)
        }
        return ((error as? LocalizedError)?.errorDescription ?? generic, nil)
    }
}

/// A transcript awaiting Ukrainian translation (carries what's needed to rebuild the result).
private struct PendingUkTranslation: Identifiable {
    let id = UUID()
    let text: String
    let lang: String?
    let dir: URL
    let txt: URL?
    let srt: URL?
    let warning: String?
}
