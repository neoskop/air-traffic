import Foundation

// MARK: - iCloud-Sync: Merge

/// Ergebnis einer Sync-Runde.
public struct SyncResult: Sendable, Equatable {
    /// Neue lokale Konfiguration (nur Regeln, Standardaktion, Safari-Verhalten und Darstellung verändert).
    public var config: Config
    /// Neuer gerätelokaler Zustand – erst nach erfolgreichem Speichern der Konfiguration schreiben.
    public var state: SyncState
    /// Neuer Inhalt von `sync.json`.
    public var document: SyncDocument
    /// `config` weicht von der Eingabe ab.
    public var localChanged: Bool
    /// `document` weicht inhaltlich vom iCloud-Stand ab (oder es gab noch keinen) – neu schreiben.
    public var remoteChanged: Bool
    /// Was sich lokal geändert hat (für Log und Mitteilung).
    public var summary: SyncSummary
}

/// Lokale Änderungen einer Sync-Runde. Regelnamen dürfen ins Log, URLs nicht.
public struct SyncSummary: Sendable, Equatable {
    public var added: [String] = []
    public var changed: [String] = []
    public var removed: [String] = []
    public var orderChanged = false
    public var settingsChanged = false

    public init(
        added: [String] = [], changed: [String] = [], removed: [String] = [],
        orderChanged: Bool = false, settingsChanged: Bool = false
    ) {
        self.added = added
        self.changed = changed
        self.removed = removed
        self.orderChanged = orderChanged
        self.settingsChanged = settingsChanged
    }

    public var isEmpty: Bool {
        added.isEmpty && changed.isEmpty && removed.isEmpty && !orderChanged && !settingsChanged
    }

    /// „2 neu, 1 geändert, 1 gelöscht, Reihenfolge geändert, Einstellungen geändert“.
    public var text: String {
        var parts: [String] = []
        if !added.isEmpty { parts.append("\(added.count) neu") }
        if !changed.isEmpty { parts.append("\(changed.count) geändert") }
        if !removed.isEmpty { parts.append("\(removed.count) gelöscht") }
        if orderChanged { parts.append("Reihenfolge geändert") }
        if settingsChanged { parts.append("Einstellungen geändert") }
        return parts.isEmpty ? "keine Änderungen" : parts.joined(separator: ", ")
    }
}

/// Merge zwischen lokaler Konfiguration und `sync.json`: je Regel (UUID) gewinnt die jüngere Änderung,
/// Löschungen als Tombstones, Reihenfolge und Einstellungen je als eigenes Register. Reine Funktionen,
/// keine Ein-/Ausgabe; die Uhrzeit kommt als Parameter.
///
/// Freigabe bleibt unangetastet: Exportiert wird je Regel `rule.effective`. Neu angelegte, noch nicht
/// freigegebene Regeln verlassen den Mac nie, bei geänderten wartenden Regeln geht nur der freigegebene
/// Stand hinaus, und `pendingChange` aus `sync.json` wird beim Lesen verworfen.
public enum SyncEngine {
    /// Tombstones verfallen nach 365 Tagen. War ein Mac länger nicht synchronisiert, gelten seine
    /// unveränderten Regeln, die in iCloud fehlen, als entfernt (sonst lebten sie wieder auf).
    public static let tombstoneLifetime: TimeInterval = 365 * 24 * 60 * 60
    /// Zeitpunkte aus `sync.json` höchstens so weit in der Zukunft (falsch gehende Uhr eines anderen Macs);
    /// sonst gewönne eine solche Änderung gegen alles, was danach kommt.
    public static let maxFutureSkew: TimeInterval = 5 * 60

