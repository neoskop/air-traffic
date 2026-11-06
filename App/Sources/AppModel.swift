import AirTrafficCore
import AppKit
import Observation
import SwiftUI

/// Tabs des Einstellungsfensters in Toolbar-Reihenfolge (§23.5).
enum SettingsTab: Hashable, CaseIterable {
    case general, browsers, rules, safari, cli, updates

    var label: String {
        switch self {
        case .general: "Allgemein"
        case .browsers: "Browser"
        case .rules: "Regeln"
        case .safari: "Safari"
        case .cli: "CLI & MCP"
        case .updates: "Updates"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .browsers: "globe"
        case .rules: "point.topleft.down.to.point.bottomright.curvepath"
        case .safari: "safari"
        case .cli: "terminal"
        case .updates: "arrow.triangle.2.circlepath"
        }
    }
}

/// Hält die Konfiguration und speichert Änderungen debounced (300 ms).
@MainActor
@Observable
final class AppModel {
    let store: ConfigStore

    var config: Config {
        didSet {
            if config != oldValue, !isApplyingExternalChange { scheduleSave() }
            if config.appearance != oldValue.appearance { applyAppearanceIfEnabled() }
        }
    }

    /// Letzter Lade-/Speicherfehler für die Anzeige in den Einstellungen.
    var problem: String?

    // MARK: Änderungen von außen (§24.5)

    /// Hinweis „Regeln wurden von außen geändert und neu geladen.“ (orange Zeile, 6 s oder Klick).
    private(set) var showsExternalChangeNotice = false
    /// Zählt Neuladen von außen.
    private(set) var externalReloadCount = 0
    /// Zählt nur Neuladen, bei denen sich die ausgewählte Regel geändert hat (bzw. Import „Ersetzen“);
    /// der Regel-Editor baut seinen eigenen Zustand nur dann neu auf (§27 A12).
    private(set) var editorResetCount = 0
    /// Fingerabdruck der zuletzt geladenen/gespeicherten Datei; Grundlage der Konfliktentscheidung.
    @ObservationIgnored private var knownFingerprint: String?
    @ObservationIgnored private var isApplyingExternalChange = false
    @ObservationIgnored private var watcher: ConfigFileWatcher?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// Nach jeder Übernahme einer Änderung von außen (§26.1): macOS-Mitteilung. Setzt der AppDelegate.
    @ObservationIgnored var onExternalChange: ((Config) -> Void)?

    /// Ausgewählter Tab im Einstellungsfenster (z. B. Sprung zu „Allgemein“ aus dem Regel-Editor).
    var settingsTab: SettingsTab = .general

    /// Ausgewählte Regel im Tab „Regeln“ (bleibt beim Tab-Wechsel erhalten).
    var selectedRuleID: UUID?

    // MARK: Suche und URL-Prüfung der Regel-Liste (§13.2, §22)

    /// Inhalt des Suchfelds im Tab „Regeln“: Text oder zu prüfende URL.
    var ruleQuery = "" {
        didSet {
            // „Als Text suchen“ gilt nur für den Inhalt, für den es gewählt wurde (§22.1).
            if ruleQueryForcedText != nil, ruleQueryForcedText != ruleQuery { ruleQueryForcedText = nil }
            resetRuleCheckIfInactive()
        }
    }

    /// Inhalt, für den „Als Text suchen“ gewählt wurde; nil = automatische Erkennung.
    var ruleQueryForcedText: String? {
        didSet { resetRuleCheckIfInactive() }
    }

    /// Prüfmodus: „Alle Regeln“ statt „Nur Treffer“ (§22.2).
    var ruleCheckShowsAll = false
    /// Simulation im Prüfmodus (Quell-App, Modifier); gilt für Liste und Editor (§22.2, §22.4).
    var ruleCheckSource = ""
    var ruleCheckModifiers: ModifierSet = []

    /// Geprüfte URL, wenn das Suchfeld eine vollständige URL enthält und nicht als Text erzwungen ist.
    var ruleCheckURL: URL? {
        ruleQueryForcedText == ruleQuery ? nil : RuleCheck.url(from: ruleQuery)
    }

