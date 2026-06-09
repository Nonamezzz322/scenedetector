// Lightweight i18n store. Order of values: [ru, uk, en]. Default = ru.
// (The desktop app defaulted to Ukrainian with an anti-Russian easter egg; for a
// plain personal web tool the language switch is neutral and defaults to Russian.)

const LANGS = ["ru", "uk", "en"];
const STORE_KEY = "ss_lang";

const DICT = {
  // tabs / shell
  tabVideo:        ["Видео", "Відео", "Video"],
  tabFolder:       ["Папка", "Папка", "Folder"],
  settingsTitle:   ["Настройки", "Налаштування", "Settings"],
  videoSubtitle:   ["Кадры на смене сцены и транскрипция речи", "Кадри на зміні сцени та транскрипція мовлення", "Scene-change frames and speech transcription"],
  folderSubtitle:  ["Превью видео из папки и пакетная обработка", "Прев’ю відео з папки та пакетна обробка", "Folder previews and batch processing"],

  // common
  process:         ["Обработать", "Обробити", "Process"],
  cancel:          ["Отменить", "Скасувати", "Cancel"],
  done:            ["Готово", "Готово", "Done"],
  selectAll:       ["Выбрать все", "Обрати все", "Select all"],
  clearAll:        ["Снять все", "Зняти все", "Clear all"],
  languageLabel:   ["Язык", "Мова", "Language"],
  pickAtLeastOne:  ["Выберите хотя бы одно действие", "Оберіть хоча б одну дію", "Pick at least one action"],
  download:        ["Скачать", "Завантажити", "Download"],
  copyText:        ["Копировать текст", "Копіювати текст", "Copy text"],
  copied:          ["Скопировано", "Скопійовано", "Copied"],
  load:            ["Загрузить", "Завантажити", "Load"],
  urlPlaceholder:  ["ссылка: прямое видео, Dropbox или Google Drive", "посилання: пряме відео, Dropbox або Google Drive", "link: direct video, Dropbox or Google Drive"],
  loadingUrl:      ["Загрузка по ссылке…", "Завантаження за посиланням…", "Loading from link…"],
  urlError:        ["Не удалось загрузить по ссылке. Нужна ПРЯМАЯ ссылка на видеофайл (.mp4/.webm/.mov) с доступом (CORS), либо настройте прокси в Настройках. Скачайте файл и загрузите его как обычно.",
                    "Не вдалося завантажити за посиланням. Потрібне ПРЯМЕ посилання на відеофайл (.mp4/.webm/.mov) з доступом (CORS), або налаштуйте проксі в Налаштуваннях. Завантажте файл і відкрийте його як зазвичай.",
                    "Couldn't load from the link. Use a DIRECT video-file URL (.mp4/.webm/.mov) with CORS, or set up the proxy in Settings. Otherwise download the file and open it normally."],
  urlSocial:       ["YouTube/TikTok/Instagram нельзя открыть по ссылке: это не файлы, им нужен сервер с yt-dlp. Скачайте видео и загрузите файл.",
                    "YouTube/TikTok/Instagram не відкрити за посиланням: це не файли, їм потрібен сервер з yt-dlp. Завантажте відео і відкрийте файл.",
                    "YouTube/TikTok/Instagram can't be opened by link — they aren't files and need a yt-dlp server. Download the video and open the file."],
  urlNeedsProxy:   ["Для Dropbox/Google Drive (и ссылок без CORS) укажите адрес вашего прокси: Настройки → «Прокси для ссылок».",
                    "Для Dropbox/Google Drive (і посилань без CORS) вкажіть адресу вашого проксі: Налаштування → «Проксі для посилань».",
                    "For Dropbox/Google Drive (and non-CORS links), set your proxy URL: Settings → “Proxy for links”."],
  proxyTitle:      ["Прокси для ссылок (Dropbox / Google Drive)", "Проксі для посилань (Dropbox / Google Drive)", "Proxy for links (Dropbox / Google Drive)"],
  proxyPlaceholder:["https://…workers.dev", "https://…workers.dev", "https://…workers.dev"],
  proxyHint:       ["Чтобы открывать видео по ссылкам с Dropbox/Google Drive (и прямым ссылкам без CORS), задеплойте бесплатный Cloudflare Worker (см. папку cloudflare-proxy в репозитории) и вставьте его адрес сюда. YouTube/TikTok/Instagram так не работают.",
                    "Щоб відкривати відео за посиланнями з Dropbox/Google Drive (і прямими посиланнями без CORS), задеплойте безкоштовний Cloudflare Worker (див. папку cloudflare-proxy у репозиторії) і вставте його адресу сюди. YouTube/TikTok/Instagram так не працюють.",
                    "To open videos by Dropbox/Google Drive links (and non-CORS direct links), deploy the free Cloudflare Worker (see the cloudflare-proxy folder) and paste its URL here. YouTube/TikTok/Instagram won't work this way."],

  // video tab
  dropVideo:       ["Перетащите сюда видеофайл", "Перетягніть сюди відеофайл", "Drag a video file here"],
  chooseVideo:     ["Выбрать видео…", "Обрати відео…", "Choose video…"],
  doFrames:        ["Извлечь кадры", "Витягти кадри", "Extract frames"],
  doTranscribe:    ["Транскрибировать", "Транскрибувати", "Transcribe"],
  selectFramesTitle: ["Выберите кадры для сохранения", "Оберіть кадри для збереження", "Pick frames to save"],
  selectFramesHint:  ["Кликайте кадры в нужном порядке — цифра = порядок.", "Клікайте кадри в потрібному порядку — цифра = порядок.", "Click frames in the order you want — the number is the order."],
  hasAudioShort:   ["есть звук", "є звук", "has audio"],
  noAudioShort:    ["нет звука", "немає звуку", "no audio"],

  // languages (transcription)
  langAuto:        ["Авто", "Авто", "Auto"],
  langRu:          ["Русский", "Російська", "Russian"],
  langUk:          ["Украинский", "Українська", "Ukrainian"],
  langEn:          ["English", "Англійська", "English"],

  // folder tab
  chooseLocalFolder: ["Выбрать локальную папку…", "Обрати локальну папку…", "Choose local folder…"],
  folderHowto:     ["Выберите папку с видеофайлами — они останутся на вашем компьютере.", "Оберіть папку з відеофайлами — вони залишаться на вашому комп’ютері.", "Pick a folder of videos — they stay on your computer."],

  // progress / status
  analyzing:       ["Анализ видео…", "Аналіз відео…", "Analyzing video…"],
  recognizing:     ["Распознавание речи…", "Розпізнавання мовлення…", "Recognizing speech…"],
  loadingModel:    ["Загрузка модели распознавания…", "Завантаження моделі розпізнавання…", "Loading recognition model…"],
  remaining:       ["осталось ~", "залишилось ~", "~ left"],
  statusWaiting:   ["ожидание", "очікування", "waiting"],
  statusProcessing:["обработка", "обробка", "processing"],
  statusDone:      ["готово", "готово", "done"],
  statusFailed:    ["ошибка", "помилка", "error"],
  statusCancelled: ["отменено", "скасовано", "cancelled"],

  // settings
  settingsLanguageSection: ["Язык приложения", "Мова застосунку", "App language"],
  settingsFramesSection:   ["Кадры", "Кадри", "Frames"],
  settingsTranscriptionSection: ["Транскрипция", "Транскрипція", "Transcription"],
  sensitivity:     ["Чувствительность", "Чутливість", "Sensitivity"],
  sensitivityHint: ["Ниже порог — больше кадров", "Нижче поріг — більше кадрів", "Lower threshold = more frames"],
  sensLow:         ["Низкая", "Низька", "Low"],
  sensMed:         ["Средняя", "Середня", "Medium"],
  sensHigh:        ["Высокая", "Висока", "High"],
  dedupScenes:     ["Только отдельные сцены (убирать похожие кадры)", "Тільки окремі сцени (прибирати схожі кадри)", "Distinct scenes only (drop similar frames)"],
  dedupHint:       ["Каждый кадр сравнивается с уже сохранёнными; похожие сильнее чувствительности — отбрасываются.", "Кожен кадр порівнюється з уже збереженими; схожіші за чутливість — відкидаються.", "Each frame is compared with kept ones; those more similar than the sensitivity are dropped."],
  rejectLowDetailLabel: ["Убирать пустые кадры (чёрные / размытые переходы)", "Прибирати порожні кадри (чорні / розмиті переходи)", "Drop empty frames (black / blurry transitions)"],
  settleDelayLabel: ["Снимать через паузу после перехода, с", "Знімати через паузу після переходу, с", "Capture after a pause past the transition, s"],
  settleDelayHint:  ["0 = в момент склейки. Больше — пропускает эффект и берёт осевшую сцену.", "0 = у момент склейки. Більше — пропускає ефект і бере сцену, що вже осіла.", "0 = at the cut. Higher skips the effect and takes the settled scene."],
  minIntervalLabel: ["Мин. интервал, с (0 = выкл)", "Мін. інтервал, с (0 = вимк)", "Min interval, s (0 = off)"],
  imageFormat:      ["Формат изображения", "Формат зображення", "Image format"],
  jpegQuality:      ["Качество JPEG", "Якість JPEG", "JPEG quality"],
  maxWidthLabel:    ["Макс. ширина (0 = как есть)", "Макс. ширина (0 = як є)", "Max width (0 = original)"],
  maxFramesLabel:   ["Макс. кадров (0 = без лимита)", "Макс. кадрів (0 = без ліміту)", "Max frames (0 = unlimited)"],
  filenameTemplate: ["Шаблон имени файла", "Шаблон імені файлу", "Filename template"],
  stitchFrames:     ["Склеить выбранные в одну картинку", "Склеїти обрані в одну картинку", "Stitch selected into one image"],
  stitchHint:       ["Сохраняет выбранные кадры ещё и одной картинкой (слева направо в порядке кликов).", "Зберігає обрані кадри ще й однією картинкою (зліва направо в порядку кліків).", "Also saves the selected frames as one image (left-to-right in click order)."],
  formatTxt:        ["Текст (TXT)", "Текст (TXT)", "Text (TXT)"],
  formatSrt:        ["Субтитры (SRT)", "Субтитри (SRT)", "Subtitles (SRT)"],
  txEngine:         ["Движок распознавания", "Рушій розпізнавання", "Recognition engine"],
  txDeviceAuto:     ["Авто", "Авто", "Auto"],
  txModelHint:      ["Первый запуск скачивает модель распознавания (~80 МБ) с huggingface.co. Дальше работает офлайн из кэша браузера.", "Перший запуск завантажує модель розпізнавання (~80 МБ) з huggingface.co. Далі працює офлайн із кешу браузера.", "First run downloads the recognition model (~80 MB) from huggingface.co. After that it works offline from the browser cache."],
  aboutTitle:       ["О приложении", "Про застосунок", "About"],
  aboutBody:        ["Всё происходит локально в браузере: ни видео, ни кадры, ни текст никуда не загружаются. Запись результата в выбранную папку доступна в Chrome/Edge; в других браузерах результат скачивается ZIP-архивом.", "Усе відбувається локально в браузері: ні відео, ні кадри, ні текст нікуди не завантажуються. Запис результату в обрану папку доступний у Chrome/Edge; в інших браузерах результат завантажується ZIP-архівом.", "Everything runs locally in the browser: no video, frames, or text are uploaded anywhere. Writing results into a chosen folder works in Chrome/Edge; other browsers download a ZIP."],

  // results
  noScenesTitle:    ["Смены сцен не найдены", "Зміни сцен не знайдено", "No scene changes found"],
  retryHint:        ["Попробуйте повысить чувствительность (понизить порог) в настройках.", "Спробуйте підвищити чутливість (знизити поріг) у налаштуваннях.", "Try raising sensitivity (lower the threshold) in Settings."],
  noSpeechTitle:    ["Речь не распознана", "Мовлення не розпізнано", "No speech recognized"],
  noSpeechMsg:      ["В аудиодорожке не нашлось распознаваемой речи.", "В аудіодоріжці не знайшлося розпізнаваного мовлення.", "No recognizable speech was found in the audio."],
  transcriptDone:   ["Транскрипция готова", "Транскрипція готова", "Transcript ready"],
  noAudioTrack:     ["В файле нет аудиодорожки — транскрибировать нечего.", "У файлі немає аудіодоріжки — транскрибувати нічого.", "The file has no audio track — nothing to transcribe."],
  errorTitle:       ["Ошибка", "Помилка", "Error"],
  cancelled:        ["Отменено.", "Скасовано.", "Cancelled."],
};

