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
- Вложения TXT/CSV/JSON/MD, DOCX/XLSX/PPTX, текстовый PDF, OCR изображений и сканированных PDF до 80 страниц. Результат вставляется в черновик для проверки перед отправкой.
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
