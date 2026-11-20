# General update 0.4.2 · build 15

Current authoritative source: this directory. Installation is not performed automatically.

- One Models screen: repository search and variants on the left, downloaded library on the right, download controls below. Repository pipeline tags describe purpose when provided; unknown purpose is explicit. GGUF format is not a guarantee of architecture/tool compatibility; engine loading is the final check.
- System-language Russian/English UI (other languages fall back to English), lowercase `inij` author, no message editing button. Right-click Quote/Copy use the selected fragment, otherwise the complete original message.
- File tools use project scope. Shell commands now use macOS Seatbelt filesystem containment; network follows the application mode. MCP runs with a sanitized environment, project + explicit roots, and a separate network grant. Unsupported sandbox hosts fail closed. Runtime/system libraries are read-only exceptions, not grants to the user's home.
- `run_command` with `outsideSandbox: true` and a nonempty `reason` always asks for a single-use approval of the exact command. Persistent tool/all grants cannot approve or persist this escalation. Offline network denial remains in force even for an escalated action.
- Skill folder catalogs discover SKILL.md through three directory levels, exclude symlinks, refresh before context construction and with Refresh catalog. Name keywords or frontmatter `triggers: spreadsheet, таблица` auto-activate; manual toggles also work. Activation does not grant execution rights. Removed skills are not silently re-added.
- Requested context budget, GGUF-declared model window and optional configured server limit are distinct. Effective local window uses the declared cap. KV-cache memory is not guessed; successful engine load is required. No universal 128K cap.
- `diagnose_app` and Settings → Advanced → Diagnostics expose actual OS/app paths, model/header checks, engines, resources, sensors, MCP/skills and bounded redacted logs. Provider connection checks are read-only, bounded to three seconds and constrained by current mode. Diagnostics do not change settings or start arbitrary MCP processes.
- Image failures preserve exit code and bounded diagnostic output, with last execution details available to diagnostics. The original user's particular checkpoint failure cannot be diagnosed retroactively without its log. Known SD fixture generation is verified separately.
- Traffic is external model API payload bytes, not all network traffic. It remains unavailable before a successful external request; missing sensor and token readings are not invented. Physical M4 Max sensor availability is not established by VM checks.

Search provider live verification: Brave tested using the existing host key. Tavily/Serper retain mock coverage; no live keys available on the host. No claims about those live services.

Build: `bash scripts/build-039.sh` on the configured Apple Silicon VM. It runs backend, native UI/document/image, signature and final read-only DMG/temporary installed-copy LaunchServices checks. It no longer copies to the user's Desktop or replaces their installed app. Additional language check: `python -I -B scripts/verify_native.py build/Inij.app build/native-en.json --skip-keychain --language en`.

The historical sections below describe earlier releases and are superseded by this section where they differ (notably shell/MCP isolation, editing, paths and localization).

# Inij для macOS

SwiftUI-приложение для Apple Silicon Mac с собственным окном и значком в Dock, локальным сервисом внутри `.app`, сохранением данных и встроенным браузером.

## Выпуск 0.3 · самостоятельные GGUF

Выбери «Настройки → Встроенная модель → Обзор…» и файл `.gguf`: приложение запускает встроенный llama.cpp с Metal. Отдельные LM Studio/Ollama не нужны. Модель не входит в установщик; её можно выбрать с диска или скачать через Explore (Hugging Face). Поддержка конкретной архитектуры определяется встроенным движком, а не расширением файла.

Explore показывает варианты и размеры, скачивает с паузой/продолжением/отменой, проверяет SHA256 из Hugging Face и добавляет результат в библиотеку. Оценка запаса RAM ориентировочная: размер весов не учитывает KV-кэш и другие расходы. Разделённые GGUF из Explore пока явно отклоняются; их полный комплект можно выбрать через «Обзор…».

Темы — тёмная и светлая монохромные; переключатель в настройках. Основное окно имеет минимум 900×650; с браузером минимум 1180×650. Имя активной модели доступно в подсказке значка CPU рядом с полем ввода. Кнопки «Сохранить» и «Сохранить и закрыть» сохраняют также системный промпт.

