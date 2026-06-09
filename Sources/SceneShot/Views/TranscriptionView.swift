import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// «Транскрипция» tab: same input affordances as «Кадры», driving whisper.cpp.
/// Input pieces are duplicated from ContentView on purpose (keeps the frames flow
/// provably unchanged); a later cleanup can extract a shared component.
struct TranscriptionView: View {
    @State private var source: Source?
    @State private var info: MediaInfo?
    @State private var remoteSizeText: String?
    @State private var notice = ""
    @State private var noticeIsError = false
    @State private var probing = false
    @State private var urlText = ""
    @State private var dropTargeted = false

    @State private var transcribing = false
    @State private var progress = 0.0
    @State private var phaseLabel = ""
    @State private var startTime: Date?
    @State private var userCancelled = false
    @State private var result: TranscriptRunResult?
    @State private var engine = WhisperEngine()
    @State private var downloader = Downloader()
    @State private var cloudTemp: URL?
    @ObservedObject private var loc = Loc.shared

    @AppStorage("tx_language") private var languageRaw = TranscriptLanguage.auto.rawValue
    @AppStorage("tx_txt") private var writeTxt = true
    @AppStorage("tx_srt") private var writeSrt = true
    @AppStorage("tx_outputFolderPath") private var outputFolderPath = ""
    @AppStorage("downloadFirst") private var downloadFirst = false
    @AppStorage("deleteSourcesAfter") private var deleteSourcesAfter = false

