import CryptoKit
import Foundation

// MARK: - Koordiniertes Lesen und Schreiben (SPEC §24.4, §24.5)

/// Inhalt der Konfigurationsdatei samt Fingerabdruck (SHA-256 der Bytes).
public struct ConfigSnapshot: Sendable, Equatable {
    public var config: Config
    public var fingerprint: String
    /// In der Datei fehlt bei mindestens einer Regel `id`; die beim Laden vergebenen IDs sollten
    /// zurückgeschrieben werden, damit sie stabil bleiben (§27 K13).
    public var hasRulesWithoutID: Bool

    public init(config: Config, fingerprint: String, hasRulesWithoutID: Bool = false) {
        self.config = config
        self.fingerprint = fingerprint
        self.hasRulesWithoutID = hasRulesWithoutID
    }

    /// Dekodiert Datei-Bytes samt Fingerabdruck.
    public init(data: Data) throws {
        self.init(
            config: try ConfigStore.decode(data),
            fingerprint: ConfigStore.fingerprint(data),
            hasRulesWithoutID: ConfigStore.hasRulesWithoutID(data)
        )
    }
}

/// Ergebnis von `ConfigStore.modify`.
public struct ConfigModification<Value: Sendable>: Sendable {
    /// Rückgabewert der Änderungsfunktion.
    public var value: Value
    /// Konfiguration nach der Änderung (bei `dryRun` nur berechnet, nicht geschrieben).
    public var config: Config
    /// Datei wurde tatsächlich geschrieben.
    public var written: Bool
    /// Sicherungskopie des Stands davor; nil ohne Schreiben.
    public var backupURL: URL?
}

extension ConfigStore {
    /// Aufbewahrung (§26.10): alle Sicherungen der letzten 24 h, höchstens so viele …
    public static let recentBackupLimit = 100
    /// … plus je Tag die neueste (und die älteste) für so viele Tage.
    public static let dailyBackupDays = 14

    /// `…/Air Traffic/backups` neben `config.json`.
    public var backupDirectory: URL {
        fileURL.deletingLastPathComponent().appending(path: "backups", directoryHint: .isDirectory)
    }

    /// SHA-256 (hex) der Datei-Bytes – Grundlage der Konflikterkennung (§24.5).
    public static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Liest die Datei unter `NSFileCoordinator`; `nil`, wenn sie nicht existiert.
    public func coordinatedData() throws -> Data? {
        var result: Result<Data?, any Error> = .success(nil)
        try coordinate(reading: true) { url in
            result = Result {
                FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? try Data(contentsOf: url) : nil
            }
        }
        return try result.get()
    }

    /// Lädt koordiniert samt Fingerabdruck; `nil`, wenn die Datei nicht existiert.
    public func loadSnapshot() throws -> ConfigSnapshot? {
        guard let data = try coordinatedData() else { return nil }
        return try ConfigSnapshot(data: data)
    }

    /// Mindestens eine Regel in `rules` hat kein `id`-Feld (§27 K13).
    public static func hasRulesWithoutID(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rules = object["rules"] as? [Any]
        else { return false }
        return rules.contains { ($0 as? [String: Any])?["id"] == nil }
    }

    /// Läuft gerade die Änderungsfunktion von `modify` (unter der Dateisperre)? Für Tests (§27 K16).
    @TaskLocal static var isInsideModify = false

