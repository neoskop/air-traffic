import Foundation

// MARK: - Fehler (SPEC §24.3, §24.4)

/// Fehler eines Felds: Pfad wie `conditions[1].value` und Grund.
public struct FieldIssue: Sendable, Equatable, CustomStringConvertible {
    public var field: String
    public var reason: String

    public init(_ field: String, _ reason: String) {
        self.field = field
        self.reason = reason
    }

    public var description: String { field.isEmpty ? reason : "\(field): \(reason)" }
}

/// Fachfehler der Agenten-Schnittstelle, deutsch beschrieben.
public enum AgentError: Error, LocalizedError, Equatable, Sendable {
    /// Falscher Aufruf (unbekannter Befehl, fehlendes Argument).
    case usage(String)
    /// Eingabe ist kein gültiges JSON oder hat die falsche Form.
    case badInput(String)
    /// Validierung fehlgeschlagen; je Feld ein Grund.
    case invalid([FieldIssue])
    /// Keine Regel zu `ref`.
    case notFound(String)
    /// Mehrere Regeln passen zu `ref`; Kandidaten als „#3 Name (id)“.
    case ambiguous(String, candidates: [String])

    public var errorDescription: String? {
        switch self {
        case .usage(let message), .badInput(let message):
            message
        case .invalid(let issues):
            issues.count == 1
                ? "Ungültige Regel – \(issues[0])"
                : "Ungültige Regel:\n" + issues.map { "- \($0)" }.joined(separator: "\n")
        case .notFound(let ref):
            "Keine Regel zu „\(ref)“ gefunden (UUID, UUID-Präfix ab 6 Zeichen, #Position oder exakter Name)."
        case .ambiguous(let ref, let candidates):
            "„\(ref)“ ist mehrdeutig. Kandidaten:\n" + candidates.map { "- \($0)" }.joined(separator: "\n")
        }
    }
}

// MARK: - Regel-Referenzen

/// `<ref>` = UUID, eindeutiges UUID-Präfix (≥ 6 Zeichen), Position (`#3`) oder exakter Name (§24.3).
public enum RuleRef {
    public static let minimumPrefixLength = 6

    /// Index (0-basiert) der Regel zu `ref`.
    public static func resolve(_ ref: String, in rules: [Rule]) throws(AgentError) -> Int {
        let text = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw .usage("Regel-Referenz fehlt.") }

        if text.hasPrefix("#"), let position = Int(text.dropFirst()) {
            guard rules.indices.contains(position - 1) else {
                throw .notFound(text)
            }
            return position - 1
        }
        if let uuid = UUID(uuidString: text), let index = rules.firstIndex(where: { $0.id == uuid }) {
            return index
        }

        var candidates: [Int] = []
        for (index, rule) in rules.enumerated() where rule.name == text {
            candidates.append(index)
        }
        let lower = text.lowercased()
        if lower.count >= minimumPrefixLength, lower.allSatisfy({ $0.isHexDigit || $0 == "-" }) {
            for (index, rule) in rules.enumerated()
            where rule.id.uuidString.lowercased().hasPrefix(lower) && !candidates.contains(index) {
                candidates.append(index)
            }
        }
        switch candidates.count {
        case 0: throw .notFound(text)
        case 1: return candidates[0]
        default:
            throw .ambiguous(text, candidates: candidates.sorted().map { label(rules[$0], position: $0 + 1) })
        }
    }

    /// „#3 Name (uuid)“ für Kandidatenlisten.
    public static func label(_ rule: Rule, position: Int) -> String {
        "#\(position) \(rule.name) (\(rule.id.uuidString.lowercased()))"
    }
}

// MARK: - App-Auflösung

/// Löst Kurzformen für Ziel-Apps auf (Name, Bundle-ID oder Pfad, §24.2). Die Umsetzung mit
/// LaunchServices/NSWorkspace liegt im Kommandozeilen-Tool; Tests nutzen eine feste Liste.
public protocol AppResolving: Sendable {
    /// App zu einem Namen, einer Bundle-ID oder einem Pfad; `nil` = nicht gefunden.
    func resolveApp(_ query: String) -> AppRef?
    /// Ob die App auf diesem Mac auffindbar ist (Bundle-ID oder Pfad).
    func isInstalled(_ app: AppRef) -> Bool
    /// Installierte Apps, die https-Links öffnen können.
    func installedBrowsers() -> [AppRef]
}

