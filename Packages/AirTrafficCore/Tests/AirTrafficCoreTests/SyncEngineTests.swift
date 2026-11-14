import Foundation
import Testing
@testable import AirTrafficCore

/// Ein Mac im Test: Konfiguration, gerätelokaler Zustand und Gerät.
private struct Mac {
    var config: Config
    var state: SyncState
    let device: SyncDevice

    init(name: String, rules: [Rule] = [], defaultAction: Action = .prompt(.all)) {
        config = Config(browsers: [AppRef(path: "/Applications/\(name).app")], rules: rules, defaultAction: defaultAction)
        device = SyncDevice(deviceID: UUID(), name: name)
        state = SyncState(enabled: true, deviceID: device.deviceID)
    }

    /// Eine Runde gegen die „iCloud-Datei“ (über JSON, wie auf der Platte).
    @discardableResult
    mutating func sync(_ cloud: inout Data?, at now: Date) throws -> SyncResult {
        let remote = try cloud.map { [try SyncFileStore.decode($0)] } ?? []
        let result = SyncEngine.sync(config: config, state: state, remote: remote, device: device, now: now)
        config = result.config
        // Zustand über JSON, wie auf der Platte.
        state = try SyncClock.makeDecoder().decode(SyncState.self, from: SyncClock.makeEncoder().encode(result.state))
        if result.remoteChanged { cloud = try SyncFileStore.encode(result.document) }
        return result
    }

    var names: [String] { config.rules.map(\.name) }
}

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
/// Inhalt der „iCloud-Datei“.
private func doc(_ cloud: Data?) throws -> SyncDocument {
    guard let cloud else { throw CocoaError(.fileNoSuchFile) }
    return try SyncFileStore.decode(cloud)
}

private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

private func makeRule(_ name: String, host: String? = nil, id: UUID = UUID()) -> Rule {
    Rule(
        id: id,
        name: name,
        conditions: [.host(TextMatch(op: .equals, value: host ?? "\(name.lowercased()).example.com"))],
        action: .prompt(.all)
    )
}

private let safari = AppRef(bundleIdentifier: "com.apple.Safari", path: "/Applications/Safari.app", displayName: "Safari")
private let firefox = AppRef(bundleIdentifier: "org.mozilla.firefox", path: "/Applications/Firefox.app", displayName: "Firefox")

@Suite("iCloud-Sync: Merge")
struct SyncEngineTests {
    @Test func firstSyncWritesDocumentAndIsIdempotent() throws {
        var a = Mac(name: "A", rules: [makeRule("Eins"), makeRule("Zwei")])
        var cloud: Data?
        let first = try a.sync(&cloud, at: at(0))
        #expect(first.remoteChanged)
        #expect(!first.localChanged)
        let document = try doc(cloud)
        #expect(document.rules.map(\.rule.name) == ["Eins", "Zwei"])
        #expect(document.updatedBy.name == "A")

        let configBefore = a.config
        let bytesBefore = cloud
        let second = try a.sync(&cloud, at: at(60))
        #expect(!second.localChanged)
        #expect(!second.remoteChanged)
        #expect(second.summary.isEmpty)
        #expect(a.config == configBefore)
        #expect(cloud == bytesBefore)
        let third = try a.sync(&cloud, at: at(120))
        #expect(!third.localChanged && !third.remoteChanged)
    }

    @Test func twoMacsConverge() throws {
        var a = Mac(name: "A", rules: [makeRule("A1"), makeRule("A2")])
        var b = Mac(name: "B", rules: [makeRule("B1")])
        var cloud: Data?
        try a.sync(&cloud, at: at(0))
        try b.sync(&cloud, at: at(10))
        try a.sync(&cloud, at: at(20))
        #expect(Set(a.names) == ["A1", "A2", "B1"])
        #expect(a.config.rules == b.config.rules)

        // Weitere Änderungen auf beiden Seiten, abwechselnd synchronisiert.
        a.config.rules.append(makeRule("A3"))
        b.config.rules[0].name = "A1 umbenannt"
        try a.sync(&cloud, at: at(30))
        try b.sync(&cloud, at: at(40))
        try a.sync(&cloud, at: at(50))
        try b.sync(&cloud, at: at(60))
        #expect(a.config.rules == b.config.rules)
        #expect(a.names.contains("A1 umbenannt"))
        #expect(a.names.contains("A3"))
        // Browserliste bleibt gerätelokal.
        #expect(a.config.browsers != b.config.browsers)
    }

    @Test func deletionPropagatesAndIsNotResurrected() throws {
        let doomed = makeRule("Weg")
        var a = Mac(name: "A", rules: [makeRule("Bleibt"), doomed])
        var b = Mac(name: "B")
        var cloud: Data?
        try a.sync(&cloud, at: at(0))
        try b.sync(&cloud, at: at(10))
        #expect(b.names == ["Bleibt", "Weg"])

        a.config.rules.removeAll { $0.id == doomed.id }
        let deletion = try a.sync(&cloud, at: at(20))
        #expect(deletion.remoteChanged)
        let document = try doc(cloud)
        #expect(document.deleted.map(\.id) == [doomed.id])

        let onB = try b.sync(&cloud, at: at(30))
        #expect(b.names == ["Bleibt"])
        #expect(onB.summary.removed == ["Weg"])
        try b.sync(&cloud, at: at(40))
        try a.sync(&cloud, at: at(50))
        #expect(a.names == ["Bleibt"])
        #expect(b.names == ["Bleibt"])
    }

