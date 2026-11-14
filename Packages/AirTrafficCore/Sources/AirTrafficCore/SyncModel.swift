import Foundation

// MARK: - iCloud-Sync: Datenmodell

/// Gerät, das `sync.json` zuletzt geschrieben hat.
public struct SyncDevice: Codable, Sendable, Equatable, Hashable {
    public var deviceID: UUID
    public var name: String

    public init(deviceID: UUID, name: String) {
        self.deviceID = deviceID
        self.name = name
    }
}

/// Regel in `sync.json` samt Zeitpunkt ihrer letzten Änderung. `rule.pendingChange` ist hier immer `nil`:
/// Über iCloud wandern nur freigegebene Stände, eine wartende Änderung aus der Datei wird verworfen.
public struct SyncedRule: Codable, Sendable, Equatable {
    public var rule: Rule {
        didSet { if rule.pendingChange != nil { rule.pendingChange = nil } }
    }
    public var modifiedAt: Date

    public init(rule: Rule, modifiedAt: Date) {
        var rule = rule
        rule.pendingChange = nil
        self.rule = rule
        self.modifiedAt = modifiedAt
    }

    private enum CodingKeys: String, CodingKey { case rule, modifiedAt }
    private enum RuleIDKey: String, CodingKey { case id }

    /// `id` ist hier Pflicht: `Rule` vergibt sonst bei jedem Lesen eine neue ID, und jeder Mac legte die
    /// Regel bei jeder Runde neu an. Fehlt sie, ist die ganze Datei unlesbar (nichts übernommen, nichts
    /// überschrieben) – `sync.json` schreibt nur Air Traffic, eine Regel ohne ID ist ein Defekt.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _ = try c.nestedContainer(keyedBy: RuleIDKey.self, forKey: .rule).decode(UUID.self, forKey: .id)
        var rule = try c.decode(Rule.self, forKey: .rule)
        // Freigabe bleibt auf dem Mac: wartende Änderungen aus iCloud gelten nie.
        rule.pendingChange = nil
        self.rule = rule
        modifiedAt = try c.decode(Date.self, forKey: .modifiedAt)
    }
}

/// Gelöschte Regel; verhindert, dass ein anderer Mac sie wiederbelebt. Verfällt nach 365 Tagen
/// (`SyncEngine.tombstoneLifetime`).
public struct SyncTombstone: Codable, Sendable, Equatable {
    public var id: UUID
    public var deletedAt: Date

    public init(id: UUID, deletedAt: Date) {
        self.id = id
        self.deletedAt = deletedAt
    }
}

/// Last-Writer-Wins-Register für eine Einstellung.
public struct SyncRegister<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public var value: Value
    public var modifiedAt: Date

    public init(value: Value, modifiedAt: Date) {
        self.value = value
        self.modifiedAt = modifiedAt
    }
}

/// Synchronisierte Einstellungen, je Feld ein eigenes Register.
public struct SyncSettings: Codable, Sendable, Equatable {
    public var defaultAction: SyncRegister<Action>
    /// `nil` = Standard.
    public var extensionSettings: SyncRegister<ExtensionSettings?>
    /// `nil` = System.
    public var appearance: SyncRegister<AppAppearance?>

    public init(
        defaultAction: SyncRegister<Action>,
        extensionSettings: SyncRegister<ExtensionSettings?>,
        appearance: SyncRegister<AppAppearance?>
    ) {
        self.defaultAction = defaultAction
        self.extensionSettings = extensionSettings
        self.appearance = appearance
    }
}

/// Inhalt von `sync.json` in iCloud Drive.
public struct SyncDocument: Codable, Sendable, Equatable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    /// Geordnet wie in der Regel-Liste (erste passende gewinnt).
    public var rules: [SyncedRule]
    public var deleted: [SyncTombstone]
    public var orderModifiedAt: Date
    public var settings: SyncSettings
    public var updatedAt: Date
    public var updatedBy: SyncDevice

    public init(
        formatVersion: Int = SyncDocument.currentFormatVersion,
        rules: [SyncedRule],
        deleted: [SyncTombstone],
        orderModifiedAt: Date,
        settings: SyncSettings,
        updatedAt: Date,
        updatedBy: SyncDevice
    ) {
        self.formatVersion = formatVersion
        self.rules = rules
        self.deleted = deleted
        self.orderModifiedAt = orderModifiedAt
        self.settings = settings
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
    }

    /// Gleicher Inhalt, ohne `updatedAt`/`updatedBy` – entscheidet, ob neu geschrieben werden muss.
    public func hasSameContent(as other: SyncDocument) -> Bool {
        formatVersion == other.formatVersion
            && rules == other.rules
            && deleted == other.deleted
            && orderModifiedAt == other.orderModifiedAt
            && settings == other.settings
    }
}

// MARK: - Gerätelokaler Zustand

/// Zuletzt bekannter Stand eines Eintrags: Hash und Zeitpunkt.
public struct SyncStamp: Codable, Sendable, Equatable {
    public var hash: String
    public var modifiedAt: Date

    public init(hash: String, modifiedAt: Date) {
        self.hash = hash
        self.modifiedAt = modifiedAt
    }
}

/// Wann `sync.json` zuletzt von einem anderen Mac geschrieben wurde (für die Anzeige).
public struct SyncUpdateInfo: Codable, Sendable, Equatable {
    public var at: Date
    public var by: SyncDevice

    public init(at: Date, by: SyncDevice) {
        self.at = at
        self.by = by
    }
}

/// Zuletzt bekannte Stände der Einstellungen.
public struct SyncSettingsStamps: Codable, Sendable, Equatable {
    public var defaultAction: SyncStamp?
    public var extensionSettings: SyncStamp?
    public var appearance: SyncStamp?

