# macOS release acceptance — not executed on Linux

Do not set a check to PASS without the corresponding Mac evidence. Record OS, architecture, build command exit, binary hash and screenshots/logs in a new verification report.

1. Build `scripts/build-app.sh` on Apple Silicon; require Swift compiler exit 0, bundled Python tests exit 0, codesign verification exit 0, bundle smoke exit 0 and DMG creation exit 0.
2. On a Mac with no Python/Homebrew installed, mount DMG, drag app to Applications, disconnect the build directory. Launch the installed app from Finder. Verify icon in Dock, one main window, no Terminal or external runtime prompt.
3. Close window, reopen from Dock. Quit with Cmd-Q; confirm app backend process exits. Launch again; projects, chats and settings survive.
4. First-run settings: existing Ollama reachable, model list loads, selected model persists. No model/invalid endpoint returns a useful error. Run local chat, streaming, stop, tool call and follow-up. Test OpenAI-compatible mode separately.
5. Import example skill, toggle in one chat, inspect context. Other projects must not inherit it. Test support-file reads.
6. Save two prompt versions; restore the older version. Edit a user message and retry answer. Verify archived prior history and current tool-call chain are valid.
7. API keys save/reload through Keychain. Verify wrong key error without echoing key. Brave/Tavily/Serper each return live sourced search results when configured.
8. Browser: navigate/read, list refs, approved click/fill, denied action, stale ref rejection, password field rejection. Manual login/captcha remains possible. Offline mode cancels navigation and blocks networking tools.
9. DOCX/XLSX/text/PDF/image attachments: text appears in draft; OCR multi-page scanned PDF is bounded and correctly ordered. Truncation displayed. No false claim of vision reasoning.
10. Create document from template with markers: deny first, then approve; compare styles/content. Invalid/missing markers fail without partial output. Existing output gets backed up.
11. MCP: add a known local server, list tools with approval, call a tool with approval, reject a call, stop hanging process. No startup occurs merely by saving config. Offline blocks MCP.
12. Backup/restore: alter data, restore prior archive, confirm pre-restore backup, paths rebased, MCP disabled, keys preserved in Keychain, external workspace requires re-selection. Reject malicious archive.
13. Move app to a path with spaces. Launch while current working directory differs. Inspect runtime dylib paths if startup fails.
14. If distributing as a normal downloaded application, verify Developer ID signature, notarization and Gatekeeper assessment on the delivered DMG. Ad-hoc local success is not this verification.

Release 0.3.3 passed the automated Apple Silicon bundle, native UI, installed-DMG and post-launch signature checks. Physical hardware sensors, live paid image generation, Developer ID notarization and downloaded-quarantine acceptance remain separate checks.