    var ruleCheckContext: LinkContext {
        let id = ruleCheckSource.trimmingCharacters(in: .whitespaces)
        return LinkContext(sourceBundleIdentifier: id.isEmpty ? nil : id, modifiers: ruleCheckModifiers)
    }

    /// Verlassen des Prüfmodus setzt Ansicht und Simulation zurück (§22.2).
    private func resetRuleCheckIfInactive() {
        guard ruleCheckURL == nil else { return }
        if ruleCheckShowsAll { ruleCheckShowsAll = false }
        if !ruleCheckSource.isEmpty { ruleCheckSource = "" }
        if !ruleCheckModifiers.isEmpty { ruleCheckModifiers = [] }
    }

    /// `false` = nichts speichern (`--snapshot`); die Konfiguration bleibt unangetastet.
    @ObservationIgnored let persists: Bool

    /// `true` = `config.appearance` steuert `NSApp.appearance` (§23.1). Aus in `--snapshot`,
    /// das die Darstellung selbst setzt.
    @ObservationIgnored var appliesAppearance = false {
        didSet { applyAppearanceIfEnabled() }
    }

    /// Schlüsselbund-Ablage des OpenRouter-Keys (§12.1).
    @ObservationIgnored let keyStore: any APIKeyStore
    /// Key vorhanden (Schlüsselbund oder `OPENROUTER_API_KEY`); ohne Inhalt zu lesen.
    private(set) var hasAssistantKey = false

    /// Ergebnis der Binärsuche je CLI (§16.2); fehlt = noch nicht gesucht.
    private(set) var cliStatus: [AssistantCLI: CLIStatus] = [:]
    @ObservationIgnored let cliLocator: CLILocator

