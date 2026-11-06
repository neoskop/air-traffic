import Foundation
import Testing
@testable import AirTrafficCore

@Suite("MCP-Server (§24.6)")
struct MCPServerTests {
    static let toolNames: Set<String> = [
        "describe_rule_format", "list_rules", "get_rule", "create_rule", "update_rule", "move_rule",
        "set_rule_enabled", "delete_rule", "check_url", "list_browsers", "get_settings",
    ]

    func server(_ temp: TempConfig) -> MCPServer {
        MCPServer(api: temp.api(), version: "1.8 (6)")
    }

    func request(_ server: MCPServer, id: JSONValue = 1, _ method: String, _ params: JSONValue? = nil) throws -> JSONValue {
        var message: [String: JSONValue] = ["jsonrpc": "2.0", "id": id, "method": .string(method)]
        if let params { message["params"] = params }
        let line = try #require(server.handle(line: JSONValue.object(message).jsonString()))
        #expect(!line.contains("\n"), "eine Nachricht pro Zeile")
        return try #require(JSONValue.parse(line))
    }

    @Test func initializeNegotiatesVersion() throws {
        let temp = try TempConfig()
        defer { temp.remove() }
        let server = server(temp)
        let known = try request(server, "initialize", ["protocolVersion": "2024-11-05", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]])
        #expect(known["id"] == 1)
        #expect(known["result"]?["protocolVersion"] == "2024-11-05")
        #expect(known["result"]?["serverInfo"]?["name"] == "air-traffic")
        #expect(known["result"]?["serverInfo"]?["version"] == "1.8 (6)")
        #expect(known["result"]?["capabilities"]?["tools"] != nil)
        #expect(known["result"]?["instructions"]?.stringValue?.contains("describe_rule_format") == true)

        let unknown = try request(server, id: "abc", "initialize", ["protocolVersion": "1999-01-01"])
        #expect(unknown["id"] == "abc")
        #expect(unknown["result"]?["protocolVersion"] == "2025-06-18")
    }

    @Test func notificationsGetNoAnswerPingDoes() throws {
        let temp = try TempConfig()
        defer { temp.remove() }
        let server = server(temp)
        #expect(server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(server.handle(line: "") == nil)
        let ping = try request(server, id: 7, "ping")
        #expect(ping["result"] == [:])
    }

    @Test func toolsListHasAllToolsWithSchemaAndAnnotations() throws {
        let temp = try TempConfig()
        defer { temp.remove() }
        let response = try request(server(temp), "tools/list")
        let tools = try #require(response["result"]?["tools"]?.arrayValue)
        #expect(Set(tools.compactMap { $0["name"]?.stringValue }) == Self.toolNames)
        for tool in tools {
            let name = tool["name"]?.stringValue ?? ""
            #expect(tool["inputSchema"]?["type"] == "object", "\(name)")
            #expect(tool["description"]?.stringValue?.isEmpty == false, "\(name)")
            let readOnly = tool["annotations"]?["readOnlyHint"]?.boolValue
            #expect(readOnly != nil, "\(name)")
            let writes = ["create_rule", "update_rule", "move_rule", "set_rule_enabled", "delete_rule"].contains(name)
            #expect(readOnly == !writes, "\(name)")
            #expect(tool["annotations"]?["destructiveHint"]?.boolValue == (writes ? name == "delete_rule" : nil), "\(name)")
        }
    }

    @Test func toolsCallSuccess() throws {
        let temp = try TempConfig()
        defer { temp.remove() }
        let server = server(temp)
        let created = try request(server, "tools/call", [
            "name": "create_rule",
            "arguments": [
                "rule": ["name": "Figma", "conditions": [["type": "host", "op": "endsWith", "value": "figma.com"]],
                         "action": ["type": "open", "app": "Figma"], "testURL": "https://www.figma.com/file/1"],
                "position": 1,
            ],
        ])
        let result = try #require(created["result"])
        #expect(result["isError"] == false)
        #expect(result["structuredContent"]?["rule"]?["name"] == "Figma")
        // Neu angelegt → wartet auf Freigabe (§26.1); die Vorschau nach Freigabe greift.
        #expect(result["structuredContent"]?["pendingApproval"] == true)
        #expect(result["structuredContent"]?["check"]?["status"] == "pendingMatch")
        #expect(result["structuredContent"]?["checkAfterApproval"]?["status"] == "wins")
        let text = try #require(result["content"]?.arrayValue?.first?["text"]?.stringValue)
        #expect(JSONValue.parse(text) == result["structuredContent"])
        #expect(try temp.load().rules.first?.name == "Figma")

        // check_url ignoriert die wartende Regel.
        let check = try request(server, "tools/call", ["name": "check_url", "arguments": ["url": "https://www.figma.com/file/1"]])
        #expect(check["result"]?["structuredContent"]?["decision"]?["matchedRule"]?["name"] == "Alles Mögliche")
        #expect(check["result"]?["structuredContent"]?["rules"]?.arrayValue?.first?["status"] == "pendingMatch")
    }

    @Test func toolsCallBusinessErrorIsToolError() throws {
        let temp = try TempConfig()
        defer { temp.remove() }
        let server = server(temp)
        let invalid = try request(server, "tools/call", [
            "name": "create_rule", "arguments": ["rule": ["name": "X", "action": ["type": "open", "app": "Netscape"]]],
        ])
        #expect(invalid["error"] == nil)
        #expect(invalid["result"]?["isError"] == true)
        #expect(invalid["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("action.app") == true)

        let missing = try request(server, "tools/call", ["name": "get_rule", "arguments": ["ref": "#99"]])
        #expect(missing["result"]?["isError"] == true)

        let extra = try request(server, "tools/call", ["name": "list_rules", "arguments": ["verbose": true]])
        #expect(extra["result"]?["isError"] == true)
        #expect(try temp.load().rules.count == 3)
    }

    @Test func protocolErrors() throws {
        let temp = try TempConfig()
        defer { temp.remove() }
        let server = server(temp)
        #expect(try request(server, "resources/list")["error"]?["code"] == -32601)
        #expect(try request(server, "tools/call", ["name": "format_disk"])["error"]?["code"] == -32602)
        let parseLine = try #require(server.handle(line: "{nope"))
        let parse = try #require(JSONValue.parse(parseLine))
        #expect(parse["error"]?["code"] == -32700)
        #expect(parse["id"] == .null)
        let invalidLine = try #require(server.handle(line: #"{"id":3,"method":"ping"}"#))
        let invalid = try #require(JSONValue.parse(invalidLine))
        #expect(invalid["error"]?["code"] == -32600)
    }
}