    /// Eine Runde: `remote` = Inhalt von `sync.json` und ggf. unaufgelöste Konfliktversionen (leer = noch
    /// keine Datei).
    public static func sync(
        config: Config,
        state: SyncState,
        remote: [SyncDocument],
        device: SyncDevice,
        now rawNow: Date
    ) -> SyncResult {
        let now = SyncClock.normalize(rawNow)
        let remoteDocument = combine(remote, now: now)
        let remoteSide = remoteDocument.map { Side(document: $0, now: now) }
        var local = LocalView(config: config, state: state, now: now)
        if state.isFirstSync, let remoteSide { local.dropDuplicates(of: remoteSide) }
        if let lastSyncedAt = state.lastSyncedAt, now.timeIntervalSince(lastSyncedAt) > tombstoneLifetime,
           let remoteSide {
            local.dropRulesRemovedDuringLongAbsence(remote: remoteSide, state: state)
        }

        let merged = merge(local.side, remoteSide, mode: .localAgainstRemote, now: now)
        let newConfig = apply(merged, to: config, local: local)
        // Verglichen wird mit der Hauptdatei: Konfliktversionen allein lösen kein Schreiben aus, nur ein
        // anderer Inhalt (auch begrenzte Zukunftszeiten).
        let mainDocument = remote.first
        let document = makeDocument(merged, remote: mainDocument, device: device, now: now)

        var newState = state
        newState.formatVersion = SyncState.currentFormatVersion
        newState.lastSyncedAt = now
        newState.lastRemoteUpdate = SyncUpdateInfo(at: document.updatedAt, by: document.updatedBy)
        newState.rules = merged.rules.mapValues { SyncStamp(hash: $0.hash, modifiedAt: $0.time) }
        newState.order = merged.order
        newState.orderModifiedAt = merged.orderTime
        newState.settings = SyncSettingsStamps(
            defaultAction: stamp(merged.settings.defaultAction),
            extensionSettings: stamp(merged.settings.extensionSettings),
            appearance: stamp(merged.settings.appearance)
        )
        newState.deleted = merged.sortedTombstones

        let remoteChanged = !(mainDocument.map { document.hasSameContent(as: $0) } ?? false)
        return SyncResult(
            config: newConfig,
            state: newState,
            document: document,
            localChanged: newConfig != config,
            remoteChanged: remoteChanged,
            summary: summarize(old: config, new: newConfig)
        )
    }

    /// Fasst `sync.json` und Konfliktversionen zu einem Stand zusammen (gleiche Regeln wie der Merge,
    /// bei Gleichstand deterministisch).
    public static func combine(_ documents: [SyncDocument], now rawNow: Date) -> SyncDocument? {
        guard var result = documents.first else { return nil }
        let now = SyncClock.normalize(rawNow)
        for next in documents.dropFirst() {
            let merged = merge(Side(document: result, now: now), Side(document: next, now: now), mode: .symmetric, now: now)
            let newer = next.updatedAt > result.updatedAt ? next : result
            result = SyncDocument(
                rules: merged.order.compactMap { id in merged.rules[id].map { SyncedRule(rule: $0.rule, modifiedAt: $0.time) } },
                deleted: merged.sortedTombstones,
                orderModifiedAt: merged.orderTime,
                settings: merged.settings,
                updatedAt: newer.updatedAt,
                updatedBy: newer.updatedBy
            )
        }
        return result
    }

    /// SHA-256 einer Regel, kodiert wie in `config.json`.
    public static func hash(_ rule: Rule) -> String {
        var rule = rule
        rule.pendingChange = nil
        return ConfigStore.fingerprint((try? ConfigStore.makeEncoder().encode(rule)) ?? Data())
    }

    static func hash<Value: Encodable>(setting value: Value) -> String {
        ConfigStore.fingerprint((try? ConfigStore.makeEncoder().encode(SettingBox(value: value))) ?? Data())
    }

    private struct SettingBox<Value: Encodable>: Encodable { var value: Value }

    private static func stamp<Value>(_ register: SyncRegister<Value>) -> SyncStamp {
        SyncStamp(hash: hash(setting: register.value), modifiedAt: register.modifiedAt)
    }

    // MARK: Seiten

    /// Freigegebener Stand einer Regel mit Zeitpunkt.
    struct Entry: Equatable {
        var rule: Rule
        var hash: String
        var time: Date
        /// Lokal ohne Eintrag im Sync-Zustand beim ersten Sync – bei Gleichstand gewinnt iCloud.
        var unknown = false

        init(rule: Rule, time: Date, unknown: Bool = false) {
            var rule = rule
            rule.pendingChange = nil
            self.rule = rule
            self.hash = SyncEngine.hash(rule)
            self.time = time
            self.unknown = unknown
        }
    }

    /// Ein Stand (lokal oder iCloud) in vergleichbarer Form.
    struct Side {
        var rules: [UUID: Entry] = [:]
        var order: [UUID] = []
        var orderTime: Date
        var tombstones: [UUID: Date] = [:]
        var settings: SyncSettings

        var sortedTombstones: [SyncTombstone] {
            tombstones.map { SyncTombstone(id: $0.key, deletedAt: $0.value) }
                .sorted { $0.id.uuidString < $1.id.uuidString }
        }