let current = (() => {
  const saved = localStorage.getItem(STORE_KEY);
  if (saved && LANGS.includes(saved)) return saved;
  const nav = (navigator.language || "ru").slice(0, 2);
  return LANGS.includes(nav) ? nav : "ru";
})();

const listeners = new Set();

export function getLang() { return current; }

export function setLang(l) {
  if (!LANGS.includes(l) || l === current) return;
  current = l;
  localStorage.setItem(STORE_KEY, l);
  document.documentElement.lang = l;
  applyI18n(document);
  listeners.forEach((fn) => fn(l));
}

export function onLangChange(fn) { listeners.add(fn); }

/** Translate a key. Falls back to the key itself if missing. */
export function t(key) {
  const entry = DICT[key];
  if (!entry) return key;
  const idx = LANGS.indexOf(current);
  return entry[idx] ?? entry[0];
}

/** Set textContent of every [data-i18n] (and placeholder of every [data-i18n-ph]) under root. */
export function applyI18n(root = document) {
  root.querySelectorAll("[data-i18n]").forEach((el) => {
    el.textContent = t(el.getAttribute("data-i18n"));
  });
  root.querySelectorAll("[data-i18n-ph]").forEach((el) => {
    el.placeholder = t(el.getAttribute("data-i18n-ph"));
  });
}

