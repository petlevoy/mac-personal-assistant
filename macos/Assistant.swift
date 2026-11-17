import SwiftUI
import AppKit
import WebKit
import Security
import PDFKit
import Vision
import UniformTypeIdentifiers

// Shared by the chat and native rendering checks. No HTML or remote content is loaded.
enum ChatMarkdown {
    static func safeURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return false }
        return true
    }
    static func render(_ source: String) -> AttributedString {
        var text = (try? AttributedString(markdown: source, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible))) ?? AttributedString(source)
        // A model may emit arbitrary URI schemes. Only web links are actionable.
        for run in Array(text.runs) {
            if let url = run.link, !safeURL(url) { text[run.range].link = nil }
        }
        let plain = String(text.characters)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
                guard let url = match.url, safeURL(url), let range = Range(match.range, in: plain),
                      let a = AttributedString.Index(range.lowerBound, within: text),
                      let b = AttributedString.Index(range.upperBound, within: text) else { continue }
                let slice = text[a..<b]
                guard !slice.runs.contains(where: { $0.link != nil || $0.inlinePresentationIntent?.contains(.code) == true }) else { continue }
                text[a..<b].link = url
            }
        }
        return text
    }
}

struct ChatMessageText: View {
    let content: String
    var body: some View {
        Text(ChatMarkdown.render(content))
            .tint(.accentColor)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                ChatMarkdown.safeURL(url) ? .systemAction : .discarded
            })
    }
}

struct Settings: Codable {
    var imageEnabled: Bool?; var imageBaseURL: String?; var imageModel: String?
    var mode: String; var provider: String; var baseURL: String; var model: String
    var thermalEnabled: Bool?; var thermalLimit: Double?
    var contextLimit: Int; var temperature: Double; var toolsEnabled: Bool; var searchProvider: String?
}
struct ProfileVersion: Codable, Identifiable { var id: String; var time: String; var name: String; var prompt: String }
struct Profile: Codable, Identifiable { var id: String; var name: String; var prompt: String; var versions: [ProfileVersion]? }
struct MCPServer: Codable, Identifiable { var id: String; var name: String; var command: String; var args: [String]; var enabled: Bool }
struct Artifact: Codable { var name: String; var path: String; var bytes: Int64 }
struct ChatMessage: Codable { var artifacts: [Artifact]?; var role: String; var content: String; var streaming: Bool? }
struct Chat: Codable, Identifiable {
    var id: String; var title: String; var messages: [ChatMessage]; var skillIDs: [String]; var profileID: String
}
struct Dependency: Codable { var name: String; var available: Bool }
struct Skill: Codable, Identifiable {
    var id: String; var name: String; var description: String; var dependencies: [Dependency]
    var requiredKeys: [String]; var dependencyNotice: String
}
struct LogEntry: Codable { var time: String; var event: String; var detail: String }
struct Project: Codable, Identifiable {
    var id: String; var name: String; var workspace: String; var memory: String
    var skills: [Skill]; var chats: [Chat]; var log: [LogEntry]
}
struct Job: Codable, Identifiable {
    var id: String; var projectID: String; var chatID: String; var status: String; var error: String; var newChatID: String?
}
struct Pending: Codable, Identifiable {
    var id: String; var projectID: String; var kind: String; var tool: String?
    var arguments: [String: JSONValue]?; var workspace: String?; var action: String?; var url: String?
}
struct LocalModelState: Codable { var status: String; var path: String; var error: String }
struct ModelDownload: Codable, Identifiable { var id: String; var repo: String; var file: String; var status: String; var bytes: Int64; var total: Int64; var path: String; var error: String }
struct Usage: Codable { var inputTokens: Int; var outputTokens: Int; var reportedRequests: Int; var missingRequests: Int; var sentBytes: Int; var receivedBytes: Int }
struct Thermal: Codable { var cpu: Double?; var gpu: Double?; var state: Int; var limited: Bool }
struct Permissions: Codable { var all: Bool; var tools: [String] }
struct Snapshot: Codable {
    var permissions: Permissions?
    var usage: Usage?; var thermal: Thermal?
    var localModel: LocalModelState?; var downloads: [ModelDownload]?

    var settings: Settings; var projects: [Project]; var profiles: [Profile]
    var mcp: [MCPServer]?
    var jobs: [Job]; var pending: [Pending]; var hasBraveKey: Bool; var hasModelKey: Bool
}
enum JSONValue: Codable {
    case string(String), number(Double), bool(Bool), object([String:JSONValue]), array([JSONValue]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String:JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .string(let v): try c.encode(v); case .number(let v): try c.encode(v); case .bool(let v): try c.encode(v); case .object(let v): try c.encode(v); case .array(let v): try c.encode(v); case .null: try c.encodeNil() }
    }
    var text: String {
        if case .string(let v) = self { return v }
        guard let d = try? JSONEncoder().encode(self) else { return "" }
        return String(data:d,encoding:.utf8) ?? ""
    }
}
struct AppError: LocalizedError { let message: String; var errorDescription: String? { message } }

enum Keys {
    static let service = CommandLine.arguments.contains("--smoke-test") ? "local.personal-assistant.smoke" : "local.inij.v1"
    static func get(_ name: String) -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: name,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func set(_ name: String, _ value: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: name]
        if value.isEmpty { SecItemDelete(query as CFDictionary); return }
        let update = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = Data(value.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AppError(message: "Связка ключей: код \(status)") }
    }
}

