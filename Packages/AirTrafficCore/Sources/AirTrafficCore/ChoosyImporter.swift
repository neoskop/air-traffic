import AirTrafficCoreObjC
import Foundation

public struct ImportNote: Sendable, Equatable, Identifiable {
    public var id = UUID()
    /// Betroffene Regel (falls regelbezogen).
    public var ruleID: UUID?
    public var ruleName: String?
    public var message: String

    public init(ruleID: UUID? = nil, ruleName: String? = nil, message: String) {
        self.ruleID = ruleID
        self.ruleName = ruleName
        self.message = message
    }

    public static func == (a: ImportNote, b: ImportNote) -> Bool {
        a.ruleID == b.ruleID && a.ruleName == b.ruleName && a.message == b.message
    }
}

public struct ImportResult: Sendable, Equatable {
    public var config: Config
    public var report: [ImportNote]

    /// Regeln, die beim Import deaktiviert und markiert wurden.
    public var rulesNeedingReview: [Rule] {
        config.rules.filter { $0.name.hasSuffix(ChoosyImporter.reviewSuffix) }
    }
}

/// Importiert Choosy-Regeln (`behaviours.plist`) und -Browser (Preferences-Plist).
public enum ChoosyImporter {
    public static let reviewSuffix = " (prüfen)"
    /// Choosy-Verhalten „bestimmte App öffnen“.
    static let openAppBehaviour = 6

