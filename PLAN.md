# SceneShot — план реализации

Нативное macOS-приложение: разбирает видео и сохраняет кадр после каждой смены сцены в виде картинки.
Источник видео — локальный файл **или** прямая ссылка на видеофайл в интернете.
Конечный пользователь — маркетолог: ставит бинарник и пользуется, консоль открывать не нужно.

**Зафиксированные решения:**
- Стек: **Swift + SwiftUI** (нативное `.app`), не sandbox.
- Движок детекции: вшитый статический **ffmpeg/ffprobe** (фильтр `select=gt(scene,…)`).
- Подпись: **аккаунта Apple Developer нет** → ad-hoc подпись + инструкция обхода Gatekeeper, с заделом под нотаризацию позже (см. §2).
- UI: **полный контроль** настроек, но со здравыми значениями по умолчанию (можно ничего не трогать).

---

## 0. Что получает маркетолог (целевой UX)

1. Скачивает `SceneShot.dmg`, открывает, перетаскивает **SceneShot** в «Программы».
2. Запускает. *(Один раз — обход Gatekeeper, см. §2. С нотаризацией этого шага нет.)*
3. В окне: перетаскивает видеофайл / жмёт «Выбрать видео», **или** вставляет прямую ссылку на видео.
4. (Необязательно) раскрывает «Расширенные настройки»: чувствительность, формат, папка и т.д. — со здравыми дефолтами.
5. Жмёт «Извлечь кадры» → прогресс → по готовности **сама открывается папка** с картинками-кадрами смены сцен.

---

## 1. Архитектура и решения

- **GUI**: Swift + SwiftUI, цель macOS 13+ (Ventura), приложение универсальное (arm64 + x86_64), **без sandbox** (проще писать в произвольную папку и запускать вложенные бинарники).
- **Движок**: статические `ffmpeg` и `ffprobe`, вшитые в бандл (`Contents/Resources/Helpers/<arch>/`). Приложение вызывает их как дочерний процесс (`Process`) и парсит прогресс.
- **Детекция сцен**: фильтр ffmpeg `select='gt(scene,THRESH)'`. Значение `scene` — 0…1 (выше = сильнее изменение кадра). Порог ~0.3 типовой; ниже порог = больше кадров. Мы только **декодируем** и пишем картинки → энкодеры x264/x265 не нужны → можно взять **LGPL**-сборку ffmpeg (без GPL-обязательств).
- **Источник видео**: локальный файл (`NSOpenPanel` + drag&drop) **или** прямая `http(s)`-ссылка (ffmpeg читает URL напрямую; есть режим «сначала скачать»). YouTube и прочие страницы **не** поддерживаются — нужен прямой URL на файл (по ТЗ).
- **Выбор архитектуры бинарника** — в рантайме (`#if arch(arm64)`), поэтому источники static-сборок ffmpeg могут быть разными, лишь бы версия совпадала.
- **Сборка (без Xcode)**: на машине только **Command Line Tools**, полного Xcode нет. Сборка через **SwiftPM** (`Package.swift`, executable target) + `Scripts/build.sh`, который вручную собирает `.app`-бандл (`Contents/MacOS`, `Contents/Resources/Helpers`, `Contents/Info.plist`) и подписывает его. XcodeGen/`xcodebuild` не используются. Пакет при желании открывается и в Xcode, если он будет установлен. Проверено: SwiftUI/AppKit/AVFoundation компилируются под CLT (Swift 6.3).

---

## 2. ⚠️ Реальность с подписью (аккаунта Apple Developer нет)

Без **нотаризации** macOS (Gatekeeper) при первом запуске покажет «Не удаётся проверить разработчика». На свежих macOS (Sequoia) старый трюк «правый клик → Открыть» больше не обходит запрет — нужно: **Системные настройки → Конфиденциальность и безопасность → пролистать вниз → «Всё равно открыть» → подтвердить**. Это разовый шаг, но он формально противоречит «ничего, кроме установки».

