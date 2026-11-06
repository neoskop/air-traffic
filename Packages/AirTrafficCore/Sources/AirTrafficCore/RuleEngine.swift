import Foundation

/// Ergebnis von `RuleEngine.test` für eine einzelne Regel (§14.3).
public struct RuleTestResult: Sendable, Equatable {
    /// Bedingungen passen (unabhängig von `enabled`).
    public var matches: Bool
    /// Ergebnis je Bedingungszeile, gleiche Reihenfolge wie `rule.conditions`.
    public var conditionResults: [Bool]
    /// Zwischenergebnis nach jeder Umschreibung, gleiche Reihenfolge wie `rule.rewrites`.
    public var rewriteSteps: [String]
    /// URL nach allen Umschreibungen (ungültig → Original-URL, mit Warnung).
    public var finalURL: URL
    /// Ungültige Regex in Bedingungen/Umschreibungen, ungültige Ergebnis-URL.
    public var warnings: [String]
    /// Erste frühere aktivierte Regel, die für diese URL trifft; nil, wenn keine
    /// oder die Regel selbst nicht in der Config ist.
    public var shadowedBy: UUID?

    public init(
        matches: Bool,
        conditionResults: [Bool],
        rewriteSteps: [String],
        finalURL: URL,
        warnings: [String],
        shadowedBy: UUID?
    ) {
        self.matches = matches
        self.conditionResults = conditionResults
        self.rewriteSteps = rewriteSteps
        self.finalURL = finalURL
        self.warnings = warnings
        self.shadowedBy = shadowedBy
    }
}

/// Auswertung einer Regel gegen einen Link (§27 K3): gemeinsam für `decide`, `check` und `test`.
struct RuleEvaluation: Sendable, Equatable {
    /// Ergebnis je Bedingung in Regel-Reihenfolge; `nil` = nicht ausgewertet (Kurzschluss, Zeitlimit).
    var results: [Bool?]
    /// Bedingungen passen; bei Zeitlimit immer `false` (§26.3).
    var matches: Bool
    /// Ein regulärer Ausdruck hat das Zeitbudget überschritten.
    var timedOut: Bool
    /// Meldungen je Bedingung (Index in `rule.conditions`, Text ohne Präfix).
    var problems: [(index: Int, message: String)]

    static func == (a: RuleEvaluation, b: RuleEvaluation) -> Bool {
        a.results == b.results && a.matches == b.matches && a.timedOut == b.timedOut
            && a.problems.map(\.index) == b.problems.map(\.index) && a.problems.map(\.message) == b.problems.map(\.message)
    }

    /// Erste ausgewertete, nicht erfüllte Bedingung (Index in Regel-Reihenfolge).
    var firstFailed: Int? { results.firstIndex { $0 == false } }
}

/// Einmal je Link berechnete Vergleichstexte (statt je Bedingung).
struct MatchSubject {
    let url: URL
    let absolute: String
    /// Host in ASCII- (Punycode) und, falls abweichend, Unicode-Form (§27 A4).
    let hosts: [String]
    let path: String

    init(_ url: URL) {
        self.url = url
        absolute = url.absoluteString
        hosts = HostName.forms(url.host(percentEncoded: false) ?? "")
        path = url.path(percentEncoded: false)
    }
}

/// Reine, testbare Entscheidungslogik: erste aktivierte, passende Regel → Rewrites → Aktion.
///
/// Laufzeit-Schutz (§26.3): URLs über `MatchLimits.maxURLLength` werden nicht geprüft; reguläre
/// Ausdrücke teilen sich je Link ein Zeitbudget. Wartende Änderungen von außen (§26.1) gelten nicht:
/// ausgewertet wird `Rule.effective`.
///
/// Auswertung (§27 K2): billige Bedingungen (Quell-App, Modifier, Linktyp, Textvergleiche) vor
/// Platzhaltern und regulären Ausdrücken; „alle“ bricht beim ersten `false` ab, „eine“ und „keine“
/// beim ersten `true`. Zeitlimit = trifft nicht.
public enum RuleEngine {
    public static func decide(url: URL, context: LinkContext, config: Config) -> Decision {
        decideTracking(url: url, context: context, config: config, budget: MatchBudget()).decision
    }

