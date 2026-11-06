import Foundation

/// Wendet `Rewrite`s per `NSRegularExpression` an.
public enum Rewriter {
    public struct Output: Sendable, Equatable {
        public var url: URL
        public var warnings: [String]
        /// Hinweise ohne Fehler, z. B. ein erlaubter Schemawechsel (nur Regel-Test, §26.2).
        public var notes: [String] = []
    }

    public enum Failure: Error, Equatable, Sendable {
        case invalidPattern(String, message: String)
        case timeout
    }

    /// Wendet die Rewrites nacheinander an. Ungültiger Regex, Zeitlimit, ein Ergebnis, das keine
    /// gültige URL ist, oder ein nicht erlaubtes Schema (§26.2) → Original-URL plus Warnung.
    public static func apply(_ rewrites: [Rewrite], to url: URL, budget: MatchBudget? = nil) -> Output {
        run(rewrites, on: url, budget: budget, collectSteps: false).output
    }

    /// Ein Durchlauf für Ergebnis und Zwischenschritte (§27 K10). `steps` (nur mit `collectSteps`)
    /// enthält den Text nach jeder Umschreibung; eine fehlgeschlagene Umschreibung lässt den Text
    /// unverändert, die folgenden laufen für die Anzeige weiter. Das Ergebnis ist dann die Original-URL.
    static func run(
        _ rewrites: [Rewrite], on url: URL, budget: MatchBudget?, collectSteps: Bool
    ) -> (output: Output, steps: [String]) {
        guard !rewrites.isEmpty else { return (Output(url: url, warnings: []), []) }
        let budget = budget ?? MatchBudget()
        var current = url.absoluteString
        var steps: [String] = []
        var failure: String?
        /// Vorlagen der Umschreibungen, die den Text tatsächlich verändert haben (§27 K11).
        var appliedTemplates: [String] = []
        for (index, rewrite) in rewrites.enumerated() {
            do {
                let next = try apply(rewrite, to: current, budget: budget)
                if next != current { appliedTemplates.append(rewrite.template) }
                current = next
            } catch let Failure.invalidPattern(pattern, message) {
                failure = failure ?? "Umschreibung \(index + 1): ungültiger regulärer Ausdruck „\(pattern)“ (\(message)); Original-URL verwendet"
            } catch Failure.timeout {
                failure = failure ?? "Umschreibung \(index + 1): \(TextMatcher.timeoutMessage); Original-URL verwendet"
            } catch {
                failure = failure ?? "Umschreibung \(index + 1): \(error); Original-URL verwendet"
            }
            if collectSteps {
                steps.append(current)
            } else if failure != nil {
                break
            }
        }
        if let failure { return (Output(url: url, warnings: [failure]), steps) }
        guard let result = validURL(current) else {
            return (Output(url: url, warnings: [
                "Umschreibung ergibt keine gültige URL („\(current)“); Original-URL verwendet",
            ]), steps)
        }
        let original = url.scheme?.lowercased() ?? ""
        let scheme = result.scheme?.lowercased() ?? ""
        guard isAllowedScheme(scheme, original: original, templates: appliedTemplates) else {
            return (Output(url: url, warnings: [
                "Umschreibung ergibt Schema „\(scheme):“ – erlaubt sind http/https, das Schema der Original-URL oder ein Schema, das literal am Anfang der Vorlage einer angewendeten Umschreibung steht; Original-URL verwendet",
            ]), steps)
        }
        var notes: [String] = []
        if scheme != original {
            notes.append("Schemawechsel „\(original):“ → „\(scheme):“")
        }
        return (Output(url: result, warnings: [], notes: notes), steps)
    }

    /// Eine einzelne Umschreibung auf einen String; unverändert, wenn das Muster nicht trifft.
    public static func apply(_ rewrite: Rewrite, to string: String) throws -> String {
        try apply(rewrite, to: string, budget: MatchBudget())
    }

    /// Ein Durchlauf über die Treffer (kein vorgeschaltetes `firstMatch`, §27 K10).
    static func apply(_ rewrite: Rewrite, to string: String, budget: MatchBudget?) throws -> String {
        let regex = try regex(for: rewrite)
        do {
            return try regex.replacingMatches(in: string, template: rewrite.template, budget: budget)
        } catch is MatchTimeout {
            throw Failure.timeout
        }
    }

    /// Fehlermeldung für ein ungültiges Muster, sonst `nil` (für die Live-Validierung im Editor).
    public static func validationError(for rewrite: Rewrite) -> String? {
        do {
            _ = try regex(for: rewrite)
            return nil
        } catch let Failure.invalidPattern(_, message) {
            return message
        } catch {
            return "\(error)"
        }
    }

    /// Gültig = strikt parsbar (ohne automatisches Kodieren ungültiger Zeichen) und mit Schema.
    public static func validURL(_ string: String) -> URL? {
        guard let url = URL(string: string, encodingInvalidCharacters: false),
              let scheme = url.scheme, !scheme.isEmpty
        else { return nil }
        return url
    }

    // MARK: Schema (§26.2)

    /// Erlaubt: http/https, das Schema der Original-URL oder ein Schema, das literal am Anfang einer
    /// Vorlage steht (vom Regel-Autor gesetzt, nicht aus der URL übernommen).
    public static func isAllowedScheme(_ scheme: String, original: String, templates: [String]) -> Bool {
        let scheme = scheme.lowercased()
        if scheme == "http" || scheme == "https" || scheme == original.lowercased() { return true }
        return templates.contains { literalScheme(of: $0) == scheme }
    }

    /// Literaler Anfang der Vorlage bis zum ersten `$` (Gruppe) bzw. `\` (Maskierung).
    public static func literalPrefix(of template: String) -> String {
        String(template.prefix { $0 != "$" && $0 != "\\" })
    }

    /// Schema, das literal am Anfang der Vorlage steht, z. B. `linear` für `linear://…`; sonst nil.
    public static func literalScheme(of template: String) -> String? {
        let literal = literalPrefix(of: template)
        guard let colon = literal.firstIndex(of: ":") else { return nil }
        let scheme = literal[..<colon]
        guard let first = scheme.first, first.isASCII, first.isLetter,
              scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) })
        else { return nil }
        return scheme.lowercased()
    }

    static func regex(for rewrite: Rewrite) throws -> NSRegularExpression {
        do {
            return try RegexCache.regex(rewrite.pattern, options: rewrite.caseSensitive ? [] : [.caseInsensitive])
        } catch {
            throw Failure.invalidPattern(rewrite.pattern, message: (error as NSError).localizedDescription)
        }
    }
}
