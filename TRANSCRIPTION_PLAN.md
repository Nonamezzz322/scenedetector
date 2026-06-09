# SceneShot — план реализации: автоматическая транскрипция голоса

Добавляем в существующее приложение SceneShot вторую функцию: **автоматическую расшифровку речи** из видео в текст (TXT) и субтитры (SRT), полностью офлайн, без облака и без настройки.

> Источник этого плана — фоновый workflow `transcription-plan` (7 дизайн-агентов A–G + 3 скептика-верификатора). Воркфлоу был остановлен на фазе синтеза; его сырые выводы сохранены в [TRANSCRIPTION_WORKFLOW_RAW.md](TRANSCRIPTION_WORKFLOW_RAW.md). Здесь — готовый поэтапный план с промптами, **с уже внесёнными правками верификаторов**.

**Зафиксированные решения (не пересматриваем):**
- Движок: вшитый **whisper.cpp** (`whisper-cli`), CPU-only, как отдельный дочерний процесс — той же моделью, что и ffmpeg.
- Модель: **ggml-base** (мультиязычная, ~142 МБ) — вшита в бандл. Поддерживает русский и английский, авто-определение языка.
- Вывод: **TXT + SRT** (оба по умолчанию включены).
- UI: отдельная вкладка **«Транскрипция»** рядом с «Кадры»; существующий флоу кадров не трогаем.
- Та же философия, что у кадров: вшитый бинарник, ноль настройки от пользователя, разумные дефолты с полным контролем.

**Вердикт верификаторов (все 3 — feasible, confidence high):** сборка whisper.cpp из исходников под Command Line Tools (без полного Xcode) — рабочая. Подтверждено выполнением: clone v1.7.4 + cmake-конфигурация дают рабочий универсальный `whisper-cli` ~2.8 МБ с чистой линковкой (только `/usr/lib` + Accelerate, без `@rpath`-dylib), `minos 13.0`, запускается и ad-hoc-подписывается. **Обязательные правки из ревью встроены в этапы ниже.**

---

## 0. Что получает маркетолог (целевой UX)

1. Тот же `SceneShot.dmg`, та же установка (перетащить в «Программы»).
2. В окне сверху — переключатель **«Кадры» / «Транскрипция»**.
3. Во вкладке «Транскрипция»: перетаскивает видео / вставляет ссылку (как в кадрах), выбирает язык (**Авто** по умолчанию), оставляет TXT+SRT включёнными.
4. Жмёт **«Транскрибировать»** → прогресс с процентами и ETA → по готовности открывается папка с `transcript.txt` и `transcript.srt`, а в окне — превью текста с кнопкой «Копировать».
5. Никакого интернета, аккаунтов, ключей API — всё локально на его маке.

---

## 1. Архитектура (как ложится на существующий код)

- **Переиспользуем готовый дедлок-безопасный раннер процессов.** `FFmpeg.swift` уже умеет: резолвить бинарник по архитектуре (`Helpers/<arch>/`), запускать `Process`, конкурентно дренировать stdout+stderr и завершать через `DispatchGroup` (3 входа: EOF stdout / EOF stderr / termination). Whisper подключается **одной строкой** — новым case в enum инструментов.
- **Конвейер транскрипции:** `Source` (файл/ссылка) → ffmpeg извлекает аудио в **16 кГц моно PCM s16le WAV** (whisper.cpp требует именно это) → `whisper-cli -m ggml-base.bin -f audio.wav` пишет `transcript.txt` + `transcript.srt` → UI читает TXT и показывает превью.
- **Прогресс** whisper берём из stderr-строки `whisper_print_progress_callback: progress = N%` (флаг `-pp`); фолбэк — таймкоды сегментов `[hh:mm:ss.fff --> …]` делить на длительность WAV.
- **Сборка та же:** swiftc + lipo + ручная сборка бандла, только Command Line Tools. Whisper собирается из исходников отдельным скриптом `fetch-whisper.sh` (как `fetch-ffmpeg.sh`), бинарь и модель кладутся в `Resources/`.
- **Модель — это данные, а не код:** `ggml-base.bin` арх-независим → **один** файл в `Contents/Resources/Models/`, не дублируется по архитектурам и НЕ подписывается отдельно (запечатывается подписью бандла).