    public init(defaultAction: SyncStamp? = nil, extensionSettings: SyncStamp? = nil, appearance: SyncStamp? = nil) {
        self.defaultAction = defaultAction
        self.extensionSettings = extensionSettings
        self.appearance = appearance
    }
}

/// Gerätelokaler Sync-Zustand (`config.sync-state.json` neben `config.json`, nie in iCloud).
/// Aus dem Vergleich mit dem aktuellen Stand ergibt sich, was sich lokal seit dem letzten Sync geändert hat.
/// Beim Ausschalten wird er bis auf `deviceID` zurückgesetzt (`resetForDisabling()`): Erneutes Einschalten ist
/// wieder ein erster Sync – iCloud gewinnt, eigene Regeln kommen dazu, lokale Löschungen aus der Zeit ohne
/// Sync werden nicht übertragen.
public struct SyncState: Codable, Sendable, Equatable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var enabled: Bool
    public var deviceID: UUID
    public var lastSyncedAt: Date?
    public var lastRemoteUpdate: SyncUpdateInfo?
    /// Zuletzt synchronisierter Stand je Regel.
    public var rules: [UUID: SyncStamp]
    public var order: [UUID]
    public var orderModifiedAt: Date?
    public var settings: SyncSettingsStamps
    public var deleted: [SyncTombstone]

    public init(
        enabled: Bool = false,
        deviceID: UUID = UUID(),
        lastSyncedAt: Date? = nil,
        lastRemoteUpdate: SyncUpdateInfo? = nil,
        rules: [UUID: SyncStamp] = [:],
        order: [UUID] = [],
        orderModifiedAt: Date? = nil,
        settings: SyncSettingsStamps = SyncSettingsStamps(),
        deleted: [SyncTombstone] = []
    ) {
        self.formatVersion = SyncState.currentFormatVersion
        self.enabled = enabled
        self.deviceID = deviceID
        self.lastSyncedAt = lastSyncedAt
        self.lastRemoteUpdate = lastRemoteUpdate
        self.rules = rules
        self.order = order
        self.orderModifiedAt = orderModifiedAt
        self.settings = settings
        self.deleted = deleted
    }

    /// Noch nie (bzw. seit dem letzten Ausschalten nicht) synchronisiert.
    public var isFirstSync: Bool { lastSyncedAt == nil }

    /// Zustand nach dem Ausschalten: alles vergessen außer der Geräte-ID.
    public func resetForDisabling() -> SyncState {
        SyncState(enabled: false, deviceID: deviceID)
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, enabled, deviceID, lastSyncedAt, lastRemoteUpdate, rules, order, orderModifiedAt, settings, deleted
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        deviceID = try c.decodeIfPresent(UUID.self, forKey: .deviceID) ?? UUID()
        lastSyncedAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        lastRemoteUpdate = try c.decodeIfPresent(SyncUpdateInfo.self, forKey: .lastRemoteUpdate)
        // Schlüssel als UUID-Text: JSON kennt nur Text-Schlüssel.
        let raw = try c.decodeIfPresent([String: SyncStamp].self, forKey: .rules) ?? [:]
        var rules: [UUID: SyncStamp] = [:]
        for (key, stamp) in raw {
            guard let id = UUID(uuidString: key) else {
                throw DecodingError.dataCorruptedError(forKey: .rules, in: c, debugDescription: "Ungültige Regel-ID \(key)")
            }
            rules[id] = stamp
        }
        self.rules = rules
        order = try c.decodeIfPresent([UUID].self, forKey: .order) ?? []
        orderModifiedAt = try c.decodeIfPresent(Date.self, forKey: .orderModifiedAt)
        settings = try c.decodeIfPresent(SyncSettingsStamps.self, forKey: .settings) ?? SyncSettingsStamps()
        deleted = try c.decodeIfPresent([SyncTombstone].self, forKey: .deleted) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(formatVersion, forKey: .formatVersion)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(deviceID, forKey: .deviceID)
        try c.encodeIfPresent(lastSyncedAt, forKey: .lastSyncedAt)
        try c.encodeIfPresent(lastRemoteUpdate, forKey: .lastRemoteUpdate)
        try c.encode(Dictionary(uniqueKeysWithValues: rules.map { ($0.key.uuidString, $0.value) }), forKey: .rules)
        try c.encode(order, forKey: .order)
        try c.encodeIfPresent(orderModifiedAt, forKey: .orderModifiedAt)
        try c.encode(settings, forKey: .settings)
        try c.encode(deleted, forKey: .deleted)
    }
}

// MARK: - Zeitpunkte

/// Alle Sync-Zeitpunkte sind auf Millisekunden gerundet und werden als ISO 8601 mit Millisekunden
/// gespeichert. So ergeben Lesen und Schreiben dieselben Werte, und Vergleiche sind exakt.
public enum SyncClock {
    /// Auf Millisekunden gerundet, immer auf dieselbe Weise gebaut (bitgleiche `Date`-Werte).
    public static func normalize(_ date: Date) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds(date)) / 1000)
    }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// Zeitstempel für Einträge, die lokal noch nie synchronisiert wurden.
    public static let unknown = Date(timeIntervalSince1970: 0)

    /// Kodierer für `sync.json` und den Sync-Zustand: lesbar, sortierte Schlüssel, ISO-Zeiten mit ms.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = ConfigStore.makeEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(PendingChange.formatDate(date))
        }
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let text = try c.decode(String.self)
            guard let date = PendingChange.parseDate(text) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Ungültige Zeitangabe \(text)")
            }
            return normalize(date)
        }
        return decoder
    }
}
