import SwiftUI
import AppKit
import WebKit
import Security
import PDFKit
import Vision
import UniformTypeIdentifiers

func L(_ russian: String, _ english: String) -> String { Locale.preferredLanguages.first?.lowercased().hasPrefix("ru") == true ? russian : english }

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

// A deliberately small, offline block renderer. Raw HTML stays inert text.
enum MarkdownBlock: Equatable {
    case text(String), heading(Int, String), code(String, String), quote(String), table([[String]]), rule
}
enum MarkdownBlocks {
    static func cells(_ line: String) -> [String] {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }
        return value.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
    static func separator(_ line: String) -> Bool {
        let parts = cells(line)
        return line.contains("|") && !parts.isEmpty && parts.allSatisfy {
            let value = $0.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return value.count >= 3 && value.allSatisfy { $0 == "-" }
        }
    }
    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.components(separatedBy: "\n")
        var result: [MarkdownBlock] = []; var i = 0
        while i < lines.count {
            let line = lines[i]; let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                let language = String(trimmed.dropFirst(3)); i += 1; var body: [String] = []
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") { body.append(lines[i]); i += 1 }
                result.append(.code(language, body.joined(separator: "\n"))); i += 1; continue
            }
            if i + 1 < lines.count && line.contains("|") && separator(lines[i+1]) {
                var rows = [cells(line)]; i += 2
                while i < lines.count && lines[i].contains("|") && !lines[i].trimmingCharacters(in: .whitespaces).isEmpty { rows.append(cells(lines[i])); i += 1 }
                result.append(.table(rows)); continue
            }
            let hashes = trimmed.prefix { $0 == "#" }.count
            if (1...6).contains(hashes) && trimmed.dropFirst(hashes).hasPrefix(" ") {
                result.append(.heading(hashes, String(trimmed.dropFirst(hashes+1))))
            } else if trimmed.hasPrefix(">") {
                result.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else if ["---", "***", "___"].contains(trimmed) { result.append(.rule) }
            else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") { result.append(.text("• " + trimmed.dropFirst(2))) }
            else { result.append(.text(line)) }
            i += 1
        }
        return result
    }
}
final class QuoteTextView: NSTextView {
    var quoteAction: ((String) -> Void)?
    var wholeMessage = ""
    var lastFontSize = 0.0
    var actionText: String {
        let range = selectedRange()
        return range.length > 0 ? (string as NSString).substring(with:range) : wholeMessage
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu=NSMenu()
        let quote=NSMenuItem(title:L("Цитировать", "Quote"),action:#selector(quoteSelection),keyEquivalent:"");quote.target=self;menu.addItem(quote)
        let copy=NSMenuItem(title:L("Копировать", "Copy"),action:#selector(copySelection),keyEquivalent:"");copy.target=self;menu.addItem(copy)
        return menu
    }
    @objc func quoteSelection() { quoteAction?(actionText) }
    @objc func copySelection() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(actionText,forType:.string) }
}
struct SelectableMessageText: NSViewRepresentable {
    let content: String; let wholeMessage: String; let fontSize: Double; var quote: ((String) -> Void)?; var verbatim = false
    func makeNSView(context:Context) -> QuoteTextView {
        let v=QuoteTextView();v.isEditable=false;v.isSelectable=true;v.drawsBackground=false
        v.textContainerInset = .zero;v.textContainer?.lineFragmentPadding=0
        v.isVerticallyResizable=true;v.isHorizontallyResizable=false;v.textContainer?.widthTracksTextView=true
        return v
    }
    func updateNSView(_ view:QuoteTextView,context:Context) {
        view.quoteAction=quote;view.wholeMessage=wholeMessage
        let display = verbatim ? NSAttributedString(string:content) : NSAttributedString(ChatMarkdown.render(content))
        if view.string != display.string || view.lastFontSize != fontSize {
            view.lastFontSize=fontSize
            let value=NSMutableAttributedString(attributedString:display)
            value.addAttributes([.font:(verbatim ? NSFont.monospacedSystemFont(ofSize:fontSize,weight:.regular) : NSFont.systemFont(ofSize:fontSize)),.foregroundColor:NSColor.labelColor],range:NSRange(location:0,length:value.length))
            view.textStorage?.setAttributedString(value)
        }
    }
    func sizeThatFits(_ proposal:ProposedViewSize,nsView:QuoteTextView,context:Context) -> CGSize? {
        let width=max(50,proposal.width ?? 600)
        nsView.textContainer?.containerSize=NSSize(width:width,height:CGFloat.greatestFiniteMagnitude)
        guard let container=nsView.textContainer,let layout=nsView.layoutManager else { return nil }
        layout.ensureLayout(for:container)
        return CGSize(width:width,height:max(fontSize+4,ceil(layout.usedRect(for:container).height)))
    }
}

struct ChatMessageText: View {
    let content: String
    var quote: ((String) -> Void)? = nil
    var quoteWhole: String? = nil
    @AppStorage("chatFontSize") private var fontSize = 14.0
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(MarkdownBlocks.parse(content).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }.font(.system(size: fontSize)).tint(.accentColor).textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in ChatMarkdown.safeURL(url) ? .systemAction : .discarded })
    }
    @ViewBuilder func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .text(let text): SelectableMessageText(content: text.isEmpty ? " " : text, wholeMessage: quoteWhole ?? content, fontSize: fontSize, quote: quote)
        case .heading(let level, let text): SelectableMessageText(content:text,wholeMessage:quoteWhole ?? content,fontSize:fontSize+Double(7-level),quote:quote).padding(.top,4)
        case .quote(let text): HStack { Rectangle().fill(Color.secondary).frame(width: 3); SelectableMessageText(content:text,wholeMessage:quoteWhole ?? content,fontSize:fontSize,quote:quote) }.fixedSize(horizontal: false, vertical: true).padding(.leading, 6)
        case .rule: Divider().padding(.vertical, 4)
        case .code(let language, let code):
            VStack(alignment: .leading, spacing: 4) {
                HStack { Text(language.isEmpty ? L("Код", "Code") : language).font(.caption); Spacer(); Button(L("Копировать", "Copy")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string) }.font(.caption) }
                ScrollView(.horizontal) { SelectableMessageText(content:code,wholeMessage:quoteWhole ?? content,fontSize:fontSize,quote:quote,verbatim:true).frame(minWidth:400) }
            }.padding(10).background(Color.primary.opacity(0.06)).cornerRadius(6)
        case .table(let rows):
            ScrollView(.horizontal) {
                Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                        GridRow {
                            ForEach(0..<(rows.map { $0.count }.max() ?? 0), id: \.self) { column in
                                SelectableMessageText(content:column < row.count ? row[column] : "",wholeMessage:quoteWhole ?? content,fontSize:fontSize,quote:quote)
                                    .fontWeight(rowIndex == 0 ? .semibold : .regular)
                                    .frame(minWidth: 90, maxWidth: 260, alignment: .leading).padding(7)
                                    .background(Color.primary.opacity(rowIndex == 0 ? 0.1 : 0.03))
                                    .border(Color.secondary.opacity(0.25), width: 0.5)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct ComposerAttachment: Codable, Identifiable {
    var id: String
    var name: String
    var text: String
}

// Isolated suite in smoke tests; production drafts persist across restarts.
final class DraftStore {
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func key(_ project: String, _ chat: String) -> String { "chatDraft." + project + "." + chat }
    func attachments(_ project: String, _ chat: String) -> [ComposerAttachment] {
        guard let data = defaults.data(forKey: key(project,chat)+".attachments") else { return [] }
        return (try? JSONDecoder().decode([ComposerAttachment].self, from:data)) ?? []
    }
    func writeAttachments(_ value: [ComposerAttachment], _ project: String, _ chat: String) {
        guard !project.isEmpty && !chat.isEmpty else { return }
        if value.isEmpty { defaults.removeObject(forKey:key(project,chat)+".attachments") }
        else if let data = try? JSONEncoder().encode(value) { defaults.set(data,forKey:key(project,chat)+".attachments") }
    }
    func read(_ project: String, _ chat: String) -> String { defaults.string(forKey: key(project,chat)) ?? "" }
    func write(_ value: String, _ project: String, _ chat: String) {
        guard !project.isEmpty && !chat.isEmpty else { return }
        if value.isEmpty { defaults.removeObject(forKey: key(project,chat)) }
        else { defaults.set(value, forKey: key(project,chat)) }
    }
}

enum ChatTranscript {
    static func attributed(title: String, messages: [ChatMessage], size: Double) -> NSAttributedString {
        let out = NSMutableAttributedString(string: title + "\n\n", attributes: [.font: NSFont.boldSystemFont(ofSize: size+5), .foregroundColor: NSColor.black])
        for message in messages where message.role != "tool" {
            out.append(NSAttributedString(string: (message.role == "user" ? L("Ты", "You") : "inij") + "\n", attributes: [.font: NSFont.boldSystemFont(ofSize: size), .foregroundColor: NSColor.black]))
            for block in MarkdownBlocks.parse(message.quoteText) {
                var text = ""; var font = NSFont.systemFont(ofSize: size)
                switch block {
                case .text(let value), .quote(let value): text = value
                case .heading(let level, let value): text = value; font = .boldSystemFont(ofSize: size+Double(7-level))
                case .code(_, let value): text = value; font = .monospacedSystemFont(ofSize: size, weight: .regular)
                case .table(let rows): text = rows.map { $0.joined(separator: "  |  ") }.joined(separator: "\n"); font = .monospacedSystemFont(ofSize: size, weight: .regular)
                case .rule: text = "────────────────────────"
                }
                out.append(NSAttributedString(string: text + "\n", attributes: [.font: font, .foregroundColor: NSColor.black]))
            }
            out.append(NSAttributedString(string: "\n"))
        }
        return out
    }
    @MainActor static func textView(title: String, messages: [ChatMessage], size: Double) -> NSTextView {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 515, height: 720))
        view.textContainer?.containerSize = NSSize(width: 515, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.backgroundColor = .white; view.textColor = .black
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.textStorage?.setAttributedString(attributed(title: title, messages: messages, size: size))
        view.sizeToFit()
        return view
    }
}

struct Settings: Codable {
    var imageEnabled: Bool?; var imageBaseURL: String?; var imageModel: String?
    var imageProvider: String?; var imageLocalModel: String?; var imageCompute: String?
    var imageWidth: Int?; var imageHeight: Int?; var imageSteps: Int?; var imageCFG: Double?
    var mode: String; var provider: String; var baseURL: String; var model: String
    var thermalEnabled: Bool?; var thermalLimit: Double?
    var serverContextLimit: Int?; var contextLimit: Int; var temperature: Double; var toolsEnabled: Bool; var searchProvider: String?
}
struct ProfileVersion: Codable, Identifiable { var id: String; var time: String; var name: String; var prompt: String }
struct Profile: Codable, Identifiable { var id: String; var name: String; var prompt: String; var versions: [ProfileVersion]? }
struct MCPServer: Codable, Identifiable { var id: String; var name: String; var command: String; var args: [String]; var enabled: Bool }
struct Artifact: Codable { var name: String; var path: String; var bytes: Int64 }
struct ChatMessage: Codable {
    var artifacts: [Artifact]?; var role: String; var content: String; var streaming: Bool?
    var reasoning: String?
    var displayText: String?; var attachments: [ComposerAttachment]?
    var visibleText: String { role == "user" ? (displayText ?? content) : content }
    var quoteText: String { visibleText + (attachments ?? []).map { L("\n[Файл: \($0.name)]", "\n[File: \($0.name)]") }.joined() }
}
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
    var detail: String?
    var progress: String?
    var id: String; var projectID: String; var chatID: String; var status: String; var error: String; var newChatID: String?
}
struct Pending: Codable, Identifiable {
    var id: String; var projectID: String; var kind: String; var tool: String?
    var oneTimeOnly: Bool?
    var arguments: [String: JSONValue]?; var workspace: String?; var action: String?; var url: String?
}
struct LocalModelState: Codable { var status: String; var path: String; var error: String }
struct ModelDownload: Codable, Identifiable { var id: String; var repo: String; var file: String; var status: String; var bytes: Int64; var total: Int64; var path: String; var error: String }
struct Usage: Codable { var inputTokens: Int; var outputTokens: Int; var reportedRequests: Int; var missingRequests: Int; var sentBytes: Int; var receivedBytes: Int; var networkRequests: Int? }
struct EngineMetrics: Codable { var firstTextSeconds: Double?; var requestSeconds: Double?; var outputTokens: Int?; var tokensPerSecond: Double?; var rateBasis: String? }
struct EngineState: Codable { var status: String; var error: String?; var loadSeconds: Double? }
struct EngineSnapshot: Codable { var provider: String; var model: String; var state: EngineState; var metrics: EngineMetrics; var rssBytes: Int64?; var canLoad: Bool; var canUnload: Bool }
struct Thermal: Codable { var cpu: Double?; var gpu: Double?; var state: Int; var limited: Bool }
struct Permissions: Codable { var all: Bool; var tools: [String] }
struct Snapshot: Codable {
    var projectsRoot: String?
    var contextBudget: [String: JSONValue]?
    var permissions: Permissions?
    var usage: Usage?; var thermal: Thermal?; var engine: EngineSnapshot?
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
        guard status == errSecSuccess else { throw AppError(message: L("Связка ключей: код \(status)", "Keychain: code \(status)")) }
    }
}

