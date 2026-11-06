import Foundation

// MARK: - AppRef

/// Verweis auf eine App. Auflösung (App-Schicht): erst `bundleIdentifier`, sonst `path`.
public struct AppRef: Codable, Sendable, Hashable {
    public var bundleIdentifier: String?
    public var path: String
    public var displayName: String

    public init(bundleIdentifier: String?, path: String, displayName: String) {
        self.bundleIdentifier = bundleIdentifier
        self.path = path
        self.displayName = displayName
    }

    /// Baut eine Referenz aus einem App-Pfad; der Name kommt aus dem Dateinamen.
    public init(path: String, bundleIdentifier: String? = nil) {
        self.init(
            bundleIdentifier: bundleIdentifier,
            path: path,
            displayName: AppRef.displayName(forPath: path)
        )
    }

    public static func displayName(forPath path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return last.hasSuffix(".app") ? String(last.dropLast(4)) : last
    }

    /// Gleiche App, wenn Bundle-IDs übereinstimmen oder (ohne Bundle-ID) die Pfade.
    public func refersToSameApp(as other: AppRef) -> Bool {
        if let a = bundleIdentifier, let b = other.bundleIdentifier {
            return a.caseInsensitiveCompare(b) == .orderedSame
        }
        return (path as NSString).standardizingPath == (other.path as NSString).standardizingPath
    }
}

// MARK: - Config

public struct Config: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// Geordnet, oben = Favorit; Liste im Chooser.
    public var browsers: [AppRef]
    /// Geordnet, erste passende gewinnt.
    public var rules: [Rule]
    /// Wenn keine Regel passt.
    public var defaultAction: Action
    /// KI-Assistent (§12). Optional: fehlt in älteren Configs und wird nur geschrieben, wenn gesetzt.
    public var assistant: AssistantSettings?
    /// Verhalten für Links aus der Safari-Erweiterung (§21.2). Optional: fehlt = Standard, wird nur geschrieben, wenn gesetzt.
    public var extensionSettings: ExtensionSettings?
    /// Darstellung der App (§23.1). `nil` = System; `.system` wird als `nil` gespeichert.
    public var appearance: AppAppearance? {
        didSet { if appearance == .system { appearance = nil } }
    }

    public init(
        schemaVersion: Int = Config.currentSchemaVersion,
        browsers: [AppRef] = [],
        rules: [Rule] = [],
        defaultAction: Action = .prompt(.all),
        assistant: AssistantSettings? = nil,
        extensionSettings: ExtensionSettings? = nil,
        appearance: AppAppearance? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.browsers = browsers
        self.rules = rules
        self.defaultAction = defaultAction
        self.assistant = assistant
        self.extensionSettings = extensionSettings
        self.appearance = appearance == .system ? nil : appearance
    }

    /// Wirksame Darstellung; fehlt = System.
    public var effectiveAppearance: AppAppearance { appearance ?? .system }

    /// Modell-ID für den Assistenten; leer oder fehlend = Standard.
    public var assistantModel: String {
        let model = assistant?.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return model.isEmpty ? AssistantSettings.defaultModel : model
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, browsers, rules, defaultAction, assistant, extensionSettings, appearance
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        browsers = try c.decodeIfPresent([AppRef].self, forKey: .browsers) ?? []
        rules = try c.decodeIfPresent([Rule].self, forKey: .rules) ?? []
        defaultAction = try c.decodeIfPresent(Action.self, forKey: .defaultAction) ?? .prompt(.all)
        assistant = try c.decodeIfPresent(AssistantSettings.self, forKey: .assistant)
        extensionSettings = try c.decodeIfPresent(ExtensionSettings.self, forKey: .extensionSettings)
        // Unbekannter Wert (neuere Version) → System statt Ladefehler.
        let decoded = (try? c.decodeIfPresent(AppAppearance.self, forKey: .appearance)) ?? nil
        appearance = decoded == .system ? nil : decoded
    }
}

/// Darstellung der App (§23.1): System folgt macOS.
public enum AppAppearance: String, Codable, Sendable, CaseIterable, Identifiable {
    case system, light, dark

    public var id: String { rawValue }
}

