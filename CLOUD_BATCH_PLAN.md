# SceneShot — план: облачные ссылки (Dropbox → Google Drive) + папки с превью и мультивыбором

Дополнение к [PLAN.md](PLAN.md) (кадры) и плану транскрипции. Добавляем:
1. Работу со ссылками **Dropbox** и **Google Drive** (сначала Dropbox).
2. Для ссылки на **папку** — подгрузку **превью всех видео** и **выбор галочками**.
3. **Пакетную обработку** отмеченных видео: «Извлечь кадры» и/или «Транскрибировать», результат — в подпапке на каждое видео.

**Зафиксированные решения:**
- Доступ: **встроенный вход в 1 клик (OAuth, PKCE)** — ключи зарегистрированных приложений зашиты в SceneShot; маркетолог жмёт «Подключить» и разово авторизуется в браузере. Токены — в Keychain.
- Очерёдность: **Dropbox первым**, Google Drive — отдельным этапом (C6).
- Превью: **миниатюры из API** (Dropbox `get_thumbnail_v2` / Drive `thumbnailLink`); для локальных папок — QuickLook/ffmpeg-кадр.
- Пакет: глобальные переключатели «Извлечь кадры»/«Транскрибировать» применяются ко **всем отмеченным**; вывод — `<папка_вывода>/<имя_видео>/`; **локальные папки тоже** поддерживаются.
- Интеграция: новая вкладка **«Папка»** (локальная папка ИЛИ облачная ссылка → грид → мультивыбор → пакет). Одиночные облачные **файл-ссылки** также работают во вкладках «Кадры»/«Транскрипция».
- Стек без изменений: SwiftUI, сборка `swiftc`+`lipo` (без Xcode), не sandbox, без внешних зависимостей — только системные `AuthenticationServices` (OAuth), `Security` (Keychain), `Foundation`/`URLSession`, `QuickLookThumbnailing`.

---

## 0. Что увидит маркетолог (UX)

1. Вкладка **«Папка»** → вставляет ссылку на папку Dropbox (или жмёт «Выбрать локальную папку»).
2. Первый раз для облака: **«Подключить Dropbox»** → браузер → «Разрешить» → возврат в приложение (статус «Подключено»).
3. Видит **сетку превью** всех видео из папки с **галочками**; отмечает нужные (есть «Выбрать все»).
4. Включает **«Извлечь кадры»** и/или **«Транскрибировать»** → жмёт **«Обработать выбранные (N)»**.
5. Идёт прогресс по каждому видео; по готовности — папка с результатами: `…/<имя_видео>/` (кадры и/или `transcript.txt`/`.srt`).

---

## 1. Архитектура и переиспользование

- **OAuthManager** — общий PKCE-флоу через `ASWebAuthenticationSession` (нативно, без зависимостей) + хранение токенов в Keychain (`Security`).
- **DropboxClient** — `list_folder` (по shared_link, с пагинацией), `get_thumbnail_v2`, скачивание файла; (позже **GoogleDriveClient** — `files.list`, `thumbnailLink`, `alt=media`).
- **CloudModels** — `CloudProvider` (dropbox/gdrive), `CloudItem` (id/имя/размер/путь/thumbURL), `CloudFolder`.
- **Source** (существующий `enum file/remote`) — расширяем кейсом `cloudFile(provider, ref)` ИЛИ резолвим облачный файл в локальный temp и подаём как `.file` (проще; см. C2).
- **BatchProcessor** — очередь выбранных элементов; на каждый: (скачать при необходимости) → `SceneExtractor` (если кадры) и/или `WhisperEngine` (если транскрипция) → подпапка. Переиспользует существующие движки и `Downloader`.
- **UI**: вкладка **FolderBatchView** + **ThumbGridView** (сетка с превью и чекбоксами). Встраивается в верхний переключатель вкладок («Кадры»/«Транскрипция»/«Папка»), который вводит план транскрипции.
- Всё реактивно через `@AppStorage`/`@State`, ошибки — короткие русские тексты, тех-лог сворачиваемый (как в существующем коде).

## 2. Дополнения к структуре репозитория

