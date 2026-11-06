import Foundation

// MARK: - CLI

/// Lokal installierte KI-CLI, die ein bestehendes Abo nutzt (§16).
public enum AssistantCLI: String, Sendable, CaseIterable, Codable {
    case claude, codex

    /// Name der Binärdatei.
    public var executableName: String { rawValue }

    /// Konfigurierter Pfad ist nur gültig, wenn der Dateiname exakt `claude` bzw. `codex` ist (§26.6).
    /// Ein Symlink mit diesem Namen ist erlaubt; wohin er zeigt, spielt keine Rolle.
    public func accepts(path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasSuffix("/") else { return false }
        return (trimmed as NSString).lastPathComponent == executableName
    }

    /// Hinweis in den Einstellungen bei ungültigem Pfad.
    public var invalidPathHint: String {
        "Pfad ungültig – Datei muss \(executableName) heißen"
    }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }

    /// Kurzer Installationshinweis für „Nicht gefunden“.
    public var installHint: String {
        switch self {
        case .claude: "Installieren mit „npm install -g @anthropic-ai/claude-code“, danach im Terminal „claude“ starten und anmelden."
        case .codex: "Installieren mit „npm install -g @openai/codex“, danach im Terminal „codex login“ ausführen."
        }
    }

    /// Hinweis, wenn die CLI nicht angemeldet ist.
    public var loginHint: String {
        switch self {
        case .claude: "Claude Code ist nicht angemeldet – im Terminal „claude“ starten und anmelden."
        case .codex: "Codex ist nicht angemeldet – im Terminal „codex login“ ausführen."
        }
    }
}

// MARK: - Fehler

/// Fehler der CLI-Anbieter, deutsch beschrieben. Enthält nie Prompt oder URLs, nur die Meldung der CLI.
public enum AssistantCLIError: Error, LocalizedError, Equatable, Sendable {
    case notFound(AssistantCLI)
    case notLoggedIn(AssistantCLI)
    case launchFailed(AssistantCLI, String)
    case timeout(AssistantCLI, seconds: Int)
    case failed(AssistantCLI, exitCode: Int32, message: String?)
    case invalidResponse(AssistantCLI, String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let cli):
            "\(cli.displayName) wurde nicht gefunden. \(cli.installHint)"
        case .notLoggedIn(let cli):
            cli.loginHint
        case .launchFailed(let cli, let detail):
            "\(cli.displayName) ließ sich nicht starten: \(detail)"
        case .timeout(let cli, let seconds):
            "Zeitüberschreitung: \(cli.displayName) hat nicht innerhalb von \(seconds) s geantwortet."
        case .failed(let cli, let code, let message):
            if let message, !message.isEmpty { "\(cli.displayName) meldet einen Fehler: \(message)" }
            else { "\(cli.displayName) wurde mit Fehlercode \(code) beendet." }
        case .invalidResponse(let cli, let detail):
            "Antwort von \(cli.displayName) nicht lesbar: \(detail)"
        }
    }

    /// Erkennt „nicht angemeldet“ in einer Fehlermeldung der CLI.
    static func looksLikeLoginProblem(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["not logged in", "please run /login", "log in", "login", "logged out", "unauthorized",
                "authentication", "invalid api key", "oauth token", "401"]
            .contains { lower.contains($0) }
    }

    /// Meldung kürzen (eine Zeile, max. 300 Zeichen).
    static func condensed(_ text: String) -> String? {
        let line = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !line.isEmpty else { return nil }
        return line.count > 300 ? String(line.prefix(300)) + "…" : line
    }
}

// MARK: - Prozesse

public struct ProcessInvocation: Sendable, Equatable {
    public var executable: URL
    public var arguments: [String]
    public var stdin: Data?
    public var environment: [String: String]?
    public var currentDirectory: URL?
    public var timeout: Duration

    public init(
        executable: URL,
        arguments: [String],
        stdin: Data? = nil,
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        timeout: Duration
    ) {
        self.executable = executable
        self.arguments = arguments
        self.stdin = stdin
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.timeout = timeout
    }
}

public struct ProcessResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data

    public init(exitCode: Int32, stdout: Data = Data(), stderr: Data = Data()) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

public enum ProcessRunnerError: Error, Equatable, Sendable {
    case launchFailed(String)
    case timedOut
}

/// Startet Prozesse; `SystemProcessRunner` in der App, Fakes in Tests.
public protocol ProcessRunner: Sendable {
    /// Wirft `ProcessRunnerError` oder `CancellationError` (Prozess wird dann beendet).
    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult
}

/// `Foundation.Process` mit Timeout und Abbruch (SIGTERM, nach 2 s SIGKILL).
public struct SystemProcessRunner: ProcessRunner {
    public init() {}

