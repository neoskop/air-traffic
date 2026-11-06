import Foundation

/// Unterbefehle von `airtraffic` (SPEC §24.3). Das Tool reicht nur Argumente, stdin und Ausgaben durch.
public struct AgentCLI {
    /// Ein- und Ausgabe des Prozesses.
    public struct IO {
        /// Liest stdin vollständig; `nil` = stdin ist ein Terminal (keine Eingabe umgeleitet).
        public var readStdin: () -> Data?
        public var out: (String) -> Void
        public var err: (String) -> Void

        public init(readStdin: @escaping () -> Data?, out: @escaping (String) -> Void, err: @escaping (String) -> Void) {
            self.readStdin = readStdin
            self.out = out
            self.err = err
        }
    }

    /// Exit-Codes nach sysexits.
    public enum ExitCode {
        public static let ok: Int32 = 0
        public static let usage: Int32 = 64
        /// Ungültige Eingabe, Validierung, unbekannte oder mehrdeutige Regel.
        public static let dataError: Int32 = 65
        /// Konfiguration fehlt oder ist nicht lesbar.
        public static let noInput: Int32 = 66
        public static let software: Int32 = 70
        public static let ioError: Int32 = 74
    }

    public let api: AgentAPI
    public let version: String

    public init(api: AgentAPI, version: String) {
        self.api = api
        self.version = version
    }

    public static func help(version: String) -> String {
        """
        airtraffic \(version) – Regeln von Air Traffic lesen, prüfen und ändern (für Menschen und KI-Agenten)

        Aufruf:
          airtraffic rules list [--json]
          airtraffic rules get <ref> [--json]
          airtraffic rules add [--at <n>] [--dry-run] [--json] < regel.json
          airtraffic rules add --name <Name> [--host <host>] [--url-contains <text>] [--regex <regex>]
                               [--match all|any|none] (--open <App> | --prompt) [--rewrite <Muster> <Vorlage>]
                               [--test-url <url>] [--at <n>] [--dry-run] [--json]
          airtraffic rules update <ref> [--dry-run] [--json] < änderung.json
          airtraffic rules move <ref> --to <n> [--json]
          airtraffic rules enable <ref> | disable <ref> [--json]
          airtraffic rules delete <ref> [--dry-run] [--json]
          airtraffic check <url> [--source <bundleID>] [--modifiers command,option,control,shift] [--json]
          airtraffic browsers list [--json]
          airtraffic settings [--json]
          airtraffic schema [--json]
          airtraffic mcp                 MCP-Server über stdio (für Claude Code, Codex …)
          airtraffic --version | help

        <ref>: UUID, UUID-Präfix (ab 6 Zeichen), Position wie #3 oder exakter Name.
        Regeln als JSON wie in config.json; „airtraffic schema“ beschreibt das Format.
        Neue Regeln und Änderungen an Umschreibungen oder Aktion warten auf Freigabe in Air Traffic und wirken erst danach.
        Vor jedem Schreiben wird eine Sicherung unter …/Air Traffic/backups/ angelegt (alle der letzten 24 h, je Tag die neueste und älteste für 14 Tage).
        AIRTRAFFIC_CONFIG_PATH=<datei> lenkt auf eine andere Konfiguration um.
        Exit-Codes: 0 ok, 64 Aufruf, 65 Eingabe/Regel ungültig oder nicht gefunden, 66 Konfiguration fehlt/unlesbar, 74 Schreibfehler.
        """
    }

    // MARK: Ausführen