@MainActor final class Browser: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var address = "https://www.google.com"
    @Published var enabled = false
    @Published var status = L("Интернет выключен", "Internet is off")
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
            webView.stopLoading(); webView.loadHTMLString(L("<p>Интернет выключен</p>", "<p>Internet is off</p>"), baseURL: nil)
            finish(AppError(message: L("Интернет выключен", "Internet is off")))
        }
        enabled = value; status = value ? L("Браузер готов", "Browser ready") : L("Интернет выключен", "Internet is off")
    }
    func finish(_ error: Error? = nil) {
        timeout?.cancel(); timeout = nil
        guard let continuation = navigationContinuation else { return }
        navigationContinuation = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
    func open(_ value: String) async throws {
        guard enabled else { throw AppError(message: L("Интернет выключен", "Internet is off")) }
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil else { throw AppError(message: L("Нужен http(s) адрес без пароля", "An http(s) address without a password is required")) }
        finish(AppError(message: L("Начат другой переход", "Another navigation started"))); address = value; status = L("Загрузка…", "Loading…")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            navigationContinuation = continuation
            webView.load(URLRequest(url: url))
            timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                self?.webView.stopLoading(); self?.finish(AppError(message: L("Страница не загрузилась за 30 секунд", "Page did not load within 30 seconds")))
            }
        }
    }
    func read() async throws -> [String: Any] {
        guard enabled else { throw AppError(message: L("Интернет выключен", "Internet is off")) }
        pageRevision = UUID().uuidString
        let script = """
        window.__assistantElements=Array.from(document.querySelectorAll('a[href],button,input:not([type=password]):not([type=hidden]),textarea,select')).filter(e=>e.getClientRects().length).slice(0,120);
        JSON.stringify({url:location.href,title:document.title,text:(document.body?.innerText||'').slice(0,24000),truncated:(document.body?.innerText||'').length>24000,elements:window.__assistantElements.map((e,i)=>({ref:String(i),tag:e.tagName,type:e.type||'',text:(e.innerText||e.getAttribute('aria-label')||e.getAttribute('placeholder')||'').slice(0,120)})),links:Array.from(document.querySelectorAll('a[href]')).filter(a=>/^https?:/.test(a.href)).slice(0,80).map(a=>({text:(a.innerText||'').slice(0,180),url:a.href}))})
        """
        let value = try await webView.evaluateJavaScript(script)
        guard let text = value as? String, let data = text.data(using: .utf8),
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError(message: L("Не удалось прочитать страницу", "Could not read the page"))
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
        guard enabled, let ref = arguments["ref"]?.text, let index = observedElements[ref], Int(index) != nil else { throw AppError(message:L("Ссылка на элемент устарела: прочитай страницу снова", "Stale element reference: read the page again")) }
        let text = arguments["text"]?.text ?? ""
        let encoded = String(data:try JSONSerialization.data(withJSONObject:[text]),encoding:.utf8)!
        let operation = action == "browser_fill" ? "if(!['INPUT','TEXTAREA'].includes(e.tagName)||['password','file','hidden'].includes(e.type))throw Error('Это поле нельзя заполнять');e.value=\(encoded)[0];e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));" : "e.click();"
        _ = try await webView.evaluateJavaScript("(()=>{const e=window.__assistantElements?.[\(index)];if(!e||!e.isConnected)throw Error('Элемент исчез');\(operation)return true;})()")
        observedElements = [:]
        try await Task.sleep(nanoseconds:500_000_000)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { observedElements = [:] }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        observedElements = [:]; address = webView.url?.absoluteString ?? address; status = L("Страница загружена", "Page loaded"); finish()
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
    @Published var projectID = "" { didSet { selectDraft() } }
    @Published var chatID = "" { didSet { selectDraft() } }
    @Published var draft = "" { didSet { draftStore.write(draft, projectID, chatID) } }
    let draftStore = DraftStore(defaults: CommandLine.arguments.contains("--smoke-test") ? UserDefaults(suiteName: "Inij-Smoke-Drafts")! : .standard)
    @Published var attachments: [ComposerAttachment] = [] {
        didSet { draftStore.writeAttachments(attachments,projectID,chatID) }
    }
    @Published var importingFiles = 0
    @Published var sending = false
    var canSend: Bool { snapshot != nil && !chatBusy && !sending && importingFiles == 0 && (!draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || !attachments.isEmpty) }
    func selectDraft() {
        draft = draftStore.read(projectID, chatID)
        attachments = draftStore.attachments(projectID,chatID)
    }
    @Published var error = ""
    @Published var startup = L("Запуск локального сервиса…", "Starting local service…")
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
    var running: Bool { snapshot?.jobs.contains { $0.status == "running" || $0.status == "queued" } ?? false }
    var chatBusy: Bool { snapshot?.jobs.contains { $0.chatID == chatID && ($0.status == "running" || $0.status == "queued") } ?? false }
    func cancelJob(_ id: String) { perform { _ = try await self.api("/stop",["id":id]) } }
    var approval: Pending? { snapshot?.pending.first { $0.kind == "approval" } }
    func start() async {
        guard !starting, port == 0 else { return }; starting = true
        defer { starting = false }
        do {
            guard let resources = Bundle.main.resourceURL else { throw AppError(message: L("Нет Resources", "Resources missing")) }
            let script = resources.appendingPathComponent("backend/server.py")
            let support = CommandLine.arguments.contains("--smoke-test") ? FileManager.default.temporaryDirectory.appendingPathComponent("Inij-Smoke-" + UUID().uuidString) : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Inij")
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let python = resources.appendingPathComponent("python/bin/python3")
            guard FileManager.default.isExecutableFile(atPath:python.path) else { throw AppError(message:L("В приложении отсутствует встроенный движок. Установи полный .app из дистрибутива.", "The bundled engine is missing. Install the complete .app from the distribution.")) }
            let ready = support.appendingPathComponent("ready-" + UUID().uuidString + ".json")
            defer { try? FileManager.default.removeItem(at:ready) }
            let p = Process(); p.executableURL = python
            p.arguments = ["-I", "-B", "-u", script.path, "--data", support.path, "--ready-file", ready.path]
            p.environment = ["MAC_ASSISTANT_TOKEN":sessionToken,"INIJ_UI_LANG":Locale.preferredLanguages.first ?? "en","PATH":"/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin","HOME":NSHomeDirectory(),"PYTHONIOENCODING":"utf-8"]
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
            guard let bytes = readyData, let json = try JSONSerialization.jsonObject(with:bytes) as? [String:Any], let value = json["port"] as? Int else { p.terminate(); throw AppError(message:L("Не удалось запустить встроенный сервис за 15 секунд. Журнал: ", "Could not start the bundled service within 15 seconds. Log: ") + logfile.path) }
            port = value
            if !CommandLine.arguments.contains("--smoke-test") {
            _ = try await api("/keys", ["image": Keys.get("image"), "model": Keys.get("model"), "brave": Keys.get("brave"), "tavily": Keys.get("tavily"), "serper": Keys.get("serper")])
            }
            try await refresh(); startup = ""; if snapshot?.settings.model.isEmpty == true { settingsShown = true }
            polling = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    guard let self, !Task.isCancelled else { return }
                    do { try await self.refresh() } catch {
                        // Cancelling a poll during shutdown/test transitions is not a connection failure.
                        guard !Task.isCancelled else { return }
                        self.error = L("Связь с локальным сервисом: \(error.localizedDescription)", "Local service connection: \(error.localizedDescription)")
                    }
                }
            }
        } catch { shutdown(); self.error = error.localizedDescription; startup = L("Запуск не завершен", "Startup incomplete") }
    }
    func shutdown() { polling?.cancel(); browser.webView.stopLoading(); process?.terminate(); process = nil; port = 0 }
    func api(_ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        guard port > 0, let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { throw AppError(message: L("Сервис не готов", "Service not ready")) }
        var request = URLRequest(url: url); request.timeoutInterval = 65
        request.setValue(sessionToken, forHTTPHeaderField: "X-App-Token")
        request.setValue(Locale.preferredLanguages.first ?? "en",forHTTPHeaderField:"Accept-Language")
        if let body {
            request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AppError(message: L("Некорректный ответ сервиса", "Invalid service response")) }
        guard let http = response as? HTTPURLResponse, http.statusCode < 400 else { throw AppError(message: result["error"] as? String ?? L("Ошибка сервиса", "Service error")) }
        return result
    }
    func refresh() async throws {
        _ = try await api("/thermal", ["state": ProcessInfo.processInfo.thermalState.rawValue])
        let json = try await api("/state")
        snapshot = try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: json))
        if project == nil { projectID = snapshot?.projects.first?.id ?? "" }
        if chat == nil { chatID = project?.chats.last?.id ?? "" }
        browser.allow(snapshot?.settings.mode != "offline")
        for job in snapshot?.jobs ?? [] where job.status != "running" && job.status != "queued" && !seenJobs.contains(job.id) {
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
        guard canSend else { return }
        let draftText = draft; let pid = projectID; let cid = chatID
        let sentAttachments = attachments
        let files = sentAttachments.map { ["id":$0.id,"name":$0.name,"text":$0.text] }
        sending = true
        perform {
            defer { self.sending = false }
            _ = try await self.api("/send", ["projectID": pid, "chatID": cid, "text": draftText,"attachments":files])
            let ids = Set(sentAttachments.map { $0.id })
            if self.projectID == pid && self.chatID == cid {
                if self.draft == draftText { self.draft = "" }
                self.attachments.removeAll { ids.contains($0.id) }
            } else {
                if self.draftStore.read(pid,cid) == draftText { self.draftStore.write("",pid,cid) }
                self.draftStore.writeAttachments(self.draftStore.attachments(pid,cid).filter { !ids.contains($0.id) },pid,cid)
            }
        }
    }
    func drawImage() {
        let text = draft; let pid = projectID; let cid = chatID
        perform { _ = try await self.api("/image/generate", ["projectID":pid,"chatID":cid,"text":text]); if self.projectID == pid && self.chatID == cid && self.draft == text { self.draft = "" } }
    }
    func stop() { let job=snapshot?.jobs.first { $0.chatID == chatID && ($0.status == "running" || $0.status == "queued") }; perform { _ = try await self.api("/stop", job.map { ["id":$0.id] } ?? [:]); self.browser.webView.stopLoading(); self.browser.finish(AppError(message: L("Остановлено", "Stopped"))) } }
    func newChat() { perform { let r = try await self.api("/chat", ["projectID": self.projectID]); self.chatID = r["id"] as? String ?? "" } }
    func newProject() {
        let alert = NSAlert(); alert.messageText = L("Новый проект", "New project"); alert.addButton(withTitle: L("Создать", "Create")); alert.addButton(withTitle: L("Отмена", "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 26)); field.placeholderString = L("Название", "Name")
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
        perform { let r = try await self.api("/project", ["name": field.stringValue]); self.projectID = r["id"] as? String ?? "" }
    }
    func chooseWorkspace() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = L("Модель сможет читать файлы этой папки. Запись требует подтверждения.", "The model can read files in this folder. Writing requires approval.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { _ = try await self.api("/project/update", ["projectID": self.projectID, "workspace": url.path]) }
    }
    func importSkill() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true
        panel.message = L("Выбери папку скилла или SKILL.md. Скрипты не запускаются при импорте.", "Choose a skill folder, parent catalog or SKILL.md. Import does not execute scripts.")
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
        panel.message = L("Только выбранный чат, без других чатов, ключей и файлов проекта.", "Only the selected chat, without other chats, keys or project files.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { _ = try await self.api("/chat/export", ["projectID":pid,"chatID":id,"path":url.path]); NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
    func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Inij-backup.zip"; panel.allowedContentTypes = [.zip]
        panel.message = L("Содержит историю, память, скиллы и импортированные файлы. Ключи и cookies не включаются.", "Contains history, memory, skills and imported files. Keys and cookies are excluded.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { _ = try await self.api("/export", ["path": url.path]); NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
    func restore() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert(); alert.messageText = L("Восстановить бэкап?", "Restore backup?"); alert.informativeText = L("Текущие данные будут сохранены отдельной копией. Ключи остаются в Связке ключей. Внешние папки нужно будет выбрать заново.", "Current data will be saved in a separate copy. Keys remain in Keychain. External folders must be selected again."); alert.addButton(withTitle:L("Восстановить", "Restore")); alert.addButton(withTitle:L("Отмена", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform { let result = try await self.api("/restore",["path":url.path]); self.projectID="";self.chatID="";self.error = result["notice"] as? String ?? L("Бэкап восстановлен", "Backup restored") }
    }
    func changeChat(_ action: String, index: Int = -1, text: String = "") {
        if action == "delete" {
            let alert = NSAlert();alert.messageText=L("Удалить чат из списка?", "Remove chat from the list?");alert.informativeText=L("История останется в архиве приложения.", "History remains in the application archive.");alert.addButton(withTitle:L("Удалить", "Delete"));alert.addButton(withTitle:L("Отмена", "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        var payload: [String:Any] = ["projectID":projectID,"chatID":chatID,"action":action,"index":index]
        if action == "edit" { payload["text"] = text }
        perform { _ = try await self.api("/chat/change",payload) }
    }

    var documentWindows: [NSWindow] = []
    func showFullText(_ text: String) {
        let window=NSWindow(contentRect:NSRect(x:150,y:150,width:800,height:600),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title=L("Полный текст", "Full text");window.isReleasedWhenClosed=false
        let scroll=NSScrollView(frame:window.contentView!.bounds);scroll.hasVerticalScroller=true;scroll.autoresizingMask=[.width,.height]
        let view=NSTextView(frame:scroll.bounds);view.string=text;view.isEditable=false;view.isSelectable=true;view.isVerticallyResizable=true;view.autoresizingMask=[.width];view.textContainer?.widthTracksTextView=true
        scroll.documentView=view;window.contentView=scroll
        documentWindows.removeAll { !$0.isVisible };documentWindows.append(window);window.makeKeyAndOrderFront(nil)
    }
    func deleteModel(_ path: String, completion: @escaping () -> Void = {}) {
        perform {
            let info = try await self.api("/models/delete-preview", ["path":path])
            guard let token=info["token"] as? String else { throw AppError(message:L("Не удалось подготовить удаление", "Could not prepare deletion")) }
            let alert=NSAlert(); alert.alertStyle = .warning
            alert.messageText=L("Переместить модель в Корзину?", "Move model to Trash?")
            let bytes=(info["size"] as? NSNumber)?.int64Value ?? 0
            alert.informativeText="\(info["name"] as? String ?? path)\n\(ByteCountFormatter.string(fromByteCount:bytes,countStyle:.file))\n\(path)\n" + ((info["external"] as? Bool == true) ? L("Это выбранный файл вне папки приложения. Он будет перемещён с указанного места. ", "This is a selected file outside the application folder. It will be moved from this location. ") : "") + L("Загруженная модель будет выгружена. Восстановить файл можно из Корзины. Место освободится после её очистки.", "The loaded model will be unloaded. Restore the file from Trash. Space is reclaimed after emptying Trash.")
            alert.addButton(withTitle:L("В Корзину", "Move to Trash")); alert.addButton(withTitle:L("Отмена", "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            _ = try await self.api("/models/delete", ["token":token])
            try await self.refresh();completion()
        }
    }
    func attach() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.message = L("До 12 МБ / 2 млн символов. Большие документы читаются по частям. PDF и изображения: локальное распознавание. В облачном режиме текст отправляется выбранному провайдеру.", "Up to 12 MB / 2 million characters. Large documents are read in chunks. PDF and images: local OCR. In cloud mode the text is sent to the selected provider.")
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { attach($0) }
    }
    func attach(_ url: URL) {
        guard url.isFileURL else { error = L("Перетащи локальный файл", "Drop a local file"); return }
        guard !projectID.isEmpty && !chatID.isEmpty && !running && !sending else { return }
        let pid = projectID; let cid = chatID
        importingFiles += 1
        perform {
            defer { self.importingFiles -= 1 }
            let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            guard size <= 12 * 1024 * 1024 else { throw AppError(message: L("Файл больше 12 МБ", "File exceeds 12 MB")) }
            var payload: [String: Any] = ["projectID": pid, "path": url.path]
            let ext = url.pathExtension.lowercased()
            if ["pdf", "png", "jpg", "jpeg", "tiff", "heic", "webp"].contains(ext) {
                payload["extractedText"] = try await Task.detached { try DocumentReader.extract(url) }.value
            }
            let r = try await self.api("/attachment", payload)
            guard let text = r["text"] as? String, !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw AppError(message:L("В файле нет читаемого текста", "No readable text in this file")) }
            guard r["truncated"] as? Bool != true else { throw AppError(message:L("Файл прочитан не полностью. Вложение не добавлено.", "File was not fully read. Attachment was not added.")) }
            let item = ComposerAttachment(id:UUID().uuidString,name:url.lastPathComponent,text:text)
            if self.projectID == pid && self.chatID == cid { self.attachments.append(item) }
            else { self.draftStore.writeAttachments(self.draftStore.attachments(pid,cid) + [item],pid,cid) }
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
    @AppStorage("chatFontSize") private var fontSize = 14.0
    @Binding var text: String
    var enterSends: Bool
    var send: () -> Void
    var files: (([URL]) -> Void)? = nil
    final class Input: NSTextView {
        var submit: (() -> Void)?
        var enterSends = true
        var files: (([URL]) -> Void)?
        static func fileURLs(_ pasteboard: NSPasteboard) -> [URL] {
            (pasteboard.readObjects(forClasses:[NSURL.self], options:[.urlReadingFileURLsOnly:true]) as? [URL]) ?? []
        }
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            if !Self.fileURLs(sender.draggingPasteboard).isEmpty { return files == nil ? [] : .copy }
            return super.draggingEntered(sender)
        }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let urls = Self.fileURLs(sender.draggingPasteboard)
            if !urls.isEmpty { guard let files else { return false }; files(urls); return true }
            return super.performDragOperation(sender)
        }
        override func paste(_ sender: Any?) {
            let urls = Self.fileURLs(.general)
            if !urls.isEmpty { files?(urls); return }
            super.paste(sender)
        }
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
        input.registerForDraggedTypes([.fileURL])
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
        input.enterSends=enterSends; input.submit=send; input.files=files; input.font = NSFont.systemFont(ofSize:fontSize)
    }
}
struct MainView: View {
    @AppStorage("enterSends") private var enterSends = true
    @EnvironmentObject var model: AppModel
    @State private var modelPickerShown = false
    @AppStorage("chatFontSize") private var chatFontSize = 14.0
    @State private var searchText = ""
    var visibleMessages: [(offset: Int, element: ChatMessage)] {
        Array((model.chat?.messages ?? []).enumerated()).filter { searchText.isEmpty || $0.element.content.localizedCaseInsensitiveContains(searchText) }
    }
    var body: some View {
        HStack(spacing:0) {
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "globe")
                    Toggle(L("Интернет", "Internet"), isOn: Binding(get: { model.snapshot?.settings.mode != "offline" }, set: { enabled in
                        model.perform {
                            let provider=model.snapshot?.settings.provider ?? "local"
                            let base=model.snapshot?.settings.baseURL ?? ""
                            if !enabled && provider != "local" && !(["127.0.0.1","localhost","::1"].contains(URLComponents(string:base)?.host ?? "")) { throw AppError(message:L("Для отключения интернета сначала выбери локальную модель в настройках", "Select a local model in settings before turning off internet")) }
                            _ = try await model.api("/settings", ["mode": enabled ? (provider == "local" || ["127.0.0.1","localhost","::1"].contains(URLComponents(string:base)?.host ?? "") ? "internet" : "cloud") : "offline"])
                        }
                    })).toggleStyle(.switch).controlSize(.small).disabled(model.running || model.snapshot == nil)
                }.padding(.bottom,8)
                HStack { Text(L("Проекты", "Projects")).font(.headline); Spacer(); Button(action: model.newProject) { Image(systemName: "folder.badge.plus") } }
                Picker(L("Проект", "Project"), selection: $model.projectID) {
                    ForEach(model.snapshot?.projects ?? []) { p in Text(p.name).tag(p.id) }
                }.labelsHidden()
                List(selection: $model.chatID) {
                    ForEach(model.project?.chats ?? []) { c in
                        Text(c.title).lineLimit(2).tag(c.id).contextMenu {
                            Button(L("Контекст чата", "Chat context")) { model.chatID=c.id; model.previewContext() }
                            Button(L("Сводка чата", "Summarize chat")) { model.chatID=c.id; model.compact() }.disabled(c.messages.isEmpty)
                            Button(L("Экспорт", "Export")) { model.exportChat(c.id) }
                            Divider()
                            Button(L("Удалить чат", "Delete chat"),role:.destructive) { model.chatID=c.id; model.changeChat("delete") }
                        }
                    }
                }
                HStack {
                    Button(action: { model.settingsShown=true }) { Image(systemName:"gearshape").font(.title3) }.help(L("Настройки", "Settings")).accessibilityIdentifier("settings.open").smokeControl("settings.open")
                    Button(action: model.newChat) { Text(L("Новый чат", "New chat")).frame(maxWidth:.infinity).padding(.vertical,6) }
                }
            }.buttonStyle(MonochromeButton()).controlSize(.regular).padding(12).frame(width:220)
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    HStack {
                        Button { model.showBrowser.toggle() } label: {
                            Label(model.showBrowser ? L("Скрыть браузер", "Hide browser") : L("Браузер", "Browser"), systemImage: "globe")
                        }
                        .help(model.showBrowser ? L("Скрыть встроенный браузер", "Hide built-in browser") : L("Показать встроенный браузер", "Show built-in browser"))
                        .accessibilityIdentifier("browser.toggle").smokeControl("browser.toggle")
                        Spacer()
                        Text(telemetryLabel).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            .help(L("Температуры датчиков, если доступны. Токены — только usage провайдера за запуск; н/д, если не возвращены. Трафик — полезные байты запросов/ответов внешнего API модели, без браузера, загрузок и протокольных накладных расходов.", "Sensor temperatures when available. Tokens: provider usage for this run; N/A when absent. Traffic: external model API request/response payload bytes, excluding browser, downloads and protocol overhead."))
                    }.padding(12)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(engineLabel).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("engine.metrics")
                        ForEach((model.snapshot?.jobs ?? []).filter { $0.status == "running" || $0.status == "queued" }) { job in
                            HStack {
                                Text(job.status == "queued" ? L("В очереди · \(chatTitle(job))", "Queued · \(chatTitle(job))") : L("Выполняется · \(chatTitle(job))", "Running · \(chatTitle(job))")).font(.caption)
                                Spacer()
                                Button(L("Отменить", "Cancel")) { model.cancelJob(job.id) }.font(.caption)
                            }
                        }
                    }.padding(.horizontal,12).padding(.bottom,6)
                    Divider()
                    if let local = model.snapshot?.localModel, model.snapshot?.settings.provider == "local", local.status == "loading" || local.status == "error" {
                        HStack {
                            if local.status == "loading" { ProgressView().controlSize(.small) }
                            Text(local.status == "ready" ? L("Модель готова · работает на этом Mac", "Model ready · running on this Mac") : local.status == "loading" ? L("Загрузка модели…", "Loading model…") : local.status == "error" ? local.error : L("Модель загрузится при отправке сообщения", "The model will load when you send a message")).font(.caption).lineLimit(3)
                            Spacer()
                        }.padding(.horizontal,12).padding(.vertical,6)
                    }
                    if !model.startup.isEmpty { Text(model.startup).padding(); Button(L("Повторить запуск", "Retry startup")) { Task { await model.start() } } }
                    if model.snapshot?.settings.model.isEmpty == true && !(model.snapshot?.settings.imageEnabled == true && model.snapshot?.settings.imageProvider == "local" && !(model.snapshot?.settings.imageLocalModel ?? "").isEmpty) { Text(L("Для текстового чата выбери файл GGUF в настройках или скачай модель в Explore.", "Choose a GGUF file in settings or download a model in Models for text chat.")).padding(); Button(L("Настроить модель", "Configure model")) { model.settingsShown = true } }
                    chatToolbar
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 16) {
                                ForEach(visibleMessages, id: \.offset) { index, message in
                                    if message.role != "tool" {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(message.role == "user" ? L("Ты", "You") : "inij").font(.caption.bold()).foregroundStyle(.secondary)
                                            if message.visibleText.count > 12000 { Button(L("Открыть полный текст…", "Open full text…")) { model.showFullText(message.visibleText) } }
                                            if !message.visibleText.isEmpty || message.streaming == true {
                                                ChatMessageText(content: message.visibleText.count > 12000 ? String(message.visibleText.prefix(1200))+L("\n\n[Большое сообщение: показано начало. Полный текст сохранён и обрабатывается целиком.]", "\n\n[Large message: showing the beginning. Full text is saved and processed.]") : (message.visibleText.isEmpty ? "…" : message.visibleText), quote: { quoteMessage($0) }, quoteWhole: message.quoteText)
                                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                            }
                                            if let reasoning = message.reasoning, !reasoning.isEmpty { DisclosureGroup(L("Ход работы модели", "Model progress")) { Text(reasoning).textSelection(.enabled) } }
                                            ForEach(message.attachments ?? []) { file in
                                                Button { model.showFullText(file.text) } label: {
                                                    HStack(spacing:8) {
                                                        Image(systemName:"doc.text")
                                                        VStack(alignment:.leading,spacing:3) {
                                                            Text(file.name).fontWeight(.medium).lineLimit(2)
                                                            Text(L("\(file.text.count) символов · Показать содержимое", "\(file.text.count) characters · Show content")).font(.caption).foregroundStyle(.secondary)
                                                        }
                                                    }.padding(9).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                                                }.buttonStyle(.plain).background(Color.secondary.opacity(0.08)).cornerRadius(7)
                                                .smokeControl("sent.attachment."+file.name)
                                            }
                                            ForEach(message.artifacts ?? [],id: \.path) { artifact in
                                                VStack(alignment:.leading,spacing:4) {
                                                    Label(artifact.name,systemImage:"doc.fill")
                                                    HStack { Button(L("Открыть", "Open")) { fileAction(artifact,action:"open") }; Button(L("Показать в Finder", "Show in Finder")) { fileAction(artifact,action:"reveal") }; Button(L("Сохранить как…", "Save as…")) { fileAction(artifact,action:"save") } }
                                                }.padding(8).background(Color.primary.opacity(0.06)).smokeControl("document.artifact."+artifact.name)
                                            }
                                        }.padding(14).background(message.role == "user" ? Color.primary.opacity(0.08) : Color.secondary.opacity(0.06))
                                            .clipShape(RoundedRectangle(cornerRadius: 10)).id(index)
                                            .contextMenu {
                                                Button(L("Цитировать", "Quote")) { quoteMessage(message.quoteText) }
                                                Button(L("Копировать", "Copy")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.quoteText,forType:.string) }
                                            }
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
                                                    Button(L("Открыть", "Open")) { fileAction(artifact, action: "open") }
                                                    Button(L("Показать в Finder", "Show in Finder")) { fileAction(artifact, action: "reveal") }
                                                    Button(L("Сохранить как…", "Save as…")) { fileAction(artifact, action: "save") }
                                                }
                                            }.padding(12).background(Color.accentColor.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 8))
                                        }
                                        DisclosureGroup(L("Результат инструмента", "Tool result")) { Text(message.content).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }.foregroundStyle(.secondary)
                                    }
                                }
                                Color.clear.frame(height: 1).id("bottom")
                            }.padding()
                        }.onChange(of: model.chat?.messages.count) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
                        .onChange(of: model.running) { running in
                            if !running { DispatchQueue.main.asyncAfter(deadline:.now()+0.15) { proxy.scrollTo("bottom",anchor:.bottom) } }
                        }
                    }
                    if let pending = model.approval {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L("Подтвердить действие: ", "Approve action: ") + (pending.tool ?? "")).bold()
                            if pending.tool == "run_command" { Text(pending.oneTimeOnly == true ? L("Одно действие вне sandbox: проверь команду и причину. Это разрешение не сохраняется.", "One action outside the sandbox: review the command and reason. This approval is not saved.") : L("Команда изолирована в папке проекта. Тайм-аут 60 секунд. Сеть зависит от режима приложения.", "The command is contained in the project folder. Timeout: 60 seconds. Network depends on the application mode.")).foregroundStyle(.primary) }
                            ScrollView { Text((pending.arguments ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.text)" }.joined(separator: "\n")).font(.system(.caption,design: .monospaced)).textSelection(.enabled) }.frame(maxHeight: 130)
                            HStack {
                                Button(L("Отклонить", "Reject")) { resolve(pending, false) }
                                Button(L("Разрешить один раз", "Allow once")) { resolve(pending, true) }
                            }
                            if pending.oneTimeOnly != true { HStack {
                                Button(L("Разрешать всегда", "Always allow")) { resolve(pending, true, scope: "tool") }
                                    .help(L("Разрешить этот инструмент во всех проектах. Для MCP — только этот сервер и инструмент.", "Allow this tool in all projects. For MCP: only this server and tool."))
                                Button(L("Разрешить всё и всегда", "Always allow everything")) { resolve(pending, true, scope: "all") }
                                    .help(L("Все инструменты, включая команды и MCP, во всех проектах. Сохраняется между запусками; сброс — в настройках.", "All tools, including commands and MCP, in all projects. Persists across restarts; reset in settings."))
                            } }
                        }.padding().background(Color.primary.opacity(0.12))
                    }
                    Divider()
                    if let detail = model.snapshot?.jobs.first(where: { $0.status == "running" })?.detail {
                        HStack { ProgressView().controlSize(.small); Text(detail).font(.caption).foregroundStyle(.secondary) }.padding(.horizontal,12)
                    }
                    HStack {
                        Button { modelPickerShown.toggle() } label: { Image(systemName: "cpu").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).help(L("Выбрать модель", "Select model")).disabled(model.running)
                            .popover(isPresented:$modelPickerShown) { ModelPickerPopup(model:model, isPresented:$modelPickerShown) }
                        Spacer()
                        Button(L("Нарисовать", "Draw"), action: model.drawImage)
                            .help(L("Создать картинку по тексту в поле ввода локально, без текстовой модели. Настройки → Модель → Генерация изображений.", "Create an image from the input prompt locally, without a text model. Settings → Model → Image generation."))
                            .accessibilityIdentifier("image.generate").smokeControl("image.generate")
                            .disabled(model.running || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.snapshot == nil)
                        Button(action: { model.attach() }) { Image(systemName: "paperclip") }.disabled(model.chatBusy)
                    }.padding(.horizontal,12).padding(.top,8)
                    if let progress=model.snapshot?.jobs.last?.progress, model.running { Text(progress).font(.caption).padding(.horizontal,12) }
                    if model.importingFiles > 0 {
                        HStack { ProgressView().controlSize(.small); Text(L("Чтение файлов: \(model.importingFiles)", "Reading files: \(model.importingFiles)")).font(.caption) }.padding(.horizontal,12)
                    }
                    if !model.attachments.isEmpty {
                        ScrollView(.horizontal) {
                            HStack {
                                ForEach(model.attachments) { item in
                                    HStack(spacing:6) {
                                        Image(systemName:"doc.text")
                                        Text(item.name).lineLimit(1)
                                        Text(L("\(item.text.count) симв.", "\(item.text.count) chars")).foregroundStyle(.secondary)
                                        Button { model.attachments.removeAll { $0.id == item.id } } label: { Image(systemName:"xmark.circle.fill") }
                                            .buttonStyle(.plain).help(L("Убрать вложение", "Remove attachment")).disabled(model.sending)
                                    }.font(.caption).padding(8).background(Color.primary.opacity(0.08)).cornerRadius(8)
                                }
                            }
                        }.frame(maxHeight:44).padding(.horizontal,12)
                    }
                    Composer(text: $model.draft, enterSends: enterSends, send: { if !model.chatBusy { model.send() } }, files: model.chatBusy ? nil : { urls in urls.forEach { model.attach($0) } }).frame(height:90).padding(8)
                    HStack {
                        Button(L("Повторить ответ", "Regenerate reply")) { model.changeChat("retry") }.disabled(model.running || (model.chat?.messages.isEmpty ?? true))
                        Text(enterSends ? L("↩ — отправить · ⇧↩ — новая строка", "↩ sends · ⇧↩ new line") : L("⌘↩ — отправить · ↩ — новая строка", "⌘↩ sends · ↩ new line")).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if model.chatBusy { Button(L("Стоп", "Stop"), action: model.stop).keyboardShortcut(.escape,modifiers: []) }
                        else { Button(L("Отправить", "Send"),action: model.send).keyboardShortcut(.return,modifiers: .command).disabled(!model.canSend) }
                    }.padding(12)
                }.frame(minWidth: 480, maxWidth: .infinity)
                if model.showBrowser {
                    BrowserPanel(browser: model.browser, close: { model.showBrowser = false }).frame(minWidth: 350,idealWidth: 500)
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
                Text(L("Контекст: ≈\(model.tokenEstimate) токенов", "Context: ≈\(model.tokenEstimate) tokens")).font(.title2)
                Text(L("Расчет: сообщения и схемы инструментов, UTF-8 байты / 4. Не токенизатор модели; точное потребление может отличаться.", "Estimate: messages and tool schemas, UTF-8 bytes / 4. Not a model tokenizer; actual usage may differ.")).font(.caption)
                ScrollView { Text(model.contextText).font(.system(.caption,design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity,alignment: .leading) }
                Button(L("Закрыть", "Close")) { model.contextShown = false }
            }.padding().frame(width: 760,height: 600)
        }
        .alert(L("Сообщение", "Message"), isPresented: Binding(get: { !model.error.isEmpty },set: { if !$0 { model.error = "" } })) { Button("OK") { model.error = "" } } message: { Text(model.error) }
    }
    var chatToolbar: some View {
        HStack {
                        TextField(L("Поиск в этом чате", "Search this chat"), text: $searchText).textFieldStyle(.roundedBorder)
                        if !searchText.isEmpty { Text("\(visibleMessages.count)").font(.caption); Button(L("Сброс", "Reset")) { searchText = "" } }
                        Menu { ForEach([12.0,14,16,18,20,24], id: \.self) { size in Button(L("\(Int(size)) пт", "\(Int(size)) pt")) { chatFontSize = size } } } label: { Text(L("Аа", "Aa")) }.help(L("Размер текста", "Text size"))
                        Button { printChat() } label: { Image(systemName: "printer") }.help(L("Печать / сохранить PDF", "Print / save PDF")).disabled(model.chat == nil)
                    }.padding(.horizontal,12).padding(.vertical,6)
    }
    func printChat() {
        guard let chat = model.chat else { return }
        let view = ChatTranscript.textView(title:chat.title, messages:chat.messages, size:chatFontSize)
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit; info.verticalPagination = .automatic
        info.isHorizontallyCentered = false; info.topMargin = 36; info.bottomMargin = 36
        let operation = NSPrintOperation(view:view, printInfo:info)
        operation.showsPrintPanel = true; operation.showsProgressPanel = true
        operation.run()
    }
    func chatTitle(_ job: Job) -> String {
        model.snapshot?.projects.first(where: { $0.id == job.projectID })?.chats.first(where: { $0.id == job.chatID })?.title ?? L("Чат", "Chat")
    }
    var engineLabel: String {
        guard let e=model.snapshot?.engine else { return L("Движок: н/д", "Engine: N/A") }
        func seconds(_ n: Double?) -> String { n.map { String(format:L("%.2f с", "%.2f s"),$0) } ?? L("н/д", "N/A") }
        let memory=e.rssBytes.map { ByteCountFormatter.string(fromByteCount:$0,countStyle:.memory) } ?? L("н/д", "N/A")
        let rate=e.metrics.tokensPerSecond.map { String(format:L("%.1f ток/с", "%.1f tok/s"),$0) } ?? L("н/д", "N/A")
        let basis=e.metrics.rateBasis == "provider_eval" ? L("генерация сервера", "server generation") : L("весь запрос", "whole request")
        return L("\(e.provider) · загрузка \(seconds(e.state.loadSeconds)) · первый текст \(seconds(e.metrics.firstTextSeconds)) · \(rate) (\(basis)) · RAM процесса \(memory)", "\(e.provider) · load \(seconds(e.state.loadSeconds)) · first text \(seconds(e.metrics.firstTextSeconds)) · \(rate) (\(basis)) · process RAM \(memory)")
    }
    var telemetryLabel: String {
        let t=model.snapshot?.thermal
        let cpu=t?.cpu.map { String(format:"%.0f°",$0) } ?? L("н/д", "N/A")
        let gpu=t?.gpu.map { String(format:"%.0f°",$0) } ?? L("н/д", "N/A")
        let u=model.snapshot?.usage
        let tokens=(u?.reportedRequests ?? 0)>0 ? L("Токены ↓\(u?.inputTokens ?? 0) ↑\(u?.outputTokens ?? 0)", "Tokens ↓\(u?.inputTokens ?? 0) ↑\(u?.outputTokens ?? 0)") + ((u?.missingRequests ?? 0)>0 ? L(" (не все)", " (partial)") : "") : L("Токены: н/д", "Tokens: N/A")
        let tx=(u?.networkRequests ?? 0) > 0 ? String(format:"%.1f KB",Double(u?.sentBytes ?? 0)/1024) : L("н/д", "N/A")
        let rx=(u?.networkRequests ?? 0) > 0 ? String(format:"%.1f KB",Double(u?.receivedBytes ?? 0)/1024) : L("н/д", "N/A")
        return L("Температура CPU \(cpu) · GPU \(gpu)", "CPU temperature \(cpu) · GPU \(gpu)") + (t?.limited == true ? L(" · ограничение", " · throttled") : "") + "  |  API ↑\(tx) ↓\(rx)  |  " + tokens
    }
    var modeLabel: String {
        switch model.snapshot?.settings.mode { case "cloud": return L("Облачная модель + интернет", "Cloud model + internet"); case "internet": return L("Локальная модель + интернет", "Local model + internet"); default: return L("Только локально", "Local only") }
    }
    func quoteMessage(_ text: String) {
        model.draft += (model.draft.isEmpty ? "" : "\n\n") + text.components(separatedBy:"\n").map { "> " + $0 }.joined(separator:"\n") + "\n\n"
    }
    func fileAction(_ artifact: Artifact, action: String) {
        let pid = model.projectID
        model.perform {
            let result = try await model.api("/artifact/path", ["projectID": pid, "path": artifact.path])
            guard let path = result["path"] as? String else { throw AppError(message: L("Файл недоступен", "File unavailable")) }
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
    var close: () -> Void
    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(L("Браузер", "Browser")).font(.headline)
                Spacer()
                Button(action: close) { Label(L("Закрыть", "Close"), systemImage: "xmark") }
                    .help(L("Закрыть панель браузера", "Close browser panel"))
                    .accessibilityIdentifier("browser.close").smokeControl("browser.close")
            }.padding(.horizontal, 8).padding(.top, 8)
            HStack {
                TextField("https://…",text: $browser.address).onSubmit { go() }
                Button(L("Открыть", "Open"),action: go).disabled(!browser.enabled)
            }.padding(8)
            Text(browser.status).font(.caption).foregroundStyle(.secondary)
            BrowserView(browser: browser)
            Text(L("Отдельный профиль приложения. Вход и капчу проходи вручную. Модель читает текст, не пароли из полей.", "Separate application profile. Sign in and solve CAPTCHAs manually. The model reads text, not password fields.")).font(.caption).foregroundStyle(.secondary).padding(8)
        }
    }
    func go() { Task { do { try await browser.open(browser.address) } catch { browser.status = error.localizedDescription } } }
}