        init(orderTime: Date, settings: SyncSettings) {
            self.orderTime = orderTime
            self.settings = settings
        }

        /// Zeiten werden auf `now + maxFutureSkew` begrenzt, auch die von Tombstones.
        init(document: SyncDocument, now: Date) {
            let limit = now.addingTimeInterval(SyncEngine.maxFutureSkew)
            func clamp(_ date: Date) -> Date { min(SyncClock.normalize(date), limit) }
            func clamp<Value>(_ register: SyncRegister<Value>) -> SyncRegister<Value> {
                SyncRegister(value: register.value, modifiedAt: clamp(register.modifiedAt))
            }
            orderTime = clamp(document.orderModifiedAt)
            settings = SyncSettings(
                defaultAction: clamp(document.settings.defaultAction),
                extensionSettings: clamp(document.settings.extensionSettings),
                appearance: clamp(document.settings.appearance)
            )
            for synced in document.rules where rules[synced.rule.id] == nil {
                rules[synced.rule.id] = Entry(rule: synced.rule, time: clamp(synced.modifiedAt))
                order.append(synced.rule.id)
            }
            for tombstone in document.deleted where !SyncEngine.isExpired(tombstone.deletedAt, now: now) {
                tombstones[tombstone.id] = max(tombstones[tombstone.id] ?? .distantPast, clamp(tombstone.deletedAt))
            }
        }
    }

    static func isExpired(_ deletedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(deletedAt) > tombstoneLifetime
    }

    /// Lokaler Stand: exportierte Regeln mit abgeleiteten Zeitpunkten, dazu Regeln, die den Mac nicht
    /// verlassen (neu angelegt und wartend).
    struct LocalView {
        var side: Side
        /// IDs neu angelegter, wartender Regeln (und doppelter IDs) – bleiben lokal unberührt.
        var localOnly: Set<UUID> = []
        /// Lokale Dubletten beim ersten Sync, die zugunsten der iCloud-Regel entfallen.
        var droppedDuplicates: Set<UUID> = []
        /// Lokale Regeln je ID (erste bei doppelten IDs).
        var rulesByID: [UUID: Rule] = [:]
        /// Indizes doppelter IDs in `config.rules`; bleiben wie sie sind.
        var duplicateIndices: Set<Int> = []
        let isFirstSync: Bool

        init(config: Config, state: SyncState, now: Date) {
            isFirstSync = state.isFirstSync
            let unknownTime = isFirstSync ? SyncClock.unknown : now
            let settings = SyncSettings(
                defaultAction: LocalView.register(config.defaultAction, state.settings.defaultAction, unknownTime, now),
                extensionSettings: LocalView.register(
                    config.extensionSettings?.isDefault == true ? nil : config.extensionSettings,
                    state.settings.extensionSettings, unknownTime, now
                ),
                appearance: LocalView.register(config.appearance, state.settings.appearance, unknownTime, now)
            )
            side = Side(orderTime: SyncClock.unknown, settings: settings)

            for (index, rule) in config.rules.enumerated() {
                guard rulesByID[rule.id] == nil else {
                    duplicateIndices.insert(index)
                    continue
                }
                rulesByID[rule.id] = rule
                guard let exported = rule.effective else {
                    localOnly.insert(rule.id)
                    continue
                }
                let entry: Entry
                if let known = state.rules[rule.id] {
                    let candidate = Entry(rule: exported, time: now)
                    entry = known.hash == candidate.hash
                        ? Entry(rule: exported, time: SyncClock.normalize(known.modifiedAt))
                        : candidate
                } else {
                    entry = Entry(rule: exported, time: unknownTime, unknown: isFirstSync)
                }
                side.rules[rule.id] = entry
                side.order.append(rule.id)
            }

            // Bekannte Tombstones und lokal gelöschte Regeln.
            for tombstone in state.deleted where !SyncEngine.isExpired(tombstone.deletedAt, now: now) {
                side.tombstones[tombstone.id] = SyncClock.normalize(tombstone.deletedAt)
            }
            for id in state.rules.keys where rulesByID[id] == nil {
                side.tombstones[id] = now
            }

            // Reihenfolge gilt nur als geändert, wenn sich die relative Folge bekannter Regeln ändert.
            if let known = state.orderModifiedAt {
                let present = Set(side.order)
                let previous = state.order.filter(present.contains)
                let previousSet = Set(previous)
                let current = side.order.filter(previousSet.contains)
                side.orderTime = current == previous ? SyncClock.normalize(known) : now
            }
        }