// MARK: - Eingabe (§24.2)

/// Wandelt Agenten-JSON in `Rule` um: Kurzformen auflösen, unbekannte Felder ablehnen, validieren.
public struct RuleInput: Sendable {
    public let resolver: any AppResolving
    /// Browserliste der Config: Namen/Bundle-IDs dort zuerst (gleiche `AppRef` wie in der App).
    public let browsers: [AppRef]

    public init(resolver: any AppResolving, browsers: [AppRef]) {
        self.resolver = resolver
        self.browsers = browsers
    }

    /// Erlaubte Felder einer Regel in Eingaben; `position` nur für Agenten (Einfügen/Verschieben).
    static let ruleKeys: Set<String> = ["id", "name", "enabled", "match", "conditions", "rewrites", "action", "testURL", "position"]

    /// Ergebnis einer Umwandlung.
    public struct Output: Sendable {
        public var rule: Rule
        /// Gewünschte Position (1-basiert), falls `position` angegeben.
        public var position: Int?
        public var warnings: [String]
    }

    /// Neue Regel aus vollständigem JSON; `id` fehlt → neue UUID.
    public func makeRule(from json: JSONValue) throws(AgentError) -> Output {
        guard let object = json.objectValue else {
            throw .badInput("Regel muss ein JSON-Objekt sein, nicht \(json.typeName).")
        }
        var issues: [FieldIssue] = []
        let (normalized, position) = normalizeRule(object, issues: &issues)
        if normalized["action"] == nil { issues.append(FieldIssue("action", "fehlt")) }
        guard issues.isEmpty else { throw .invalid(issues) }
        var rule = try decodeRule(normalized)
        if normalized["id"] == nil { rule.id = UUID() }
        let warnings = try validate(rule)
        return Output(rule: rule, position: position, warnings: warnings)
    }

    /// Teilobjekt auf eine bestehende Regel: Felder ersetzen, `conditions`/`rewrites` als ganze Liste.
    public func apply(patch json: JSONValue, to rule: Rule) throws(AgentError) -> Output {
        guard let object = json.objectValue else {
            throw .badInput("Änderung muss ein JSON-Objekt sein, nicht \(json.typeName).")
        }
        var issues: [FieldIssue] = []
        let (normalized, position) = normalizeRule(object, issues: &issues)
        if let id = normalized["id"]?.stringValue, UUID(uuidString: id) != rule.id {
            issues.append(FieldIssue("id", "kann nicht geändert werden"))
        }
        guard issues.isEmpty else { throw .invalid(issues) }
        guard var merged = (try? JSONValue(encoding: rule))?.objectValue else {
            throw .badInput("Regel nicht kodierbar.")
        }
        for (key, value) in normalized { merged[key] = value }
        if normalized["testURL"]?.isNull == true { merged["testURL"] = nil }
        let updated = try decodeRule(merged)
        let warnings = try validate(updated)
        return Output(rule: updated, position: position, warnings: warnings)
    }

    // MARK: Normalisieren

