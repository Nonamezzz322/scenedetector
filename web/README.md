# SceneShot Web

Веб-аналог десктопного SceneShot — **полностью в браузере, без сервера**. Извлекает кадры
на смене сцены из видео и (по желанию) распознаёт речь в текст/субтитры. Подходит для хостинга
на **GitHub Pages**: это статичные файлы, ничего собирать не нужно.

> Ни видео, ни кадры, ни текст никуда не загружаются — вся обработка идёт на вашем компьютере
> средствами браузера.

## Что умеет

- **Видео** — перетащите файл (или выберите), включите «Извлечь кадры» и/или «Транскрибировать».
  - **Кадры**: браузерный аналог ffmpeg-детектора сцен. Тот же набор настроек и пост-обработки,
    что в десктопе: чувствительность, пауза после перехода (settle), отбраковка пустых кадров,
    дедуп похожих сцен (перцептивный хеш), макс. ширина/кол-во, шаблон имени, склейка в одну
    картинку. После анализа вы **выбираете нужные кадры кликами** (в порядке клика) и сохраняете.
  - **Транскрипция**: Whisper (модель `base`) прямо в браузере через
    [transformers.js](https://huggingface.co/docs/transformers.js) (WebGPU/CPU). Выдаёт TXT и SRT.
    **Без перевода на украинский** (этот шаг убран). Языки: Авто / Русский / Украинский / English.
- **Папка** — выберите **локальную папку** с видео, отметьте нужные и обработайте пакетно. Затем
  для каждого видео выберите кадры и сохраните. **Без Google Drive и Dropbox** — только локально.

## Чем отличается от десктопа

| Десктоп (macOS) | Веб |
|---|---|
| ffmpeg (`select=gt(scene,…)`) | `<video>` + `<canvas>`: тот же алгоритм/настройки, метрика разницы кадров |
| whisper.cpp (локальный бинарь) | transformers.js (Whisper в браузере, WebGPU/WASM) |
| Перевод транскрипта на украинский | **убран** |
| Google Drive / Dropbox / yt-dlp (ссылки) | **убраны** (нужен сервер — на статике невозможно) |
| Сохранение в `~/Movies/SceneShot/…` | Запись в выбранную папку (Chrome/Edge) или скачивание **ZIP** |

## Поддержка браузеров

- **Лучше всего: Chrome / Edge** (есть File System Access API — результат пишется прямо в выбранную
  папку; есть WebGPU — быстрая транскрипция).
- **Safari / Firefox**: кадры и транскрипция работают; результат **скачивается ZIP-архивом** (запись
  в произвольную папку этими браузерами не поддерживается). Транскрипция идёт на CPU (медленнее).
- Видео декодируется средствами браузера — лучше всего **MP4 (H.264)** / WebM. Экзотические кодеки
  (часть HEVC/MOV) могут не открыться — тогда покажется подсказка.

## Запуск локально

ES-модули не грузятся с `file://` — нужен локальный сервер:

```sh
cd web
python3 -m http.server 8000
# открыть http://localhost:8000
```

(или любой статичный сервер: `npx serve`, `php -S localhost:8000`, расширение Live Server и т.п.)

## Деплой на GitHub Pages

Сайт лежит в папке `web/` и использует **относительные пути**, поэтому работает и из подпапки
`https://<user>.github.io/<repo>/`.

### Вариант A — GitHub Actions (рекомендуется)

В репозитории уже есть workflow [`.github/workflows/deploy-pages.yml`](../.github/workflows/deploy-pages.yml).

1. Запушьте репозиторий на GitHub (`git init && git add . && git commit -m "web" && git push`).
2. **Settings → Pages → Build and deployment → Source = "GitHub Actions"**.
3. Любой push в `main`/`master` (с изменениями в `web/`) публикует сайт. Адрес появится во вкладке
   **Actions** / **Settings → Pages**: `https://<user>.github.io/<repo>/`.

### Вариант B — без Actions (ветка/папка)

Если удобнее «Deploy from a branch»: скопируйте содержимое `web/` в папку `docs/` в корне репозитория,
затем **Settings → Pages → Source = Deploy from a branch → main / `/docs`**.

> Файл `web/.nojekyll` уже есть — он отключает обработку Jekyll, чтобы файлы отдавались как есть.

## Зависимости (с CDN, ничего ставить не надо)

- [`@huggingface/transformers`](https://www.npmjs.com/package/@huggingface/transformers) — Whisper в браузере (грузится лениво при первой транскрипции).
- [`jszip`](https://www.npmjs.com/package/jszip) — ZIP-архив результата (когда запись в папку недоступна).

Модель Whisper (~80 МБ) скачивается один раз с `huggingface.co` и кешируется браузером — дальше
транскрипция работает офлайн.

## Структура

```
web/
  index.html            — оболочка (вкладки, настройки)
  styles.css            — оформление (светлая/тёмная тема)
  .nojekyll             — отключает Jekyll на GitHub Pages
  app/
    main.js             — бутстрап: вкладки, настройки, i18n
    i18n.js             — переводы (ru/uk/en, по умолчанию ru)
    settings.js         — настройки (localStorage)
    scene/              — детектор сцен (порт ffmpeg-логики)
      frameSampler.js   — покадровый сэмплинг видео + state-machine захвата
      sceneEngine.js    — пост-обработка: detail-отбраковка, дедуп, лимит, кодирование
      sceneMetric.js    — метрика смены сцены (аналог ffmpeg scene)
      detail.js / dhash.js / dedup.js / stitch.js / filename.js / encode.js
    transcribe/         — whisper.js (transformers.js) + srt.js
    io/                 — localFolder.js (File System Access) / save.js (ZIP) / output.js
    ui/                 — videoTab.js / folderTab.js / settingsPanel.js / frameGrid.js / thumbnail.js / dom.js
```