    /// Lesen-Ändern-Schreiben unter `NSFileCoordinator`, atomar, mit Sicherungskopie (§24.4).
    ///
    /// Fehlt die Datei, wird nichts angelegt (`StoreError.missing`). Ändert `change` nichts oder
    /// ist `dryRun` gesetzt, wird weder gesichert noch geschrieben.
    public func modify<Value: Sendable>(
        dryRun: Bool = false,
        now: Date = Date(),
        _ change: (inout Config) throws -> Value
    ) throws -> ConfigModification<Value> {
        var outcome: Result<ConfigModification<Value>, any Error>?
        try coordinate(reading: false) { url in
            outcome = Result {
                let path = url.path(percentEncoded: false)
                guard FileManager.default.fileExists(atPath: path) else { throw StoreError.missing(path: path) }
                let data = try Data(contentsOf: url)
                let original = try ConfigStore.decode(data)
                var config = original
                let value = try ConfigStore.$isInsideModify.withValue(true) { try change(&config) }
                // Beim Laden vergebene IDs zurückschreiben, auch wenn sich sonst nichts ändert (§27 K13).
                let assignsIDs = ConfigStore.hasRulesWithoutID(data)
                guard !dryRun, config != original || assignsIDs else {
                    return ConfigModification(value: value, config: config, written: false, backupURL: nil)
                }
                let backup = try writeBackup(data, now: now)
                try ConfigStore.encode(config).write(to: url, options: .atomic)
                return ConfigModification(value: value, config: config, written: true, backupURL: backup)
            }
        }
        guard let outcome else { throw CocoaError(.fileWriteUnknown) }
        return try outcome.get()
    }

    /// Ergebnis von `save(_:ifUnchangedSince:)`.
    public enum SaveOutcome: Sendable, Equatable {
        /// Geschrieben; neuer Fingerabdruck.
        case saved(fingerprint: String)
        /// Datei wurde inzwischen von außen geändert – nicht überschrieben (§24.5).
        case conflict(current: ConfigSnapshot)
        /// Von außen geändert, aber nicht lesbar – nicht überschrieben.
        case conflictUnreadable(message: String)
    }

    /// Speichern der App (§24.5): koordiniert und atomar; überschreibt nur, wenn die Datei noch
    /// dem zuletzt geladenen/gespeicherten Stand (`knownFingerprint`) entspricht oder fehlt.
    public func save(_ config: Config, ifUnchangedSince knownFingerprint: String?) throws -> SaveOutcome {
        var outcome: Result<SaveOutcome, any Error>?
        try coordinate(reading: false) { url in
            outcome = Result {
                let path = url.path(percentEncoded: false)
                let current = FileManager.default.fileExists(atPath: path) ? try Data(contentsOf: url) : nil
                switch ConfigSync.saveDecision(known: knownFingerprint, current: current.map(ConfigStore.fingerprint)) {
                case .write:
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    let data = try ConfigStore.encode(config)
                    try data.write(to: url, options: .atomic)
                    return .saved(fingerprint: ConfigStore.fingerprint(data))
                case .reloadInstead:
                    guard let current else { return .saved(fingerprint: "") }
                    do {
                        return .conflict(current: try ConfigSnapshot(data: current))
                    } catch {
                        return .conflictUnreadable(message: error.localizedDescription)
                    }
                }
            }
        }
        guard let outcome else { throw CocoaError(.fileWriteUnknown) }
        return try outcome.get()
    }

    // MARK: Sicherungen

    /// Kopie nach `backups/config-<ISO-Zeit>.json`; danach wird nach Zeit ausgedünnt (§26.10).
    @discardableResult
    func writeBackup(_ data: Data, now: Date) throws -> URL {
        let fm = FileManager.default
        let dir = backupDirectory
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ConfigStore.backupStamp(now)
        var target = dir.appending(path: "config-\(stamp).json")
        var counter = 1
        while fm.fileExists(atPath: target.path(percentEncoded: false)) {
            counter += 1
            target = dir.appending(path: "config-\(stamp)-\(counter).json")
        }
        try data.write(to: target, options: .atomic)
        try pruneBackups(now: now)
        return target
    }

    /// Sicherung eines Stands aus der App, z. B. vor dem Löschen einer Regel (§27 A15).
    @discardableResult
    public func writeBackup(of config: Config, now: Date = Date()) throws -> URL {
        try writeBackup(ConfigStore.encode(config), now: now)
    }