    /// `decide` mit den Auswertungen der dabei geprüften Regeln (Index in `config.rules`).
    static func decideTracking(
        url: URL, context: LinkContext, config: Config, budget: MatchBudget
    ) -> (decision: Decision, evaluations: [Int: RuleEvaluation]) {
        if MatchLimits.isTooLong(url) {
            return (Decision(
                originalURL: url, finalURL: url, matchedRuleID: nil,
                action: .prompt(.all), warnings: [MatchLimits.tooLongWarning]
            ), [:])
        }
        let subject = MatchSubject(url)
        var warnings: [String] = []
        var evaluations: [Int: RuleEvaluation] = [:]

        for (index, stored) in config.rules.enumerated() {
            guard let rule = stored.effective, rule.enabled else { continue }
            let evaluation = evaluateRule(rule, subject: subject, context: context, budget: budget)
            evaluations[index] = evaluation
            warnings += evaluation.problems.map { "Regel „\(rule.name)“: \($0.message)" }
            guard evaluation.matches else { continue }
            let rewritten = Rewriter.apply(rule.rewrites, to: url, budget: budget)
            warnings += rewritten.warnings.map { "Regel „\(rule.name)“: \($0)" }
            return (Decision(
                originalURL: url,
                finalURL: rewritten.url,
                matchedRuleID: rule.id,
                action: rule.action,
                warnings: warnings
            ), evaluations)
        }

        return (Decision(
            originalURL: url,
            finalURL: url,
            matchedRuleID: nil,
            action: config.defaultAction,
            warnings: warnings
        ), evaluations)
    }

    /// Testet eine einzelne Regel für den Abschnitt „Test“ im Regel-Editor (§14.3).
    /// Wertet `rule` unabhängig von `enabled` und einer wartenden Freigabe aus (Vorschau des Stands
    /// im Editor). `rewriteSteps` und `finalURL` zeigen, was die Umschreibungen ergeben – unabhängig
    /// davon, ob die Bedingungen passen.
    ///
    /// `matches` folgt derselben Auswertung wie `decide` (Kurzschluss, Zeitlimit = trifft nicht);
    /// Bedingungen, die der Kurzschluss übersprungen hat, werden nur für die Anzeige nachgeholt.
    public static func test(rule: Rule, url: URL, context: LinkContext, config: Config) -> RuleTestResult {
        let budget = MatchBudget()
        let subject = MatchSubject(url)
        let evaluation = evaluateRule(rule, subject: subject, context: context, budget: budget)

        // Erste frühere aktivierte Regel, die trifft (wie `decide` mit voller Config).
        var shadowedBy: UUID?
        if let ownIndex = config.rules.firstIndex(where: { $0.id == rule.id }) {
            shadowedBy = config.rules[..<ownIndex].first { stored in
                guard let earlier = stored.effective, earlier.enabled else { return false }
                return evaluateRule(earlier, subject: subject, context: context, budget: budget).matches
            }?.id
        }

        // Anzeige: übersprungene Bedingungen nachholen (ändert `matches` nicht).
        var problems = evaluation.problems
        let conditionResults = rule.conditions.enumerated().map { index, condition in
            if let known = evaluation.results[index] { return known }
            var message: String?
            let result = evaluate(condition, subject: subject, context: context, error: &message, budget: budget)
            if let message { problems.append((index, message)) }
            return result
        }
        var warnings = problems.sorted { $0.index < $1.index }.map { "Bedingung \($0.index + 1): \($0.message)" }

        // Zwischenergebnisse aus demselben Lauf wie das Endergebnis (§27 K10).
        let rewritten = Rewriter.run(rule.rewrites, on: url, budget: budget, collectSteps: true)
        warnings += rewritten.output.warnings
        warnings += rewritten.output.notes

        return RuleTestResult(
            matches: evaluation.matches,
            conditionResults: conditionResults,
            rewriteSteps: rewritten.steps,
            finalURL: rewritten.output.url,
            warnings: warnings,
            shadowedBy: shadowedBy
        )
    }

    /// Prüft, ob die Bedingungen einer Regel passen (ignoriert `enabled`).
    public static func matches(rule: Rule, url: URL, context: LinkContext) -> Bool {
        evaluateRule(rule, subject: MatchSubject(url), context: context, budget: MatchBudget()).matches
    }