Установка: открыть `Inij-0.3.3-arm64.dmg`, перенести приложение в «Программы» и открыть. Python и llama.cpp находятся внутри `.app`. Публикуемая сборка подписана ad-hoc и не нотарифицирована Apple, поэтому macOS может потребовать ручное разрешение запуска в «Конфиденциальность и безопасность».

Модели, их частичные загрузки и runtime log не включаются в ZIP-бэкап чатов. При переносе на другой Mac модели выбираются/скачиваются отдельно.

CI обязан пройти backend-тесты, настоящий GGUF inference/tool-call smoke, нативные проверки и codesign до/после запуска, затем проверку установленной копии из финального DMG. Итог и ограничения фиксируются в COMPLETION.md.

## Реализованные пути

- Потоковый чат встроенного GGUF, а также опциональных Ollama и OpenAI-совместимого API; остановка, сохранение истории, повтор ответа, редактирование сообщения с пересозданием дальнейшей ветки. Предыдущая история архивируется.
- Изолированные проекты, память, выбор рабочей папки, импорт папок `SKILL.md` и включение скилла для чата. Проверка зависимостей — эвристическая, не доказательство совместимости.
- Профили системного промпта, история до 100 версий и восстановление прежней версии. Просмотр полного отправляемого контекста и приблизительной оценки объема.
- Видимый WKWebView с отдельным профилем приложения. Открытие, чтение, перечень элементов, клики и заполнение непарольных полей. Клики и заполнение требуют подтверждения пользователя; устаревшие ссылки на элементы отвергаются. Вход, капчу и секретные поля пользователь заполняет сам.
- Поиск Brave, Tavily и Serper; ключи в macOS Keychain. Ключи не записываются в состояние и не экспортируются. Живые запросы провайдеров без пользовательских ключей не проверялись.
- MCP stdio: регистрация локального исполняемого файла и аргументов, инициализация, `tools/list`, `tools/call`. Каждый запуск/вызов требует подтверждения. Сервер получает права пользователя, не является sandbox. Обратные sampling/elicitation-вызовы не разрешаются. HTTP MCP и ключи окружения серверов пока не поддержаны.
- Чтение, буквальный поиск и запись файлов в выбранной папке, команды с подтверждением, ограничением времени и остановкой процесса. Запись сохраняет прежний файл.
- Вложения TXT/CSV/JSON/MD, DOCX/XLSX/PPTX, текстовый PDF, OCR изображений и сканированных PDF. Добавление скрепкой (несколько файлов) или перетаскиванием в поле ввода; отдельные удаляемые карточки не заполняют поле вопроса текстом файла. Лимиты актуального импорта — в разделе 0.3.9 ниже.
- Инструмент `create_document`: заполнение текстовых меток `{{name}}` в DOCX/XLSX-шаблоне внутри рабочей папки, отдельный выходной файл, подтверждение. Метки должны находиться целиком в одном текстовом узле; разделенные форматированием метки дают ошибку, а не неполный результат. Это не произвольный визуальный редактор Word/Excel.
- Автосохранение, экспорт ZIP, восстановление ZIP с проверкой путей, симлинков и распакованного объема. Перед восстановлением сохраняются ZIP и предыдущая папка данных. Внешние рабочие папки отвязываются, импортированные MCP-серверы выключаются.
- Явные режимы: только локально / локальная модель с интернетом / облачная модель. Автоматического перехода в облако нет. В offline отключены браузер, поисковые API, команды и MCP.

## Оставшиеся ограничения

- Native bundle, Dock/reopen, WebKit and OCR are covered by macOS smoke tests. Login Keychain, physical temperature sensors and downloaded-quarantine behavior require separate environment-specific verification.
- Release gate проверяет настоящий Qwen3-0.6B GGUF и принудительный вызов инструмента. Это не доказывает поддержку всех моделей. Живые поисковые ключи и сторонние MCP здесь не проверяются.
- Поиск по файлам буквальный, не семантический RAG. Визуальный ввод изображения в LLM не подключен: изображения проходят OCR.
- Оценка контекста — UTF-8 байты / 4, не токенизатор модели. Сводка создает новый чат и требует свободного контекста.
- Локальные MCP stdio поддержаны, удаленный HTTP MCP — нет. Произвольные API кроме перечисленных подключаются только через написанный для них MCP stdio-сервер.
- Без подписи Developer ID / нотарификации возможна системная блокировка запуска скачанного приложения. Ключи подписи в проект не включены.
- Диктовка, озвучка, расписания, управление экраном и субагенты не входят в согласованную первую версию.