    /// Sparkle-Updater (§17); `nil` in `--snapshot` und Debug-Schaltern.
    @ObservationIgnored var updates: UpdateController?

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(
        store: ConfigStore,
        keyStore: any APIKeyStore = KeychainAPIKeyStore(),
        cliLocator: CLILocator = .system,
        persists: Bool = true
    ) {
        self.store = store
        self.keyStore = keyStore
        self.cliLocator = cliLocator
        self.persists = persists
        do {
            if let loaded = try store.loadSnapshot() {
                config = loaded.config
                knownFingerprint = loaded.fingerprint
                Log.config.info("Konfiguration geladen: \(store.fileURL.path, privacy: .public)")
                // Regeln ohne `id`: vergebene IDs sofort zurückschreiben, damit sie stabil bleiben (§27 K13).
                if loaded.hasRulesWithoutID { saveNow() }
            } else {
                config = AppModel.firstRunConfig()
                Log.config.info("Erster Start – Browser erkannt: \(self.config.browsers.count)")
                saveNow()
            }
        } catch where !persists {
            config = AppModel.firstRunConfig()
            problem = "Konfiguration war nicht lesbar (\(error.localizedDescription))."
        } catch {
            // Defekte Datei sichern statt überschreiben.
            let backup = store.fileURL.deletingPathExtension()
                .appendingPathExtension("broken-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: store.fileURL, to: backup)
            config = AppModel.firstRunConfig()
            problem = "Konfiguration war nicht lesbar (\(error.localizedDescription)). Gesichert als \(backup.lastPathComponent)."
            Log.config.error("Konfiguration nicht lesbar: \(String(describing: error), privacy: .private)")
            saveNow()
        }
        refreshAssistantKey()
        if persists {
            watcher = ConfigFileWatcher(fileURL: store.fileURL) { [weak self] in self?.checkForExternalChange() }
        }
    }

    /// Erster Start: installierte Browser erkennen, Auswahl zeigen, keine Regeln.
    static func firstRunConfig() -> Config {
        Config(browsers: Apps.installedBrowsers(), rules: [], defaultAction: .prompt(.all))
    }

    /// Browserliste ohne Air Traffic selbst; leer → installierte Browser.
    var effectiveBrowsers: [AppRef] {
        let list = config.browsers.filter { !Apps.isSelf($0) }
        return list.isEmpty ? Apps.installedBrowsers() : list
    }

    func rule(withID id: UUID?) -> Rule? {
        guard let index = ruleIndex(id) else { return nil }
        return config.rules[index]
    }

    // MARK: Regeln per ID (§27 A1, A6/A7)

    @ObservationIgnored private var indexCache: (rules: [Rule], index: [UUID: Int])?

    /// Index einer Regel über ein zwischengespeichertes `id → index`-Dictionary.
    func ruleIndex(_ id: UUID?) -> Int? {
        guard let id else { return nil }
        let rules = config.rules
        if let cache = indexCache, cache.rules == rules { return cache.index[id] }
        let index = Dictionary(rules.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        indexCache = (rules, index)
        return index[id]
    }

    /// Ändert die Regel mit dieser ID (nicht über einen Index, der inzwischen woanders hinzeigt).
    func updateRule(_ id: UUID, _ change: (inout Rule) -> Void) {
        guard let index = ruleIndex(id) else { return }
        var rule = config.rules[index]
        change(&rule)
        guard rule != config.rules[index] else { return }
        config.rules[index] = rule
    }

    /// Bindung an eine Regel per ID; ist sie weg, liefert sie `fallback` und schreibt nichts.
    func ruleBinding(_ id: UUID, fallback: Rule) -> Binding<Rule> {
        Binding(
            get: { [weak self] in self?.rule(withID: id) ?? fallback },
            set: { [weak self] new in self?.updateRule(id) { $0 = new } }
        )
    }

    // MARK: Liste im Tab „Regeln“ (§27 A6/A7)

    @ObservationIgnored private var ruleListCache: (key: RuleListKey, state: RuleListState)?

    /// Sichtbare Zeilen samt URL-Prüfung; nur neu berechnet, wenn sich Konfiguration, Suchtext,
    /// Prüf-URL, Simulation oder Ansicht ändern.
    var ruleList: RuleListState {
        let key = RuleListKey(
            config: config,
            query: ruleQuery,
            checkURL: ruleCheckURL,
            context: ruleCheckContext,
            showsAll: ruleCheckShowsAll
        )
        if let cache = ruleListCache, cache.key == key { return cache.state }
        let state = RuleListState.make(key)
        ruleListCache = (key, state)
        return state
    }

    /// Nächste Auswahl nach dem Entfernen: aus den sichtbaren Regeln (§27 A10).
    private func selectionAfterRemoving(_ id: UUID) -> UUID? {
        RuleListEditing.selection(afterRemoving: id, visible: ruleList.rows.map(\.id))
    }

    // MARK: Löschen, Duplizieren, Umsortieren mit Rückgängig (§27 A15)

    /// Löscht die Regel; vorher Sicherung des Stands. Rückgängig über den UndoManager des Fensters.
    func deleteRule(_ id: UUID, undoManager: UndoManager?) {
        guard let index = ruleIndex(id) else { return }
        backupBeforeDelete()
        let rule = config.rules[index]
        let next = selectedRuleID == id ? selectionAfterRemoving(id) : selectedRuleID
        config.rules.remove(at: index)
        selectedRuleID = next
        registerUndo(undoManager, name: "Regel löschen") { model, undo in
            RuleListEditing.reinsert(rule, at: index, into: &model.config.rules)
            model.selectedRuleID = rule.id
            model.registerUndo(undo, name: "Regel löschen") { model, redo in model.deleteRule(rule.id, undoManager: redo) }
        }
    }

    /// Kopie hinter der Regel bzw. an `index`; wird ausgewählt.
    func insertRule(_ rule: Rule, at index: Int, undoManager: UndoManager?, actionName: String) {
        RuleListEditing.reinsert(rule, at: index, into: &config.rules)
        selectedRuleID = rule.id
        registerUndo(undoManager, name: actionName) { model, undo in
            let previous = model.selectedRuleID == rule.id ? model.selectionAfterRemoving(rule.id) : model.selectedRuleID
            model.config.rules.removeAll { $0.id == rule.id }
            model.selectedRuleID = previous
            model.registerUndo(undo, name: actionName) { model, redo in
                model.insertRule(rule, at: index, undoManager: redo, actionName: actionName)
            }
        }
    }

    func moveRules(fromOffsets from: IndexSet, toOffset to: Int, undoManager: UndoManager?) {
        let before = config.rules.map(\.id)
        config.rules.move(fromOffsets: from, toOffset: to)
        registerReorderUndo(undoManager, restoring: before)
    }

    private func registerReorderUndo(_ undoManager: UndoManager?, restoring order: [UUID]) {
        registerUndo(undoManager, name: "Regeln umsortieren") { model, undo in
            let current = model.config.rules.map(\.id)
            model.config.rules = RuleListEditing.reorder(model.config.rules, to: order)
            model.registerReorderUndo(undo, restoring: current)
        }
    }

    /// Undo-Schritt, der beim Ausführen den Gegenschritt (Wiederholen) selbst registriert.
    private func registerUndo(
        _ undoManager: UndoManager?, name: String, _ action: @escaping @MainActor (AppModel, UndoManager) -> Void
    ) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { action(model, undoManager) }
        }
        undoManager.setActionName(name)
    }