    /// Wie `matches(rule:url:context:)`, mit Warnungen und vorgegebenem Budget.
    static func matches(
        rule: Rule, url: URL, context: LinkContext, warnings: inout [String], budget: MatchBudget?
    ) -> Bool {
        let evaluation = evaluateRule(rule, url: url, context: context, budget: budget)
        warnings += evaluation.problems.map { "Regel „\(rule.name)“: \($0.message)" }
        return evaluation.matches
    }

    /// Gemeinsame Auswertung (§27 K2, K3).
    static func evaluateRule(_ rule: Rule, url: URL, context: LinkContext, budget: MatchBudget?) -> RuleEvaluation {
        evaluateRule(rule, subject: MatchSubject(url), context: context, budget: budget)
    }

    static func evaluateRule(
        _ rule: Rule, subject: MatchSubject, context: LinkContext, budget: MatchBudget?
    ) -> RuleEvaluation {
        var results = [Bool?](repeating: nil, count: rule.conditions.count)
        var problems: [(index: Int, message: String)] = []
        if rule.conditions.isEmpty {
            return RuleEvaluation(results: [], matches: true, timedOut: false, problems: [])
        }
        // Stabile Sortierung nach Kosten: gleich teure Bedingungen in Regel-Reihenfolge.
        let order = rule.conditions.indices.sorted { a, b in
            let ca = cost(rule.conditions[a]), cb = cost(rule.conditions[b])
            return ca == cb ? a < b : ca < cb
        }
        for index in order {
            var message: String?
            let result = evaluate(rule.conditions[index], subject: subject, context: context, error: &message, budget: budget)
            if let message {
                problems.append((index, message))
                if message == TextMatcher.timeoutMessage {
                    return RuleEvaluation(results: results, matches: false, timedOut: true, problems: problems)
                }
            }
            results[index] = result
            switch rule.match {
            case .all where !result, .any where result, .none where result:
                return RuleEvaluation(results: results, matches: rule.match == .any, timedOut: false, problems: problems)
            default:
                continue
            }
        }
        // Alle ausgewertet ohne Abbruch: „alle“ → alle wahr, „eine“ → keine wahr, „keine“ → keine wahr.
        return RuleEvaluation(results: results, matches: rule.match != .any, timedOut: false, problems: problems)
    }

    /// Grobe Kosten einer Bedingung für die Auswertungsreihenfolge.
    static func cost(_ condition: Condition) -> Int {
        switch condition {
        case .sourceApp, .modifiers, .linkType: 0
        case .host(let m): textCost(m, base: 1)
        case .path(let m), .url(let m): textCost(m, base: 2)
        }
    }

    private static func textCost(_ m: TextMatch, base: Int) -> Int {
        switch m.op {
        case .wildcard: 3
        case .regex: 4
        default: base
        }
    }

    /// Verknüpft Bedingungsergebnisse nach Match-Modus; leer = passt immer.
    static func combine(_ results: [Bool], mode: MatchMode) -> Bool {
        if results.isEmpty { return true }
        switch mode {
        case .all: return results.allSatisfy { $0 }
        case .any: return results.contains(true)
        case .none: return !results.contains(true)
        }
    }

    public static func evaluate(_ condition: Condition, url: URL, context: LinkContext) -> Bool {
        var ignored: String?
        return evaluate(condition, subject: MatchSubject(url), context: context, error: &ignored, budget: MatchBudget())
    }

    static func evaluate(
        _ condition: Condition, url: URL, context: LinkContext, error: inout String?, budget: MatchBudget?
    ) -> Bool {
        evaluate(condition, subject: MatchSubject(url), context: context, error: &error, budget: budget)
    }

    static func evaluate(
        _ condition: Condition, subject: MatchSubject, context: LinkContext, error: inout String?, budget: MatchBudget?
    ) -> Bool {
        switch condition {
        case .url(let m):
            return TextMatcher.matches(m, subject.absolute, problem: &error, budget: budget)
        case .host(let m):
            return TextMatcher.matches(m, anyOf: subject.hosts, problem: &error, budget: budget)
        case .path(let m):
            return TextMatcher.matches(m, subject.path, problem: &error, budget: budget)
        case .sourceApp(let bundleIdentifier, let negated):
            let isSource = context.sourceBundleIdentifier.map {
                $0.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
            } ?? false
            return isSource != negated
        case .modifiers(let set, let negated):
            return (context.modifiers == set) != negated
        case .linkType(let type):
            return (subject.url.isFileURL ? LinkType.file : .web) == type
        }
    }
}

