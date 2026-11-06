import Foundation

// MARK: - Freigabe riskanter Änderungen von außen (SPEC §26.1)

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
    /// mit dem aktuellen An/Aus (§27 K5: das wirkt sofort und bleibt beim Verwerfen erhalten).
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

// MARK: - Ziel einer Umschreibung (§26.1)

extension RuleDescriber {
    /// Ziel der Umschreibungen für Kurzbeschreibungen: literaler Anfang der Vorlage bis zum ersten `$`,
    /// bei http/https nur der Host („review.example.com“), sonst Schema und Rest („linear://review“).
    /// Mehrere Umschreibungen: die letzte mit literalem Ziel. Nil, wenn keine ein literales Ziel hat.
    public static func rewriteTarget(_ rewrites: [Rewrite]) -> String? {
        for rewrite in rewrites.reversed() {
            if let target = target(ofTemplate: rewrite.template) { return target }
        }
        return nil
    }

    static func target(ofTemplate template: String) -> String? {
        let literal = Rewriter.literalPrefix(of: template).trimmingCharacters(in: .whitespaces)
        guard !literal.isEmpty else { return nil }
        guard let separator = literal.range(of: "://") else {
            return literal.count > 40 ? String(literal.prefix(40)) + "…" : literal
        }
        let scheme = literal[..<separator.lowerBound].lowercased()
        let rest = literal[separator.upperBound...]
        let host = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        if scheme == "http" || scheme == "https" {
            return host.isEmpty ? nil : String(host)
        }
        return host.isEmpty ? "\(scheme)://" : "\(scheme)://\(host)"
    }

    /// Chip/Kurztext: „↻ review.example.com“, ohne literales Ziel „↻ umschreiben“.
    public static func rewriteChip(_ rewrites: [Rewrite]) -> String? {
        guard !rewrites.isEmpty else { return nil }
        return "↻ " + (rewriteTarget(rewrites) ?? "umschreiben")
    }
}
