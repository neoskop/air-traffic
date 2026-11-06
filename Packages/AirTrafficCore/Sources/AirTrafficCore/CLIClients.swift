import Foundation

// MARK: - Claude Code

/// KI-Assistent über die Claude-Code-CLI und das bestehende Claude-Abo (§16.2).
///
/// Aufruf (geprüft mit Claude Code 2.1.318):
/// `claude -p --output-format json --json-schema <Schema> --model <Modell> --system-prompt <System>
///  --tools "" --no-session-persistence --strict-mcp-config`, Prompt über stdin, Arbeitsverzeichnis leer.
/// Kein `--bare`, sonst greift das Abo-Login nicht.
///
/// Antwort: ein JSON-Objekt `{"type":"result","is_error":false,"result":"<Text>","structured_output":{…},…}`;
/// bei Fehlern `is_error: true`, Meldung in `result`, Exit-Code 1.
public struct ClaudeCLIClient: LLMClient {
    public var transport: CLITransport

    public init(transport: CLITransport) {
        self.transport = transport
    }

    public init(configuredPath: String? = nil) {
        self.init(transport: CLITransport(cli: .claude, configuredPath: configuredPath))
    }

    public static func arguments(model: String, systemPrompt: String, schema: ResponseSchema?) -> [String] {
        var args = ["-p", "--output-format", "json"]
        if let schema { args += ["--json-schema", CLIPrompt.encodeJSON(schema.schema)] }
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty { args += ["--model", model] }
        if !systemPrompt.isEmpty { args += ["--system-prompt", systemPrompt] }
        args += ["--tools", "", "--no-session-persistence", "--strict-mcp-config"]
        return args
    }

    public func complete(_ request: LLMRequest) async throws -> String {
        let (system, prompt) = CLIPrompt.split(request.messages)
        let dir = try CLIPrompt.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = try await transport.run(
            arguments: Self.arguments(model: request.model, systemPrompt: system, schema: request.responseSchema),
            stdin: Data(prompt.utf8),
            in: dir
        )
        try Task.checkCancellation()
        return try Self.parse(result)
    }

    /// Liest das Ergebnis-Objekt: `structured_output` (bei `--json-schema`), sonst `result`.
    public static func parse(_ result: ProcessResult) throws -> String {
        let json = try? JSONDecoder().decode(JSONValue.self, from: result.stdout)
        let isError: Bool = {
            if case .bool(true) = json?["is_error"] { return true }
            return false
        }()
        if result.exitCode != 0 || isError {
            let message = json?["result"]?.stringValue
                ?? AssistantCLIError.condensed(result.stderrText)
                ?? AssistantCLIError.condensed(result.stdoutText)
            var status: Int?
            if case .number(let n) = json?["api_error_status"] { status = Int(n) }
            if status == 401 || status == 403 || AssistantCLIError.looksLikeLoginProblem(message ?? "") {
                throw AssistantCLIError.notLoggedIn(.claude)
            }
            throw AssistantCLIError.failed(.claude, exitCode: result.exitCode, message: message.flatMap(AssistantCLIError.condensed))
        }
        guard let json else {
            throw AssistantCLIError.invalidResponse(.claude, "kein JSON-Ergebnis")
        }
        if let structured = json["structured_output"], case .object = structured {
            return CLIPrompt.encodeJSON(structured)
        }
        guard let text = json["result"]?.stringValue,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw AssistantCLIError.invalidResponse(.claude, "leere Antwort")
        }
        return text
    }
}

// MARK: - Codex

/// KI-Assistent über die Codex-CLI und das bestehende ChatGPT-Abo (§16.2).
///
/// Aufruf (geprüft mit codex-cli 0.166.0):
/// `codex exec --ephemeral --skip-git-repo-check -s read-only -C <TempDir> --output-schema <Datei>
///  -o <Datei> -c model_reasoning_effort="low" [-m <Modell>] -`, Prompt (System + Nutzer) über stdin.
///
/// Antwort: die letzte Nachricht des Modells als Datei `-o` (bei `--output-schema` ein JSON-Objekt).
/// Fehler: Exit-Code ≠ 0, Meldung als Zeile „ERROR: …“ auf stderr.
public struct CodexCLIClient: LLMClient {
    public var transport: CLITransport

    public static let schemaFileName = "schema.json"
    public static let outputFileName = "answer.txt"

    public init(transport: CLITransport) {
        self.transport = transport
    }

    public init(configuredPath: String? = nil) {
        self.init(transport: CLITransport(cli: .codex, configuredPath: configuredPath))
    }