@Suite("Kommandozeile (§24.3)")
struct AgentCLITests {
    final class Capture: @unchecked Sendable {
        var out = ""
        var err = ""
    }

    func run(_ args: [String], stdin: String? = nil, temp: TempConfig) -> (code: Int32, out: String, err: String) {
        let capture = Capture()
        let io = AgentCLI.IO(
            readStdin: { stdin.map { Data($0.utf8) } },
            out: { capture.out += $0 + "\n" },
            err: { capture.err += $0 + "\n" }
        )
        let code = AgentCLI(api: temp.api(), version: "1.8").run(args, io: io)
        return (code, capture.out, capture.err)
    }

    @Test func addWithFlags() throws {
        let temp = try TempConfig()
        defer { temp.remove() }
        let result = run([
            "rules", "add", "--name", "Docs", "--host", "docs.example.com", "--open", "Safari",
            "--rewrite", "^http:", "https:", "--test-url", "https://docs.example.com/a", "--at", "1", "--json",
        ], temp: temp)
        #expect(result.code == 0, "\(result.err)")
        let json = try #require(JSONValue.parse(result.out))
        #expect(json["rule"]?["position"] == 1)
        let rule = try temp.load().rules[0]
        #expect(rule.name == "Docs")
        #expect(rule.conditions == [.host(TextMatch(op: .equals, value: "docs.example.com"))])
        #expect(rule.rewrites == [Rewrite(pattern: "^http:", template: "https:")])
        #expect(rule.action == .open(FakeAppResolver.safari))
    }

