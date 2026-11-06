// Debug-Schalter: nur im Debug-Build (§26.5); der Release-Build kennt den Befehl nicht.
#if DEBUG
import AirTrafficCore
import AppKit
import SwiftUI

/// `--snapshot <dir>` (SPEC §15.9): rendert Chooser und Einstellungen offscreen als PNG,
/// je hell und dunkel, und beendet sich. Schreibt nichts in die Konfiguration, liest keinen Key.
@MainActor
enum SnapshotCommand {
    static let flag = "--snapshot"

    private static let settingsSize = NSSize(width: 980, height: 720)
    private static let fullPageSize = NSSize(width: 980, height: 1100)
    /// Tabs „CLI & MCP“ und „Updates“ (§25).
    private static let smallPageSize = NSSize(width: 980, height: 620)

    static func run(arguments: [String]) async -> Int32 {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            printError("Aufruf: \(flag) <Verzeichnis>")
            return 64
        }
        let dir = URL(fileURLWithPath: (arguments[index + 1] as NSString).expandingTildeInPath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            printError("Verzeichnis nicht anlegbar: \(error.localizedDescription)")
            return 73
        }

        let model = AppModel(store: .makeDefault(), keyStore: SnapshotKeyStore(), persists: false)
        // Darstellung setzt der Snapshot selbst (§23.5); `appliesAppearance` bleibt aus, und der
        // Picker in „Allgemein“ zeigt den Standard „System“ statt der Darstellung aus der Config.
        model.config.appearance = nil
        // Liest nur die Update-Einstellungen, prüft nichts.
        model.updates = UpdateController(startingUpdater: false)
        var written: [String] = []

        for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = NSAppearance(named: appearanceName)
            NSApp.appearance = appearance

            if let url = await renderChooser(model: model, appearance: appearance, to: dir, suffix: suffix) {
                written.append(url.lastPathComponent)
            }

            let controller = SettingsWindowController(model: model, autosavesFrame: false)
            guard let window = controller.window else { continue }
            window.appearance = appearance

            let jobs: [(String, SettingsTab, NSSize, UUID?)] = [
                ("general", .general, settingsSize, nil),
                ("browsers", .browsers, settingsSize, nil),
                ("safari", .safari, settingsSize, nil),
                ("cli", .cli, smallPageSize, nil),
                ("updates", .updates, smallPageSize, nil),
                ("rules", .rules, settingsSize, firstRuleWithTestURL(model.config)),
                ("rules-min", .rules, SettingsWindowController.minSize, firstRuleWithTestURL(model.config)),
                ("rules-shadow", .rules, settingsSize, firstShadowedRule(model.config)),
            ]
            for (name, tab, size, ruleID) in jobs {
                if name.hasPrefix("rules"), ruleID == nil, name != "rules" { continue }
                model.selectedRuleID = ruleID ?? model.config.rules.first?.id
                model.settingsTab = tab
                window.setContentSize(size)
                await settle(window)
                let file = dir.appending(path: "\(name)-\(suffix).png")
                if writePNG(of: window, to: file) { written.append(file.lastPathComponent) }
            }

            // Freigabe (§26.1): wartende Regel in Liste und Editor. Hat die Config keine, wird nur für den
            // Snapshot eine Regel als wartend markiert (`persists: false` – nichts wird gespeichert).
            let savedRules = model.config.rules
            if let pendingID = preparePendingRule(model) {
                for (name, size) in [("rules-pending", settingsSize), ("rules-pending-min", SettingsWindowController.minSize)] {
                    model.ruleQuery = ""
                    model.selectedRuleID = pendingID
                    model.settingsTab = .rules
                    window.setContentSize(size)
                    await settle(window)
                    let file = dir.appending(path: "\(name)-\(suffix).png")
                    if writePNG(of: window, to: file) { written.append(file.lastPathComponent) }
                }
            }
            model.config.rules = savedRules