/// Verhalten für `airtraffic://open`-Links aus der Safari-Erweiterung ohne `prompt` (§21.2):
/// „Mit Air Traffic öffnen“ und Symbolleisten-Knopf. „Mit Air Traffic auswählen …“ zeigt immer die Auswahl.
public struct ExtensionSettings: Codable, Sendable, Equatable {
    /// Regeln (Bedingungen + Umschreibungen) wie beim Standardbrowser anwenden.
    public var applyRules: Bool
    /// Aktion, wenn keine Regel passt bzw. wenn `applyRules == false`; `nil` = globale Standardaktion.
    public var fallbackAction: Action?

    public init(applyRules: Bool = true, fallbackAction: Action? = nil) {
        self.applyRules = applyRules
        self.fallbackAction = fallbackAction
    }

    private enum CodingKeys: String, CodingKey { case applyRules, fallbackAction }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        applyRules = try c.decodeIfPresent(Bool.self, forKey: .applyRules) ?? true
        fallbackAction = try c.decodeIfPresent(Action.self, forKey: .fallbackAction)
    }

    /// Alles auf Standard – dann schreibt die Config den Abschnitt gar nicht.
    public var isDefault: Bool { self == ExtensionSettings() }
}

/// Einstellungen des KI-Assistenten. Der API-Key steht nie hier, nur im Schlüsselbund.
/// Alle Felder optional: fehlt = Standard, `nil` wird nicht geschrieben (ältere Configs bleiben ladbar).
public struct AssistantSettings: Codable, Sendable, Equatable {
    public static let defaultModel = "anthropic/claude-haiku-5.5"
    public static let defaultClaudeModel = "haiku"

    /// Transport (§16); `nil` = `.openRouter`.
    public var provider: AssistantProvider?
    /// OpenRouter-Modell-ID; `nil` = `defaultModel`.
    public var model: String?
    /// Modell für Claude Code (`--model`); `nil` = `defaultClaudeModel`.
    public var claudeModel: String?
    /// Modell für Codex (`-m`); `nil` = Standard der CLI.
    public var codexModel: String?
    /// Pfad zur `claude`-Binärdatei; `nil` = automatisch suchen.
    public var claudePath: String?
    /// Pfad zur `codex`-Binärdatei; `nil` = automatisch suchen.
    public var codexPath: String?

    public init(
        provider: AssistantProvider? = nil,
        model: String? = nil,
        claudeModel: String? = nil,
        codexModel: String? = nil,
        claudePath: String? = nil,
        codexPath: String? = nil
    ) {
        self.provider = provider
        self.model = model
        self.claudeModel = claudeModel
        self.codexModel = codexModel
        self.claudePath = claudePath
        self.codexPath = codexPath
    }

    private enum CodingKeys: String, CodingKey {
        case provider, model, claudeModel, codexModel, claudePath, codexPath
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Unbekannter Anbieter (neuere Version) → Standard statt unlesbarer Config.
        provider = (try? c.decodeIfPresent(AssistantProvider.self, forKey: .provider)) ?? nil
        model = try c.decodeIfPresent(String.self, forKey: .model)
        claudeModel = try c.decodeIfPresent(String.self, forKey: .claudeModel)
        codexModel = try c.decodeIfPresent(String.self, forKey: .codexModel)
        claudePath = try c.decodeIfPresent(String.self, forKey: .claudePath)
        codexPath = try c.decodeIfPresent(String.self, forKey: .codexPath)
    }

    /// Alles auf Standard – dann schreibt die Config den Abschnitt gar nicht.
    public var isEmpty: Bool { self == AssistantSettings() }

    /// Leere Strings und `provider == .openRouter` werden zu `nil` (Standard).
    public func normalized() -> AssistantSettings {
        func clean(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        return AssistantSettings(
            provider: provider == .openRouter ? nil : provider,
            model: clean(model),
            claudeModel: clean(claudeModel),
            codexModel: clean(codexModel),
            claudePath: clean(claudePath),
            codexPath: clean(codexPath)
        )
    }

    /// Konfigurierter Pfad der CLI (nil = automatisch suchen).
    public func path(for cli: AssistantCLI) -> String? {
        switch cli {
        case .claude: claudePath
        case .codex: codexPath
        }
    }
}

/// Wie der KI-Assistent das Modell erreicht (§16).
public enum AssistantProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    case openRouter, claudeCLI, codexCLI