```
Sources/SceneShot/
  Cloud/
    OAuthManager.swift        # PKCE + ASWebAuthenticationSession + Keychain
    Keychain.swift            # тонкая обёртка над Security
    CloudModels.swift         # CloudProvider, CloudItem, CloudFolder, CloudError
    DropboxClient.swift       # list_folder / get_thumbnail_v2 / download
    GoogleDriveClient.swift   # (этап C6)
    Secrets.swift             # DROPBOX_APP_KEY и т.п. (плейсхолдеры; см. ниже)
  Engine/
    BatchProcessor.swift      # очередь: кадры и/или транскрипция на видео
  Views/
    FolderBatchView.swift     # вкладка «Папка»
    ThumbGridView.swift       # сетка превью + чекбоксы
Resources/Info.plist          # + CFBundleURLTypes (схема sceneshot://)
```

> **Про Secrets.swift и безопасность:** для **desktop/native** клиента используется **PKCE без client secret** — встраивать `client secret` НЕЛЬЗЯ, а `app key` (публичный идентификатор) встраивать нормально. `Secrets.swift` коммитим с плейсхолдером, реальные ключи — через сборку/локально. Токены пользователя — только в Keychain.

## 3. Предусловия для разработчика (один раз)

- **Dropbox App Console** → создать приложение (scoped, «App folder» или «Full Dropbox» по необходимости), включить **PKCE**, добавить redirect URI `sceneshot://oauth`, выдать scopes: `files.metadata.read`, `files.content.read`, `sharing.read`. Скопировать **App key** в `Secrets.swift`.
- **(этап C6) Google Cloud** → проект, включить **Drive API**, создать **OAuth client (Desktop/iOS)**, scope `drive.readonly`, redirect `sceneshot://oauth`; на время — **режим «Тестирование»** + список тест-пользователей (без долгой верификации Google).
- Зарегистрировать URL-схему `sceneshot` в `Info.plist` (этап C1).

---

## 4. Этапы и промпты

> Промпты самодостаточны — вставлять по очереди агенту. Не переходить дальше до выполнения «Критерия приёмки». Все этапы опираются на существующий код (FFmpeg.swift, SceneExtractor.swift, WhisperEngine.swift, Downloader.swift, ContentView/вкладки) и конвенции PLAN.md.

### Этап C1 — OAuth «Подключить Dropbox» (1 клик)
```
Добавь вход в Dropbox по OAuth 2.0 + PKCE без внешних зависимостей.
- Info.plist: добавь CFBundleURLTypes со схемой "sceneshot" (CFBundleURLName com.example.sceneshot, CFBundleURLSchemes ["sceneshot"]).
- Sources/SceneShot/Cloud/Keychain.swift: обёртка над Security (SecItemAdd/Copy/Update/Delete) — set(token, account)/get(account)/delete(account). Хранить в kSecClassGenericPassword, сервис "com.example.sceneshot.tokens".
- Sources/SceneShot/Cloud/Secrets.swift: enum Secrets { static let dropboxAppKey = "<APP_KEY>" } (плейсхолдер; НЕ хранить client secret — у нас PKCE public client).
- Sources/SceneShot/Cloud/OAuthManager.swift:
  * PKCE: code_verifier = 64 случайных байт base64url; code_challenge = base64url(SHA256(verifier)) (CryptoKit).
  * authorize URL: https://www.dropbox.com/oauth2/authorize?client_id=<key>&response_type=code&code_challenge=<ch>&code_challenge_method=S256&redirect_uri=sceneshot://oauth&token_access_type=offline&scope=files.metadata.read%20files.content.read%20sharing.read
  * Открой через ASWebAuthenticationSession(url:, callbackURLScheme:"sceneshot"); из callback-URL достань ?code=.
  * Обмен кода: POST https://api.dropboxapi.com/oauth2/token (x-www-form-urlencoded): grant_type=authorization_code, code, code_verifier, client_id, redirect_uri → access_token, refresh_token, expires_in. Сохрани refresh_token (+ access_token + expiry) в Keychain.
  * Обновление: POST .../oauth2/token grant_type=refresh_token, refresh_token, client_id → новый access_token. validAccessToken() async → возвращает свежий токен (рефрешит при истечении).
  * Состояние: isConnected (есть refresh_token), disconnect() (revoke + чистка Keychain).
- UI: в настройках/во вкладке «Папка» кнопка «Подключить Dropbox» / «Отключить» + статус «Подключено как …» (опц.: /2/users/get_current_account).
Критерий приёмки: клик «Подключить» → браузер → «Разрешить» → возврат в приложение → токен в Keychain → статус «Подключено»; после перезапуска приложение остаётся подключённым (refresh работает); «Отключить» очищает токен.
```

