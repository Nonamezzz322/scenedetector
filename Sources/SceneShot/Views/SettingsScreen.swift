import SwiftUI
import AppKit

/// Dedicated settings screen (opened by the gear icon). Holds every frame and
/// transcription setting plus the app-language switch. All controls bind to the
/// same @AppStorage keys the tabs read.
struct SettingsScreen: View {
    @ObservedObject private var loc = Loc.shared
    let onClose: () -> Void

    // Frames
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
    @AppStorage("dedupScenes") private var dedupScenes = true
    @AppStorage("settleDelay") private var settleDelay = 0.4
    @AppStorage("rejectLowDetail") private var rejectLowDetail = true
    @AppStorage("stitchFrames") private var stitchFrames = true
    @AppStorage("translateUk") private var translateUk = false
    // Transcription
    @AppStorage("tx_language") private var txLanguage = TranscriptLanguage.auto.rawValue
    @AppStorage("tx_txt") private var txTxt = true
    @AppStorage("tx_srt") private var txSrt = true
    @AppStorage("tx_outputFolderPath") private var txOutputFolderPath = ""

    @State private var showBlock = false
    @State private var blockPhrase = ""

    private var isJPG: Bool { formatRaw == ImageFormat.jpg.rawValue }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(loc.settingsTitle).font(.title2).bold()
                Spacer()
                Button(loc.done) { onClose() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    languageSection
                    Divider()
                    framesSection
                    Divider()
                    transcriptionSection
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(hotkey)
        .alert(loc.blockPopupTitle, isPresented: $showBlock) {
            Button(loc.blockPopupOK, role: .cancel) { loc.set(.uk) }
        } message: {
            Text(blockPhrase)
        }
    }

    // MARK: - App language

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(loc.settingsLanguageSection).font(.headline)
            Picker("", selection: Binding(
                get: { loc.lang },
                set: { selectLanguage($0) }
            )) {
                ForEach(AppLanguage.allCases) { Text($0.nativeName).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
        }
    }