    @Test func concurrentChangesToDifferentRulesBothSurvive() throws {
        var a = Mac(name: "A", rules: [makeRule("Eins"), makeRule("Zwei")])
        var b = Mac(name: "B")
        var cloud: Data?
        try a.sync(&cloud, at: at(0))
        try b.sync(&cloud, at: at(1))

        a.config.rules[0].name = "Eins (A)"
        b.config.rules[1].name = "Zwei (B)"
        try a.sync(&cloud, at: at(10))
        try b.sync(&cloud, at: at(11))
        try a.sync(&cloud, at: at(12))
        #expect(a.names == ["Eins (A)", "Zwei (B)"])
        #expect(b.names == ["Eins (A)", "Zwei (B)"])
    }

    @Test func sameRuleNewerChangeWins() throws {
        var a = Mac(name: "A", rules: [makeRule("Regel")])
        var b = Mac(name: "B")
        var cloud: Data?
        try a.sync(&cloud, at: at(0))
        try b.sync(&cloud, at: at(1))

        // A ändert früher, B später; A synchronisiert zuerst.
        a.config.rules[0].name = "von A"
        b.config.rules[0].name = "von B"
        try a.sync(&cloud, at: at(10))
        try b.sync(&cloud, at: at(20))
        try a.sync(&cloud, at: at(30))
        #expect(a.names == ["von B"])
        #expect(b.names == ["von B"])

        // Jetzt umgekehrt: B synchronisiert zuerst, A ist jünger.
        a.config.rules[0].name = "A jünger"
        b.config.rules[0].name = "B älter"
        try b.sync(&cloud, at: at(40))
        try a.sync(&cloud, at: at(50))
        try b.sync(&cloud, at: at(60))
        #expect(a.names == ["A jünger"])
        #expect(b.names == ["A jünger"])
    }

    @Test func pendingNewRuleIsNeverExported() throws {
        var pending = makeRule("Neu von außen")
        pending.pendingChange = PendingChange(since: at(0), reason: "neu angelegt von außen (CLI/MCP)", previous: nil)
        let approved = makeRule("Frei")
        var a = Mac(name: "A", rules: [approved, pending])
        var cloud: Data?
        try a.sync(&cloud, at: at(0))
        let document = try doc(cloud)
        #expect(document.rules.map(\.rule.id) == [approved.id])
        #expect(!String(decoding: try #require(cloud), as: UTF8.self).contains("Neu von außen"))
        // Lokal bleibt sie unberührt und wird nicht als gelöscht übertragen.
        #expect(a.config.rules.map(\.id) == [approved.id, pending.id])
        #expect(a.config.rules[1].isPendingApproval)
        try a.sync(&cloud, at: at(10))
        #expect(try doc(cloud).deleted.isEmpty)
    }

    @Test func pendingChangedRuleExportsOnlyApprovedState() throws {
        var rule = makeRule("Review")
        rule.action = .open(safari)
        var previous = rule
        previous.rewrites = []
        rule.rewrites = [Rewrite(pattern: "^https://(.*)$", template: "evil://$1")]
        rule.action = .open(firefox)
        previous.action = .open(safari)
        rule.pendingChange = PendingChange(since: at(0), reason: "Umschreibungen und Aktion geändert von außen (CLI/MCP)", previous: previous)

        var a = Mac(name: "A", rules: [rule])
        var cloud: Data?
        try a.sync(&cloud, at: at(0))
        let synced = try #require(try doc(cloud).rules.first?.rule)
        #expect(synced.rewrites.isEmpty)
        #expect(synced.action == .open(safari))
        #expect(synced.pendingChange == nil)
        #expect(!String(decoding: try #require(cloud), as: UTF8.self).contains("evil://"))
        // Lokal wartet die Änderung weiter.
        #expect(a.config.rules[0] == rule)
    }

    @Test func pendingChangeInSyncFileIsDiscarded() throws {
        let id = UUID()
        let json = """
        {
          "formatVersion": 1,
          "rules": [{
            "modifiedAt": "2027-01-15T08:00:00.000Z",
            "rule": {
              "id": "\(id.uuidString)",
              "name": "Untergeschoben",
              "action": {"type": "open", "app": {"path": "/Applications/Evil.app", "displayName": "Evil"}},
              "pendingChange": {
                "since": "2027-01-15T08:00:00.000Z",
                "reason": "x",
                "previous": {"id": "\(id.uuidString)", "name": "Alt", "action": {"type": "prompt", "scope": "all"}}
              }
            }
          }],
          "deleted": [],
          "orderModifiedAt": "2027-01-15T08:00:00.000Z",
          "settings": {
            "defaultAction": {"value": {"type": "prompt", "scope": "all"}, "modifiedAt": "2027-01-15T08:00:00.000Z"},
            "extensionSettings": {"value": null, "modifiedAt": "2027-01-15T08:00:00.000Z"},
            "appearance": {"value": null, "modifiedAt": "2027-01-15T08:00:00.000Z"}
          },
          "updatedAt": "2027-01-15T08:00:00.000Z",
          "updatedBy": {"deviceID": "\(UUID().uuidString)", "name": "X"}
        }
        """
        let document = try SyncFileStore.decode(Data(json.utf8))
        #expect(document.rules.first?.rule.pendingChange == nil)

        var a = Mac(name: "A")
        var cloud: Data? = Data(json.utf8)
        try a.sync(&cloud, at: at(0))
        #expect(a.config.rules.count == 1)
        #expect(a.config.rules[0].pendingChange == nil)
        #expect(a.config.rules[0].name == "Untergeschoben")
    }