### Новые/изменяемые файлы (сводно)
```
Scripts/
  fetch-whisper.sh            # NEW — собрать whisper-cli из исходников + скачать модель (пины URL+sha256)
  build.sh                    # EDIT — chmod/codesign +whisper-cli; копировать Models/ и WHISPER-LICENSE.txt
  sign.sh                     # EDIT — подписывать whisper-cli ДО .app
  make-dmg.sh                 # EDIT — положить WHISPER-LICENSE.txt в DMG
  test-transcribe.sh          # NEW — headless-приёмка конвейера
Resources/
  Helpers/arm64/whisper-cli   # NEW — универсальный fat-бинарь (копия в обе arch-папки)
  Helpers/x86_64/whisper-cli  # NEW — та же копия (резолвер найдёт на любом хосте)
  Models/ggml-base.bin        # NEW — ~142 МБ, арх-независимая модель
  WHISPER-LICENSE.txt         # NEW — MIT whisper.cpp + атрибуция модели
  SceneShot.entitlements      # EDIT — НЕ добавлять JIT-энтайтлмент (комментарий с обоснованием)
Sources/SceneShot/
  Engine/
    FFmpeg.swift              # EDIT — +case whisper = "whisper-cli" (одна строка)
    MediaProbe.swift          # EDIT — +hasAudio/audioCodec (без новых вызовов ffprobe)
    AudioExtractor.swift      # NEW — Source → 16к моно s16le WAV (+ pre-flight «нет звука»)
    WhisperEngine.swift       # NEW — обёртка whisper-cli, зеркало SceneExtractor.swift
  SceneShotApp.swift          # EDIT — ContentView() → RootView()
  Views/
    RootView.swift            # NEW — сегментированный переключатель «Кадры»/«Транскрипция»
    FramesView.swift          # NEW — бывший ContentView без изменений логики
    TranscriptionView.swift   # NEW — ввод + язык + форматы + прогресс
    TranscriptionResultsView.swift  # NEW — превью TXT, «Открыть папку», «Копировать»
```

---

## 2. ⚠️ Что нужно один раз сделать разработчику

- **Установить cmake** на сборочной машине: `~/.brew/bin/brew install cmake` (git и make уже есть в CLT; cmake — нет). `fetch-whisper.sh` обязан проверять наличие cmake и падать с понятным сообщением, как `build.sh` делает для `swiftc`.
- **Никаких изменений для конечного пользователя** — он по-прежнему только ставит бинарник.
- **Размер растёт:** бинарь whisper ~3 МБ + модель ~142 МБ → DMG вырастает примерно до **~280 МБ**. Это в пределах нормы для офлайн-распознавания; отметить в README.
- **Метал/CoreML недоступны под CLT** (`xcrun --find metal`/`metallib` отсутствуют — проверено) → собираем строго **CPU-only** (`-DGGML_METAL=OFF -DWHISPER_COREML=OFF`). Это не фолбэк, а единственный детерминированный путь.

---

## Этапы реализации

Порядок: **T1** даёт бинарь+модель → **T2/T3** строят движок → **T4** добавляет вкладку (сначала на заглушке) → **T5** доводит вывод/превью → **T6** проверяет всё headless-скриптом.

---

### T1 — Сборка и встраивание whisper.cpp + модели (+ упаковка/подпись/лицензия)

**Цель:** получить универсальный `whisper-cli` и модель `ggml-base.bin` в бандле, подписанные и лицензионно чистые; DMG собирается как раньше.

**Файлы:** `Scripts/fetch-whisper.sh` (NEW), `Scripts/build.sh` (EDIT), `Scripts/sign.sh` (EDIT), `Scripts/make-dmg.sh` (EDIT), `Resources/WHISPER-LICENSE.txt` (NEW), `Resources/SceneShot.entitlements` (EDIT), `Resources/Helpers/{arm64,x86_64}/whisper-cli` (NEW), `Resources/Models/ggml-base.bin` (NEW).

