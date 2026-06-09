import SwiftUI
import AppKit

/// View-facing result of a transcription run (mirrors ResultsView.RunResult).
enum TranscriptRunResult {
    case done(dir: URL, txt: URL?, srt: URL?, text: String, srtWarning: String?)
    case empty(dir: URL)
    case error(message: String, technical: String?)
    case cancelled
}

struct TranscriptResultsView: View {
    let result: TranscriptRunResult
    @ObservedObject private var loc = Loc.shared

    @State private var copied = false
    @State private var showTechnical = false

    var body: some View {
        switch result {
        case .done(let dir, let txt, let srt, let text, let warning):
            doneCard(dir: dir, txt: txt, srt: srt, text: text, warning: warning)
        case .empty:
            infoCard(icon: "text.bubble", title: loc.noSpeechTitle, message: loc.noSpeechMsg)
        case .error(let message, let technical):
            errorCard(message: message, technical: technical)
        case .cancelled:
            infoCard(icon: "xmark.circle", title: loc.cancelledTitle, message: loc.transcribeStopped)
        }
    }

    // MARK: - Done

    private func doneCard(dir: URL, txt: URL?, srt: URL?, text: String, warning: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(loc.transcribeDoneTitle).font(.headline)
                Spacer()
                HStack(spacing: 6) {
                    if txt != nil { tag("TXT") }
                    if srt != nil { tag("SRT") }
                }
            }

            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }

            ScrollView {
                Text(text.isEmpty ? "—" : text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 220)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))

            HStack(spacing: 10) {
                Button {
                    NSWorkspace.shared.open(dir)
                } label: { Label(loc.openFolder, systemImage: "folder") }

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([txt ?? srt ?? dir])
                } label: { Label(loc.showInFinder, systemImage: "magnifyingglass") }

                Button {
                    copyText(text)
                } label: { Label(copied ? loc.copied : loc.copyText,
                                 systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .disabled(text.isEmpty)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
    }

    // MARK: - Error / info

    private func errorCard(message: String, technical: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
            if let technical, !technical.isEmpty {
                DisclosureGroup(loc.technicalDetails, isExpanded: $showTechnical) {
                    ScrollView {
                        Text(technical)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                }
                .font(.caption)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.06)))
    }

    private func infoCard(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
    }

    private func tag(_ s: String) -> some View {
        Text(s).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
    }

    private func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}

/// Lightweight, non-fatal SRT sanity check: returns a warning string or nil.
enum SRTSanity {
    static func check(_ url: URL?) -> String? {
        guard let url, let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var count = 0
        var lastEnd = -1.0
        var brokeMonotonic = false
        for line in content.split(separator: "\n") where line.contains("-->") {
            let sides = line.components(separatedBy: "-->")
            guard sides.count == 2,
                  let start = WhisperEngine.parseSrtTime(sides[0].trimmingCharacters(in: .whitespaces)),
                  let end = WhisperEngine.parseSrtTime(sides[1].trimmingCharacters(in: .whitespaces)) else {
                return L("Субтитри SRT виглядають пошкодженими (не розпізнано таймкод).", "Субтитры SRT выглядят повреждёнными (не распознан таймкод).", "The SRT subtitles look corrupted (timecode not recognized).")
            }
            count += 1
            if start < lastEnd - 0.5 { brokeMonotonic = true }
            lastEnd = end
        }
        if count == 0 { return L("У SRT не знайдено жодного таймкоду.", "В SRT не найдено ни одного таймкода.", "No timecodes found in the SRT.") }
        if brokeMonotonic { return L("Таймкоди SRT ідуть не по порядку — перевірте файл.", "Таймкоды SRT идут не по порядку — проверьте файл.", "SRT timecodes are out of order — check the file.") }
        return nil
    }
}