@MainActor final class Browser: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var address = "https://www.google.com"
    @Published var enabled = false
    @Published var status = "Интернет выключен"
    let webView: WKWebView
    var observedElements: [String:String] = [:]
    var pageRevision = UUID().uuidString
    var navigationContinuation: CheckedContinuation<Void, Error>?
    var timeout: Task<Void, Never>?
    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(); webView.navigationDelegate = self
    }
    func allow(_ value: Bool) {
        if enabled && !value {
            webView.stopLoading(); webView.loadHTMLString("<p>Интернет выключен</p>", baseURL: nil)
            finish(AppError(message: "Интернет выключен"))
        }
        enabled = value; status = value ? "Браузер готов" : "Интернет выключен"
    }
    func finish(_ error: Error? = nil) {
        timeout?.cancel(); timeout = nil
        guard let continuation = navigationContinuation else { return }
        navigationContinuation = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
    func open(_ value: String) async throws {
        guard enabled else { throw AppError(message: "Интернет выключен") }
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil else { throw AppError(message: "Нужен http(s) адрес без пароля") }
        finish(AppError(message: "Начат другой переход")); address = value; status = "Загрузка…"
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            navigationContinuation = continuation
            webView.load(URLRequest(url: url))
            timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                self?.webView.stopLoading(); self?.finish(AppError(message: "Страница не загрузилась за 30 секунд"))
            }
        }
    }
    func read() async throws -> [String: Any] {
        guard enabled else { throw AppError(message: "Интернет выключен") }
        pageRevision = UUID().uuidString
        let script = """
        window.__assistantElements=Array.from(document.querySelectorAll('a[href],button,input:not([type=password]):not([type=hidden]),textarea,select')).filter(e=>e.getClientRects().length).slice(0,120);
        JSON.stringify({url:location.href,title:document.title,text:(document.body?.innerText||'').slice(0,24000),truncated:(document.body?.innerText||'').length>24000,elements:window.__assistantElements.map((e,i)=>({ref:String(i),tag:e.tagName,type:e.type||'',text:(e.innerText||e.getAttribute('aria-label')||e.getAttribute('placeholder')||'').slice(0,120)})),links:Array.from(document.querySelectorAll('a[href]')).filter(a=>/^https?:/.test(a.href)).slice(0,80).map(a=>({text:(a.innerText||'').slice(0,180),url:a.href}))})
        """
        let value = try await webView.evaluateJavaScript(script)
        guard let text = value as? String, let data = text.data(using: .utf8),
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError(message: "Не удалось прочитать страницу")
        }
        var enriched = result
        let elements = result["elements"] as? [[String:Any]] ?? []
        observedElements = [:]
        enriched["elements"] = elements.map { item -> [String:Any] in
            var item = item
            let index = item["ref"] as? String ?? ""
            let ref = pageRevision + ":" + index
            observedElements[ref] = index; item["ref"] = ref; return item
        }
        return enriched
    }
    func act(_ action: String, arguments: [String:JSONValue]) async throws {
        guard enabled, let ref = arguments["ref"]?.text, let index = observedElements[ref], Int(index) != nil else { throw AppError(message:"Ссылка на элемент устарела: прочитай страницу снова") }
        let text = arguments["text"]?.text ?? ""
        let encoded = String(data:try JSONSerialization.data(withJSONObject:[text]),encoding:.utf8)!
        let operation = action == "browser_fill" ? "if(!['INPUT','TEXTAREA'].includes(e.tagName)||['password','file','hidden'].includes(e.type))throw Error('Это поле нельзя заполнять');e.value=\(encoded)[0];e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));" : "e.click();"
        _ = try await webView.evaluateJavaScript("(()=>{const e=window.__assistantElements?.[\(index)];if(!e||!e.isConnected)throw Error('Элемент исчез');\(operation)return true;})()")
        observedElements = [:]
        try await Task.sleep(nanoseconds:500_000_000)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { observedElements = [:] }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        observedElements = [:]; address = webView.url?.absoluteString ?? address; status = "Страница загружена"; finish()
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { status = error.localizedDescription; finish(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { status = error.localizedDescription; finish(error) }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        decisionHandler((enabled && ["http", "https"].contains(scheme)) || scheme == "about" ? .allow : .cancel)
    }
}
struct BrowserView: NSViewRepresentable {
    @ObservedObject var browser: Browser
    func makeNSView(context: Context) -> WKWebView { browser.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

@MainActor final class AppModel: ObservableObject {
    @Published var snapshot: Snapshot?
    @Published var projectID = ""
    @Published var chatID = ""
    @Published var draft = ""
    @Published var error = ""
    @Published var startup = "Запуск локального сервиса…"
    @Published var showBrowser = false
    @Published var settingsShown = false
    @Published var inspectorShown = false
    @Published var exploreShown = false
    @Published var contextText = ""
    @Published var contextShown = false
    @Published var tokenEstimate = 0
    let browser = Browser()
    var starting = false
    var process: Process?
    var sessionToken = UUID().uuidString + UUID().uuidString
    var port = 0
    var polling: Task<Void, Never>?
    var browserRequests = Set<String>()
    var seenJobs = Set<String>()
    var project: Project? { snapshot?.projects.first { $0.id == projectID } }
    var chat: Chat? { project?.chats.first { $0.id == chatID } }
    var running: Bool { snapshot?.jobs.contains { $0.status == "running" } ?? false }
    var approval: Pending? { snapshot?.pending.first { $0.kind == "approval" } }
    func start() async {
        guard !starting, port == 0 else { return }; starting = true
        defer { starting = false }
        do {
            guard let resources = Bundle.main.resourceURL else { throw AppError(message: "Нет Resources") }
            let script = resources.appendingPathComponent("backend/server.py")
            let support = CommandLine.arguments.contains("--smoke-test") ? FileManager.default.temporaryDirectory.appendingPathComponent("Inij-Smoke-" + UUID().uuidString) : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Inij")
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let python = resources.appendingPathComponent("python/bin/python3")
            guard FileManager.default.isExecutableFile(atPath:python.path) else { throw AppError(message:"В приложении отсутствует встроенный движок. Установи полный .app из дистрибутива.") }
            let ready = support.appendingPathComponent("ready-" + UUID().uuidString + ".json")
            defer { try? FileManager.default.removeItem(at:ready) }
            let p = Process(); p.executableURL = python
            p.arguments = ["-I", "-B", "-u", script.path, "--data", support.path, "--ready-file", ready.path]
            p.environment = ["MAC_ASSISTANT_TOKEN":sessionToken,"PATH":"/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin","HOME":NSHomeDirectory(),"PYTHONIOENCODING":"utf-8"]
            p.standardOutput = FileHandle.nullDevice
            let logfile = support.appendingPathComponent("service.log")
            FileManager.default.createFile(atPath:logfile.path,contents:nil)
            p.standardError = try FileHandle(forWritingTo:logfile)
            try p.run(); process = p
            var readyData: Data?
            for _ in 0..<150 {
                if let data = try? Data(contentsOf:ready) { readyData = data; break }
                if !p.isRunning { break }
                try await Task.sleep(nanoseconds:100_000_000)
            }
            guard let bytes = readyData, let json = try JSONSerialization.jsonObject(with:bytes) as? [String:Any], let value = json["port"] as? Int else { p.terminate(); throw AppError(message:"Не удалось запустить встроенный сервис за 15 секунд. Журнал: " + logfile.path) }
            port = value
            if !CommandLine.arguments.contains("--smoke-test") {
            _ = try await api("/keys", ["image": Keys.get("image"), "model": Keys.get("model"), "brave": Keys.get("brave"), "tavily": Keys.get("tavily"), "serper": Keys.get("serper")])
            }
            try await refresh(); startup = ""; if snapshot?.settings.model.isEmpty == true { settingsShown = true }
            polling = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    guard let self, !Task.isCancelled else { return }
                    do { try await self.refresh() } catch { self.error = "Связь с локальным сервисом: \(error.localizedDescription)" }
                }
            }
        } catch { shutdown(); self.error = error.localizedDescription; startup = "Запуск не завершен" }
    }
    func shutdown() { polling?.cancel(); browser.webView.stopLoading(); process?.terminate(); process = nil; port = 0 }
    func api(_ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        guard port > 0, let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { throw AppError(message: "Сервис не готов") }
        var request = URLRequest(url: url); request.timeoutInterval = 65
        request.setValue(sessionToken, forHTTPHeaderField: "X-App-Token")
        if let body {
            request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AppError(message: "Некорректный ответ сервиса") }
        guard let http = response as? HTTPURLResponse, http.statusCode < 400 else { throw AppError(message: result["error"] as? String ?? "Ошибка сервиса") }
        return result
    }
    func refresh() async throws {
        _ = try await api("/thermal", ["state": ProcessInfo.processInfo.thermalState.rawValue])
        let json = try await api("/state")
        snapshot = try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: json))
        if project == nil { projectID = snapshot?.projects.first?.id ?? "" }
        if chat == nil { chatID = project?.chats.last?.id ?? "" }
        browser.allow(snapshot?.settings.mode != "offline")
        for job in snapshot?.jobs ?? [] where job.status != "running" && !seenJobs.contains(job.id) {
            seenJobs.insert(job.id)
            if !job.error.isEmpty && job.status == "failed" { error = job.error }
            if let new = job.newChatID { projectID = job.projectID; chatID = new }
        }
        for request in snapshot?.pending ?? [] where request.kind == "browser" && !browserRequests.contains(request.id) {
            browserRequests.insert(request.id); showBrowser = true
            Task {
                var result: [String: Any]
                do {
                    if request.action == "browser_open" { try await browser.open(request.url ?? "") }
                    if ["browser_click","browser_fill"].contains(request.action ?? "") { try await browser.act(request.action!,arguments:request.arguments ?? [:]) }
                    result = try await browser.read()
                } catch { result = ["error": error.localizedDescription] }
                _ = try? await api("/resolve", ["id": request.id, "response": result])
            }
        }
    }
    func perform(_ action: @escaping () async throws -> Void) {
        Task { do { try await action(); try await refresh() } catch { self.error = error.localizedDescription } }
    }
    func send() {
        let text = draft; let pid = projectID; let cid = chatID
        perform { _ = try await self.api("/send", ["projectID": pid, "chatID": cid, "text": text]); self.draft = "" }
    }
    func stop() { perform { _ = try await self.api("/stop", [:]); self.browser.webView.stopLoading(); self.browser.finish(AppError(message: "Остановлено")) } }
    func newChat() { perform { let r = try await self.api("/chat", ["projectID": self.projectID]); self.chatID = r["id"] as? String ?? "" } }
    func newProject() {
        let alert = NSAlert(); alert.messageText = "Новый проект"; alert.addButton(withTitle: "Создать"); alert.addButton(withTitle: "Отмена")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 26)); field.placeholderString = "Название"
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
        perform { let r = try await self.api("/project", ["name": field.stringValue]); self.projectID = r["id"] as? String ?? "" }
    }
    func chooseWorkspace() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Модель сможет читать файлы этой папки. Запись требует подтверждения."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { _ = try await self.api("/project/update", ["projectID": self.projectID, "workspace": url.path]) }
    }
    func importSkill() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true
        panel.message = "Выбери папку скилла или SKILL.md. Скрипты не запускаются при импорте."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { _ = try await self.api("/skill", ["projectID": self.projectID, "path": url.path]) }
    }
    func toggleSkill(_ id: String) {
        var ids = chat?.skillIDs ?? []
        if ids.contains(id) { ids.removeAll { $0 == id } } else { ids.append(id) }
        perform { _ = try await self.api("/chat/config", ["projectID": self.projectID, "chatID": self.chatID, "skillIDs": ids]) }
    }
    func previewContext() {
        perform {
            let r = try await self.api("/context", ["projectID": self.projectID, "chatID": self.chatID])
            self.tokenEstimate = r["estimatedTokens"] as? Int ?? 0
            let d = try JSONSerialization.data(withJSONObject: r["messages"] ?? [], options: [.prettyPrinted, .sortedKeys])
            self.contextText = String(data: d, encoding: .utf8) ?? ""; self.contextShown = true
        }
    }
    func compact() {
        perform { _ = try await self.api("/compact", ["projectID": self.projectID, "chatID": self.chatID]) }
    }
    func exportChat(_ id: String) {
        let pid = projectID
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Inij-chat.json"; panel.allowedContentTypes = [.json]
        panel.message = "Только выбранный чат, без других чатов, ключей и файлов проекта."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { _ = try await self.api("/chat/export", ["projectID":pid,"chatID":id,"path":url.path]); NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
    func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Inij-backup.zip"; panel.allowedContentTypes = [.zip]
        panel.message = "Содержит историю, память, скиллы и импортированные файлы. Ключи и cookies не включаются."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { _ = try await self.api("/export", ["path": url.path]); NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
    func restore() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert(); alert.messageText = "Восстановить бэкап?"; alert.informativeText = "Текущие данные будут сохранены отдельной копией. Ключи остаются в Связке ключей. Внешние папки нужно будет выбрать заново."; alert.addButton(withTitle:"Восстановить"); alert.addButton(withTitle:"Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform { let result = try await self.api("/restore",["path":url.path]); self.projectID="";self.chatID="";self.error = result["notice"] as? String ?? "Бэкап восстановлен" }
    }
    func changeChat(_ action: String, index: Int = -1, text: String = "") {
        if action == "delete" {
            let alert = NSAlert();alert.messageText="Удалить чат из списка?";alert.informativeText="История останется в архиве приложения.";alert.addButton(withTitle:"Удалить");alert.addButton(withTitle:"Отмена")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        var payload: [String:Any] = ["projectID":projectID,"chatID":chatID,"action":action,"index":index]
        if action == "edit" { payload["text"] = text }
        perform { _ = try await self.api("/chat/change",payload) }
    }
    func editMessage(_ index: Int, _ content: String) {
        let alert = NSAlert();alert.messageText="Изменить сообщение и ответить заново";alert.informativeText="Последующая история будет сохранена в архиве.";alert.addButton(withTitle:"Отправить");alert.addButton(withTitle:"Отмена")
        let field = NSTextField(frame:NSRect(x:0,y:0,width:450,height:100));field.stringValue=content;alert.accessoryView=field
        if alert.runModal() == .alertFirstButtonReturn { changeChat("edit",index:index,text:field.stringValue) }
    }
    func attach() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.message = "Текст будет вставлен в сообщение; в облачном режиме он уйдет выбранному провайдеру. До 12 МБ."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let pid = projectID
        perform {
            let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            guard size <= 12 * 1024 * 1024 else { throw AppError(message: "Файл больше 12 МБ") }
            var payload: [String: Any] = ["projectID": pid, "path": url.path]
            let ext = url.pathExtension.lowercased()
            if ext == "pdf" {
                guard let doc = PDFDocument(url: url) else { throw AppError(message: "PDF не открылся") }
                let text = doc.string ?? ""
                if text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                    guard doc.pageCount <= 80 else { throw AppError(message:"Для OCR раздели PDF на части до 80 страниц") }
                    var pages: [String] = []
                    for i in 0..<doc.pageCount {
                        guard let page = doc.page(at:i) else { continue }
                        let image = page.thumbnail(of:NSSize(width:1600,height:2200),for:.mediaBox)
                        guard let data = image.tiffRepresentation else { continue }
                        let recognized = try await Task.detached {
                            let request = VNRecognizeTextRequest();request.recognitionLevel = .accurate;request.recognitionLanguages=["ru-RU","en-US"]
                            try VNImageRequestHandler(data:data).perform([request])
                            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator:"\n")
                        }.value
                        pages.append("[Страница \(i+1)]\n"+recognized)
                    }
                    payload["extractedText"] = pages.joined(separator:"\n")
                } else { payload["extractedText"] = text }
            } else if ["png", "jpg", "jpeg", "tiff", "heic", "webp"].contains(ext) {
                let text = try await Task.detached {
                    let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages = ["ru-RU", "en-US"]
                    try VNImageRequestHandler(url: url).perform([request])
                    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                }.value
                guard !text.isEmpty else { throw AppError(message: "Текст на картинке не распознан. Визуальное описание моделью пока не подключено.") }
                payload["extractedText"] = text
            }
            let r = try await self.api("/attachment", payload)
            let note = (r["truncated"] as? Bool == true) ? " [ОБРЕЗАНО до 60000 символов]" : ""
            self.draft += "\n\n[Файл: \(url.lastPathComponent)\(note)]\n\(r["text"] as? String ?? "")\n[Конец файла]\n"
        }
    }
}