    /// Prüft Felder und Typen, löst Kurzformen auf. Gibt das normalisierte Objekt (ohne `position`) zurück.
    func normalizeRule(_ object: [String: JSONValue], issues: inout [FieldIssue]) -> ([String: JSONValue], Int?) {
        var result: [String: JSONValue] = [:]
        var position: Int?
        for key in object.keys.sorted() where !Self.ruleKeys.contains(key) {
            if key == "pendingChange" {
                // Freigabe nur in der App (§26.1).
                issues.append(RuleApproval.inputIssue)
                continue
            }
            issues.append(FieldIssue(key, "unbekanntes Feld (erlaubt: \(Self.ruleKeys.sorted().joined(separator: ", ")))"))
        }
        for (key, value) in object.sorted(by: { $0.key < $1.key }) where Self.ruleKeys.contains(key) {
            switch key {
            case "id":
                guard let text = value.stringValue, UUID(uuidString: text) != nil else {
                    issues.append(FieldIssue("id", "keine gültige UUID"))
                    continue
                }
                result[key] = value
            case "name":
                guard expect(value, isString: true, field: key, issues: &issues) else { continue }
                if (value.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append(FieldIssue("name", "darf nicht leer sein"))
                }
                result[key] = value
            case "testURL":
                if value.isNull || expect(value, isString: true, field: key, issues: &issues) { result[key] = value }
            case "enabled":
                if expectBool(value, field: key, issues: &issues) { result[key] = value }
            case "match":
                if expectEnum(value, MatchMode.allCases.map(\.rawValue), field: key, issues: &issues) { result[key] = value }
            case "position":
                guard let n = value.intValue, n >= 1 else {
                    issues.append(FieldIssue("position", "muss eine Zahl ab 1 sein"))
                    continue
                }
                position = n
            case "conditions":
                guard let list = value.arrayValue else {
                    issues.append(FieldIssue(key, "muss eine Liste sein"))
                    continue
                }
                result[key] = .array(list.enumerated().map { normalizeCondition($1, field: "conditions[\($0)]", issues: &issues) })
            case "rewrites":
                guard let list = value.arrayValue else {
                    issues.append(FieldIssue(key, "muss eine Liste sein"))
                    continue
                }
                result[key] = .array(list.enumerated().map { normalizeRewrite($1, field: "rewrites[\($0)]", issues: &issues) })
            case "action":
                result[key] = normalizeAction(value, field: "action", issues: &issues)
            default:
                break
            }
        }
        return (result, position)
    }

    static let conditionKeys: [String: Set<String>] = [
        "url": ["type", "op", "value", "caseSensitive"],
        "host": ["type", "op", "value", "caseSensitive"],
        "path": ["type", "op", "value", "caseSensitive"],
        "sourceApp": ["type", "bundleIdentifier", "negated"],
        "modifiers": ["type", "modifiers", "negated"],
        "linkType": ["type", "linkType"],
    ]

    private func normalizeCondition(_ value: JSONValue, field: String, issues: inout [FieldIssue]) -> JSONValue {
        guard let object = value.objectValue else {
            issues.append(FieldIssue(field, "muss ein Objekt sein"))
            return value
        }
        guard let type = object["type"]?.stringValue, let allowed = Self.conditionKeys[type] else {
            issues.append(FieldIssue("\(field).type", "fehlt oder unbekannt (erlaubt: \(Self.conditionKeys.keys.sorted().joined(separator: ", ")))"))
            return value
        }
        checkKeys(object, allowed: allowed, field: field, issues: &issues)
        var result = object
        switch type {
        case "url", "host", "path":
            let validOp = expectEnum(object["op"], TextOp.allCases.map(\.rawValue), field: "\(field).op", issues: &issues)
            if expect(object["value"], isString: true, field: "\(field).value", issues: &issues), validOp,
               object["op"]?.stringValue == TextOp.regex.rawValue, let pattern = object["value"]?.stringValue,
               (try? NSRegularExpression(pattern: pattern)) == nil {
                issues.append(FieldIssue("\(field).value", "ungültiger regulärer Ausdruck „\(pattern)“"))
            }
            if let flag = object["caseSensitive"] { _ = expectBool(flag, field: "\(field).caseSensitive", issues: &issues) }
        case "sourceApp":
            if let id = object["bundleIdentifier"]?.stringValue, !id.trimmingCharacters(in: .whitespaces).isEmpty {
                result["bundleIdentifier"] = .string(id.trimmingCharacters(in: .whitespaces))
            } else {
                issues.append(FieldIssue("\(field).bundleIdentifier", "fehlt oder ist leer"))
            }
            if let flag = object["negated"] { _ = expectBool(flag, field: "\(field).negated", issues: &issues) }
        case "modifiers":
            if let names = object["modifiers"]?.arrayValue {
                let known = ModifierSet.named.map(\.name)
                for (index, name) in names.enumerated() where !known.contains(name.stringValue ?? "") {
                    issues.append(FieldIssue("\(field).modifiers[\(index)]", "unbekannt (erlaubt: \(known.joined(separator: ", ")))"))
                }
            } else {
                issues.append(FieldIssue("\(field).modifiers", "muss eine Liste sein, z. B. [\"command\"] oder []"))
            }
            if let flag = object["negated"] { _ = expectBool(flag, field: "\(field).negated", issues: &issues) }
        case "linkType":
            _ = expectEnum(object["linkType"], LinkType.allCases.map(\.rawValue), field: "\(field).linkType", issues: &issues)
        default:
            break
        }
        return .object(result)
    }

