import AppKit
import SwiftUI
import Foundation
import PDFKit

// Geometry anchors exist only in the isolated smoke launch. Events still pass through
// the real NSWindow hit-testing and SwiftUI button/checkbox dispatch, never actions directly.
@MainActor final class SmokeControlView: NSView {
    static let controls = NSMapTable<NSString, SmokeControlView>(keyOptions: .strongMemory, valueOptions: .weakMemory)
    var testValue = ""
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
struct SmokeControlAnchor: NSViewRepresentable {
    var identifier: String
    var value: String
    func makeNSView(context: Context) -> SmokeControlView { SmokeControlView(frame: .zero) }
    func updateNSView(_ view: SmokeControlView, context: Context) {
        view.testValue = value
        SmokeControlView.controls.setObject(view, forKey: identifier as NSString)
    }
}
extension View {
    @ViewBuilder func smokeControl(_ identifier: String, value: String = "") -> some View {
        if CommandLine.arguments.contains("--smoke-test") {
            self.background(SmokeControlAnchor(identifier: identifier, value: value))
        } else { self }
    }
}

@MainActor func runNativeSmoke(model: AppModel, delegate: AppDelegate, reportPath: String) async {
    var checks: [String] = []
    var report: [String: Any] = [:]
    func require(_ condition: Bool, _ name: String) throws {
        guard condition else { throw AppError(message: "Smoke check failed: " + name) }
        checks.append(name)
    }
    // Render our own app view; no desktop Screen Recording entitlement is needed.
    func capture(_ suffix: String, _ target: NSWindow) throws {
        guard let view = target.contentView else { throw AppError(message: "Window content absent") }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw AppError(message: "Window bitmap unavailable") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw AppError(message: "Window PNG unavailable") }
        try data.write(to: URL(fileURLWithPath: reportPath + "-" + suffix + ".png"))
    }
    do {
        try require(model.port > 0 && model.snapshot != nil && model.error.isEmpty, "native app launched embedded backend and decoded state")
        try require(NSApp.activationPolicy() == .regular, "regular Dock application activation policy")
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain }) else { throw AppError(message: "Main window absent") }
        delegate.mainWindow = window
        try require(window.isVisible && window.frame.width > 300, "main window visible")
        model.settingsShown = false
        try await Task.sleep(nanoseconds: 700_000_000)
        let savedTheme = UserDefaults.standard.string(forKey: "appearanceTheme") ?? "dark"
        for theme in ["light", "dark"] {
            UserDefaults.standard.set(theme, forKey: "appearanceTheme")
            let expected: NSAppearance.Name = theme == "light" ? .aqua : .darkAqua
            for _ in 0..<30 {
                if NSApp.appearance?.bestMatch(from: [.aqua,.darkAqua]) == expected { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            try require(NSApp.appearance?.bestMatch(from: [.aqua, .darkAqua]) == expected, "persistent " + theme + " theme applied to native app")
        }
        UserDefaults.standard.set(savedTheme, forKey: "appearanceTheme")
        try await Task.sleep(nanoseconds: 300_000_000)
        let input = Composer.Input(frame:NSRect(x:0,y:0,width:200,height:80))
        var submissions=0
        input.submit = { submissions += 1 }
        input.enterSends=true
        let enter=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)!
        input.keyDown(with:enter)
        try require(submissions == 1, "Enter submits in default composer mode")
        input.enterSends=false
        window.contentView?.addSubview(input); window.makeFirstResponder(input)
        input.keyDown(with:enter)
        try require(submissions == 1 && input.string.contains("\n"), "Enter inserts newline when send preference disabled")
        input.enterSends=true
        let shiftEnter=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.shift,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)!
        input.string=""; input.keyDown(with:shiftEnter)
        try require(submissions == 1 && input.string.contains("\n"), "Shift Enter inserts newline in send mode")
        let cmdEnter=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)!
        input.enterSends=false; input.keyDown(with:cmdEnter)
        try require(submissions == 2, "Command Enter submits in newline mode")
        input.removeFromSuperview()
        let savedEnter = UserDefaults.standard.object(forKey:"enterSends")
        UserDefaults.standard.set(false,forKey:"enterSends")
        try require(!UserDefaults.standard.bool(forKey:"enterSends"), "composer preference persisted")
        if let saved=savedEnter { UserDefaults.standard.set(saved,forKey:"enterSends") } else { UserDefaults.standard.removeObject(forKey:"enterSends") }
        try require(model.snapshot?.usage != nil && model.snapshot?.thermal != nil, "native telemetry decoded, absent sensors remain optional")
        if let flag = CommandLine.arguments.firstIndex(of: "--chat-model"), CommandLine.arguments.count > flag + 1 {
            let path = CommandLine.arguments[flag+1]
            _ = try await model.api("/settings", ["provider":"local", "model":path, "contextLimit":4096, "temperature":0, "toolsEnabled":false])
            let created = try await model.api("/project", ["name":"Проверка чата на Mac"])
            try await model.refresh()
            model.projectID = created["id"] as? String ?? ""
            try await model.refresh()
            model.draft = "Say hello in one short sentence. /no_think"
            model.send()
            var finished = false
            for _ in 0..<240 {
                try await Task.sleep(nanoseconds: 500_000_000)
                try await model.refresh()
                if let job = model.snapshot?.jobs.first, job.status != "running" {
                    try require(job.status == "done", "native chat completed: " + job.error)
                    finished = true
                    break
                }
            }
            try require(finished, "native send/refresh completed within timeout")
            try require(!(model.chat?.messages.last?.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true), "real model reply reached native chat state")
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--image-smoke-base"), CommandLine.arguments.count > flag + 1 {
            let base = CommandLine.arguments[flag+1]
            _ = try await model.api("/settings", ["mode":"cloud", "provider":"openai", "baseURL":base, "model":"fixture-chat", "toolsEnabled":true, "imageEnabled":true, "imageProvider":"cloud", "imageBaseURL":base, "imageModel":"gpt-image-fixture"])
            _ = try await model.api("/keys", ["image":"fixture-image-key", "model":"fixture-chat-key"])
            try await model.refresh()
            model.draft = "Generate the fixture image"
            model.send()
            var finished = false
            for _ in 0..<120 {
                try await Task.sleep(nanoseconds:250_000_000)
                try await model.refresh()
                for pending in model.snapshot?.pending ?? [] where pending.kind == "approval" {
                    _ = try await model.api("/resolve", ["id":pending.id,"response":["approved":true,"scope":"once"]])
                }
                if let job = model.snapshot?.jobs.first, job.status != "running" {
                    try require(job.status == "done", "image tool chat finished: " + job.error)
                    finished = true; break
                }
            }
            try require(finished, "image tool chat completed within timeout")
            guard let artifact = model.chat?.messages.compactMap({ $0.artifacts?.first }).first else { throw AppError(message:"Image artifact absent from native chat") }
            let result = try await model.api("/artifact/path", ["projectID":model.projectID,"path":artifact.path])
            guard let path = result["path"] as? String, let preview = NSImage(contentsOfFile:path) else { throw AppError(message:"Image preview failed") }
            try require(preview.isValid, "generated image decoded by native preview")
            let bytes = try Data(contentsOf:URL(fileURLWithPath:path))
            let saved = URL(fileURLWithPath:reportPath + "-saved.png")
            try bytes.write(to:saved,options:.atomic)
            let savedBytes = try Data(contentsOf:saved)
            try require(bytes == savedBytes, "image Save As atomic copy preserves bytes")
            try require(model.snapshot?.settings.imageModel == "gpt-image-fixture" && model.snapshot?.settings.model == "fixture-chat", "independent image and chat settings decoded")
        }
        model.settingsShown = true
        try await Task.sleep(nanoseconds:700_000_000)
        try require(!window.sheets.isEmpty, "updated settings sheet opens")
        model.settingsShown = false
        model.polling?.cancel()
        if !CommandLine.arguments.contains("--skip-capture") {
        model.snapshot?.settings.model="/Models/Very-Long-Model-Repository/Qwen3-27B-Turbo-Fusion-Example-Uncensored-Coder-MAX-Q4_K_M.gguf"
        window.setContentSize(NSSize(width:900,height:650))
        try await Task.sleep(nanoseconds:500_000_000)
        try capture("main-min",window)
        try require(window.contentView!.bounds.width >= 900, "minimum main window width enforced")
        model.settingsShown=true
        try await Task.sleep(nanoseconds:700_000_000)
        if let sheet=window.sheets.first { try capture("settings",sheet) } else { throw AppError(message:"Settings sheet absent") }
        model.settingsShown=false
        try await Task.sleep(nanoseconds:400_000_000)
        model.exploreShown=true
        try await Task.sleep(nanoseconds:700_000_000)
        if let sheet=window.sheets.first { try capture("explore",sheet) } else { throw AppError(message:"Explore sheet absent") }
        model.exploreShown=false
        try await Task.sleep(nanoseconds:400_000_000)
        checks.append("native minimum-size main/settings/Explore screenshots captured")
        }
        if CommandLine.arguments.contains("--picker-capture") {
            model.snapshot?.settings.provider="local"
            let fixtures=(1...8).map { "/Models/Example-Repository/Qwen3-27B-Turbo-Fusion-Long-Model-Name-Variant-\($0)-Q4_K_M.gguf" }
            model.snapshot?.settings.model=fixtures[0]
            let host=NSHostingView(rootView:ModelPickerPopup(model:model,isPresented:.constant(true),previewChoices:fixtures))
            let panel=NSWindow(contentRect:NSRect(x:100,y:100,width:496,height:430),styleMask:[.titled],backing:.buffered,defer:false)
            panel.contentView=host; panel.makeKeyAndOrderFront(nil)
            try await Task.sleep(nanoseconds:1_000_000_000)
            host.layoutSubtreeIfNeeded()
            guard let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) else { throw AppError(message:"Picker bitmap missing") }
            host.cacheDisplay(in:host.bounds,to:bitmap)
            guard let png=bitmap.representation(using:.png,properties:[:]) else { throw AppError(message:"Picker PNG missing") }
            try png.write(to:URL(fileURLWithPath:reportPath+"-picker.png"))
            try require(host.bounds.height >= 350,"model picker list has stable height with long filenames")
            panel.orderOut(nil)
        }
        let markdownFixture = "# Заголовок\n\n| Имя | Значение |\n| --- | --- |\n| Один | **Два** |\n\n```swift\nlet x = 1\n```\n> Цитата\n- Пункт"
        let blocks = MarkdownBlocks.parse(markdownFixture)
        try require(blocks.contains(.heading(1, "Заголовок")) && blocks.contains(.table([["Имя","Значение"],["Один","**Два**"]])) && blocks.contains(.code("swift","let x = 1")), "block Markdown parses heading, table and fenced code")
        try require(MarkdownBlocks.parse("```\npartial").contains(.code("","partial")), "streaming unfinished code fence is retained")
        let suite = "Inij-Draft-Test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let store = DraftStore(defaults:defaults)
        store.write("Первый", "p", "a"); store.write("Второй", "p", "b")
        let reloaded = DraftStore(defaults:UserDefaults(suiteName:suite)!)
        try require(reloaded.read("p","a") == "Первый" && reloaded.read("p","b") == "Второй" && reloaded.read("other","a").isEmpty, "draft reload preserves separate chat and project identities")
        store.write("", "p","a")
        try require(reloaded.read("p","a").isEmpty && reloaded.read("p","b") == "Второй", "sending one draft does not clear another")
        let pid = model.projectID; let cid = model.chatID
        let originalDraft = model.draft
        model.draft = "Draft A"
        model.chatID = "smoke-alternate-chat"
        model.draft = "Draft B"
        model.chatID = cid
        try require(model.draft == "Draft A", "native chat selection restores its own draft")
        model.chatID = "smoke-alternate-chat"
        try require(model.draft == "Draft B", "native alternate chat retains draft")
        model.draft = ""; model.projectID = pid; model.chatID = cid; model.draft = originalDraft
        let attachmentURL = FileManager.default.temporaryDirectory.appendingPathComponent("Inij-drop-" + UUID().uuidString + ".txt")
        try "Содержимое перетаскиваемого файла".write(to:attachmentURL,atomically:true,encoding:.utf8)
        defer { try? FileManager.default.removeItem(at:attachmentURL) }
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.writeObjects([attachmentURL as NSURL])
        try require(Composer.Input.fileURLs(pasteboard) == [attachmentURL], "native file drop decodes local Finder URL")
        pasteboard.releaseGlobally()
        model.attach(attachmentURL)
        for _ in 0..<30 {
            if model.draft.contains("Содержимое перетаскиваемого файла") { break }
            try await Task.sleep(nanoseconds:100_000_000)
        }
        try require(model.draft.contains("Содержимое перетаскиваемого файла"), "dropped-file import path extracts text into current draft")
        model.draft = originalDraft
        let transcript = ChatTranscript.textView(title:"Проверка PDF",messages:[ChatMessage(role:"assistant",content:markdownFixture)],size:14)
        let pdf = transcript.dataWithPDF(inside:transcript.bounds)
        try require(pdf.starts(with:Data("%PDF".utf8)) && pdf.count > 500, "chat transcript renders an actual PDF")
        try pdf.write(to:URL(fileURLWithPath:reportPath + "-chat.pdf"))
        let renderedHost = NSHostingView(rootView:ChatMessageText(content:markdownFixture).padding(20).frame(width:620,height:460,alignment:.topLeading))
        let renderedWindow = NSWindow(contentRect:NSRect(x:100,y:100,width:620,height:460),styleMask:[.titled],backing:.buffered,defer:false)
        renderedWindow.contentView=renderedHost; renderedWindow.makeKeyAndOrderFront(nil)
        try await Task.sleep(nanoseconds:300_000_000)
        renderedHost.layoutSubtreeIfNeeded()
        guard let bitmap=renderedHost.bitmapImageRepForCachingDisplay(in:renderedHost.bounds) else { throw AppError(message:"Markdown bitmap missing") }
        renderedHost.cacheDisplay(in:renderedHost.bounds,to:bitmap)
        guard let png=bitmap.representation(using:.png,properties:[:]) else { throw AppError(message:"Markdown PNG missing") }
        try png.write(to:URL(fileURLWithPath:reportPath+"-markdown.png"))
        renderedWindow.orderOut(nil)
        checks.append("block Markdown native view rendered to PNG")
        let richSource = "**Новости**\n[Источник](https://example.com/news?q=1) и *курсив*\nОбычный URL: https://example.org/page\n`https://code.example/path`"
        let rich = ChatMarkdown.render(richSource)
        try require(String(rich.characters).contains("Новости\nИсточник и курсив\n"), "Markdown labels and Cyrillic line breaks preserved")
        try require(rich.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }, "Markdown bold is attributed")
        try require(rich.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true }, "Markdown emphasis is attributed")
        let targets = rich.runs.compactMap { $0.link?.absoluteString }
        try require(targets.contains("https://example.com/news?q=1") && targets.contains("https://example.org/page"), "semantic and plain web URLs have clickable link attributes")
        try require(!targets.contains("https://code.example/path"), "inline code is not auto-linked")
        let unsafe = ChatMarkdown.render("[файл](file:///etc/passwd) [скрипт](javascript:alert) [ssh](ssh://host)")
        try require(unsafe.runs.allSatisfy { $0.link == nil }, "unsafe URL schemes removed")
        try require(!ChatMarkdown.safeURL(URL(string:"file:///tmp/test")!) && ChatMarkdown.safeURL(URL(string:"https://example.com")!), "click routing only allows HTTP and HTTPS")
        for prefix in ["", "**Нов", "[Источ", "[Источник](https://exa", "Строка\n\nследующая"] {
            _ = ChatMarkdown.render(prefix)
        }
        try require(String(ChatMarkdown.render("Строка\n\nследующая").characters) == "Строка\n\nследующая", "streaming partial Markdown tolerates incomplete syntax and blank lines")
        if CommandLine.arguments.contains("--links-capture") {
            let host = NSHostingView(rootView: ChatMessageText(content: richSource).padding(20).frame(width:600,height:250,alignment:.topLeading))
            let panel=NSWindow(contentRect:NSRect(x:100,y:100,width:600,height:250),styleMask:[.titled],backing:.buffered,defer:false)
            panel.contentView=host; panel.makeKeyAndOrderFront(nil)
            try await Task.sleep(nanoseconds:1_000_000_000)
            host.layoutSubtreeIfNeeded()
            guard let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) else { throw AppError(message:"Links bitmap missing") }
            host.cacheDisplay(in:host.bounds,to:bitmap)
            guard let png=bitmap.representation(using:.png,properties:[:]) else { throw AppError(message:"Links PNG missing") }
            try png.write(to:URL(fileURLWithPath:reportPath+"-links.png"))
            panel.orderOut(nil)
        }
        window.orderOut(nil)
        _ = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        try require(window.isVisible, "Dock reopen handler restores main window")
        let key = "ci-smoke-" + UUID().uuidString
        defer { try? Keys.set(key, "") }
        if CommandLine.arguments.contains("--skip-keychain") {
            report["limitations"] = ["Keychain not tested: login keychain unavailable in CI session"]
        } else {
            try Keys.set(key, "smoke-test-only")
            try require(Keys.get(key) == "smoke-test-only", "Keychain save and reload")
        }
        model.browser.allow(true)
        model.browser.webView.loadHTMLString("<html><body><h1>Native smoke fixture</h1><input placeholder='Test input'><button onclick=\"document.getElementById('result').innerText='clicked'\">Click</button><p id='result'>ready</p></body></html>", baseURL: URL(string: "http://localhost/"))
        var page: [String: Any] = [:]
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            page = (try? await model.browser.read()) ?? [:]
            if (page["text"] as? String ?? "").contains("Native smoke fixture") { break }
        }
        try require((page["text"] as? String ?? "").contains("Native smoke fixture"), "WebKit loads and reads document")
        let elements = page["elements"] as? [[String: Any]] ?? []
        guard let input = elements.first(where: { $0["tag"] as? String == "INPUT" })?["ref"] as? String,
              let button = elements.first(where: { $0["tag"] as? String == "BUTTON" })?["ref"] as? String else { throw AppError(message: "Missing browser refs") }
        try await model.browser.act("browser_fill", arguments: ["ref": .string(input), "text": .string("hello")])
        let value = try await model.browser.webView.evaluateJavaScript("document.querySelector('input').value") as? String
        try require(value == "hello", "WebKit fills observed input")
        page = try await model.browser.read()
        guard let freshButton = (page["elements"] as? [[String: Any]])?.first(where: { $0["tag"] as? String == "BUTTON" })?["ref"] as? String else { throw AppError(message: "Missing fresh button ref") }
        try await model.browser.act("browser_click", arguments: ["ref": .string(freshButton)])
        page = try await model.browser.read()
        try require((page["text"] as? String ?? "").contains("clicked"), "WebKit clicks observed button")
        do {
            try await model.browser.act("browser_click", arguments: ["ref": .string(button)])
            throw AppError(message: "Stale browser ref unexpectedly accepted")
        } catch let error as AppError {
            try require(error.message.contains("устарела"), "WebKit rejects stale reference")
        }
        // Exercise the actual SwiftUI controls with hit-tested mouse events, not the model closure.
        func clickControl(_ identifier: String, in target: NSWindow? = nil) async throws {
            let window = target ?? window
            window.contentView?.layoutSubtreeIfNeeded()
            guard let root = window.contentView, let anchor = SmokeControlView.controls.object(forKey: identifier as NSString), anchor.window === window else {
                throw AppError(message: "Control not mounted in the expected window: " + identifier)
            }
            let rect = anchor.convert(anchor.bounds, to: nil)
            try require(rect.width > 10 && rect.height > 10, identifier + " has a visible click target")
            let point = NSPoint(x: identifier == "settings.tools" ? rect.maxX - 8 : rect.midX, y: rect.midY)
            guard let hit = root.hitTest(root.convert(point, from: nil)), !hit.isHidden else {
                throw AppError(message: "Control is not hit-testable: " + identifier)
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try await Task.sleep(nanoseconds: 200_000_000)
            guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
                  let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.05, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0) else {
                throw AppError(message: "Cannot create control mouse events")
            }
            // sendEvent routes through the window's real hit test. Queue the matching
            // mouse-up first so AppKit's synchronous button tracking can consume it.
            NSApp.postEvent(up, atStart: true)
            window.sendEvent(down)
            window.sendEvent(up)
            var trace = report["mouse_events"] as? [String] ?? []
            trace.append(identifier + " " + NSStringFromRect(rect) + " hit=" + String(describing: type(of: hit)))
            report["mouse_events"] = trace
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        model.showBrowser = false
        try await Task.sleep(nanoseconds: 400_000_000)
        try await clickControl("browser.toggle")
        try require(model.showBrowser && model.browser.webView.window === window, "mouse click opens embedded browser")
        // Closing is also available offline; it only hides the panel and preserves its page.
        model.browser.enabled = false
        if !CommandLine.arguments.contains("--skip-capture") {
            try capture("browser-open", window)
            checks.append("browser close control view rendered")
        }
        try await clickControl("browser.close")
        try require(!model.showBrowser && model.browser.webView.window == nil, "mouse click on Close removes browser panel even offline")
        try require(window.isVisible && model.port > 0, "closing browser leaves chat window and backend running")
        try await clickControl("browser.toggle")
        try require(model.showBrowser && model.browser.webView.window === window, "mouse click reopens browser without settings")
        let retained = try await model.browser.webView.evaluateJavaScript("document.querySelector('input').value") as? String
        try require(retained == "hello", "browser page and entered text survive close and reopen")
        try await clickControl("browser.toggle")
        try require(!model.showBrowser, "toolbar mouse click can also hide browser")
        model.browser.allow(false)
        try require(!model.browser.enabled, "offline mode disables browser")
        if let flag = CommandLine.arguments.firstIndex(of: "--settings-busy-smoke-base"), CommandLine.arguments.count > flag + 1 {
            let base = CommandLine.arguments[flag + 1]
            _ = try await model.api("/settings", ["mode":"cloud", "provider":"openai", "baseURL":base, "model":"settings-stream-fixture", "toolsEnabled":false])
            try await model.refresh()
            let initialSettings = try JSONSerialization.data(withJSONObject: (try await model.api("/state"))["settings"] ?? [:], options: .sortedKeys)
            try await clickControl("settings.open")
            guard let idleSheet = window.sheets.first else { throw AppError(message: "Settings did not open for cancel test") }
            // This checkbox is a local draft. Dismissing must not call save or alter the backend.
            try await clickControl("settings.tools", in: idleSheet)
            let draftValue = SmokeControlView.controls.object(forKey: "settings.tools")?.testValue
            try require(draftValue == "on", "mouse edits tools checkbox in unsaved settings draft")
            try await clickControl("settings.close", in: idleSheet)
            try require(!model.settingsShown && window.sheets.isEmpty, "settings top Close responds to mouse and dismisses unsaved edits")
            let cancelledSettings = try JSONSerialization.data(withJSONObject: (try await model.api("/state"))["settings"] ?? [:], options: .sortedKeys)
            try require(initialSettings == cancelledSettings, "cancelled settings draft does not change saved backend parameters")
            model.draft = "Continue streaming while I open and close settings"
            model.send()
            for _ in 0..<40 {
                try await Task.sleep(nanoseconds:100_000_000)
                try await model.refresh()
                if model.running && !(model.chat?.messages.last?.content.isEmpty ?? true) { break }
            }
            guard let active = model.snapshot?.jobs.first(where: { $0.status == "running" }) else { throw AppError(message: "Streaming fixture did not start") }
            try require(model.running, "real backend streaming job is running before settings close")
            try await clickControl("settings.open")
            guard let busySheet = window.sheets.first else { throw AppError(message: "Settings did not open during generation") }
            if !CommandLine.arguments.contains("--skip-capture") { try capture("settings-busy", busySheet) }
            try await clickControl("settings.cancel", in: busySheet)
            try await model.refresh()
            try require(!model.settingsShown && window.sheets.isEmpty, "mouse closes settings without saving while generation is active")
            try require(model.snapshot?.jobs.first(where: { $0.id == active.id })?.status == "running", "closing settings does not stop the running generation")
            let busySettings = try JSONSerialization.data(withJSONObject: (try await model.api("/state"))["settings"] ?? [:], options: .sortedKeys)
            try require(initialSettings == busySettings, "closing busy settings leaves saved parameters unchanged")
            for _ in 0..<160 {
                try await Task.sleep(nanoseconds:100_000_000)
                try await model.refresh()
                if !model.running { break }
            }
            try require(model.snapshot?.jobs.first(where: { $0.id == active.id })?.status == "done", "same generation completes after settings dismissal")
            try require(model.chat?.messages.last?.content.contains("STREAM_COMPLETED") == true, "remaining streaming response reaches chat after closing settings")
        }
        if let flag=CommandLine.arguments.firstIndex(of:"--documents-smoke-base"),CommandLine.arguments.count>flag+1 {
            let base=CommandLine.arguments[flag+1]
            let fixture=FileManager.default.temporaryDirectory.appendingPathComponent("Inij-039-"+UUID().uuidString).resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at:fixture,withIntermediateDirectories:true)
            defer { try? FileManager.default.removeItem(at:fixture) }
            let image=NSImage(size:NSSize(width:1200,height:400));image.lockFocus()
            NSColor.white.setFill();NSRect(x:0,y:0,width:1200,height:400).fill()
            ("OCR SCAN MIDDLE 456" as NSString).draw(at:NSPoint(x:50,y:200),withAttributes:[.font:NSFont.systemFont(ofSize:48),.foregroundColor:NSColor.black]);image.unlockFocus()
            let bitmap=NSBitmapImageRep(data:image.tiffRepresentation!)!
            let png=fixture.appendingPathComponent("scan.png");try bitmap.representation(using:.png,properties:[:])!.write(to:png)
            let imageText=try await Task.detached { try DocumentReader.extract(png) }.value
            try require(imageText.contains("MIDDLE") && imageText.contains("456"),"offline Vision image OCR reads fixture")
            let textView=ChatTranscript.textView(title:"PDF",messages:[ChatMessage(role:"assistant",content:"PDF TEXT START 123")],size:24)
            let mixed=PDFDocument(data:textView.dataWithPDF(inside:textView.bounds))!
            mixed.insert(PDFPage(image:image)!,at:mixed.pageCount)
            let pdf=fixture.appendingPathComponent("mixed.pdf");try require(mixed.write(to:pdf),"mixed text/scanned PDF fixture saved")
            let recognized=try await Task.detached { try DocumentReader.extract(pdf) }.value
            try require(recognized.contains("START 123") && recognized.contains("MIDDLE") && recognized.contains("456"),"per-page extraction preserves text AND scanned pages in mixed PDF")
            model.draft=""
            model.attach(pdf)
            for _ in 0..<100 { if model.draft.contains("MIDDLE") { break };try await Task.sleep(nanoseconds:100_000_000) }
            try require(model.draft.contains("START 123") && model.draft.contains("MIDDLE"),"native PDF attachment uses offline mixed-page recognition")
            let large="START-123\n"+String(repeating:"Текст большого документа.\n",count:1600)+"MIDDLE-456\n"+String(repeating:"Текст большого документа.\n",count:1600)+"END-987"
            let file=fixture.appendingPathComponent("large.txt");try large.write(to:file,atomically:true,encoding:.utf8)
            model.draft="Найди маркеры."
            model.attach(file)
            for _ in 0..<100 { if model.draft.contains("END-987") { break };try await Task.sleep(nanoseconds:100_000_000) }
            try require(large.count>60000 && model.draft.contains(large),"native attachment imports over 60000 characters with beginning/middle/end intact")
            _ = try await model.api("/settings",["provider":"openai","mode":"offline","baseURL":base,"model":"fixture","toolsEnabled":false,"contextLimit":4096])
            model.send()
            for _ in 0..<500 { try await Task.sleep(nanoseconds:100_000_000);try await model.refresh();if let job=model.snapshot?.jobs.last,job.status != "running" { break } }
            try require(model.snapshot?.jobs.last?.status == "done","large document sent through native composer and fully processed: "+(model.snapshot?.jobs.last?.error ?? ""))
            let answer=model.chat?.messages.last?.content ?? ""
            try require(answer.contains("START-123") && answer.contains("MIDDLE-456") && answer.contains("END-987"),"all three distant markers reach native final answer")
            try require((model.chat?.messages.last?.artifacts ?? []).count == 3,"original, per-part results and coverage manifest exposed as chat files")
            try await Task.sleep(nanoseconds:1000_000_000)
            try require(SmokeControlView.controls.object(forKey:"document.artifact.original.txt")?.window === window,"document file card mounted visibly in native chat")
            if !CommandLine.arguments.contains("--skip-capture") { try capture("large-document",window) }
            // Test UI deletion using only tiny fixtures, never a user's weights.
            for kind in ["text","image"] {
                let path=fixture.appendingPathComponent(kind == "text" ? "fixture.gguf" : "fixture.safetensors")
                try Data([71,71,85,70,3,0,0,0,0,0,0,0]).write(to:path)
                if kind == "text" { _ = try await model.api("/settings",["provider":"local","model":path.path]) }
                else { _ = try await model.api("/settings",["imageLocalModel":path.path]) }
                try await model.refresh()
                let testWindow=NSWindow(contentRect:NSRect(x:120,y:100,width:850,height:650),styleMask:[.titled,.closable],backing:.buffered,defer:false)
                testWindow.isReleasedWhenClosed=false
                testWindow.contentView=NSHostingView(rootView:ExploreView(model:model,embedded:true,tab:1).frame(width:850,height:650))
                testWindow.makeKeyAndOrderFront(nil)
                for _ in 0..<40 { if SmokeControlView.controls.object(forKey:"model.delete")?.window === testWindow { break };try await Task.sleep(nanoseconds:100_000_000) }
                report["deletion_library_"+kind]=try await model.api("/local/library")
                if !CommandLine.arguments.contains("--skip-capture") { try capture("model-before-"+kind,testWindow) }
                func chooseAlert(_ title:String) {
                    let timer=Timer(timeInterval:0.8,repeats:false) { _ in
                        MainActor.assumeIsolated {
                            func buttons(_ view:NSView)->[NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons($0) } }
                            if let modal=NSApp.modalWindow, let root=modal.contentView, let button=buttons(root).first(where:{$0.title == title}) { button.performClick(nil) }
                            else { NSApp.abortModal() }
                        }
                    }
                    RunLoop.main.add(timer,forMode:.modalPanel)
                }
                chooseAlert("Отмена");try await clickControl("model.delete",in:testWindow)
                try await Task.sleep(nanoseconds:1200_000_000)
                try require(FileManager.default.fileExists(atPath:path.path),kind+" deletion cancelled through confirmation dialog")
                if !CommandLine.arguments.contains("--skip-capture") { try capture("model-library-"+kind,testWindow) }
                chooseAlert("В Корзину");try await clickControl("model.delete",in:testWindow)
                for _ in 0..<60 { if !FileManager.default.fileExists(atPath:path.path) { break };try await Task.sleep(nanoseconds:100_000_000) }
                try require(!FileManager.default.fileExists(atPath:path.path),kind+" fixture deleted using library mouse click and confirmed dialog")
                try await model.refresh();try require((kind == "text" ? model.snapshot?.settings.model : model.snapshot?.settings.imageLocalModel) == "",kind+" deleted selection cleared")
                testWindow.close()
            }
            // Restore baseline settings for remaining smoke checks.
            _ = try await model.api("/settings",["provider":"local","mode":"offline","model":"","imageLocalModel":""])
            try await model.refresh()
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--local-image-smoke-model"), CommandLine.arguments.count > flag + 1 {
            let modelPath=CommandLine.arguments[flag + 1]
            _ = try await model.api("/settings", ["mode":"offline","provider":"local","model":"","imageEnabled":true,"imageProvider":"local","imageLocalModel":modelPath,"imageCompute":"auto","imageWidth":256,"imageHeight":256,"imageSteps":1,"imageCFG":1])
            try await model.refresh()
            try require(model.snapshot?.settings.imageProvider == "local" && model.snapshot?.settings.imageLocalModel == modelPath, "local image settings decode independently of empty text model")
            model.draft="a red apple on a wooden table, studio photograph"
            try await Task.sleep(nanoseconds:400_000_000)
            try await clickControl("image.generate")
            var imageDone=false
            for _ in 0..<900 {
                try await Task.sleep(nanoseconds:100_000_000)
                try await model.refresh()
                if let job=model.snapshot?.jobs.last,job.status != "running" {
                    try require(job.status == "done", "real local image job completed: " + job.error)
                    imageDone=true; break
                }
            }
            try require(imageDone,"real bundled SD inference finishes offline without text model")
            guard let artifact=model.chat?.messages.flatMap({ $0.artifacts ?? [] }).last else { throw AppError(message:"Local image artifact missing") }
            let response=try await model.api("/artifact/path",["projectID":model.projectID,"path":artifact.path])
            guard let path=response["path"] as? String,let preview=NSImage(contentsOfFile:path) else { throw AppError(message:"Local image cannot decode") }
            try require(preview.isValid && preview.size.width == 256 && preview.size.height == 256,"native preview decodes real 256×256 generated PNG")
            let data=try Data(contentsOf:URL(fileURLWithPath:path)); let saved=URL(fileURLWithPath:reportPath + ".generated.png")
            try data.write(to:saved,options:.atomic)
            let readBack=try Data(contentsOf:saved)
            try require(data == readBack,"local image save preserves generated bytes")
            report["local_image_saved"]=saved.path; report["local_image_bytes"]=data.count
            report["local_image_model"]=modelPath
            report["local_image_mode"]=model.snapshot?.settings.mode ?? ""
            try require(model.snapshot?.settings.mode == "offline" && model.snapshot?.settings.model == "","local image did not enable cloud or select text model")
            if !CommandLine.arguments.contains("--skip-capture") { try capture("local-image-chat",window) }
            // Real cancellation, not a mocked process: start a larger run and stop it.
            _ = try await model.api("/settings",["imageWidth":512,"imageHeight":512,"imageSteps":50])
            model.draft="a blue ocean"; model.drawImage()
            for _ in 0..<50 {
                try await Task.sleep(nanoseconds:100_000_000); try await model.refresh()
                if model.running { break }
            }
            try require(model.running,"second real image job started for stop test")
            try await Task.sleep(nanoseconds:800_000_000)
            model.stop()
            for _ in 0..<100 {
                try await Task.sleep(nanoseconds:100_000_000); try await model.refresh()
                if !model.running { break }
            }
            try require(model.snapshot?.jobs.last?.status == "stopped","Stop cancels real local image generation")
            let allArtifacts=model.chat?.messages.flatMap({ $0.artifacts ?? [] }) ?? []
            try require(allArtifacts.count == 1,"cancelled generation does not attach partial image")
        }
        report["status"] = "passed"
    } catch { report["status"] = "failed"; report["error"] = error.localizedDescription }
    report["checks"] = checks
    report["backend_pid"] = model.process?.processIdentifier ?? 0
    report["os"] = ProcessInfo.processInfo.operatingSystemVersionString
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: URL(fileURLWithPath: reportPath))
    }
    model.settingsShown = false
    model.exploreShown = false
    for window in NSApp.windows { for sheet in window.sheets { window.endSheet(sheet) } }
    try? await Task.sleep(nanoseconds: 200_000_000)
    NSApp.terminate(nil)
}