struct AppTheme: ViewModifier {
    @AppStorage("appearanceTheme") private var theme = "dark"
    func body(content: Content) -> some View {
        content.preferredColorScheme(theme == "light" ? .light : .dark)
            .onAppear { apply() }
            .onChange(of: theme) { _ in apply() }
    }
    private func apply() {
        NSApp.appearance = NSAppearance(named: theme == "light" ? .aqua : .darkAqua)
    }
}

struct MonochromeButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration:Configuration) -> some View {
        configuration.label.font(.system(size:13,weight:.medium)).lineLimit(1)
            .padding(.horizontal,10).padding(.vertical,6)
            .foregroundStyle(Color.primary.opacity(enabled ? 1 : 0.35))
            .background(Color.primary.opacity(configuration.isPressed ? 0.22 : (enabled ? 0.12 : 0.05)))
            .clipShape(RoundedRectangle(cornerRadius:7))
    }
}
struct Composer: NSViewRepresentable {
    @Binding var text: String
    var enterSends: Bool
    var send: () -> Void
    final class Input: NSTextView {
        var submit: (() -> Void)?
        var enterSends = true
        override func keyDown(with event: NSEvent) {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 36 && !hasMarkedText() {
                if flags.contains(.command) || (enterSends && !flags.contains(.shift) && !flags.contains(.option) && !flags.contains(.control)) { submit?(); return }
            }
            super.keyDown(with:event)
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: Composer
        init(_ parent: Composer) { self.parent=parent }
        func textDidChange(_ notification: Notification) { if let view=notification.object as? NSTextView { parent.text=view.string } }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll=NSScrollView(); scroll.hasVerticalScroller=true; scroll.drawsBackground=false
        let input=Input(); input.isRichText=false; input.font=NSFont.systemFont(ofSize:NSFont.systemFontSize)
        input.textColor = .textColor; input.backgroundColor = .textBackgroundColor
        input.minSize=NSSize(width:0,height:80); input.maxSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        input.isVerticallyResizable=true; input.isHorizontallyResizable=false
        input.autoresizingMask=[.width]; input.textContainer?.widthTracksTextView=true
        input.textContainerInset=NSSize(width:8,height:8); input.delegate=context.coordinator
        scroll.documentView=input
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent=self
        guard let input=scroll.documentView as? Input else { return }
        if input.string != text { input.string=text }
        input.enterSends=enterSends; input.submit=send
    }
}
struct MainView: View {
    @AppStorage("enterSends") private var enterSends = true
    @EnvironmentObject var model: AppModel
    @State private var modelPickerShown = false
    var body: some View {
        HStack(spacing:0) {
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "globe")
                    Toggle("Интернет", isOn: Binding(get: { model.snapshot?.settings.mode != "offline" }, set: { enabled in
                        model.perform {
                            let provider=model.snapshot?.settings.provider ?? "local"
                            let base=model.snapshot?.settings.baseURL ?? ""
                            if !enabled && provider != "local" && !(["127.0.0.1","localhost","::1"].contains(URLComponents(string:base)?.host ?? "")) { throw AppError(message:"Для отключения интернета сначала выбери локальную модель в настройках") }
                            _ = try await model.api("/settings", ["mode": enabled ? (provider == "local" || ["127.0.0.1","localhost","::1"].contains(URLComponents(string:base)?.host ?? "") ? "internet" : "cloud") : "offline"])
                        }
                    })).toggleStyle(.switch).controlSize(.small).disabled(model.running || model.snapshot == nil)
                }.padding(.bottom,8)
                HStack { Text("Проекты").font(.headline); Spacer(); Button(action: model.newProject) { Image(systemName: "folder.badge.plus") } }
                Picker("Проект", selection: $model.projectID) {
                    ForEach(model.snapshot?.projects ?? []) { p in Text(p.name).tag(p.id) }
                }.labelsHidden().disabled(model.running)
                List(selection: $model.chatID) {
                    ForEach(model.project?.chats ?? []) { c in
                        Text(c.title).lineLimit(2).tag(c.id).contextMenu {
                            Button("Контекст чата") { model.chatID=c.id; model.previewContext() }
                            Button("Сводка чата") { model.chatID=c.id; model.compact() }.disabled(c.messages.isEmpty)
                            Button("Экспорт") { model.exportChat(c.id) }
                            Divider()
                            Button("Удалить чат",role:.destructive) { model.chatID=c.id; model.changeChat("delete") }
                        }.disabled(model.running)
                    }
                }
                HStack {
                    Button(action: { model.settingsShown=true }) { Image(systemName:"gearshape").font(.title3) }.help("Настройки")
                    Button(action: model.newChat) { Text("Новый чат").frame(maxWidth:.infinity).padding(.vertical,6) }.disabled(model.running)
                }
            }.buttonStyle(MonochromeButton()).controlSize(.regular).padding(12).frame(width:220)
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Text(telemetryLabel).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            .help("Температуры датчиков, если доступны. Токены — только usage провайдера за запуск; н/д, если не возвращены. Трафик — полезные байты запросов/ответов внешнего API модели, без браузера, загрузок и протокольных накладных расходов.")
                    }.padding(12)
                    Divider()
                    if let local = model.snapshot?.localModel, model.snapshot?.settings.provider == "local", local.status == "loading" || local.status == "error" {
                        HStack {
                            if local.status == "loading" { ProgressView().controlSize(.small) }
                            Text(local.status == "ready" ? "Модель готова · работает на этом Mac" : local.status == "loading" ? "Загрузка модели…" : local.status == "error" ? local.error : "Модель загрузится при отправке сообщения").font(.caption).lineLimit(3)
                            Spacer()
                        }.padding(.horizontal,12).padding(.vertical,6)
                    }
                    if !model.startup.isEmpty { Text(model.startup).padding(); Button("Повторить запуск") { Task { await model.start() } } }
                    if model.snapshot?.settings.model.isEmpty == true { Text("Выбери файл GGUF в настройках или скачай модель в Explore.").padding(); Button("Настроить модель") { model.settingsShown = true } }
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 16) {
                                ForEach(Array((model.chat?.messages ?? []).enumerated()), id: \.offset) { index, message in
                                    if message.role != "tool" {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(message.role == "user" ? "Ты" : "Помощник").font(.caption.bold()).foregroundStyle(.secondary)
                                            if message.role == "user" { Button("Изменить") { model.editMessage(index,message.content) }.font(.caption).disabled(model.running) }
                                            ChatMessageText(content: message.content.isEmpty && message.streaming == true ? "…" : message.content)
                                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                        }.padding(14).background(message.role == "user" ? Color.primary.opacity(0.08) : Color.secondary.opacity(0.06))
                                            .clipShape(RoundedRectangle(cornerRadius: 10)).id(index)
                                    } else {
                                        ForEach(message.artifacts ?? [], id: \.path) { artifact in
                                            VStack(alignment: .leading, spacing: 6) {
                                                if let workspace = model.project?.workspace,
                                                   ["png","jpg","jpeg","webp"].contains(URL(fileURLWithPath:artifact.path).pathExtension.lowercased()),
                                                   let preview = NSImage(contentsOfFile: URL(fileURLWithPath:workspace).appendingPathComponent(artifact.path).path) {
                                                    Image(nsImage:preview).resizable().scaledToFit().frame(maxWidth:480,maxHeight:360)
                                                }
                                                Label(artifact.name, systemImage: "doc.fill").font(.headline)
                                                Text(ByteCountFormatter.string(fromByteCount: artifact.bytes, countStyle: .file)).font(.caption)
                                                HStack {
                                                    Button("Открыть") { fileAction(artifact, action: "open") }
                                                    Button("Показать в Finder") { fileAction(artifact, action: "reveal") }
                                                    Button("Сохранить как…") { fileAction(artifact, action: "save") }
                                                }
                                            }.padding(12).background(Color.accentColor.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 8))
                                        }
                                        DisclosureGroup("Результат инструмента") { Text(message.content).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }.foregroundStyle(.secondary)
                                    }
                                }
                                Color.clear.frame(height: 1).id("bottom")
                            }.padding()
                        }.onChange(of: model.chat?.messages.count) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    if let pending = model.approval {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Подтвердить действие: \(pending.tool ?? "")").bold()
                            if pending.tool == "run_command" { Text(model.snapshot?.settings.mode == "offline" ? "Локальная команда: сеть запрещена для процесса и потомков. Доступ к файлам — с твоими правами. Тайм-аут 60 секунд." : "Команда имеет права твоего пользователя, включая сеть. Тайм-аут 60 секунд.").foregroundStyle(.primary) }
                            ScrollView { Text((pending.arguments ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.text)" }.joined(separator: "\n")).font(.system(.caption,design: .monospaced)).textSelection(.enabled) }.frame(maxHeight: 130)
                            HStack {
                                Button("Отклонить") { resolve(pending, false) }
                                Button("Разрешить один раз") { resolve(pending, true) }
                            }
                            HStack {
                                Button("Разрешать всегда") { resolve(pending, true, scope: "tool") }
                                    .help("Разрешить этот инструмент во всех проектах. Для MCP — только этот сервер и инструмент.")
                                Button("Разрешить всё и всегда") { resolve(pending, true, scope: "all") }
                                    .help("Все инструменты, включая команды и MCP, во всех проектах. Сохраняется между запусками; сброс — в настройках.")
                            }
                        }.padding().background(Color.primary.opacity(0.12))
                    }
                    Divider()
                    HStack {
                        Button { modelPickerShown.toggle() } label: { Image(systemName: "cpu").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).help("Выбрать модель").disabled(model.running)
                            .popover(isPresented:$modelPickerShown) { ModelPickerPopup(model:model, isPresented:$modelPickerShown) }
                        Spacer()
                        Button(action: model.attach) { Image(systemName: "paperclip") }.disabled(model.running)
                    }.padding(.horizontal,12).padding(.top,8)
                    Composer(text: $model.draft, enterSends: enterSends, send: { if !model.running { model.send() } }).frame(height:90).padding(8)
                    HStack {
                        Button("Повторить ответ") { model.changeChat("retry") }.disabled(model.running || (model.chat?.messages.isEmpty ?? true))
                        Text(enterSends ? "↩ — отправить · ⇧↩ — новая строка" : "⌘↩ — отправить · ↩ — новая строка").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if model.running { Button("Стоп", action: model.stop).keyboardShortcut(.escape,modifiers: []) }
                        else { Button("Отправить",action: model.send).keyboardShortcut(.return,modifiers: .command).disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.snapshot == nil) }
                    }.padding(12)
                }.frame(minWidth: 480, maxWidth: .infinity)
                if model.showBrowser {
                    BrowserPanel(browser: model.browser).frame(minWidth: 350,idealWidth: 500)
                }
            }
        }
        .frame(minWidth: model.showBrowser ? 1180 : 900,minHeight: 650)
        .modifier(AppTheme()).tint(.gray).accentColor(.gray).buttonStyle(MonochromeButton())
        .sheet(isPresented: $model.exploreShown) { ExploreView(model: model) }
        .sheet(isPresented: $model.settingsShown) { SettingsView(model: model) }
        .sheet(isPresented: $model.inspectorShown) { InspectorView(model: model) }
        .sheet(isPresented: $model.contextShown) {
            VStack(alignment: .leading) {
                Text("Контекст: ≈\(model.tokenEstimate) токенов").font(.title2)
                Text("Расчет: сообщения и схемы инструментов, UTF-8 байты / 4. Не токенизатор модели; точное потребление может отличаться.").font(.caption)
                ScrollView { Text(model.contextText).font(.system(.caption,design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity,alignment: .leading) }
                Button("Закрыть") { model.contextShown = false }
            }.padding().frame(width: 760,height: 600)
        }
        .alert("Сообщение", isPresented: Binding(get: { !model.error.isEmpty },set: { if !$0 { model.error = "" } })) { Button("OK") { model.error = "" } } message: { Text(model.error) }
    }
    var telemetryLabel: String {
        let t=model.snapshot?.thermal
        let cpu=t?.cpu.map { String(format:"%.0f°",$0) } ?? "н/д"
        let gpu=t?.gpu.map { String(format:"%.0f°",$0) } ?? "н/д"
        let u=model.snapshot?.usage
        let tokens=(u?.reportedRequests ?? 0)>0 ? "Токены ↓\(u?.inputTokens ?? 0) ↑\(u?.outputTokens ?? 0)" + ((u?.missingRequests ?? 0)>0 ? " (не все)" : "") : "Токены: н/д"
        let tx=ByteCountFormatter.string(fromByteCount:Int64(u?.sentBytes ?? 0),countStyle:.file)
        let rx=ByteCountFormatter.string(fromByteCount:Int64(u?.receivedBytes ?? 0),countStyle:.file)
        return "Температура CPU \(cpu) · GPU \(gpu)" + (t?.limited == true ? " · ограничение" : "") + "  |  API ↑\(tx) ↓\(rx)  |  " + tokens
    }
    var modeLabel: String {
        switch model.snapshot?.settings.mode { case "cloud": return "Облачная модель + интернет"; case "internet": return "Локальная модель + интернет"; default: return "Только локально" }
    }
    func fileAction(_ artifact: Artifact, action: String) {
        let pid = model.projectID
        model.perform {
            let result = try await model.api("/artifact/path", ["projectID": pid, "path": artifact.path])
            guard let path = result["path"] as? String else { throw AppError(message: "Файл недоступен") }
            let url = URL(fileURLWithPath: path)
            if action == "open" { NSWorkspace.shared.open(url) }
            else if action == "reveal" { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            else {
                let panel = NSSavePanel(); panel.nameFieldStringValue = artifact.name
                if panel.runModal() == .OK, let destination = panel.url, destination.standardizedFileURL != url.standardizedFileURL {
                    let bytes = try Data(contentsOf: url)
                    try bytes.write(to: destination, options: .atomic)
                }
            }
        }
    }
    func resolve(_ pending: Pending, _ approved: Bool, scope: String = "once") {
        model.perform { _ = try await model.api("/resolve", ["id": pending.id,"response": ["approved": approved, "scope": scope]]) }
    }
}
struct BrowserPanel: View {
    @ObservedObject var browser: Browser
    var body: some View {
        VStack(spacing: 6) {
            HStack {
                TextField("https://…",text: $browser.address).onSubmit { go() }
                Button("Открыть",action: go).disabled(!browser.enabled)
            }.padding(8)
            Text(browser.status).font(.caption).foregroundStyle(.secondary)
            BrowserView(browser: browser)
            Text("Отдельный профиль приложения. Вход и капчу проходи вручную. Модель читает текст, не пароли из полей.").font(.caption).foregroundStyle(.secondary).padding(8)
        }
    }
    func go() { Task { do { try await browser.open(browser.address) } catch { browser.status = error.localizedDescription } } }
}