    @Test func firstSyncDropsLocalDuplicates() throws {
        let shared = makeRule("GitHub", host: "github.com")
        var a = Mac(name: "A", rules: [shared])
        var copy = shared
        copy.id = UUID()
        let own = makeRule("Nur auf B")
        var b = Mac(name: "B", rules: [copy, own])
        var cloud: Data?
        try a.sync(&cloud, at: at(0))
        let result = try b.sync(&cloud, at: at(10))
        #expect(b.config.rules.map(\.id) == [shared.id, own.id])
        #expect(result.localChanged)
        // Ein zweiter Lauf entfernt keine absichtlich gleichen Regeln mehr.
        var again = shared
        again.id = UUID()
        b.config.rules.append(again)
        try b.sync(&cloud, at: at(20))
        #expect(b.config.rules.map(\.id) == [shared.id, own.id, again.id])
    }

    @Test func firstSyncPrefersCloudForSameID() throws {
        let id = UUID()
        var a = Mac(name: "A", rules: [makeRule("Stand A", id: id)])
        var b = Mac(name: "B", rules: [makeRule("Stand B", id: id)])
        var cloud: Data?
        try a.sync(&cloud, at: at(0))
        try b.sync(&cloud, at: at(10))
        #expect(b.names == ["Stand A"])
        try a.sync(&cloud, at: at(20))
        #expect(a.names == ["Stand A"])
    }

    @Test func undoAfterSyncedDeletionRestoresRule() throws {
        let rule = makeRule("Zurück")
        var a = Mac(name: "A", rules: [rule])
        var cloud: Data?
        try a.sync(&cloud, at: at(0))
        a.config.rules = []
        try a.sync(&cloud, at: at(10))
        a.config.rules = [rule]
        try a.sync(&cloud, at: at(20))
        #expect(a.names == ["Zurück"])
        let document = try doc(cloud)
        #expect(document.rules.map(\.rule.id) == [rule.id])
        #expect(document.deleted.isEmpty)
    }

    // MARK: Freigabe trifft auf neueren iCloud-Stand

    @Test func pendingRuleAdoptsNewerCloudStateAsApproved() throws {
        var a = Mac(name: "A", rules: [makeRule("Review")])
        var b = Mac(name: "B")
        var cloud: Data?
        try a.sync(&cloud, at: at(0))
        try b.sync(&cloud, at: at(1))

        // Auf A schlägt ein Agent eine neue Umschreibung vor (wartet).
        let approvedOnA = a.config.rules[0]
        var proposed = approvedOnA
        proposed.rewrites = [Rewrite(pattern: "a", template: "b")]
        a.config.rules[0] = RuleApproval.gate(old: approvedOnA, new: proposed, now: at(5))
        #expect(a.config.rules[0].isPendingApproval)

        // Auf B wird die Regel umbenannt und die Aktion geändert.
        b.config.rules[0].name = "Review (B)"
        b.config.rules[0].action = .open(safari)
        try b.sync(&cloud, at: at(10))
        try a.sync(&cloud, at: at(20))

        let rule = a.config.rules[0]
        #expect(rule.name == "Review (B)")
        #expect(rule.rewrites == proposed.rewrites)
        #expect(rule.action == proposed.action)
        #expect(rule.pendingChange?.previous == b.config.rules[0])
        #expect(rule.effective == b.config.rules[0])
        // Stabil: nächste Runde ändert nichts, iCloud bekommt den Vorschlag nicht.
        let next = try a.sync(&cloud, at: at(30))
        #expect(!next.localChanged && !next.remoteChanged)
        #expect(try doc(cloud).rules[0].rule.rewrites.isEmpty)
    }

    @Test func pendingRuleIsDeletedWhenTombstoneWins() throws {
        let rule = makeRule("Weg")
        var a = Mac(name: "A", rules: [rule])
        var b = Mac(name: "B")
        var cloud: Data?
        try a.sync(&cloud, at: at(0))
        try b.sync(&cloud, at: at(1))
        var proposed = a.config.rules[0]
        proposed.action = .open(firefox)
        a.config.rules[0] = RuleApproval.gate(old: a.config.rules[0], new: proposed, now: at(5))
        b.config.rules = []
        try b.sync(&cloud, at: at(10))
        try a.sync(&cloud, at: at(20))
        #expect(a.config.rules.isEmpty)
    }

    @Test func pendingNewRuleKeepsRelativePosition() throws {
        let one = makeRule("Eins")
        let two = makeRule("Zwei")
        var a = Mac(name: "A", rules: [one, two])
        var b = Mac(name: "B")
        var cloud: Data?
        try a.sync(&cloud, at: at(0))
        try b.sync(&cloud, at: at(1))

        var pending = makeRule("Wartet")
        pending.pendingChange = PendingChange(since: at(2), reason: "neu", previous: nil)
        a.config.rules.insert(pending, at: 1)  // hinter „Eins“
        // B stellt um und fügt vorn eine Regel ein.
        b.config.rules = [makeRule("Null"), two, one]
        try b.sync(&cloud, at: at(10))
        try a.sync(&cloud, at: at(20))
        #expect(a.names == ["Null", "Zwei", "Eins", "Wartet"])
    }

    // MARK: Reihenfolge

    @Test func reorderPropagates() throws {
        var a = Mac(name: "A", rules: [makeRule("Eins"), makeRule("Zwei"), makeRule("Drei")])
        var b = Mac(name: "B")
        var cloud: Data?
        try a.sync(&cloud, at: at(0))
        try b.sync(&cloud, at: at(1))
        a.config.rules.insert(a.config.rules.removeLast(), at: 0)
        let result = try a.sync(&cloud, at: at(10))
        #expect(result.remoteChanged)
        let onB = try b.sync(&cloud, at: at(20))
        #expect(b.names == ["Drei", "Eins", "Zwei"])
        #expect(onB.summary.orderChanged)
    }