## Сборка выпуска — для разработчика, не для пользователя

На Apple Silicon Mac с Xcode Command Line Tools:

```bash
bash scripts/build-app.sh
```

Сборщик скачивает фиксированный Python 3.12.16 ARM64 из `astral-sh/python-build-standalone`, проверяет SHA256, вкладывает его в `.app`, запускает тесты, собирает Swift, генерирует `.icns`, подписывает вложенные Mach-O и приложение, проверяет bundle и запуск локального сервиса, создает DMG со ссылкой на Applications.

Переменная `SIGNING_IDENTITY` включает Developer ID подпись. `NOTARY_PROFILE` — имя уже настроенного профиля Keychain для `notarytool`. Секреты в файлы проекта не помещаются. Без них сборка ad-hoc и не нотарифицируется Apple. CI собирает и проверяет артефакт, но публикация выпуска выполняется отдельно.

Дальше обязателен `MAC-ACCEPTANCE.md`. Только после успешной сборки и приемки `.dmg` можно отправлять как готовую программу.

## Локальная разработческая проверка

```bash
python3 -m unittest discover -s tests -v
python3 -m py_compile backend/*.py scripts/*.py
bash -n scripts/build-app.sh
```

Данные на Mac: `~/Library/Application Support/Inij/`. Сервер слушает случайный loopback-порт с токеном текущего запуска и отвергает запросы с Origin. Экспорт не содержит service.log, Keychain или браузерные cookies. Он содержит переписки и документы; это личный архив.


## Signed-bundle regression guard (0.2.1)

Every invocation of bundled Python after signing must pass `-I -B`: `-I` ignores `PYTHONDONTWRITEBYTECODE`, so the environment variable alone is not a fix. The app process, bundle verifier, native verifier and installer verifier pass `-B`. Native tests must not add `__pycache__` or any other resource inside the signed `.app`.

Release builds require a clean `build/Inij.app` and `build/dmg-stage`. `codesign --verify --deep --strict` runs both before and after runtime tests. The final DMG is mounted read-only; its app is copied into a unique directory under `/Applications`, launched using LaunchServices (`open -n -W -a ...`), and verified again after exit. Passing direct executable startup alone does not establish Finder/LaunchServices startup.

An ad-hoc signed build is not Developer ID signed or notarized. A clean build-machine launch does not establish downloaded-quarantine acceptance on another Mac.

## Выпуск 0.3.3 — Inij: настройки, Office, телеметрия и изображения

Production stores new data in `~/Library/Application Support/Inij` and API credentials in the macOS Keychain service `local.inij.v1`. It does not import data or credentials from earlier development builds. No account, API key, conversation, model or provider configuration is shipped.

- Слева сверху — переключатель интернета с глобусом; внизу — шестерёнка настроек и большая кнопка «Новый чат». Дополнительные действия перенесены в настройки, экспорт/восстановление — отдельная вкладка. Выбор активного профиля находится во вкладке «Промпты».
- Enter отправляет, Shift+Enter переносит строку. В «Общие» можно переключить Enter на перенос; ⌘Enter отправляет в обоих режимах. Переключение и светлая/тёмная тема сохраняются автоматически.
- Профили промптов можно удалять из списка. Копия остаётся в локальном архиве, связанные чаты переключаются на оставшийся профиль (при удалении последнего создаётся пустой).
- `create_office` создаёт новые DOCX (текст/таблицы), XLSX (листы/ячейки без формул из строк), PPTX (слайды/заголовки/текст). Запись требует подтверждения в приложении, не перезаписывает существующие файлы. Все три формата читаются через скрепку и `read_file`; старые бинарные DOC/XLS/PPT не поддерживаются. Библиотеки включены в app, Python устанавливать пользователю не требуется. Готовый файл лежит в папке проекта («Настройки → Общие → Открыть папку файлов проекта»).
- В шапке справа — температуры CPU/GPU, если датчики доступны, фактические входные/выходные токены из usage провайдера и полезные байты внешнего API модели за запуск. Трафик НЕ включает браузер, поиск, загрузки и накладные расходы протокола; это явно обозначено как API и в подсказке. При отсутствии usage показано н/д, пропущенные запросы не оцениваются.
- Температурный ограничитель управляет только процессом встроенного llama-server: при пороге — 50% рабочего времени, восстановление при охлаждении на 3 °C. Если датчики недоступны (включая VM), численный порог неактивен, применяется системный thermalState macOS serious/critical. Это не управление вентиляторами и не гарантия удержания температуры. Реальный датчик на физическом Apple Silicon Mac ещё не проверен; н/д не заменяется расчётным значением.
- Модели и личные данные не входят в DMG.

