import Foundation

// MARK: - Typen

/// Worauf eine Regex-Bedingung angewendet wird (Feld der Bedingungszeile).
public enum RegexTarget: String, Codable, Sendable, CaseIterable {
    case url, host, path

    /// Prüfstring wie in `RuleEngine.evaluate`.
    public func subject(of url: URL) -> String {
        switch self {
        case .url: url.absoluteString
        case .host: url.host(percentEncoded: false) ?? ""
        case .path: url.path(percentEncoded: false)
        }
    }
}

public enum RegexAssistantMode: Sendable, Equatable {
    /// Muster + Vorlage für eine Umschreibung (immer auf die gesamte URL).
    case rewrite
    /// Nur Muster für eine Bedingung mit Operator `regex`.
    case condition(RegexTarget)

    public var isRewrite: Bool { self == .rewrite }
}

/// Antwort des Modells.
public struct RegexSuggestion: Codable, Sendable, Equatable {
    public var pattern: String
    public var template: String?
    public var explanation: String

    public init(pattern: String, template: String?, explanation: String = "") {
        self.pattern = pattern
        self.template = template
        self.explanation = explanation
    }
}

/// Eine Zeile der Tabelle „Vorher → Nachher“ bzw. „trifft / trifft nicht“.
public struct RegexExampleResult: Codable, Sendable, Equatable {
    public var input: String
    /// `false`, wenn die Beispiel-URL selbst nicht parsbar ist (wird nicht dem Modell angelastet).
    public var inputIsValidURL: Bool
    public var matches: Bool
    /// Nur Modus Umschreiben: Ergebnis (bei Nicht-Treffer = Eingabe).
    public var output: String?
    public var outputIsValidURL: Bool
}

/// Problem, das eine Reparaturrunde auslöst.
public enum RegexProblem: Sendable, Equatable {
    case emptyPattern
    case invalidPattern(String)
    case missingTemplate
    case invalidResultURL(input: String, output: String)

    /// Für das Modell (Reparaturrunde).
    public var englishDescription: String {
        switch self {
        case .emptyPattern: "The pattern is empty."
        case .invalidPattern(let message): "The pattern does not compile with NSRegularExpression: \(message)"
        case .missingTemplate: "Rewrite mode requires a template, but \"template\" was null or missing."
        case .invalidResultURL(let input, let output):
            "Rewriting \"\(input)\" produces \"\(output)\", which is not a valid absolute URL."
        }
    }

    /// Für die Anzeige.
    public var germanDescription: String {
        switch self {
        case .emptyPattern: "Das Muster ist leer."
        case .invalidPattern(let message): "Ungültiger regulärer Ausdruck: \(message)"
        case .missingTemplate: "Keine Vorlage angegeben."
        case .invalidResultURL(let input, let output):
            "„\(input)“ ergibt „\(output)“ – keine gültige URL."
        }
    }
}

/// Ergebnis der lokalen Prüfung.
public struct RegexValidation: Sendable, Equatable {
    public var results: [RegexExampleResult]
    /// Lösen eine Reparaturrunde aus.
    public var problems: [RegexProblem]
    /// Nur Hinweise (deutsch), z. B. „trifft keine Beispiel-URL“.
    public var hints: [String]

    public var isValid: Bool { problems.isEmpty }
    public var patternCompiles: Bool {
        !problems.contains { if case .emptyPattern = $0 { true } else if case .invalidPattern = $0 { true } else { false } }
    }
}

/// Gesprächsverlauf für „Verfeinern“ (Multi-Turn).
public struct RegexConversation: Sendable, Equatable {
    public let mode: RegexAssistantMode
    public var caseSensitive: Bool
    public internal(set) var messages: [ChatMessage]
}

public struct RegexAssistantTurn: Sendable, Equatable {
    public var conversation: RegexConversation
    public var suggestion: RegexSuggestion
    public var validation: RegexValidation
    /// Es lief eine automatische Reparaturrunde.
    public var repaired: Bool

    /// Deutsche Warnungen für die Anzeige, falls auch nach der Reparatur Probleme bleiben.
    public var warnings: [String] {
        guard !validation.isValid else { return [] }
        return ["Auch nach einer Reparaturrunde nicht fehlerfrei – bitte prüfen."]
            + validation.problems.map(\.germanDescription)
    }
}

// MARK: - Assistent