    public enum ImportError: Error, LocalizedError {
        case unreadable(URL, String)
        case unexpectedFormat(URL, String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let url, let reason):
                "\(url.lastPathComponent) konnte nicht gelesen werden: \(reason)"
            case .unexpectedFormat(let url, let expected):
                "\(url.lastPathComponent) hat ein unerwartetes Format (erwartet: \(expected))."
            }
        }
    }

    public static var defaultBehavioursURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: "Library/Application Support/Choosy/behaviours.plist")
    }

    public static var defaultPreferencesURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: "Library/Preferences/com.choosyosx.Choosy.plist")
    }

    /// Ob unter den Standardpfaden Choosy-Dateien liegen (prüft nur die Existenz).
    public static func choosyFilesExist(
        behavioursURL: URL = defaultBehavioursURL,
        preferencesURL: URL = defaultPreferencesURL
    ) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: behavioursURL.path(percentEncoded: false))
            || fm.fileExists(atPath: preferencesURL.path(percentEncoded: false))
    }

    /// Liest beide Dateien; fehlende Dateien ergeben einen Hinweis statt eines Fehlers.
    public static func importConfig(
        behavioursURL: URL,
        preferencesURL: URL,
        bundleIdentifierForPath: (String) -> String? = { Bundle(path: $0)?.bundleIdentifier }
    ) throws -> ImportResult {
        var report: [ImportNote] = []
        let fm = FileManager.default

        var behaviours: [[String: Any]] = []
        if fm.fileExists(atPath: behavioursURL.path(percentEncoded: false)) {
            guard let array = try readPlist(behavioursURL) as? [[String: Any]] else {
                throw ImportError.unexpectedFormat(behavioursURL, "Array von Dictionaries")
            }
            behaviours = array
        } else {
            report.append(ImportNote(message: "Keine Regeldatei gefunden (\(behavioursURL.lastPathComponent))."))
        }

        var browserPaths: [String] = []
        if fm.fileExists(atPath: preferencesURL.path(percentEncoded: false)) {
            guard let prefs = try readPlist(preferencesURL) as? [String: Any] else {
                throw ImportError.unexpectedFormat(preferencesURL, "Dictionary")
            }
            browserPaths = browserPathsFromPreferences(prefs)
            if browserPaths.isEmpty {
                report.append(ImportNote(message: "Keine Browserliste in den Choosy-Einstellungen gefunden."))
            }
        } else {
            report.append(ImportNote(message: "Keine Choosy-Einstellungen gefunden (\(preferencesURL.lastPathComponent))."))
        }

        var result = importConfig(
            behaviours: behaviours,
            browserPaths: browserPaths,
            bundleIdentifierForPath: bundleIdentifierForPath
        )
        result.report.insert(contentsOf: report, at: 0)
        return result
    }

    /// Kern der Abbildung, ohne Dateizugriff.
    public static func importConfig(
        behaviours: [[String: Any]],
        browserPaths: [String],
        bundleIdentifierForPath: (String) -> String? = { Bundle(path: $0)?.bundleIdentifier }
    ) -> ImportResult {
        var report: [ImportNote] = []
        var rules: [Rule] = []
        var defaultAction: Action = .prompt(.all)

        func appRef(_ path: String) -> AppRef {
            AppRef(path: path, bundleIdentifier: bundleIdentifierForPath(path))
        }

        for (index, entry) in behaviours.enumerated() {
            let title = (entry["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Choosy-Regel \(index + 1)"
            let enabled = (entry["enabled"] as? Bool) ?? (entry["enabled"] as? NSNumber)?.boolValue ?? true
            let predicateFormat = (entry["predicate"] as? String) ?? ""
            let id = UUID()

            // Aktion
            var notes: [String] = []
            let behaviour = (entry["behaviour"] as? Int) ?? (entry["behaviour"] as? NSNumber)?.intValue
            let argument = entry["behaviourArgument"] as? [String: Any]
            let action: Action
            if behaviour == openAppBehaviour, let path = argument?["path"] as? String, !path.isEmpty {
                action = .open(appRef(path))
            } else {
                action = .prompt(.all)
                let code = behaviour.map(String.init) ?? "fehlt"
                notes.append(behaviour == openAppBehaviour
                    ? "Verhalten 6 ohne App-Pfad, als Auswahl importiert"
                    : "Verhalten \(code) nicht bekannt, als Auswahl importiert")
            }

            // Bedingungen
            let parsed = parsePredicate(predicateFormat)
            switch parsed {
            case .always:
                if index == behaviours.count - 1, !enabled {
                    // Deaktiviert in Choosy: nicht zur Standardaktion machen (§27 K6).
                    rules.append(Rule(id: id, name: title, enabled: false, match: .all, conditions: [], action: action))
                    notes.insert("TRUEPREDICATE als letzte Regel ist in Choosy deaktiviert – als deaktivierte Regel ohne Bedingungen importiert, nicht als Standardaktion", at: 0)
                } else if index == behaviours.count - 1 {
                    defaultAction = action
                    let suffix = notes.isEmpty ? "" : " (\(notes.joined(separator: "; ")))"
                    report.append(ImportNote(
                        ruleName: title,
                        message: "TRUEPREDICATE als letzte Regel → Standardaktion\(suffix)."
                    ))
                    continue
                } else {
                    rules.append(Rule(id: id, name: title, enabled: enabled, match: .all, conditions: [], action: action))
                }
            case .conditions(let mode, let conditions):
                rules.append(Rule(id: id, name: title, enabled: enabled, match: mode, conditions: conditions, action: action))
            case .unsupported(let reason):
                let name = title + reviewSuffix
                rules.append(Rule(id: id, name: name, enabled: false, match: .all, conditions: [], action: action))
                notes.insert("\(reason) – deaktiviert importiert. Original-Prädikat: \(predicateFormat)", at: 0)
            }
            for note in notes {
                report.append(ImportNote(ruleID: id, ruleName: rules.last?.name ?? title, message: note))
            }
        }

        var browsers: [AppRef] = []
        for path in browserPaths where !browsers.contains(where: { $0.path == path }) {
            browsers.append(appRef(path))
        }

        return ImportResult(
            config: Config(browsers: browsers, rules: rules, defaultAction: defaultAction),
            report: report
        )
    }

    static func browserPathsFromPreferences(_ prefs: [String: Any]) -> [String] {
        guard let list = prefs["browsers"] as? [Any] else { return [] }
        return list.compactMap { item in
            if let dict = item as? [String: Any] { return dict["path"] as? String }
            return nil
        }
    }

    private static func readPlist(_ url: URL) throws -> Any {
        do {
            let data = try Data(contentsOf: url)
            return try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            throw ImportError.unreadable(url, error.localizedDescription)
        }
    }

    // MARK: - Prädikate

    public enum ParsedPredicate: Equatable, Sendable {
        case always
        case conditions(MatchMode, [Condition])
        case unsupported(String)
    }

    /// Parst einen Choosy-Prädikat-String per `NSPredicate(format:)` und bildet ihn auf eine Ebene ab.
    public static func parsePredicate(_ format: String) -> ParsedPredicate {
        let trimmed = format.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unsupported("Leeres Prädikat") }
        var message: NSString?
        guard let predicate = ATParsePredicate(trimmed, &message) else {
            return .unsupported("Prädikat nicht lesbar (\(message.map(String.init) ?? "Parse-Fehler"))")
        }
        do {
            return try flatten(predicate)
        } catch let failure as Unsupported {
            return .unsupported(failure.reason)
        } catch {
            return .unsupported("\(error)")
        }
    }

    struct Unsupported: Error { var reason: String }

    private static func isTrue(_ p: NSPredicate) -> Bool { p.predicateFormat == "TRUEPREDICATE" }
    private static func isFalse(_ p: NSPredicate) -> Bool { p.predicateFormat == "FALSEPREDICATE" }

    private static func flatten(_ predicate: NSPredicate) throws -> ParsedPredicate {
        if isTrue(predicate) { return .always }
        if isFalse(predicate) { throw Unsupported(reason: "FALSEPREDICATE wird nicht unterstützt") }
        if let comparison = predicate as? NSComparisonPredicate {
            return .conditions(.all, [try condition(comparison)])
        }
        guard let compound = predicate as? NSCompoundPredicate else {
            throw Unsupported(reason: "Unbekannter Prädikat-Typ")
        }
        let subs = compound.subpredicates.compactMap { $0 as? NSPredicate }
        switch compound.compoundPredicateType {
        case .and:
            if subs.count == 1 { return try flatten(subs[0]) }
            return .conditions(.all, try subs.flatMap { try conjunctionTerms($0) })
        case .or:
            if subs.count == 1 { return try flatten(subs[0]) }
            return .conditions(.any, try subs.flatMap { try disjunctionTerms($0) })
        case .not:
            guard subs.count == 1 else { throw Unsupported(reason: "NOT mit mehreren Operanden") }
            return try negate(subs[0])
        @unknown default:
            throw Unsupported(reason: "Unbekannter Verknüpfungstyp")
        }
    }

    /// Bedingungen, die per UND verknüpft werden können.
    private static func conjunctionTerms(_ p: NSPredicate) throws -> [Condition] {
        if let c = p as? NSComparisonPredicate { return [try condition(c)] }
        if let compound = p as? NSCompoundPredicate {
            let subs = compound.subpredicates.compactMap { $0 as? NSPredicate }
            switch compound.compoundPredicateType {
            case .and: return try subs.flatMap { try conjunctionTerms($0) }
            case .or where subs.count == 1: return try conjunctionTerms(subs[0])
            case .not where subs.count == 1:
                if let c = subs[0] as? NSComparisonPredicate, let negated = negatedCondition(try condition(c)) {
                    return [negated]
                }
            default: break
            }
        }
        throw Unsupported(reason: "Verschachtelte Mischform (UND/ODER/NICHT) nicht auf eine Ebene abbildbar")
    }

    /// Bedingungen, die per ODER verknüpft werden können.
    private static func disjunctionTerms(_ p: NSPredicate) throws -> [Condition] {
        if let c = p as? NSComparisonPredicate { return [try condition(c)] }
        if let compound = p as? NSCompoundPredicate {
            let subs = compound.subpredicates.compactMap { $0 as? NSPredicate }
            switch compound.compoundPredicateType {
            case .or: return try subs.flatMap { try disjunctionTerms($0) }
            case .and where subs.count == 1: return try disjunctionTerms(subs[0])
            case .not where subs.count == 1:
                if let c = subs[0] as? NSComparisonPredicate, let negated = negatedCondition(try condition(c)) {
                    return [negated]
                }
            default: break
            }
        }
        throw Unsupported(reason: "Verschachtelte Mischform (UND/ODER/NICHT) nicht auf eine Ebene abbildbar")
    }

    /// NOT(x): NOT(a) / NOT(a OR b) → „keine“; NOT(NOT x) → x; NOT(a AND b) → „irgendeine“ mit negierten Ops.
    private static func negate(_ p: NSPredicate) throws -> ParsedPredicate {
        if let c = p as? NSComparisonPredicate { return .conditions(.none, [try condition(c)]) }
        if let compound = p as? NSCompoundPredicate {
            let subs = compound.subpredicates.compactMap { $0 as? NSPredicate }
            switch compound.compoundPredicateType {
            case .not where subs.count == 1:
                return try flatten(subs[0])
            case .or:
                return .conditions(.none, try subs.flatMap { try disjunctionTerms($0) })
            case .and:
                let terms = try subs.flatMap { try conjunctionTerms($0) }
                let negated = terms.compactMap(negatedCondition)
                if negated.count == terms.count { return .conditions(.any, negated) }
            default: break
            }
        }
        throw Unsupported(reason: "Verschachtelte Mischform (UND/ODER/NICHT) nicht auf eine Ebene abbildbar")
    }

    private static func negatedCondition(_ c: Condition) -> Condition? {
        guard case .url(var m) = c else { return nil }
        switch m.op {
        case .equals: m.op = .notEquals
        case .notEquals: m.op = .equals
        case .contains: m.op = .notContains
        case .notContains: m.op = .contains
        default: return nil
        }
        return .url(m)
    }

    private static func condition(_ p: NSComparisonPredicate) throws -> Condition {
        guard p.comparisonPredicateModifier == .direct else {
            throw Unsupported(reason: "ANY/ALL-Vergleiche werden nicht unterstützt")
        }
        let left = p.leftExpression
        guard left.expressionType == .keyPath else {
            throw Unsupported(reason: "Linke Seite ist kein Feld")
        }
        let keyPath = left.keyPath
        guard keyPath.caseInsensitiveCompare("URL") == .orderedSame else {
            throw Unsupported(reason: "Feld „\(keyPath)“ nicht unterstützt")
        }
        guard p.rightExpression.expressionType == .constantValue,
              let value = p.rightExpression.constantValue as? String
        else {
            throw Unsupported(reason: "Vergleichswert ist kein Text")
        }
        let op: TextOp
        switch p.predicateOperatorType {
        case .contains: op = .contains
        case .beginsWith: op = .beginsWith
        case .endsWith: op = .endsWith
        case .equalTo: op = .equals
        case .notEqualTo: op = .notEquals
        case .like: op = .wildcard
        case .matches:
            // NSPredicate MATCHES prüft den ganzen String, `.regex` sucht irgendwo → verankern.
            return .url(TextMatch(op: .regex, value: "^(?:\(value))$", caseSensitive: false))
        default:
            throw Unsupported(reason: "Operator „\(p.predicateFormat)“ nicht unterstützt")
        }
        // Choosy vergleicht praktisch immer ohne Groß/klein-Unterscheidung (SPEC §9).
        return .url(TextMatch(op: op, value: value, caseSensitive: false))
    }
}