    private func normalizeRewrite(_ value: JSONValue, field: String, issues: inout [FieldIssue]) -> JSONValue {
        guard let object = value.objectValue else {
            issues.append(FieldIssue(field, "muss ein Objekt sein"))
            return value
        }
        checkKeys(object, allowed: ["pattern", "template", "caseSensitive"], field: field, issues: &issues)
        if expect(object["pattern"], isString: true, field: "\(field).pattern", issues: &issues),
           let pattern = object["pattern"]?.stringValue,
           let message = Rewriter.validationError(for: Rewrite(pattern: pattern, template: "")) {
            issues.append(FieldIssue("\(field).pattern", "ungültiger regulärer Ausdruck „\(pattern)“ (\(message))"))
        }
        _ = expect(object["template"], isString: true, field: "\(field).template", issues: &issues)
        if let flag = object["caseSensitive"] { _ = expectBool(flag, field: "\(field).caseSensitive", issues: &issues) }
        return value
    }

    private func normalizeAction(_ value: JSONValue, field: String, issues: inout [FieldIssue]) -> JSONValue {
        guard let object = value.objectValue else {
            issues.append(FieldIssue(field, "muss ein Objekt sein, z. B. {\"type\": \"open\", \"app\": \"Safari\"}"))
            return value
        }
        let kinds: [String: Set<String>] = [
            "open": ["type", "app"],
            "openFirstRunning": ["type", "fallback"],
            "prompt": ["type", "scope"],
        ]
        guard let type = object["type"]?.stringValue, let allowed = kinds[type] else {
            issues.append(FieldIssue("\(field).type", "fehlt oder unbekannt (erlaubt: open, openFirstRunning, prompt)"))
            return value
        }
        checkKeys(object, allowed: allowed, field: field, issues: &issues)
        var result = object
        switch type {
        case "open":
            if let app = object["app"] {
                result["app"] = normalizeApp(app, field: "\(field).app", issues: &issues)
            } else {
                issues.append(FieldIssue("\(field).app", "fehlt (Name, Bundle-ID oder Pfad der App)"))
            }
        case "openFirstRunning":
            if let fallback = object["fallback"] {
                result["fallback"] = fallback.isNull ? nil : normalizeApp(fallback, field: "\(field).fallback", issues: &issues)
            }
        case "prompt":
            if let scope = object["scope"] {
                _ = expectEnum(scope, PromptScope.allCases.map(\.rawValue), field: "\(field).scope", issues: &issues)
            }
        default:
            break
        }
        return .object(result)
    }