    public static func arguments(model: String, directory: URL, hasSchema: Bool) -> [String] {
        var args = [
            "exec", "--ephemeral", "--skip-git-repo-check",
            "-s", "read-only",
            "-C", directory.path(percentEncoded: false),
        ]
        if hasSchema {
            args += ["--output-schema", directory.appending(path: schemaFileName).path(percentEncoded: false)]
        }
        args += [
            "-o", directory.appending(path: outputFileName).path(percentEncoded: false),
            "-c", "model_reasoning_effort=\"low\"",
        ]
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty { args += ["-m", model] }
        args.append("-")
        return args
    }

    /// Klare Anweisung vorweg (§26.6): Codex ist ein Agent mit Werkzeugen; hier soll er nur antworten.
    public static let toolInstruction = """
        IMPORTANT: Do not use any tools. Do not run shell commands, do not read, list, search or write files, \
        and do not browse. Everything you need is in this message. Reply only with the requested JSON object, nothing else.
        """

    /// System und Gespräch in einem Prompt (Codex kennt keinen getrennten Systemprompt im `exec`-Modus),
    /// mit `toolInstruction` vorweg.
    public static func prompt(for messages: [ChatMessage]) -> String {
        let (system, prompt) = CLIPrompt.split(messages)
        guard !system.isEmpty else { return "\(toolInstruction)\n\n---\n\n\(prompt)" }
        return "\(toolInstruction)\n\n\(system)\n\n---\n\n\(prompt)"
    }

    public func complete(_ request: LLMRequest) async throws -> String {
        let dir = try CLIPrompt.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        if let schema = request.responseSchema {
            try Data(CLIPrompt.encodeJSON(schema.schema).utf8).write(to: dir.appending(path: Self.schemaFileName))
        }
        let result = try await transport.run(
            arguments: Self.arguments(model: request.model, directory: dir, hasSchema: request.responseSchema != nil),
            stdin: Data(Self.prompt(for: request.messages).utf8),
            in: dir
        )
        try Task.checkCancellation()
        let output = try? String(contentsOf: dir.appending(path: Self.outputFileName), encoding: .utf8)
        return try Self.parse(result, output: output)
    }

    public static func parse(_ result: ProcessResult, output: String?) throws -> String {
        if result.exitCode != 0 {
            let message = errorMessage(in: result.stderrText) ?? AssistantCLIError.condensed(result.stdoutText)
            if AssistantCLIError.looksLikeLoginProblem(message ?? "") {
                throw AssistantCLIError.notLoggedIn(.codex)
            }
            throw AssistantCLIError.failed(.codex, exitCode: result.exitCode, message: message)
        }
        guard let output, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AssistantCLIError.invalidResponse(.codex, "leere Antwort")
        }
        return output
    }

    /// Letzte Zeile „ERROR: …“ (ohne Präfix), sonst die letzte nicht leere Zeile von stderr.
    static func errorMessage(in stderr: String) -> String? {
        let lines = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if let line = lines.last(where: { $0.hasPrefix("ERROR:") }) {
            return AssistantCLIError.condensed(String(line.dropFirst("ERROR:".count)))
        }
        return lines.last(where: { !$0.isEmpty }).flatMap(AssistantCLIError.condensed)
    }
}

// MARK: - Verbindungstest

/// „Verbindung testen“ für alle Anbieter: Mini-Anfrage mit kurzem JSON-Echo (§16.3).
public enum AssistantConnectionCheck {
    public static let schema = ResponseSchema(
        name: "echo",
        schema: .object([
            "type": .string("object"),
            "properties": .object(["ok": .object(["type": .string("boolean")])]),
            "required": .array([.string("ok")]),
            "additionalProperties": .bool(false),
        ])
    )

    public static func request(model: String) -> LLMRequest {
        LLMRequest(
            model: model,
            messages: [
                .system("You are a connectivity check. Respond with JSON only."),
                .user("Reply with exactly this JSON object: {\"ok\": true}"),
            ],
            temperature: 0,
            responseSchema: schema
        )
    }

    /// Wirft, wenn die Anfrage scheitert oder die Antwort kein `{"ok": true}` enthält.
    public static func run(client: any LLMClient, model: String) async throws {
        let reply = try await client.complete(request(model: model))
        guard isEcho(reply) else {
            throw LLMError.invalidResponse("unerwartete Antwort auf den Verbindungstest")
        }
    }

    static func isEcho(_ reply: String) -> Bool {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates = [trimmed]
        if let open = trimmed.firstIndex(of: "{"), let close = trimmed.lastIndex(of: "}"), open < close {
            candidates.append(String(trimmed[open...close]))
        }
        return candidates.contains { candidate in
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(candidate.utf8)) else { return false }
            return value["ok"] == .bool(true)
        }
    }
}
