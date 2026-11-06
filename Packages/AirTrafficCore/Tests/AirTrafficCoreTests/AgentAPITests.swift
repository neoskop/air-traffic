import Foundation
import Testing
@testable import AirTrafficCore

@Suite("Agenten-Operationen (§24.3)")
struct AgentAPITests {
    @Test func addAppendsByDefaultAndAtPosition() throws {
        let temp = try TempConfig()
        defer { temp.remove() }
        let api = temp.api()

        let end = try api.createRule(["name": "Figma", "action": ["type": "open", "app": "Figma"]])
        #expect(end.json["rule"]?["position"] == 4)
        #expect(end.json["written"] == true)
        #expect(try temp.load().rules.map(\.name) == ["GitHub", "Alles Mögliche", "Doppelt", "Figma"])

        _ = try api.createRule(["name": "Oben", "action": ["type": "prompt"]], position: 1)
        #expect(try temp.load().rules.first?.name == "Oben")

        #expect(throws: AgentError.self) { try api.createRule(["name": "X", "action": ["type": "prompt"]], position: 9) }
        #expect(throws: AgentError.self) {
            try api.createRule(["id": .string(TempConfig.idA.uuidString), "name": "X", "action": ["type": "prompt"]])
        }
    }

    @Test func writeAnswersWithRuleAndTestURLCheck() throws {
        let temp = try TempConfig()
        defer { temp.remove() }
        let result = try temp.api().createRule([
            "name": "Figma", "conditions": [["type": "host", "op": "endsWith", "value": "figma.com"]],
            "action": ["type": "open", "app": "Figma"], "testURL": "https://www.figma.com/file/1",
        ], position: 1)
        // Neu angelegt → wartet auf Freigabe (§26.1); die Vorschau nach Freigabe zeigt, was dann passiert.
        #expect(result.json["check"]?["status"] == "pendingMatch")
        #expect(result.json["checkAfterApproval"]?["status"] == "wins")
        #expect(result.text.contains("wartet auf Freigabe in Air Traffic"))
        #expect(result.text.contains("Nach Freigabe: Test-URL https://www.figma.com/file/1: greift"))

        // Hinter „Alles Mögliche“ (passt immer) ist die Regel verdeckt.
        let shadowed = try temp.api().updateRule("Figma", patch: ["position": 3])
        #expect(shadowed.json["rule"]?["position"] == 3)
        #expect(shadowed.json["checkAfterApproval"]?["status"] == "shadowed")
        #expect(shadowed.json["checkAfterApproval"]?["winnerPosition"] == 2)
    }

    @Test func dryRunWritesNothing() throws {
        let temp = try TempConfig()
        defer { temp.remove() }
        let before = try Data(contentsOf: temp.store.fileURL)
        let api = temp.api()
        let result = try api.createRule(["name": "X", "action": ["type": "prompt"]], dryRun: true)
        _ = try api.updateRule("#1", patch: ["name": "Y"], dryRun: true)
        _ = try api.deleteRule("#1", dryRun: true)
        _ = try api.moveRule("#1", to: 3, dryRun: true)
        #expect(result.json["dryRun"] == true && result.json["written"] == false)
        #expect(result.text.contains("Probelauf"))
        #expect(try Data(contentsOf: temp.store.fileURL) == before)
        #expect(temp.store.backups().isEmpty)
    }

    @Test func updateMoveEnableDelete() throws {
        let temp = try TempConfig()
        defer { temp.remove() }
        let api = temp.api()

        _ = try api.updateRule("GitHub", patch: ["rewrites": [["pattern": "^https://github\\.com/(.*)$", "template": "https://gh.example/$1"]]])
        var config = try temp.load()
        #expect(config.rules[0].rewrites.count == 1)
        #expect(config.rules[0].conditions.count == 1)

        _ = try api.moveRule("#1", to: 3)
        config = try temp.load()
        #expect(config.rules.map(\.id) == [TempConfig.idB, TempConfig.idC, TempConfig.idA])

        _ = try api.setRuleEnabled("222222", enabled: true)
        #expect(try temp.load().rules[1].enabled)

        let deleted = try api.deleteRule("Alles Mögliche")
        #expect(deleted.json["deleted"]?["name"] == "Alles Mögliche")
        #expect(try temp.load().rules.map(\.id) == [TempConfig.idC, TempConfig.idA])
    }

    @Test func unchangedWriteDoesNotBackUp() throws {
        let temp = try TempConfig()
        defer { temp.remove() }
        let result = try temp.api().setRuleEnabled("#1", enabled: true)
        #expect(result.json["written"] == false)
        #expect(temp.store.backups().isEmpty)
    }

    @Test func listGetCheckSettings() throws {
        let temp = try TempConfig()
        defer { temp.remove() }
        let api = temp.api()

        let list = try api.listRules()
        #expect(list.json["count"] == 3)
        #expect(list.json["rules"]?.arrayValue?[2]["enabled"] == false)
        #expect(list.text.contains("[11111111-a]"))

        let get = try api.getRule("#1")
        #expect(get.json["rule"]?["id"] == .string(TempConfig.idA.uuidString.lowercased()))
        let roundTrip = try RuleInput(resolver: FakeAppResolver(), browsers: []).makeRule(from: try #require(get.json["rule"]))
        let first = try temp.load().rules[0]
        #expect(roundTrip.rule == first)

        let check = try api.checkURL("https://github.com/acme")
        #expect(check.json["decision"]?["matchedRule"]?["position"] == 1)
        let statuses = check.json["rules"]?.arrayValue?.compactMap { $0["status"]?.stringValue }
        #expect(statuses == ["wins", "shadowed", "noMatch"])

        let other = try api.checkURL("https://a.example/x", source: "com.apple.mail", modifiers: [.command])
        #expect(other.json["rules"]?.arrayValue?[2]["status"] == "disabledMatch")
        #expect(other.json["modifiers"] == ["command"])
        #expect(throws: AgentError.self) { try api.checkURL("github.com") }

        let settings = try api.getSettings()
        #expect(settings.json["defaultAction"]?["type"] == "prompt")
        #expect(settings.json["appearance"] == "system")

        let browsers = try api.listBrowsers()
        #expect(browsers.json["browsers"]?.arrayValue?.count == 2)
        #expect(browsers.json["otherInstalledBrowsers"]?.arrayValue?.isEmpty == true)
    }

    /// §27 K8: Lesen ohne Konfiguration ist ein Fehler (Exit 66), keine leere Liste.
    @Test func missingConfigRefusesReadsAndWrites() throws {
        let temp = try TempConfig(nil)
        defer { temp.remove() }
        #expect(throws: ConfigStore.StoreError.missing(path: temp.store.fileURL.path(percentEncoded: false))) {
            try temp.api().listRules()
        }
        #expect(throws: ConfigStore.StoreError.self) {
            try temp.api().createRule(["name": "X", "action": ["type": "prompt"]])
        }
        #expect(!temp.store.exists)
    }
}