    @Test func addingOrDeletingDoesNotOverrideRemoteReorder() throws {
        var a = Mac(name: "A", rules: [makeRule("Eins"), makeRule("Zwei"), makeRule("Drei")])
        var b = Mac(name: "B")
        var cloud: Data?
        try a.sync(&cloud, at: at(0))
        try b.sync(&cloud, at: at(1))

        // A stellt um; B fügt hinter „Eins“ eine Regel ein und löscht „Drei“ – später.
        a.config.rules = [a.config.rules[1], a.config.rules[0], a.config.rules[2]]
        try a.sync(&cloud, at: at(10))
        b.config.rules.insert(makeRule("Neu"), at: 1)
        b.config.rules.removeAll { $0.name == "Drei" }
        try b.sync(&cloud, at: at(20))
        #expect(b.names == ["Zwei", "Eins", "Neu"])
        try a.sync(&cloud, at: at(30))
        #expect(a.names == ["Zwei", "Eins", "Neu"])
    }

    @Test func newerReorderWinsAndMissingRulesFollowPredecessor() throws {
        var a = Mac(name: "A", rules: [makeRule("Eins"), makeRule("Zwei"), makeRule("Drei")])
        var b = Mac(name: "B")
        var cloud: Data?
        try a.sync(&cloud, at: at(0))
        try b.sync(&cloud, at: at(1))

        // A fügt vorn und hinter „Zwei“ ein; B stellt später um.
        a.config.rules.insert(makeRule("A-vorn"), at: 0)
        a.config.rules.insert(makeRule("A-mitte"), at: 3)
        try a.sync(&cloud, at: at(10))
        b.config.rules.reverse()
        try b.sync(&cloud, at: at(20))
        #expect(b.names == ["A-vorn", "Drei", "Zwei", "A-mitte", "Eins"])
        try a.sync(&cloud, at: at(30))
        #expect(a.names == b.names)
    }

    @Test func mergeOrderInsertsAfterPredecessorOrAtFront() {
        let ids = (0..<6).map { _ in UUID() }
        let winner = [ids[2], ids[1], ids[0]]
        let other = [ids[3], ids[0], ids[4], ids[5], ids[1]]
        let result = SyncEngine.mergeOrder(winner: winner, other: other, survivors: Set(ids).subtracting([ids[5]]))
        #expect(result == [ids[3], ids[2], ids[1], ids[0], ids[4]])
    }

    // MARK: Einstellungen

    @Test func settingsMergePerField() throws {
        var a = Mac(name: "A", rules: [makeRule("Eins")])
        var b = Mac(name: "B")
        var cloud: Data?
        try a.sync(&cloud, at: at(0))
        try b.sync(&cloud, at: at(1))
        a.config.defaultAction = .open(safari)
        b.config.appearance = .dark
        b.config.extensionSettings = ExtensionSettings(applyRules: false)
        try a.sync(&cloud, at: at(10))
        let onB = try b.sync(&cloud, at: at(20))
        #expect(onB.summary.settingsChanged)
        try a.sync(&cloud, at: at(30))
        for mac in [a, b] {
            #expect(mac.config.defaultAction == .open(safari))
            #expect(mac.config.appearance == .dark)
            #expect(mac.config.extensionSettings == ExtensionSettings(applyRules: false))
        }
        // Zurück auf System/Standard wird ebenfalls übertragen.
        a.config.appearance = nil
        a.config.extensionSettings = nil
        try a.sync(&cloud, at: at(40))
        try b.sync(&cloud, at: at(50))
        #expect(b.config.appearance == nil)
        #expect(b.config.extensionSettings == nil)
    }

    @Test func firstSyncAdoptsCloudSettingsAndKeepsLocalOnlyFields() throws {
        var a = Mac(name: "A", defaultAction: .open(safari))
        a.config.assistant = AssistantSettings(model: "a/model")
        var b = Mac(name: "B", defaultAction: .prompt(.running))
        b.config.assistant = AssistantSettings(model: "b/model")
        var cloud: Data?
        try a.sync(&cloud, at: at(0))
        try b.sync(&cloud, at: at(10))
        #expect(b.config.defaultAction == .open(safari))
        #expect(b.config.assistant?.model == "b/model")
        #expect(!String(decoding: try #require(cloud), as: UTF8.self).contains("a/model"))
    }

    // MARK: Tombstones

    @Test func tombstonesExpireAfter365Days() throws {
        let doomed = makeRule("Weg")
        var a = Mac(name: "A", rules: [doomed])
        var cloud: Data?
        try a.sync(&cloud, at: at(0))
        a.config.rules = []
        try a.sync(&cloud, at: at(10))
        #expect(try doc(cloud).deleted.count == 1)

        a.config.rules.append(makeRule("Später"))
        try a.sync(&cloud, at: at(10 + 364 * 24 * 3600))
        #expect(try doc(cloud).deleted.count == 1)
        a.config.rules.append(makeRule("Viel später"))
        try a.sync(&cloud, at: at(10 + 366 * 24 * 3600))
        #expect(try doc(cloud).deleted.isEmpty)
        #expect(a.state.deleted.isEmpty)
    }

    // MARK: Konfliktversionen