**Промпт для агента:**
> Собери и вшей универсальный (arm64+x86_64) `whisper-cli` и модель `ggml-base` из исходников **только под Command Line Tools** (полного Xcode нет). ЗАФИКСИРОВАНО (проверено, не пересматривать): `xcrun --find metal`/`metallib` падают → сборка строго CPU-only (`GGML_METAL=OFF`); cmake НЕ установлен, но Homebrew есть (`~/.brew`); git+make есть; хост arm64; SDK в `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk` умеет кросс-компиляцию x86_64; whisper.cpp — MIT.
>
> 1. **`Scripts/fetch-whisper.sh`** (зеркало `Scripts/fetch-ffmpeg.sh`: `set -euo pipefail`, `cd "$(dirname "$0")/.."`, `FORCE=1` для рефреша, пины ref/sha, hard-fail при несовпадении sha, финальная проверка хост-бинаря):
>    - a) **Prereq-guard cmake:** `command -v cmake >/dev/null || { command -v brew >/dev/null && brew install cmake || { echo 'ERROR: нужен cmake (brew install cmake; Homebrew в ~/.brew)'>&2; exit 1; }; }`. Не авто-ставить молча — падать с точной командой.
>    - b) Пин `WHISPER_REF="v1.7.4"` (тег, проверен; апать осознанно). `git clone --depth 1 --branch "$WHISPER_REF" https://github.com/ggml-org/whisper.cpp` в scratch-папку под `dist/.build` (НЕ вендорить исходники в репо).
>    - c) **ОСНОВНОЙ путь — per-arch + lipo** (совпадает с конвенцией `build.sh`, каждый под-билд чисто ложится на реальную ветку CPU-арки): для каждой из `arm64`,`x86_64` отдельный build-каталог с `-DCMAKE_OSX_ARCHITECTURES=<arch>`, затем `lipo -create … -output <fat>`. Флаги конфигурации: `-DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 -DGGML_METAL=OFF -DGGML_METAL_EMBED_LIBRARY=OFF -DWHISPER_COREML=OFF -DGGML_NATIVE=OFF -DWHISPER_BUILD_TESTS=OFF -DBUILD_SHARED_LIBS=OFF`. Для x86_64-ветки добавь явные `-DGGML_AVX=OFF -DGGML_AVX2=OFF` (детерминизм базовой линии). **Фолбэк за `SINGLE_CONFIGURE=1`:** одна конфигурация с `-DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"`.
>    - d) **Assert статической линковки:** `otool -L <fat>` должен показывать только `/usr/lib` + `/System/Library` (без `libwhisper`/`libggml` dylib). Если появились dylib — падать с понятным сообщением.
>    - e) Положи fat-бинарь в **обе** arch-папки (резолвер `FFmpeg.swift` найдёт его на любом хосте): `cp <fat> Resources/Helpers/arm64/whisper-cli; cp <fat> Resources/Helpers/x86_64/whisper-cli; chmod +x …`.
>    - f) Модель: `MODEL_URL` — **коммит-пиннутый** raw-URL Hugging Face (`https://huggingface.co/ggml-org/whisper.cpp/resolve/<commit-sha>/ggml-base.bin`, НЕ `resolve/main/` — иначе «движущийся latest»), dest `Resources/Models/ggml-base.bin`, `curl -fL --retry 3 -o`. Пре-чек точного размера `EXPECTED_SIZE=147951465` (`stat -f%z`). `EXPECTED_SHA256="REPLACE_AFTER_FIRST_FETCH"` — на первом запуске печатать вычисленный `shasum -a 256` и громкий WARNING «впиши значение»; когда задан — verify и `exit 1` при несовпадении (whisper.cpp не публикует чек-суммы модели → пин-на-первом-фетче, как в `fetch-ffmpeg.sh`).
>    - g) Финальная проверка: `Resources/Helpers/$(uname -m)/whisper-cli --help | head -1` (exit 0) и `lipo -info Resources/Helpers/arm64/whisper-cli` (должно быть `arm64 x86_64`). Также проверь, что `whisper-cli -h` перечисляет флаги `-pp -otxt -osrt -of` (защита от дрейфа версии).
> 2. **`Resources/WHISPER-LICENSE.txt`**: текст MIT whisper.cpp + заметка, что `ggml-base.bin` — это модель OpenAI Whisper base (MIT), конвертированная ggml-org, и что `whisper-cli` вызывается как отдельный процесс (не линкуется в приложение). Тон — как у `Resources/FFMPEG-LICENSE.txt`.
> 3. **`Scripts/build.sh`** (ОБЯЗАТЕЛЬНЫЕ правки из ревью — НЕ только sign.sh):
>    - Строка ~66 (chmod после копирования Helpers): добавь `-o -name 'whisper-cli'` в предикат `find`.
>    - Строка ~78 (ad-hoc codesign вложенных): добавь `-o -name 'whisper-cli'` — **иначе в основном (ad-hoc) билде бинарь whisper остаётся неподписанным и `codesign --verify --strict` падает**.
>    - После блока Helpers: `if [ -d "$ROOT/Resources/Models" ]; then mkdir -p "$APP/Contents/Resources/Models"; cp -R "$ROOT/Resources/Models/." "$APP/Contents/Resources/Models/"; fi`.
>    - Копировать лицензию: `[ -f "$ROOT/Resources/WHISPER-LICENSE.txt" ] && cp … "$APP/Contents/Resources/WHISPER-LICENSE.txt"`.
> 4. **`Scripts/sign.sh`**: добавь `-o -name whisper-cli` в `find` вложенных бинарей (подписываются ДО `.app`, ветки ad-hoc и Developer ID). Модель НЕ подписывать.
> 5. **`Scripts/make-dmg.sh`**: скопируй `Resources/WHISPER-LICENSE.txt` в stage DMG (рядом с FFMPEG-LICENSE.txt).
> 6. **`Resources/SceneShot.entitlements`**: НЕ добавлять `com.apple.security.cs.allow-jit` / `allow-unsigned-executable-memory`. CPU-only ggml исполняет прекомпилированные SIMD-ядра (NEON/AVX), не мапит W^X-память → JIT не нужен. Существующего `com.apple.security.cs.disable-library-validation` достаточно (именно он позволяет запускать отдельно подписанный вложенный ffmpeg под hardened runtime). Добавь комментарий с обоснованием и закомментированный фолбэк на случай будущей Metal/CoreML-сборки.