    public var id: String { rawValue }

    /// Kurzname für Untertitel und Hinweise.
    public var displayName: String {
        switch self {
        case .openRouter: "OpenRouter"
        case .claudeCLI: "Claude Code"
        case .codexCLI: "Codex"
        }
    }

    /// Eintrag im Anbieter-Picker.
    public var pickerTitle: String {
        switch self {
        case .openRouter: "OpenRouter (API-Key)"
        case .claudeCLI: "Claude-Abo (Claude Code)"
        case .codexCLI: "ChatGPT-Abo (Codex)"
        }
    }

    /// Wohin Beschreibung und Beispiel-URLs gehen (Datenschutzhinweis).
    public var recipient: String {
        switch self {
        case .openRouter: "OpenRouter"
        case .claudeCLI: "Claude Code (Anthropic)"
        case .codexCLI: "Codex (OpenAI)"
        }
    }

    /// Lokale CLI; `nil` für OpenRouter.
    public var cli: AssistantCLI? {
        switch self {
        case .openRouter: nil
        case .claudeCLI: .claude
        case .codexCLI: .codex
        }
    }

    /// Wert für `--provider` (`--suggest-regex`).
    public var argument: String {
        switch self {
        case .openRouter: "openrouter"
        case .claudeCLI: "claude"
        case .codexCLI: "codex"
        }
    }

    public init?(argument: String) {
        guard let match = AssistantProvider.allCases.first(where: { $0.argument == argument.lowercased() }) else { return nil }
        self = match
    }
}

extension Config {
    /// Aktiver Anbieter; fehlt = OpenRouter.
    public var assistantProvider: AssistantProvider { assistant?.provider ?? .openRouter }

    /// Modell für Claude Code; leer oder fehlend = `haiku`.
    public var assistantClaudeModel: String {
        let model = assistant?.claudeModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return model.isEmpty ? AssistantSettings.defaultClaudeModel : model
    }

    /// Modell für Codex; leer = Standard der CLI (kein `-m`).
    public var assistantCodexModel: String {
        assistant?.codexModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Modell, das an den `LLMClient` des Anbieters geht.
    public func assistantModel(for provider: AssistantProvider) -> String {
        switch provider {
        case .openRouter: assistantModel
        case .claudeCLI: assistantClaudeModel
        case .codexCLI: assistantCodexModel
        }
    }

    /// Anzeige „Anbieter · Modell“ (KI-Sheet).
    public func assistantModelLabel(for provider: AssistantProvider) -> String {
        let model = assistantModel(for: provider)
        return model.isEmpty ? "Standardmodell" : model
    }
}

// MARK: - Rule

public enum MatchMode: String, Codable, Sendable, CaseIterable {
    case all, any, none
}

public struct Rule: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var match: MatchMode
    /// Leer = passt immer.
    public var conditions: [Condition]
    /// Nacheinander angewendet, darf leer sein.
    public var rewrites: [Rewrite]
    public var action: Action
    /// Test-URL für den Abschnitt „Test“ im Regel-Editor (§14). Optional: fehlt = nil, wird bei nil nicht geschrieben.
    public var testURL: String?
    /// Änderung von außen (CLI/MCP) an Umschreibungen oder Aktion, die noch in der App freigegeben
    /// werden muss (§26.1). Optional: fehlt = freigegeben, wird bei nil nicht geschrieben.
    public var pendingChange: PendingChange?