struct SettingsView: View {
    @AppStorage("enterSends") private var enterSends = true
    @State var serverLimit = 0
    @State var mcpNetwork = false
    @State var mcpReadRoots: [String] = []
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
    @State var imageProvider = "local"
    @State var imageLocalModel = ""
    @State var imageCompute = "auto"
    @State var imageWidth = 512
    @State var imageHeight = 512
    @State var imageSteps = 20
    @State var imageCFG = 7.0
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
    var contextDescription: String {
        let values=model.snapshot?.contextBudget
        let window=values?["modelWindow"]?.text ?? L("н/д", "N/A")
        let server=values?["serverLimit"]?.text ?? L("н/д", "N/A")
        return L("Окно модели: ", "Model window: ") + window + L(" · Лимит сервера: ", " · Server limit: ") + server
    }
    var body: some View {
        VStack(alignment: .leading,spacing: 12) {
            HStack {
                Text(L("Настройки", "Settings")).font(.title)
                Spacer()
                Button { model.settingsShown = false } label: { Label(L("Закрыть", "Close"), systemImage: "xmark") }
                    .help(L("Закрыть без сохранения изменений формы", "Close without saving form changes"))
                    .accessibilityIdentifier("settings.close").smokeControl("settings.close")
            }
            Picker(L("Оформление", "Appearance"), selection: $appearanceTheme) {
                Text(L("Тёмное", "Dark")).tag("dark")
                Text(L("Светлое", "Light")).tag("light")
            }.pickerStyle(.segmented).help(L("Сохраняется автоматически и применяется ко всему приложению", "Saved automatically and applied to the whole application")).disabled(model.running)
            VStack(spacing:8) {
                HStack {
                    ForEach(Array([L("Модель", "Model"),L("Промпты", "Prompts"),L("Скиллы и память", "Skills and memory"),"MCP",L("Экспорт и бэкап", "Export and backup"),L("Explore · модели", "Models"),L("Дополнительно", "Advanced")].enumerated()),id: \.offset) { index,title in
                        Button(title) { settingsTab=index }.background(settingsTab == index ? Color.primary.opacity(0.15) : Color.clear).clipShape(RoundedRectangle(cornerRadius:7))
                    }
                }
                Group { if settingsTab == 0 {
                ScrollView { Form {
                    Picker(L("Режим", "Mode"),selection: $mode) { Text(L("Только локально", "Local only")).tag("offline"); Text(L("Локальная модель + интернет", "Local model + internet")).tag("internet"); Text(L("Облачная модель + интернет", "Cloud model + internet")).tag("cloud") }
                    Picker(L("Протокол", "Protocol"),selection: $provider) { Text(L("Встроенная модель · GGUF", "Bundled model · GGUF")).tag("local"); Text(L("Ollama · внешний сервер", "Ollama · external server")).tag("ollama"); Text(L("OpenAI-совместимый API", "OpenAI-compatible API")).tag("openai") }
                    if provider == "local" {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(selectedModel.isEmpty ? L("Файл модели не выбран", "No model file selected") : URL(fileURLWithPath:selectedModel).lastPathComponent).lineLimit(2).truncationMode(.middle).help(selectedModel)
                            HStack {
                                Button(L("Обзор…", "Browse…"), action: browseModel)
                                Button(L("Загрузить модель", "Load model")) { save(fetch:false, load:true) }.disabled(selectedModel.isEmpty)
                                Button(L("Выгрузить", "Unload")) { model.perform { _ = try await model.api("/local/unload",[:]) } }
                                Button(L("Удалить…", "Delete…")) { model.deleteModel(selectedModel) { selectedModel="" } }.disabled(selectedModel.isEmpty || model.running)
                            }
                            Text(L("GGUF запускается встроенным движком на этом Mac. Другие приложения не нужны. Поддержка зависит от архитектуры модели.", "GGUF runs with the bundled engine on this Mac. No other application is needed. Support depends on the model architecture.")).font(.caption).foregroundStyle(.secondary)
                            if let local = model.snapshot?.localModel { Text(local.status == "loading" ? L("Загружаю…", "Loading…") : local.status == "ready" ? L("Модель готова", "Model ready") : local.error).font(.caption) }
                        }
                    } else {
                        TextField(L("Адрес API", "API address"),text: $base)
                        Text(L("Ollama: адрес без /api. OpenAI API: с /v1. Поле модели — ID сервера, не путь к файлу.", "Ollama: address without /api. OpenAI API: with /v1. Model is the server ID, not a file path.")).font(.caption).foregroundStyle(.secondary)
                        TextField(L("ID модели", "Model ID"),text: $selectedModel)
                        if !models.isEmpty { Picker(L("Доступные модели", "Available models"),selection: $selectedModel) { ForEach(models,id: \.self) { Text($0).tag($0) } } }
                        Button(L("Проверить список моделей", "Check model list")) { save(fetch: true) }
                    }
                    Toggle(L("Разрешить инструменты модели", "Enable model tools"),isOn: $toolsEnabled).accessibilityIdentifier("settings.tools").smokeControl("settings.tools", value: toolsEnabled ? "on" : "off")
                    Text(L("Для действий нужна модель с поддержкой tool calling. Если она не поддерживается, выключи инструменты для обычного чата.", "Actions require a model with tool calling support. Disable tools for ordinary chat if unsupported.")).font(.caption).foregroundStyle(.secondary)
                    TextField(L("Лимит контекста", "Context budget"),value: $limit,format: .number)
                    if provider != "local" { TextField(L("Лимит сервера (0 — неизвестен)", "Server limit (0 = unknown)"),value:$serverLimit,format:.number) }
                    Text(contextDescription).font(.caption)
                    Text(L("Больший контекст требует больше памяти. Фактический лимит проверяется при запуске движка.", "Larger context needs more memory. The effective limit is checked when the engine starts.")).font(.caption)
                    Slider(value: $temperature,in: 0...2) { Text(L("Температура ", "Temperature ") + String(format:"%.1f",temperature)) }
                    SecureField(L("Ключ модели", "Model key"),text: $modelKey)
                    Section(L("Генерация изображений · отдельная модель", "Image generation · separate model")) {
                        Toggle(L("Включить генератор изображений", "Enable image generation"),isOn:$imageEnabled)
                        Picker(L("Где создавать", "Generate with"),selection:$imageProvider) {
                            Text(L("На этом Mac · без интернета", "On this Mac · offline")).tag("local")
                            Text(L("Облачный Images API", "Cloud Images API")).tag("cloud")
                        }
                        if imageProvider == "local" {
                            Text(imageLocalModel.isEmpty ? L("Checkpoint изображений не выбран", "No image checkpoint selected") : URL(fileURLWithPath:imageLocalModel).lastPathComponent).lineLimit(2).help(imageLocalModel)
                            Button(L("Выбрать модель изображений…", "Choose image model…")) {
                                let panel=NSOpenPanel(); panel.allowedFileTypes=["gguf","safetensors"]; panel.allowsMultipleSelection=false
                                if panel.runModal() == .OK, let url=panel.url { imageLocalModel=url.path }
                            }
                            Button(L("Удалить модель изображений…", "Delete image model…")) { model.deleteModel(imageLocalModel) { imageLocalModel="" } }.disabled(imageLocalModel.isEmpty || model.running)
                            Text(L("Полный checkpoint Stable Diffusion 1.x / 2.x / SDXL (.safetensors или GGUF для stable-diffusion.cpp). Не текстовый GGUF и не LoRA. FLUX / SD3 с отдельными компонентами пока не подключены. Веса выбираются с диска, в установщик не входят.", "Full Stable Diffusion 1.x / 2.x / SDXL checkpoint (.safetensors or GGUF for stable-diffusion.cpp). Not a text GGUF or LoRA. FLUX / SD3 with separate components are not connected. Weights are selected from disk and are not bundled.")).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Picker(L("Ширина", "Width"),selection:$imageWidth) { ForEach([256,512,768,1024],id: \.self) { Text(String($0)).tag($0) } }
                                Picker(L("Высота", "Height"),selection:$imageHeight) { ForEach([256,512,768,1024],id: \.self) { Text(String($0)).tag($0) } }
                            }
                            Stepper(L("Шаги: \(imageSteps)", "Steps: \(imageSteps)"),value:$imageSteps,in:1...50)
                            Slider(value:$imageCFG,in:1...15,step:0.5) { Text("CFG: \(imageCFG,specifier:"%.1f")") }
                            Picker(L("Вычисления", "Compute"),selection:$imageCompute) { Text(L("Авто · Metal при наличии", "Auto · Metal if available")).tag("auto"); Text(L("CPU · медленнее", "CPU · slower")).tag("cpu") }
                            Text(L("Нужна macOS 26+. Напиши запрос и нажми «Нарисовать» в чате — текстовая модель не нужна. Английские запросы лучше подходят большинству SD checkpoint. Для снижения расхода памяти текстовая модель выгружается и загрузится при следующем ответе. «Стоп» отменяет создание.", "Requires macOS 26+. Enter a prompt and click Draw; no text model is needed. English prompts suit most SD checkpoints better. The text model is unloaded to reduce memory usage and reloads for the next reply. Stop cancels generation.")).font(.caption).foregroundStyle(.secondary)
                        } else {
                            TextField(L("Адрес OpenAI-совместимого Images API, с /v1", "OpenAI-compatible Images API address, with /v1"),text:$imageBase)
                            TextField(L("ID модели изображений", "Image model ID"),text:$imageModel)
                            SecureField(L("Ключ генератора изображений", "Image generator key"),text:$imageKey)
                            Text(L("Основная модель вызывает облачный генератор как инструмент. Нужен интернет. /images/generations с b64_json. Автоматического перехода в облако нет.", "The main model calls the cloud image generator as a tool. Internet required. /images/generations with b64_json. No automatic cloud fallback.")).font(.caption)
                        }
                    }
                    Picker(L("Поиск", "Search"),selection:$searchProvider) { Text("Brave").tag("brave");Text("Tavily").tag("tavily");Text("Serper").tag("serper") }
                    SecureField(L("Ключ Brave Search", "Brave Search key"),text: $braveKey)
                    SecureField(L("Ключ Tavily", "Tavily key"),text:$tavilyKey)
                    SecureField(L("Ключ Serper", "Serper key"),text:$serperKey)

                    Text(L("Ключи хранятся в Связке ключей. Поисковый API проверяется первым запросом. В режиме без интернета поиск и MCP отключены.", "Keys are stored in Keychain. Search API is checked on the first request. Search and MCP are disabled offline.")).font(.caption)
                    Text(L("В облачном режиме провайдер получает выбранный контекст, память и подключенные скиллы. Автоматического перехода из локального режима нет.", "In cloud mode the provider receives selected context, memory and active skills. There is no automatic switch from local mode.")).font(.caption)
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }.formStyle(.grouped).padding(8) } } else if settingsTab == 1 {
                VStack(alignment: .leading) {
                    Picker(L("Профиль", "Profile"),selection: $profileID) {
                        ForEach(model.snapshot?.profiles ?? []) { p in Text(p.name).tag(p.id) }
                        Text(L("Новый профиль", "New profile")).tag("")
                    }.onChange(of: profileID) { value in loadProfile(value) }
                    Button(L("Использовать этот профиль в текущем чате", "Use this profile in the current chat")) { model.perform { _ = try await model.api("/chat/config", ["projectID":model.projectID,"chatID":model.chatID,"profileID":profileID]) } }.disabled(profileID.isEmpty)
                    TextField(L("Название", "Name"),text: $profileName)
                    TextEditor(text: $prompt).font(.system(.body,design: .monospaced))
                    Text(L("Добавляется к коротким встроенным правилам и памяти проекта. Полный результат виден в «Контекст». Перед каждым изменением сохраняется версия для отката.", "Added to built-in rules and project memory. View the full result in Context. A rollback version is saved before each change.")).font(.caption)
                    Menu(L("Восстановить версию", "Restore version")) {
                        ForEach(model.snapshot?.profiles.first(where:{$0.id==profileID})?.versions ?? []) { version in
                            Button(version.time + " · " + version.name) { model.perform { _ = try await model.api("/profile/restore",["id":profileID,"versionID":version.id]);prompt=version.prompt;profileName=version.name } }
                        }
                    }
                    HStack {
                        Button(L("Сохранить профиль", "Save profile")) { save(fetch:false) }.disabled(profileName.isEmpty)
                        Button(L("Удалить профиль", "Delete profile"),role:.destructive) { deleteProfileShown=true }.disabled(profileID.isEmpty)
                    }
                    .confirmationDialog(L("Удалить сохранённый промпт? Чаты будут переключены на другой профиль. Копия сохранится в архиве.", "Delete saved prompt? Chats switch to another profile. A copy is retained in the archive."),isPresented:$deleteProfileShown) {
                        Button(L("Удалить", "Delete"),role:.destructive) { model.perform { let result=try await model.api("/profile/delete",["id":profileID]); try await model.refresh(); profileID=result["id"] as? String ?? ""; loadProfile(profileID) } }
                    }
                }.padding() } else if settingsTab == 2 {
                    InspectorView(model:model, embedded:true)
                } else if settingsTab == 3 {
                VStack(alignment:.leading,spacing:12) {
                    Text(L("MCP · локальные stdio-серверы", "MCP · local stdio servers")).font(.headline)
                    Text(L("MCP работает в sandbox: только папка проекта и явно выбранные папки. Сеть разрешается отдельно. Аргументы не должны содержать ключи.", "MCP runs in a sandbox: only the project and explicitly selected folders. Network access is granted separately. Never put keys in arguments.")).font(.caption)
                    List(model.snapshot?.mcp ?? []) { server in
                        HStack { VStack(alignment:.leading) { Text(server.name);Text(server.command + " " + server.args.joined(separator:" ")).font(.caption);Text(server.enabled ? L("Включен", "Enabled") : L("Выключен после восстановления", "Disabled after restore")) };Spacer(); Button(L("Удалить", "Delete")) { model.perform { _ = try await model.api("/mcp/remove",["id":server.id]) } } }
                    }
                    TextField(L("Название сервера", "Server name"),text:$mcpName)
                    TextField(L("Путь к исполняемому файлу", "Executable path"),text:$mcpCommand)
                    TextField(L("Аргументы: JSON-массив строк", "Arguments: JSON array of strings"),text:$mcpArgs)
                    Toggle(L("Разрешить сеть MCP", "Allow MCP network"),isOn:$mcpNetwork)
                    HStack { Button(L("Папка MCP для чтения…", "MCP read-only folder…")) { let p=NSOpenPanel();p.canChooseDirectories=true;p.canChooseFiles=false;if p.runModal() == .OK,let u=p.url { mcpReadRoots.append(u.path) } }; Text(mcpReadRoots.joined(separator:", ")).font(.caption) }
                    Button(L("Добавить MCP", "Add MCP")) {
                        model.perform {
                            guard let bytes=mcpArgs.data(using:.utf8),let args=try JSONSerialization.jsonObject(with:bytes) as? [String] else { throw AppError(message:L("Аргументы должны быть JSON-массивом строк", "Arguments must be a JSON array of strings")) }
                            _ = try await model.api("/mcp/save",["name":mcpName,"command":mcpCommand,"args":args,"enabled":true,"allowNetwork":mcpNetwork,"readRoots":mcpReadRoots]);mcpName="";mcpCommand="";mcpArgs="[]"
                        }
                    }.disabled(mcpName.isEmpty || mcpCommand.isEmpty)
                    Text(L("В чате попроси показать инструменты сервера; помощник вызовет mcp_list, затем mcp_call.", "Ask to list the server tools in chat; inij will use mcp_list, then mcp_call.")).font(.caption)
                }.padding() } else if settingsTab == 6 {
                    ScrollView { VStack(alignment:.leading,spacing:16) {
                        Text(L("Разрешения инструментов", "Tool permissions")).font(.headline)
                        Text(model.snapshot?.permissions?.all == true ? L("Все инструменты разрешены постоянно во всех проектах.", "All tools are permanently allowed in all projects.") : L("Постоянных разрешений: \(model.snapshot?.permissions?.tools.count ?? 0). Остальные действия требуют подтверждения.", "Permanent approvals: \(model.snapshot?.permissions?.tools.count ?? 0). Other actions require confirmation.")).font(.caption)
                        Button(L("Сбросить постоянные разрешения", "Reset permanent approvals")) { model.perform { _ = try await model.api("/permissions/reset", [:]); try await model.refresh() } }
                        Text(L("Сброс действует на следующие действия. Уже запущенные действия не отменяются.", "Reset applies to subsequent actions. Already running actions are not cancelled.")).font(.caption)
                        Button(L("Диагностика inij", "inij diagnostics")) { model.perform { let r = try await model.api("/diagnostics",["projectID":model.projectID]); let d = try JSONSerialization.data(withJSONObject:r,options:[.prettyPrinted,.sortedKeys]); model.showFullText(String(data:d,encoding:.utf8) ?? "") } }
                        Divider()
                        Toggle(L("Отправлять по Enter (Shift+Enter — новая строка)", "Send with Enter (Shift+Enter adds a new line)"),isOn:$enterSends)
                        Text(L("Если выключено: Enter — новая строка, ⌘Enter — отправка.", "When off: Enter adds a new line, ⌘Enter sends.")).font(.caption)
                        Toggle(L("Ограничивать нагрузку локальной модели при перегреве", "Throttle the local model when overheating"),isOn:$thermalEnabled)
                        Text(L("Порог: \(Int(thermalLimit)) °C", "Threshold: \(Int(thermalLimit)) °C"))
                        Slider(value:$thermalLimit,in:45...100,step:1).disabled(!thermalEnabled || (model.snapshot?.thermal?.cpu == nil && model.snapshot?.thermal?.gpu == nil))
                        Text(L("При достижении порога встроенный движок получает 50% рабочего времени. Возврат — после охлаждения на 3 °C. Без доступных датчиков используется системный статус перегрева macOS; порог в градусах тогда недоступен. Облачная модель не ограничивается.", "At the threshold the bundled engine gets 50% duty cycle. Restores after cooling by 3 °C. Without accessible sensors macOS thermal state is used; the numeric threshold is unavailable. Cloud models are not throttled.")).font(.caption)
                        Divider()
                        Button(L("Показать / скрыть браузер", "Show / hide browser")) { model.showBrowser.toggle(); model.settingsShown=false }
                        Button(L("Открыть хранилище проектов", "Open project storage")) { if let path=model.snapshot?.projectsRoot { NSWorkspace.shared.open(URL(fileURLWithPath:path)) } }
                    }.frame(maxWidth:.infinity,alignment:.leading).toggleStyle(.checkbox).padding() }
                } else if settingsTab == 5 {
                    ExploreView(model:model, embedded:true)
                } else {
                    VStack(alignment:.leading,spacing:20) {
                        Text(L("Экспорт и бэкап", "Export and backup")).font(.headline)
                        Text(L("Архив содержит переписки, профили, память и файлы. Ключи, cookies и веса моделей не включаются.", "The archive contains chats, profiles, memory and files. Keys, cookies and model weights are excluded."))
                        Button(L("Экспортировать ZIP / создать бэкап", "Export ZIP / create backup"),action:model.export)
                        Button(L("Восстановить из ZIP", "Restore from ZIP"),action:model.restore).disabled(model.running)
                        Spacer()
                    }.padding()
                } }.frame(maxHeight:.infinity)
            }
            .disabled(model.running)
            if model.snapshot?.settings.provider == "ollama" {
                HStack {
                    Button(L("Загрузить Ollama", "Load Ollama")) { model.perform { _ = try await model.api("/engine/load",[:]) } }
                    Button(L("Выгрузить Ollama", "Unload Ollama")) { model.perform { _ = try await model.api("/engine/unload",[:]) } }
                }.disabled(model.running)
                Text(L("Действует на сохранённые настройки Ollama. Адрес сервера определяет, где работает модель.", "Uses saved Ollama settings. The server address determines where the model runs.")).font(.caption)
            }
            if model.snapshot?.settings.provider == "openai" { Text(L("Загрузкой и выгрузкой модели управляет сервер API.", "The API server manages loading and unloading models.")).font(.caption) }
            if model.running { Text(L("Модель работает. Настройки можно закрыть без сохранения — ответ продолжит генерироваться.", "The model is running. Close settings without saving; generation will continue.")).font(.caption).foregroundStyle(.secondary) }
            if !model.error.isEmpty { Text(model.error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button(L("Закрыть без сохранения", "Close without saving")) { model.settingsShown = false }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("settings.cancel").smokeControl("settings.cancel")
                Spacer()
                Button(L("Сохранить", "Save"),action: { save(fetch: false) }).disabled(model.running)
                Button(L("Сохранить и закрыть", "Save and close")) { save(fetch:false, close:true) }.disabled(model.running)
            }
        }.padding(24).frame(width: 1000,height: 720).modifier(AppTheme()).tint(.gray).accentColor(.gray).buttonStyle(MonochromeButton()).interactiveDismissDisabled()
        .onAppear {
            if let s = model.snapshot?.settings { imageProvider=s.imageProvider ?? "cloud"; imageLocalModel=s.imageLocalModel ?? ""; imageCompute=s.imageCompute ?? "auto"; imageWidth=s.imageWidth ?? 512; imageHeight=s.imageHeight ?? 512; imageSteps=s.imageSteps ?? 20; imageCFG=s.imageCFG ?? 7; imageEnabled=s.imageEnabled ?? false; imageBase=s.imageBaseURL ?? ""; imageModel=s.imageModel ?? ""; thermalEnabled=s.thermalEnabled ?? false; thermalLimit=s.thermalLimit ?? 80; mode=s.mode; provider=s.provider; base=s.baseURL; selectedModel=s.model; limit=s.contextLimit;serverLimit=s.serverContextLimit ?? 0; temperature=s.temperature; toolsEnabled=s.toolsEnabled;searchProvider=s.searchProvider ?? "brave" }
            imageKey=Keys.get("image"); modelKey=Keys.get("model"); braveKey=Keys.get("brave");tavilyKey=Keys.get("tavily");serperKey=Keys.get("serper")
            profileID=model.chat?.profileID ?? model.snapshot?.profiles.first?.id ?? ""; loadProfile(profileID)
        }
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
        guard !model.running else { return }
        model.error = ""
        model.perform {
            _ = try await model.api("/settings", ["imageProvider":imageProvider,"imageLocalModel":imageLocalModel,"imageCompute":imageCompute,"imageWidth":imageWidth,"imageHeight":imageHeight,"imageSteps":imageSteps,"imageCFG":imageCFG,"imageEnabled":imageEnabled,"imageBaseURL":imageBase,"imageModel":imageModel,"thermalEnabled":thermalEnabled,"thermalLimit":thermalLimit,"mode":mode,"provider":provider,"baseURL":base,"model":selectedModel,"contextLimit":limit,"serverContextLimit":serverLimit,"temperature":temperature,"toolsEnabled":toolsEnabled,"searchProvider":searchProvider])
            try Keys.set("image",imageKey); try Keys.set("model",modelKey); try Keys.set("brave",braveKey);try Keys.set("tavily",tavilyKey);try Keys.set("serper",serperKey)
            _ = try await model.api("/keys", ["image":imageKey,"model":modelKey,"brave":braveKey,"tavily":tavilyKey,"serper":serperKey])
            if !profileName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                let r = try await model.api("/profile",["id":profileID,"name":profileName,"prompt":prompt])
                if let id=r["id"] as? String { profileID=id }
            }
            if load { _ = try await model.api("/local/load",["path":selectedModel]) }
            if close { model.settingsShown=false }
            if fetch { let r=try await model.api("/models"); models=r["models"] as? [String] ?? []; notice=L("Получено моделей: \(models.count)", "Models received: \(models.count)") }
            else { notice=L("Настройки сохранены", "Settings saved") }
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
            Text(model.project?.name ?? L("Проект", "Project")).font(.title)
            VStack(spacing:8) {
                HStack {
                    ForEach(Array([L("Скиллы", "Skills"),L("Память и файлы", "Memory and files"),L("Журнал", "Log")].enumerated()),id: \.offset) { index,title in
                        Button(title) { inspectorTab=index }.background(inspectorTab == index ? Color.primary.opacity(0.15) : Color.clear).clipShape(RoundedRectangle(cornerRadius:7))
                    }
                }
                Group { if inspectorTab == 0 {
                VStack(alignment: .leading,spacing: 10) {
                    HStack { Button(L("Импортировать скилл", "Import skill"),action: model.importSkill); Button(L("Обновить каталог", "Refresh catalog")) { model.perform { _ = try await model.api("/skills/refresh",["projectID":model.projectID]) } }; Spacer(); Text(L("Автовыбор по triggers / названию; переключатели — ручной выбор", "Auto-select by triggers / name; toggles select manually")).font(.caption) }
                    List(model.project?.skills ?? []) { skill in
                        VStack(alignment: .leading,spacing: 5) {
                            Toggle(skill.name,isOn: Binding(get: { model.chat?.skillIDs.contains(skill.id) ?? false },set: { _ in model.toggleSkill(skill.id) }))
                            Text(skill.description).font(.caption)
                            Text(skill.dependencies.map { "\($0.name): \($0.available ? L("найден", "found") : L("нет", "missing"))" }.joined(separator: "; ")).font(.caption)
                            if !skill.requiredKeys.isEmpty { Text(L("Упомянутые ключи: ", "Mentioned keys: ")+skill.requiredKeys.joined(separator: ", ")).font(.caption) }
                            Text(skill.dependencyNotice).font(.caption).foregroundStyle(.secondary)
                            Button(L("Убрать из библиотеки", "Remove from library")) { model.perform { _ = try await model.api("/skill/remove", ["projectID":model.projectID,"id":skill.id]) } }.font(.caption)
                        }.padding(.vertical,5)
                    }
                }.padding() } else if inspectorTab == 1 {
                VStack(alignment: .leading) {
                    Text(L("Память редактируется вручную. Модель не записывает сюда факты сама.", "Memory is edited manually. The model does not write facts here on its own.")).font(.caption)
                    TextEditor(text: $memory)
                    Button(L("Сохранить память", "Save memory")) { model.perform { _ = try await model.api("/project/update", ["projectID":model.projectID,"memory":memory]) } }
                    Divider(); Text(L("Папка для файловых инструментов:", "File tool folder:")).bold(); Text(model.project?.workspace ?? "").textSelection(.enabled)
                    Button(L("Выбрать папку…", "Choose folder…"),action: model.chooseWorkspace)
                    Text(L("Поиск пока буквальный по текстовым файлам; не RAG. PDF/картинки прикрепляй к сообщению для извлечения текста.", "Search is literal over text files, not RAG. Attach PDFs/images to a message to extract text.")).font(.caption)
                }.padding() } else {
                ScrollView {
                    VStack(alignment: .leading,spacing: 8) {
                        ForEach(Array((model.project?.log ?? []).reversed().enumerated()),id: \.offset) { _,entry in
                            Text("\(entry.time) · \(entry.event)\n\(entry.detail)").font(.system(.caption,design: .monospaced)).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity,alignment: .leading)
                }.padding() } }.frame(maxHeight:.infinity)
            }
            if !embedded { Button(L("Закрыть", "Close")) { model.inspectorShown=false } }
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
        }.windowResizability(.contentMinSize).defaultSize(width:1100,height:760).commands { CommandGroup(replacing: .newItem) { Button(L("Новый чат", "New chat"),action:model.newChat).keyboardShortcut("n"); Button(L("Настройки", "Settings")) { model.settingsShown=true }.keyboardShortcut(",") } }
    }
}