**Критерии приёмки:** `./Scripts/fetch-whisper.sh` создаёт `Resources/Helpers/{arm64,x86_64}/whisper-cli` (fat, обе арки по `lipo -info`) и `Resources/Models/ggml-base.bin` (147 951 465 байт, sha совпадает с пином); `whisper-cli --help` exit 0; `otool -L` без лишних dylib; `./Scripts/build.sh` собирает `dist/SceneShot.app` с подписанным whisper-cli и моделью+лицензией под `Contents/Resources/`; `codesign --verify --strict` проходит.

---

### T2 — Движок извлечения аудио (ffmpeg → 16к моно s16le WAV) + детект «нет звука»

**Цель:** из любого `Source` (файл или ссылка) получить готовый для whisper WAV; немое видео отсекать заранее дружелюбной ошибкой, не запуская лишний проход.

**Файлы:** `Sources/SceneShot/Engine/AudioExtractor.swift` (NEW), `Sources/SceneShot/Engine/MediaProbe.swift` (EDIT).

**Промпт для агента:**
> Добавь движок `AudioExtractor`, превращающий `Source` (локальный файл или URL) в WAV для whisper.cpp, плюс pre-flight проверку наличия звука. Структуру зеркаль с `SceneExtractor.swift`, временные файлы — по конвенции `Downloader` (`FileManager.default.temporaryDirectory` + `sceneshot-audio-<UUID>.wav`).
>
> 1. **Команда извлечения** (проверена на вшитом ffmpeg 8.1.1): `ffmpeg -hide_banner -nostdin -i INPUT -vn -ac 1 -ar 16000 -c:a pcm_s16le -progress pipe:1 -y OUT.wav`. Это даёт ровно `codec_name=pcm_s16le, sample_rate=16000, channels=1, bits_per_sample=16`. Флаги держи явными в одном месте (легко поменять, если будущий whisper попросит f32). Добавь `-nostdin`, чтобы ffmpeg не съедал родительский stdin на длинных удалённых чтениях.
> 2. **Прогресс — 100% переиспользование:** `-progress pipe:1` шлёт те же строки `out_time=HH:MM:SS.micro` / `progress=end` в stdout, что уже парсит `SceneExtractor.parseProgress`. Вызывай его напрямую, не дублируй парсер. Запуск — через тот же `FFmpeg.shared.launch`, отмена — `Running.cancel()`, проверка `exitCode`, ошибки — через существующий `FFmpegError.failed`.
> 3. **Детект «нет звука» БЕЗ нового вызова ffprobe:** существующие аргументы `MediaProbe` уже возвращают аудиопотоки в массиве `streams`. В `MediaProbe.swift` расширь `MediaInfo` полями `hasAudio: Bool` и `audioCodec: String?`, а `parse()` — сканированием `streams` на `codec_type == "audio"`. Аргументы ffprobe НЕ менять.
> 4. **Pre-flight guard:** если `MediaInfo.hasAudio == false`, бросай ТИПИЗИРОВАННУЮ `AudioExtractError.noAudio` ДО запуска ffmpeg, с дружелюбным русским сообщением («В файле нет звуковой дорожки»). Важно: вызывающий обязан передавать уже **прозонданный** `MediaInfo` (как кадровый флоу передаёт `durationSeconds`); задокументируй это.
> 5. **Удалённые источники:** переиспользуй `Source.isRemote` (те же reconnect-флаги, что в `SceneExtractor`) и существующий `Downloader` для режима «сначала скачать» — нового сетевого кода не пиши. Оркестратор передаёт `.file(downloadedURL)` для download-first и `.remote(url)` для стрима.
> 6. **Жизненный цикл temp:** WAV удаляется при отмене и при ошибке ffmpeg; на успехе владение переходит вызывающему (движок whisper удалит после расшифровки).