    private func backupBeforeDelete() {
        guard persists else { return }
        do {
            try store.writeBackup(of: config)
        } catch {
            Log.config.error("Sicherung vor dem Löschen fehlgeschlagen: \(String(describing: error), privacy: .private)")
        }
    }

    // MARK: Speichern

    private func scheduleSave() {
        guard persists else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func flushPendingSave() {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        saveNow()
    }

    /// Koordiniert und atomar; wurde die Datei inzwischen von außen geändert, wird nicht
    /// überschrieben, sondern neu geladen (§24.5).
    private func saveNow() {
        saveTask = nil
        guard persists else { return }
        do {
            switch try store.save(config, ifUnchangedSince: knownFingerprint) {
            case .saved(let fingerprint):
                knownFingerprint = fingerprint
                if problem?.hasPrefix("Speichern") == true || problem?.hasPrefix("Von außen") == true { problem = nil }
            case .conflict(let current):
                Log.config.info("Speichern übersprungen: Konfiguration wurde von außen geändert")
                applyExternal(current)
            case .conflictUnreadable(let message):
                problem = "Von außen geändert, aber nicht lesbar (\(message)) – deine Änderung wurde nicht gespeichert."
            }
        } catch {
            problem = "Speichern fehlgeschlagen: \(error.localizedDescription)"
            Log.config.error("Speichern fehlgeschlagen: \(String(describing: error), privacy: .private)")
        }
    }

    // MARK: Änderungen von außen (§24.5)

    /// Nach einer Datei-Benachrichtigung: eigene Speichervorgänge (gleicher Fingerabdruck) ignorieren.
    func checkForExternalChange() {
        guard persists else { return }
        let data: Data?
        do {
            data = try store.coordinatedData()
        } catch {
            Log.config.error("Konfiguration nicht lesbar: \(String(describing: error), privacy: .private)")
            return
        }
        guard ConfigSync.changeDecision(known: knownFingerprint, current: data.map(ConfigStore.fingerprint)) == .reload,
              let data
        else { return }
        do {
            applyExternal(ConfigSnapshot(config: try ConfigStore.decode(data), fingerprint: ConfigStore.fingerprint(data)))
        } catch {
            // Nicht übernehmen und nicht überschreiben: Speichern meldet den Konflikt, bis die Datei wieder gültig ist.
            problem = "Von außen geändert, aber nicht lesbar (\(error.localizedDescription))."
            Log.config.error("Externe Änderung nicht lesbar: \(String(describing: error), privacy: .private)")
        }
    }

    /// Übernimmt den Stand von der Platte; eine ausstehende eigene Änderung verfällt.
    private func applyExternal(_ snapshot: ConfigSnapshot) {
        saveTask?.cancel()
        saveTask = nil
        knownFingerprint = snapshot.fingerprint
        let selectedBefore = rule(withID: selectedRuleID)
        isApplyingExternalChange = true
        config = snapshot.config
        isApplyingExternalChange = false
        if let id = selectedRuleID, ruleIndex(id) == nil { selectedRuleID = nil }
        if problem?.hasPrefix("Von außen") == true { problem = nil }
        externalReloadCount += 1
        // Editor nur neu aufbauen, wenn sich die ausgewählte Regel geändert hat (§27 A12).
        if rule(withID: selectedRuleID) != selectedBefore { editorResetCount += 1 }
        // Regeln ohne `id` (von Hand bearbeitet): vergebene IDs zurückschreiben (§27 K13).
        if snapshot.hasRulesWithoutID { scheduleSave() }
        Log.config.info("Konfiguration von außen geändert und neu geladen, wartend: \(self.pendingRuleCount)")
        showExternalChangeNotice()
        onExternalChange?(config)
    }

    private func showExternalChangeNotice() {
        showsExternalChangeNotice = true
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.showsExternalChangeNotice = false
        }
    }