struct SettingsView: View {
    @AppStorage("enterSends") private var enterSends = true
    @State var thermalEnabled = false
    @State var thermalLimit = 80.0
    @State private var deleteProfileShown = false
    @AppStorage("appearanceTheme") private var appearanceTheme = "dark"
    @ObservedObject var model: AppModel
    @State var mode = "offline"
    @State private var settingsTab = 0
    @State var provider = "local"
    @State var base = "http://127.0.0.1:11434"
    @State var selectedModel = ""
    @State var limit = 8192
    @State var temperature = 0.4
    @State var toolsEnabled = false
    @State var imageEnabled = false
    @State var imageBase = ""
    @State var imageModel = ""
    @State var imageKey = ""
    @State var modelKey = ""
    @State var braveKey = ""
    @State var tavilyKey = ""
    @State var serperKey = ""
    @State var searchProvider = "brave"
    @State var mcpName = ""
    @State var mcpCommand = ""
    @State var mcpArgs = "[]"
    @State var models: [String] = []
    @State var notice = ""
    @State var profileID = ""
    @State var profileName = ""
    @State var prompt = ""
    var body: some View {
        VStack(alignment: .leading,spacing: 12) {
            Text("Настройки").font(.title)
            Picker("Оформление", selection: $appearanceTheme) {
                Text("Тёмное").tag("dark")
                Text("Светлое").tag("light")
            }.pickerStyle(.segmented).help("Сохраняется автоматически и применяется ко всему приложению")
            VStack(spacing:8) {
                HStack {
                    ForEach(Array(["Модель","Промпты","Скиллы и память","MCP","Экспорт и бэкап","Explore · модели","Дополнительно"].enumerated()),id: \.offset) { index,title in
                        Button(title) { settingsTab=index }.background(settingsTab == index ? Color.primary.opacity(0.15) : Color.clear).clipShape(RoundedRectangle(cornerRadius:7))
                    }
                }
                Group { if settingsTab == 0 {
                ScrollView { Form {
                    Picker("Режим",selection: $mode) { Text("Только локально").tag("offline"); Text("Локальная модель + интернет").tag("internet"); Text("Облачная модель + интернет").tag("cloud") }
                    Picker("Протокол",selection: $provider) { Text("Встроенная модель · GGUF").tag("local"); Text("Ollama · внешний сервер").tag("ollama"); Text("OpenAI-совместимый API").tag("openai") }
                    if provider == "local" {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(selectedModel.isEmpty ? "Файл модели не выбран" : URL(fileURLWithPath:selectedModel).lastPathComponent).lineLimit(2).truncationMode(.middle).help(selectedModel)
                            HStack {
                                Button("Обзор…", action: browseModel)
                                Button("Загрузить модель") { save(fetch:false, load:true) }.disabled(selectedModel.isEmpty)
                                Button("Выгрузить") { model.perform { _ = try await model.api("/local/unload",[:]) } }
                            }
                            Text("GGUF запускается встроенным движком на этом Mac. Другие приложения не нужны. Поддержка зависит от архитектуры модели.").font(.caption).foregroundStyle(.secondary)
                            if let local = model.snapshot?.localModel { Text(local.status == "loading" ? "Загружаю…" : local.status == "ready" ? "Модель готова" : local.error).font(.caption) }
                        }
                    } else {
                        TextField("Адрес API",text: $base)
                        Text("Ollama: адрес без /api. OpenAI API: с /v1. Поле модели — ID сервера, не путь к файлу.").font(.caption).foregroundStyle(.secondary)
                        TextField("ID модели",text: $selectedModel)
                        if !models.isEmpty { Picker("Доступные модели",selection: $selectedModel) { ForEach(models,id: \.self) { Text($0).tag($0) } } }
                        Button("Проверить список моделей") { save(fetch: true) }
                    }
                    Toggle("Разрешить инструменты модели",isOn: $toolsEnabled)
                    Text("Для действий нужна модель с поддержкой tool calling. Если она не поддерживается, выключи инструменты для обычного чата.").font(.caption).foregroundStyle(.secondary)
                    TextField("Лимит контекста",value: $limit,format: .number)
                    Slider(value: $temperature,in: 0...2) { Text("Температура \(temperature, specifier: "%.1f")") }
                    SecureField("Ключ модели",text: $modelKey)
                    Section("Генерация изображений · отдельная модель") {
                        Toggle("Включить генератор изображений",isOn:$imageEnabled)
                        TextField("Адрес OpenAI-совместимого Images API, с /v1",text:$imageBase)
                        TextField("ID модели изображений",text:$imageModel)
                        SecureField("Ключ генератора изображений",text:$imageKey)
                        Text("Основная модель вызывает генератор как инструмент. Нужен интернет. Поддерживается /images/generations с ответом b64_json; картинка сохраняется в проекте.").font(.caption)
                    }
                    Picker("Поиск",selection:$searchProvider) { Text("Brave").tag("brave");Text("Tavily").tag("tavily");Text("Serper").tag("serper") }
                    SecureField("Ключ Brave Search",text: $braveKey)
                    SecureField("Ключ Tavily",text:$tavilyKey)
                    SecureField("Ключ Serper",text:$serperKey)

                    Text("Ключи хранятся в Связке ключей. Поисковый API проверяется первым запросом. В режиме без интернета поиск и MCP отключены.").font(.caption)
                    Text("В облачном режиме провайдер получает выбранный контекст, память и подключенные скиллы. Автоматического перехода из локального режима нет.").font(.caption)
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }.formStyle(.grouped).padding(8) } } else if settingsTab == 1 {
                VStack(alignment: .leading) {
                    Picker("Профиль",selection: $profileID) {
                        ForEach(model.snapshot?.profiles ?? []) { p in Text(p.name).tag(p.id) }
                        Text("Новый профиль").tag("")
                    }.onChange(of: profileID) { value in loadProfile(value) }
                    Button("Использовать этот профиль в текущем чате") { model.perform { _ = try await model.api("/chat/config", ["projectID":model.projectID,"chatID":model.chatID,"profileID":profileID]) } }.disabled(profileID.isEmpty)
                    TextField("Название",text: $profileName)
                    TextEditor(text: $prompt).font(.system(.body,design: .monospaced))
                    Text("Добавляется к коротким встроенным правилам и памяти проекта. Полный результат виден в «Контекст». Перед каждым изменением сохраняется версия для отката.").font(.caption)
                    Menu("Восстановить версию") {
                        ForEach(model.snapshot?.profiles.first(where:{$0.id==profileID})?.versions ?? []) { version in
                            Button(version.time + " · " + version.name) { model.perform { _ = try await model.api("/profile/restore",["id":profileID,"versionID":version.id]);prompt=version.prompt;profileName=version.name } }
                        }
                    }
                    HStack {
                        Button("Сохранить профиль") { save(fetch:false) }.disabled(profileName.isEmpty)
                        Button("Удалить профиль",role:.destructive) { deleteProfileShown=true }.disabled(profileID.isEmpty)
                    }
                    .confirmationDialog("Удалить сохранённый промпт? Чаты будут переключены на другой профиль. Копия сохранится в архиве.",isPresented:$deleteProfileShown) {
                        Button("Удалить",role:.destructive) { model.perform { let result=try await model.api("/profile/delete",["id":profileID]); try await model.refresh(); profileID=result["id"] as? String ?? ""; loadProfile(profileID) } }
                    }
                }.padding() } else if settingsTab == 2 {
                    InspectorView(model:model, embedded:true)
                } else if settingsTab == 3 {
                VStack(alignment:.leading,spacing:12) {
                    Text("MCP · локальные stdio-серверы").font(.headline)
                    Text("Запуск процесса и вызовы требуют подтверждения, если не сохранено постоянное разрешение. Сервер работает с правами твоего пользователя; аргументы не должны содержать ключи.").font(.caption)
                    List(model.snapshot?.mcp ?? []) { server in
                        HStack { VStack(alignment:.leading) { Text(server.name);Text(server.command + " " + server.args.joined(separator:" ")).font(.caption);Text(server.enabled ? "Включен" : "Выключен после восстановления") };Spacer(); Button("Удалить") { model.perform { _ = try await model.api("/mcp/remove",["id":server.id]) } } }
                    }
                    TextField("Название сервера",text:$mcpName)
                    TextField("Путь к исполняемому файлу",text:$mcpCommand)
                    TextField("Аргументы: JSON-массив строк",text:$mcpArgs)
                    Button("Добавить MCP") {
                        model.perform {
                            guard let bytes=mcpArgs.data(using:.utf8),let args=try JSONSerialization.jsonObject(with:bytes) as? [String] else { throw AppError(message:"Аргументы должны быть JSON-массивом строк") }
                            _ = try await model.api("/mcp/save",["name":mcpName,"command":mcpCommand,"args":args,"enabled":true]);mcpName="";mcpCommand="";mcpArgs="[]"
                        }
                    }.disabled(mcpName.isEmpty || mcpCommand.isEmpty)
                    Text("В чате попроси показать инструменты сервера; помощник вызовет mcp_list, затем mcp_call.").font(.caption)
                }.padding() } else if settingsTab == 6 {
                    ScrollView { VStack(alignment:.leading,spacing:16) {
                        Text("Разрешения инструментов").font(.headline)
                        Text(model.snapshot?.permissions?.all == true ? "Все инструменты разрешены постоянно во всех проектах." : "Постоянных разрешений: \(model.snapshot?.permissions?.tools.count ?? 0). Остальные действия требуют подтверждения.").font(.caption)
                        Button("Сбросить постоянные разрешения") { model.perform { _ = try await model.api("/permissions/reset", [:]); try await model.refresh() } }
                        Text("Сброс действует на следующие действия. Уже запущенные действия не отменяются.").font(.caption)
                        Divider()
                        Toggle("Отправлять по Enter (Shift+Enter — новая строка)",isOn:$enterSends)
                        Text("Если выключено: Enter — новая строка, ⌘Enter — отправка.").font(.caption)
                        Toggle("Ограничивать нагрузку локальной модели при перегреве",isOn:$thermalEnabled)
                        Text("Порог: \(Int(thermalLimit)) °C")
                        Slider(value:$thermalLimit,in:45...100,step:1).disabled(!thermalEnabled || (model.snapshot?.thermal?.cpu == nil && model.snapshot?.thermal?.gpu == nil))
                        Text("При достижении порога встроенный движок получает 50% рабочего времени. Возврат — после охлаждения на 3 °C. Без доступных датчиков используется системный статус перегрева macOS; порог в градусах тогда недоступен. Облачная модель не ограничивается.").font(.caption)
                        Divider()
                        Button("Показать / скрыть браузер") { model.showBrowser.toggle(); model.settingsShown=false }
                        Button("Открыть папку файлов проекта") { if let path=model.project?.workspace { NSWorkspace.shared.open(URL(fileURLWithPath:path)) } }
                    }.frame(maxWidth:.infinity,alignment:.leading).toggleStyle(.checkbox).padding() }
                } else if settingsTab == 5 {
                    ExploreView(model:model, embedded:true)
                } else {
                    VStack(alignment:.leading,spacing:20) {
                        Text("Экспорт и бэкап").font(.headline)
                        Text("Архив содержит переписки, профили, память и файлы. Ключи, cookies и веса моделей не включаются.")
                        Button("Экспортировать ZIP / создать бэкап",action:model.export)
                        Button("Восстановить из ZIP",action:model.restore).disabled(model.running)
                        Spacer()
                    }.padding()
                } }.frame(maxHeight:.infinity)
            }
            HStack { Button("Сохранить и закрыть") { save(fetch:false, close:true) }; Spacer(); Button("Сохранить",action: { save(fetch: false) }).disabled(model.running) }
        }.padding(24).frame(width: 1000,height: 720).modifier(AppTheme()).tint(.gray).accentColor(.gray).buttonStyle(MonochromeButton()).interactiveDismissDisabled()
        .onAppear {
            if let s = model.snapshot?.settings { imageEnabled=s.imageEnabled ?? false; imageBase=s.imageBaseURL ?? ""; imageModel=s.imageModel ?? ""; thermalEnabled=s.thermalEnabled ?? false; thermalLimit=s.thermalLimit ?? 80; mode=s.mode; provider=s.provider; base=s.baseURL; selectedModel=s.model; limit=s.contextLimit; temperature=s.temperature; toolsEnabled=s.toolsEnabled;searchProvider=s.searchProvider ?? "brave" }
            imageKey=Keys.get("image"); modelKey=Keys.get("model"); braveKey=Keys.get("brave");tavilyKey=Keys.get("tavily");serperKey=Keys.get("serper")
            profileID=model.chat?.profileID ?? model.snapshot?.profiles.first?.id ?? ""; loadProfile(profileID)
        }
        .disabled(model.running)
    }
    func loadProfile(_ id: String) {
        if id.isEmpty { profileName=""; prompt="" }
        else if let p=model.snapshot?.profiles.first(where: { $0.id == id }) { profileName=p.name; prompt=p.prompt }
    }
    func browseModel() {
        let panel=NSOpenPanel(); panel.allowedContentTypes=[UTType(filenameExtension:"gguf") ?? .data]; panel.allowsMultipleSelection=false; panel.canChooseDirectories=false
        if panel.runModal() == .OK, let url=panel.url { selectedModel=url.path; provider="local"; if mode == "cloud" { mode="offline" }; save(fetch:false,load:true) }
    }
    func save(fetch: Bool, load: Bool = false, close: Bool = false) {
        model.perform {
            _ = try await model.api("/settings", ["imageEnabled":imageEnabled,"imageBaseURL":imageBase,"imageModel":imageModel,"thermalEnabled":thermalEnabled,"thermalLimit":thermalLimit,"mode":mode,"provider":provider,"baseURL":base,"model":selectedModel,"contextLimit":limit,"temperature":temperature,"toolsEnabled":toolsEnabled,"searchProvider":searchProvider])
            try Keys.set("image",imageKey); try Keys.set("model",modelKey); try Keys.set("brave",braveKey);try Keys.set("tavily",tavilyKey);try Keys.set("serper",serperKey)
            _ = try await model.api("/keys", ["image":imageKey,"model":modelKey,"brave":braveKey,"tavily":tavilyKey,"serper":serperKey])
            if !profileName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                let r = try await model.api("/profile",["id":profileID,"name":profileName,"prompt":prompt])
                if let id=r["id"] as? String { profileID=id }
            }
            if load { _ = try await model.api("/local/load",["path":selectedModel]) }
            if close { model.settingsShown=false }
            if fetch { let r=try await model.api("/models"); models=r["models"] as? [String] ?? []; notice="Получено моделей: \(models.count)" }
            else { notice="Настройки сохранены" }
        }
    }
}
struct InspectorView: View {
    @ObservedObject var model: AppModel
    var embedded = false
    @State var memory = ""
    @State private var inspectorTab = 0
    var body: some View {
        VStack(alignment: .leading) {
            Text(model.project?.name ?? "Проект").font(.title)
            VStack(spacing:8) {
                HStack {
                    ForEach(Array(["Скиллы","Память и файлы","Журнал"].enumerated()),id: \.offset) { index,title in
                        Button(title) { inspectorTab=index }.background(inspectorTab == index ? Color.primary.opacity(0.15) : Color.clear).clipShape(RoundedRectangle(cornerRadius:7))
                    }
                }
                Group { if inspectorTab == 0 {
                VStack(alignment: .leading,spacing: 10) {
                    HStack { Button("Импортировать скилл",action: model.importSkill); Spacer(); Text("Активные скиллы — только для текущего чата").font(.caption) }
                    List(model.project?.skills ?? []) { skill in
                        VStack(alignment: .leading,spacing: 5) {
                            Toggle(skill.name,isOn: Binding(get: { model.chat?.skillIDs.contains(skill.id) ?? false },set: { _ in model.toggleSkill(skill.id) }))
                            Text(skill.description).font(.caption)
                            Text(skill.dependencies.map { "\($0.name): \($0.available ? "найден" : "нет")" }.joined(separator: "; ")).font(.caption)
                            if !skill.requiredKeys.isEmpty { Text("Упомянутые ключи: "+skill.requiredKeys.joined(separator: ", ")).font(.caption) }
                            Text(skill.dependencyNotice).font(.caption).foregroundStyle(.secondary)
                            Button("Убрать из библиотеки") { model.perform { _ = try await model.api("/skill/remove", ["projectID":model.projectID,"id":skill.id]) } }.font(.caption)
                        }.padding(.vertical,5)
                    }
                }.padding() } else if inspectorTab == 1 {
                VStack(alignment: .leading) {
                    Text("Память редактируется вручную. Модель не записывает сюда факты сама.").font(.caption)
                    TextEditor(text: $memory)
                    Button("Сохранить память") { model.perform { _ = try await model.api("/project/update", ["projectID":model.projectID,"memory":memory]) } }
                    Divider(); Text("Папка для файловых инструментов:").bold(); Text(model.project?.workspace ?? "").textSelection(.enabled)
                    Button("Выбрать папку…",action: model.chooseWorkspace)
                    Text("Поиск пока буквальный по текстовым файлам; не RAG. PDF/картинки прикрепляй к сообщению для извлечения текста.").font(.caption)
                }.padding() } else {
                ScrollView {
                    VStack(alignment: .leading,spacing: 8) {
                        ForEach(Array((model.project?.log ?? []).reversed().enumerated()),id: \.offset) { _,entry in
                            Text("\(entry.time) · \(entry.event)\n\(entry.detail)").font(.system(.caption,design: .monospaced)).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity,alignment: .leading)
                }.padding() } }.frame(maxHeight:.infinity)
            }
            if !embedded { Button("Закрыть") { model.inspectorShown=false } }
        }.padding(20).frame(width: embedded ? nil : 740,height: embedded ? nil : 600).modifier(AppTheme()).tint(.gray).accentColor(.gray).buttonStyle(MonochromeButton()).onAppear { memory=model.project?.memory ?? "" }.disabled(model.running)
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    var mainWindow: NSWindow?
    func applicationDidFinishLaunching(_ notification:Notification) {
        NSApp.appearance=NSAppearance(named: UserDefaults.standard.string(forKey:"appearanceTheme") == "light" ? .aqua : .darkAqua)
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps:true)
        // LaunchServices may restore a previously closed SwiftUI WindowGroup with
        // no window, so its view task never runs. Ensure a usable window exists.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
                self.mainWindow = window
                window.makeKeyAndOrderFront(nil)
            } else {
                let appModel = self.model ?? AppModel()
                self.model = appModel
                let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1100,height:760), styleMask:[.titled,.closable,.miniaturizable,.resizable], backing:.buffered, defer:false)
                window.title="Inij"; window.isReleasedWhenClosed=false
                window.contentView=NSHostingView(rootView:MainView().environmentObject(appModel))
                window.center(); self.mainWindow=window; window.makeKeyAndOrderFront(nil)
                await appModel.start()
                if let flag=CommandLine.arguments.firstIndex(of:"--smoke-test"), CommandLine.arguments.count > flag+1 {
                    await runNativeSmoke(model:appModel,delegate:self,reportPath:CommandLine.arguments[flag+1])
                }
            }
            NSApp.activate(ignoringOtherApps:true)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool) -> Bool {
        if !hasVisibleWindows { (mainWindow ?? sender.windows.first(where:{$0.canBecomeMain}))?.makeKeyAndOrderFront(nil) }
        sender.activate(ignoringOtherApps:true);return true
    }
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
}
@main @MainActor struct PersonalAssistantApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("Inij") {
            MainView().environmentObject(model).task { delegate.model=model;delegate.mainWindow=NSApp.windows.first(where:{$0.canBecomeMain});delegate.mainWindow?.isReleasedWhenClosed=false; if model.port==0 { await model.start() }
                if let flag = CommandLine.arguments.firstIndex(of: "--smoke-test"), CommandLine.arguments.count > flag + 1 {
                    await runNativeSmoke(model: model, delegate: delegate, reportPath: CommandLine.arguments[flag + 1])
                }
            }
        }.windowResizability(.contentMinSize).defaultSize(width:1100,height:760).commands { CommandGroup(replacing: .newItem) { Button("Новый чат",action:model.newChat).keyboardShortcut("n"); Button("Настройки") { model.settingsShown=true }.keyboardShortcut(",") } }
    }
}