@Suite("Sicherung und koordiniertes Schreiben (§24.4)")
struct ConfigModifyTests {
    @Test func backupBeforeEveryWriteKeepsAllOfLast24Hours() throws {
        let temp = try TempConfig()
        defer { temp.remove() }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var firstContent: Data?
        for i in 0..<35 {
            let before = try Data(contentsOf: temp.store.fileURL)
            if i == 0 { firstContent = before }
            let result = try temp.store.modify(now: start.addingTimeInterval(Double(i))) { config in
                config.rules[0].name = "Name \(i)"
            }
            let backup = try #require(result.backupURL)
            #expect(try Data(contentsOf: backup) == before)
        }
        // Alle innerhalb von 24 h bleiben (§26.10); die älteste ist der Stand vor der ersten Änderung.
        let backups = temp.store.backups()
        #expect(backups.count == 35)
        #expect(backups.first?.lastPathComponent == "config-\(ConfigStore.backupStamp(start)).json")
        #expect(try Data(contentsOf: try #require(backups.first)) == firstContent)
        #expect(try temp.load().rules[0].name == "Name 34")
    }

    @Test func backupNameIsISOLikeAndUnique() throws {
        let temp = try TempConfig()
        defer { temp.remove() }
        let now = Date(timeIntervalSince1970: 1_800_000_000.25)
        #expect(ConfigStore.backupStamp(now) == "2027-01-15T08-00-00.250Z")
        let a = try temp.store.writeBackup(Data("a".utf8), now: now)
        let b = try temp.store.writeBackup(Data("b".utf8), now: now)
        #expect(a != b)
        #expect(b.lastPathComponent == "config-2027-01-15T08-00-00.250Z-2.json")
        #expect(a.deletingLastPathComponent().lastPathComponent == "backups")
    }