**Критерии приёмки:** на видео со звуком возвращает валидный WAV (проверка ffprobe: pcm_s16le/16000/mono); на немом видео бросает `AudioExtractError.noAudio` ДО запуска ffmpeg; прогресс идёт через `parseProgress`; отмена и ошибка не оставляют temp-файлов; `MediaProbe` отдаёт `hasAudio` корректно (со звуком/без), аргументы ffprobe не изменены.

---

### T3 — Обёртка WhisperEngine + обобщение раннера процессов

**Цель:** запускать `whisper-cli` через тот же дедлок-безопасный раннер и получать `transcript.txt` + `transcript.srt` с прогрессом, отменой и переводом языка.

**Файлы:** `Sources/SceneShot/Engine/FFmpeg.swift` (EDIT, одна строка), `Sources/SceneShot/Engine/WhisperEngine.swift` (NEW).

**Промпт для агента:**
> 1. **Обобщи раннер ОДНОЙ строкой:** в enum `FFmpegTool` (в `Sources/SceneShot/Engine/FFmpeg.swift`) добавь `case whisper = "whisper-cli"`. `toolURL()` и `launch()` уже инструмент-агностичны и работают по `rawValue` → это автоматически резолвит `Contents/Resources/Helpers/<arch>/whisper-cli` и гоняет его через неизменный `launch()` (DispatchGroup + конкурентный дренаж stdout/stderr). Не переименовывай enum, не трогай `MediaProbe`/`SceneExtractor`/`Downloader`.
> 2. **`WhisperEngine.swift`** — зеркало `SceneExtractor.swift`:
>    - Сначала транскодируй источник в 16к моно s16le WAV (через `AudioExtractor` из T2, либо `FFmpeg.shared.run(.ffmpeg,…)` напрямую), temp-файл удаляй через `defer`.
>    - Резолвь модель: `Bundle.main.resourceURL` + `Models/ggml-base.bin`. Если бинаря или модели нет — бросай `FFmpegError.toolMissing` (сырой stderr — только в технический лог, не в лицо пользователю).
>    - Запусти `whisper-cli -m <model> -f <wav> -l <auto|ru|en> -otxt -osrt -of <outbase> -t <threads> -pp`. `-of` принимает basename **без расширения** (иначе получится `.txt.txt`). Язык по умолчанию `auto` (whisper сам определит ru/en); пользователь может форсировать ru/en.
>    - Потоки: `-t` = `min(физические ядра, 8)` (пере-подписка сверх физических ядер вредит throughput whisper).
>    - **Прогресс** из stderr-строки `whisper_print_progress_callback: progress = N%` → `N/100`. Фолбэк: старт сегментного таймкода `[hh:mm:ss.fff --> …]` ÷ длительность WAV (заведи и на stdout — часть сборок шлёт сегменты туда).
>    - Отмена через `running.cancel()` → `terminate()`; на каждой фазе nil-чекай активный handle (во время ffmpeg-транскода `running` ещё nil). Если отменено — верни `.cancelled` ДО проверки наличия файлов; частичные `.txt/.srt` от прерванного whisper НЕ репортить как `.done`.
>    - В конце собери `<outbase>.txt` и `<outbase>.srt`.

**Критерии приёмки:** на тестовом видео со звуком создаёт непустой `transcript.txt` и валидный `transcript.srt`; прогресс монотонно растёт 0→1; отмена в любой фазе (транскод/распознавание) даёт `.cancelled` без ложного `.done`; отсутствие модели/бинаря → `FFmpegError.toolMissing`; русская речь распознаётся при `-l auto` и `-l ru`.

---