    public func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        let job = ProcessJob(invocation)
        return try await withTaskCancellationHandler {
            try await job.start()
        } onCancel: {
            job.cancel()
        }
    }
}

/// Ein laufender Prozess. Zustand hinter einem Lock, damit Abbruch und Timeout aus anderen Threads greifen.
///
/// §27 K15: Der Start wird unter dem Lock markiert und nach `run()` erneut auf Abbruch geprüft (ein
/// Abbruch zwischen Prüfung und Start beendet den Prozess sofort). Zeitlimit und Abbruch zählen nur,
/// solange der Prozess läuft – endet er vorher, gilt sein Ergebnis, auch wenn ein Enkel die Ausgabe
/// noch offen hält. §27 K1: Schreiben auf stdin eines schon beendeten Kinds ergibt EPIPE statt SIGPIPE.
private final class ProcessJob: @unchecked Sendable {
    private enum Phase { case notStarted, starting, running, finished }
    private enum StopReason { case cancelled, timedOut }

    private let invocation: ProcessInvocation
    private let process = Process()
    private let lock = NSLock()
    private var phase = Phase.notStarted
    private var stopReason: StopReason?
    private var stdoutData = Data()
    private var stderrData = Data()

    init(_ invocation: ProcessInvocation) {
        self.invocation = invocation
    }

    func start() async throws -> ProcessResult {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try self.runBlocking() })
            }
        }
    }

    private func runBlocking() throws -> ProcessResult {
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = invocation.executable
        process.arguments = invocation.arguments
        if let environment = invocation.environment { process.environment = environment }
        if let dir = invocation.currentDirectory { process.currentDirectoryURL = dir }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Kind beendet, bevor es stdin gelesen hat → write() liefert EPIPE, kein SIGPIPE für uns (§27 K1).
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        lock.lock()
        if stopReason == .cancelled { lock.unlock(); throw CancellationError() }
        phase = .starting
        lock.unlock()

        do {
            try process.run()
        } catch {
            lock.withLock { phase = .finished }
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
        }

        lock.lock()
        phase = .running
        let cancelledWhileStarting = stopReason == .cancelled
        lock.unlock()
        if cancelledWhileStarting { terminate() }

        let group = DispatchGroup()
        read(stdoutPipe, group: group) { job, data in job.stdoutData = data }
        read(stderrPipe, group: group) { job, data in job.stderrData = data }

        // stdin getrennt schreiben, damit ein voller Puffer nicht blockiert. EPIPE ist ein normaler Fehler.
        let input = invocation.stdin ?? Data()
        DispatchQueue.global(qos: .userInitiated).async {
            let handle = stdinPipe.fileHandleForWriting
            try? handle.write(contentsOf: input)
            try? handle.close()
        }

        let seconds = Double(invocation.timeout.components.seconds)
            + Double(invocation.timeout.components.attoseconds) / 1e18
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.stop(because: .timedOut)
        }

        process.waitUntilExit()
        lock.withLock { phase = .finished }
        group.wait()

        lock.lock()
        defer { lock.unlock() }
        switch stopReason {
        case .cancelled: throw CancellationError()
        case .timedOut: throw ProcessRunnerError.timedOut
        case nil: return ProcessResult(exitCode: process.terminationStatus, stdout: stdoutData, stderr: stderrData)
        }
    }

    private func read(_ pipe: Pipe, group: DispatchGroup, store: @escaping @Sendable (ProcessJob, Data) -> Void) {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            self.lock.lock()
            store(self, data)
            self.lock.unlock()
            group.leave()
        }
    }

    func cancel() { stop(because: .cancelled) }

    private func stop(because reason: StopReason) {
        lock.lock()
        // Schon beendet: Ergebnis gilt. Noch nicht gestartet/startend: `runBlocking` prüft danach selbst.
        guard stopReason == nil, phase != .finished else { lock.unlock(); return }
        if reason == .timedOut, phase != .running { lock.unlock(); return }
        stopReason = reason
        let running = phase == .running
        lock.unlock()
        if running { terminate() }
    }

    /// SIGTERM, nach 2 s SIGKILL.
    private func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

// MARK: - Login-Shell

