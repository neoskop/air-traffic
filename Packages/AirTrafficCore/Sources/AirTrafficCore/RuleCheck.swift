import Foundation

/// URL-Prüfung im Tab „Regeln“ (SPEC §22): welche Regeln treffen, welche greift, was passiert.
public enum RuleCheck {
    /// Erkennt eine vollständige URL im Suchfeld (§22.1). Eingabe wird getrimmt.
    ///
    /// Gültig: keine Leerzeichen, `URL(string:)` gültig, Schema vorhanden und entweder
    /// `http`/`https` mit Host, `file`, oder ein beliebiges Schema mit `://` und Host.
    /// Ohne Schema (`github.com/acme`) → nil, bleibt Textsuche.
    public static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), !scheme.isEmpty
        else { return nil }
        let host = url.host(percentEncoded: false) ?? ""
        switch scheme {
        case "http", "https":
            return host.isEmpty ? nil : url
        case "file":
            return url.path(percentEncoded: false).isEmpty ? nil : url
        default:
            return trimmed.contains("://") && !host.isEmpty ? url : nil
        }
    }
}

/// Status einer Regel für die geprüfte URL (§22.3, §22.5).
public enum RuleCheckStatus: Sendable, Equatable {
    /// Erste aktivierte, passende Regel – greift bei einem echten Klick.
    case wins
    /// Aktiviert und passend, aber eine frühere Regel greift zuerst.
    case shadowed(by: UUID)
    /// Passt, ist aber deaktiviert.
    case disabledMatch
    /// Neu von außen angelegt, passt, wartet aber auf Freigabe in der App (§26.1) – greift nicht.
    case pendingMatch
    /// Bedingungen passen nicht.
    case noMatch
}

/// Eine Regel im Prüfergebnis, in Config-Reihenfolge.
public struct RuleCheckEntry: Sendable, Equatable {
    public var ruleID: UUID
    /// Position in der Gesamtliste, 1-basiert.
    public var position: Int
    /// Bedingungen passen (unabhängig von `enabled`).
    public var matches: Bool
    /// Index (0-basiert) der nicht erfüllten Bedingung, an der die Auswertung abbrach (billige
    /// Bedingungen zuerst, §27 K2); nur bei MatchMode „alle“ und nicht passender Regel, sonst nil.
    public var firstFailedCondition: Int?
    public var status: RuleCheckStatus

    public init(ruleID: UUID, position: Int, matches: Bool, firstFailedCondition: Int?, status: RuleCheckStatus) {
        self.ruleID = ruleID
        self.position = position
        self.matches = matches
        self.firstFailedCondition = firstFailedCondition
        self.status = status
    }
}

/// Ergebnis von `RuleEngine.check`.
public struct RuleCheckResult: Sendable, Equatable {
    /// Identisch zu `RuleEngine.decide` für dieselbe URL und denselben Kontext.
    public var decision: Decision
    /// Alle Regeln in Config-Reihenfolge.
    public var entries: [RuleCheckEntry]

    /// Anzahl passender Regeln (auch deaktivierte).
    public var matchCount: Int { entries.count(where: \.matches) }

    public init(decision: Decision, entries: [RuleCheckEntry]) {
        self.decision = decision
        self.entries = entries
    }
}

extension RuleEngine {
    /// Prüft eine URL gegen alle Regeln (§22.5). Rein; ändert nichts.
    ///
    /// Wartende Änderungen (§26.1) zählen nicht: geänderte Regeln werden im wirksamen Stand
    /// geprüft, neu angelegte stehen als `pendingMatch` bzw. `noMatch` da.
    ///
    /// Ein Zeitbudget für alles (§27 K3): zuerst genau der Lauf von `decide` (dessen Auswertungen
    /// wiederverwendet werden), danach mit dem Rest des Budgets die übrigen Regeln. Zeitlimit = trifft nicht.
    public static func check(url: URL, context: LinkContext, config: Config) -> RuleCheckResult {
        let budget = MatchBudget()
        let tooLong = MatchLimits.isTooLong(url)
        let (decision, known) = decideTracking(url: url, context: context, config: config, budget: budget)
        let winner = decision.matchedRuleID
        let subject = tooLong ? nil : MatchSubject(url)

        let entries = config.rules.enumerated().map { index, stored in
            let rule = stored.effective ?? stored
            let matches: Bool
            let firstFailed: Int?
            if let subject {
                let evaluation = known[index] ?? evaluateRule(rule, subject: subject, context: context, budget: budget)
                matches = evaluation.matches
                firstFailed = !matches && rule.match == .all ? evaluation.firstFailed : nil
            } else {
                matches = false
                firstFailed = rule.match == .all && !rule.conditions.isEmpty ? 0 : nil
            }
            let status: RuleCheckStatus = if !matches {
                .noMatch
            } else if stored.effective == nil {
                .pendingMatch
            } else if !rule.enabled {
                .disabledMatch
            } else if rule.id == winner {
                .wins
            } else if let winner {
                .shadowed(by: winner)
            } else {
                // Kann nicht eintreten: eine aktivierte passende Regel ist immer `decide`s Treffer
                // oder liegt hinter ihm. Sicherheitshalber als Gewinner werten.
                .wins
            }
            return RuleCheckEntry(
                ruleID: rule.id,
                position: index + 1,
                matches: matches,
                firstFailedCondition: firstFailed,
                status: status
            )
        }
        return RuleCheckResult(decision: decision, entries: entries)
    }
}