### T4 — UI: вкладка «Транскрипция» без поломки флоу «Кадры»

**Цель:** добавить верхний переключатель «Кадры»/«Транскрипция»; существующий кадровый экран остаётся бит-в-бит прежним; новая вкладка компилируется независимо от движка (через тонкий контракт-заглушку).

**Файлы:** `SceneShotApp.swift` (EDIT), `ContentView.swift` → `Views/FramesView.swift` (MOVE/RENAME), `Views/RootView.swift` (NEW), `Views/TranscriptionView.swift` (NEW), `Engine/Transcriber.swift` (NEW — контракт + заглушка).

**Промпт для агента:**
> Отрефактори монолитный `ContentView` в `RootView`, который держит верхний **сегментированный `Picker`** между «Кадры» (существующий флоу) и «Транскрипция» (новый).
> 1. **Переключатель — сегментированный `Picker`**, не `TabView` (совпадает с `.pickerStyle(.segmented)` в `SettingsView`, сохраняет единый `WindowGroup` + `.windowResizability(.contentSize)`).
> 2. **`ContentView` → `FramesView`** (перенести в `Views/`, переименовать структуру, **ноль изменений логики** — только largeTitle-заголовок и внешний `minWidth/minHeight` поднять в `RootView`). Это делает «поведение кадров идентично» доказуемым.
> 3. **Ввод дублируем** в `TranscriptionView` (копировать `dropZone`/`urlRow`/`sourceSummary` + `pickVideo`/`handleDrop`/`loadFromURL`/`setSource`/`failInput`), а НЕ извлекаем в общий компонент в этом этапе — чтобы гарантированно не задеть кадровый флоу. Пометить как осознанный долг: отдельный cleanup-этап потом вынесет общий `SharedSourceInput`, когда обе вкладки зелёные. Переиспользуй существующие `Source`/`VideoValidation`/`MediaProbe`/`Downloader.validate`.
> 4. **`TranscriptionView`** добавляет: пикер языка (Авто/Русский/English), тумблеры TXT/SRT (оба on по умолчанию), пикер папки вывода, статичную строку «Модель: base (встроена)», большую кнопку «Транскрибировать», прогресс+ETA+отмену и карточку результата — на том же паттерне состояний `idle/probing/working/done/empty/error/cancelled`, что и кадры.
> 5. **Контракт движка-заглушка:** объяви `Transcriber` (класс) + `TranscribeParams` + `TranscribeOutcome` + `TranscriptResult` с заглушечной реализацией, бросающей `FFmpegError.toolMissing("whisper")` — чтобы UI собирался и кнопка работала end-to-end независимо от T3. Реальную реализацию из T3 подставит интеграция.
> 6. **Обе вкладки живут одновременно** (`ZStack` + `opacity`/`allowsHitTesting`, не `switch`), чтобы идущая извлечение/расшифровка пережила переключение вкладок.
> 7. **Новые `@AppStorage`-ключи с префиксом `tx_`** (`tx_language`/`tx_txt`/`tx_srt`/`tx_outputFolderPath`) + `activeTab` — никаких коллизий с 9 существующими кадровыми ключами. Точка входа: `ContentView()` → `RootView()` в `SceneShotApp.swift`.

**Критерии приёмки:** приложение собирается и запускается; вкладка «Кадры» работает идентично прежнему (извлечение кадров проходит как раньше); вкладка «Транскрипция» рендерит ввод/язык/форматы/прогресс; кнопка с заглушкой даёт честную ошибку «whisper недоступен»; переключение вкладок не прерывает идущий процесс; кадровые настройки не сбрасываются.

---

### T5 — Вывод TXT+SRT и UX результата/превью/сохранения

**Цель:** записать TXT+SRT в папку на запуск, показать читаемое выделяемое превью текста и кнопки «Открыть папку»/«Показать в Finder»/«Копировать текст»; «нет речи» — отдельное состояние.

**Файлы:** `Views/TranscriptionResultsView.swift` (NEW), интеграция в `TranscriptionView`/`Transcriber` из T3–T4.

