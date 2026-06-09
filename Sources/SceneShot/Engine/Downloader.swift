import Foundation

struct RemoteInfo {
    var contentLength: Int64?
    var contentType: String?

    var sizeText: String? {
        guard let bytes = contentLength, bytes > 0 else { return nil }
        let mb = Double(bytes) / 1_048_576
        return mb >= 1 ? String(format: "%.1f \(L("МБ", "МБ", "MB"))", mb)
                       : String(format: "%.0f \(L("КБ", "КБ", "KB"))", Double(bytes) / 1024)
    }
}

/// Validates and (optionally) downloads remote videos.
/// Validation uses HEAD; download uses a delegate task so we get progress.
/// Shared mutable state is guarded by `lock`; the continuation is resumed exactly once.
final class Downloader: NSObject, URLSessionDownloadDelegate {

    // MARK: - HEAD validation

    /// Rejects obvious non-files (HTML pages). Returns size/type when available.
    /// HEAD failures are tolerated (some servers disallow it) — ffprobe will try next.
    static func validate(_ url: URL) async throws -> RemoteInfo {
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 20
        let session = URLSession(configuration: .default)
        do {
            let (_, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { return RemoteInfo() }
            let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased()
            let len = http.expectedContentLength >= 0 ? http.expectedContentLength : nil
            if let type, type.hasPrefix("text/html") {
                throw ValidationError(message: L("Це схоже на сторінку сайту, а не на пряме посилання на відеофайл. YouTube і подібні не підтримуються тут — потрібен прямий URL на файл.",
                                                 "Это похоже на страницу сайта, а не на прямую ссылку на видеофайл. YouTube и подобные не поддерживаются — нужен прямой URL на файл.",
                                                 "This looks like a web page, not a direct video-file link. YouTube and the like aren't supported here — a direct file URL is required."))
            }
            return RemoteInfo(contentLength: len, contentType: type)
        } catch let e as ValidationError {
            throw e
        } catch {
            // HEAD unsupported / network hiccup — don't hard-fail here.
            return RemoteInfo()
        }
    }

    // MARK: - Download with progress

    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var task: URLSessionDownloadTask?
    private var didResume = false
    private var onProgress: ((Double) -> Void)?
    private var destExt = "mp4"

    func download(_ url: URL, onProgress: @escaping (Double) -> Void) async throws -> URL {
        // Set before the task/delegate exists — no concurrent access yet, so no lock needed here.
        self.onProgress = onProgress
        self.didResume = false
        if !url.pathExtension.isEmpty { destExt = url.pathExtension }

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            self.continuation = cont
            let t = session.downloadTask(with: url)
            self.task = t
            lock.unlock()
            t.resume()
        }
    }

    func cancel() {
        lock.lock(); let t = task; lock.unlock()
        t?.cancel()
    }

    /// Resume the continuation exactly once.
    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        if didResume { lock.unlock(); return }
        didResume = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        switch result {
        case .success(let u): cont?.resume(returning: u)
        case .failure(let e): cont?.resume(throwing: e)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            lock.lock(); let cb = onProgress; lock.unlock()
            cb?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // `location` is removed when this method returns — move it somewhere stable.
        lock.lock(); let ext = destExt; lock.unlock()
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("sceneshot-\(UUID().uuidString).\(ext)")
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            finish(.success(dest))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(Self.friendly(error)))
        }
        session.finishTasksAndInvalidate()
    }

    static func friendly(_ error: Error) -> Error {
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled { return CancellationError() }
        if let urlErr = error as? URLError {
            switch urlErr.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return ValidationError(message: L("Немає підключення до інтернету.", "Нет подключения к интернету.", "No internet connection."))
            case .timedOut:
                return ValidationError(message: L("Сервер не відповідає (таймаут).", "Сервер не отвечает (таймаут).", "The server isn't responding (timeout)."))
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return ValidationError(message: L("Не вдалося підключитися до сервера.", "Не удалось подключиться к серверу.", "Could not connect to the server."))
            default:
                return ValidationError(message: L("Помилка завантаження: \(urlErr.localizedDescription)", "Ошибка загрузки: \(urlErr.localizedDescription)", "Download error: \(urlErr.localizedDescription)"))
            }
        }
        return error
    }
}
