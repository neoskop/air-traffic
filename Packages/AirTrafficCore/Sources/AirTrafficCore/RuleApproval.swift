import Foundation

// MARK: - Freigabe riskanter Änderungen von außen

/// Änderungen über CLI/MCP an Umschreibungen oder Aktion wirken erst nach Freigabe in der App.
/// Agenten können nicht freigeben: dafür gibt es weder Befehl noch Tool.
public enum RuleApproval {
    /// Text für Antworten von create/update.
    public static let waitingText = "wartet auf Freigabe in Air Traffic"

    /// Regel nach einer Agenten-Änderung: `old` = Stand davor (nil = neu angelegt), `new` = Ergebnis.
    ///
    /// - Neu angelegt → wartet immer (jede Regel hat eine Aktion), `previous` = nil.
    /// - Geändert, Umschreibungen oder Aktion weichen vom zuletzt freigegebenen Stand ab → wartet,
    ///   `previous` = zuletzt freigegebener Stand (bei erneuter Änderung einer wartenden Regel unverändert).
    /// - Sonst (z. B. Name, Bedingungen, Test-URL, an/aus) → sofort wirksam; eine wartende Regel, deren
    ///   Umschreibungen und Aktion wieder dem freigegebenen Stand entsprechen, wartet nicht mehr.
    public static func gate(old: Rule?, new: Rule, now: Date) -> Rule {
        var result = new
        guard let old else {
            result.pendingChange = PendingChange(since: now, reason: "neu angelegt von außen (CLI/MCP)", previous: nil)
            return result
        }
        if let pending = old.pendingChange {
            guard let approved = pending.previous else {
                // Neu angelegt und noch nicht freigegeben: bleibt neu.
                result.pendingChange = PendingChange(since: pending.since, reason: pending.reason, previous: nil)
                return result
            }
            if let reason = riskyChange(from: approved, to: new) {
                result.pendingChange = PendingChange(since: pending.since, reason: reason, previous: approved)
            } else {
                result.pendingChange = nil
            }
            return result
        }
        if let reason = riskyChange(from: old, to: new) {
            var approved = old
            approved.pendingChange = nil
            result.pendingChange = PendingChange(since: now, reason: reason, previous: approved)
        } else {
            result.pendingChange = nil
        }
        return result
    }

    /// Grund, wenn Umschreibungen oder Aktion abweichen; sonst nil.
    public static func riskyChange(from approved: Rule, to new: Rule) -> String? {
        let rewrites = approved.rewrites != new.rewrites
        let action = approved.action != new.action
        switch (rewrites, action) {
        case (true, true): return "Umschreibungen und Aktion geändert von außen (CLI/MCP)"
        case (true, false): return "Umschreibungen geändert von außen (CLI/MCP)"
        case (false, true): return "Aktion geändert von außen (CLI/MCP)"
        case (false, false): return nil
        }
    }

    /// „Freigeben“ in der App: Regel gilt wie sie ist.
    public static func approve(_ rule: Rule) -> Rule {
        var result = rule
        result.pendingChange = nil
        return result
    }

    /// „Verwerfen“ in der App: neu angelegt → nil (löschen), geändert → zuletzt freigegebener Stand,
    /// mit dem aktuellen An/Aus (das wirkt sofort und bleibt beim Verwerfen erhalten).
    public static func discard(_ rule: Rule) -> Rule? {
        guard let pending = rule.pendingChange else { return rule }
        guard var previous = pending.previous else { return nil }
        previous.id = rule.id
        previous.enabled = rule.enabled
        previous.pendingChange = nil
        return previous
    }

    /// Anzahl wartender Regeln.
    public static func pendingCount(in config: Config) -> Int {
        config.rules.count(where: \.isPendingApproval)
    }

    /// „1 Regel wartet auf Freigabe“ / „3 Regeln warten auf Freigabe“.
    public static func countText(_ count: Int) -> String {
        count == 1 ? "1 Regel wartet auf Freigabe" : "\(count) Regeln warten auf Freigabe"
    }

    /// Prüft Eingaben von Agenten: `pendingChange` darf nicht gesetzt werden.
    static let inputIssue = FieldIssue(
        "pendingChange",
        "kann nicht von außen gesetzt werden – Änderungen an Umschreibungen oder Aktion gibt der Nutzer in Air Traffic frei"
    )
}

// MARK: - Ziel einer Umschreibung

extension RuleDescriber {
    /// Ziel der Umschreibungen für Kurzbeschreibungen: literaler Anfang der Vorlage bis zum ersten `$`,
    /// bei http/https nur der Host („review.example.com“), sonst Schema und Rest („linear://review“).
    /// Mehrere Umschreibungen: die letzte mit literalem Ziel; folgen danach weitere Schritte, steht
    /// „+1 Schritt“ bzw. „+n Schritte“ dahinter – sie können die URL noch beliebig verändern.
    /// Nil, wenn keine ein literales Ziel hat.
    public static func rewriteTarget(_ rewrites: [Rewrite]) -> String? {
        guard let index = rewrites.lastIndex(where: { target(ofTemplate: $0.template) != nil }),
              let target = target(ofTemplate: rewrites[index].template)
        else { return nil }
        let later = rewrites.count - 1 - index
        guard later > 0 else { return target }
        return "\(target) +\(later) \(later == 1 ? "Schritt" : "Schritte")"
    }

    /// Ziel einer Vorlage. Der Host steht nur fest, wenn er im literalen Teil endet (`/`, `?`, `#` oder
    /// Ende der Vorlage); geht die Vorlage mitten im Host mit einer Gruppe weiter, endet das Ziel auf
    /// „…“. Bei einer Benutzerangabe (`nutzer@host`) zählt, was hinter dem letzten `@` steht.
    static func target(ofTemplate template: String) -> String? {
        let prefix = Rewriter.literalPrefix(of: template)
        let literal = prefix.trimmingCharacters(in: .whitespaces)
        guard !literal.isEmpty else { return nil }
        guard let separator = literal.range(of: "://") else {
            return literal.count > 40 ? String(literal.prefix(40)) + "…" : literal
        }
        let scheme = literal[..<separator.lowerBound].lowercased()
        let rest = literal[separator.upperBound...]
        var authority = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        // Vorlage geht nach dem literalen Teil weiter, ohne dass der Host dort schon zu Ende wäre.
        let open = prefix.count < template.count && authority.endIndex == rest.endIndex
        if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
        guard !authority.isEmpty else {
            return scheme == "http" || scheme == "https" ? nil : "\(scheme)://"
        }
        let host = String(authority) + (open ? "…" : "")
        return scheme == "http" || scheme == "https" ? host : "\(scheme)://\(host)"
    }

    /// Chip/Kurztext: „↻ review.example.com“, ohne literales Ziel „↻ umschreiben“.
    public static func rewriteChip(_ rewrites: [Rewrite]) -> String? {
        guard !rewrites.isEmpty else { return nil }
        return "↻ " + (rewriteTarget(rewrites) ?? "umschreiben")
    }
}