    @Test func combineMergesConflictVersionsDeterministically() throws {
        var a = Mac(name: "A", rules: [makeRule("Eins")])
        var b = Mac(name: "B")
        var cloud: Data?
        try a.sync(&cloud, at: at(0))
        try b.sync(&cloud, at: at(1))
        var cloudA = cloud
        var cloudB = cloud
        a.config.rules.append(makeRule("Von A"))
        b.config.rules.append(makeRule("Von B"))
        try a.sync(&cloudA, at: at(10))
        try b.sync(&cloudB, at: at(11))
        let docA = try doc(cloudA)
        let docB = try doc(cloudB)
        let ab = try #require(SyncEngine.combine([docA, docB], now: at(20)))
        let ba = try #require(SyncEngine.combine([docB, docA], now: at(20)))
        #expect(ab.hasSameContent(as: ba))
        #expect(Set(ab.rules.map(\.rule.name)) == ["Eins", "Von A", "Von B"])

        let result = SyncEngine.sync(config: a.config, state: a.state, remote: [docA, docB], device: a.device, now: at(30))
        #expect(Set(result.config.rules.map(\.name)) == ["Eins", "Von A", "Von B"])
        #expect(result.remoteChanged)
    }

    @Test func longAbsentMacDoesNotResurrectRulesWithExpiredTombstones() throws {
        let keep = makeRule("Bleibt")
        let gone = makeRule("Weg")
        let edited = makeRule("Bearbeitet")
        var a = Mac(name: "A", rules: [keep, gone, edited])
        var b = Mac(name: "B")
        var cloud: Data?
        try a.sync(&cloud, at: at(0))
        try b.sync(&cloud, at: at(1))
        a.config.rules = [keep]
        try a.sync(&cloud, at: at(10))

        // B ist über ein Jahr weg und ändert in der Zeit „Bearbeitet“; die Tombstones verfallen.
        b.config.rules[2].name = "Bearbeitet auf B"
        let year: TimeInterval = 366 * 24 * 3600
        try a.sync(&cloud, at: at(10 + year))
        #expect(try doc(cloud).deleted.isEmpty)
        try b.sync(&cloud, at: at(20 + year))
        // „Weg“ (unverändert) lebt nicht wieder auf; die lokale Änderung an „Bearbeitet“ zählt als neuer Stand.
        #expect(b.names == ["Bleibt", "Bearbeitet auf B"])
        try a.sync(&cloud, at: at(30 + year))
        #expect(a.names == ["Bleibt", "Bearbeitet auf B"])
    }

    @Test func normalOperationKeepsRulesMissingInCloud() throws {
        let rule = makeRule("Fehlt in iCloud")
        var a = Mac(name: "A", rules: [rule])
        var cloud: Data?
        try a.sync(&cloud, at: at(0))
        // Ohne Tombstone verschwunden (z. B. verlorener Schreibvorgang): im Normalbetrieb nicht löschen.
        var document = try doc(cloud)
        document.rules = []
        cloud = try SyncFileStore.encode(document)
        let result = try a.sync(&cloud, at: at(10))
        #expect(a.names == ["Fehlt in iCloud"])
        #expect(result.remoteChanged)
        #expect(try doc(cloud).rules.map(\.rule.id) == [rule.id])
    }

    @Test func reenablingAfterLocalDeleteIsFirstSyncAndDeletesNothing() throws {
        let rule = makeRule("Bleibt überall")
        var a = Mac(name: "A", rules: [rule, makeRule("Zwei")])
        var b = Mac(name: "B")
        var cloud: Data?
        try a.sync(&cloud, at: at(0))
        try b.sync(&cloud, at: at(1))

        // Aus → lokal löschen → ein.
        let deviceID = a.state.deviceID
        a.state = a.state.resetForDisabling()
        #expect(!a.state.enabled && a.state.isFirstSync && a.state.rules.isEmpty && a.state.deviceID == deviceID)
        a.config.rules.removeAll { $0.id == rule.id }
        a.state.enabled = true
        try a.sync(&cloud, at: at(20))
        #expect(a.names == ["Bleibt überall", "Zwei"])
        #expect(try doc(cloud).deleted.isEmpty)
        try b.sync(&cloud, at: at(30))
        #expect(b.names == ["Bleibt überall", "Zwei"])
    }

    @Test func firstSyncCommitsStateOnlyAfterSeeingOrCreatingDocument() {
        let fresh = SyncState(enabled: true)
        #expect(SyncStateCommit.plan(previous: fresh, readRemoteDocument: true) == .beforeWrite)
        let plan = SyncStateCommit.plan(previous: fresh, readRemoteDocument: false)
        #expect(plan == .afterSavedWrite)
        #expect(plan.commitsAfterWrite(.saved(fingerprint: "abc")))
        #expect(!plan.commitsAfterWrite(.conflict))
        #expect(!plan.commitsAfterWrite(nil))
        var synced = fresh
        synced.lastSyncedAt = t0
        #expect(SyncStateCommit.plan(previous: synced, readRemoteDocument: false) == .beforeWrite)
        #expect(!SyncStateCommit.beforeWrite.commitsAfterWrite(.saved(fingerprint: "abc")))
    }

    @Test func uncommittedFirstSyncStillPrefersCloudLater() throws {
        let id = UUID()
        var a = Mac(name: "A", rules: [makeRule("Stand A", id: id)])
        var b = Mac(name: "B", rules: [makeRule("Stand B", id: id)])
        var cloud: Data?
        // B sieht keine Datei, das Schreiben scheitert am Konflikt: Zustand bleibt „erster Sync“.
        let attempt = SyncEngine.sync(config: b.config, state: b.state, remote: [], device: b.device, now: at(0))
        #expect(SyncStateCommit.plan(previous: b.state, readRemoteDocument: false).commitsAfterWrite(.conflict) == false)
        #expect(attempt.remoteChanged)
        try a.sync(&cloud, at: at(1))
        try b.sync(&cloud, at: at(10))
        #expect(b.names == ["Stand A"])
    }