/// Fragt die Login-Shell (`$SHELL -lc …`, Timeout 3 s). Ergebnis für `PATH` wird zwischengespeichert.
public actor LoginShell {
    public static let shared = LoginShell()

    public static let timeout: Duration = .seconds(3)
    private static let marker = "__AIRTRAFFIC__"

    private let runner: any ProcessRunner
    private let shellPath: String
    private var cachedPath: String?

    public init(
        runner: any ProcessRunner = SystemProcessRunner(),
        shellPath: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    ) {
        self.runner = runner
        self.shellPath = shellPath.isEmpty ? "/bin/zsh" : shellPath
    }

    /// Führt `script` aus und liefert, was zwischen zwei Markern ausgegeben wurde
    /// (Profil-Skripte dürfen davor und danach beliebig drucken).
    public func evaluate(_ expression: String) async -> String? {
        let script = "printf '\(Self.marker)%s\(Self.marker)' \(expression)"
        let invocation = ProcessInvocation(
            executable: URL(fileURLWithPath: shellPath),
            arguments: ["-lc", script],
            timeout: Self.timeout
        )
        guard let result = try? await runner.run(invocation), result.exitCode == 0 else { return nil }
        return Self.extract(from: result.stdoutText)
    }

    static func extract(from output: String) -> String? {
        let parts = output.components(separatedBy: marker)
        guard parts.count >= 3 else { return nil }
        let value = parts[parts.count - 2].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// `PATH` der Login-Shell; nur ein gefundener Wert wird zwischengespeichert (§27 A17), ein
    /// Fehlschlag (Zeitlimit, kaputtes Profil) wird beim nächsten Mal erneut versucht.
    public func path() async -> String? {
        if let cachedPath { return cachedPath }
        let value = await evaluate("\"$PATH\"")
        if let value { cachedPath = value }
        return value
    }

    /// Vergisst den zwischengespeicherten `PATH` (App wieder aktiv, „Erneut suchen“).
    public func invalidateCache() {
        cachedPath = nil
    }

    /// `command -v <name>` in der Login-Shell.
    public func commandPath(_ name: String) async -> String? {
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return await evaluate("\"$(command -v \(name))\"")
    }
}

// MARK: - Binärsuche

/// Sucht eine CLI: konfigurierter Pfad → bekannte Verzeichnisse → Login-Shell (§16.2).
public struct CLILocator: Sendable {
    public var homeDirectory: String
    public var isExecutable: @Sendable (String) -> Bool
    /// `command -v` in der Login-Shell; `nil` = nicht gefunden.
    public var shellLookup: @Sendable (String) async -> String?

    public init(
        homeDirectory: String,
        isExecutable: @escaping @Sendable (String) -> Bool,
        shellLookup: @escaping @Sendable (String) async -> String?
    ) {
        self.homeDirectory = homeDirectory
        self.isExecutable = isExecutable
        self.shellLookup = shellLookup
    }

    public static let system = CLILocator(
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false),
        isExecutable: { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
                && FileManager.default.isExecutableFile(atPath: path)
        },
        shellLookup: { name in await LoginShell.shared.commandPath(name) }
    )

    /// Feste Suchorte in dieser Reihenfolge.
    public static func searchDirectories(home: String) -> [String] {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        return [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.claude/local",
            "\(home)/.npm-global/bin",
            "\(home)/.bun/bin",
        ]
    }

    private func expand(_ path: String) -> String {
        if path == "~" { return homeDirectory }
        if path.hasPrefix("~/") { return homeDirectory + "/" + path.dropFirst(2) }
        return path
    }

    /// Ohne Login-Shell (schnell, synchron): konfigurierter Pfad, dann feste Orte.
    public func locateWithoutShell(_ cli: AssistantCLI, configuredPath: String?) -> URL? {
        // Ungültiger Dateiname (§26.6) → ignoriert, automatische Suche.
        if let configured = configuredPath?.trimmingCharacters(in: .whitespacesAndNewlines), !configured.isEmpty,
           cli.accepts(path: configured) {
            let path = expand(configured)
            if isExecutable(path) { return URL(fileURLWithPath: path) }
        }
        for dir in Self.searchDirectories(home: homeDirectory) {
            let path = dir + "/" + cli.executableName
            if isExecutable(path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    /// Vollständige Suche inkl. Login-Shell.
    public func locate(_ cli: AssistantCLI, configuredPath: String?) async -> URL? {
        if let url = locateWithoutShell(cli, configuredPath: configuredPath) { return url }
        if let path = await shellLookup(cli.executableName), path.hasPrefix("/"), isExecutable(path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}

// MARK: - Transport

/// Gemeinsamer Unterbau der CLI-Clients: Binärdatei finden, Umgebung bauen, Prozess starten.
public struct CLITransport: Sendable {
    public static let defaultTimeout: Duration = .seconds(90)

    public var cli: AssistantCLI
    public var configuredPath: String?
    public var runner: any ProcessRunner
    public var locator: CLILocator
    /// `nil` = Prozessumgebung mit `PATH` der Login-Shell.
    public var environment: [String: String]?
    public var timeout: Duration

    public init(
        cli: AssistantCLI,
        configuredPath: String? = nil,
        runner: any ProcessRunner = SystemProcessRunner(),
        locator: CLILocator = .system,
        environment: [String: String]? = nil,
        timeout: Duration = CLITransport.defaultTimeout
    ) {
        self.cli = cli
        self.configuredPath = configuredPath
        self.runner = runner
        self.locator = locator
        self.environment = environment
        self.timeout = timeout
    }

    /// Umgebung für die CLI: Prozessumgebung, `PATH` aus der Login-Shell (CLIs brauchen u. a. `node`),
    /// Verzeichnis der Binärdatei vorn. `ANTHROPIC_API_KEY` fällt weg, damit Claude Code das Abo nutzt
    /// statt eines API-Keys mit Kosten.
    public static func environment(
        base: [String: String],
        loginPath: String?,
        executable: URL,
        home: String
    ) -> [String: String] {
        var env = base
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        var parts = (loginPath ?? base["PATH"] ?? "").split(separator: ":").map(String.init)
        if loginPath == nil {
            parts += CLILocator.searchDirectories(home: home)
        }
        parts.insert(executable.deletingLastPathComponent().path(percentEncoded: false), at: 0)
        parts += ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        let unique = parts
            .map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        env["PATH"] = unique.joined(separator: ":")
        return env
    }

    func resolveExecutable() async throws -> URL {
        guard let url = await locator.locate(cli, configuredPath: configuredPath) else {
            throw AssistantCLIError.notFound(cli)
        }
        return url
    }

    /// Startet die CLI im angegebenen Arbeitsverzeichnis; Fehler des Runners → `AssistantCLIError`.
    func run(arguments: [String], stdin: Data, in directory: URL) async throws -> ProcessResult {
        let executable = try await resolveExecutable()
        let env: [String: String]
        if let environment {
            env = environment
        } else {
            env = Self.environment(
                base: ProcessInfo.processInfo.environment,
                loginPath: await LoginShell.shared.path(),
                executable: executable,
                home: locator.homeDirectory
            )
        }
        let invocation = ProcessInvocation(
            executable: executable,
            arguments: arguments,
            stdin: stdin,
            environment: env,
            currentDirectory: directory,
            timeout: timeout
        )
        do {
            return try await runner.run(invocation)
        } catch ProcessRunnerError.timedOut {
            throw AssistantCLIError.timeout(cli, seconds: Int(timeout.components.seconds))
        } catch ProcessRunnerError.launchFailed(let detail) {
            throw AssistantCLIError.launchFailed(cli, detail)
        }
    }

    /// Version der CLI (`--version`), z. B. „2.1.318“; `nil`, wenn nicht ermittelbar.
    /// Startet nur Dateien namens `claude` oder `codex` (§26.6).
    public static func version(of executable: URL, runner: any ProcessRunner = SystemProcessRunner()) async -> String? {
        let name = executable.lastPathComponent
        guard AssistantCLI.allCases.contains(where: { $0.executableName == name }) else { return nil }
        let invocation = ProcessInvocation(executable: executable, arguments: ["--version"], timeout: .seconds(5))
        guard let result = try? await runner.run(invocation), result.exitCode == 0 else { return nil }
        return parseVersion(result.stdoutText)
    }

    /// Erste Versionsnummer `x.y[.z…]` im Text.
    public static func parseVersion(_ text: String) -> String? {
        guard let range = text.range(of: #"\d+(\.\d+)+"#, options: .regularExpression) else { return nil }
        return String(text[range])
    }
}

// MARK: - Gemeinsame Hilfen

enum CLIPrompt {
    /// Leeres, eindeutiges Arbeitsverzeichnis; wird nach dem Aufruf gelöscht.
    static func makeTemporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "AirTraffic-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Systemnachrichten (zusammengefügt) und der Gesprächsverlauf als ein Prompt.
    /// Die CLIs sind einschüssig; frühere Runden gehen als Verlauf mit.
    static func split(_ messages: [ChatMessage]) -> (system: String, prompt: String) {
        let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        let turns = messages.filter { $0.role != .system }
        guard turns.count > 1 else { return (system, turns.first?.content ?? "") }
        var lines = ["This conversation continues. Earlier turns are listed in order; answer only the last user message."]
        for (index, turn) in turns.enumerated() {
            let label = turn.role == .assistant ? "ASSISTANT" : "USER"
            let marker = index == turns.count - 1 ? "\(label) (answer this)" : label
            lines.append("### \(marker)\n\(turn.content)")
        }
        return (system, lines.joined(separator: "\n\n"))
    }

    static func encodeJSON(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