### Этап C2 — Dropbox: одиночные файл-ссылки во вкладках «Кадры»/«Транскрипция»
```
Научи существующий ввод принимать ссылки Dropbox на ОДИН файл.
- Определение типа ссылки Dropbox по URL: папка — содержит "/scl/fo/" или "/sh/"; файл — "/scl/fi/" или "/s/". (Вынеси в CloudLink.detect(url) → .dropboxFile/.dropboxFolder/.unknown.)
- Для ФАЙЛ-ссылки: получить локальный temp через POST https://content.dropboxapi.com/2/sharing/get_shared_link_file (Authorization: Bearer <token>, Dropbox-API-Arg: {"url":"<share_url>"}) → тело файла во временный файл; ИЛИ как fallback без токена — преобразовать в прямую загрузку (заменить dl=0 на dl=1) и отдать существующему Downloader.
- Интеграция: в ContentView/вводе, если это Dropbox файл-ссылка — резолвим в .file(tempURL) и дальше существующий путь (MediaProbe → Кадры/Транскрипция). Если приватная и нет токена → понятная ошибка «Подключите Dropbox, чтобы открыть приватную ссылку».
- Чистка temp после обработки.
Критерий приёмки: ссылка Dropbox на видеофайл (публичная и приватная-при-подключении) обрабатывается и во вкладке «Кадры», и во вкладке «Транскрипция».
```

### Этап C3 — Dropbox: листинг папки + миниатюры
```
Реализуй чтение содержимого папки Dropbox по shared-ссылке и превью.
- Sources/SceneShot/Cloud/CloudModels.swift: CloudProvider; CloudItem { id, name, sizeBytes, pathLower, isVideo }; CloudFolder { provider, items }.
- Sources/SceneShot/Cloud/DropboxClient.swift:
  * listFolder(sharedLink) async: POST https://api.dropboxapi.com/2/files/list_folder { "path":"", "shared_link":{"url":"<folder_url>"} }. Пагинация: пока has_more — POST /2/files/list_folder/continue { cursor }. Собери entries (.tag=="file"), фильтр по видео-расширениям (mp4/mov/m4v/webm/mkv/avi). Верни [CloudItem] (path_lower → pathLower).
  * thumbnail(for: item, sharedLink) async -> NSImage?: POST https://content.dropboxapi.com/2/files/get_thumbnail_v2, Dropbox-API-Arg: {"resource":{".tag":"shared_link","url":"<folder_url>","path":"<item.pathLower относительно папки>"},"format":"jpeg","size":"w256h256","mode":"fitone_bestfit"} → image bytes. Если для формата миниатюры нет — верни nil (грид покажет заглушку).
  * Все запросы с Authorization: Bearer <validAccessToken()>; обработка 401 (рефреш/переподключение), 429 (Retry-After), сетевых ошибок — типизированные CloudError с русскими сообщениями.
Критерий приёмки: вставляю ссылку на папку Dropbox с несколькими видео → получаю список всех видео; для большинства — миниатюры; пагинация и ошибки обрабатываются (проверить на реальной shared-папке).
```

### Этап C4 — Вкладка «Папка»: грид превью + галочки
```
Добавь вкладку «Папка» с сеткой превью и мультивыбором (локальные + облачные папки).
- RootView: добавь третью вкладку «Папка» рядом с «Кадры»/«Транскрипция» (тот же верхний переключатель).
- Sources/SceneShot/Views/FolderBatchView.swift:
  * Ввод: кнопка «Выбрать локальную папку…» (NSOpenPanel, canChooseDirectories) ИЛИ поле «ссылка на папку Dropbox» (+ «Подключить Dropbox», если не подключён).
  * Локальная папка: перечисли видеофайлы (FileManager), превью через QuickLookThumbnailing (QLThumbnailGenerator) или кадр вшитым ffmpeg (-ss 1 -frames:v 1 в temp jpeg).
  * Облачная папка: DropboxClient.listFolder + thumbnail (этап C3).
  * Sources/SceneShot/Views/ThumbGridView.swift: LazyVGrid с карточками (превью + имя + чекбокс). Состояние выбора — Set<id>. «Выбрать все»/«Снять все», счётчик «Выбрано N из M». Асинхронная подгрузка превью (плейсхолдер пока грузится), кеш по id.
  * Глобальные переключатели «Извлечь кадры» / «Транскрибировать» (@AppStorage; хотя бы один обязателен). Кнопка «Обработать выбранные (N)» активна при N≥1 и хотя бы одном включённом действии.
Критерий приёмки: и для папки Dropbox, и для локальной папки появляется сетка превью с чекбоксами; «Выбрать все», счётчик и переключатели работают; кнопка запуска корректно активируется.
```

