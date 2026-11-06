import AirTrafficCore
import Foundation

// `airtraffic` (SPEC §24): dünne Hülle um `AgentCLI` und `MCPServer` aus dem Core.
// Liest/schreibt nur die Konfiguration (AIRTRAFFIC_CONFIG_PATH beachtet); kein Netzwerk,
// kein Schlüsselbund, öffnet nichts.

setvbuf(stdout, nil, _IOLBF, 0)
// Leser weg (z. B. `airtraffic rules list | head -1`, MCP-Client beendet): EPIPE statt SIGPIPE (§27 K1).
signal(SIGPIPE, SIG_IGN)

/// Schreibt eine Zeile; ist der Leser weg, endet das Tool still.
func emit(_ text: String, to handle: FileHandle, exitCode: Int32) {
    do {
        try handle.write(contentsOf: Data(text.utf8))
    } catch {
        exit(exitCode)
    }
}

let version = ToolVersion.current
let api = AgentAPI(store: .makeDefault(), resolver: WorkspaceAppResolver())
let arguments = Array(CommandLine.arguments.dropFirst())

if arguments == ["mcp"] {
    let server = MCPServer(api: api, version: version)
    try? FileHandle.standardError.write(contentsOf: Data("airtraffic \(version): MCP-Server bereit (stdio), Konfiguration \(api.store.fileURL.path(percentEncoded: false))\n".utf8))
    while let line = readLine(strippingNewline: true) {
        if let response = server.handle(line: line) {
            emit(response + "\n", to: .standardOutput, exitCode: 0)
        }
    }
    exit(0)
}

let io = AgentCLI.IO(
    readStdin: {
        guard isatty(STDIN_FILENO) == 0 else { return nil }
        return FileHandle.standardInput.readDataToEndOfFile()
    },
    out: { emit($0 + "\n", to: .standardOutput, exitCode: AgentCLI.ExitCode.ioError) },
    err: { try? FileHandle.standardError.write(contentsOf: Data(($0 + "\n").utf8)) }
)
exit(AgentCLI(api: api, version: version).run(arguments, io: io))
