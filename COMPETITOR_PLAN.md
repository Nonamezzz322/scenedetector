# SceneShot — план: конкурент-аналітика та насмотренність

Дві фічі з категорії «Конкурент-аналітика», що складаються в один потік:
1. **Масовий збір по конкуренту** — канал/профіль/плейлист/хештег/пошук (YouTube/TikTok/Instagram) через вбудований **yt-dlp**: перелік роликів → сітка прев’ю з галочками → завантаження обраних.
2. **Метрики монтажу** — на кожне відео: к-сть склейок, склейок/хв, середня довжина сцени (ASL), медіана/мін/макс сцени, довжина хука (час до 1-ї склейки). Опційно — кадри та транскрипт. Підсумок — таблиця + **CSV-звіт** («creative intelligence»).

**Зафіксовані рішення:**
- Нова вкладка **«Конкуренти»** (4-та) — щоб не плутати з «Папка» (локальні/хмарні папки).
- Перелік — `yt-dlp --flat-playlist --dump-single-json --playlist-end N` (швидко, без резолву кожного відео). Ліміт N — налаштування (типово 24).
- Метрики — окремий аналізатор без запису кадрів: `ffmpeg select=gt(scene,thr),showinfo -f null -` (швидше за повний витяг). Кадри/транскрипт — опційно, через існуючі рушії.
- Переиспользуем `ThumbGridView` (сітка+галочки), `MediaFetcher` (завантаження), `SceneExtractor`/`WhisperEngine` (опц.), `MediaProbe`.
- Стек без нових залежностей. Усе локально.

**Чесні обмеження (в README):**
- Метрики склейок = апроксимація ритму (поріг сцени ловить жорсткі склейки; швидкий рух/плавні переходи можуть зміщувати лічбу). Це індикатор темпу, не покадровий shot-detection.
- Масовий збір TikTok/YouTube/IG залежить від площадки: IG-профілі часто потребують входу; великі канали — повільно, тому ліміт N. Дотримання ToS площадок і авторських прав — на боці користувача.

---

## Архітектура (нові/змінені файли)
```
Sources/SceneShot/
  Engine/
    MediaEnumerator.swift   # NEW — yt-dlp перелік: RemoteEntry[] (id,title,url,duration,thumb,uploader)
    SceneAnalyzer.swift     # NEW — метрики монтажу без запису кадрів (SceneMetrics)
    CompetitorAnalyzer.swift# NEW — на кожен ролик: download→metrics→опц.кадри/транскрипт→VideoMetrics + CSV
    BatchProcessor.swift    # EDIT — +BatchSource.remoteVideo (для сітки/сумісності)
  Views/
    CompetitorsView.swift   # NEW — вкладка: ввід→перелік→сітка→тумблери→прогрес→таблиця+CSV
    RootView.swift          # EDIT — 4-та вкладка «Конкуренти»
  Localization.swift        # EDIT — рядки вкладки/метрик
```

---

## Етапи

### K1 — Перелік роликів конкурента (yt-dlp flat list)
**Файли:** `Engine/MediaEnumerator.swift` (NEW).
**Промпт:**
> Додай `MediaEnumerator`, що через вбудований yt-dlp перелічує ролики з URL каналу/профілю/плейлиста/хештега або пошукового запиту.
> - `struct RemoteEntry { id, title, url, durationSec?, thumbnailURL?, uploader? }`.
> - `enumerate(_ input: String, limit: Int) async throws -> [RemoteEntry]`: запусти `.ytdlp` з `--flat-playlist --dump-single-json --no-warnings --playlist-end <limit> "<input>"` через `FFmpeg.shared.run`. Якщо input не схожий на URL — інтерпретуй як YouTube-пошук `ytsearch<limit>:<input>`.
> - Парсинг: якщо JSON має `entries` — це плейлист/канал → мапь кожен запис; інакше це одиночне відео → один RemoteEntry. Витягни `id`, `title`, `url` (fallback `webpage_url`/`id`), `duration`, `uploader`/`channel`, мініатюру (`thumbnails`.останній.`url` або `thumbnail`).
> - Помилки → типізований `EnumerateError` з людськими повідомленнями (порожньо / приватне / потрібен вхід / yt-dlp не зібрано).
> **Приймання:** на посилання YouTube-каналу/плейлиста або TikTok-профілю повертається список до N записів із заголовками; одиночне відео → 1 запис; помилки людські.

### K2 — Аналізатор метрик монтажу (без запису кадрів)
**Файли:** `Engine/SceneAnalyzer.swift` (NEW).
**Промпт:**
> Додай `SceneAnalyzer`, що рахує метрики монтажу, НЕ зберігаючи кадри.
> - `struct SceneMetrics { duration, cuts, cutsPerMin, avgShot, medianShot, minShot, maxShot, hookLen }`.
> - `analyze(source:Source, threshold:Double, duration:Double?, onProgress:) async throws -> SceneMetrics`: `ffmpeg -hide_banner -nostats [reconnect для remote] -i <input> -vf "select=gt(scene\,<thr>),showinfo" -an -progress pipe:1 -f null -`. Прогрес — `SceneExtractor.parseProgress` (stdout), таймкоди склейок — `SceneExtractor.parsePTS` (stderr). Скасування через `running.cancel()`.
> - Метрики: `boundaries=[0]+sorted(cutTimes)+[duration]`; `shots`=послідовні різниці>0; `avgShot=duration/shots.count`; median/min/max з shots; `hookLen`=перший таймкод склейки (або duration); `cutsPerMin=cuts/(duration/60)`.
> **Приймання:** на локальному відео к-сть склейок збігається з к-стю кадрів від `SceneExtractor` за тим самим порогом; ASL ≈ duration/(cuts+1).

