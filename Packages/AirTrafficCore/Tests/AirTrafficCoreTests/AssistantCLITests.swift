import Foundation
import Synchronization
import Testing
@testable import AirTrafficCore

/// Nimmt Aufrufe entgegen und antwortet mit einem vorbereiteten Ergebnis (oder Fehler).
final class FakeProcessRunner: ProcessRunner {
    struct Call: Sendable {
        var invocation: ProcessInvocation
        var stdinText: String
        /// Dateien im Arbeitsverzeichnis zum Zeitpunkt des Aufrufs (Name → Inhalt).
        var files: [String: String]
    }

    private let state: Mutex<[Call]>
    private let respond: @Sendable (ProcessInvocation) throws -> ProcessResult

    init(_ respond: @escaping @Sendable (ProcessInvocation) throws -> ProcessResult) {
        state = Mutex([])
        self.respond = respond
    }

    convenience init(result: ProcessResult) {
        self.init { _ in result }
    }

    var calls: [Call] { state.withLock { $0 } }

    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        var files: [String: String] = [:]
        if let dir = invocation.currentDirectory,
           let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false)) {
            for name in names {
                files[name] = (try? String(contentsOf: dir.appending(path: name), encoding: .utf8)) ?? ""
            }
        }
        let call = Call(
            invocation: invocation,
            stdinText: String(decoding: invocation.stdin ?? Data(), as: UTF8.self),
            files: files
        )
        state.withLock { $0.append(call) }
        return try respond(invocation)
    }
}

/// Fake-Dateisystem für die Binärsuche.
func fakeLocator(executables: Set<String>, home: String = "/Users/test", shell: String? = nil) -> CLILocator {
    CLILocator(
        homeDirectory: home,
        isExecutable: { executables.contains($0) },
        shellLookup: { _ in shell }
    )
}

func claudeTransport(runner: FakeProcessRunner, timeout: Duration = .seconds(90)) -> CLITransport {
    CLITransport(
        cli: .claude,
        configuredPath: nil,
        runner: runner,
        locator: fakeLocator(executables: ["/opt/homebrew/bin/claude"]),
        environment: ["PATH": "/opt/homebrew/bin:/usr/bin"],
        timeout: timeout
    )
}

func codexTransport(runner: FakeProcessRunner) -> CLITransport {
    CLITransport(
        cli: .codex,
        runner: runner,
        locator: fakeLocator(executables: ["/usr/local/bin/codex"]),
        environment: ["PATH": "/usr/local/bin:/usr/bin"]
    )
}

/// Echte Antwort von Claude Code 2.1.318 (gekürzt) mit `--output-format json --json-schema`.
let claudeSuccessJSON = #"""
{"type":"result","subtype":"success","is_error":false,"api_error_status":null,"num_turns":3,
 "result":"{\"pattern\":\"^https?://example\\\\.com(?:[/?#]|$)\",\"template\":null,\"explanation\":\"Trifft example.com.\"}",
 "structured_output":{"pattern":"^https?://example\\.com(?:[/?#]|$)","template":null,"explanation":"Trifft example.com."},
 "session_id":"0f33c2b1","total_cost_usd":0.0014}
