import AppKit
import SwiftUI
import Foundation

@MainActor func runNativeSmoke(model: AppModel, delegate: AppDelegate, reportPath: String) async {
    var checks: [String] = []
    var report: [String: Any] = [:]
    func require(_ condition: Bool, _ name: String) throws {
        guard condition else { throw AppError(message: "Smoke check failed: " + name) }
        checks.append(name)
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
            _ = try await model.api("/settings", ["mode":"cloud", "provider":"openai", "baseURL":base, "model":"fixture-chat", "toolsEnabled":true, "imageEnabled":true, "imageBaseURL":base, "imageModel":"gpt-image-fixture"])
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
        func capture(_ suffix:String, _ target:NSWindow) throws {
            let capture=Process(); capture.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture")
            capture.arguments=["-x","-l",String(target.windowNumber),reportPath+"-"+suffix+".png"]
            try capture.run(); capture.waitUntilExit()
            guard capture.terminationStatus == 0 else { throw AppError(message:"Window screenshot failed") }

        }
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
        model.browser.allow(false)
        try require(!model.browser.enabled, "offline mode disables browser")
        report["status"] = "passed"
    } catch { report["status"] = "failed"; report["error"] = error.localizedDescription }
    report["checks"] = checks
    report["backend_pid"] = model.process?.processIdentifier ?? 0
    report["os"] = ProcessInfo.processInfo.operatingSystemVersionString
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: URL(fileURLWithPath: reportPath))
    }
    NSApp.terminate(nil)
}