    /// App als Text (Name, Bundle-ID, Pfad) oder `AppRef`-Objekt.
    private func normalizeApp(_ value: JSONValue, field: String, issues: inout [FieldIssue]) -> JSONValue {
        if let text = value.stringValue {
            guard let app = resolveApp(text) else {
                issues.append(FieldIssue(field, "App „\(text)“ nicht gefunden (Name, Bundle-ID oder Pfad angeben)"))
                return value
            }
            return (try? JSONValue(encoding: app)) ?? value
        }
        guard let object = value.objectValue else {
            issues.append(FieldIssue(field, "muss Name/Bundle-ID/Pfad (Text) oder ein Objekt {bundleIdentifier, path, displayName} sein"))
            return value
        }
        checkKeys(object, allowed: ["bundleIdentifier", "path", "displayName"], field: field, issues: &issues)
        let id = object["bundleIdentifier"]?.stringValue?.trimmingCharacters(in: .whitespaces)
        var path = object["path"]?.stringValue ?? ""
        var name = object["displayName"]?.stringValue ?? ""
        if path.isEmpty, let id, !id.isEmpty, let found = resolveApp(id) {
            path = found.path
            if name.isEmpty { name = found.displayName }
        }
        if (id ?? "").isEmpty, path.isEmpty {
            issues.append(FieldIssue(field, "braucht bundleIdentifier oder path"))
            return value
        }
        if name.isEmpty { name = path.isEmpty ? (id ?? "") : AppRef.displayName(forPath: path) }
        let app = AppRef(bundleIdentifier: (id ?? "").isEmpty ? nil : id, path: path, displayName: name)
        return (try? JSONValue(encoding: app)) ?? value
    }

    /// Browserliste der Config zuerst (Name oder Bundle-ID), dann das System.
    func resolveApp(_ query: String) -> AppRef? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("/") {
            if let match = browsers.first(where: {
                $0.displayName.caseInsensitiveCompare(text) == .orderedSame
                    || $0.bundleIdentifier?.caseInsensitiveCompare(text) == .orderedSame
            }) {
                return match
            }
        }
        return resolver.resolveApp(text)
    }

    // MARK: Typprüfungen

    private func checkKeys(_ object: [String: JSONValue], allowed: Set<String>, field: String, issues: inout [FieldIssue]) {
        for key in object.keys.sorted() where !allowed.contains(key) {
            issues.append(FieldIssue("\(field).\(key)", "unbekanntes Feld (erlaubt: \(allowed.sorted().joined(separator: ", ")))"))
        }
    }

    private func expect(_ value: JSONValue?, isString: Bool, field: String, issues: inout [FieldIssue]) -> Bool {
        guard let value else {
            issues.append(FieldIssue(field, "fehlt"))
            return false
        }
        guard value.stringValue != nil else {
            issues.append(FieldIssue(field, "muss Text sein, nicht \(value.typeName)"))
            return false
        }
        return true
    }

    private func expectBool(_ value: JSONValue, field: String, issues: inout [FieldIssue]) -> Bool {
        guard value.boolValue != nil else {
            issues.append(FieldIssue(field, "muss true oder false sein"))
            return false
        }
        return true
    }

    private func expectEnum(_ value: JSONValue?, _ allowed: [String], field: String, issues: inout [FieldIssue]) -> Bool {
        guard let text = value?.stringValue, allowed.contains(text) else {
            let shown = value.map { $0.stringValue.map { "„\($0)“" } ?? $0.typeName } ?? "fehlt"
            issues.append(FieldIssue(field, "\(shown) ist ungültig (erlaubt: \(allowed.joined(separator: ", ")))"))
            return false
        }
        return true
    }

    private func decodeRule(_ object: [String: JSONValue]) throws(AgentError) -> Rule {
        do {
            return try JSONValue.object(object).decode(Rule.self)
        } catch let error as DecodingError {
            throw .invalid([RuleInput.issue(from: error)])
        } catch {
            throw .badInput(error.localizedDescription)
        }
    }

    static func issue(from error: DecodingError) -> FieldIssue {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.reduce("") { result, key in
                if let index = key.intValue { return "\(result)[\(index)]" }
                return result.isEmpty ? key.stringValue : "\(result).\(key.stringValue)"
            }
        }
        switch error {
        case .keyNotFound(let key, let context):
            let base = path(context)
            return FieldIssue(base.isEmpty ? key.stringValue : "\(base).\(key.stringValue)", "fehlt")
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return FieldIssue(path(context), "ungültiger Wert (\(context.debugDescription))")
        @unknown default:
            return FieldIssue("", "ungültige Regel")
        }
    }

    // MARK: Validierung (§24.4)

    /// Fehler werfen, Warnungen zurückgeben.
    public func validate(_ rule: Rule) throws(AgentError) -> [String] {
        let (issues, warnings) = RuleValidator.check(rule, resolver: resolver)
        guard issues.isEmpty else { throw .invalid(issues) }
        return warnings
    }
}

