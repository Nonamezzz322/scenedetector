import SwiftUI

/// Top-level shell: a segmented switch between «Кадри»/«Транскрипція»/«Папка», plus a
/// gear button (top-right) that opens the Settings screen. Tab subtrees stay alive so an
/// in-progress run survives tab switches.
struct RootView: View {
    @AppStorage("activeTab") private var activeTab = 0
    @State private var showSettings = false
    @ObservedObject private var loc = Loc.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $activeTab) {
                    Text(loc.tabVideo).tag(0)
                    Text(loc.tabFolder).tag(2)
                    // «Конкуренти» приховано (код збережено) — допрацюємо пізніше.
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
                .onAppear { if activeTab != 0 && activeTab != 2 { activeTab = 0 } }

                Spacer()

                Button {
                    showSettings.toggle()
                } label: {
                    Image(systemName: "gearshape").font(.system(size: 18))
                }
                .buttonStyle(.borderless)
                .help(loc.settingsTooltip)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 2)

            ZStack {
                VideoView()
                    .opacity(activeTab == 0 ? 1 : 0)
                    .allowsHitTesting(activeTab == 0)
                FolderBatchView()
                    .opacity(activeTab == 2 ? 1 : 0)
                    .allowsHitTesting(activeTab == 2)
                // ContentView/TranscriptionView/CompetitorsView коду збережено, але не показуються.

                if showSettings {
                    SettingsScreen(onClose: { showSettings = false })
                        .transition(.opacity)
                }
            }
            .buttonStyle(.pressableBordered)   // tactile feedback for every in-tab button
        }
        .frame(minWidth: 580, minHeight: 680)
    }
}