    func dismissExternalChangeNotice() {
        noticeTask?.cancel()
        showsExternalChangeNotice = false
    }

    // MARK: Freigabe (§26.1)

    /// Regeln, die auf Freigabe warten.
    var pendingRuleCount: Int { RuleApproval.pendingCount(in: config) }

    /// Erste wartende Regel (Sprung aus der Mitteilung).
    var firstPendingRuleID: UUID? { config.rules.first(where: \.isPendingApproval)?.id }

    /// „Freigeben“: Änderung gilt ab sofort.
    func approveRule(_ id: UUID) {
        guard let index = config.rules.firstIndex(where: { $0.id == id }) else { return }
        config.rules[index] = RuleApproval.approve(config.rules[index])
        Log.config.info("Regel freigegeben: \(self.config.rules[index].name, privacy: .public)")
    }

    /// „Verwerfen“: neu angelegt → löschen (mit Sicherung), geändert → zuletzt freigegebenen Stand
    /// wiederherstellen. Rückgängig über den UndoManager des Fensters (§27 A15).
    func discardPendingChange(_ id: UUID, undoManager: UndoManager? = nil) {
        guard let index = ruleIndex(id) else { return }
        let original = config.rules[index]
        if let restored = RuleApproval.discard(original) {
            config.rules[index] = restored
        } else {
            backupBeforeDelete()
            // Nächste Auswahl aus den sichtbaren Regeln (§27 A10).
            let next = selectedRuleID == id ? selectionAfterRemoving(id) : selectedRuleID
            config.rules.remove(at: index)
            selectedRuleID = next
        }
        registerUndo(undoManager, name: "Änderung verwerfen") { model, undo in
            if let current = model.ruleIndex(id) {
                model.config.rules[current] = original
            } else {
                RuleListEditing.reinsert(original, at: index, into: &model.config.rules)
            }
            model.selectedRuleID = id
            model.registerUndo(undo, name: "Änderung verwerfen") { model, redo in
                model.discardPendingChange(id, undoManager: redo)
            }
        }
        Log.config.info("Änderung von außen verworfen: \(original.name, privacy: .public)")
    }

    // MARK: Darstellung (§23.1)

    /// Picker in Allgemein → „Darstellung“; `.system` landet als `nil` in der Config.
    var appearance: AppAppearance {
        get { config.effectiveAppearance }
        set { config.appearance = newValue }
    }