    @Test func pendingNewRuleWithExistingCloudIDWaitsAgainstCloudRule() throws {
        let id = UUID()
        var a = Mac(name: "A", rules: [makeRule("In iCloud", id: id)])
        var cloud: Data?
        try a.sync(&cloud, at: at(0))
        let cloudRule = a.config.rules[0]

        var proposal = makeRule("Vorschlag", id: id)
        proposal.action = .open(firefox)
        proposal.pendingChange = PendingChange(since: at(0), reason: "neu angelegt von außen (CLI/MCP)", previous: nil)
        var b = Mac(name: "B", rules: [proposal])
        try b.sync(&cloud, at: at(10))
        #expect(b.config.rules.count == 1)
        let rule = b.config.rules[0]
        #expect(rule.name == "In iCloud")
        #expect(rule.action == .open(firefox))
        #expect(rule.pendingChange?.previous == cloudRule)
        #expect(rule.effective == cloudRule)
        #expect(try doc(cloud).rules.map(\.rule) == [cloudRule])
        let next = try b.sync(&cloud, at: at(20))
        #expect(!next.localChanged && !next.remoteChanged)
    }

    @Test func futureTimesFromCloudAreCapped() throws {
        var a = Mac(name: "A", rules: [makeRule("Regel")])
        var cloud: Data?
        try a.sync(&cloud, at: at(0))
        // Anderer Mac mit falsch gehender Uhr: einen Tag in der Zukunft.
        var document = try doc(cloud)
        document.rules[0].rule.name = "Zukunft"
        document.rules[0].modifiedAt = at(86_400)
        document.deleted = [SyncTombstone(id: UUID(), deletedAt: at(86_400))]
        document.settings.appearance = SyncRegister(value: .dark, modifiedAt: at(86_400))
        cloud = try SyncFileStore.encode(document)

        try a.sync(&cloud, at: at(100))
        #expect(a.names == ["Zukunft"])
        #expect(a.config.appearance == .dark)
        let capped = try doc(cloud)
        #expect(capped.rules[0].modifiedAt == at(400))
        #expect(capped.deleted[0].deletedAt == at(400))
        #expect(capped.settings.appearance.modifiedAt == at(400))

        // Eine Änderung zehn Minuten später gewinnt trotzdem.
        a.config.rules[0].name = "Jetzt"
        try a.sync(&cloud, at: at(700))
        #expect(try doc(cloud).rules[0].rule.name == "Jetzt")
    }

    /// Mac B geht eine Stunde vor: A begrenzt B's Zeiten, B übernimmt die begrenzten – kein Ping-Pong.
    @Test func clockSkewDoesNotCausePingPong() throws {
        let skew: TimeInterval = 3600
        var a = Mac(name: "A", rules: [makeRule("Eins"), makeRule("Zwei"), makeRule("Drei")])
        var b = Mac(name: "B")
        var cloud: Data?
        try a.sync(&cloud, at: at(0))
        try b.sync(&cloud, at: at(10 + skew))

        // B ändert eine Regel, löscht eine, stellt um und ändert eine Einstellung – mit vorgehender Uhr.
        b.config.rules[0].name = "Eins (B)"
        b.config.rules.removeAll { $0.name == "Drei" }
        b.config.rules.reverse()
        b.config.appearance = .dark
        try b.sync(&cloud, at: at(20 + skew))

        var aChanges: [Bool] = []
        var bChanges: [Bool] = []
        for round in 0..<5 {
            let base = TimeInterval(100 + round * 60)
            aChanges.append(try a.sync(&cloud, at: at(base)).remoteChanged)
            bChanges.append(try b.sync(&cloud, at: at(base + 30 + skew)).remoteChanged)
        }
        #expect(aChanges.suffix(3) == [false, false, false])
        #expect(bChanges.suffix(3) == [false, false, false])
        #expect(a.config.rules == b.config.rules)
        #expect(a.names == ["Zwei", "Eins (B)"])
        #expect(a.config.appearance == .dark)
    }

    @Test func subsumedConflictVersionDoesNotForceWrite() throws {
        var a = Mac(name: "A", rules: [makeRule("Eins")])
        var cloud: Data?
        try a.sync(&cloud, at: at(0))
        let older = try doc(cloud)
        a.config.rules.append(makeRule("Zwei"))
        try a.sync(&cloud, at: at(10))
        let current = try doc(cloud)
        let result = SyncEngine.sync(config: a.config, state: a.state, remote: [current, older], device: a.device, now: at(20))
        #expect(!result.localChanged)
        #expect(!result.remoteChanged)
    }

    // MARK: Zufällige Abläufe