    public init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        match: MatchMode = .all,
        conditions: [Condition] = [],
        rewrites: [Rewrite] = [],
        action: Action = .prompt(.all),
        testURL: String? = nil,
        pendingChange: PendingChange? = nil
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.match = match
        self.conditions = conditions
        self.rewrites = rewrites
        self.action = action
        self.testURL = testURL
        self.pendingChange = pendingChange
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, enabled, match, conditions, rewrites, action, testURL, pendingChange
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        match = try c.decodeIfPresent(MatchMode.self, forKey: .match) ?? .all
        conditions = try c.decodeIfPresent([Condition].self, forKey: .conditions) ?? []
        rewrites = try c.decodeIfPresent([Rewrite].self, forKey: .rewrites) ?? []
        action = try c.decode(Action.self, forKey: .action)
        testURL = try c.decodeIfPresent(String.self, forKey: .testURL)
        pendingChange = try c.decodeIfPresent(PendingChange.self, forKey: .pendingChange)
    }

    /// Stand, den die Engine auswertet (§26.1, §27 K4): ohne wartende Änderung die Regel selbst; neu
    /// angelegt und wartend → `nil` (übersprungen); geändert und wartend → die aktuelle Regel mit
    /// Umschreibungen und Aktion aus dem zuletzt freigegebenen Stand. Name, Bedingungen, Test-URL und
    /// An/Aus wirken sofort.
    public var effective: Rule? {
        guard let pendingChange else { return self }
        guard let previous = pendingChange.previous else { return nil }
        var rule = self
        rule.rewrites = previous.rewrites
        rule.action = previous.action
        rule.pendingChange = nil
        return rule
    }

    /// Wartet auf Freigabe in der App.
    public var isPendingApproval: Bool { pendingChange != nil }
}

// MARK: - Freigabe (§26.1)

/// Änderung von außen an Umschreibungen oder Aktion, die erst nach Freigabe in der App wirkt.
public struct PendingChange: Codable, Sendable, Equatable {
    /// Seit wann die Änderung wartet (erste noch nicht freigegebene Änderung).
    public var since: Date
    /// Kurzer Grund, z. B. „Umschreibungen geändert“.
    public var reason: String
    /// Array statt Optional, weil `Rule` sonst sich selbst enthielte (Wertetyp ohne Indirektion).
    private var previousStorage: [Rule]

    /// Vollständiger zuletzt freigegebener Stand; `nil` = neu angelegt.
    public var previous: Rule? {
        get { previousStorage.first }
        set {
            guard var rule = newValue else { previousStorage = []; return }
            rule.pendingChange = nil
            previousStorage = [rule]
        }
    }

    public init(since: Date, reason: String, previous: Rule?) {
        self.since = since
        self.reason = reason
        self.previousStorage = []
        self.previous = previous
    }

    private enum CodingKeys: String, CodingKey { case since, reason, previous }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? c.decode(String.self, forKey: .since), let date = PendingChange.parseDate(text) {
            since = date
        } else {
            since = try c.decode(Date.self, forKey: .since)
        }
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        previousStorage = []
        previous = try c.decodeIfPresent(Rule.self, forKey: .previous)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // ISO 8601 statt Sekunden seit 2001 – lesbar in config.json.
        try c.encode(PendingChange.formatDate(since), forKey: .since)
        try c.encode(reason, forKey: .reason)
        try c.encodeIfPresent(previous, forKey: .previous)
    }

    /// ISO 8601 mit auf Millisekunden gerundetem Bruchteil (§27 K14): Lesen und erneutes Schreiben
    /// ergeben dieselben Bytes (der Formatierer schneidet sonst ab, 0,234 → 0,233).
    static func formatDate(_ date: Date) -> String {
        let millis = (date.timeIntervalSince1970 * 1000).rounded()
        let seconds = (millis / 1000).rounded(.down)
        let fraction = Int(millis - seconds * 1000)
        let whole = Date.ISO8601FormatStyle().format(Date(timeIntervalSince1970: seconds))
        guard whole.hasSuffix("Z") else { return Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date) }
        return String(whole.dropLast()) + "." + String(format: "%03d", fraction) + "Z"
    }

    static func parseDate(_ text: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            ?? (try? Date.ISO8601FormatStyle().parse(text))
    }
}

// MARK: - Condition

public enum LinkType: String, Codable, Sendable, CaseIterable {
    case web, file
}

public enum TextOp: String, Codable, Sendable, CaseIterable {
    case equals, notEquals, contains, notContains, beginsWith, endsWith, wildcard, regex
}

public struct TextMatch: Codable, Sendable, Equatable {
    public var op: TextOp
    public var value: String
    public var caseSensitive: Bool