### Этап C5 — Пакетный движок (кадры и/или транскрипция)
```
Реализуй пакетную обработку отмеченных видео.
- Sources/SceneShot/Engine/BatchProcessor.swift:
  * Вход: [выбранные элементы] (локальные URL или CloudItem+sharedLink), флаги doFrames/doTranscribe, параметры кадров/транскрипции (из существующих настроек), базовая папка вывода.
  * Последовательно (или с ограниченной конкуренцией, по умолчанию 1) по каждому элементу:
      1) если облачный — скачать во временный файл (get_shared_link_file / Downloader) с прогрессом этого элемента;
      2) создать подпапку <out>/<имя_видео>/;
      3) если doFrames — SceneExtractor → подпапка frames/ (или прямо в подпапку);
      4) если doTranscribe — извлечь 16k wav (ffmpeg) → WhisperEngine → transcript.txt/.srt в подпапке;
      5) удалить temp.
  * Прогресс: общий i/N + прогресс текущего элемента; ETA. Отмена: останавливает текущий процесс и очередь. ИЗОЛЯЦИЯ ОШИБОК: падение одного видео не прерывает остальные — копим [ошибки], продолжаем. Итог: «Готово: N, ошибок: M» + список проблемных.
- UI (FolderBatchView): во время пакета — список элементов со статусами (ожидание/идёт/готово/ошибка), общий прогресс, «Отменить»; по завершении — сводка и «Открыть папку вывода».
Критерий приёмки: пакет из нескольких выбранных видео создаёт по подпапке на каждое (кадры и/или transcript по флагам); отмена останавливает; ошибка одного элемента не рушит остальные; сводка верна.
```

### Этап C6 — Google Drive (второй сервис)
```
Добавь Google Drive по той же модели, что и Dropbox.
- OAuth: переиспользуй OAuthManager (PKCE), provider=.gdrive: authorize https://accounts.google.com/o/oauth2/v2/auth?client_id=<id>&response_type=code&redirect_uri=sceneshot://oauth&scope=https://www.googleapis.com/auth/drive.readonly&code_challenge=...&code_challenge_method=S256&access_type=offline&prompt=consent ; обмен на https://oauth2.googleapis.com/token. Токены — в Keychain (отдельный account "gdrive").
- Определение типа ссылки: папка — "/drive/folders/<ID>"; файл — "/file/d/<ID>". Достань ID регуляркой.
- GoogleDriveClient:
  * listFolder(id): GET https://www.googleapis.com/drive/v3/files?q='<ID>'+in+parents+and+mimeType+contains+'video/'&fields=files(id,name,size,thumbnailLink,mimeType)&pageSize=1000 (+ pageToken). Авторизация Bearer.
  * thumbnail: грузим по thumbnailLink (с токеном). 
  * download(fileId): GET https://www.googleapis.com/drive/v3/files/<ID>?alt=media (Bearer) → temp; для больших файлов с антивирус-интерстишелом обработай confirm-token.
- Встрой в ThumbGridView/BatchProcessor и в одиночные файл-ссылки (вкладки «Кадры»/«Транскрипция»), как Dropbox.
Критерий приёмки: ссылка на папку Google Drive даёт сетку видео с превью и пакетится как Dropbox; файл-ссылка Drive работает во вкладках «Кадры»/«Транскрипция».
```