**Варианты:**
- **Идеал**: оформить **Apple Developer ($99/год)** → подпись Developer ID + нотаризация = ноль предупреждений, чистый «поставил и работает». План построен так, что это добавляется **без переписывания кода** — только переменные окружения в `sign.sh`/`notarize.sh`.
- **Пока без аккаунта**: ad-hoc подпись + в DMG кладём картинку-инструкцию «Как открыть» со скриншотами. Один разовый клик-данс.

**Рекомендация:** заложить нотаризацию в скрипты сразу (этап 8), а аккаунт оформить, когда будете готовы раздавать вживую. До тех пор — ad-hoc + инструкция.

---

## 3. Структура репозитория

```
scenedetector/
  Package.swift                # SwiftPM (executable target SceneShot)
  Sources/SceneShot/
    SceneShotApp.swift         # @main App
    ContentView.swift
    Models/
      Settings.swift           # @AppStorage параметры
      Source.swift             # enum file/remote
    Engine/
      FFmpeg.swift             # путь к бинарю + запуск Process (дренаж stdout+stderr)
      MediaProbe.swift         # ffprobe → длительность/разрешение
      SceneExtractor.swift     # сборка ffmpeg-команды, прогресс, тайминги
      Downloader.swift         # HEAD-проверка, скачивание по URL
    Views/                     # input zone, settings, progress, results
  Resources/
    Info.plist                 # копируется в Contents/Info.plist
    AppIcon.icns               # иконка приложения (.icns, без asset catalog)
    Helpers/arm64/{ffmpeg,ffprobe}
    Helpers/x86_64/{ffmpeg,ffprobe}
  Scripts/
    fetch-ffmpeg.sh            # скачать static-бинарники
    make-icon.sh               # AppIcon.icns из одного PNG (sips/iconutil)
    build.sh                   # swift build + ручная сборка .app → dist/SceneShot.app
    sign.sh                    # ad-hoc или Developer ID
    make-dmg.sh                # create-dmg
    notarize.sh                # задел под нотаризацию
    release.sh                 # build → sign → dmg → notarize
  dmg/
    background.png
    КАК-ОТКРЫТЬ.png            # инструкция обхода Gatekeeper
  README.md
  PLAN.md
```

---

## 4. Предусловия для разработчика (один раз, на машине сборки)

> Проверено на этой машине: только **Command Line Tools** (Swift 6.3, `swiftc`, `codesign`), brew, git; полного Xcode НЕТ. SwiftUI/AppKit/AVFoundation компилируются под CLT. Поэтому сборка — через **SwiftPM + ручная сборка `.app`** (без Xcode/XcodeGen/`xcodebuild`).

- **Xcode Command Line Tools** — даёт `swift`/`swiftc`/`codesign`. Полный Xcode НЕ нужен. (Если CLT нет: `xcode-select --install`.)
- Для DMG: `brew install create-dmg`.
- Позже, для нотаризации: аккаунт Apple Developer + Developer ID Application сертификат.

---

## 5. Этапы и промпты для агента

Промпты ниже самодостаточны — вставляйте по очереди в Claude Code (агента) в папке проекта. **Не переходите к следующему, пока не выполнен «Критерий приёмки» текущего.**