            // URL-Prüfung (§22.6): URL mit Gewinner und verdeckter Regel; „Nur Treffer“ mit
            // ausgewähltem Gewinner, „Alle Regeln“ mit ausgewählter verdeckter Regel bei Mindestgröße.
            if let check = checkExample(model.config) {
                for (name, showsAll, size, ruleID) in [
                    ("rules-check", false, settingsSize, check.winner),
                    ("rules-check-all", true, SettingsWindowController.minSize, check.shadowed),
                ] {
                    model.ruleQuery = check.url.absoluteString
                    model.ruleCheckShowsAll = showsAll
                    model.selectedRuleID = ruleID
                    model.settingsTab = .rules
                    window.setContentSize(size)
                    await settle(window)
                    let file = dir.appending(path: "\(name)-\(suffix).png")
                    if writePNG(of: window, to: file) { written.append(file.lastPathComponent) }
                }
                model.ruleQuery = ""
            }

            // Ganze Seite „Allgemein“ mit allen Abschnitten inkl. „Darstellung“, je einmal pro
            // Anbieter-Art (§16.3, §23.4).
            let savedAssistant = model.config.assistant
            for (name, provider) in [("general-full", AssistantProvider.openRouter), ("general-claude", .claudeCLI)] {
                model.updateAssistant { $0.provider = provider }
                if let cli = provider.cli { await model.refreshCLIStatus(cli) }
                model.settingsTab = .general
                window.setContentSize(fullPageSize)
                await settle(window)
                let file = dir.appending(path: "\(name)-\(suffix).png")
                if writePNG(of: window, to: file) { written.append(file.lastPathComponent) }
            }
            model.config.assistant = savedAssistant

            // Tab „Safari“ (§21.2, §23.2): Regeln aus mit eigener Aktion (Standard zeigt `safari-*`).
            let savedExtension = model.config.extensionSettings
            model.config.extensionSettings = ExtensionSettings(applyRules: false, fallbackAction: .prompt(.running))
            model.settingsTab = .safari
            window.setContentSize(settingsSize)
            await settle(window)
            let ownFile = dir.appending(path: "safari-own-\(suffix).png")
            if writePNG(of: window, to: ownFile) { written.append(ownFile.lastPathComponent) }
            model.config.extensionSettings = savedExtension
            window.orderOut(nil)

