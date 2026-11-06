// Debug-Schalter: nur im Debug-Build (§26.5); der Release-Build kennt den Befehl nicht.
#if DEBUG
import AirTrafficCore
import Foundation

/// `--suggest-regex "<Beschreibung>" --example <url> [--example <url> …] [--mode rewrite|condition]
/// [--provider openrouter|claude|codex]` (§12.5, §16.4): Anbieter aus `--provider`, sonst aus der Config.
/// OpenRouter: Key aus `OPENROUTER_API_KEY`, sonst Schlüsselbund. Druckt das geprüfte Ergebnis als JSON.
/// Exit 0 bei Erfolg, 1 bei Fehler (Meldung auf stderr). Kein Fenster, schreibt nichts.
@MainActor
enum SuggestRegexCommand {
    static let flag = "--suggest-regex"
    static let exampleFlag = "--example"
    static let modeFlag = "--mode"
    static let providerFlag = "--provider"

    static let usage = "Aufruf: \(flag) \"<Beschreibung>\" \(exampleFlag) <url> [\(exampleFlag) <url> …] [\(modeFlag) rewrite|condition] [\(providerFlag) openrouter|claude|codex]"

    struct Output: Encodable {
        var mode: String
        var provider: String
        var model: String
        var pattern: String
        var template: String?
        var explanation: String
        var valid: Bool
        var repaired: Bool
        var warnings: [String]
        var hints: [String]
        var examples: [RegexExampleResult]

        private enum CodingKeys: String, CodingKey {
            case mode, provider, model, pattern, template, explanation, valid, repaired, warnings, hints, examples
        }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(mode, forKey: .mode)
            try c.encode(provider, forKey: .provider)
            try c.encode(model, forKey: .model)
            try c.encode(pattern, forKey: .pattern)
            try c.encode(template, forKey: .template) // explizit null im Modus Bedingung
            try c.encode(explanation, forKey: .explanation)
            try c.encode(valid, forKey: .valid)
            try c.encode(repaired, forKey: .repaired)
            try c.encode(warnings, forKey: .warnings)
            try c.encode(hints, forKey: .hints)
            try c.encode(examples, forKey: .examples)
        }
    }

    static func run(arguments: [String]) async -> Int32 {
        guard let description = value(after: flag, in: arguments), !description.hasPrefix("--"),
              !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return fail(usage)
        }
        let examples = values(after: exampleFlag, in: arguments)
        guard !examples.isEmpty else { return fail("Mindestens eine \(exampleFlag) <url> angeben.\n\(usage)") }

        let mode: RegexAssistantMode
        switch value(after: modeFlag, in: arguments) ?? "rewrite" {
        case "rewrite": mode = .rewrite
        case "condition": mode = .condition(.url)
        case let other: return fail("Unbekannter Modus „\(other)“ – erlaubt: rewrite, condition")
        }

        // Anbieter und Modelle aus der Konfiguration; fehlt oder unlesbar → Standard.
        let config = ((try? ConfigStore.makeDefault().load()) ?? nil) ?? Config()
        let provider: AssistantProvider
        if let argument = value(after: providerFlag, in: arguments) {
            guard let parsed = AssistantProvider(argument: argument) else {
                return fail("Unbekannter Anbieter „\(argument)“ – erlaubt: openrouter, claude, codex")
            }
            provider = parsed
        } else {
            provider = config.assistantProvider
        }

        let client: any LLMClient
        switch provider {
        case .openRouter:
            do {
                client = OpenRouterClient(apiKey: try APIKeyResolver.resolve(store: KeychainAPIKeyStore()))
            } catch LLMError.missingAPIKey {
                return fail("Kein OpenRouter-API-Key: Umgebungsvariable \(APIKeyResolver.environmentKey) setzen oder in Einstellungen → Allgemein → „KI-Assistent“ sichern.")
            } catch {
                return fail(error.localizedDescription)
            }
        case .claudeCLI:
            client = ClaudeCLIClient(configuredPath: config.assistant?.claudePath)
        case .codexCLI:
            client = CodexCLIClient(configuredPath: config.assistant?.codexPath)
        }
        let model = config.assistantModel(for: provider)
        let assistant = RegexAssistant(client: client, model: model)

        let turn: RegexAssistantTurn
        do {
            turn = try await assistant.start(mode: mode, examples: examples, description: description)
        } catch {
            return fail(error.localizedDescription)
        }

        let output = Output(
            mode: mode.isRewrite ? "rewrite" : "condition",
            provider: provider.argument,
            model: model,
            pattern: turn.suggestion.pattern,
            template: turn.suggestion.template,
            explanation: turn.suggestion.explanation,
            valid: turn.validation.isValid,
            repaired: turn.repaired,
            warnings: turn.warnings,
            hints: turn.validation.hints,
            examples: turn.validation.results
        )
        do {
            var data = try ConfigStore.makeEncoder().encode(output)
            data.append(0x0A)
            FileHandle.standardOutput.write(data)
        } catch {
            return fail("JSON-Fehler: \(error)")
        }
        guard turn.validation.isValid else {
            return fail("Ergebnis auch nach einer Reparaturrunde nicht fehlerfrei: "
                + turn.validation.problems.map(\.germanDescription).joined(separator: "; "))
        }
        return 0
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func values(after flag: String, in arguments: [String]) -> [String] {
        arguments.indices.compactMap { i in
            arguments[i] == flag && arguments.indices.contains(i + 1) ? arguments[i + 1] : nil
        }
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return 1
    }
}
#endif