    @Test func addFromStdinAndUpdate() throws {
        let temp = try TempConfig()
        defer { temp.remove() }
        let add = run(["rules", "add"], stdin: #"{"name": "Neu", "action": {"type": "prompt", "scope": "running"}}"#, temp: temp)
        #expect(add.code == 0)
        #expect(add.out.contains("Angelegt: #4 Neu"))
        let update = run(["rules", "update", "Neu", "--dry-run"], stdin: #"{"enabled": false}"#, temp: temp)
        #expect(update.code == 0)
        #expect(update.out.contains("Probelauf"))
        #expect(try temp.load().rules[3].enabled)
    }

    @Test func exitCodes() throws {
        let temp = try TempConfig()
        defer { temp.remove() }
        #expect(run(["rules", "frobnicate"], temp: temp).code == AgentCLI.ExitCode.usage)
        #expect(run(["rules", "add"], temp: temp).code == AgentCLI.ExitCode.usage)
        #expect(run(["rules", "add"], stdin: "{kaputt", temp: temp).code == AgentCLI.ExitCode.dataError)
        let notFound = run(["rules", "get", "#9"], temp: temp)
        #expect(notFound.code == AgentCLI.ExitCode.dataError)
        #expect(notFound.err.hasPrefix("Fehler: "))
        #expect(notFound.out.isEmpty)
        #expect(run(["rules", "move", "#1", "--to", "0"], temp: temp).code == AgentCLI.ExitCode.usage)
        #expect(run(["check", "https://a.example", "--modifiers", "hyper"], temp: temp).code == AgentCLI.ExitCode.usage)
        #expect(run(["--version"], temp: temp).out == "airtraffic 1.8\n")

        let missing = try TempConfig(nil)
        defer { missing.remove() }
        #expect(run(["rules", "enable", "#1"], temp: missing).code == AgentCLI.ExitCode.noInput)
    }

    @Test func readCommands() throws {
        let temp = try TempConfig()
        defer { temp.remove() }
        for args in [["rules", "list"], ["rules", "get", "GitHub"], ["check", "https://github.com/x", "--source", "com.apple.mail"],
                     ["browsers", "list"], ["settings"], ["schema"], ["help"]] {
            let result = run(args, temp: temp)
            #expect(result.code == 0, "\(args): \(result.err)")
            #expect(!result.out.isEmpty)
            let json = run(args + ["--json"], temp: temp)
            if args != ["help"] { #expect(JSONValue.parse(json.out)?.objectValue != nil, "\(args)") }
        }
        #expect(run(["schema"], temp: temp).out.contains("Beispiel 3"))
    }
}

@Suite("Installation des Symlinks (§24.7)")
struct CommandLineInstallTests {
    func makeDirs() throws -> (root: URL, link: URL, helper: URL, other: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "AirTrafficInstall-\(UUID().uuidString)")
        let helper = root.appending(path: "A/Air Traffic.app/Contents/Helpers/airtraffic")
        let other = root.appending(path: "B/Air Traffic.app/Contents/Helpers/airtraffic")
        for file in [helper, other] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: file)
        }
        return (root, root.appending(path: "home/.local/bin/airtraffic"), helper, other)
    }

    @Test func installUpdateUninstall() throws {
        let (root, link, helper, other) = try makeDirs()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(CommandLineInstall.status(link: link, helper: helper) == .notInstalled)
        try CommandLineInstall.install(link: link, helper: helper)
        #expect(CommandLineInstall.status(link: link, helper: helper) == .installed)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == helper.path)

        // Andere App-Kopie: Status meldet sie, „Aktualisieren“ biegt um.
        #expect(CommandLineInstall.status(link: link, helper: other) == .otherCopy(destination: helper.path))
        try CommandLineInstall.install(link: link, helper: other)
        #expect(CommandLineInstall.status(link: link, helper: other) == .installed)

        try CommandLineInstall.uninstall(link: link)
        #expect(CommandLineInstall.status(link: link, helper: other) == .notInstalled)
        #expect(FileManager.default.fileExists(atPath: other.path))
        try CommandLineInstall.uninstall(link: link)
    }

    @Test func foreignFileIsNeverTouched() throws {
        let (root, link, helper, _) = try makeDirs()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("eigenes Skript".utf8).write(to: link)
        #expect(CommandLineInstall.status(link: link, helper: helper) == .blocked)
        #expect(throws: CommandLineInstall.InstallError.self) { try CommandLineInstall.install(link: link, helper: helper) }
        #expect(throws: CommandLineInstall.InstallError.self) { try CommandLineInstall.uninstall(link: link) }
        #expect(try Data(contentsOf: link) == Data("eigenes Skript".utf8))
    }

    @Test func missingHelper() throws {
        let (root, link, _, _) = try makeDirs()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: CommandLineInstall.InstallError.self) {
            try CommandLineInstall.install(link: link, helper: root.appending(path: "fehlt"))
        }
        #expect(CommandLineInstall.status(link: link, helper: root) == .notInstalled)
    }

    @Test func pathCheck() {
        let dir = URL(fileURLWithPath: "/Users/test/.local/bin")
        #expect(CommandLineInstall.path("/usr/bin:/Users/test/.local/bin/", contains: dir, home: "/Users/test"))
        #expect(CommandLineInstall.path("~/.local/bin:/usr/bin", contains: dir, home: "/Users/test"))
        #expect(CommandLineInstall.path("$HOME/.local/bin", contains: dir, home: "/Users/test"))
        #expect(!CommandLineInstall.path("/usr/bin:/Users/test/.local", contains: dir, home: "/Users/test"))
        #expect(CommandLineInstall.defaultLinkURL(home: URL(fileURLWithPath: "/Users/test")).path == "/Users/test/.local/bin/airtraffic")
    }
}