    /// Gilt für alle Fenster der App, auch das Auswahlfenster, Sheets, Popover und Alerts.
    private func applyAppearanceIfEnabled() {
        guard appliesAppearance else { return }
        NSApp.appearance = switch config.effectiveAppearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    // MARK: KI-Assistent

    func refreshAssistantKey() {
        let env = ProcessInfo.processInfo.environment[APIKeyResolver.environmentKey] ?? ""
        hasAssistantKey = keyStore.hasKey() || !env.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func saveAssistantKey(_ key: String) throws {
        try keyStore.saveKey(key.trimmingCharacters(in: .whitespacesAndNewlines))
        refreshAssistantKey()
    }

    func deleteAssistantKey() throws {
        try keyStore.deleteKey()
        refreshAssistantKey()
    }

    // MARK: Anbieter (§16)

    var assistantProvider: AssistantProvider { config.assistantProvider }

    /// Ändert die Assistenz-Einstellungen; alles auf Standard → Abschnitt fällt aus der Config.
    func updateAssistant(_ change: (inout AssistantSettings) -> Void) {
        var settings = config.assistant ?? AssistantSettings()
        change(&settings)
        let normalized = settings.normalized()
        config.assistant = normalized.isEmpty ? nil : normalized
    }

    // MARK: Safari-Erweiterung (§21.2)

    var extensionSettings: ExtensionSettings { config.extensionSettings ?? ExtensionSettings() }

    /// Ändert das Verhalten für Links aus der Erweiterung; alles auf Standard → Abschnitt fällt aus der Config.
    func updateExtensionSettings(_ change: (inout ExtensionSettings) -> Void) {
        var settings = extensionSettings
        change(&settings)
        config.extensionSettings = settings.isDefault ? nil : settings
    }

    /// OpenRouter: Key vorhanden; CLI: Binärdatei gefunden (Cache oder schnelle Suche ohne Login-Shell).
    var assistantAvailable: Bool {
        guard let cli = assistantProvider.cli else { return hasAssistantKey }
        if cliStatus[cli]?.url != nil { return true }
        return cliLocator.locateWithoutShell(cli, configuredPath: config.assistant?.path(for: cli)) != nil
    }

    /// Vollständige Prüfung für den aktiven Anbieter (inkl. Login-Shell bei CLIs).
    func refreshAssistantAvailability() async {
        refreshAssistantKey()
        if let cli = assistantProvider.cli { await refreshCLIStatus(cli) }
    }

    /// Sucht die CLI (konfigurierter Pfad → feste Orte → Login-Shell) und liest ihre Version.
    func refreshCLIStatus(_ cli: AssistantCLI) async {
        let path = config.assistant?.path(for: cli)
        let url = await cliLocator.locate(cli, configuredPath: path)
        var version: String?
        if let url { version = await CLITransport.version(of: url) }
        // Pfad inzwischen geändert → Ergebnis verwerfen.
        guard config.assistant?.path(for: cli) == path else { return }
        cliStatus[cli] = CLIStatus(url: url, version: version)
    }

    /// Client für den Anbieter; wirft `LLMError.missingAPIKey` ohne OpenRouter-Key.
    func makeLLMClient(for provider: AssistantProvider) throws -> any LLMClient {
        switch provider {
        case .openRouter:
            return OpenRouterClient(apiKey: try APIKeyResolver.resolve(store: keyStore))
        case .claudeCLI:
            return ClaudeCLIClient(transport: transport(for: .claude))
        case .codexCLI:
            return CodexCLIClient(transport: transport(for: .codex))
        }
    }

    private func transport(for cli: AssistantCLI) -> CLITransport {
        // Gefundener Pfad zuerst, damit die Suche nicht bei jeder Anfrage läuft.
        let path = cliStatus[cli]?.url?.path(percentEncoded: false) ?? config.assistant?.path(for: cli)
        return CLITransport(cli: cli, configuredPath: path, locator: cliLocator)
    }

    /// Assistent für den aktiven Anbieter und dessen Modell.
    func makeRegexAssistant() throws -> RegexAssistant {
        let provider = assistantProvider
        return RegexAssistant(client: try makeLLMClient(for: provider), model: config.assistantModel(for: provider))
    }

    /// „Anbieter · Modell“ für das KI-Sheet.
    var assistantSubtitle: String {
        "\(assistantProvider.displayName) · \(config.assistantModelLabel(for: assistantProvider))"
    }

    // MARK: Import

    func applyImport(_ result: ImportResult, replace: Bool) {
        var next = config
        if replace {
            next.rules = result.config.rules
            next.defaultAction = result.config.defaultAction
            if !result.config.browsers.isEmpty { next.browsers = result.config.browsers }
        } else {
            next.rules += result.config.rules
            for browser in result.config.browsers where !next.browsers.contains(where: { $0.refersToSameApp(as: browser) }) {
                next.browsers.append(browser)
            }
        }
        config = next
        // „Ersetzen“: Auswahl und Editor zurücksetzen wie beim Neuladen von außen (§27 A11).
        if replace {
            if let id = selectedRuleID, ruleIndex(id) == nil { selectedRuleID = nil }
            editorResetCount += 1
        }
    }
}

/// Ergebnis der Binärsuche für eine CLI.
struct CLIStatus: Equatable {
    var url: URL?
    var version: String?
}

// MARK: - Zeilenmodelle der Regel-Liste (§27 A6/A7)

/// Eingaben, von denen die Regel-Liste abhängt.
struct RuleListKey: Equatable {
    var config: Config
    var query: String
    var checkURL: URL?
    var context: LinkContext
    var showsAll: Bool
}

/// Eine sichtbare Zeile: Wert der Regel, Position und (im Prüfmodus) Status-Zeile.
struct RuleRowModel: Identifiable, Equatable {
    var rule: Rule
    var position: Int
    var checkLine: RuleCheckLine?
    var id: UUID { rule.id }
}

/// Vorab berechnete Liste: URL-Prüfung bzw. Textfilter, Zeilen in Anzeigereihenfolge.
struct RuleListState: Equatable {
    var check: RuleCheckResult?
    var rows: [RuleRowModel]
    /// Position (1-basiert) je Regel, für „Regel n greift zuerst“.
    var positions: [UUID: Int]

    func contains(_ id: UUID) -> Bool { rows.contains { $0.id == id } }

    static func make(_ key: RuleListKey) -> RuleListState {
        let rules = key.config.rules
        let positions = Dictionary(rules.enumerated().map { ($1.id, $0 + 1) }, uniquingKeysWith: { a, _ in a })
        guard let url = key.checkURL else {
            let rows = RuleSearch.filter(rules, query: key.query).map {
                RuleRowModel(rule: $0, position: positions[$0.id] ?? 0, checkLine: nil)
            }
            return RuleListState(check: nil, rows: rows, positions: positions)
        }
        let check = RuleEngine.check(url: url, context: key.context, config: key.config)
        let rows = zip(rules, check.entries)
            .filter { key.showsAll || $0.1.matches }
            .map { rule, entry in
                RuleRowModel(rule: rule, position: entry.position, checkLine: checkLine(for: rule, entry: entry, in: check, positions: positions))
            }
        return RuleListState(check: check, rows: rows, positions: positions)
    }

    /// Status-Zeile einer Regel im Prüfmodus (§22.3).
    static func checkLine(
        for rule: Rule, entry: RuleCheckEntry, in check: RuleCheckResult, positions: [UUID: Int]
    ) -> RuleCheckLine {
        switch entry.status {
        case .wins:
            let rewrites = check.decision.finalURL != check.decision.originalURL
            return RuleCheckLine(kind: .wins, text: rewrites ? "greift · schreibt um" : "greift")
        case .shadowed(let winnerID):
            let number = positions[winnerID]
            return RuleCheckLine(kind: .shadowed, text: "trifft, aber Regel \(number.map(String.init) ?? "?") greift zuerst")
        case .disabledMatch:
            return RuleCheckLine(kind: .disabledMatch, text: "Aus – würde treffen")
        case .pendingMatch:
            return RuleCheckLine(kind: .pending, text: "trifft, wartet auf Freigabe")
        case .noMatch:
            guard let index = entry.firstFailedCondition, rule.conditions.indices.contains(index) else {
                return RuleCheckLine(kind: .noMatch, text: "trifft nicht")
            }
            return RuleCheckLine(
                kind: .noMatch,
                text: "trifft nicht · Bedingung \(index + 1) (\(RuleText.fieldName(rule.conditions[index])))"
            )
        }
    }
}