**Промпт для агента:**
> Спроектируй вывод и экран результата вкладки «Транскрипция», зеркаля паттерн `ResultsView` кадров.
> 1. **Папка вывода:** переиспользуй конвенцию `makeOutputDir` (override `@AppStorage transcriptOutputFolderPath`, фолбэк `.moviesDirectory`, тот же штамп `yyyy-MM-dd_HH-mm-ss`), но суффикс `-transcript-<stamp>`: `~/Movies/SceneShot/<name>-transcript-<stamp>/`. Отдельный ключ `@AppStorage`, чтобы кадры и транскрипты не сталкивались под общим родителем.
> 2. **Сайдкары whisper:** `-of <dir>/transcript -otxt -osrt` → `transcript.txt` + `transcript.srt`. `-of` ОБЯЗАТЕЛЬНО без расширения. Фиксированный basename `transcript` делает пути детерминированными.
> 3. **`TranscriptResult`** — типизированный enum `.done/.empty/.error/.cancelled` (отдельный от кадрового `RunResult`), свитчится в `TranscriptResultsView` (без общего generic-компонента — у каждой вкладки свой набор affordances).
> 4. **Превью TXT** читается ОДИН раз на фоновом завершении движка и передаётся в view готовой `String` (не читать в `body` — та же дисциплина главного потока, что в `ResultsView`); рендер — скроллируемый `textSelection(.enabled)` monospaced (модификатор уже используется для технического лога).
> 5. **Кнопки бит-в-бит:** `NSWorkspace.shared.activateFileViewerSelecting([txtURL])` («Показать в Finder»), `NSWorkspace.shared.open(dir)` («Открыть папку»), плюс «Копировать текст» через `NSPasteboard` с подтверждением «Скопировано» на 1.5 с.
> 6. **«Нет речи» — первоклассное состояние `.empty`:** детект по whitespace-only TXT после 0-exit запуска, отдельное русское сообщение «Речь не распознана», без кнопки повтора (у whisper нет аналога порога чувствительности).
> 7. **Санити SRT — не фатально:** лёгкая проверка таймкодов (`HH:MM:SS,mmm --> HH:MM:SS,mmm`, монотонность) только добавляет мягкое предупреждение `srtWarning` к `.done`, НИКОГДА не низводит запуск до `.error`.

**Критерии приёмки:** успешный прогон создаёт `transcript.txt`+`transcript.srt` в `~/Movies/SceneShot/<name>-transcript-<stamp>/`; превью показывает выделяемый текст; три кнопки работают; «Копировать» кладёт текст в буфер с подтверждением; немой/без-речи ролик даёт состояние «Речь не распознана»; битый таймкод SRT — предупреждение, не ошибка.

---

### T6 — Тестирование, граничные случаи, производительность

**Цель:** воспроизводимая headless-приёмка всего конвейера (как уже принято в репо — shell-скрипты, не XCTest).

**Файлы:** `Scripts/test-transcribe.sh` (NEW), правки `PLAN.md`/`README.md`.

**Промпт для агента:**
> Напиши `Scripts/test-transcribe.sh` — headless-проверку конвейера транскрипции (в репо НЕТ `Tests/` и тест-таргета в `Package.swift` → тесты это shell-скрипты, как акцептанс у `build.sh`).
> 1. **Генерация входа без сети:** `say -o /tmp/clip.aiff "Привет, это тест транскрипции."` → прогнать через вшитый `Resources/Helpers/$(uname -m)/ffmpeg` с `-ar 16000 -ac 1 -c:a pcm_s16le` → `/tmp/clip.wav` (проверено: даёт pcm_s16le/16000/mono).
> 2. **Запуск whisper:** `Resources/Helpers/$(uname -m)/whisper-cli -m Resources/Models/ggml-base.bin -f /tmp/clip.wav -l auto -otxt -osrt -of /tmp/clip -pp -t $(sysctl -n hw.physicalcpu)`.
> 3. **Толерантные ассерты** (база модели даёт вариативность): load-bearing гарантии — **непустой `clip.txt`** и **≥1 таймкод в `clip.srt`**; проверка слов — регистронезависимо, OR-группами (например, «тест|транскрипц|привет»). Не требовать точного совпадения строки.
> 4. **Граничные случаи в чек-лист `PLAN.md` §7:** видео без звука (ожидать «нет звуковой дорожки»), очень длинное видео (размер WAV ~1.9 МБ/мин ≈ 115 МБ/час в temp — чистить после), отмена в фазе транскода и в фазе распознавания, удалённая ссылка (стрим vs download-first), не-русская/смешанная речь при `-l auto`.
> 5. **Производительность:** база CPU-only, потоки `min(hw.physicalcpu, 8)`; Metal/CoreML явно отложены (для base ускорение умеренное, а CoreML тянет отдельную модель+кэш+подпись — конфликт с офлайн/zero-config). Зафиксировать ожидания скорости в README (база ≈ реальное время × коэффициент на CPU).
> 6. Обнови `PLAN.md` (§3 структура, §4 prerequisites — cmake, §7 чек-лист, §8 риски — размер DMG/temp) и `README.md` (шаг `fetch-whisper`, ~280 МБ DMG, лицензия whisper, ожидания скорости).