            if let url = await renderAssistantSheet(model: model, appearance: appearance, to: dir, suffix: suffix) {
                written.append(url.lastPathComponent)
            }
        }

        print("Snapshots in \(dir.path(percentEncoded: false)):")
        for name in written { print("  \(name)") }
        return written.isEmpty ? 1 : 0
    }

    // MARK: Auswahl der Regeln

    /// Erste wartende Regel; sonst die erste Regel mit Umschreibung und Test-URL als „von außen
    /// umgeschrieben“ markieren (vorher ohne Umschreibung), notfalls die erste Regel als neu angelegt.
    private static func preparePendingRule(_ model: AppModel) -> UUID? {
        if let id = model.firstPendingRuleID { return id }
        let since = Date(timeIntervalSince1970: 1_793_958_060)  // 2026-11-06 09:41 UTC, fest für stabile Bilder
        if let index = model.config.rules.firstIndex(where: { !$0.rewrites.isEmpty && testURL(of: $0) != nil }) {
            var previous = model.config.rules[index]
            previous.rewrites = []
            model.config.rules[index].pendingChange = PendingChange(
                since: since, reason: "Umschreibungen geändert von außen (CLI/MCP)", previous: previous
            )
            return model.config.rules[index].id
        }
        guard !model.config.rules.isEmpty else { return nil }
        model.config.rules[0].pendingChange = PendingChange(since: since, reason: "neu angelegt von außen (CLI/MCP)", previous: nil)
        return model.config.rules[0].id
    }

    private static func firstRuleWithTestURL(_ config: Config) -> UUID? {
        config.rules.first { testURL(of: $0) != nil }?.id
    }

    private static func firstShadowedRule(_ config: Config) -> UUID? {
        config.rules.first { rule in
            guard let url = testURL(of: rule) else { return false }
            return RuleEngine.test(rule: rule, url: url, context: LinkContext(), config: config).shadowedBy != nil
        }?.id
    }

    /// Erste Test-URL der Config, für die eine Regel greift und eine zweite verdeckt ist (§22.6).
    private static func checkExample(_ config: Config) -> (url: URL, winner: UUID, shadowed: UUID)? {
        for rule in config.rules {
            guard let url = testURL(of: rule) else { continue }
            let result = RuleEngine.check(url: url, context: LinkContext(), config: config)
            guard let winner = result.decision.matchedRuleID,
                  let shadowed = result.entries.first(where: { $0.status == .shadowed(by: winner) })
            else { continue }
            return (url, winner, shadowed.ruleID)
        }
        return nil
    }

    private static func testURL(of rule: Rule) -> URL? {
        guard let text = rule.testURL?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let url = URL(string: text), url.scheme != nil
        else { return nil }
        return url
    }

    // MARK: Chooser

    private static func renderChooser(
        model: AppModel, appearance: NSAppearance?, to dir: URL, suffix: String
    ) async -> URL? {
        var browsers = model.effectiveBrowsers
        if browsers.count < 4 {
            for app in Apps.installedBrowsers() where !browsers.contains(where: { $0.refersToSameApp(as: app) }) {
                browsers.append(app)
            }
        }
        let request = ChooserRequest(
            url: URL(string: "https://example.com/docs/getting-started/install?ref=air-traffic")!,
            sourceBundleIdentifier: "com.apple.mail",
            scope: .all,
            hint: nil
        )
        let state = ChooserState(request: request, browsers: browsers)
        let chooser = ChooserView(
            state: state,
            maxWidth: 900,
            animatesIn: false,
            onOpen: { _ in }, onFieldSubmit: {}, onFieldEscape: {}, onFocusField: {}, registerField: { _ in }
        )
        // Schreibtisch-Hintergrund, damit Glas/Material sichtbar wird.
        let dark = suffix == "dark"
        let desk = ZStack {
            LinearGradient(
                colors: dark
                    ? [Color(red: 0.24, green: 0.55, blue: 0.49), Color(red: 0.17, green: 0.30, blue: 0.55)]
                    : [Color(red: 0.75, green: 0.90, blue: 0.85), Color(red: 0.79, green: 0.84, blue: 0.96)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            chooser.shadow(color: .black.opacity(dark ? 0.5 : 0.22), radius: 25, y: 12)
        }
        let hosting = NSHostingView(rootView: desk.padding(0))
        let size = hosting.fittingSize
        let frame = NSRect(x: 0, y: 0, width: size.width + 120, height: size.height + 100)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        hosting.frame = frame
        window.contentView = hosting
        await settle(window)
        let file = dir.appending(path: "chooser-\(suffix).png")
        let ok = writePNG(view: hosting, to: file)
        window.orderOut(nil)
        return ok ? file : nil
    }

    // MARK: KI-Sheet (Eingabezustand, ohne Anfrage)

    private static func renderAssistantSheet(
        model: AppModel, appearance: NSAppearance?, to dir: URL, suffix: String
    ) async -> URL? {
        let examples = model.config.rules.compactMap { testURL(of: $0)?.absoluteString }.prefix(2)
        let request = RegexAssistantRequest(
            mode: .rewrite,
            context: "Neue Umschreibung",
            examples: Array(examples),
            current: nil,
            caseSensitive: false,
            apply: { _, _, _ in }
        )
        let sheet = RegexAssistantSheet(
            request: request,
            subtitle: model.assistantSubtitle,
            recipient: model.assistantProvider.recipient,
            makeAssistant: { throw LLMError.missingAPIKey }
        )
        let hosting = NSHostingView(rootView: sheet.frame(height: 420))
        let size = hosting.fittingSize
        let frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        hosting.frame = frame
        window.contentView = hosting
        await settle(window)
        let file = dir.appending(path: "assistant-\(suffix).png")
        let ok = writePNG(view: hosting, to: file)
        window.orderOut(nil)
        return ok ? file : nil
    }

    // MARK: Rendern

    private static func settle(_ window: NSWindow) async {
        for _ in 0..<4 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    /// Ganzes Fenster inkl. Titelleiste und Toolbar (Rahmen-View).
    private static func writePNG(of window: NSWindow, to file: URL) -> Bool {
        guard let frameView = window.contentView?.superview else { return false }
        return writePNG(view: frameView, to: file)
    }

    private static func writePNG(view: NSView, to file: URL) -> Bool {
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return false }
        view.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: file, options: .atomic)
            return true
        } catch {
            printError("\(file.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// Snapshot-Schlüsselbund: zeigt „Key gespeichert“, liest und schreibt nichts.
private struct SnapshotKeyStore: APIKeyStore {
    func readKey() throws -> String? { nil }
    func hasKey() -> Bool { true }
    func saveKey(_ key: String) throws {}
    func deleteKey() throws {}
}
#endif