    /// Feste Zufallsfolge (reproduzierbar): Anlegen, Ändern, Löschen, Umsortieren und Einstellungen auf drei
    /// Macs, abwechselnd synchronisiert. Danach haben alle denselben Stand, und weitere Runden ändern nichts.
    @Test(arguments: [1, 7, 42, 1234, 99_999] as [UInt64])
    func randomEditsConverge(seed: UInt64) throws {
        var random = SeededRandom(seed: seed)
        var macs = [Mac(name: "A", rules: [makeRule("Start")]), Mac(name: "B"), Mac(name: "C")]
        var cloud: Data?
        var clock: TimeInterval = 0
        for _ in 0..<120 {
            clock += Double(random.next(in: 1...30))
            let index = random.next(in: 0...2)
            var mac = macs[index]
            switch random.next(in: 0...6) {
            case 0, 1:
                mac.config.rules.insert(makeRule("R\(random.next(in: 0...999))"), at: random.next(in: 0...mac.config.rules.count))
            case 2 where !mac.config.rules.isEmpty:
                mac.config.rules[random.next(in: 0...mac.config.rules.count - 1)].name += "'"
            case 3 where !mac.config.rules.isEmpty:
                mac.config.rules.remove(at: random.next(in: 0...mac.config.rules.count - 1))
            case 4 where mac.config.rules.count > 1:
                let rule = mac.config.rules.remove(at: random.next(in: 0...mac.config.rules.count - 1))
                mac.config.rules.insert(rule, at: random.next(in: 0...mac.config.rules.count))
            case 5:
                mac.config.appearance = [nil, .light, .dark][random.next(in: 0...2)]
            default:
                try mac.sync(&cloud, at: at(clock))
            }
            macs[index] = mac
        }
        for _ in 0..<2 {
            for index in macs.indices {
                clock += 1
                try macs[index].sync(&cloud, at: at(clock))
            }
        }
        #expect(macs[0].config.rules == macs[1].config.rules)
        #expect(macs[1].config.rules == macs[2].config.rules)
        #expect(macs[0].config.appearance == macs[2].config.appearance)
        #expect(macs[0].config.rules.map(\.id) == (try doc(cloud)).rules.map(\.rule.id))
        for index in macs.indices {
            clock += 1
            let result = try macs[index].sync(&cloud, at: at(clock))
            #expect(!result.localChanged && !result.remoteChanged)
        }
    }

    // MARK: Zusammenfassung

    @Test func summaryText() {
        let summary = SyncSummary(added: ["a", "b"], changed: ["c"], removed: ["d"], settingsChanged: true)
        #expect(summary.text == "2 neu, 1 geändert, 1 gelöscht, Einstellungen geändert")
        #expect(SyncSummary().text == "keine Änderungen")
    }
}

