import SwiftUI
import Translation

/// Translates text to Ukrainian using Apple's on-device Translation framework
/// (offline, free, no API key). Available on macOS 15+; the first use of a language
/// pair may prompt the system to download the language. Rendered as a 0-size view —
/// it exists only to host `.translationTask`. Calls `onResult(nil)` on any failure.
@available(macOS 15.0, *)
struct UkrainianTranslator: View {
    let text: String
    let sourceLang: String?
    let onResult: (String?) -> Void

    @State private var config: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(config) { session in
                let lines = text
                    .split(whereSeparator: \.isNewline)
                    .map(String.init)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                guard !lines.isEmpty else { onResult(nil); return }
                do {
                    let requests = lines.map { TranslationSession.Request(sourceText: $0) }
                    let responses = try await session.translations(from: requests)
                    let uk = responses.map(\.targetText).joined(separator: "\n")
                    onResult(uk.isEmpty ? nil : uk)
                } catch {
                    onResult(nil)
                }
            }
            .task {
                config = TranslationSession.Configuration(
                    source: sourceLang.map { Locale.Language(identifier: $0) },
                    target: Locale.Language(identifier: "uk"))
            }
    }
}