/// Prüfungen vor dem Schreiben: Name, Regex, Aktion, Ziel-App.
public enum RuleValidator {
    public static func check(_ rule: Rule, resolver: any AppResolving) -> (errors: [FieldIssue], warnings: [String]) {
        var errors: [FieldIssue] = []
        var warnings: [String] = []

        if rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(FieldIssue("name", "darf nicht leer sein"))
        }
        for (index, condition) in rule.conditions.enumerated() {
            switch condition {
            case .url(let m), .host(let m), .path(let m):
                if m.op == .regex {
                    do {
                        _ = try NSRegularExpression(pattern: m.value, options: m.caseSensitive ? [] : [.caseInsensitive])
                    } catch {
                        errors.append(FieldIssue("conditions[\(index)].value", "ungültiger regulärer Ausdruck „\(m.value)“"))
                    }
                }
            case .sourceApp(let id, _):
                if id.trimmingCharacters(in: .whitespaces).isEmpty {
                    errors.append(FieldIssue("conditions[\(index)].bundleIdentifier", "darf nicht leer sein"))
                }
            case .modifiers, .linkType:
                break
            }
        }
        for (index, rewrite) in rule.rewrites.enumerated() {
            if let message = Rewriter.validationError(for: rewrite) {
                errors.append(FieldIssue("rewrites[\(index)].pattern", "ungültiger regulärer Ausdruck „\(rewrite.pattern)“ (\(message))"))
            }
        }
        func checkApp(_ app: AppRef, field: String) {
            if (app.bundleIdentifier ?? "").isEmpty, app.path.isEmpty {
                errors.append(FieldIssue(field, "braucht bundleIdentifier oder path"))
            } else if !resolver.isInstalled(app) {
                warnings.append("\(field): „\(app.displayName)“ ist auf diesem Mac nicht auffindbar (\(app.path.isEmpty ? app.bundleIdentifier ?? "" : app.path)).")
            }
        }
        switch rule.action {
        case .open(let app): checkApp(app, field: "action.app")
        case .openFirstRunning(let fallback?): checkApp(fallback, field: "action.fallback")
        case .openFirstRunning(nil), .prompt: break
        }
        if let text = rule.testURL?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
           URL(string: text)?.scheme == nil {
            warnings.append("testURL: „\(text)“ ist keine vollständige URL (mit Schema, z. B. https://…).")
        }
        return (errors, warnings)
    }
}

// MARK: - Operationen auf der Config

/// Reine Änderungen an `Config.rules` (Positionen 1-basiert).
public enum RuleEditing {
    /// Fügt ein; `position` nil = ans Ende. Gibt den Index zurück.
    @discardableResult
    public static func insert(_ rule: Rule, at position: Int?, into config: inout Config) throws(AgentError) -> Int {
        if config.rules.contains(where: { $0.id == rule.id }) {
            throw .invalid([FieldIssue("id", "existiert schon (\(rule.id.uuidString.lowercased()))")])
        }
        let index = (position ?? config.rules.count + 1) - 1
        guard (0...config.rules.count).contains(index) else {
            throw .usage("Position \(index + 1) außerhalb von 1…\(config.rules.count + 1).")
        }
        config.rules.insert(rule, at: index)
        return index
    }

    /// Verschiebt auf `position` (1…Anzahl). Gibt den neuen Index zurück.
    @discardableResult
    public static func move(from index: Int, to position: Int, in config: inout Config) throws(AgentError) -> Int {
        guard (1...max(config.rules.count, 1)).contains(position) else {
            throw .usage("Position \(position) außerhalb von 1…\(config.rules.count).")
        }
        let rule = config.rules.remove(at: index)
        config.rules.insert(rule, at: position - 1)
        return position - 1
    }
}

// MARK: - Liste in der App (§27 A10, A15)