struct CatalogModel: Identifiable { let id: String; let downloads: Int }
struct CatalogFile: Identifiable { let name: String; let size: Int64; var id: String { name } }
struct LocalLibraryModel: Identifiable { let path: String; let name: String; let size: Int64; var id: String { path } }
struct ExploreView: View {
    @ObservedObject var model: AppModel
    var embedded = false
    @State private var query = ""
    @State private var results: [CatalogModel] = []
    @State private var files: [CatalogFile] = []
    @State private var library: [LocalLibraryModel] = []
    @State private var repo = ""
    @State private var busy = false
    @State private var notice = ""
    @State private var tab = 0
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack { Text("Explore · модели").font(.title2); Spacer(); if !embedded { Button("Закрыть") { model.exploreShown=false } } }
            VStack(spacing:8) {
                HStack {
                    ForEach(Array(["Поиск","Библиотека","Загрузки"].enumerated()),id: \.offset) { index,title in
                        Button(title) { tab=index }.background(tab == index ? Color.primary.opacity(0.15) : Color.clear).clipShape(RoundedRectangle(cornerRadius:7))
                    }
                }
                Group { if tab == 0 {
                VStack(alignment:.leading,spacing:10) {
                    HStack { TextField("Поиск моделей в Hugging Face",text:$query).onSubmit(search); Button("Найти",action:search).disabled(busy) }
                    Text("Поиск и скачивание используют интернет. Сам чат с загруженной моделью может работать офлайн.").font(.caption).foregroundStyle(.secondary)
                    HStack(alignment:.top,spacing:12) {
                        List(results) { item in
                            Button { select(item.id) } label: {
                                VStack(alignment:.leading) { Text(item.id).lineLimit(2).truncationMode(.middle); Text("Загрузок: \(item.downloads)").font(.caption).foregroundStyle(.secondary) }.frame(maxWidth:.infinity,alignment:.leading)
                            }.buttonStyle(.plain)
                        }.frame(width:250)
                        VStack(alignment:.leading,spacing:8) {
                            Text(repo.isEmpty ? "Выбери модель слева" : repo).font(.headline).lineLimit(2)
                            Text("Варианты GGUF · размер файла не равен расходу памяти").font(.caption)
                            List(files) { file in
                                VStack(alignment:.leading,spacing:6) {
                                    Text(file.name).lineLimit(3).truncationMode(.middle).font(.callout)
                                    Text(size(file.size) + " · " + fit(file.size)).font(.caption).foregroundStyle(.secondary)
                                    Button("Скачать") { download(file) }.disabled(busy)
                                }.padding(.vertical,4)
                            }
                            Text("Совместимость архитектуры и инструментов проверяется при загрузке/работе. Каталог не гарантирует её по названию файла.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.padding(12) } else if tab == 1 {
                VStack(alignment:.leading) {
                    HStack { Button("Обновить библиотеку",action:loadLibrary); Spacer(); Button("Открыть GGUF…",action:browse) }
                    List(library) { item in
                        VStack(alignment:.leading,spacing:6) {
                            Text(item.name).lineLimit(2).truncationMode(.middle)
                            HStack { Text(size(item.size)).font(.caption); Spacer(); Button("Выбрать и загрузить") { load(item.path) }.disabled(model.running) }
                        }.padding(.vertical,4)
                    }
                }.padding(12) } else {
                List(model.snapshot?.downloads ?? []) { d in
                    VStack(alignment:.leading,spacing:8) {
                        Text(d.file).lineLimit(2).truncationMode(.middle)
                        ProgressView(value:Double(d.bytes),total:Double(max(d.total,d.bytes,1)))
                        Text("\(size(d.bytes)) / \(size(d.total)) · \(status(d.status))").font(.caption)
                        if !d.error.isEmpty { Text(d.error).font(.caption).textSelection(.enabled) }
                        HStack {
                            if d.status == "downloading" { Button("Пауза") { control(d.id,"pause") } }
                            if ["paused","error","cancelled"].contains(d.status) { Button("Продолжить") { control(d.id,"resume") } }
                            if d.status == "complete" { Button("Загрузить модель") { load(d.path) }.disabled(model.running) }
                            else if d.status != "verifying" { Button("Отменить") { control(d.id,"cancel") } }
                        }
                    }.padding(.vertical,6)
                }.padding(12) } }.frame(maxHeight:.infinity)
            }
            if busy { ProgressView().controlSize(.small) }
            Text(notice).font(.caption).lineLimit(3).textSelection(.enabled)
        }.padding(24).frame(width:embedded ? nil : 850,height:embedded ? nil : 650).modifier(AppTheme()).tint(.gray).accentColor(.gray).buttonStyle(MonochromeButton())
        .onAppear(perform:loadLibrary).onChange(of:tab) { value in if value == 1 { loadLibrary() } }
    }
    func size(_ n:Int64)->String { ByteCountFormatter.string(fromByteCount:n,countStyle:.file) }
    func fit(_ n:Int64)->String {
        let ram=Int64(ProcessInfo.processInfo.physicalMemory)
        if n == 0 { return "размер неизвестен" }
        return n > ram * 7 / 10 ? "мало запаса RAM; выбери меньше" : "есть запас RAM; контекст потребует дополнительную память"
    }
    func status(_ s:String)->String { ["downloading":"скачивание","paused":"пауза","error":"ошибка","complete":"готово","verifying":"проверка файла","cancelled":"отменено","cancelling":"отмена"][s] ?? s }
    func search() {
        busy=true; notice=""
        Task { defer { busy=false }; do {
            let r=try await model.api("/explore/search",["query":query]); results=(r["models"] as? [[String:Any]] ?? []).compactMap { v in guard let id=v["id"] as? String else{return nil};return CatalogModel(id:id,downloads:v["downloads"] as? Int ?? 0) }
            if results.isEmpty { notice="Модели не найдены" }
        } catch { notice=error.localizedDescription } }
    }
    func select(_ id:String) {
        repo=id; files=[]; busy=true; notice=""
        Task { defer { busy=false }; do {
            let r=try await model.api("/explore/files",["repo":id]); if repo != id { return }
            files=(r["files"] as? [[String:Any]] ?? []).compactMap { v in guard let name=v["name"] as? String else{return nil}; return CatalogFile(name:name,size:(v["size"] as? NSNumber)?.int64Value ?? 0) }
        } catch { notice=error.localizedDescription } }
    }
    func download(_ file:CatalogFile) {
        busy=true; Task { defer { busy=false }; do { _ = try await model.api("/downloads/start",["repo":repo,"file":file.name]);try await model.refresh();tab=2 } catch { notice=error.localizedDescription } }
    }
    func control(_ id:String,_ action:String) { model.perform { _ = try await model.api("/downloads/control",["id":id,"action":action]) } }
    func loadLibrary() { Task { do {
        let r=try await model.api("/local/library");library=(r["models"] as? [[String:Any]] ?? []).compactMap { v in guard let path=v["path"] as? String else{return nil};return LocalLibraryModel(path:path,name:v["name"] as? String ?? path,size:(v["size"] as? NSNumber)?.int64Value ?? 0) }
    } catch { notice=error.localizedDescription } } }
    func load(_ path:String) { Task { do { _ = try await model.api("/local/load",["path":path]);try await model.refresh();model.exploreShown=false } catch { notice=error.localizedDescription } } }
    func browse() { let p=NSOpenPanel();p.allowedContentTypes=[UTType(filenameExtension:"gguf") ?? .data];p.canChooseDirectories=false;p.allowsMultipleSelection=false;if p.runModal() == .OK,let u=p.url{load(u.path)} }
}

struct ModelPickerPopup: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    @State private var choices: [String] = []
    var previewChoices: [String] = []
    @State private var notice = ""
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Выбор модели").font(.headline)
            Text(currentModelName).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle)
                .help(model.snapshot?.settings.model ?? "")
                .fixedSize(horizontal:false, vertical:true)
            ScrollView {
                VStack(alignment:.leading,spacing:8) {
                    ForEach(choices,id: \.self) { path in
                        Button { select(path) } label: {
                            HStack(alignment:.top, spacing:8) {
                                Text(displayName(path)).lineLimit(2).truncationMode(.middle)
                                    .multilineTextAlignment(.leading).fixedSize(horizontal:false, vertical:true)
                                Spacer(minLength:0)
                                if path == model.snapshot?.settings.model { Image(systemName:"checkmark") }
                            }.frame(maxWidth:.infinity, minHeight:32, alignment:.leading)
                        }.help(path)
                    }
                }
            }.frame(height:220)
            if model.snapshot?.settings.provider == "local" { Button("Открыть GGUF…",action:browse) }
            if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false, vertical:true) }
            HStack {
                Button("Настройки модели") { isPresented=false; model.settingsShown=true }
                Spacer(); Button("Закрыть") { isPresented=false }
            }
        }.padding(18).frame(width:460).fixedSize(horizontal:false, vertical:true).buttonStyle(MonochromeButton())
        .task {
            if !previewChoices.isEmpty { choices=previewChoices; return }
            do {
                if model.snapshot?.settings.provider == "local" {
                    let data=try await model.api("/local/library")
                    choices=(data["models"] as? [[String:Any]] ?? []).compactMap { $0["path"] as? String }
                } else {
                    let data=try await model.api("/models"); choices=data["models"] as? [String] ?? []
                }
                if choices.isEmpty { notice="В библиотеке нет моделей. Выбери файл или открой Explore в настройках." }
            } catch { notice=error.localizedDescription }
        }
    }
    func displayName(_ value:String) -> String {
        model.snapshot?.settings.provider == "local" ? URL(fileURLWithPath:value).lastPathComponent : value
    }
    var currentModelName: String {
        guard let value=model.snapshot?.settings.model, !value.isEmpty else { return "Не выбрана" }
        return displayName(value)
    }
    func select(_ path:String) {
        model.perform {
            if model.snapshot?.settings.provider == "local" { _ = try await model.api("/local/load",["path":path]) }
            else { _ = try await model.api("/settings",["model":path]) }
            isPresented=false
        }
    }
    func browse() {
        let panel=NSOpenPanel(); panel.allowedContentTypes=[UTType(filenameExtension:"gguf") ?? .data]
        if panel.runModal() == .OK, let url=panel.url { select(url.path) }
    }
}