/// Textvergleiche für `TextMatch`.
public enum TextMatcher {
    static let timeoutMessage = "Zeitlimit überschritten"

    public static func matches(_ m: TextMatch, _ subject: String) -> Bool {
        var ignored: String?
        return matches(m, subject, problem: &ignored, budget: MatchBudget())
    }

    static func matches(_ m: TextMatch, _ subject: String, problem: inout String?, budget: MatchBudget?) -> Bool {
        let options: String.CompareOptions = m.caseSensitive ? [] : [.caseInsensitive]
        switch m.op {
        case .equals:
            return equal(subject, m.value, caseSensitive: m.caseSensitive)
        case .notEquals:
            return !equal(subject, m.value, caseSensitive: m.caseSensitive)
        case .contains:
            return contains(subject, m.value, options: options)
        case .notContains:
            return !contains(subject, m.value, options: options)
        case .beginsWith:
            return m.value.isEmpty || subject.range(of: m.value, options: options.union(.anchored)) != nil
        case .endsWith:
            return m.value.isEmpty
                || subject.range(of: m.value, options: options.union([.anchored, .backwards])) != nil
        case .wildcard:
            // Ohne Regex: linear, ohne Backtracking-Explosion (§26.3).
            return WildcardPattern(m.value, caseSensitive: m.caseSensitive).matches(subject)
        case .regex:
            let regex: NSRegularExpression
            do {
                regex = try RegexCache.regex(m.value, options: m.caseSensitive ? [] : [.caseInsensitive])
            } catch {
                problem = "ungültiger regulärer Ausdruck „\(m.value)“"
                return false
            }
            do {
                return try regex.firstMatch(in: subject, budget: budget) != nil
            } catch {
                problem = timeoutMessage
                return false
            }
        }
    }

    /// Mehrere gleichwertige Formen desselben Texts (Host in Punycode und Unicode, §27 A4):
    /// positive Vergleiche treffen, wenn eine Form trifft; „ist nicht“/„enthält nicht“ nur, wenn keine trifft.
    static func matches(_ m: TextMatch, anyOf subjects: [String], problem: inout String?, budget: MatchBudget?) -> Bool {
        guard subjects.count > 1 else { return matches(m, subjects.first ?? "", problem: &problem, budget: budget) }
        var positive = m
        let negated: Bool
        switch m.op {
        case .notEquals: positive.op = .equals; negated = true
        case .notContains: positive.op = .contains; negated = true
        default: negated = false
        }
        var found = false
        for subject in subjects {
            if matches(positive, subject, problem: &problem, budget: budget) { found = true; break }
            if problem == timeoutMessage { return false }
        }
        return found != negated
    }

    private static func equal(_ a: String, _ b: String, caseSensitive: Bool) -> Bool {
        caseSensitive ? a == b : a.compare(b, options: .caseInsensitive) == .orderedSame
    }

    private static func contains(_ subject: String, _ needle: String, options: String.CompareOptions) -> Bool {
        needle.isEmpty || subject.range(of: needle, options: options) != nil
    }

    /// Bisherige Umsetzung von `wildcard` als regulärer Ausdruck (`*` → `.*`, `?` → `.`, ganzer String).
    /// Nur noch Referenz für Äquivalenztests; der Abgleich nutzt `WildcardPattern`.
    public static func wildcardRegex(_ pattern: String, caseSensitive: Bool) throws -> NSRegularExpression {
        var regex = "^"
        var escaping = false
        for ch in pattern {
            if escaping {
                regex += NSRegularExpression.escapedPattern(for: String(ch))
                escaping = false
                continue
            }
            switch ch {
            case "\\": escaping = true
            case "*": regex += ".*"
            case "?": regex += "."
            default: regex += NSRegularExpression.escapedPattern(for: String(ch))
            }
        }
        if escaping { regex += NSRegularExpression.escapedPattern(for: "\\") }
        regex += "$"
        var options: NSRegularExpression.Options = [.dotMatchesLineSeparators]
        if !caseSensitive { options.insert(.caseInsensitive) }
        return try NSRegularExpression(pattern: regex, options: options)
    }
}