    /// Sicherungen, älteste zuerst.
    public func backups() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        return items
            .filter { $0.lastPathComponent.hasPrefix("config-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func pruneBackups(now: Date, calendar: Calendar = .current) throws {
        let all = backups()
        let keep = ConfigStore.backupsToKeep(all, now: now, calendar: calendar)
        for url in all where !keep.contains(url) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Aufbewahrung nach Zeit (§26.10): alle Sicherungen der letzten 24 h (höchstens
    /// `recentBackupLimit`, die neuesten) plus je Kalendertag der letzten `dailyBackupDays` Tage die
    /// neueste und die älteste. Die älteste eines Tages ist die Sicherung vor der ersten Änderung des
    /// Tages. Sicherungen mit unbekanntem Namen bleiben.
    static func backupsToKeep(_ urls: [URL], now: Date, calendar: Calendar) -> Set<URL> {
        var keep = Set<URL>()
        var dated: [(url: URL, date: Date)] = []
        for url in urls {
            if let date = backupDate(url) {
                dated.append((url, date))
            } else {
                keep.insert(url)
            }
        }
        dated.sort { $0.date > $1.date }

        let recent = dated.filter { now.timeIntervalSince($0.date) < 24 * 60 * 60 }
        keep.formUnion(recent.prefix(recentBackupLimit).map(\.url))

        let today = calendar.startOfDay(for: now)
        var byDay: [Date: [(url: URL, date: Date)]] = [:]
        for item in dated {
            byDay[calendar.startOfDay(for: item.date), default: []].append(item)
        }
        for (day, items) in byDay {
            let age = calendar.dateComponents([.day], from: day, to: today).day ?? Int.max
            guard age < dailyBackupDays else { continue }
            // `items` ist absteigend sortiert: erstes = neueste, letztes = älteste.
            if let newest = items.first { keep.insert(newest.url) }
            if let oldest = items.last { keep.insert(oldest.url) }
        }
        return keep
    }

    /// Zeitpunkt aus `config-2026-11-06T14-22-33.123Z[-2].json`.
    static func backupDate(_ url: URL) -> Date? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("config-") else { return nil }
        let stamp = name.dropFirst("config-".count).prefix("yyyy-MM-ddTHH-mm-ss.SSSZ".count)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss.SSS'Z'"
        return formatter.date(from: String(stamp))
    }

    /// `2026-11-06T14-22-33.123Z` (UTC, Doppelpunkte als Bindestrich – Finder-tauglich, sortierbar).
    static func backupStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss.SSS'Z'"
        return formatter.string(from: date)
    }

    // MARK: Koordination

    private func coordinate(reading: Bool, _ body: (URL) -> Void) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        if reading {
            coordinator.coordinate(readingItemAt: fileURL, options: [], error: &coordinationError, byAccessor: body)
        } else {
            coordinator.coordinate(writingItemAt: fileURL, options: .forMerging, error: &coordinationError, byAccessor: body)
        }
        if let coordinationError { throw coordinationError }
    }
}

// MARK: - Konfliktentscheidung (§24.5)

/// Reine Entscheidungslogik für externe Änderungen; Fingerabdrücke aus `ConfigStore.fingerprint`.
public enum ConfigSync {
    public enum SaveDecision: Sendable, Equatable {
        /// Datei entspricht dem bekannten Stand oder fehlt – schreiben.
        case write
        /// Datei wurde von außen geändert – nicht überschreiben, neu laden.
        case reloadInstead
    }

    public enum ChangeDecision: Sendable, Equatable {
        /// Eigener Speichervorgang oder Datei fehlt (gerade ersetzt/gelöscht) – nichts tun.
        case ignore
        /// Fremde Änderung – neu laden.
        case reload
    }

    /// Vor dem Speichern: `known` = zuletzt geladen/gespeichert, `current` = jetzt auf der Platte.
    public static func saveDecision(known: String?, current: String?) -> SaveDecision {
        guard let current else { return .write }
        return current == known ? .write : .reloadInstead
    }

    /// Nach einer Datei-Benachrichtigung.
    public static func changeDecision(known: String?, current: String?) -> ChangeDecision {
        guard let current else { return .ignore }
        return current == known ? .ignore : .reload
    }
}