### Independent image model

Settings now include a separate image endpoint, model ID and Keychain credential.
The chat model calls `generate_image`; the backend requests an OpenAI-compatible
`/images/generations` endpoint and requires `data[0].b64_json` (PNG/JPEG/WebP).
GPT-image IDs omit `response_format`; other compatible models request `b64_json`.
URL-only responses and non-OpenAI image protocols are not supported in this increment.
Cloud generation is blocked while offline, including previously granted tool permissions.
The image is stored in the project and exposed as an artifact with preview/open/save controls.
The generator key is distinct from the chat key, never serialized in backend state.
Automated provider tests use a mock; live paid generation is not yet verified. Native smoke tests use isolated temporary application data. The Apple Silicon distribution is ad-hoc signed, not Apple-notarized.

## Chat UX in 0.3.6

- Chat messages render headings, fenced code with a copy button, block quotes, simple pipe tables and lists, in addition to inline bold/italic and safe web links. Raw HTML remains text. This is a compact Markdown subset, not a full GFM renderer (escaped pipes and multiline table cells are not supported).
- Unsent drafts are saved locally per project/chat and restored when returning to that chat or restarting the app. Sending clears only the submitted, unchanged draft; an in-flight attachment stays with the originating chat. Drafts use app preferences and are not included in the backend project backup.
- Search filters the current chat by case-insensitive message text; clear the field to show all messages. «Цитировать» inserts a Markdown quote into the composer.
- Drag local files from Finder into the composer to use the same extraction/import path as the paperclip (12 MB limit). This imports text/OCR, not general multimodal image understanding.
- «Аа» persists the text size for messages and the composer. The printer button opens the native print dialog for the full chat; choose PDF → Save as PDF to export. Printing includes text, headings, code and textual table rows, not image attachments.
- The 0.3.5 fix allowing incomplete image-generator settings to be saved is preserved.


## Выпуск 0.3.8 — локальные изображения

«Настройки → Модель → Генерация изображений»: включить, выбрать «На этом Mac»,
указать полный checkpoint SD 1.x / SD 2.x / SDXL (.safetensors или GGUF для
stable-diffusion.cpp), сохранить. Это отдельная модель, не файл текстовой LLM.
Веса в DMG не входят. Отдельные UNet/LoRA и FLUX/SD3 с отдельными компонентами
этим интерфейсом не поддержаны; поддержка архитектуры не определяется расширением.

Встроенный CPU/Metal runtime этой сборки требует **macOS 26+**. Остальные функции
приложения сохраняют прежние требования. На виртуальной macOS VirtualMac авто-режим
использует CPU: paravirtual Metal не выполнил проверочный SD-граф. На физическом Mac
авто-режим предоставляет выбор устройства движку; физический Metal ещё не проверен.

Напиши запрос в чате и нажми **«Нарисовать»**. Текстовая модель и API не нужны.
Картинка появится вложением с предпросмотром, открытием и сохранением. Можно также
поручить generate_image текстовой модели, поддерживающей инструменты. В офлайн-режиме
локальный генератор доступен; сеть его процессу и потомкам запрещена sandbox-exec.
Облачный Images API — отдельный явный выбор, никогда не fallback.