    private var available: Bool { WhisperEngine.isAvailable }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"; return f
    }()

    var body: some View {
        VStack(spacing: 16) {
            header
            ScrollView {
                VStack(spacing: 16) {
                    dropZone
                    urlRow
                    if probing { ProgressView().controlSize(.small) }
                    if let source { sourceSummary(source) }
                    modelStatus
                    if !notice.isEmpty {
                        Text(notice).font(.caption)
                            .foregroundStyle(noticeIsError ? .red : .secondary)
                            .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                    }
                    if let result, !transcribing {
                        TranscriptResultsView(result: result)
                    }
                }
                .padding(.horizontal, 2)
            }
            bottomBar
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 620)
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(spacing: 4) {
            Text(loc.tabTranscription).font(.largeTitle).bold()
            Text(loc.transcriptionSubtitle).foregroundStyle(.secondary)
        }
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform").font(.system(size: 40)).foregroundStyle(.tint)
            Text(loc.dropMedia).foregroundStyle(.secondary)
            Button { pickFile() } label: { Label(loc.chooseFile, systemImage: "folder") }
                .controlSize(.large).disabled(probing || transcribing)
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
                .disabled(probing || transcribing)
            Button(loc.load) { loadFromURL() }
                .disabled(probing || transcribing || urlText.trimmingCharacters(in: .whitespaces).isEmpty)
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
                if info?.hasAudio == true {
                    Text("🔊 " + loc.hasAudioShort).foregroundStyle(.secondary)
                } else if info != nil {
                    Text(loc.noAudioShort).foregroundStyle(.orange)
                }
                if let c = info?.audioCodec { Text(c).foregroundStyle(.secondary) }
                if let size = remoteSizeText { Text("⬇︎ \(size)").foregroundStyle(.secondary) }
            }.font(.caption)
        }
        .padding(10).frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private var modelStatus: some View {
        HStack(spacing: 6) {
            Image(systemName: available ? "checkmark.seal" : "exclamationmark.triangle")
                .foregroundStyle(available ? .green : .orange)
            Text(available ? loc.modelReady : loc.modelMissing)
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Image(systemName: "gearshape").foregroundStyle(.secondary)
            Text(loc.languageLabel + " · " + (writeTxt ? "TXT " : "") + (writeSrt ? "SRT" : ""))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    @ViewBuilder
    private var bottomBar: some View {
        if transcribing {
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
            Button { transcribe() } label: {
                Label(loc.transcribe, systemImage: "text.quote").frame(maxWidth: .infinity)
            }
            .controlSize(.large).buttonStyle(.pressableProminent)
            .disabled(source == nil || probing || !available || (!writeTxt && !writeSrt))
        }
    }

    // MARK: - Input

    private func pickFile() {
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
                guard let url else { self.failInput(L("Не вдалося прочитати файл.", "Не удалось прочитать файл.", "Couldn't read the file.")); return }
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
        case .dropboxFile(let url): resolveCloudFile(.dropbox(url))
        case .gdriveFile(let id, let url): resolveCloudFile(.gdrive(id: id, url: url))
        case .dropboxFolder, .gdriveFolder:
            failInput(L("Це посилання на папку. Відкрийте його у вкладці «Папка».", "Это ссылка на папку. Откройте её во вкладке «Папка».", "This is a folder link. Open it in the Folder tab."))
        case .plainRemote, .unknown:
            switch VideoValidation.remoteSource(from: urlText) {
            case .success(let s): setSource(s)
            case .failure(let err): failInput(err.message)
            }
        }
    }

    /// Downloads a TikTok/Instagram/YouTube video via yt-dlp, then treats it as a local file.
    private func resolveSocial(_ pageURL: String, platform: SocialPlatform) {
        guard MediaFetcher.isAvailable else {
            failInput(L("Завантаження з \(platform.rawValue) недоступне — не зібрано модуль yt-dlp (Scripts/fetch-ytdlp.sh).", "Загрузка из \(platform.rawValue) недоступна — не собран модуль yt-dlp (Scripts/fetch-ytdlp.sh).", "Downloading from \(platform.rawValue) is unavailable — yt-dlp module not built (Scripts/fetch-ytdlp.sh)."))
            return
        }
        source = nil; info = nil; remoteSizeText = nil; result = nil
        notice = L("Завантажую з \(platform.rawValue)…", "Скачиваю из \(platform.rawValue)…", "Downloading from \(platform.rawValue)…"); noticeIsError = false; probing = true
        Task {
            do {
                let temp = try await MediaFetcher().fetch(pageURL: pageURL, onProgress: { p in
                    Task { @MainActor in self.notice = L("Завантажую з \(platform.rawValue)… \(Int(p * 100))%", "Скачиваю из \(platform.rawValue)… \(Int(p * 100))%", "Downloading from \(platform.rawValue)… \(Int(p * 100))%") }
                })
                await MainActor.run { self.cloudTemp = temp; self.notice = ""; self.setSource(.file(temp)) }
            } catch {
                await MainActor.run {
                    self.probing = false; self.noticeIsError = true
                    self.notice = (error as? LocalizedError)?.errorDescription ?? L("Не вдалося завантажити відео.", "Не удалось скачать видео.", "Couldn't download the video.")
                }
            }
        }
    }

    private enum CloudFileRef { case dropbox(URL); case gdrive(id: String, url: URL) }

    private func resolveCloudFile(_ ref: CloudFileRef) {
        source = nil; info = nil; remoteSizeText = nil; result = nil
        notice = L("Відкриваю посилання…", "Открываю ссылку…", "Opening link…"); noticeIsError = false; probing = true
        Task {
            do {
                let temp: URL
                switch ref {
                case .dropbox(let url):
                    if OAuthManager.shared.isConnected(.dropbox) {
                        temp = try await DropboxClient().downloadSharedFile(
                            sharedLink: url.absoluteString, pathLower: nil, suggestedName: url.lastPathComponent)
                    } else {
                        await MainActor.run { self.notice = ""; self.setSource(.remote(Self.dropboxDirect(url))) }
                        return
                    }
                case .gdrive(let id, let url):
                    guard OAuthManager.shared.isConnected(.gdrive) else { throw CloudError.notConnected(.gdrive) }
                    temp = try await GoogleDriveClient().download(fileId: id, suggestedName: url.lastPathComponent)
                }
                await MainActor.run { self.cloudTemp = temp; self.notice = ""; self.setSource(.file(temp)) }
            } catch {
                await MainActor.run {
                    self.probing = false; self.noticeIsError = true
                    self.notice = (error as? LocalizedError)?.errorDescription ?? L("Не вдалося відкрити посилання.", "Не удалось открыть ссылку.", "Couldn't open the link.")
                }
            }
        }
    }

    private func setSource(_ s: Source) {
        source = s; info = nil; remoteSizeText = nil; notice = ""; noticeIsError = false; result = nil
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
                    if !probed.hasAudio && probed.durationSeconds != nil {
                        self.notice = L("У файлі, схоже, немає звукової доріжки.", "В файле, похоже, нет звуковой дорожки.", "The file appears to have no audio track.")
                        self.noticeIsError = false
                    }
                }
            } catch {
                await MainActor.run {
                    self.probing = false; self.source = nil; self.noticeIsError = true
                    self.notice = (error as? LocalizedError)?.errorDescription ?? L("Помилка читання файлу.", "Ошибка чтения файла.", "Error reading the file.")
                }
            }
        }
    }

    private func failInput(_ message: String) { noticeIsError = true; notice = message }

    private func clearCloudTemp() {
        if let t = cloudTemp {
            try? FileManager.default.removeItem(at: t)
            let parent = t.deletingLastPathComponent()
            if parent.lastPathComponent.hasPrefix("sceneshot-dl-") {
                try? FileManager.default.removeItem(at: parent)
            }
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

    // MARK: - Transcription

    private func transcribe() {
        guard let source else { return }
        let outDir = makeTranscriptOutputDir(for: source)
        var params = TranscribeParams()
        params.language = TranscriptLanguage(rawValue: languageRaw) ?? .auto
        params.writeTxt = writeTxt
        params.writeSrt = writeSrt
        let duration = info?.durationSeconds
        let useDownloadFirst = source.isRemote && downloadFirst
        let probed = info ?? MediaInfo()

        transcribing = true; progress = 0; userCancelled = false; result = nil; notice = ""
        startTime = Date()
        phaseLabel = useDownloadFirst ? loc.downloadingVideo : loc.recognizing

        Task {
            var tempToCleanup: URL?
            do {
                var work = source
                var workInfo = probed
                if useDownloadFirst, case .remote(let url) = source {
                    let temp = try await downloader.download(url) { p in Task { @MainActor in self.progress = p * 0.1 } }
                    tempToCleanup = temp
                    work = .file(temp)
                    if workInfo.durationSeconds == nil { workInfo = (try? await MediaProbe.probe(temp.path)) ?? workInfo }
                    await MainActor.run { self.progress = 0; self.startTime = Date(); self.phaseLabel = loc.recognizing }
                }

                let outcome = try await engine.transcribe(
                    source: work, info: workInfo, outputDir: outDir, params: params,
                    durationSeconds: duration, onProgress: { p in Task { @MainActor in self.progress = p } })

                if let t = tempToCleanup { try? FileManager.default.removeItem(at: t) }
                await MainActor.run {
                    self.finish()
                    switch outcome {
                    case .done(let dir, let files):
                        let warning = SRTSanity.check(files.srt)
                        self.result = .done(dir: dir, txt: files.txt, srt: files.srt, text: files.text, srtWarning: warning)
                        NSWorkspace.shared.activateFileViewerSelecting([dir])
                    case .empty(let dir):
                        self.result = .empty(dir: dir)
                    case .cancelled:
                        self.result = .cancelled
                    }
                    self.cleanupSourceIfNeeded()
                }
            } catch {
                if let t = tempToCleanup { try? FileManager.default.removeItem(at: t) }
                await MainActor.run {
                    self.finish()
                    if self.userCancelled || error is CancellationError {
                        self.result = .cancelled
                    } else {
                        let d = Self.describeError(error)
                        self.result = .error(message: d.message, technical: d.technical)
                    }
                    self.cleanupSourceIfNeeded()
                }
            }
        }
    }

    private func cleanupSourceIfNeeded() {
        guard deleteSourcesAfter, cloudTemp != nil else { return }
        clearCloudTemp()
        source = nil
        info = nil
        remoteSizeText = nil
    }

    private func finish() { transcribing = false; progress = 0; phaseLabel = ""; startTime = nil }

    private func cancelAll() { userCancelled = true; downloader.cancel(); engine.cancel() }

    private func etaText() -> String? {
        guard let start = startTime, progress > 0.03 else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        let remaining = max(0, elapsed / progress - elapsed)
        let t = Int(remaining.rounded())
        let min = L("хв", "мин", "min"), sec = L("с", "с", "s")
        return t >= 60 ? "\(t / 60) \(min) \(t % 60) \(sec)" : "\(t) \(sec)"
    }

    private func makeTranscriptOutputDir(for source: Source) -> URL {
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
        return base.appendingPathComponent("\(name)-transcript-\(stamp)", isDirectory: true)
    }

    private static func describeError(_ error: Error) -> (message: String, technical: String?) {
        let generic = L("Помилка розпізнавання.", "Ошибка распознавания.", "Recognition error.")
        if let ae = error as? AudioExtractError { return (ae.errorDescription ?? generic, nil) }
        if let ff = error as? FFmpegError {
            if case .failed(_, let stderr) = ff {
                return (ff.errorDescription ?? generic, stderr)
            }
            return (ff.errorDescription ?? generic, nil)
        }
        return ((error as? LocalizedError)?.errorDescription ?? generic, nil)
    }
}