    public init(op: TextOp, value: String, caseSensitive: Bool = false) {
        self.op = op
        self.value = value
        self.caseSensitive = caseSensitive
    }

    private enum CodingKeys: String, CodingKey { case op, value, caseSensitive }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        op = try c.decode(TextOp.self, forKey: .op)
        value = try c.decode(String.self, forKey: .value)
        caseSensitive = try c.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? false
    }
}

public struct ModifierSet: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = ModifierSet(rawValue: 1 << 0)
    public static let option = ModifierSet(rawValue: 1 << 1)
    public static let control = ModifierSet(rawValue: 1 << 2)
    public static let shift = ModifierSet(rawValue: 1 << 3)

    /// Stabile Reihenfolge und Namen für JSON und UI.
    public static let named: [(name: String, value: ModifierSet)] = [
        ("command", .command), ("option", .option), ("control", .control), ("shift", .shift),
    ]

    public var names: [String] {
        ModifierSet.named.filter { contains($0.value) }.map(\.name)
    }

    /// JSON-Form: Array von Namen, z. B. `["command","shift"]`.
    public init(from decoder: any Decoder) throws {
        let names = try decoder.singleValueContainer().decode([String].self)
        var set: ModifierSet = []
        for name in names {
            guard let entry = ModifierSet.named.first(where: { $0.name == name }) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unbekannter Modifier '\(name)'"
                ))
            }
            set.insert(entry.value)
        }
        self = set
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(names)
    }
}

public enum Condition: Sendable, Equatable {
    /// Gesamte URL als String.
    case url(TextMatch)
    /// `URL.host`.
    case host(TextMatch)
    /// `URL.path`.
    case path(TextMatch)
    case sourceApp(bundleIdentifier: String, negated: Bool)
    /// Exakter Vergleich der Menge.
    case modifiers(ModifierSet, negated: Bool)
    case linkType(LinkType)
}

extension Condition: Codable {
    private enum Kind: String, Codable {
        case url, host, path, sourceApp, modifiers, linkType
    }

    private enum CodingKeys: String, CodingKey {
        case type, op, value, caseSensitive, bundleIdentifier, negated, modifiers, linkType
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .type)
        func text() throws -> TextMatch {
            TextMatch(
                op: try c.decode(TextOp.self, forKey: .op),
                value: try c.decode(String.self, forKey: .value),
                caseSensitive: try c.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? false
            )
        }
        switch kind {
        case .url: self = .url(try text())
        case .host: self = .host(try text())
        case .path: self = .path(try text())
        case .sourceApp:
            self = .sourceApp(
                bundleIdentifier: try c.decode(String.self, forKey: .bundleIdentifier),
                negated: try c.decodeIfPresent(Bool.self, forKey: .negated) ?? false
            )
        case .modifiers:
            self = .modifiers(
                try c.decode(ModifierSet.self, forKey: .modifiers),
                negated: try c.decodeIfPresent(Bool.self, forKey: .negated) ?? false
            )
        case .linkType:
            self = .linkType(try c.decode(LinkType.self, forKey: .linkType))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        func text(_ kind: Kind, _ m: TextMatch) throws {
            try c.encode(kind, forKey: .type)
            try c.encode(m.op, forKey: .op)
            try c.encode(m.value, forKey: .value)
            try c.encode(m.caseSensitive, forKey: .caseSensitive)
        }
        switch self {
        case .url(let m): try text(.url, m)
        case .host(let m): try text(.host, m)
        case .path(let m): try text(.path, m)
        case .sourceApp(let id, let negated):
            try c.encode(Kind.sourceApp, forKey: .type)
            try c.encode(id, forKey: .bundleIdentifier)
            try c.encode(negated, forKey: .negated)
        case .modifiers(let set, let negated):
            try c.encode(Kind.modifiers, forKey: .type)
            try c.encode(set, forKey: .modifiers)
            try c.encode(negated, forKey: .negated)
        case .linkType(let type):
            try c.encode(Kind.linkType, forKey: .type)
            try c.encode(type, forKey: .linkType)
        }
    }
}