    public func run(_ arguments: [String], io: IO) -> Int32 {
        var args = arguments
        let json = Self.takeFlag("--json", from: &args)
        do {
            guard let command = args.first else {
                io.out(Self.help(version: version))
                return ExitCode.ok
            }
            args.removeFirst()
            let result: AgentResult
            switch command {
            case "help", "-h", "--help":
                io.out(Self.help(version: version))
                return ExitCode.ok
            case "--version", "version":
                io.out("airtraffic \(version)")
                return ExitCode.ok
            case "rules":
                result = try runRules(&args, io: io)
            case "check":
                let source = try Self.takeOption("--source", from: &args)
                let modifierText = try Self.takeOption("--modifiers", from: &args)
                let modifiers = try Self.parseModifiers(
                    (modifierText ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                )
                let url = try Self.takeArgument("<url>", from: &args)
                try Self.expectEmpty(args)
                result = try api.checkURL(url, source: source, modifiers: modifiers)
            case "browsers":
                let sub = args.first
                guard sub == nil || sub == "list" else { throw AgentError.usage("Unbekannt: browsers \(sub ?? "") – gemeint ist „browsers list“.") }
                if sub != nil { args.removeFirst() }
                try Self.expectEmpty(args)
                result = try api.listBrowsers()
            case "settings":
                try Self.expectEmpty(args)
                result = try api.getSettings()
            case "schema":
                try Self.expectEmpty(args)
                result = api.describeRuleFormat()
            case "mcp":
                throw AgentError.usage("„mcp“ startet den MCP-Server und nimmt keine weiteren Argumente.")
            default:
                throw AgentError.usage("Unbekannter Befehl „\(command)“. „airtraffic help“ zeigt alle Befehle.")
            }
            io.out(json ? result.json.jsonString(pretty: true) : result.text)
            return ExitCode.ok
        } catch {
            return report(error, io: io)
        }
    }

    private func runRules(_ args: inout [String], io: IO) throws -> AgentResult {
        guard let sub = args.first else { throw AgentError.usage("Unterbefehl fehlt: rules list|get|add|update|move|enable|disable|delete") }
        args.removeFirst()
        switch sub {
        case "list":
            try Self.expectEmpty(args)
            return try api.listRules()
        case "get":
            let ref = try Self.takeArgument("<ref>", from: &args)
            try Self.expectEmpty(args)
            return try api.getRule(ref)
        case "add":
            let dryRun = Self.takeFlag("--dry-run", from: &args)
            let at = try Self.takeOption("--at", from: &args).map { try Self.parsePosition($0, option: "--at") }
            let rule: JSONValue
            if let built = try Self.ruleFromFlags(&args) {
                rule = built
            } else {
                rule = try Self.readJSON(io, what: "Regel")
            }
            try Self.expectEmpty(args)
            return try api.createRule(rule, position: at, dryRun: dryRun)
        case "update":
            let dryRun = Self.takeFlag("--dry-run", from: &args)
            let ref = try Self.takeArgument("<ref>", from: &args)
            try Self.expectEmpty(args)
            let patch = try Self.readJSON(io, what: "Änderung")
            return try api.updateRule(ref, patch: patch, dryRun: dryRun)
        case "move":
            let dryRun = Self.takeFlag("--dry-run", from: &args)
            guard let to = try Self.takeOption("--to", from: &args) else { throw AgentError.usage("--to <n> fehlt.") }
            let position = try Self.parsePosition(to, option: "--to")
            let ref = try Self.takeArgument("<ref>", from: &args)
            try Self.expectEmpty(args)
            return try api.moveRule(ref, to: position, dryRun: dryRun)
        case "enable", "disable":
            let dryRun = Self.takeFlag("--dry-run", from: &args)
            let ref = try Self.takeArgument("<ref>", from: &args)
            try Self.expectEmpty(args)
            return try api.setRuleEnabled(ref, enabled: sub == "enable", dryRun: dryRun)
        case "delete":
            let dryRun = Self.takeFlag("--dry-run", from: &args)
            let ref = try Self.takeArgument("<ref>", from: &args)
            try Self.expectEmpty(args)
            return try api.deleteRule(ref, dryRun: dryRun)
        default:
            throw AgentError.usage("Unbekannt: rules \(sub). Möglich: list, get, add, update, move, enable, disable, delete.")
        }
    }

    private func report(_ error: any Error, io: IO) -> Int32 {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        io.err("Fehler: \(message)")
        switch error {
        case let error as AgentError:
            if case .usage = error { return ExitCode.usage }
            return ExitCode.dataError
        case is ConfigStore.StoreError:
            return ExitCode.noInput
        case is DecodingError:
            return ExitCode.noInput
        case let error as CocoaError where error.isFileError:
            return error.code.rawValue >= CocoaError.fileWriteUnknown.rawValue ? ExitCode.ioError : ExitCode.noInput
        default:
            return ExitCode.software
        }
    }

    // MARK: Regel aus Flags

    /// `nil`, wenn kein Bau-Flag angegeben ist (dann JSON über stdin).
    static func ruleFromFlags(_ args: inout [String]) throws(AgentError) -> JSONValue? {
        var conditions: [JSONValue] = []
        var rewrites: [JSONValue] = []
        var object: [String: JSONValue] = [:]
        var used = false

        if let name = try takeOption("--name", from: &args) { object["name"] = .string(name); used = true }
        while let host = try takeOption("--host", from: &args) {
            conditions.append(["type": "host", "op": "equals", "value": .string(host)])
        }
        while let text = try takeOption("--url-contains", from: &args) {
            conditions.append(["type": "url", "op": "contains", "value": .string(text)])
        }
        while let regex = try takeOption("--regex", from: &args) {
            conditions.append(["type": "url", "op": "regex", "value": .string(regex)])
        }
        if let match = try takeOption("--match", from: &args) { object["match"] = .string(match); used = true }
        while let index = args.firstIndex(of: "--rewrite") {
            guard args.count > index + 2 else { throw .usage("--rewrite braucht <Muster> <Vorlage>.") }
            rewrites.append(["pattern": .string(args[index + 1]), "template": .string(args[index + 2])])
            args.removeSubrange(index...(index + 2))
        }
        let open = try takeOption("--open", from: &args)
        let prompt = takeFlag("--prompt", from: &args)
        if open != nil, prompt { throw .usage("Entweder --open <App> oder --prompt, nicht beides.") }
        if let open { object["action"] = ["type": "open", "app": .string(open)] }
        if prompt { object["action"] = ["type": "prompt", "scope": "all"] }
        if let testURL = try takeOption("--test-url", from: &args) { object["testURL"] = .string(testURL); used = true }

        used = used || !conditions.isEmpty || !rewrites.isEmpty || open != nil || prompt
        guard used else { return nil }
        if !conditions.isEmpty { object["conditions"] = .array(conditions) }
        if !rewrites.isEmpty { object["rewrites"] = .array(rewrites) }
        if object["action"] == nil { throw .usage("Aktion fehlt: --open <App> oder --prompt.") }
        return .object(object)
    }

    // MARK: Argument-Hilfen

    static func takeFlag(_ flag: String, from args: inout [String]) -> Bool {
        guard let index = args.firstIndex(of: flag) else { return false }
        args.remove(at: index)
        return true
    }

    static func takeOption(_ option: String, from args: inout [String]) throws(AgentError) -> String? {
        if let index = args.firstIndex(where: { $0.hasPrefix(option + "=") }) {
            let value = String(args[index].dropFirst(option.count + 1))
            args.remove(at: index)
            return value
        }
        guard let index = args.firstIndex(of: option) else { return nil }
        guard args.count > index + 1 else { throw .usage("\(option) braucht einen Wert.") }
        let value = args[index + 1]
        args.removeSubrange(index...(index + 1))
        return value
    }

    static func takeArgument(_ name: String, from args: inout [String]) throws(AgentError) -> String {
        guard let index = args.firstIndex(where: { !$0.hasPrefix("--") }) else { throw .usage("\(name) fehlt.") }
        return args.remove(at: index)
    }

    static func expectEmpty(_ args: [String]) throws(AgentError) {
        if let first = args.first { throw .usage("Unerwartetes Argument „\(first)“.") }
    }

    static func parsePosition(_ text: String, option: String) throws(AgentError) -> Int {
        let digits = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard let n = Int(digits), n >= 1 else { throw .usage("\(option) braucht eine Position ab 1, nicht „\(text)“.") }
        return n
    }

    static func parseModifiers(_ names: [String]) throws(AgentError) -> ModifierSet {
        var set: ModifierSet = []
        for name in names where !name.isEmpty {
            guard let entry = ModifierSet.named.first(where: { $0.name == name.lowercased() }) else {
                throw .usage("Unbekannter Modifier „\(name)“ (erlaubt: command, option, control, shift).")
            }
            set.insert(entry.value)
        }
        return set
    }

    static func readJSON(_ io: IO, what: String) throws(AgentError) -> JSONValue {
        guard let data = io.readStdin() else {
            throw .usage("\(what) als JSON über stdin erwartet, z. B. „airtraffic rules add < regel.json“.")
        }
        guard !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) else {
            throw .badInput("\(what): stdin ist leer.")
        }
        guard let json = JSONValue.parse(data) else {
            var detail = ""
            do { _ = try JSONSerialization.jsonObject(with: data) } catch { detail = " (\((error as NSError).localizedDescription))" }
            throw .badInput("\(what): kein gültiges JSON\(detail).")
        }
        return json
    }
}