### K3 — Рушій аналізу конкурентів (download → metrics → опц. кадри/транскрипт)
**Файли:** `Engine/CompetitorAnalyzer.swift` (NEW), `Engine/BatchProcessor.swift` (EDIT: +`BatchSource.remoteVideo(url,title)`).
**Промпт:**
> Додай `CompetitorAnalyzer: ObservableObject` (дзеркало `BatchProcessor`: statuses, overall, currentIndex, running, cancel, ізоляція помилок).
> - `struct VideoMetrics { name, url, duration, cuts, cutsPerMin, avgShot, medianShot, hookLen, transcriptWords?, language?, framesCount? }`.
> - `run(entries:[RemoteEntry], doFrames:Bool, doTranscribe:Bool, language:TranscriptLanguage, threshold:Double, baseOutputDir:URL)`: послідовно на кожен запис: статус→download через `MediaFetcher` (тимч. файл)→`MediaProbe`→`SceneAnalyzer` метрики→ (опц.) `SceneExtractor` кадри в підпапку `<output>/<title>/`→ (опц.) `WhisperEngine` транскрипт у ту ж підпапку (порахуй слова)→ зібери `VideoMetrics`→ видали тимч. Падіння одного не зупиняє решту.
> - `summary`: `[VideoMetrics]` + агрегати (середній ASL, середня к-сть склейок) + `outputDir`. Метод `exportCSV() -> URL`: запиши `report.csv` у baseOutputDir (заголовок + рядки; екрануй коми/лапки; UTF-8 BOM для Excel).
> - У `BatchProcessor` додай case `.remoteVideo(url,title)` у resolve (download через MediaFetcher) — для сумісного switch і щоб «Папка» теж могла приймати такі айтеми.
> **Приймання:** на 2-3 обраних роликах створюються підпапки + рядки метрик; CSV відкривається в Excel/Sheets; скасування зупиняє; помилка одного ролика не рушить інші.

### K4 — Вкладка «Конкуренти» (UI)
**Файли:** `Views/CompetitorsView.swift` (NEW), `Views/RootView.swift` (EDIT), `Localization.swift` (EDIT).
**Промпт:**
> Додай 4-ту вкладку «Конкуренти» в `RootView` (теги 0..3) і `CompetitorsView`.
> - Ввід: поле «посилання на канал / профіль / хештег або пошуковий запит» + поле ліміту (Stepper, типово 24) + кнопка «Знайти». Якщо yt-dlp не зібрано — підказка.
> - Перелік (K1) → `ThumbGridView` (мапь `RemoteEntry`→`GridEntry` з `BatchSource.remoteVideo`; мініатюри — завантаж `thumbnailURL` як `NSImage`, кеш у моделі; інакше плейсхолдер). «Обрати все»/«Зняти», лічильник.
> - Тумблери: **Метрики монтажу** (завжди увімкнено, disabled-checked), **Кадри** (опц.), **Транскрипція** (опц., gated як у «Папка»), мова транскрипту (Auto/Uk/Ru/En).
> - Кнопка «Проаналізувати обрані (N)» → `CompetitorAnalyzer.run` (поріг із налаштувань `@AppStorage("threshold")`, базова папка `~/Movies/SceneShot/<source>-competitors-<stamp>/`). Прогрес: загальний + поелементні статуси.
> - Результати: таблиця метрик (рядок на відео: назва, тривалість, склейки, склейок/хв, ASL, хук, слова/мова) + агрегати зверху + кнопки «Експорт CSV» і «Відкрити папку».
> **Приймання:** наскрізно на реальному каналі: знайти→обрати галочками→проаналізувати→таблиця метрик→CSV у папці.

### K5 — Локалізація, README, збірка
**Промпт:**
> Локалізуй усі видимі рядки вкладки/метрик (uk/ru/en) у `Loc`. Додай у README розділ «Конкурент-аналітика» з чесними обмеженнями (апроксимація склейок; ToS/вхід площадок; ліміт N; yt-dlp треба оновлювати). Збери універсально, перевір запуск, онови DMG.
> **Приймання:** UI трьома мовами; `./Scripts/build.sh` дає підписаний універсальний `.app`; DMG зібрано.

---

## CSV-звіт (формат)
```
name,url,uploader,duration_s,cuts,cuts_per_min,avg_shot_s,median_shot_s,hook_s,words,language
```
Один рядок на відео; зверху агрегати показуються в UI (не в CSV). UTF-8 (+BOM для Excel).