    /// Hidden Cmd+Shift+R: a real, no-popup switch to Russian (dev/escape hatch).
    /// Only active while the Settings screen is on screen.
    private var hotkey: some View {
        Button("") { loc.set(.ru) }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    private func selectLanguage(_ l: AppLanguage) {
        if l == .ru {
            // Default stays Ukrainian: show the popup, never actually switch to Russian.
            blockPhrase = loc.randomBlockPhrase()
            showBlock = true
            loc.set(.uk)
        } else {
            loc.set(l)
        }
    }

    // MARK: - Frames

    private var framesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(loc.settingsFramesSection).font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(loc.sensitivity).bold()
                    Spacer()
                    Text(String(format: "%.2f", threshold)).monospacedDigit().foregroundStyle(.secondary)
                }
                Picker("", selection: Binding(get: { Self.nearestPreset(threshold) }, set: { threshold = $0 })) {
                    Text(loc.lang == .en ? "Low" : (loc.lang == .uk ? "Низька" : "Низкая")).tag(0.45)
                    Text(loc.lang == .en ? "Medium" : (loc.lang == .uk ? "Середня" : "Средняя")).tag(0.30)
                    Text(loc.lang == .en ? "High" : (loc.lang == .uk ? "Висока" : "Высокая")).tag(0.18)
                }
                .pickerStyle(.segmented).labelsHidden()
                Slider(value: $threshold, in: 0.05...0.9)
                Text(loc.sensitivityHint).font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Toggle(isOn: $dedupScenes) { Text(loc.dedupScenes) }
                Text(loc.dedupHint).font(.caption2).foregroundStyle(.secondary)
            }

            Toggle(isOn: $rejectLowDetail) { Text(loc.rejectLowDetailLabel) }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(loc.settleDelayLabel)
                    Spacer()
                    Stepper(value: $settleDelay, in: 0...2, step: 0.1) {
                        Text(settleDelay == 0 ? "0" : String(format: "%.1f", settleDelay)).monospacedDigit()
                    }.fixedSize()
                }
                Text(loc.settleDelayHint).font(.caption2).foregroundStyle(.secondary)
            }

            HStack {
                Text(loc.minIntervalLabel)
                Spacer()
                Stepper(value: $minInterval, in: 0...60, step: 0.5) {
                    Text(minInterval == 0 ? "0" : String(format: "%.1f", minInterval)).monospacedDigit()
                }.fixedSize()
            }

            HStack {
                Text(loc.imageFormat).bold()
                Spacer()
                Picker("", selection: $formatRaw) {
                    Text("JPG").tag(ImageFormat.jpg.rawValue)
                    Text("PNG").tag(ImageFormat.png.rawValue)
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if isJPG {
                HStack {
                    Text(loc.jpegQuality)
                    Slider(value: Binding(get: { Double(jpegQuality) }, set: { jpegQuality = Int($0.rounded()) }), in: 2...31)
                    Text("\(jpegQuality)").monospacedDigit().frame(width: 24)
                }
            }

            HStack {
                Text(loc.maxWidthLabel)
                Spacer()
                TextField("0", value: $maxWidth, format: .number).frame(width: 72).textFieldStyle(.roundedBorder)
            }
            HStack {
                Text(loc.maxFramesLabel)
                Spacer()
                TextField("0", value: $maxFrames, format: .number).frame(width: 72).textFieldStyle(.roundedBorder)
            }

            HStack {
                Text(loc.filenameTemplate)
                TextField("scene_{index}_{time}", text: $filenameTemplate).textFieldStyle(.roundedBorder)
            }

            folderRow(title: loc.outputFolder, path: $outputFolderPath)

            VStack(alignment: .leading, spacing: 2) {
                Toggle(isOn: $stitchFrames) { Text(loc.stitchFrames) }
                Text(loc.stitchHint).font(.caption2).foregroundStyle(.secondary)
            }

            Toggle(isOn: $downloadFirst) { Text(loc.downloadFirst) }
            VStack(alignment: .leading, spacing: 2) {
                Toggle(isOn: $deleteSourcesAfter) { Text(loc.deleteSourcesAfter) }
                Text(loc.deleteSourcesHint).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Transcription

    private var transcriptionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(loc.settingsTranscriptionSection).font(.headline)
            HStack {
                Text(loc.languageLabel).frame(width: 110, alignment: .leading)
                Picker("", selection: $txLanguage) {
                    Text(loc.langAuto).tag(TranscriptLanguage.auto.rawValue)
                    Text(loc.langUk).tag(TranscriptLanguage.uk.rawValue)
                    Text(loc.langRu).tag(TranscriptLanguage.ru.rawValue)
                    Text(loc.langEn).tag(TranscriptLanguage.en.rawValue)
                }.labelsHidden().pickerStyle(.segmented).frame(maxWidth: 360)
            }
            HStack(spacing: 20) {
                Toggle(loc.formatTxt, isOn: $txTxt)
                Toggle(loc.formatSrt, isOn: $txSrt)
            }
            VStack(alignment: .leading, spacing: 2) {
                Toggle(isOn: $translateUk) { Text(loc.translateUkLabel) }
                Text(loc.translateUkHint).font(.caption2).foregroundStyle(.secondary)
            }
            folderRow(title: loc.outputFolder, path: $txOutputFolderPath)
        }
    }

    // MARK: - Helpers

    private func folderRow(title: String, path: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).bold()
                Spacer()
                if !path.wrappedValue.isEmpty { Button(loc.reset) { path.wrappedValue = "" } }
                Button(loc.chooseShort) { chooseFolder(path) }
            }
            Text(path.wrappedValue.isEmpty ? loc.defaultFolderHint : path.wrappedValue)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }

    private func chooseFolder(_ path: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { path.wrappedValue = url.path }
    }

    static func nearestPreset(_ t: Double) -> Double {
        [0.45, 0.30, 0.18].min(by: { abs($0 - t) < abs($1 - t) }) ?? 0.30
    }
}