    @Test func modifyFailureLeavesFileUntouched() throws {
        let temp = try TempConfig()
        defer { temp.remove() }
        let before = try Data(contentsOf: temp.store.fileURL)
        #expect(throws: AgentError.self) {
            try temp.store.modify { config in
                config.rules.removeAll()
                throw AgentError.usage("abbrechen")
            }
        }
        #expect(try Data(contentsOf: temp.store.fileURL) == before)
        #expect(temp.store.backups().isEmpty)
    }

    @Test func modifyIsAtomicUnderConcurrency() async throws {
        let temp = try TempConfig()
        defer { temp.remove() }
        let store = temp.store
        // 20 parallele Lesen-Ändern-Schreiben: keines geht verloren, die Datei bleibt immer gültig.
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    _ = try? store.modify { config in
                        config.rules.append(Rule(name: "Parallel \(i)", action: .prompt(.all)))
                    }
                }
            }
        }
        let config = try temp.load()
        #expect(config.rules.count == 23)
        #expect(Set(config.rules.map(\.name)).count == 23)
    }
}

@Suite("Konfliktentscheidung (§24.5)")
struct ConfigSyncTests {
    @Test func saveDecision() {
        #expect(ConfigSync.saveDecision(known: "a", current: "a") == .write)
        #expect(ConfigSync.saveDecision(known: "a", current: "b") == .reloadInstead)
        #expect(ConfigSync.saveDecision(known: nil, current: "b") == .reloadInstead)
        #expect(ConfigSync.saveDecision(known: "a", current: nil) == .write)
        #expect(ConfigSync.saveDecision(known: nil, current: nil) == .write)
    }

    @Test func changeDecision() {
        #expect(ConfigSync.changeDecision(known: "a", current: "a") == .ignore)
        #expect(ConfigSync.changeDecision(known: "a", current: "b") == .reload)
        #expect(ConfigSync.changeDecision(known: "a", current: nil) == .ignore)
    }

    @Test func saveDoesNotOverwriteExternalChange() throws {
        let temp = try TempConfig()
        defer { temp.remove() }
        let loaded = try #require(try temp.store.loadSnapshot())

        // Eigener Speichervorgang: Fingerabdruck passt → geschrieben.
        var mine = loaded.config
        mine.rules[0].name = "App"
        guard case .saved(let fingerprint) = try temp.store.save(mine, ifUnchangedSince: loaded.fingerprint) else {
            Issue.record("nicht gespeichert")
            return
        }
        #expect(fingerprint == ConfigStore.fingerprint(try Data(contentsOf: temp.store.fileURL)))

        // Von außen geändert → nicht überschreiben, sondern den neuen Stand liefern.
        _ = try temp.api().deleteRule("#3")
        var stale = mine
        stale.rules[0].name = "Veraltet"
        guard case .conflict(let current) = try temp.store.save(stale, ifUnchangedSince: fingerprint) else {
            Issue.record("Konflikt nicht erkannt")
            return
        }
        #expect(current.config.rules.count == 2)
        #expect(current.config.rules[0].name == "App")
        #expect(try temp.load().rules[0].name == "App")
    }

    @Test func externallyBrokenFileIsNotOverwritten() throws {
        let temp = try TempConfig()
        defer { temp.remove() }
        let loaded = try #require(try temp.store.loadSnapshot())
        try Data("{ kaputt".utf8).write(to: temp.store.fileURL)
        let outcome = try temp.store.save(loaded.config, ifUnchangedSince: loaded.fingerprint)
        guard case .conflictUnreadable = outcome else {
            Issue.record("erwartet conflictUnreadable, war \(outcome)")
            return
        }
        #expect(try Data(contentsOf: temp.store.fileURL) == Data("{ kaputt".utf8))
    }
}