/// Reine Hilfen für Löschen, Rückgängig und Auswahl im Tab „Regeln“.
public enum RuleListEditing {
    /// Auswahl nach dem Entfernen von `id` aus der sichtbaren Liste: der nächste sichtbare Eintrag,
    /// sonst der vorherige, sonst nil (§27 A10). Ist `id` nicht sichtbar, der erste sichtbare.
    public static func selection(afterRemoving id: UUID, visible: [UUID]) -> UUID? {
        guard let index = visible.firstIndex(of: id) else { return visible.first }
        if index + 1 < visible.count { return visible[index + 1] }
        return index > 0 ? visible[index - 1] : nil
    }

    /// Ordnet `rules` nach der ID-Reihenfolge `order`; Regeln, die dort fehlen (inzwischen angelegt),
    /// folgen in ihrer bisherigen Reihenfolge. Für „Umsortieren rückgängig“ (§27 A15).
    public static func reorder(_ rules: [Rule], to order: [UUID]) -> [Rule] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return rules.enumerated()
            .sorted { a, b in
                let ra = rank[a.element.id] ?? (order.count + a.offset)
                let rb = rank[b.element.id] ?? (order.count + b.offset)
                return ra < rb
            }
            .map(\.element)
    }

    /// Fügt `rule` wieder an `index` ein (begrenzt auf die Listenlänge), falls die ID fehlt.
    public static func reinsert(_ rule: Rule, at index: Int, into rules: inout [Rule]) {
        guard !rules.contains(where: { $0.id == rule.id }) else { return }
        rules.insert(rule, at: min(max(index, 0), rules.count))
    }
}

// MARK: - Kurzbeschreibungen (ohne App-Schicht)

/// Deutsche Kurztexte für Regeln und Aktionen (Kommandozeile, MCP).
public enum RuleDescriber {
    public static func action(_ action: Action) -> String {
        switch action {
        case .open(let app): "öffnen mit \(app.displayName)"
        case .openFirstRunning(let fallback):
            "erster laufender Browser, sonst \(fallback?.displayName ?? "erster der Liste")"
        case .prompt(.all): "Auswahl zeigen (alle)"
        case .prompt(.running): "Auswahl zeigen (laufende)"
        }
    }

    public static func condition(_ condition: Condition) -> String {
        func op(_ op: TextOp) -> String {
            switch op {
            case .equals: "ist"
            case .notEquals: "ist nicht"
            case .contains: "enthält"
            case .notContains: "enthält nicht"
            case .beginsWith: "beginnt mit"
            case .endsWith: "endet mit"
            case .wildcard: "passt auf Muster"
            case .regex: "passt auf Regex"
            }
        }
        switch condition {
        case .url(let m): return "URL \(op(m.op)) „\(m.value)“"
        case .host(let m): return "Host \(op(m.op)) „\(m.value)“"
        case .path(let m): return "Pfad \(op(m.op)) „\(m.value)“"
        case .sourceApp(let id, let negated): return "Quell-App \(negated ? "ist nicht" : "ist") \(id)"
        case .modifiers(let set, let negated):
            let names = set.names.isEmpty ? "keine" : set.names.joined(separator: "+")
            return "Modifier \(negated ? "nicht genau" : "genau") \(names)"
        case .linkType(let type): return "Linktyp \(type == .web ? "Web" : "Datei")"
        }
    }

    /// „Host ist „github.com“ · ↻ review.example.com → öffnen mit Chrome“.
    public static func summary(_ rule: Rule) -> String {
        let conditions: String
        switch rule.conditions.count {
        case 0: conditions = "immer"
        case 1: conditions = condition(rule.conditions[0])
        default:
            let mode = switch rule.match {
            case .all: "alle"
            case .any: "irgendeine"
            case .none: "keine"
            }
            conditions = "\(rule.conditions.count) Bedingungen (\(mode))"
        }
        let rewrite = rewriteChip(rule.rewrites).map { " · \($0)" } ?? ""
        return "\(conditions)\(rewrite) → \(action(rule.action))"
    }
}