// ----- Parametrized / pluralized helpers -----

export function savedFrames(n) {
  return { ru: `Сохранено кадров: ${n}`, uk: `Збережено кадрів: ${n}`, en: `Saved frames: ${n}` }[current];
}
export function framesDone(n) {
  return { ru: `Готово: ${n} ${pluralRu(n, "кадр", "кадра", "кадров")}`,
           uk: `Готово: ${n} ${pluralUk(n, "кадр", "кадри", "кадрів")}`,
           en: `Done: ${n} frame${n === 1 ? "" : "s"}` }[current];
}
export function saveSelected(n) {
  return { ru: `Сохранить выбранные (${n})`, uk: `Зберегти обрані (${n})`, en: `Save selected (${n})` }[current];
}
export function selectedOf(n, m) {
  return { ru: `Выбрано ${n} из ${m}`, uk: `Обрано ${n} з ${m}`, en: `Selected ${n} of ${m}` }[current];
}
export function processSelected(n) {
  return { ru: `Обработать выбранные (${n})`, uk: `Обробити обрані (${n})`, en: `Process selected (${n})` }[current];
}
export function processingOf(i, n) {
  return { ru: `Обработка ${i} из ${n}…`, uk: `Обробка ${i} з ${n}…`, en: `Processing ${i} of ${n}…` }[current];
}
export function summary(done, failed) {
  if (!failed) return { ru: `Готово: ${done}`, uk: `Готово: ${done}`, en: `Done: ${done}` }[current];
  return { ru: `Готово: ${done}, ошибок: ${failed}`, uk: `Готово: ${done}, помилок: ${failed}`, en: `Done: ${done}, errors: ${failed}` }[current];
}
export function stitchedSuffix() {
  return { ru: " + склеенная картинка", uk: " + склеєна картинка", en: " + stitched image" }[current];
}
export function downloadingModelPct(p) {
  return { ru: `Загрузка модели… ${p}%`, uk: `Завантаження моделі… ${p}%`, en: `Loading model… ${p}%` }[current];
}

function pluralRu(n, one, few, many) {
  const m10 = n % 10, m100 = n % 100;
  if (m10 === 1 && m100 !== 11) return one;
  if (m10 >= 2 && m10 <= 4 && !(m100 >= 12 && m100 <= 14)) return few;
  return many;
}
function pluralUk(n, one, few, many) { return pluralRu(n, one, few, many); }

document.documentElement.lang = current;