        private static func register<Value: Codable & Sendable & Equatable>(
            _ value: Value, _ stamp: SyncStamp?, _ unknownTime: Date, _ now: Date
        ) -> SyncRegister<Value> {
            guard let stamp else { return SyncRegister(value: value, modifiedAt: unknownTime) }
            let time = stamp.hash == SyncEngine.hash(setting: value) ? SyncClock.normalize(stamp.modifiedAt) : now
            return SyncRegister(value: value, modifiedAt: time)
        }

        /// Erster Sync: Eine lokale Regel ohne Sync-Zustand, deren Inhalt (alles außer `id`) einer
        /// iCloud-Regel entspricht, entfällt zugunsten der iCloud-Regel. Je iCloud-Regel höchstens eine;
        /// wartende Regeln bleiben, damit ihre Änderung nicht verloren geht.
        mutating func dropDuplicates(of remote: Side) {
            var available = remote.order.filter { side.rules[$0] == nil }
            for id in side.order {
                guard let entry = side.rules[id], entry.unknown, remote.rules[id] == nil,
                      rulesByID[id]?.isPendingApproval == false
                else { continue }
                guard let match = available.firstIndex(where: { remoteID in
                    guard let remoteRule = remote.rules[remoteID]?.rule else { return false }
                    var candidate = entry.rule
                    candidate.id = remoteID
                    return candidate == remoteRule
                }) else { continue }
                // Die iCloud-Regel übernimmt den Platz der lokalen Dublette in der lokalen Reihenfolge.
                let remoteID = available.remove(at: match)
                side.rules[id] = nil
                droppedDuplicates.insert(id)
                if let index = side.order.firstIndex(of: id) { side.order[index] = remoteID }
            }
        }

        /// Mac war länger als die Tombstone-Lebensdauer nicht synchronisiert: Regeln, die er kennt, die lokal
        /// unverändert sind und im iCloud-Stand ohne Tombstone fehlen, wurden inzwischen gelöscht (der
        /// Tombstone ist verfallen) – sie entfallen auch hier, statt wieder aufzuleben. Nur in diesem Fall:
        /// im Normalbetrieb könnte ein durch Konflikt verlorener Schreibvorgang sonst Regeln löschen.
        mutating func dropRulesRemovedDuringLongAbsence(remote: Side, state: SyncState) {
            var removed = Set<UUID>()
            for (id, entry) in side.rules {
                guard let known = state.rules[id], known.hash == entry.hash,
                      remote.rules[id] == nil, remote.tombstones[id] == nil
                else { continue }
                removed.insert(id)
            }
            for id in removed { side.rules[id] = nil }
            side.order.removeAll(where: removed.contains)
        }
    }

    // MARK: Merge

    enum Mode {
        /// Lokal gegen iCloud: bei Gleichstand von Reihenfolge und Einstellungen gewinnt iCloud,
        /// bei Regeln ohne lokalen Sync-Zustand ebenfalls.
        case localAgainstRemote
        /// Zwei iCloud-Stände (Konfliktversionen): rein deterministisch.
        case symmetric
    }

    private enum Candidate {
        case rule(Entry, remote: Bool)
        case tombstone(Date)

        var time: Date {
            switch self {
            case .rule(let entry, _): entry.time
            case .tombstone(let date): date
            }
        }
    }

    /// `true`, wenn `a` gegen `b` gewinnt.
    private static func wins(_ a: Candidate, over b: Candidate, mode: Mode) -> Bool {
        if a.time != b.time { return a.time > b.time }
        switch (a, b) {
        case (.rule, .tombstone): return true
        case (.tombstone, _): return false
        case (.rule(let x, let xRemote), .rule(let y, let yRemote)):
            if mode == .localAgainstRemote, xRemote != yRemote {
                // Erster Sync: iCloud gewinnt gegen lokale Regel ohne Sync-Zustand.
                if !xRemote, x.unknown { return false }
                if !yRemote, y.unknown { return true }
            }
            return x.hash < y.hash
        }
    }