«Стоп» завершает процесс; частичные файлы не прикрепляются. Ограничение одного
запуска — 30 минут. Поддерживаются размеры 256/512/768/1024, 1–50 шагов, CFG 1–15.
Обычным checkpoint нужны обычные параметры; однокроковые/distilled модели требуют
параметров своего автора. Для тестового Hyper-SD 1-step использованы 1 шаг и CFG 1.
Перед изображением выгружается только текстовый движок текущего Inij, чтобы не держать
обе модели в памяти; следующий текстовый запрос загрузит его вновь. Веса лежат снаружи
приложения и не добавляются в архив чатов.

Runtime: leejet/stable-diffusion.cpp master-1106-532d2c1; скачивание, SHA256 и извлечение
arm64 воспроизводятся scripts/install-image-runtime.sh. Лицензии вложены в app.
Отчёт выпуска и точные проверки: ../COMPLETION.md.


## Выпуск 0.3.9 — файлы и библиотека

- В Explore → Библиотека/Загрузки и настройках моделей есть «Удалить…». Диалог показывает имя, размер и полный путь. Подтверждённый файл перемещается в Корзину; место освобождается после её очистки. Внешний выбранный файл тоже перемещается, о чём диалог предупреждает. На другом томе операция отклоняется без копирования/удаления: используй Finder.
- Удаление проверяется сервером: только зарегистрированные GGUF/safetensors; без симлинков; не во время генерации/загрузки. Подтверждение привязано к inode/размеру/mtime и действует пять минут. Выбранная модель сбрасывается, работающий принадлежащий приложению движок выгружается; запись загрузки удаляется, чтобы файл можно было скачать заново.
- Лимит импорта: 12 МБ, 2 млн символов, PDF до 400 страниц. Прежнего обрезания на 60 000 символах нет. Превышение ресурсного лимита — явная ошибка, не обрезание.
- PDF: текстовый слой сохраняется; каждую страницу дополнительно читает локальный Apple Vision OCR. Отличающиеся OCR-строки помечаются отдельно. Это позволяет видеть и сканы, и растровые вставки рядом с текстом. OCR может ошибаться/дублировать строки; изображения без текста не получают визуального описания моделью.
- Большие вложения автоматически читаются последовательно по частям. Все символы проходят первый этап. Результаты сводятся в несколько этапов, если не помещаются в контекст. Интерфейс показывает прогресс, кнопка «Стоп» работает. Исходник, результаты каждой части и манифест покрытия сохраняются в `analysis-*` в папке проекта; три итоговых файла прикрепляются к ответу.
- Это анализ через промежуточные сводки модели, не помещение целого документа в один контекст. Семантическая полнота зависит от модели. Предыдущая история не включается в отдельный большой анализ; об этом говорится в чате. Оригинал остаётся в истории/файле, для последующих запросов используется явно обозначенная сводка. Для нового задания по полному исходнику прикрепи его снова.
- Офлайн сохраняется офлайн. В облачном режиме части отправляются выбранному пользователем провайдеру. Скрытого облачного fallback нет.

Проверки нового маршрута: `tests/test_documents_delete.py`, `scripts/verify_documents_native.py`, `scripts/verify_real_document.py`; сборка — `scripts/build-039.sh`. Нативный smoke использует только одноразовые маленькие модели, не пользовательские веса. Перед финальной упаковкой после любого изменения исходников повторно собери бинарник и подпись.

Сборочные предохранители 0.3.9: диагностический Python запускай с `-B` (или вне подписанного app), иначе `__pycache__` меняет sealed resources. Упаковка всегда создаёт новую staging-папку: `ditto` поверх старой сохранял удалённые `.pyc`, отчего смонтированный DMG не проходил `codesign --verify`. Большие сообщения в SwiftUI показываются компактно с открытием полного текста; полный rich-text на десятках тысяч символов давал пустой/неустойчивый viewport. Файловые карточки разрешены и у assistant-сообщений, а не только tool-результатов; после завершения ответа чат прокручивается к ним.


### Native smoke in the macOS VM

The VM can expose active display 1 while `CGMainDisplayID()` returns 0. In this state, `NSApp.postEvent` changed a synthetic click from window-local y=624 to y=-506 (one 1130-point screen height). Unlocking, pointer warping and longer down/up delays did not fix it. `clickControl` therefore dispatches SwiftUI gestures directly and normalizes the queued release used by AppKit list-cell and checkbox tracking from its Quartz coordinate before delivery. Both paths use the mounted control's geometry and actual hit-testing, never its model closure. Direct down followed by an async up is unsuitable for native Toggle controls: their nested tracking loop blocks the async continuation. Preserve the open/close, settings and confirmed/cancelled deletion assertions.