### Этап 1 — Скелет проекта
```
Создай нативное macOS-приложение на Swift + SwiftUI с именем SceneShot, собираемое из CLI ТОЛЬКО через Command Line Tools (полного Xcode на машине нет).
- SwiftPM: Package.swift с executableTarget "SceneShot" (platforms: .macOS(.v13)), исходники в Sources/SceneShot/. Для @main нужен флаг -parse-as-library (через swiftSettings unsafeFlags).
- Структура: Sources/SceneShot/ (SceneShotApp.swift, ContentView.swift, подпапки Models/Engine/Views), Resources/, Scripts/.
- SceneShotApp.swift — @main App с одним WindowGroup; ContentView — заглушка с заголовком и версией.
- Info.plist (хранится в Resources/Info.plist, build.sh копирует в Contents/Info.plist): CFBundleName SceneShot, CFBundleIdentifier com.example.sceneshot, CFBundleExecutable SceneShot, LSMinimumSystemVersion 13.0, NSHighResolutionCapable true, LSApplicationCategoryType public.app-category.utilities, NSPrincipalClass NSApplication, CFBundlePackageType APPL, NSAppTransportSecurity → NSAllowsArbitraryLoads=YES (для http-ссылок).
- Scripts/build.sh (set -euo pipefail, идемпотентный): `swift build -c release` (по возможности универсально: `--arch arm64 --arch x86_64`, при сбое — нативная арх), затем СОБРАТЬ бандл вручную: dist/SceneShot.app/Contents/{MacOS,Resources}, скопировать бинарь в MacOS/SceneShot (+x), Resources/Info.plist → Contents/Info.plist, при наличии — Resources/Helpers/* и AppIcon.icns; в конце ad-hoc подпись `codesign -s - --force --deep dist/SceneShot.app`.
- README с предусловиями: только Command Line Tools (`swift`), для DMG `brew install create-dmg`.
Критерий приёмки: ./Scripts/build.sh собирает dist/SceneShot.app; `file Contents/MacOS/SceneShot` — корректный Mach-O; `plutil -lint Contents/Info.plist` ок; `codesign --verify` проходит; (на машине с дисплеем `open` показывает окно); без ворнингов сборки.
```

### Этап 2 — Вшить ffmpeg/ffprobe + определение длительности
```
Вшей ffmpeg и ffprobe в бандл и сделай определение длительности/разрешения видео.
- Scripts/fetch-ffmpeg.sh: скачивает СТАТИЧЕСКИЕ ffmpeg и ffprobe под обе архитектуры в Resources/Helpers/arm64/ и Resources/Helpers/x86_64/. Источники задай переменными вверху скрипта (по умолчанию arm64 — osxexperts.net, x86_64 — evermeet.cx), ОДНОЙ И ТОЙ ЖЕ версии (зафиксируй версию), проверяй контрольные суммы, делай chmod +x. В шапке — комментарий про лицензию: предпочесть LGPL-сборку; нам нужны только декодеры + энкодеры mjpeg/png, x264/x265 НЕ нужны; если GPL — приложить LICENSE и письменное предложение исходников.
- build.sh: при сборке бандла копируй Resources/Helpers/<arch>/ в SceneShot.app/Contents/Resources/Helpers/<arch>/ (chmod +x ff*). Код читает их из Bundle.main.resourceURL.
- Sources/Engine/FFmpeg.swift: функция bundledTool(name) → путь к бинарю по текущей архитектуре (#if arch(arm64) → arm64, иначе x86_64). Утилита run(args, onStdoutLine, onStderrLine): запускает Process, ОДНОВРЕМЕННО дренирует stdout и stderr через Pipe.readabilityHandler на фоновых очередях (иначе дедлок на заполнении пайпа), поддерживает отмену (хранит Process, terminate()).
- Sources/Engine/MediaProbe.swift: ffprobe `-v error -print_format json -show_entries format=duration:stream=index,codec_type,codec_name,width,height,avg_frame_rate INPUT` → структура MediaInfo { durationSeconds, width, height, codec, fps }.
- Временный UI: кнопка «Выбрать видео» (NSOpenPanel, типы movie) → показать длительность ЧЧ:ММ:СС и разрешение.
Критерий приёмки: выбираю mp4 → корректная длительность и разрешение; работает на Apple Silicon и Intel.
```

