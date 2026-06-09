import Foundation

/// Nonisolated translation lookup for non-View / error contexts (reads the persisted
/// language directly from UserDefaults, so it's safe to call off the main actor, e.g. in
/// a LocalizedError.errorDescription). Order: (uk, ru, en).
func L(_ uk: String, _ ru: String, _ en: String) -> String {
    switch UserDefaults.standard.string(forKey: "appLanguage") {
    case "ru": return ru
    case "en": return en
    default:   return uk
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case uk, ru, en
    var id: String { rawValue }
    var nativeName: String {
        switch self {
        case .uk: return "Українська"
        case .ru: return "Русский"
        case .en: return "English"
        }
    }
}

/// App-wide localization store. Default language is Ukrainian. Views observe this
/// object, so changing `lang` re-renders the whole UI. Persisted in UserDefaults.
@MainActor
final class Loc: ObservableObject {
    static let shared = Loc()

    @Published private(set) var lang: AppLanguage

    private init() {
        if let s = UserDefaults.standard.string(forKey: "appLanguage"), let l = AppLanguage(rawValue: s) {
            lang = l
        } else {
            lang = .uk
        }
    }

    func set(_ l: AppLanguage) {
        lang = l
        UserDefaults.standard.set(l.rawValue, forKey: "appLanguage")
    }

    /// Pick a translation by current language. Order: (uk, ru, en).
    private func tr(_ uk: String, _ ru: String, _ en: String) -> String {
        switch lang {
        case .uk: return uk
        case .ru: return ru
        case .en: return en
        }
    }

    // MARK: Tabs / shell
    var tabVideo: String { tr("Відео", "Видео", "Video") }
    var videoSubtitle: String { tr("Кадри на зміні сцени та транскрипція мовлення",
                                   "Кадры на смене сцены и транскрипция речи",
                                   "Scene-change frames and speech transcription") }
    var process: String { tr("Обробити", "Обработать", "Process") }
    var pickAtLeastOne: String { tr("Оберіть хоча б одну дію", "Выберите хотя бы одно действие", "Pick at least one action") }
    var selectFramesTitle: String { tr("Оберіть кадри для збереження", "Выберите кадры для сохранения", "Pick frames to save") }
    var selectFramesHint: String { tr("Клікайте кадри в потрібному порядку — цифра = порядок.",
                                      "Кликайте кадры в нужном порядке — цифра = порядок.",
                                      "Click frames in the order you want — the number is the order.") }
    var stitchFrames: String { tr("Склеїти обрані в одну картинку", "Склеить выбранные в одну картинку", "Stitch selected into one image") }
    func saveSelectedFrames(_ n: Int) -> String {
        tr("Зберегти обрані (\(n))", "Сохранить выбранные (\(n))", "Save selected (\(n))")
    }
    func savedFrames(_ n: Int) -> String {
        tr("Збережено кадрів: \(n)", "Сохранено кадров: \(n)", "Saved frames: \(n)")
    }
    var stitchedSaved: String { tr("+ склеєна картинка", "+ склеенная картинка", "+ stitched image") }
    var translatingUk: String { tr("Перекладаю українською…", "Перевожу на украинский…", "Translating to Ukrainian…") }
    var ukSectionHeader: String { tr("— Переклад українською —", "— Перевод на украинский —", "— Ukrainian translation —") }
    var tabFrames: String { tr("Кадри", "Кадры", "Frames") }
    var tabTranscription: String { tr("Транскрипція", "Транскрипция", "Transcription") }
    var tabFolder: String { tr("Папка", "Папка", "Folder") }
    var tabCompetitors: String { tr("Конкуренти", "Конкуренты", "Competitors") }
    var settingsTitle: String { tr("Налаштування", "Настройки", "Settings") }
    var settingsTooltip: String { tr("Налаштування", "Настройки", "Settings") }

    // MARK: Common
    var cancel: String { tr("Скасувати", "Отменить", "Cancel") }
    var done: String { tr("Готово", "Готово", "Done") }
    var load: String { tr("Завантажити", "Загрузить", "Load") }
    var openFolder: String { tr("Відкрити папку", "Открыть папку", "Open folder") }
    var showInFinder: String { tr("Показати у Finder", "Показать в Finder", "Show in Finder") }
    var chooseShort: String { tr("Обрати…", "Выбрать…", "Choose…") }
    var reset: String { tr("Скинути", "Сброс", "Reset") }
    var selectAll: String { tr("Обрати все", "Выбрать все", "Select all") }
    var clearAll: String { tr("Зняти все", "Снять все", "Clear all") }
    var languageLabel: String { tr("Мова", "Язык", "Language") }
    var noAudioShort: String { tr("немає звуку", "нет звука", "no audio") }
    var hasAudioShort: String { tr("є звук", "есть звук", "has audio") }

    // MARK: Frames tab
    var framesSubtitle: String { tr("Витяг кадрів на зміні сцени", "Извлечение кадров на смене сцены", "Frame extraction on scene change") }
    var dropVideo: String { tr("Перетягніть сюди відеофайл", "Перетащите сюда видеофайл", "Drag a video file here") }
    var chooseVideo: String { tr("Обрати відео…", "Выбрать видео…", "Choose video…") }
    var urlPlaceholder: String { tr("посилання: відео, YouTube, TikTok, Instagram, Dropbox, Google Drive",
                                    "ссылка: видео, YouTube, TikTok, Instagram, Dropbox, Google Drive",
                                    "link: video, YouTube, TikTok, Instagram, Dropbox, Google Drive") }
    var extractFrames: String { tr("Витягти кадри", "Извлечь кадры", "Extract frames") }
    var analyzing: String { tr("Аналіз відео…", "Анализ видео…", "Analyzing video…") }
    var downloadingVideo: String { tr("Завантаження відео…", "Загрузка видео…", "Downloading video…") }
    var remaining: String { tr("залишилось ~", "осталось ~", "~ left") }

    // MARK: Transcription tab
    var transcriptionSubtitle: String { tr("Розпізнавання мовлення в текст (TXT) і субтитри (SRT)",
                                           "Распознавание речи в текст (TXT) и субтитры (SRT)",
                                           "Speech-to-text (TXT) and subtitles (SRT)") }
    var dropMedia: String { tr("Перетягніть сюди відео або аудіо", "Перетащите сюда видео или аудио", "Drag video or audio here") }
    var chooseFile: String { tr("Обрати файл…", "Выбрать файл…", "Choose file…") }
    var transcribe: String { tr("Транскрибувати", "Транскрибировать", "Transcribe") }
    var recognizing: String { tr("Розпізнавання мовлення…", "Распознавание речи…", "Recognizing speech…") }
    var modelReady: String { tr("Модель: base (вбудована)", "Модель: base (встроена)", "Model: base (bundled)") }
    var modelMissing: String { tr("Модуль розпізнавання не встановлено — зберіть whisper (Scripts/fetch-whisper.sh)",
                                  "Модуль распознавания не установлен — соберите whisper (Scripts/fetch-whisper.sh)",
                                  "Recognition module not installed — build whisper (Scripts/fetch-whisper.sh)") }
    var langAuto: String { tr("Авто", "Авто", "Auto") }
    var langUk: String { tr("Українська", "Украинский", "Ukrainian") }
    var langRu: String { tr("Російська", "Русский", "Russian") }
    var langEn: String { tr("Англійська", "English", "English") }
    var translateUkLabel: String { tr("Дописувати переклад українською",
                                      "Дописывать перевод на украинский",
                                      "Append Ukrainian translation") }
    var translateUkHint: String { tr("У той самий TXT, якщо мова не українська. Потрібен macOS 15+; перший раз — завантаження мовного пакета.",
                                     "В тот же TXT, если язык не украинский. Нужен macOS 15+; первый раз — загрузка языкового пакета.",
                                     "Into the same TXT when the language isn't Ukrainian. Needs macOS 15+; first run downloads the language.") }
    var stitchHint: String { tr("Зберігає обрані кадри ще й однією картинкою (зліва направо в порядку кліків).",
                                "Сохраняет выбранные кадры ещё и одной картинкой (слева направо в порядке кликов).",
                                "Also saves the selected frames as one image (left-to-right in click order).") }
    var formatTxt: String { tr("Текст (TXT)", "Текст (TXT)", "Text (TXT)") }
    var formatSrt: String { tr("Субтитри (SRT)", "Субтитры (SRT)", "Subtitles (SRT)") }
    var copyText: String { tr("Копіювати текст", "Копировать текст", "Copy text") }
    var copied: String { tr("Скопійовано", "Скопировано", "Copied") }
    var noSpeechTitle: String { tr("Мовлення не розпізнано", "Речь не распознана", "No speech recognized") }
    var noSpeechMsg: String { tr("В аудіодоріжці не знайшлося розпізнаваного мовлення.",
                                 "В аудиодорожке не нашлось распознаваемой речи.",
                                 "No recognizable speech was found in the audio.") }

    // MARK: Folder tab
    var folderSubtitle: String { tr("Прев’ю відео з папки та пакетна обробка",
                                    "Превью видео из папки и пакетная обработка",
                                    "Folder previews and batch processing") }
    var chooseLocalFolder: String { tr("Обрати локальну папку…", "Выбрать локальную папку…", "Choose local folder…") }
    var folderLinkPlaceholder: String { tr("посилання на папку Dropbox або Google Drive",
                                           "ссылка на папку Dropbox или Google Drive",
                                           "Dropbox or Google Drive folder link") }
    var openAction: String { tr("Відкрити", "Открыть", "Open") }
    var loadingList: String { tr("Завантаження списку…", "Загрузка списка…", "Loading list…") }
    var doFrames: String { tr("Витягти кадри", "Извлечь кадры", "Extract frames") }
    var doTranscribe: String { tr("Транскрибувати", "Транскрибировать", "Transcribe") }
    var transcribeSoon: String { tr("Транскрипція з’явиться після збірки модуля whisper (Scripts/fetch-whisper.sh).",
                                    "Транскрипция появится после сборки модуля whisper (Scripts/fetch-whisper.sh).",
                                    "Transcription will appear after building the whisper module (Scripts/fetch-whisper.sh).") }
    var cloudNotConfigured: String { tr("Хмара не налаштована у збірці", "Облако не настроено в сборке", "Cloud not configured in this build") }
    func selectedOf(_ n: Int, _ m: Int) -> String {
        tr("Обрано \(n) з \(m)", "Выбрано \(n) из \(m)", "Selected \(n) of \(m)")
    }
    func processSelected(_ n: Int) -> String {
        tr("Обробити обрані (\(n))", "Обработать выбранные (\(n))", "Process selected (\(n))")
    }
    func processingOf(_ i: Int, _ n: Int) -> String {
        tr("Обробка \(i) з \(n)…", "Обработка \(i) из \(n)…", "Processing \(i) of \(n)…")
    }
    func connectProvider(_ name: String) -> String {
        tr("Підключити \(name)", "Подключить \(name)", "Connect \(name)")
    }
    func disconnectProvider(_ name: String) -> String {
        tr("\(name): відключити", "\(name): отключить", "\(name): disconnect")
    }
    var statusWaiting: String { tr("очікування", "ожидание", "waiting") }
    var statusDone: String { tr("готово", "готово", "done") }
    var statusCancelled: String { tr("скасовано", "отменено", "cancelled") }
    func statusDownloading(_ p: Int) -> String { tr("завантаження \(p)%", "загрузка \(p)%", "downloading \(p)%") }
    func statusProcessing(_ p: Int) -> String { tr("обробка \(p)%", "обработка \(p)%", "processing \(p)%") }
    func summary(_ done: Int, _ failed: Int) -> String {
        if failed == 0 { return tr("Готово: \(done)", "Готово: \(done)", "Done: \(done)") }
        return tr("Готово: \(done), помилок: \(failed)", "Готово: \(done), ошибок: \(failed)", "Done: \(done), errors: \(failed)")
    }
    var openOutputFolder: String { tr("Відкрити папку виводу", "Открыть папку вывода", "Open output folder") }

    // MARK: Competitors tab
    var competitorsSubtitle: String { tr("Збір роликів конкурента та метрики монтажу",
                                         "Сбор роликов конкурента и метрики монтажа",
                                         "Competitor video collection and editing metrics") }
    var competitorInputPlaceholder: String { tr("канал / профіль / хештег / плейлист або пошуковий запит",
                                                "канал / профиль / хэштег / плейлист или поисковый запрос",
                                                "channel / profile / hashtag / playlist or search query") }
    var find: String { tr("Знайти", "Найти", "Find") }
    var limitLabel: String { tr("Ліміт", "Лимит", "Limit") }
    var ytdlpMissing: String { tr("Модуль yt-dlp не зібрано (Scripts/fetch-ytdlp.sh).",
                                  "Модуль yt-dlp не собран (Scripts/fetch-ytdlp.sh).",
                                  "yt-dlp module not built (Scripts/fetch-ytdlp.sh).") }
    var metricsToggle: String { tr("Метрики монтажу", "Метрики монтажа", "Editing metrics") }
    var metricsAlwaysOn: String { tr("(рахуються завжди)", "(считаются всегда)", "(always computed)") }
    func analyzeSelected(_ n: Int) -> String {
        tr("Проаналізувати обрані (\(n))", "Проанализировать выбранные (\(n))", "Analyze selected (\(n))")
    }
    var exportCSV: String { tr("Експорт CSV", "Экспорт CSV", "Export CSV") }
    var csvSaved: String { tr("CSV збережено", "CSV сохранён", "CSV saved") }
    var setAverage: String { tr("Середнє по добірці", "Среднее по подборке", "Set average") }
    // Metric column headers (short)
    var colVideo: String { tr("Відео", "Видео", "Video") }
    var colDuration: String { tr("Трив.", "Длит.", "Dur.") }
    var colCuts: String { tr("Склейок", "Склеек", "Cuts") }
    var colCutsMin: String { tr("Скл/хв", "Скл/мин", "Cuts/min") }
    var colASL: String { tr("Сцена", "Сцена", "ASL") }
    var colHook: String { tr("Хук", "Хук", "Hook") }
    var colWords: String { tr("Слів", "Слов", "Words") }
    var metricsHint: String { tr("Склейки — апроксимація ритму (жорсткі переходи за порогом сцени).",
                                 "Склейки — аппроксимация ритма (жёсткие переходы по порогу сцены).",
                                 "Cuts are a rhythm approximation (hard transitions by the scene threshold).") }

    // MARK: Settings screen
    var settingsFramesSection: String { tr("Кадри", "Кадры", "Frames") }
    var settingsTranscriptionSection: String { tr("Транскрипція", "Транскрипция", "Transcription") }
    var settingsLanguageSection: String { tr("Мова застосунку", "Язык приложения", "App language") }
    var sensitivity: String { tr("Чутливість", "Чувствительность", "Sensitivity") }
    var sensitivityHint: String { tr("Нижче поріг — більше кадрів", "Ниже порог — больше кадров", "Lower threshold = more frames") }
    var imageFormat: String { tr("Формат зображення", "Формат изображения", "Image format") }
    var jpegQuality: String { tr("Якість JPEG", "Качество JPEG", "JPEG quality") }
    var maxWidthLabel: String { tr("Макс. ширина (0 = як є)", "Макс. ширина (0 = как есть)", "Max width (0 = original)") }
    var maxFramesLabel: String { tr("Макс. кадрів (0 = без ліміту)", "Макс. кадров (0 = без лимита)", "Max frames (0 = unlimited)") }
    var minIntervalLabel: String { tr("Мін. інтервал, с (0 = вимк)", "Мин. интервал, с (0 = выкл)", "Min interval, s (0 = off)") }
    var filenameTemplate: String { tr("Шаблон імені файлу", "Шаблон имени файла", "Filename template") }
    var outputFolder: String { tr("Папка виводу", "Папка вывода", "Output folder") }
    var downloadFirst: String { tr("Спочатку завантажити (для посилань)", "Сначала скачать (для ссылок)", "Download first (for links)") }
    var deleteSourcesAfter: String { tr("Видаляти завантажені джерела одразу після обробки",
                                        "Удалять скачанные исходники сразу после обработки",
                                        "Delete downloaded sources right after processing") }
    var deleteSourcesHint: String { tr("«Папка» і «Конкуренти» й так видаляють одразу. Для одиночних вкладок «Повторити» доведеться завантажити заново.",
                                       "«Папка» и «Конкуренты» и так удаляют сразу. Для одиночных вкладок «Повторить» придётся скачать заново.",
                                       "Folder and Competitors already delete immediately. In single tabs, Retry will re-download.") }
    var defaultFolderHint: String { tr("За умовч.: ~/Movies/SceneShot/…", "По умолч.: ~/Movies/SceneShot/…", "Default: ~/Movies/SceneShot/…") }
    var dedupScenes: String { tr("Тільки окремі сцени (прибирати схожі кадри)",
                                 "Только отдельные сцены (убирать похожие кадры)",
                                 "Distinct scenes only (drop similar frames)") }
    var dedupHint: String { tr("Кожен кадр порівнюється з уже збереженими; схожіші за чутливість — відкидаються.",
                               "Каждый кадр сравнивается с уже сохранёнными; похожие сильнее чувствительности — отбрасываются.",
                               "Each frame is compared with kept ones; those more similar than the sensitivity are dropped.") }
    var settleDelayLabel: String { tr("Знімати через паузу після переходу, с",
                                      "Снимать через паузу после перехода, с",
                                      "Capture after a pause past the transition, s") }
    var settleDelayHint: String { tr("0 = у момент склейки. Більше — пропускає ефект і бере сцену, що вже осіла.",
                                     "0 = в момент склейки. Больше — пропускает эффект и берёт осевшую сцену.",
                                     "0 = at the cut. Higher skips the effect and takes the settled scene.") }
    var rejectLowDetailLabel: String { tr("Прибирати порожні кадри (чорні / розмиті переходи)",
                                          "Убирать пустые кадры (чёрные / размытые переходы)",
                                          "Drop empty frames (black / blurry transitions)") }

    // MARK: Result cards
    var cancelledDot: String { tr("Скасовано.", "Отменено.", "Cancelled.") }
    var noScenesTitle: String { tr("Зміни сцен не знайдено", "Смены сцен не найдены", "No scene changes found") }
    var retryHint: String { tr("Спробуйте підвищити чутливість (знизити поріг).",
                               "Попробуйте повысить чувствительность (понизить порог).",
                               "Try increasing sensitivity (lower the threshold).") }
    var retryMoreSensitive: String { tr("Повторити з більшою чутливістю",
                                        "Повторить с большей чувствительностью",
                                        "Retry with higher sensitivity") }
    var technicalLog: String { tr("Технічний лог", "Технический лог", "Technical log") }
    var technicalDetails: String { tr("Технічні подробиці", "Технические подробности", "Technical details") }
    func framesDone(_ n: Int) -> String {
        let word: String
        switch lang {
        case .en: word = n == 1 ? "frame" : "frames"
        case .uk:
            let m10 = n % 10, m100 = n % 100
            if m10 == 1 && m100 != 11 { word = "кадр" }
            else if (2...4).contains(m10) && !(12...14).contains(m100) { word = "кадри" }
            else { word = "кадрів" }
        case .ru:
            let m10 = n % 10, m100 = n % 100
            if m10 == 1 && m100 != 11 { word = "кадр" }
            else if (2...4).contains(m10) && !(12...14).contains(m100) { word = "кадра" }
            else { word = "кадров" }
        }
        return tr("Готово: \(n) \(word)", "Готово: \(n) \(word)", "Done: \(n) \(word)")
    }
    var transcribeDoneTitle: String { tr("Готово", "Готово", "Done") }
    var cancelledTitle: String { tr("Скасовано", "Отменено", "Cancelled") }
    var transcribeStopped: String { tr("Транскрипцію зупинено.", "Транскрипция остановлена.", "Transcription stopped.") }

    // MARK: Russian-language block popup
    var blockPopupTitle: String { tr("Стоп", "Стоп", "Stop") }
    var blockPopupOK: String { "OK" }

    /// Phrases shown when someone picks Russian (then the app reverts to Ukrainian).
    /// First line is the user's own; the rest are anti-war / anti-invasion political slogans
    /// (aimed at the invasion / occupying military / the state — not at people as an ethnicity).
    /// Edit freely.
    static let blockPhrases: [String] = [
        "Поставь унитаз на место, и спердоляй до Москвы, свинья",
        "Руки геть від України!",
        "Російський воєнний корабль, іди на хуй!",
        "Окупанти, додому!",
        "Повертайся до Москви — тобі тут не раді.",
        "Слава Україні! Героям слава!",
        "Україна — не Росія, і ніколи нею не буде.",
    ]
    func randomBlockPhrase() -> String {
        Self.blockPhrases.randomElement() ?? Self.blockPhrases.first ?? ""
    }
}