    static func merge(_ local: Side, _ remote: Side?, mode: Mode, now: Date) -> Side {
        guard let remote else { return local }
        var result = Side(orderTime: local.orderTime, settings: local.settings)

        // Lokal gegen iCloud bei gleichem Inhalt: iCloud gewinnt samt Zeit, egal welche größer ist. Sonst
        // übernähme ein Mac mit vorgehender Uhr seine eigene (dort begrenzte) Zeit immer wieder aus dem
        // Sync-Zustand, und beide Macs schrieben im Wechsel.
        let prefersRemoteOnEqualContent = mode == .localAgainstRemote
        let ids = Set(local.rules.keys).union(remote.rules.keys).union(local.tombstones.keys).union(remote.tombstones.keys)
        for id in ids {
            var candidates: [Candidate] = []
            if let entry = local.rules[id],
               !(prefersRemoteOnEqualContent && remote.rules[id]?.hash == entry.hash) {
                candidates.append(.rule(entry, remote: false))
            }
            if let date = local.tombstones[id], !(prefersRemoteOnEqualContent && remote.tombstones[id] != nil) {
                candidates.append(.tombstone(date))
            }
            if let entry = remote.rules[id] { candidates.append(.rule(entry, remote: true)) }
            if let date = remote.tombstones[id] { candidates.append(.tombstone(date)) }
            guard var winner = candidates.first else { continue }
            for candidate in candidates.dropFirst() where wins(candidate, over: winner, mode: mode) {
                winner = candidate
            }
            switch winner {
            case .rule(let entry, _): result.rules[id] = entry
            case .tombstone(let date): result.tombstones[id] = date
            }
        }

        // Reihenfolge: gleiche Folge → iCloud samt Zeit; sonst jüngere; Gleichstand → iCloud bzw. deterministisch.
        let localWins: Bool
        if prefersRemoteOnEqualContent, local.order == remote.order {
            localWins = false
        } else if local.orderTime != remote.orderTime {
            localWins = local.orderTime > remote.orderTime
        } else if mode == .localAgainstRemote {
            localWins = false
        } else {
            localWins = local.order.map(\.uuidString).lexicographicallyPrecedes(remote.order.map(\.uuidString))
        }
        let (winner, other) = localWins ? (local, remote) : (remote, local)
        result.orderTime = winner.orderTime
        result.order = mergeOrder(winner: winner.order, other: other.order, survivors: Set(result.rules.keys))

        result.settings = SyncSettings(
            defaultAction: pick(local.settings.defaultAction, remote.settings.defaultAction, mode: mode),
            extensionSettings: pick(local.settings.extensionSettings, remote.settings.extensionSettings, mode: mode),
            appearance: pick(local.settings.appearance, remote.settings.appearance, mode: mode)
        )
        return result
    }