### Этап 3 — Ввод: файл + drag&drop + ссылка
```
Сделай ввод видео двумя способами и единое состояние источника.
- Sources/Models/Source.swift: enum Source { case file(URL); case remote(URL) }.
- UI: зона с пунктирной рамкой — drag&drop видеофайла (onDrop, проверка UTType.movie/расширения) И кнопка «Выбрать видео…» (NSOpenPanel). Ниже — поле «или вставьте прямую ссылку на видео» (TextField) + кнопка «Загрузить по ссылке».
- Валидация ссылки: http/https и видео-расширение (.mp4/.mov/.webm/.mkv/.m4v) ИЛИ проверка из этапа 6; иначе подсветить ошибку «нужна прямая ссылка на видеофайл, а не страница сайта».
- При выборе источника заполняется @State source и показывается MediaInfo.
- Большая кнопка «Извлечь кадры» (пока заглушка), активна только когда source задан.
Критерий приёмки: и перетаскивание файла, и вставка ссылки заполняют состояние; невалидная ссылка даёт понятную ошибку.
```

### Этап 4 — Движок извлечения кадров (ядро)
```
Реализуй движок извлечения кадров на смене сцены.
- Sources/Engine/SceneExtractor.swift. Вход: source, выходная папка, параметры (threshold=0.30, формат jpg, качество=3, downscale=0, minInterval=0, maxFrames=0 — пока дефолты, панель в этапе 5).
- Сборка аргументов ffmpeg:
  * -hide_banner -nostats; для remote ПЕРЕД -i добавь -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5.
  * -i INPUT
  * -vf: строй аккуратно. ЗАПЯТЫЕ ВНУТРИ ВЫРАЖЕНИЙ экранируй как \,  (в Swift-строке это \\,). Базовый фильтр: "select=gt(scene\\,0.30),showinfo". Если downscale>0 — добавь ",scale=min(<maxw>\\,iw):-2" ПОСЛЕ select (масштабировать только отобранные кадры). showinfo — всегда в конце.
  * -fps_mode vfr
  * jpg: -q:v <2..31>;  png: без -q:v.
  * maxFrames>0: -frames:v N
  * -progress pipe:1
  * выход: <OUTDIR>/scene_%05d.<ext>
- Прогресс: парси stdout строки out_time=HH:MM:SS.micro → секунды / durationSeconds → 0..1; progress=end → готово.
- Тайминги кадров: из stderr showinfo парси "pts_time:<float>" по порядку → сопоставь i-му файлу; сохрани [(index, time)].
- Отмена: terminate(); опционально удалить недописанный последний кадр.
- Пустой результат: 0 кадров → статус «смены сцен не найдены — попробуйте выше чувствительность (ниже порог)».
- Подключи к кнопке: дефолтная папка ~/Movies/SceneShot/<имя_видео>-<таймстамп>/ (создать). По завершении — открыть папку в Finder (NSWorkspace.activateFileViewerSelecting).
Критерий приёмки: на ролике с явными склейками появляются кадры, прогресс движется, отмена останавливает ffmpeg, по готовности открывается Finder.
```

### Этап 5 — Панель «Полный контроль»
```
Добавь панель «Расширенные настройки» (DisclosureGroup, свёрнута по умолчанию) со здравыми дефолтами — можно не трогать.
Параметры в Sources/Models/Settings.swift (@AppStorage для запоминания):
- Порог/чувствительность: слайдер 0.05…0.9 (дефолт 0.30), подпись «ниже = больше кадров». Покажи пресеты Низкая/Средняя/Высокая = 0.45/0.30/0.18 И точное число.
- Мин. интервал между кадрами, сек (0 = выкл). Если >0 — в select добавь множитель: "*(isnan(prev_selected_t)+gte(t-prev_selected_t\\,<сек>))" (запятые экранированы).
- Формат: JPG / PNG (дефолт JPG).
- Качество JPG: слайдер 2..31 (дефолт 3, меньше = лучше).
- Downscale: макс. ширина px (0 = оригинал).
- Лимит кадров (0 = без лимита).
- Папка вывода: выбор директории (NSOpenPanel), дефолт ~/Movies/SceneShot/…, запоминать.
- Шаблон имени: токены {index},{time},{name} (дефолт "scene_{index}_{time}"). После извлечения переименуй файлы по шаблону, {time} из showinfo (секунды с 2 знаками или ЧЧ-ММ-СС).
Прокинь все значения в SceneExtractor.
Критерий приёмки: смена порога заметно меняет число кадров; PNG/JPG, downscale, лимит, имена, папка — применяются.
```