struct CatalogModel: Identifiable { let id: String; let downloads: Int; var task: String = "unknown" }
struct CatalogFile: Identifiable { let name: String; let size: Int64; var id: String { name } }
struct LocalLibraryModel: Identifiable { let path: String; let name: String; let size: Int64; var kind: String = "text"; var id: String { path } }
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
    @State var tab = 0
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Text(L("Модели", "Models")).font(.title2); Spacer(); if !embedded { Button(L("Закрыть", "Close")) { model.exploreShown=false } } }
            HStack { TextField(L("Поиск моделей в Hugging Face", "Search models on Hugging Face"),text:$query).onSubmit(search); Button(L("Найти", "Search"),action:search).disabled(busy); Button(L("Открыть GGUF…", "Open GGUF…"),action:browse) }
            HStack(alignment:.top,spacing:12) {
                VStack(alignment:.leading) {
                    Text(L("Поиск совместимых GGUF", "Compatible GGUF search")).font(.headline)
                    List(results) { item in
                        Button { select(item.id) } label: { VStack(alignment:.leading) { Text(item.id).lineLimit(2); Text(item.task == "unknown" ? L("Назначение не указано", "Purpose not specified") : item.task).font(.caption) } }.buttonStyle(.plain)
                    }.frame(minHeight:110,maxHeight:180)
                    Text(repo.isEmpty ? L("Выбери модель слева", "Select a model on the left") : repo).font(.caption).lineLimit(2)
                    List(files) { file in
                        VStack(alignment:.leading) { Text(file.name).lineLimit(2); Text(size(file.size)+" · "+fit(file.size)).font(.caption); Button(L("Скачать", "Download")) { download(file) }.disabled(busy) }
                    }
                }.frame(maxWidth:.infinity)
                Divider()
                VStack(alignment:.leading) {
                    HStack { Text(L("Скачанные модели", "Downloaded models")).font(.headline); Spacer(); Button(L("Обновить", "Refresh"),action:loadLibrary) }
                    List(library.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { item in
                        VStack(alignment:.leading,spacing:6) {
                            Text(item.name).lineLimit(2)
                            Text(libraryDescription(item)).font(.caption)
                            HStack { if item.kind != "image" { Button(L("Загрузить в память", "Load into memory")) { load(item.path) }.disabled(model.running) }; Button(L("Удалить…", "Delete…")) { model.deleteModel(item.path) { loadLibrary() } }.disabled(model.running || busy).accessibilityIdentifier("model.delete").smokeControl("model.delete") }
                        }.padding(.vertical,4)
                    }
                }.frame(maxWidth:.infinity)
            }
            Text(L("Скачивания", "Downloads")).font(.headline)
            ScrollView { VStack(alignment:.leading) { ForEach(model.snapshot?.downloads ?? []) { d in
                VStack(alignment:.leading,spacing:4) {
                    Text(d.file).lineLimit(1); ProgressView(value:Double(d.bytes),total:Double(max(d.total,d.bytes,1)))
                    HStack { Text(size(d.bytes)+" / "+size(d.total)+" · "+status(d.status)).font(.caption)
                        if d.status == "downloading" { Button(L("Пауза", "Pause")) { control(d.id,"pause") } }
                        if ["paused","error","cancelled"].contains(d.status) { Button(L("Продолжить", "Resume")) { control(d.id,"resume") } }
                        if d.status != "complete" && d.status != "verifying" { Button(L("Отменить", "Cancel")) { control(d.id,"cancel") } }
                    }
                    if !d.error.isEmpty { Text(d.error).font(.caption) }
                }.padding(.vertical,4)
            } } }.frame(maxHeight:130)
            if busy { ProgressView().controlSize(.small) }
            Text(notice).font(.caption).lineLimit(3).textSelection(.enabled)
        }.padding(20).frame(width:embedded ? nil : 900,height:embedded ? nil : 680).modifier(AppTheme()).tint(.gray).accentColor(.gray).buttonStyle(MonochromeButton())
        .onAppear(perform:loadLibrary).onChange(of:model.snapshot?.downloads?.filter { $0.status == "complete" }.count) { _ in loadLibrary() }
    }
    func libraryDescription(_ item: LocalLibraryModel) -> String {
        let kind=item.kind == "image" ? L("Изображения", "Images") : L("Текст", "Text")
        let active=model.snapshot?.localModel?.path == item.path && model.snapshot?.localModel?.status == "ready"
        return size(item.size)+" · "+kind+" · "+(active ? L("В памяти", "In memory") : L("На диске", "On disk"))
    }
    func size(_ n:Int64)->String { ByteCountFormatter.string(fromByteCount:n,countStyle:.file) }
    func fit(_ n:Int64)->String {
        let ram=Int64(ProcessInfo.processInfo.physicalMemory)
        if n == 0 { return L("размер неизвестен", "size unknown") }
        return n > ram * 7 / 10 ? L("мало запаса RAM; выбери меньше", "limited RAM headroom; choose a smaller model") : L("есть запас RAM; контекст потребует дополнительную память", "RAM headroom available; context needs additional memory")
    }
    func status(_ s:String)->String { ["downloading":L("скачивание", "downloading"),"paused":L("пауза", "paused"),"error":L("ошибка", "error"),"complete":L("готово", "done"),"verifying":L("проверка файла", "verifying file"),"cancelled":L("отменено", "cancelled"),"cancelling":L("отмена", "cancelling")][s] ?? s }
    func search() {
        busy=true; notice=""
        Task { defer { busy=false }; do {
            let r=try await model.api("/explore/search",["query":query]); results=(r["models"] as? [[String:Any]] ?? []).compactMap { v in guard let id=v["id"] as? String else{return nil};return CatalogModel(id:id,downloads:v["downloads"] as? Int ?? 0,task:v["task"] as? String ?? "unknown") }
            if results.isEmpty { notice=L("Модели не найдены", "No models found") }
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
        let r=try await model.api("/local/library");library=(r["models"] as? [[String:Any]] ?? []).compactMap { v in guard let path=v["path"] as? String else{return nil};return LocalLibraryModel(path:path,name:v["name"] as? String ?? path,size:(v["size"] as? NSNumber)?.int64Value ?? 0,kind:v["kind"] as? String ?? "text") }
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
            Text(L("Выбор модели", "Choose model")).font(.headline)
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
            if model.snapshot?.settings.provider == "local" { Button(L("Открыть GGUF…", "Open GGUF…"),action:browse) }
            if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false, vertical:true) }
            HStack {
                Button(L("Настройки модели", "Model settings")) { isPresented=false; model.settingsShown=true }
                Spacer(); Button(L("Закрыть", "Close")) { isPresented=false }
            }
        }.padding(18).frame(width:460).fixedSize(horizontal:false, vertical:true).buttonStyle(MonochromeButton())
        .task {
            if !previewChoices.isEmpty { choices=previewChoices; return }
            do {
                if model.snapshot?.settings.provider == "local" {
                    let data=try await model.api("/local/library")
                    choices=(data["models"] as? [[String:Any]] ?? []).filter { ($0["kind"] as? String) != "image" }.compactMap { $0["path"] as? String }
                } else {
                    let data=try await model.api("/models"); choices=data["models"] as? [String] ?? []
                }
                if choices.isEmpty { notice=L("В библиотеке нет моделей. Выбери файл или открой Explore в настройках.", "No models in the library. Choose a file or open Models in settings.") }
            } catch { notice=error.localizedDescription }
        }
    }
    func displayName(_ value:String) -> String {
        model.snapshot?.settings.provider == "local" ? URL(fileURLWithPath:value).lastPathComponent : value
    }
    var currentModelName: String {
        guard let value=model.snapshot?.settings.model, !value.isEmpty else { return L("Не выбрана", "Not selected") }
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


enum DocumentReader {
    static func recognize(_ data: Data) throws -> String {
        let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate
        request.recognitionLanguages=["ru-RU","en-US"];request.usesLanguageCorrection=true
        try VNImageRequestHandler(data:data).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator:"\n")
    }
    static func extract(_ url: URL) throws -> String {
        if url.pathExtension.lowercased() != "pdf" {
            let text=try recognize(Data(contentsOf:url))
            guard !text.isEmpty else { throw AppError(message:L("Текст на картинке не распознан. Описание объектов моделью не подключено.", "No text recognized in the image. Visual object descriptions are not connected.")) }
            return text
        }
        guard let doc=PDFDocument(url:url), !doc.isLocked else { throw AppError(message:L("PDF не открылся или защищён паролем", "Cannot open PDF or it is password protected")) }
        guard doc.pageCount<=400 else { throw AppError(message:L("PDF больше 400 страниц; раздели файл. Страницы не обрезаны.", "PDF exceeds 400 pages; split the file. No pages were truncated.")) }
        var result=""
        for i in 0..<doc.pageCount {
            let text: String = try autoreleasepool {
                guard let page=doc.page(at:i) else { throw AppError(message:L("Не удалось прочитать страницу \(i+1)", "Could not read page \(i+1)")) }
                let embedded=(page.string ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
                let image=page.thumbnail(of:NSSize(width:1800,height:2400),for:.mediaBox)
                guard let data=image.tiffRepresentation else { throw AppError(message:L("Не удалось распознать страницу \(i+1)", "Could not recognize page \(i+1)")) }
                let recognized=try recognize(data)
                if embedded.isEmpty { return recognized.isEmpty ? L("[Текст не распознан или страница пуста]", "[No text recognized or page is blank]") : recognized }
                let known=Set(embedded.components(separatedBy:.newlines).map { $0.trimmingCharacters(in:.whitespaces) })
                let extra=recognized.components(separatedBy:.newlines).filter { !known.contains($0.trimmingCharacters(in:.whitespaces)) }.joined(separator:"\n")
                return embedded + (extra.isEmpty ? "" : L("\n[Дополнительно распознано на странице]\n", "\n[Additional recognized text on page]\n")+extra)
            }
            result += L("[Страница \(i+1)]\n", "[Page \(i+1)]\n") + text + "\n"
            guard result.count<=2_000_000 else { throw AppError(message:L("Документ больше 2 млн символов; раздели файл. Текст не обрезан.", "Document exceeds 2 million characters; split the file. No text was truncated.")) }
        }
        return result
    }
}