@Suite("iCloud-Sync: Dateien")
struct SyncFileStoreTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "AirTrafficSync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func document(rules: [Rule] = [makeRule("Eins")], at date: Date = t0) -> SyncDocument {
        let register = { (value: Action) in SyncRegister(value: value, modifiedAt: date) }
        return SyncDocument(
            rules: rules.map { SyncedRule(rule: $0, modifiedAt: date) },
            deleted: [SyncTombstone(id: UUID(), deletedAt: date)],
            orderModifiedAt: date,
            settings: SyncSettings(
                defaultAction: register(.prompt(.all)),
                extensionSettings: SyncRegister(value: nil, modifiedAt: date),
                appearance: SyncRegister(value: .dark, modifiedAt: date)
            ),
            updatedAt: date,
            updatedBy: SyncDevice(deviceID: UUID(), name: "Test-Mac")
        )
    }

    @Test func roundTripIsStableWithMilliseconds() throws {
        let doc = document(at: Date(timeIntervalSince1970: 1_800_000_000.2346))
        let data = try SyncFileStore.encode(doc)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""updatedAt" : "2027-01-15T08:00:00.235Z""#))
        let decoded = try SyncFileStore.decode(data)
        #expect(try SyncFileStore.encode(decoded) == data)
        #expect(decoded.updatedAt == SyncClock.normalize(doc.updatedAt))
    }

    @Test func rejectsNewerFormatVersion() throws {
        let json = #"{"formatVersion": 2, "rules": "irgendwas Neues"}"#
        #expect(throws: SyncFileStore.StoreError.newerFormat(2)) { try SyncFileStore.decode(Data(json.utf8)) }
    }

    @Test func rejectsTooManyRulesAndTooLargeFiles() throws {
        let rules = (0...SyncFileStore.maxRules).map { _ in makeRule("R") }
        let data = try SyncFileStore.encode(document(rules: rules))
        #expect(throws: SyncFileStore.StoreError.self) { try SyncFileStore.decode(data) }

        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SyncFileStore(directoryURL: dir)
        try Data(count: SyncFileStore.maxBytes + 1).write(to: store.fileURL)
        #expect(throws: SyncFileStore.StoreError.tooLarge(bytes: SyncFileStore.maxBytes + 1)) { try store.read() }
    }

    @Test func writeChecksFingerprint() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SyncFileStore(directoryURL: dir.appending(path: "Air Traffic"))
        let empty = try store.read()
        #expect(empty.document == nil && empty.fingerprint == nil)

        let doc = document()
        guard case .saved(let fingerprint) = try store.write(doc, ifUnchangedSince: nil) else {
            Issue.record("nicht gespeichert")
            return
        }
        // Datei existiert inzwischen: Schreiben „ohne bekannten Stand“ ist ein Konflikt.
        #expect(try store.write(doc, ifUnchangedSince: nil) == .conflict)

        let snapshot = try store.read()
        #expect(snapshot.fingerprint == fingerprint)
        #expect(snapshot.document?.hasSameContent(as: doc) == true)
        #expect(snapshot.conflicts.isEmpty)
        #expect(snapshot.documents.count == 1)

        // Anderer Mac schreibt dazwischen.
        let other = document(rules: [makeRule("Anders")])
        #expect(try store.write(other, ifUnchangedSince: fingerprint) != .conflict)
        #expect(try store.write(doc, ifUnchangedSince: fingerprint) == .conflict)
        #expect(try store.read().document?.rules.first?.rule.name == "Anders")
        try store.resolveConflicts([])
    }

    @Test func defaultDirectoryAndOverride() {
        let home = URL(fileURLWithPath: "/Users/test")
        let standard = SyncFileStore.defaultDirectory(environment: [:], home: home)
        #expect(standard.path(percentEncoded: false).hasPrefix("/Users/test/Library/Mobile Documents/com~apple~CloudDocs/Air Traffic"))
        #expect(SyncFileStore.availabilityRoot(environment: [:], home: home).lastPathComponent == "com~apple~CloudDocs")
        let env = [SyncFileStore.directoryEnvironmentKey: "/tmp/sync-test"]
        #expect(SyncFileStore.defaultDirectory(environment: env, home: home).path(percentEncoded: false).hasPrefix("/tmp/sync-test"))
        #expect(SyncFileStore.availabilityRoot(environment: env, home: home) == SyncFileStore.defaultDirectory(environment: env, home: home))
        #expect(!SyncFileStore.isAvailable(root: URL(fileURLWithPath: "/nicht/vorhanden-\(UUID().uuidString)")))
    }

    @Test func permissionErrorsGetReadableText() {
        let error = CocoaError(.fileReadNoPermission)
        #expect(SyncFileStore.describe(error).contains("Kein Zugriff auf iCloud Drive"))
        #expect(SyncFileStore.describe(SyncFileStore.StoreError.newerFormat(3)).contains("neueren"))
    }

    @Test func ruleWithoutIDInSyncFileIsRejected() throws {
        let rule = makeRule("Ohne ID")
        let json = String(decoding: try SyncFileStore.encode(document(rules: [rule])), as: UTF8.self)
        #expect(try SyncFileStore.decode(Data(json.utf8)).rules.map(\.rule.id) == [rule.id])
        let withoutID = json.replacingOccurrences(of: "\"id\" : \"\(rule.id.uuidString)\",", with: "")
        #expect(withoutID != json)
        #expect(throws: DecodingError.self) { try SyncFileStore.decode(Data(withoutID.utf8)) }
    }

    @Test func onlyMissingFileCountsAsMissing() throws {
        let dir = try tempDir()
        let locked = dir.appending(path: "gesperrt")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path(percentEncoded: false))
            try? FileManager.default.removeItem(at: dir)
        }
        #expect(try SyncFileStore(directoryURL: dir).read().document == nil)

        let store = SyncFileStore(directoryURL: locked)
        do {
            _ = try store.read()
            Issue.record("Lesen ohne Rechte darf nicht als „fehlt“ gelten")
        } catch {
            #expect(SyncFileStore.describe(error).contains("Kein Zugriff auf iCloud Drive"))
        }
        #expect(throws: (any Error).self) { try store.write(document(), ifUnchangedSince: nil) }
    }

    @Test func writeRespectsLimits() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SyncFileStore(directoryURL: dir)
        let exists = { FileManager.default.fileExists(atPath: store.fileURL.path(percentEncoded: false)) }

        let many = document(rules: (0...SyncFileStore.maxRules).map { _ in makeRule("R") })
        #expect(throws: SyncFileStore.StoreError.tooManyRulesToWrite(SyncFileStore.maxRules + 1)) {
            try store.write(many, ifUnchangedSince: nil)
        }
        #expect(!exists())

        let huge = document(rules: [makeRule(String(repeating: "x", count: SyncFileStore.maxBytes))])
        do {
            _ = try store.write(huge, ifUnchangedSince: nil)
            Issue.record("zu große Datei geschrieben")
        } catch SyncFileStore.StoreError.tooLargeToWrite {
        } catch {
            Issue.record("falscher Fehler: \(error)")
        }
        #expect(!exists())

        // Vorhandene Datei über der Grenze: nicht einlesen, nicht überschreiben.
        let big = Data(count: SyncFileStore.maxBytes + 1)
        try big.write(to: store.fileURL)
        #expect(throws: SyncFileStore.StoreError.tooLarge(bytes: SyncFileStore.maxBytes + 1)) {
            try store.write(document(), ifUnchangedSince: "unbekannt")
        }
        #expect(try Data(contentsOf: store.fileURL) == big)
        #expect(SyncFileStore.describe(SyncFileStore.StoreError.tooManyRulesToWrite(1001)).contains("nichts übertragen"))
    }

    @Test func stateStoreLivesNextToConfig() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SyncStateStore(configFileURL: dir.appending(path: "config.json"))
        #expect(store.fileURL.lastPathComponent == "config.sync-state.json")
        #expect(SyncStateStore(configFileURL: dir.appending(path: "test.json")).fileURL.lastPathComponent == "test.sync-state.json")
        #expect(try store.load() == nil)

        let id = UUID()
        let state = SyncState(
            enabled: true,
            lastSyncedAt: t0,
            lastRemoteUpdate: SyncUpdateInfo(at: t0, by: SyncDevice(deviceID: UUID(), name: "B")),
            rules: [id: SyncStamp(hash: "abc", modifiedAt: t0)],
            order: [id],
            orderModifiedAt: t0,
            deleted: [SyncTombstone(id: UUID(), deletedAt: t0)]
        )
        try store.save(state)
        #expect(try store.load() == state)
        #expect(String(decoding: try Data(contentsOf: store.fileURL), as: UTF8.self).contains(id.uuidString))
    }
}

/// Reproduzierbare Zufallsfolge (SplitMix64).
private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func nextValue() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(nextValue() % UInt64(range.count))
    }
}