### Этап 6 — Надёжная работа со ссылками
```
Усиль обработку прямых ссылок.
- Sources/Engine/Downloader.swift:
  * Перед обработкой — HEAD-запрос (URLSession). Content-Type начинается с video/ или известный контейнер (mp4/mov/webm/mkv/m4v) → ок. text/html → ошибка «это похоже на страницу сайта, а не на прямую ссылку на видеофайл; YouTube и т.п. не поддерживаются».
  * Content-Length → показать размер, если есть.
  * Длительность для remote — ffprobe прямо по URL (для прогресса).
- Тумблер режима в расширенных настройках (дефолт «Стримить»):
  * «Стримить»: ffmpeg читает URL напрямую (как в этапе 4).
  * «Сначала скачать»: URLSession downloadTask с прогрессом во временную папку → обработка локального файла → удалить временный.
- Ошибки сети/таймауты — человеческие сообщения, без трейсбеков.
Критерий приёмки: прямой .mp4-URL → кадры; ссылка на HTML → понятная ошибка; режим «сначала скачать» работает с прогрессом.
```

### Этап 7 — Результат, ошибки, пустой результат
```
Доведи UX результата и ошибок.
- Экран результата: число найденных кадров, кнопки «Открыть папку» / «Показать в Finder», сетка превью (NSImage по первым N кадрам).
- Состояния: idle → probing → working(progress, ETA) → done(count) / cancelled / error(message) / empty.
- empty → кнопка «Повторить с большей чувствительностью» (снижает порог на шаг и перезапускает).
- Все ошибки — короткие человеческие тексты на русском с подсказкой; никаких stderr-дампов в лицо, но добавь сворачиваемый «Технический лог» для отладки.
- Блокируй кнопку запуска во время работы; показывай ETA из прогресса.
Критерий приёмки: сценарии done/empty/error/cancel понятны нетехническому человеку.
```

### Этап 8 — Упаковка и подпись (с заделом под нотаризацию)
```
Собери распространяемый DMG и оформи подпись.
- Scripts/sign.sh: подписывает ВСЕ вложенные бинарники (Helpers/*/ffmpeg, ffprobe), затем сам .app. Если задан env CODESIGN_IDENTITY (Developer ID) — подписывает им с --options runtime (hardened) и entitlements; иначе ad-hoc: codesign -s - --force --deep. Подписывай вложенные бинарники ПЕРЕД .app.
- Scripts/notarize.sh: если заданы APPLE_ID, TEAM_ID, APP_PASSWORD — `xcrun notarytool submit dist/SceneShot.dmg --wait` + `xcrun stapler staple`; иначе печатает «нотаризация пропущена (нет аккаунта Apple Developer)».
- Scripts/make-dmg.sh: через create-dmg делает dist/SceneShot.dmg с фоном dmg/background.png, симлинком на /Applications и стрелкой. В DMG положи dmg/КАК-ОТКРЫТЬ.png — инструкция обхода Gatekeeper (Системные настройки → Конфиденциальность и безопасность → «Всё равно открыть»).
- Scripts/release.sh: build.sh → sign.sh → make-dmg.sh → notarize.sh.
- README, раздел «Распространение»: честное предупреждение про Gatekeeper без нотаризации + инструкция для пользователя.
Критерий приёмки: ./Scripts/release.sh даёт dist/SceneShot.dmg; на чистой машине: открыть DMG → перетащить в «Программы» → (разово обойти Gatekeeper) → работает. С env-переменными нотаризации — открывается без предупреждений.
```

### Этап 9 — Иконка, имя, финальный чеклист
```
Финальная отделка.
- Scripts/make-icon.sh: из одного PNG через sips/iconutil собрать Resources/AppIcon.icns (build.sh копирует его в бандл; в Info.plist выставь CFBundleIconFile=AppIcon).
- Имя/версия/копирайт в Info.plist; экран «О программе».
- Русские подписи, аккуратные отступы, тёмная тема.
- Зафиксируй в README чеклист тестирования (см. §7 PLAN.md) и пройди его.
Критерий приёмки: приложение выглядит законченным, чеклист пройден.
```