// MARK: - Rewrite

/// `NSRegularExpression.stringByReplacingMatches(…, withTemplate:)` → `$1`, `$2` …;
/// ersetzt nur, wenn `pattern` trifft.
public struct Rewrite: Codable, Sendable, Equatable {
    public var pattern: String
    public var template: String
    public var caseSensitive: Bool

    public init(pattern: String, template: String, caseSensitive: Bool = false) {
        self.pattern = pattern
        self.template = template
        self.caseSensitive = caseSensitive
    }

    private enum CodingKeys: String, CodingKey { case pattern, template, caseSensitive }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pattern = try c.decode(String.self, forKey: .pattern)
        template = try c.decode(String.self, forKey: .template)
        caseSensitive = try c.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? false
    }
}

// MARK: - Action

public enum PromptScope: String, Codable, Sendable, CaseIterable {
    case all, running
}

public enum Action: Sendable, Equatable {
    /// Genau diese App.
    case open(AppRef)
    /// Höchster laufender Eintrag aus `browsers`, sonst `fallback`, sonst `browsers[0]`.
    case openFirstRunning(fallback: AppRef?)
    case prompt(PromptScope)
}

extension Action: Codable {
    private enum Kind: String, Codable { case open, openFirstRunning, prompt }
    private enum CodingKeys: String, CodingKey { case type, app, fallback, scope }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .open: self = .open(try c.decode(AppRef.self, forKey: .app))
        case .openFirstRunning:
            self = .openFirstRunning(fallback: try c.decodeIfPresent(AppRef.self, forKey: .fallback))
        case .prompt: self = .prompt(try c.decodeIfPresent(PromptScope.self, forKey: .scope) ?? .all)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .open(let app):
            try c.encode(Kind.open, forKey: .type)
            try c.encode(app, forKey: .app)
        case .openFirstRunning(let fallback):
            try c.encode(Kind.openFirstRunning, forKey: .type)
            try c.encodeIfPresent(fallback, forKey: .fallback)
        case .prompt(let scope):
            try c.encode(Kind.prompt, forKey: .type)
            try c.encode(scope, forKey: .scope)
        }
    }
}

// MARK: - Kontext & Entscheidung

/// Kontext eines eingehenden Links (in der App-Schicht erfasst).
public struct LinkContext: Sendable, Equatable {
    public var sourceBundleIdentifier: String?
    public var modifiers: ModifierSet
    public var runningBundleIdentifiers: Set<String>

    public init(
        sourceBundleIdentifier: String? = nil,
        modifiers: ModifierSet = [],
        runningBundleIdentifiers: Set<String> = []
    ) {
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.modifiers = modifiers
        self.runningBundleIdentifiers = runningBundleIdentifiers
    }
}

public struct Decision: Codable, Sendable, Equatable {
    public var originalURL: URL
    public var finalURL: URL
    public var matchedRuleID: UUID?
    public var action: Action
    public var warnings: [String]

    public init(originalURL: URL, finalURL: URL, matchedRuleID: UUID?, action: Action, warnings: [String]) {
        self.originalURL = originalURL
        self.finalURL = finalURL
        self.matchedRuleID = matchedRuleID
        self.action = action
        self.warnings = warnings
    }

    private enum CodingKeys: String, CodingKey {
        case originalURL, finalURL, matchedRuleID, action, warnings
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func url(_ key: CodingKeys) throws -> URL {
            let s = try c.decode(String.self, forKey: key)
            guard let u = URL(string: s) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Ungültige URL")
            }
            return u
        }
        originalURL = try url(.originalURL)
        finalURL = try url(.finalURL)
        matchedRuleID = try c.decodeIfPresent(UUID.self, forKey: .matchedRuleID)
        action = try c.decode(Action.self, forKey: .action)
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(originalURL.absoluteString, forKey: .originalURL)
        try c.encode(finalURL.absoluteString, forKey: .finalURL)
        // Explizit null, damit „keine Regel“ im JSON sichtbar ist.
        try c.encode(matchedRuleID, forKey: .matchedRuleID)
        try c.encode(action, forKey: .action)
        try c.encode(warnings, forKey: .warnings)
    }
}