    /// Ordnung des Gewinners, gefiltert auf überlebende Regeln; Fehlende nach ihrem Vorgänger aus der
    /// anderen Liste, sonst vorn.
    static func mergeOrder(winner: [UUID], other: [UUID], survivors: Set<UUID>) -> [UUID] {
        var result: [UUID] = []
        var seen = Set<UUID>()
        for id in winner where survivors.contains(id) && seen.insert(id).inserted { result.append(id) }
        var anchor: UUID?
        for id in other {
            if seen.contains(id) {
                anchor = id
                continue
            }
            guard survivors.contains(id) else { continue }
            let position = anchor.flatMap { result.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            result.insert(id, at: position)
            seen.insert(id)
            anchor = id
        }
        return result
    }

    private static func pick<Value>(_ local: SyncRegister<Value>, _ remote: SyncRegister<Value>, mode: Mode) -> SyncRegister<Value> {
        // Gleicher Wert: iCloud samt Zeit (siehe Regeln).
        if mode == .localAgainstRemote, hash(setting: local.value) == hash(setting: remote.value) { return remote }
        if local.modifiedAt != remote.modifiedAt { return local.modifiedAt > remote.modifiedAt ? local : remote }
        if mode == .localAgainstRemote { return remote }
        return hash(setting: local.value) <= hash(setting: remote.value) ? local : remote
    }

    // MARK: Ergebnis

    /// Neue lokale Konfiguration aus dem Merge. Wartende Regeln behalten ihren Vorschlag; neu angelegte
    /// wartende Regeln bleiben hinter ihrem lokalen Vorgänger.
    private static func apply(_ merged: Side, to config: Config, local: LocalView) -> Config {
        var result = config
        var rules: [Rule] = merged.order.compactMap { id in
            guard let entry = merged.rules[id] else { return nil }
            guard let current = local.rulesByID[id], current.isPendingApproval else { return entry.rule }
            if current.effective.map(SyncEngine.hash) == entry.hash { return current }
            // iCloud-Stand ist neuer: wird der freigegebene Stand, der lokale Vorschlag wartet weiter.
            var rule = entry.rule
            rule.rewrites = current.rewrites
            rule.action = current.action
            if let reason = RuleApproval.riskyChange(from: entry.rule, to: rule) {
                rule.pendingChange = PendingChange(
                    since: current.pendingChange?.since ?? Date(), reason: reason, previous: entry.rule
                )
            } else {
                rule.pendingChange = nil
            }
            return rule
        }

        // Lokal bleibende Regeln (neu und wartend, doppelte IDs) hinter ihren lokalen Vorgänger.
        let placed = Set(rules.map(\.id))
        var anchor: UUID?
        var insertAfterIndex: Int?
        for (index, rule) in config.rules.enumerated() {
            let staysLocal = local.duplicateIndices.contains(index) || (local.localOnly.contains(rule.id) && !placed.contains(rule.id))
            guard staysLocal else {
                if placed.contains(rule.id), !local.duplicateIndices.contains(index) {
                    anchor = rule.id
                    insertAfterIndex = nil
                }
                continue
            }
            let position: Int
            if let insertAfterIndex {
                position = insertAfterIndex + 1
            } else if let anchor, let anchorIndex = rules.firstIndex(where: { $0.id == anchor }) {
                position = anchorIndex + 1
            } else {
                position = 0
            }
            rules.insert(rule, at: position)
            insertAfterIndex = position
        }

        result.rules = rules
        result.defaultAction = merged.settings.defaultAction.value
        result.extensionSettings = merged.settings.extensionSettings.value
        result.appearance = merged.settings.appearance.value
        return result
    }

    private static func makeDocument(_ merged: Side, remote: SyncDocument?, device: SyncDevice, now: Date) -> SyncDocument {
        var document = SyncDocument(
            rules: merged.order.compactMap { id in merged.rules[id].map { SyncedRule(rule: $0.rule, modifiedAt: $0.time) } },
            deleted: merged.sortedTombstones,
            orderModifiedAt: merged.orderTime,
            settings: merged.settings,
            updatedAt: now,
            updatedBy: device
        )
        if let remote, remote.formatVersion == document.formatVersion, document.hasSameContent(as: remote) {
            document.updatedAt = remote.updatedAt
            document.updatedBy = remote.updatedBy
        }
        return document
    }

    static func summarize(old: Config, new: Config) -> SyncSummary {
        let before = Dictionary(old.rules.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let after = Dictionary(new.rules.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var summary = SyncSummary()
        for rule in new.rules {
            if let previous = before[rule.id] {
                if previous != rule { summary.changed.append(rule.name) }
            } else {
                summary.added.append(rule.name)
            }
        }
        for rule in old.rules where after[rule.id] == nil { summary.removed.append(rule.name) }
        let common = Set(before.keys).intersection(after.keys)
        summary.orderChanged = old.rules.map(\.id).filter(common.contains) != new.rules.map(\.id).filter(common.contains)
        summary.settingsChanged = old.defaultAction != new.defaultAction
            || old.extensionSettings != new.extensionSettings
            || old.appearance != new.appearance
        return summary
    }
}

// MARK: - Wann der Sync-Zustand gespeichert wird

/// Zeitpunkt, zu dem eine Runde ihren neuen `SyncState` speichern darf.
public enum SyncStateCommit: Sendable, Equatable {
    /// Vor dem Schreiben von `sync.json` (nach erfolgreichem Speichern der Konfiguration).
    case beforeWrite
    /// Erster Sync ohne gelesenes iCloud-Dokument: erst, wenn `sync.json` tatsächlich neu angelegt wurde.
    /// Sonst bliebe ein Mac, der die Datei (noch) nicht sehen konnte, für immer bei „kein erster Sync“ –
    /// und der iCloud-Stand gewönne beim nächsten Mal nicht mehr.
    case afterSavedWrite

    public static func plan(previous: SyncState, readRemoteDocument: Bool) -> SyncStateCommit {
        previous.isFirstSync && !readRemoteDocument ? .afterSavedWrite : .beforeWrite
    }

    /// Nach dem Schreiben (`outcome == nil` = Schreibfehler oder nicht geschrieben): speichern?
    /// Bei `.beforeWrite` ist der Zustand schon gespeichert.
    public func commitsAfterWrite(_ outcome: SyncFileStore.SaveOutcome?) -> Bool {
        guard self == .afterSavedWrite, case .saved = outcome else { return false }
        return true
    }
}