### Этап C7 — Безопасность, упаковка, edge-cases, тесты
```
Доведи до релиза.
- Info.plist: CFBundleURLTypes (схема sceneshot) — проверь, что callback ловится.
- Keychain: не sandbox → системный login keychain работает без доп. entitlements (если позже включите sandbox — добавьте keychain-access-groups и com.apple.security.network.client). Зафиксируй в README.
- Secrets: PKCE public client — app key встроить можно, client secret НЕЛЬЗЯ. Проверь, что секретов в репозитории нет.
- Надёжность API: пагинация, 429 + Retry-After с бэк-оффом, 401 → авто-рефреш → при провале «Переподключите аккаунт», офлайн/таймаут — человеческие русские сообщения, тех-лог сворачиваемый.
- Большие папки: ленивая подгрузка превью (видимые ячейки), отмена скачивания.
- README/PLAN: разделы про подключение Dropbox/Drive и пакетный режим; обнови release-чеклист.
- Тест-чеклист: реальная shared-папка Dropbox (смешанные файлы, видео разных форматов); приватная vs публичная ссылка; большая папка (пагинация); отмена в середине пакета; изоляция ошибки одного видео; обе архитектуры; сохранение токенов после перезапуска; повторная авторизация после отзыва токена.
Критерий приёмки: сквозной прогон по реальной папке Dropbox (выбор галочками → кадры+транскрипция → подпапки на видео); токены переживают перезапуск; ошибки человеческие; ./Scripts/release.sh по-прежнему даёт валидный подписанный универсальный DMG.
```

---

## 5. Шпаргалка по API

**Dropbox — листинг папки по shared-ссылке:**
```
POST https://api.dropboxapi.com/2/files/list_folder
Authorization: Bearer <token>
{ "path": "", "shared_link": { "url": "<folder_share_url>" } }
# далее: /2/files/list_folder/continue { "cursor": "<cursor>" } пока has_more
```
**Dropbox — миниатюра видео:**
```
POST https://content.dropboxapi.com/2/files/get_thumbnail_v2
Dropbox-API-Arg: {"resource":{".tag":"shared_link","url":"<folder_url>","path":"<rel_path>"},
                  "format":"jpeg","size":"w256h256","mode":"fitone_bestfit"}
```
**Dropbox — скачать файл по shared-ссылке:**
```
POST https://content.dropboxapi.com/2/sharing/get_shared_link_file
Dropbox-API-Arg: {"url":"<file_share_url>"}    # или {"url":"<folder_url>","path":"<rel_path>"}
```
**OAuth (PKCE):** authorize → ASWebAuthenticationSession (callbackScheme "sceneshot") → code → POST oauth2/token (grant_type=authorization_code, code_verifier) → refresh_token; обновление grant_type=refresh_token.

**Google Drive (C6):** `files.list?q='<folderId>' in parents and mimeType contains 'video/'` ; `thumbnailLink` ; `files/<id>?alt=media`.

---

## 6. Риски и запасные ходы

- **Google OAuth-верификация** для `drive.readonly` в проде — обход: режим «Тестирование» + тест-пользователи (узкий круг). Полная верификация — позже, если нужно публично.
- **Миниатюры Dropbox** есть не для всех видеоформатов → fallback: кадр вшитым ffmpeg (скачать начало файла).
- **Лимиты/пагинация** больших папок → бэк-офф по 429, ленивая загрузка превью.
- **Хранение токенов** → только Keychain; в логи/файлы не писать.
- **ASWebAuthenticationSession** требует активного GUI-приложения (у нас так и есть) и схемы в Info.plist.
- **Размер вывода пакета** — много видео × (кадры+транскрипт) → предупреждать и складывать аккуратно по подпапкам.

---

## 7. Чеклист тестирования

- [ ] Подключение Dropbox в 1 клик; токен переживает перезапуск; «Отключить» чистит.
- [ ] Dropbox файл-ссылка (публичная и приватная) → «Кадры» и «Транскрипция».
- [ ] Dropbox папка-ссылка → сетка превью всех видео.
- [ ] Галочки/«Выбрать все»/счётчик; обязателен ≥1 выбор и ≥1 действие.
- [ ] Пакет «только кадры», «только транскрипция», «и то и то».
- [ ] Подпапка на каждое видео; сводка «готово/ошибок».
- [ ] Отмена в середине пакета; изоляция ошибки одного видео.
- [ ] Локальная папка → тот же грид/пакет (превью QuickLook/ffmpeg).
- [ ] (C6) Google Drive папка и файл.
- [ ] Большая папка (пагинация), 429/таймаут/офлайн — человеческие ошибки.
- [ ] Обе архитектуры; release.sh → валидный подписанный DMG.
