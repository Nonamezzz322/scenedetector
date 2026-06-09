import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var source: Source?
    @State private var info: MediaInfo?
    @State private var remoteSizeText: String?
    @State private var notice: String = ""        // input-stage hints / errors
    @State private var noticeIsError = false
    @State private var probing = false
    @State private var urlText = ""
    @State private var dropTargeted = false

    @State private var extracting = false
    @State private var progress = 0.0
    @State private var phaseLabel = ""            // e.g. "Загрузка видео…"
    @State private var startTime: Date?
    @State private var userCancelled = false
    @State private var result: RunResult?
    @State private var extractor = SceneExtractor()
    @State private var downloader = Downloader()
    @State private var cloudTemp: URL?            // a resolved cloud file kept for reuse/cleanup
    @ObservedObject private var loc = Loc.shared

    // Persisted full-control settings.
    @AppStorage("threshold") private var threshold = 0.30
    @AppStorage("minInterval") private var minInterval = 0.0
    @AppStorage("format") private var formatRaw = ImageFormat.jpg.rawValue
    @AppStorage("jpegQuality") private var jpegQuality = 3
    @AppStorage("maxWidth") private var maxWidth = 0
    @AppStorage("maxFrames") private var maxFrames = 0
    @AppStorage("outputFolderPath") private var outputFolderPath = ""
    @AppStorage("filenameTemplate") private var filenameTemplate = "scene_{index}_{time}"
    @AppStorage("downloadFirst") private var downloadFirst = false
    @AppStorage("deleteSourcesAfter") private var deleteSourcesAfter = false

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
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
                    if !notice.isEmpty {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(noticeIsError ? .red : .secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                    if let result, !extracting {
                        ResultsView(result: result, onRetryMoreSensitive: retryMoreSensitive)
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
            Text("SceneShot").font(.largeTitle).bold()
            Text(loc.framesSubtitle).foregroundStyle(.secondary)
        }
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text(loc.dropVideo)
                .foregroundStyle(.secondary)
            Button {
                pickVideo()
            } label: {
                Label(loc.chooseVideo, systemImage: "folder")
            }
            .controlSize(.large)
            .disabled(probing || extracting)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
        )
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(dropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
    }

    private var urlRow: some View {
        HStack(spacing: 8) {
            TextField(loc.urlPlaceholder, text: $urlText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { loadFromURL() }
                .disabled(probing || extracting)
            Button(loc.load) { loadFromURL() }
                .disabled(probing || extracting || urlText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func sourceSummary(_ source: Source) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: source.isRemote ? "link" : "doc")
                Text(source.displayName).lineLimit(1).truncationMode(.middle)
            }
            .font(.callout)

            HStack(spacing: 14) {
                if let d = info?.durationText { Text("⏱ \(d)") }
                if let r = info?.resolutionText { Text("🖼 \(r)") }
                if let c = info?.codec { Text(c).foregroundStyle(.secondary) }
                if let f = info?.fps { Text(String(format: "%.0f fps", f)).foregroundStyle(.secondary) }
                if let size = remoteSizeText { Text("⬇︎ \(size)").foregroundStyle(.secondary) }
            }
            .font(.caption)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    @ViewBuilder
    private var bottomBar: some View {
        if extracting {
            VStack(spacing: 8) {
                if !phaseLabel.isEmpty {
                    Text(phaseLabel).font(.caption).foregroundStyle(.secondary)
                }
                ProgressView(value: progress).progressViewStyle(.linear)
                HStack {
                    Text("\(Int(progress * 100))%").font(.caption).monospacedDigit()
                    if let eta = etaText() {
                        Text("· \(loc.remaining)\(eta)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(loc.cancel) { cancelAll() }
                }
            }
        } else {
            Button {
                extract()
            } label: {
                Label(loc.extractFrames, systemImage: "square.grid.2x2")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.pressableProminent)
            .disabled(source == nil || probing)
        }
    }

    // MARK: - Input actions

    private func pickVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        clearCloudTemp()
        setSource(.file(url))
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first, provider.canLoadObject(ofClass: URL.self) else {
            return false
        }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            DispatchQueue.main.async {
                guard let url else {
                    self.failInput(L("Не вдалося прочитати перетягнутий файл.", "Не удалось прочитать перетащенный файл.", "Couldn't read the dropped file."))
                    return
                }
                if VideoValidation.isVideoFile(url) {
                    self.clearCloudTemp()
                    self.setSource(.file(url))
                } else {
                    self.failInput(L("Це не схоже на відеофайл.", "Это не похоже на видеофайл.", "This doesn't look like a video file."))
                }
            }
        }
        return true
    }

    private func loadFromURL() {
        clearCloudTemp()
        if let platform = SocialLink.detect(urlText) { resolveSocial(urlText, platform: platform); return }
        switch CloudLink.detect(urlText) {
        case .dropboxFile(let url):
            resolveDropboxFile(url)
        case .dropboxFolder:
            failInput(L("Це посилання на папку Dropbox. Відкрийте його у вкладці «Папка».", "Это ссылка на папку Dropbox. Откройте её во вкладке «Папка».", "This is a Dropbox folder link. Open it in the Folder tab."))
        case .gdriveFolder:
            failInput(L("Це посилання на папку Google Drive. Відкрийте його у вкладці «Папка».", "Это ссылка на папку Google Drive. Откройте её во вкладке «Папка».", "This is a Google Drive folder link. Open it in the Folder tab."))
        case .gdriveFile(let id, let url):
            resolveGDriveFile(id: id, url: url)
        case .plainRemote, .unknown:
            switch VideoValidation.remoteSource(from: urlText) {
            case .success(let s): setSource(s)
            case .failure(let err): failInput(err.message)
            }
        }
    }

    /// Resolves a Dropbox file share. Connected → download via API to a temp file;
    /// otherwise fall back to the public direct-download URL (dl=1) as a remote source.
    private func resolveDropboxFile(_ shareURL: URL) {
        source = nil; info = nil; remoteSizeText = nil; result = nil
        notice = L("Відкриваю посилання Dropbox…", "Открываю ссылку Dropbox…", "Opening Dropbox link…"); noticeIsError = false
        probing = true
        Task {
            if OAuthManager.shared.isConnected(.dropbox) {
                do {
                    let temp = try await DropboxClient().downloadSharedFile(
                        sharedLink: shareURL.absoluteString, pathLower: nil,
                        suggestedName: shareURL.lastPathComponent)
                    await MainActor.run {
                        self.cloudTemp = temp
                        self.notice = ""
                        self.setSource(.file(temp))
                    }
                } catch {
                    await MainActor.run {
                        self.probing = false
                        self.noticeIsError = true
                        self.notice = (error as? LocalizedError)?.errorDescription ?? L("Не вдалося відкрити посилання Dropbox.", "Не удалось открыть ссылку Dropbox.", "Couldn't open the Dropbox link.")
                    }
                }
            } else {
                let direct = Self.dropboxDirect(shareURL)
                await MainActor.run {
                    self.notice = ""
                    self.setSource(.remote(direct))
                }
            }
        }
    }

    /// Google Drive single-file resolution (implemented in stage C6).
    private func resolveGDriveFile(id: String, url: URL) {
        source = nil; info = nil; remoteSizeText = nil; result = nil
        notice = L("Відкриваю посилання Google Drive…", "Открываю ссылку Google Drive…", "Opening Google Drive link…"); noticeIsError = false
        probing = true
        Task {
            do {
                guard OAuthManager.shared.isConnected(.gdrive) else {
                    throw CloudError.notConnected(.gdrive)
                }
                let temp = try await GoogleDriveClient().download(fileId: id, suggestedName: url.lastPathComponent)
                await MainActor.run {
                    self.cloudTemp = temp
                    self.notice = ""
                    self.setSource(.file(temp))
                }
            } catch {
                await MainActor.run {
                    self.probing = false
                    self.noticeIsError = true
                    self.notice = (error as? LocalizedError)?.errorDescription ?? L("Не вдалося відкрити посилання Google Drive.", "Не удалось открыть ссылку Google Drive.", "Couldn't open the Google Drive link.")
                }
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

    private func clearCloudTemp() {
        if let t = cloudTemp {
            try? FileManager.default.removeItem(at: t)
            // Social downloads live in a per-item temp dir; remove the now-empty dir too.
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

    private func setSource(_ s: Source) {
        source = s
        info = nil
        remoteSizeText = nil
        notice = ""
        noticeIsError = false
        result = nil
        probing = true
        Task {
            do {
                if case .remote(let url) = s {
                    let remote = try await Downloader.validate(url)
                    await MainActor.run { self.remoteSizeText = remote.sizeText }
                }
                let probed = try await MediaProbe.probe(s.ffmpegInput)
                await MainActor.run {
                    self.info = probed
                    self.probing = false
                    if probed.durationSeconds == nil && probed.width == nil {
                        self.notice = L("Джерело прийнято, але метадані прочитати не вдалося.", "Источник принят, но метаданные прочитать не удалось.", "Source accepted, but metadata couldn't be read.")
                        self.noticeIsError = false
                    }
                }
            } catch {
                await MainActor.run {
                    self.probing = false
                    self.source = nil
                    self.noticeIsError = true
                    self.notice = (error as? LocalizedError)?.errorDescription ?? L("Помилка читання відео.", "Ошибка чтения видео.", "Error reading the video.")
                }
            }
        }
    }

    private func failInput(_ message: String) {
        noticeIsError = true
        notice = message
    }

    // MARK: - Extraction

    private func currentParams(for source: Source) -> ExtractParams {
        var params = ExtractParams()
        params.threshold = threshold
        params.minInterval = minInterval
        params.format = ImageFormat(rawValue: formatRaw) ?? .jpg
        params.jpegQuality = jpegQuality
        params.maxWidth = max(0, maxWidth)
        params.maxFrames = max(0, maxFrames)
        params.filenameTemplate = filenameTemplate
        params.sourceName = (source.displayName as NSString).deletingPathExtension
        return params
    }

    private func extract() {
        guard let source else { return }
        let outDir = makeOutputDir(for: source)
        let params = currentParams(for: source)
        let duration = info?.durationSeconds
        let useDownloadFirst = source.isRemote && downloadFirst

        extracting = true
        progress = 0
        userCancelled = false
        result = nil
        notice = ""
        startTime = Date()
        phaseLabel = useDownloadFirst ? loc.downloadingVideo : loc.analyzing

        Task {
            var tempToCleanup: URL?
            do {
                var workSource = source
                if useDownloadFirst, case .remote(let url) = source {
                    let temp = try await downloader.download(url) { p in
                        Task { @MainActor in self.progress = p }
                    }
                    tempToCleanup = temp
                    workSource = .file(temp)
                    await MainActor.run {
                        self.progress = 0
                        self.startTime = Date()
                        self.phaseLabel = loc.analyzing
                    }
                }

                let outcome = try await extractor.extract(
                    source: workSource,
                    outputDir: outDir,
                    params: params,
                    durationSeconds: duration,
                    onProgress: { p in Task { @MainActor in self.progress = p } }
                )

                if let t = tempToCleanup { try? FileManager.default.removeItem(at: t) }

                await MainActor.run {
                    self.finishExtraction()
                    switch outcome {
                    case .done(let count, let dir, let frames):
                        self.result = .done(count: count, dir: dir, frames: frames)
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
                    self.finishExtraction()
                    if self.userCancelled || error is CancellationError {
                        self.result = .cancelled
                    } else {
                        let described = Self.describeError(error)
                        self.result = .error(message: described.message, technical: described.technical)
                    }
                    self.cleanupSourceIfNeeded()
                }
            }
        }
    }

    /// When "delete sources after processing" is on, drop a downloaded temp source
    /// right away (Retry would then re-download). Local files are never touched.
    private func cleanupSourceIfNeeded() {
        guard deleteSourcesAfter, cloudTemp != nil else { return }
        clearCloudTemp()
        source = nil
        info = nil
        remoteSizeText = nil
    }

    private func finishExtraction() {
        extracting = false
        progress = 0
        phaseLabel = ""
        startTime = nil
    }

    private func retryMoreSensitive() {
        threshold = max(0.05, (threshold - 0.10).rounded(toPlaces: 2))
        extract()
    }

    private func cancelAll() {
        userCancelled = true
        downloader.cancel()
        extractor.cancel()
    }

    private func etaText() -> String? {
        guard let start = startTime, progress > 0.03 else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        let remaining = max(0, elapsed / progress - elapsed)
        let t = Int(remaining.rounded())
        let min = L("хв", "мин", "min"), sec = L("с", "с", "s")
        return t >= 60 ? "\(t / 60) \(min) \(t % 60) \(sec)" : "\(t) \(sec)"
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

    private static func describeError(_ error: Error) -> (message: String, technical: String?) {
        if let ff = error as? FFmpegError, case .failed(_, let stderr) = ff {
            var message = ff.errorDescription ?? L("Помилка витягу.", "Ошибка извлечения.", "Extraction error.")
            if stderr.contains("received no packets") || stderr.contains("Invalid argument")
                || stderr.contains("Server returned") {
                message = L("Не вдалося прочитати потік за посиланням. Увімкніть «Спочатку завантажити» в налаштуваннях і повторіть.",
                            "Не удалось прочитать поток по ссылке. Включите «Сначала скачать» в настройках и повторите.",
                            "Couldn't read the stream from the link. Enable “Download first” in Settings and retry.")
            }
            return (message, stderr)
        }
        return ((error as? LocalizedError)?.errorDescription ?? L("Помилка витягу.", "Ошибка извлечения.", "Extraction error."), nil)
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let p = pow(10.0, Double(places))
        return (self * p).rounded() / p
    }
}