**Критерии приёмки:** `./Scripts/test-transcribe.sh` на машине с собранным бинарём+моделью проходит (непустой TXT, ≥1 таймкод SRT, exit 0); чек-лист в `PLAN.md` покрывает немое/длинное/отменённое/удалённое/мультиязычное; `README` отражает новый шаг сборки, размер и лицензию.

---

## 3. Сводка зафиксированных технических решений (из ревью)

| Тема | Решение | Почему |
|---|---|---|
| Сборка whisper | Из исходников, **CPU-only**, под CLT | Metal/metallib отсутствуют под Command Line Tools (проверено) |
| Универсальность | **per-arch + lipo** (основной), single-configure (фолбэк) | Совпадает с конвенцией `build.sh`; чистая линковка проверена |
| Линковка | `-DBUILD_SHARED_LIBS=OFF`, assert `otool -L` | Без `@rpath`-dylib — не нужны install_name-фиксы |
| Модель | `ggml-base.bin`, один файл в `Resources/Models/`, коммит-пиннутый URL+sha256 | Мультиязык (рус), арх-независима, без «движущегося latest» |
| Раннер | +`case whisper` в `FFmpegTool` (одна строка) | `toolURL`/`launch` уже инструмент-агностичны и дедлок-безопасны |
| Аудио | ffmpeg `-vn -ac 1 -ar 16000 -c:a pcm_s16le`, прогресс через `parseProgress` | Точный формат whisper; парсер прогресса переиспользуется 1:1 |
| Детект «нет звука» | расширить `MediaProbe.parse` полем `hasAudio` | ffprobe уже возвращает аудиопотоки — без нового вызова |
| Прогресс whisper | stderr `progress = N%` (`-pp`), фолбэк по таймкодам сегментов | Самодостаточно, без матема́тики длительности |
| Энтайтлменты | **НЕ** добавлять JIT | CPU ggml не мапит W^X; хватает `disable-library-validation` |
| Подпись | whisper-cli в `find` **build.sh (стр. 66 и 78)** и sign.sh, ДО `.app`; модель НЕ подписывать | Иначе ad-hoc билд оставляет бинарь неподписанным → verify падает |
| UI | сегментированный `Picker`, `ContentView`→`FramesView` без правок логики, ключи `tx_*` | Доказуемо не ломает кадровый флоу |
| Тесты | shell `test-transcribe.sh`, толерантные ассерты | В репо нет XCTest-таргета; база модели вариативна |

---

## 4. Известные риски и митигации

- **sha256 модели нельзя снять в офлайн-среде** → скрипт печатает вычисленный хэш на первом реальном фетче, мейнтейнер пинит; далее hard-fail при несовпадении (без молчаливого прохода).
- **Дрейф версии whisper.cpp** (переименование CMake-опций, имя `main` vs `whisper-cli`, dylib вопреки `BUILD_SHARED_LIBS=OFF`) → пин `v1.7.4`, апать осознанно; assert `otool -L`; проверка `whisper-cli -h` на наличие флагов.
- **Generic-baseline x86_64** (без AVX-автотюна при per-arch с `GGML_NATIVE=OFF`) → медленнее на Intel; приемлемо для офлайн base. При нужде — отдельная x86_64-сборка с `-DGGML_AVX2=ON`.
- **Размер**: бинарь ~3 МБ + модель ~142 МБ → DMG ~280 МБ. Не блокер, отметить в README.
- **Большой temp WAV** на длинных видео (~115 МБ/час) → чистить сразу после расшифровки; cleanup-on-failure/cancel уже предотвращает «осиротевшие» файлы.
- **`hasAudio` достоверен только если источник прозондирован** → вызывающий обязан передавать прозонданный `MediaInfo`; для ненадёжных удалённых серверов предпочитать download-first.

---

*Сырые выкладки всех 7 дизайн-агентов и 3 верификаторов: [TRANSCRIPTION_WORKFLOW_RAW.md](TRANSCRIPTION_WORKFLOW_RAW.md).*
