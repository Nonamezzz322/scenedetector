import Foundation

enum FFmpegTool: String {
    case ffmpeg
    case ffprobe
    case whisper = "whisper-cli"
    case ytdlp = "yt-dlp"
}

enum FFmpegError: LocalizedError {
    case toolMissing(String)
    case failed(code: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .toolMissing(let name):
            return L("Не знайдено вбудований \(name). Спробуйте перевстановити застосунок.",
                     "Не найден встроенный \(name). Попробуйте переустановить приложение.",
                     "Bundled \(name) not found. Try reinstalling the app.")
        case .failed:
            // Human-facing message only; the raw stderr lives in the technical log.
            return L("Не вдалося обробити відео.", "Не удалось обработать видео.", "Could not process the video.")
        }
    }
}

struct ProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

/// Locates bundled ffmpeg/ffprobe for the current architecture and runs them,
/// draining stdout AND stderr concurrently. Completion fires only after BOTH
/// pipes reach EOF and the process has terminated (via a DispatchGroup), so the
/// full output and any streamed lines are guaranteed delivered before completion.
final class FFmpeg {
    static let shared = FFmpeg()

    private var arch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    /// URL of a bundled helper binary, or nil if missing/non-executable.
    /// Looks in the arch-specific dir first, then a shared `Helpers/` location for
    /// universal binaries that needn't be duplicated per arch (e.g. yt-dlp).
    func toolURL(_ tool: FFmpegTool) -> URL? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let helpers = res.appendingPathComponent("Helpers", isDirectory: true)
        let candidates = [
            helpers.appendingPathComponent(arch, isDirectory: true).appendingPathComponent(tool.rawValue),
            helpers.appendingPathComponent(tool.rawValue)
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// A running process handle that supports cancellation.
    final class Running {
        let process: Process
        init(_ p: Process) { process = p }
        func cancel() { if process.isRunning { process.terminate() } }
    }

    /// Launch a tool. `onStdoutLine`/`onStderrLine` fire on a background queue per complete line.
    /// Returns a Running handle immediately; `completion` fires once, on a background queue.
    @discardableResult
    func launch(
        _ tool: FFmpegTool,
        args: [String],
        onStdoutLine: ((String) -> Void)? = nil,
        onStderrLine: ((String) -> Void)? = nil,
        completion: @escaping (Result<ProcessResult, FFmpegError>) -> Void
    ) -> Running? {
        guard let exe = toolURL(tool) else {
            completion(.failure(.toolMissing(tool.rawValue)))
            return nil
        }

        let process = Process()
        process.executableURL = exe
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let lock = NSLock()
        var outData = Data()
        var errData = Data()
        var outLineBuf = Data()
        var errLineBuf = Data()
        let newline = UInt8(ascii: "\n")

        func drain(_ buf: inout Data, into lines: inout [String]) {
            while let i = buf.firstIndex(of: newline) {
                let line = buf.subdata(in: buf.startIndex..<i)
                buf.removeSubrange(buf.startIndex...i)
                if let s = String(data: line, encoding: .utf8) { lines.append(s) }
            }
        }

        func onChunk(_ d: Data, isErr: Bool) {
            var lines: [String] = []
            lock.lock()
            if isErr {
                errData.append(d); errLineBuf.append(d); drain(&errLineBuf, into: &lines)
            } else {
                outData.append(d); outLineBuf.append(d); drain(&outLineBuf, into: &lines)
            }
            lock.unlock()
            if let cb = isErr ? onStderrLine : onStdoutLine { for l in lines { cb(l) } }
        }

        func flushFinal(isErr: Bool) {
            var lines: [String] = []
            lock.lock()
            if isErr {
                drain(&errLineBuf, into: &lines)
                if !errLineBuf.isEmpty, let s = String(data: errLineBuf, encoding: .utf8) { lines.append(s) }
                errLineBuf.removeAll()
            } else {
                drain(&outLineBuf, into: &lines)
                if !outLineBuf.isEmpty, let s = String(data: outLineBuf, encoding: .utf8) { lines.append(s) }
                outLineBuf.removeAll()
            }
            lock.unlock()
            if let cb = isErr ? onStderrLine : onStdoutLine { for l in lines { cb(l) } }
        }

        let group = DispatchGroup()
        group.enter() // stdout EOF
        group.enter() // stderr EOF
        group.enter() // process termination

        outPipe.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            if d.isEmpty {
                fh.readabilityHandler = nil
                flushFinal(isErr: false)
                group.leave()
            } else {
                onChunk(d, isErr: false)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            if d.isEmpty {
                fh.readabilityHandler = nil
                flushFinal(isErr: true)
                group.leave()
            } else {
                onChunk(d, isErr: true)
            }
        }

        process.terminationHandler = { _ in group.leave() }

        group.notify(queue: .global()) {
            lock.lock()
            let out = String(data: outData, encoding: .utf8) ?? ""
            let err = String(data: errData, encoding: .utf8) ?? ""
            lock.unlock()
            completion(.success(ProcessResult(exitCode: process.terminationStatus, stdout: out, stderr: err)))
        }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            completion(.failure(.toolMissing(tool.rawValue)))
            return nil
        }
        return Running(process)
    }

    /// Convenience: run to completion and return the result (async).
    func run(_ tool: FFmpegTool, args: [String]) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { cont in
            _ = launch(tool, args: args) { result in
                switch result {
                case .success(let r): cont.resume(returning: r)
                case .failure(let e): cont.resume(throwing: e)
                }
            }
        }
    }
}