/// Baut Nachrichten, ruft das Modell, parst, prüft lokal und repariert einmal (§12.4).
public struct RegexAssistant: Sendable {
    public let client: any LLMClient
    public let model: String

    public init(client: any LLMClient, model: String) {
        self.client = client
        self.model = model
    }

    // MARK: Prompt

    public static let systemPrompt = """
    You write regular expressions for "Air Traffic", a macOS app that rewrites and routes URLs before \
    they are opened in a browser or app.

    Rules:
    1. Dialect: ICU regular expressions as used by Apple's NSRegularExpression. Do not use PCRE-only \
    features such as \\K, recursion or conditionals.
    2. The pattern is applied to the entire URL string, for example \
    "https://github.com/owner/repo/pull/12/files?w=1#diff", unless the user message says the pattern \
    is matched against the host or path only.
    3. Matching is case-insensitive by default. Do not add inline flags such as (?i) unless asked.
    4. Rewrite mode: the URL is rewritten with NSRegularExpression.stringByReplacingMatches(in:range:withTemplate:). \
    Every match is replaced, so anchor the pattern with ^ and $ and capture what must be kept. \
    In the template, $1 … $n refer to capture groups and $0 to the whole match. Write a literal "$" as "\\$" \
    and a literal backslash as "\\\\". The rewritten result must be a valid absolute URL.
    5. Keep the query string and the fragment unless the user explicitly asks to change or drop them.
    6. Match only the URLs the user describes; other URLs must stay unmatched. Escape literal dots, \
    avoid unanchored catch-all patterns, and prefer [^/]+ over .* for single path segments.
    7. Condition mode: return only a pattern and set "template" to null. The pattern is tested with \
    firstMatch, so it matches anywhere in the string unless anchored.
    8. Respond with JSON only, no Markdown and no prose outside the JSON object:
    {"pattern": string, "template": string or null, "explanation": string}
    Remember JSON string escaping: a regex backslash is written as \\\\ inside the JSON string.
    "explanation" is 1–3 short sentences in German describing what the pattern matches and what the \
    template produces.
    """