"""#

let claudeRequest = LLMRequest(
    model: "haiku",
    messages: [.system("SYSTEM PROMPT"), .user("Describe example.com")],
    temperature: 0,
    responseSchema: RegexAssistant.responseSchema
)

@Suite("KI über CLI (§16)")
struct AssistantCLITests {
    // MARK: Argumente

    @Test func claudeArguments() {
        let args = ClaudeCLIClient.arguments(model: "haiku", systemPrompt: "SYS", schema: RegexAssistant.responseSchema)
        #expect(args == [
            "-p", "--output-format", "json",
            "--json-schema", CLIPrompt.encodeJSON(RegexAssistant.responseSchema.schema),
            "--model", "haiku",
            "--system-prompt", "SYS",
            "--tools", "", "--no-session-persistence", "--strict-mcp-config",
        ])
        #expect(!args.contains("--bare"), "sonst greift das Abo-Login nicht")
        let schema = args[args.firstIndex(of: "--json-schema")! + 1]
        let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(schema.utf8))
        #expect(decoded == RegexAssistant.responseSchema.schema)
    }

    @Test func claudeArgumentsWithoutModelOrSchema() {
        let args = ClaudeCLIClient.arguments(model: " ", systemPrompt: "", schema: nil)
        #expect(args == ["-p", "--output-format", "json", "--tools", "", "--no-session-persistence", "--strict-mcp-config"])
    }

    @Test func codexArguments() {
        let dir = URL(fileURLWithPath: "/tmp/AirTraffic-x", isDirectory: true)
        let args = CodexCLIClient.arguments(model: "gpt-5", directory: dir, hasSchema: true)
        #expect(args == [
            "exec", "--ephemeral", "--skip-git-repo-check",
            "-s", "read-only",
            "-C", "/tmp/AirTraffic-x/",
            "--output-schema", "/tmp/AirTraffic-x/schema.json",
            "-o", "/tmp/AirTraffic-x/answer.txt",
            "-c", "model_reasoning_effort=\"low\"",
            "-m", "gpt-5",
            "-",
        ])
        let withoutModel = CodexCLIClient.arguments(model: "", directory: dir, hasSchema: false)
        #expect(!withoutModel.contains("-m"), "leer = Standard der CLI")
        #expect(!withoutModel.contains("--output-schema"))
        #expect(withoutModel.last == "-", "Prompt über stdin")
    }

    // MARK: Prompt

    @Test func singleTurnPromptIsPlainUserMessage() {
        let (system, prompt) = CLIPrompt.split([.system("A"), .system("B"), .user("Frage")])
        #expect(system == "A\n\nB")
        #expect(prompt == "Frage")
    }

    @Test func multiTurnPromptKeepsHistoryInOrder() {
        let (_, prompt) = CLIPrompt.split([.system("S"), .user("eins"), .assistant("{\"pattern\":\"a\"}"), .user("zwei")])
        let one = try! #require(prompt.range(of: "### USER\neins"))
        let answer = try! #require(prompt.range(of: "### ASSISTANT\n{\"pattern\":\"a\"}"))
        let two = try! #require(prompt.range(of: "### USER (answer this)\nzwei"))
        #expect(one.lowerBound < answer.lowerBound && answer.lowerBound < two.lowerBound)
        #expect(!prompt.contains("S\n"), "Systemprompt geht getrennt")
    }

    @Test func codexPromptCombinesSystemAndUser() {
        let tools = CodexCLIClient.toolInstruction
        #expect(CodexCLIClient.prompt(for: [.system("SYS"), .user("Frage")]) == "\(tools)\n\nSYS\n\n---\n\nFrage")
        #expect(CodexCLIClient.prompt(for: [.user("Frage")]) == "\(tools)\n\n---\n\nFrage")
        // Klare Anweisung ohne Werkzeuge/Shell, nur JSON (§26.6).
        #expect(tools.contains("Do not use any tools") && tools.contains("shell") && tools.contains("JSON"))
    }

    // MARK: Claude: Antwort

    @Test func claudeParsesStructuredOutput() throws {
        let text = try ClaudeCLIClient.parse(ProcessResult(exitCode: 0, stdout: Data(claudeSuccessJSON.utf8)))
        let suggestion = try RegexAssistant.parse(text)
        #expect(suggestion.pattern == #"^https?://example\.com(?:[/?#]|$)"#)
        #expect(suggestion.template == nil)
        #expect(suggestion.explanation == "Trifft example.com.")
    }

    @Test func claudeFallsBackToResultText() throws {
        let json = #"{"type":"result","is_error":false,"result":"```json\n{\"pattern\":\"a\",\"template\":null,\"explanation\":\"x\"}\n```"}"#
        let text = try ClaudeCLIClient.parse(ProcessResult(exitCode: 0, stdout: Data(json.utf8)))
        #expect(try RegexAssistant.parse(text).pattern == "a")
    }

    @Test func claudeErrorsAreMapped() {
        // Echte Fehlerantwort (unbekanntes Modell): Exit 1, is_error, Meldung in `result`.
        let modelError = #"{"type":"result","subtype":"success","is_error":true,"api_error_status":404,"result":"There's an issue with the selected model (x). It may not exist or you may not have access to it."}"#
        #expect(throws: AssistantCLIError.failed(.claude, exitCode: 1, message: "There's an issue with the selected model (x). It may not exist or you may not have access to it.")) {
            try ClaudeCLIClient.parse(ProcessResult(exitCode: 1, stdout: Data(modelError.utf8)))
        }
        let loggedOut = #"{"type":"result","is_error":true,"result":"Not logged in · Please run /login"}"#
        #expect(throws: AssistantCLIError.notLoggedIn(.claude)) {
            try ClaudeCLIClient.parse(ProcessResult(exitCode: 1, stdout: Data(loggedOut.utf8)))
        }
        let unauthorized = #"{"type":"result","is_error":true,"api_error_status":401,"result":"API Error"}"#
        #expect(throws: AssistantCLIError.notLoggedIn(.claude)) {
            try ClaudeCLIClient.parse(ProcessResult(exitCode: 1, stdout: Data(unauthorized.utf8)))
        }
        #expect(throws: AssistantCLIError.failed(.claude, exitCode: 2, message: "boom")) {
            try ClaudeCLIClient.parse(ProcessResult(exitCode: 2, stdout: Data(), stderr: Data("\nboom\n".utf8)))
        }
        #expect(throws: AssistantCLIError.invalidResponse(.claude, "kein JSON-Ergebnis")) {
            try ClaudeCLIClient.parse(ProcessResult(exitCode: 0, stdout: Data("hallo".utf8)))
        }
        #expect(throws: AssistantCLIError.invalidResponse(.claude, "leere Antwort")) {
            try ClaudeCLIClient.parse(ProcessResult(exitCode: 0, stdout: Data(#"{"is_error":false,"result":"  "}"#.utf8)))
        }
    }

    @Test func notLoggedInMessageNamesTheFix() {
        #expect(AssistantCLIError.notLoggedIn(.claude).localizedDescription
            == "Claude Code ist nicht angemeldet – im Terminal „claude“ starten und anmelden.")
        #expect(AssistantCLIError.notFound(.codex).localizedDescription.hasPrefix("Codex wurde nicht gefunden."))
        #expect(AssistantCLIError.timeout(.claude, seconds: 90).localizedDescription.contains("90 s"))
    }

    // MARK: Codex: Antwort

    @Test func codexParsesOutputFile() throws {
        let output = #"{"pattern":"^https?://example\\.com(?=[:/?#]|$)","template":null,"explanation":"x"}"#
        let text = try CodexCLIClient.parse(ProcessResult(exitCode: 0), output: output)
        #expect(try RegexAssistant.parse(text).pattern == #"^https?://example\.com(?=[:/?#]|$)"#)
    }

    @Test func codexErrorsAreMapped() {
        // Echte Fehlerausgabe (unbekanntes Modell): Exit 1, „ERROR: …“ auf stderr, keine -o-Datei.
        let stderr = """
        OpenAI Codex v0.166.0
        --------
        warning: Model metadata for `x` not found.
        ERROR: The 'x' model is not supported when using Codex with a ChatGPT account.
        ERROR: The 'x' model is not supported when using Codex with a ChatGPT account.
        """
        #expect(throws: AssistantCLIError.failed(.codex, exitCode: 1, message: "The 'x' model is not supported when using Codex with a ChatGPT account.")) {
            try CodexCLIClient.parse(ProcessResult(exitCode: 1, stderr: Data(stderr.utf8)), output: nil)
        }
        #expect(throws: AssistantCLIError.notLoggedIn(.codex)) {
            try CodexCLIClient.parse(ProcessResult(exitCode: 1, stderr: Data("ERROR: Not logged in. Run codex login.\n".utf8)), output: nil)
        }
        #expect(throws: AssistantCLIError.invalidResponse(.codex, "leere Antwort")) {
            try CodexCLIClient.parse(ProcessResult(exitCode: 0), output: "\n")
        }
    }

    // MARK: Ablauf mit Fake-Prozess

    @Test func claudeCompleteRunsCLIWithStdinInEmptyTempDir() async throws {
        let runner = FakeProcessRunner(result: ProcessResult(exitCode: 0, stdout: Data(claudeSuccessJSON.utf8)))
        let client = ClaudeCLIClient(transport: claudeTransport(runner: runner))
        let reply = try await client.complete(claudeRequest)
        #expect(try RegexAssistant.parse(reply).explanation == "Trifft example.com.")

        let call = try #require(runner.calls.first)
        #expect(call.invocation.executable.path == "/opt/homebrew/bin/claude")
        #expect(call.invocation.arguments == ClaudeCLIClient.arguments(model: "haiku", systemPrompt: "SYSTEM PROMPT", schema: RegexAssistant.responseSchema))
        #expect(call.stdinText == "Describe example.com")
        #expect(call.invocation.environment?["PATH"] == "/opt/homebrew/bin:/usr/bin")
        #expect(call.invocation.timeout == .seconds(90))
        #expect(call.files.isEmpty, "Arbeitsverzeichnis leer")
        let dir = try #require(call.invocation.currentDirectory)
        #expect(!FileManager.default.fileExists(atPath: dir.path(percentEncoded: false)), "danach aufgeräumt")
    }

    @Test func codexCompleteWritesSchemaAndReadsOutputFile() async throws {
        let answer = #"{"pattern":"a","template":"b","explanation":"c"}"#
        let runner = FakeProcessRunner { invocation in
            let args = invocation.arguments
            let out = args[args.firstIndex(of: "-o")! + 1]
            try Data(answer.utf8).write(to: URL(fileURLWithPath: out))
            return ProcessResult(exitCode: 0, stdout: Data(answer.utf8), stderr: Data("OpenAI Codex v0.166.0\n".utf8))
        }
        let client = CodexCLIClient(transport: codexTransport(runner: runner))
        let request = LLMRequest(model: "", messages: [.system("SYS"), .user("Frage")], responseSchema: RegexAssistant.responseSchema)
        #expect(try await client.complete(request) == answer)

        let call = try #require(runner.calls.first)
        let dir = try #require(call.invocation.currentDirectory)
        #expect(call.invocation.executable.path == "/usr/local/bin/codex")
        #expect(call.invocation.arguments == CodexCLIClient.arguments(model: "", directory: dir, hasSchema: true))
        #expect(call.stdinText == "\(CodexCLIClient.toolInstruction)\n\nSYS\n\n---\n\nFrage")
        let schema = try #require(call.files[CodexCLIClient.schemaFileName])
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data(schema.utf8)) == RegexAssistant.responseSchema.schema)
        #expect(!FileManager.default.fileExists(atPath: dir.path(percentEncoded: false)))
    }

    @Test func timeoutAndLaunchFailureAreMapped() async {
        let slow = FakeProcessRunner { _ in throw ProcessRunnerError.timedOut }
        await #expect(throws: AssistantCLIError.timeout(.claude, seconds: 90)) {
            try await ClaudeCLIClient(transport: claudeTransport(runner: slow)).complete(claudeRequest)
        }
        let broken = FakeProcessRunner { _ in throw ProcessRunnerError.launchFailed("nope") }
        await #expect(throws: AssistantCLIError.launchFailed(.codex, "nope")) {
            try await CodexCLIClient(transport: codexTransport(runner: broken)).complete(claudeRequest)
        }
    }

    @Test func missingBinaryThrowsNotFound() async {
        let runner = FakeProcessRunner(result: ProcessResult(exitCode: 0))
        var transport = claudeTransport(runner: runner)
        transport.locator = fakeLocator(executables: [])
        await #expect(throws: AssistantCLIError.notFound(.claude)) {
            try await ClaudeCLIClient(transport: transport).complete(claudeRequest)
        }
        #expect(runner.calls.isEmpty)
    }

    @Test func regexAssistantWorksOverClaudeCLIIncludingRepair() async throws {
        // Erst ungültiges Muster, dann gültiges – die Reparaturrunde geht mit Verlauf an die CLI.
        let replies = Mutex([
            #"{"type":"result","is_error":false,"structured_output":{"pattern":"(","template":null,"explanation":"kaputt"}}"#,
            #"{"type":"result","is_error":false,"structured_output":{"pattern":"example\\.com","template":null,"explanation":"ok"}}"#,
        ])
        let runner = FakeProcessRunner { _ in
            ProcessResult(exitCode: 0, stdout: Data(replies.withLock { $0.removeFirst() }.utf8))
        }
        let assistant = RegexAssistant(client: ClaudeCLIClient(transport: claudeTransport(runner: runner)), model: "haiku")
        let turn = try await assistant.start(mode: .condition(.url), examples: ["https://example.com/a"], description: "example.com")
        #expect(turn.repaired)
        #expect(turn.validation.isValid)
        #expect(turn.suggestion.pattern == #"example\.com"#)
        #expect(runner.calls.count == 2)
        let second = runner.calls[1]
        #expect(second.stdinText.contains("### ASSISTANT"))
        #expect(second.stdinText.contains("failed local validation"))
        #expect(second.invocation.arguments.contains(RegexAssistant.systemPrompt))
    }

    // MARK: Verbindungstest

    @Test func connectionCheckAcceptsEcho() async throws {
        let ok = FakeLLMClient([#"{"ok":true}"#])
        try await AssistantConnectionCheck.run(client: ok, model: "haiku")
        #expect(ok.requests.first?.responseSchema == AssistantConnectionCheck.schema)
        #expect(ok.requests.first?.model == "haiku")
        await #expect(throws: LLMError.self) {
            try await AssistantConnectionCheck.run(client: FakeLLMClient(["nein"]), model: "")
        }
        #expect(AssistantConnectionCheck.isEcho("Sure: {\"ok\": true}"))
        #expect(!AssistantConnectionCheck.isEcho(#"{"ok":false}"#))
    }

    // MARK: Binärsuche

    @Test func locatorPrefersConfiguredPath() async {
        let locator = fakeLocator(executables: ["/Users/test/bin/claude", "/opt/homebrew/bin/claude"])
        #expect(await locator.locate(.claude, configuredPath: "~/bin/claude")?.path == "/Users/test/bin/claude")
        #expect(locator.locateWithoutShell(.claude, configuredPath: "/Users/test/bin/claude")?.path == "/Users/test/bin/claude")
    }

    @Test func locatorFallsBackWhenConfiguredPathIsMissing() {
        let locator = fakeLocator(executables: ["/opt/homebrew/bin/claude"])
        #expect(locator.locateWithoutShell(.claude, configuredPath: "/nope/claude")?.path == "/opt/homebrew/bin/claude")
    }

    @Test func locatorSearchesKnownDirectoriesInOrder() {
        #expect(CLILocator.searchDirectories(home: "/Users/test/") == [
            "/opt/homebrew/bin", "/usr/local/bin", "/Users/test/.local/bin",
            "/Users/test/.claude/local", "/Users/test/.npm-global/bin", "/Users/test/.bun/bin",
        ])
        let locator = fakeLocator(executables: ["/Users/test/.bun/bin/codex", "/Users/test/.local/bin/codex"])
        #expect(locator.locateWithoutShell(.codex, configuredPath: nil)?.path == "/Users/test/.local/bin/codex")
        #expect(fakeLocator(executables: ["/Users/test/.claude/local/claude"]).locateWithoutShell(.claude, configuredPath: nil)?.path
            == "/Users/test/.claude/local/claude")
    }

    @Test func locatorAsksLoginShellLast() async {
        let viaShell = fakeLocator(executables: ["/Users/test/.volta/bin/codex"], shell: "/Users/test/.volta/bin/codex")
        #expect(viaShell.locateWithoutShell(.codex, configuredPath: nil) == nil)
        #expect(await viaShell.locate(.codex, configuredPath: nil)?.path == "/Users/test/.volta/bin/codex")
        // Shell meldet etwas, das nicht ausführbar ist (z. B. Alias-Text) → nicht gefunden.
        let alias = fakeLocator(executables: [], shell: "alias codex=foo")
        #expect(await alias.locate(.codex, configuredPath: nil) == nil)
    }

    @Test func loginShellOutputIsExtractedBetweenMarkers() {
        #expect(LoginShell.extract(from: "Welcome!\n__AIRTRAFFIC__/opt/homebrew/bin:/usr/bin__AIRTRAFFIC__\nbye") == "/opt/homebrew/bin:/usr/bin")
        #expect(LoginShell.extract(from: "__AIRTRAFFIC____AIRTRAFFIC__") == nil)
        #expect(LoginShell.extract(from: "kein Marker") == nil)
    }

    @Test func loginShellUsesShellWithLoginFlag() async throws {
        let runner = FakeProcessRunner(result: ProcessResult(exitCode: 0, stdout: Data("motd\n__AIRTRAFFIC__/a:/b__AIRTRAFFIC__".utf8)))
        let shell = LoginShell(runner: runner, shellPath: "/bin/zsh")
        #expect(await shell.path() == "/a:/b")
        #expect(await shell.path() == "/a:/b")
        #expect(runner.calls.count == 1, "PATH wird zwischengespeichert")
        let call = try #require(runner.calls.first)
        #expect(call.invocation.executable.path == "/bin/zsh")
        #expect(call.invocation.arguments.first == "-lc")
        #expect(call.invocation.timeout == .seconds(3))
        #expect(await shell.commandPath("rm -rf /") == nil, "nur einfache Namen")
    }

    @Test func environmentUsesLoginPathAndDropsAPIKey() {
        let exe = URL(fileURLWithPath: "/Users/test/.bun/bin/claude")
        let env = CLITransport.environment(
            base: ["PATH": "/usr/bin:/bin", "HOME": "/Users/test", "ANTHROPIC_API_KEY": "sk-x"],
            loginPath: "/opt/homebrew/bin:/usr/bin:/bin",
            executable: exe,
            home: "/Users/test"
        )
        #expect(env["ANTHROPIC_API_KEY"] == nil, "Abo statt API-Key")
        #expect(env["HOME"] == "/Users/test")
        #expect(env["PATH"] == "/Users/test/.bun/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin")

        let fallback = CLITransport.environment(base: ["PATH": "/usr/bin:/bin"], loginPath: nil, executable: exe, home: "/Users/test")
        let parts = fallback["PATH"]!.split(separator: ":").map(String.init)
        #expect(parts.first == "/Users/test/.bun/bin")
        #expect(parts.contains("/opt/homebrew/bin"))
        #expect(Set(parts).count == parts.count, "keine Dubletten")
    }

    @Test func versionIsParsed() {
        #expect(CLITransport.parseVersion("2.1.318 (Claude Code)\n") == "2.1.318")
        #expect(CLITransport.parseVersion("codex-cli 0.166.0") == "0.166.0")
        #expect(CLITransport.parseVersion("unbekannt") == nil)
    }

    // MARK: Echter Prozess

    @Test func systemRunnerPassesStdinAndCollectsOutput() async throws {
        let runner = SystemProcessRunner()
        let result = try await runner.run(ProcessInvocation(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "cat; echo fehler >&2; exit 3"],
            stdin: Data("hallo".utf8),
            timeout: .seconds(10)
        ))
        #expect(result.exitCode == 3)
        #expect(result.stdoutText == "hallo")
        #expect(result.stderrText == "fehler\n")
    }

    @Test func systemRunnerHandlesLargeOutput() async throws {
        let big = String(repeating: "x", count: 300_000)
        let result = try await SystemProcessRunner().run(ProcessInvocation(
            executable: URL(fileURLWithPath: "/bin/cat"),
            arguments: [],
            stdin: Data(big.utf8),
            timeout: .seconds(10)
        ))
        #expect(result.stdout.count == 300_000)
    }

    @Test func systemRunnerTimesOut() async {
        let start = ContinuousClock.now
        await #expect(throws: ProcessRunnerError.timedOut) {
            try await SystemProcessRunner().run(ProcessInvocation(
                executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: .milliseconds(300)
            ))
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func systemRunnerStopsOnCancel() async {
        let task = Task {
            try await SystemProcessRunner().run(ProcessInvocation(
                executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: .seconds(30)
            ))
        }
        try? await Task.sleep(for: .milliseconds(200))
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func systemRunnerReportsLaunchFailure() async {
        await #expect(throws: ProcessRunnerError.self) {
            try await SystemProcessRunner().run(ProcessInvocation(
                executable: URL(fileURLWithPath: "/nope/missing"), arguments: [], timeout: .seconds(1)
            ))
        }
    }
}

@Suite("Anbieter-Einstellungen (§16.1)")
struct AssistantProviderSettingsTests {
    @Test func providerRoundTripAndDefaults() throws {
        var config = Config()
        #expect(config.assistantProvider == .openRouter)
        #expect(config.assistantClaudeModel == "haiku")
        #expect(config.assistantCodexModel == "")

        config.assistant = AssistantSettings(provider: .claudeCLI, model: "openai/gpt-x", claudeModel: "sonnet", codexModel: "gpt-5", claudePath: "/x/claude")
        let data = try ConfigStore.encode(config)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""provider" : "claudeCLI""#))
        #expect(!text.contains("codexPath"), "nil wird nicht geschrieben")
        let decoded = try ConfigStore.decode(data)
        #expect(decoded == config)
        #expect(decoded.assistantProvider == .claudeCLI)
        #expect(decoded.assistantModel == "openai/gpt-x", "OpenRouter-Modell bleibt getrennt")
        #expect(decoded.assistantModel(for: .claudeCLI) == "sonnet")
        #expect(decoded.assistantModel(for: .codexCLI) == "gpt-5")
        #expect(decoded.assistant?.path(for: .claude) == "/x/claude")
    }

    @Test func missingOrUnknownProviderMeansOpenRouter() throws {
        let old = #"{"schemaVersion":1,"assistant":{"model":"m"},"defaultAction":{"type":"prompt","scope":"all"}}"#
        let config = try ConfigStore.decode(Data(old.utf8))
        #expect(config.assistantProvider == .openRouter)
        #expect(config.assistant?.provider == nil)
        let future = #"{"schemaVersion":1,"assistant":{"provider":"somethingNew","model":"m"},"defaultAction":{"type":"prompt","scope":"all"}}"#
        let tolerant = try ConfigStore.decode(Data(future.utf8))
        #expect(tolerant.assistantProvider == .openRouter)
        #expect(tolerant.assistant?.model == "m")
    }

    @Test func normalizedDropsDefaults() {
        let settings = AssistantSettings(provider: .openRouter, model: " ", claudeModel: "", codexModel: " gpt-5 ", claudePath: "")
        #expect(settings.normalized() == AssistantSettings(codexModel: "gpt-5"))
        #expect(AssistantSettings(provider: .openRouter).normalized().isEmpty)
        #expect(!AssistantSettings(provider: .codexCLI).normalized().isEmpty)
    }

    @Test func providerArgumentsAndLabels() {
        #expect(AssistantProvider(argument: "claude") == .claudeCLI)
        #expect(AssistantProvider(argument: "OpenRouter") == .openRouter)
        #expect(AssistantProvider(argument: "codex") == .codexCLI)
        #expect(AssistantProvider(argument: "gemini") == nil)
        #expect(AssistantProvider.allCases.map(\.pickerTitle) == ["OpenRouter (API-Key)", "Claude-Abo (Claude Code)", "ChatGPT-Abo (Codex)"])
        #expect(AssistantProvider.codexCLI.cli == .codex)
        #expect(AssistantProvider.openRouter.cli == nil)
        var config = Config()
        config.assistant = AssistantSettings(provider: .codexCLI)
        #expect(config.assistantModelLabel(for: .codexCLI) == "Standardmodell")
        #expect(config.assistantModelLabel(for: .claudeCLI) == "haiku")
    }
}