`cacheDisplay` PNGs include transparent backgrounds; a viewer that ignores alpha can show white button silhouettes. The smoke capture helper composites on the window's appearance-resolved background and saves opaque pixels. This is an app-view render, not a capture of the entire desktop. Desktop `screencapture` is not a prerequisite for these app-local screenshots.

### Sent attachment presentation (2026-11-19)

`/send` accepts question text and a separate `attachments` array. The persisted user
message keeps the full model input in `content` and independent `displayText` plus
attachment metadata for the chat. Provider requests still contain the complete file
text (or the existing explicitly labelled document-mode summary on later turns).
The native chat shows filename cards; clicking a card opens the full extracted text
in a separate window. Quote and print include filenames, not extracted bodies;
editing the question and retrying preserve the attachments. Complete legacy inline
`[Файл: …]` blocks are recognized on load without changing the original model text.
Unterminated blocks are left visible. Regression coverage: backend persistence,
provider payload, HTTP transport, edit/retry and legacy migration; native document
smoke additionally checks the compact card and explicit open action. Native build
verification is recorded separately in the task completion report.


## Выпуск 0.4.0 — компактные отправленные вложения

В истории чата показаны вопрос и карточка файла, а полный извлечённый текст сохраняется для модели. Нажатие на карточку открывает отдельное окно полного текста; цитирование и печать не разворачивают тело файла. Редактирование и повторный запрос сохраняют вложения. Полная площадь карточки участвует в нажатии; выделение текста ограничено текстом сообщения, а не кнопками вложений. Сборочный сценарий `scripts/build-039.sh` берёт номер выпуска из `macos/Info.plist`.

Native UI smoke: `window != nil` у SwiftUI geometry anchor подтверждает mount, но не видимость в прокручиваемом чате. После автопрокрутки к ответу карточка отправленного файла может оказаться за clip viewport, при этом hitTest попадает в toolbar. Перед click-тестом карточки выполняется `scrollToVisible`, проверяется пересечение `bounds` и `visibleRect`, затем отправляются обычные mouse down/up. Не применять эту прокрутку ко всем toolbar-контролам: это меняет геометрию SwiftUI anchor. Исправление только `contentShape` без прокрутки не решало этот сбой теста.

## 0.4.1 — engine management

`backend/engines.py` holds separate bundled llama.cpp, Ollama and OpenAI-compatible
request/stream adapters. A single FIFO worker runs text jobs across chats; up to 20
requests may wait. One pending/running request per chat prevents stale-context and
interleaved-message races. New chats and navigation remain available while generating.
Each running/queued row can be cancelled independently; Stop targets the current chat.
Settings and destructive history/model operations remain locked until work settles.
Queues are session-only, never replayed after restart. Image jobs remain exclusive.

Bundled models load/unload locally. Ollama lifecycle uses `/api/generate` with
`keep_alive`; its configured server owns the process. OpenAI-compatible APIs do not
standardize load/unload, so those controls are deliberately unavailable for that adapter.
Ollama controls act on saved settings. Existing local-model library controls remain.

Measurements: model readiness latency (local health check; Ollama lifecycle request),
time from starting a model call to first nonempty content (includes local model load),
and actual resident memory of the owned llama-server process (`ps rss`, not file size,
not a claim of total unified/GPU memory). Remote memory stays unavailable. Token counts
come only from provider usage. Ollama `eval_duration` supplies generation throughput;
otherwise throughput uses the **whole HTTP request** duration, explicitly labelled in UI.
No provider counts means no token/s estimate. Metrics show the latest model call, not a
sum across tool rounds or document chunks; switching model/provider clears them.

Verification: `tests/test_engines.py` covers protocol/tool deltas, FIFO, queued and active
cancellation, settings guards, lifecycle protocol and missing usage. Native smoke covers
sending a second chat into the queue, cancellation and metrics decoding. Run
`scripts/verify_engine_metrics.py <app> <existing GGUF>` for real-model load/RSS/usage/unload.