    /// Strict JSON-Schema für `response_format`.
    public static let responseSchema = ResponseSchema(
        name: "regex_suggestion",
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "pattern": .object(["type": .string("string")]),
                "template": .object(["type": .array([.string("string"), .string("null")])]),
                "explanation": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("pattern"), .string("template"), .string("explanation")]),
            "additionalProperties": .bool(false),
        ])
    )

    static func modeDescription(_ mode: RegexAssistantMode, caseSensitive: Bool) -> String {
        let caseNote = caseSensitive ? " Matching is case-SENSITIVE for this rule." : ""
        switch mode {
        case .rewrite:
            return "Mode: REWRITE. Return a pattern and a template.\(caseNote)"
        case .condition(.url):
            return "Mode: CONDITION. Return only a pattern (template null). It is matched against the entire URL.\(caseNote)"
        case .condition(.host):
            return "Mode: CONDITION. Return only a pattern (template null). It is matched against the URL's host only, e.g. \"github.com\" – not the whole URL.\(caseNote)"
        case .condition(.path):
            return "Mode: CONDITION. Return only a pattern (template null). It is matched against the URL's path only, e.g. \"/owner/repo/pull/12\" – without scheme, host, query or fragment.\(caseNote)"
        }
    }

    static func examplesBlock(_ examples: [String], target: RegexTarget) -> String {
        guard !examples.isEmpty else { return "Example URLs: none given." }
        let lines = examples.map { example -> String in
            if target != .url, let url = Rewriter.validURL(example) {
                return "- \(example)  (\(target.rawValue): \"\(target.subject(of: url))\")"
            }
            return "- \(example)"
        }
        return "Example URLs (one per line):\n" + lines.joined(separator: "\n")
    }

    static func currentBlock(_ current: RegexSuggestion?, mode: RegexAssistantMode) -> String? {
        guard let current, !current.pattern.isEmpty else { return nil }
        var text = "Current pattern: \(current.pattern)"
        if mode.isRewrite { text += "\nCurrent template: \(current.template ?? "")" }
        return text
    }

    static func target(of mode: RegexAssistantMode) -> RegexTarget {
        if case .condition(let target) = mode { target } else { .url }
    }

    /// Erste Nutzernachricht: Modus, Beispiele, Beschreibung, ggf. vorhandenes Muster.
    public static func initialMessage(
        mode: RegexAssistantMode,
        examples: [String],
        description: String,
        current: RegexSuggestion? = nil,
        caseSensitive: Bool = false
    ) -> String {
        var parts = [modeDescription(mode, caseSensitive: caseSensitive), examplesBlock(examples, target: target(of: mode))]
        if let block = currentBlock(current, mode: mode) {
            parts.append(block + "\nImprove or replace it according to the description.")
        }
        parts.append("Description:\n\(description.trimmingCharacters(in: .whitespacesAndNewlines))")
        return parts.joined(separator: "\n\n")
    }

    /// Folgeanweisung („Verfeinern“) mit dem aktuellen, ggf. vom Nutzer bearbeiteten Stand.
    public static func refineMessage(
        instruction: String,
        mode: RegexAssistantMode,
        examples: [String],
        current: RegexSuggestion?
    ) -> String {
        var parts: [String] = []
        if let block = currentBlock(current, mode: mode) {
            parts.append(block + "\n(This is the current state; the user may have edited it.)")
        }
        parts.append(examplesBlock(examples, target: target(of: mode)))
        parts.append("Follow-up instruction:\n\(instruction.trimmingCharacters(in: .whitespacesAndNewlines))")
        parts.append("Answer again with the complete JSON object.")
        return parts.joined(separator: "\n\n")
    }

    static func repairMessage(problems: [String]) -> String {
        "Your previous answer failed local validation:\n"
            + problems.map { "- \($0)" }.joined(separator: "\n")
            + "\n\nReturn a corrected answer as the complete JSON object."
    }

    // MARK: Parsing

    /// Akzeptiert reines JSON, JSON in ```-Codeblöcken und JSON mit Text drumherum.
    public static func parse(_ text: String) throws -> RegexSuggestion {
        for candidate in jsonCandidates(in: text) {
            if let suggestion = decode(candidate) { return suggestion }
        }
        throw LLMError.invalidResponse("kein JSON-Objekt mit „pattern“ gefunden")
    }

    private static func jsonCandidates(in text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates = [trimmed]
        // ```json … ``` bzw. ``` … ```
        if let regex = try? NSRegularExpression(pattern: "```[A-Za-z]*\\s*\\n?([\\s\\S]*?)```") {
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            for match in regex.matches(in: trimmed, range: range) {
                if let r = Range(match.range(at: 1), in: trimmed) {
                    candidates.append(String(trimmed[r]).trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
        if let open = trimmed.firstIndex(of: "{"), let close = trimmed.lastIndex(of: "}"), open < close {
            candidates.append(String(trimmed[open...close]))
        }
        return candidates
    }

    private static func decode(_ candidate: String) -> RegexSuggestion? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(candidate.utf8)),
              let pattern = value["pattern"]?.stringValue
        else { return nil }
        let template: String? = value["template"]?.stringValue
        let explanation = value["explanation"]?.stringValue ?? ""
        return RegexSuggestion(
            pattern: pattern,
            template: template,
            explanation: explanation.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: Validierung

    /// Zerlegt das mehrzeilige Beispiel-Feld (leere Zeilen weg, Leerraum getrimmt).
    public static func examples(from text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Lokale Prüfung: Muster kompiliert; Modus Umschreiben: jedes Beispiel ergibt eine gültige URL.
    public static func validate(
        pattern: String,
        template: String?,
        caseSensitive: Bool = false,
        mode: RegexAssistantMode,
        examples: [String]
    ) -> RegexValidation {
        var problems: [RegexProblem] = []
        var hints: [String] = []

        if pattern.isEmpty {
            problems.append(.emptyPattern)
        } else if let error = Rewriter.validationError(for: Rewrite(pattern: pattern, template: "", caseSensitive: caseSensitive)) {
            problems.append(.invalidPattern(error))
        }
        guard problems.isEmpty else {
            let rows = examples.map {
                RegexExampleResult(input: $0, inputIsValidURL: Rewriter.validURL($0) != nil, matches: false, output: nil, outputIsValidURL: false)
            }
            return RegexValidation(results: rows, problems: problems, hints: hints)
        }
        if mode.isRewrite, template == nil { problems.append(.missingTemplate) }

        let target = target(of: mode)
        let matchSpec = TextMatch(op: .regex, value: pattern, caseSensitive: caseSensitive)
        var rows: [RegexExampleResult] = []
        for example in examples {
            guard let url = Rewriter.validURL(example) else {
                rows.append(RegexExampleResult(input: example, inputIsValidURL: false, matches: false, output: nil, outputIsValidURL: false))
                hints.append("„\(example)“ ist selbst keine gültige URL und wird nicht geprüft.")
                continue
            }
            if mode.isRewrite {
                let subject = url.absoluteString
                let matches = TextMatcher.matches(matchSpec, subject)
                let output = (try? Rewriter.apply(
                    Rewrite(pattern: pattern, template: template ?? "", caseSensitive: caseSensitive),
                    to: subject
                )) ?? subject
                let outputValid = Rewriter.validURL(output) != nil
                if !outputValid { problems.append(.invalidResultURL(input: example, output: output)) }
                rows.append(RegexExampleResult(input: example, inputIsValidURL: true, matches: matches, output: output, outputIsValidURL: outputValid))
            } else {
                let matches = TextMatcher.matches(matchSpec, target.subject(of: url))
                rows.append(RegexExampleResult(input: example, inputIsValidURL: true, matches: matches, output: nil, outputIsValidURL: true))
            }
        }
        if !rows.isEmpty, rows.contains(where: \.inputIsValidURL), !rows.contains(where: \.matches) {
            hints.append("Das Muster trifft keine der Beispiel-URLs.")
        }
        return RegexValidation(results: rows, problems: problems, hints: hints)
    }

    // MARK: Ablauf

    /// Neues Gespräch. `current` = vorhandenes Muster/Vorlage, das verfeinert werden soll.
    public func start(
        mode: RegexAssistantMode,
        examples: [String],
        description: String,
        current: RegexSuggestion? = nil,
        caseSensitive: Bool = false
    ) async throws -> RegexAssistantTurn {
        let conversation = RegexConversation(mode: mode, caseSensitive: caseSensitive, messages: [.system(Self.systemPrompt)])
        let message = Self.initialMessage(mode: mode, examples: examples, description: description, current: current, caseSensitive: caseSensitive)
        return try await run(conversation, userMessage: message, examples: examples)
    }

    /// Folgeanweisung im selben Gespräch.
    public func refine(
        _ conversation: RegexConversation,
        instruction: String,
        examples: [String],
        current: RegexSuggestion?
    ) async throws -> RegexAssistantTurn {
        let message = Self.refineMessage(instruction: instruction, mode: conversation.mode, examples: examples, current: current)
        return try await run(conversation, userMessage: message, examples: examples)
    }

    private func run(_ start: RegexConversation, userMessage: String, examples: [String]) async throws -> RegexAssistantTurn {
        var conversation = start
        conversation.messages.append(.user(userMessage))

        var outcome = try await ask(&conversation, examples: examples)
        var repaired = false
        if !outcome.problems.isEmpty {
            repaired = true
            conversation.messages.append(.user(Self.repairMessage(problems: outcome.problems)))
            outcome = try await ask(&conversation, examples: examples)
        }
        guard let suggestion = outcome.suggestion, let validation = outcome.validation else {
            // Auch die Reparatur war nicht parsbar.
            throw outcome.parseError ?? LLMError.invalidResponse("Antwort nicht lesbar")
        }
        return RegexAssistantTurn(conversation: conversation, suggestion: suggestion, validation: validation, repaired: repaired)
    }

    private struct Outcome {
        var suggestion: RegexSuggestion?
        var validation: RegexValidation?
        var parseError: (any Error)?
        /// Englische Problembeschreibungen für die Reparaturrunde.
        var problems: [String]
    }

    private func ask(_ conversation: inout RegexConversation, examples: [String]) async throws -> Outcome {
        let request = LLMRequest(model: model, messages: conversation.messages, temperature: 0, responseSchema: Self.responseSchema)
        let reply = try await client.complete(request)
        try Task.checkCancellation()
        conversation.messages.append(.assistant(reply))

        let suggestion: RegexSuggestion
        do {
            suggestion = try Self.parse(reply)
        } catch {
            return Outcome(parseError: error, problems: [
                "The answer could not be parsed. Reply with exactly one JSON object {\"pattern\": string, \"template\": string or null, \"explanation\": string}.",
            ])
        }
        var normalized = suggestion
        if !conversation.mode.isRewrite { normalized.template = nil }
        let validation = Self.validate(
            pattern: normalized.pattern,
            template: normalized.template,
            caseSensitive: conversation.caseSensitive,
            mode: conversation.mode,
            examples: examples
        )
        return Outcome(suggestion: normalized, validation: validation, problems: validation.problems.map(\.englishDescription))
    }
}