---

## 6. Шпаргалка по ffmpeg (ядро логики)

**Длительность/метаданные:**
```
ffprobe -v error -print_format json \
  -show_entries format=duration:stream=index,codec_type,codec_name,width,height,avg_frame_rate \
  INPUT
```

**Детекция сцен + извлечение кадров** (аргументы передаём массивом в Process, БЕЗ шелл-кавычек; запятые внутри выражений экранируем `\,`):
```
ffmpeg -hide_banner -nostats \
  [-reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5]   # только для URL, перед -i
  -i INPUT \
  -vf "select=gt(scene\,0.30),showinfo"   # + ,scale=min(MAXW\,iw):-2 если downscale; showinfo в конце \
  -fps_mode vfr \
  -q:v 3 \                                  # только jpg
  -progress pipe:1 \
  OUTDIR/scene_%05d.jpg
```

- `scene` 0…1, выше = сильнее смена. Порог ниже → больше кадров.
- Мин. интервал: `select=gt(scene\,T)*(isnan(prev_selected_t)+gte(t-prev_selected_t\,SEC))` — `isnan(...)` пропускает первый кадр.
- Прогресс: stdout `out_time=HH:MM:SS.micro` → сек / duration; `progress=end` → конец.
- Тайминги: stderr showinfo `pts_time:<float>` по порядку.
- **Footgun:** запятые внутри `gt(...)`/`scale(...)` обязательно `\,`; в Swift-литерале — `\\,`. Запятая-разделитель фильтров (`select=...,showinfo`) остаётся без экранирования.
- Версию ffmpeg зафиксировать (7.x): флаг `-fps_mode vfr` есть с 5.1; на старых — `-vsync vfr`.

---

## 7. Чеклист тестирования

- [ ] Форматы: mp4 (H.264), mov, webm, mkv.
- [ ] Ориентация: горизонтальное и вертикальное видео (downscale `-2` держит чётную высоту).
- [ ] Длинное видео: корректный прогресс и ETA.
- [ ] Видео без склеек: ветка «смены не найдены» + «повторить с большей чувствительностью».
- [ ] Прямой URL: стрим и «сначала скачать».
- [ ] Ссылка на HTML-страницу: понятная ошибка.
- [ ] Нестабильный сервер: reconnect / переключение на «скачать».
- [ ] Отмена в середине: ffmpeg останавливается, UI чистый.
- [ ] Обе архитектуры: Apple Silicon и Intel.
- [ ] Повторный запуск: настройки запомнены (@AppStorage).
- [ ] Чистая машина: DMG → установка → запуск (с обходом Gatekeeper).

---

## 8. Риски и запасные ходы

- **Gatekeeper без нотаризации** — главный риск для «поставил и работает». Митигация: оформить $99-аккаунт; скрипты уже готовы (этап 8).
- **Источник/лицензия static ffmpeg** — зафиксировать версию и контрольные суммы; предпочесть LGPL-сборку (нам нужны лишь декодеры + mjpeg/png).
- **Различия флагов ffmpeg между версиями** (`-fps_mode` vs `-vsync`, `prev_selected_t`) — закрепить одну версию 7.x.
- **Только прямые ссылки** (без YouTube) — по ТЗ; закрыть понятным сообщением об ошибке.
- **Большие удалённые файлы / нестабильный стрим** — режим «сначала скачать».
- **Экранирование запятых в фильтрах** — самый частый баг; вынесено в шпаргалку (§6).
- **Полного Xcode на машине НЕТ** (только CLT) → сборка через **SwiftPM + ручная сборка `.app`** (НЕ XcodeGen/`xcodebuild`). Проверено: Swift 6.3, SwiftUI/AppKit/AVFoundation компилируются под CLT; минимальное SwiftUI-приложение линкуется `swiftc -parse-as-library -target arm64-apple-macosx13.0`.
