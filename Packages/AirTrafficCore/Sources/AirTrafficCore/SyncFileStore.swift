import Foundation

// MARK: - sync.json in iCloud Drive

/// Liest und schreibt `sync.json` koordiniert, mit Fingerabdruck wie `ConfigStore.save(_:ifUnchangedSince:)`.
/// Kann beim Herunterladen aus iCloud blockieren – nie auf dem Main Thread aufrufen.
public struct SyncFileStore: Sendable {
    /// Überschreibt den Sync-Ordner (Tests, Debug). Der Ordner muss existieren.
    public static let directoryEnvironmentKey = "AIRTRAFFIC_SYNC_DIR"
    public static let fileName = "sync.json"
    /// Obergrenzen beim Lesen; darüber wird nichts übernommen und nichts geschrieben.
    public static let maxBytes = 2 * 1024 * 1024
    public static let maxRules = 1000

    public enum StoreError: Error, LocalizedError, Equatable {
        /// Aus einer neueren Air-Traffic-Version: nicht übernehmen, nicht überschreiben.
        case newerFormat(Int)
        case tooLarge(bytes: Int)
        case tooManyRules(Int)
        /// Der eigene Stand überschreitet die Grenzen – es wird nichts geschrieben.
        case tooLargeToWrite(bytes: Int)
        case tooManyRulesToWrite(Int)
        /// iCloud Drive (bzw. der Override-Ordner) fehlt.
        case unavailable

        public var errorDescription: String? {
            switch self {
            case .newerFormat(let version):
                "Die Sync-Datei stammt von einer neueren Air-Traffic-Version (Format \(version)). Bitte Air Traffic aktualisieren."
            case .tooLarge(let bytes):
                "Die Sync-Datei ist zu groß (\(bytes / 1024) KB, höchstens \(SyncFileStore.maxBytes / 1024 / 1024) MB)."
            case .tooManyRules(let count):
                "Die Sync-Datei enthält zu viele Regeln (\(count), höchstens \(SyncFileStore.maxRules))."
            case .tooLargeToWrite(let bytes):
                "Die Regeln sind für iCloud-Sync zu umfangreich (\(bytes / 1024) KB, höchstens \(SyncFileStore.maxBytes / 1024 / 1024) MB) – es wird nichts übertragen."
            case .tooManyRulesToWrite(let count):
                "Zu viele Regeln für iCloud-Sync (\(count), höchstens \(SyncFileStore.maxRules)) – es wird nichts übertragen."
            case .unavailable:
                "iCloud Drive ist nicht verfügbar."
            }
        }
    }

    /// Unaufgelöste Konfliktversion von `sync.json` (iCloud hat zwei Stände nicht selbst zusammengeführt).
    public struct ConflictVersion: Sendable, Equatable {
        public var document: SyncDocument
        /// Ablage der Version; dient beim Auflösen als Kennung.
        public var url: URL
    }

    /// Gelesener Stand: `document == nil`, wenn es die Datei noch nicht gibt.
    public struct Snapshot: Sendable, Equatable {
        public var document: SyncDocument?
        public var fingerprint: String?
        public var conflicts: [ConflictVersion]
        /// Konfliktversionen, die nicht lesbar, zu groß oder aus einer neueren Version waren (Fehlertext);
        /// sie bleiben liegen und werden nicht eingemischt.
        public var skippedConflicts: [String] = []

        public init(document: SyncDocument?, fingerprint: String?, conflicts: [ConflictVersion], skippedConflicts: [String] = []) {
            self.document = document
            self.fingerprint = fingerprint
            self.conflicts = conflicts
            self.skippedConflicts = skippedConflicts
        }

        /// Hauptstand und Konfliktversionen zum gemeinsamen Merge.
        public var documents: [SyncDocument] {
            (document.map { [$0] } ?? []) + conflicts.map(\.document)
        }
    }

    public enum SaveOutcome: Sendable, Equatable {
        case saved(fingerprint: String)
        /// Datei wurde inzwischen geändert (anderer Mac) – nicht überschrieben.
        case conflict
    }

    /// Ordner mit `sync.json`.
    public let directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public var fileURL: URL {
        directoryURL.appending(path: SyncFileStore.fileName, directoryHint: .notDirectory)
    }

    // MARK: Ablageort

    /// `~/Library/Mobile Documents/com~apple~CloudDocs` – existiert, wenn iCloud Drive eingeschaltet ist.
    public static func iCloudDriveRoot(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> URL {
        home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
    }

    /// `AIRTRAFFIC_SYNC_DIR` oder `iCloud Drive/Air Traffic`.
    public static func defaultDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) -> URL {
        if let override = environment[directoryEnvironmentKey], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return iCloudDriveRoot(home: home).appending(path: "Air Traffic", directoryHint: .isDirectory)
    }

    /// Ordner, dessen Existenz „iCloud Drive verfügbar“ bedeutet: der Override-Ordner selbst bzw. iCloud Drive.
    public static func availabilityRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) -> URL {
        if let override = environment[directoryEnvironmentKey], !override.isEmpty {
            return defaultDirectory(environment: environment, home: home)
        }
        return iCloudDriveRoot(home: home)
    }

    public static func makeDefault(environment: [String: String] = ProcessInfo.processInfo.environment) -> SyncFileStore {
        SyncFileStore(directoryURL: defaultDirectory(environment: environment))
    }

    /// iCloud Drive bzw. der Override-Ordner existiert.
    public static func isAvailable(root: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path(percentEncoded: false), isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Verständlicher Text für Fehler beim Zugriff; fehlende Rechte (TCC) mit Hinweis.
    public static func describe(_ error: any Error) -> String {
        if let error = error as? StoreError { return error.localizedDescription }
        if isPermissionError(error) {
            return "Kein Zugriff auf iCloud Drive. Erlaube Air Traffic den Zugriff unter Systemeinstellungen → Datenschutz & Sicherheit → Dateien und Ordner."
        }
        if error is DecodingError { return "Die Sync-Datei ist nicht lesbar (kein gültiges Format)." }
        return "Sync fehlgeschlagen: \(error.localizedDescription)"
    }

    static func isPermissionError(_ error: any Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain,
           [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(ns.code) { return true }
        if ns.domain == NSPOSIXErrorDomain, [Int(EPERM), Int(EACCES)].contains(ns.code) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError { return isPermissionError(underlying) }
        return false
    }

    // MARK: Kodierung

    public static func encode(_ document: SyncDocument) throws -> Data {
        var data = try SyncClock.makeEncoder().encode(document)
        data.append(0x0A)
        return data
    }

    /// Kodiert zum Schreiben; dieselben Grenzen wie beim Lesen, damit kein Mac eine Datei erzeugt, die
    /// die anderen ablehnen.
    public static func encodeForWriting(_ document: SyncDocument) throws -> Data {
        guard document.rules.count <= maxRules else { throw StoreError.tooManyRulesToWrite(document.rules.count) }
        let data = try encode(document)
        guard data.count <= maxBytes else { throw StoreError.tooLargeToWrite(bytes: data.count) }
        return data
    }

    public static func decode(_ data: Data) throws -> SyncDocument {
        guard data.count <= maxBytes else { throw StoreError.tooLarge(bytes: data.count) }
        // Formatversion zuerst: Eine neuere Datei kann Werte enthalten, die dieser Stand nicht versteht.
        if let version = (try? JSONDecoder().decode(FormatProbe.self, from: data))?.formatVersion,
           version > SyncDocument.currentFormatVersion {
            throw StoreError.newerFormat(version)
        }
        if let count = (try? JSONDecoder().decode(CountProbe.self, from: data))?.rules.count, count > maxRules {
            throw StoreError.tooManyRules(count)
        }
        let document = try SyncClock.makeDecoder().decode(SyncDocument.self, from: data)
        guard document.formatVersion <= SyncDocument.currentFormatVersion else {
            throw StoreError.newerFormat(document.formatVersion)
        }
        return document
    }

    private struct FormatProbe: Decodable { var formatVersion: Int? }

    private struct CountProbe: Decodable {
        var rules: [Ignored]
        struct Ignored: Decodable { init(from decoder: any Decoder) throws {} }
    }

    // MARK: Lesen

    /// Liest `sync.json` und unaufgelöste Konfliktversionen. Vorher wird das Herunterladen angestoßen
    /// (Fehler werden ignoriert, z. B. außerhalb von iCloud Drive).
    public func read() throws -> Snapshot {
        try? FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
        var result: Result<Snapshot, any Error> = .success(Snapshot(document: nil, fingerprint: nil, conflicts: []))
        try coordinate(reading: true) { url in
            result = Result {
                guard let data = try SyncFileStore.readLimited(url) else {
                    return Snapshot(document: nil, fingerprint: nil, conflicts: [])
                }
                let document = try SyncFileStore.decode(data)
                let (conflicts, skipped) = conflictVersions(of: url)
                return Snapshot(
                    document: document,
                    fingerprint: ConfigStore.fingerprint(data),
                    conflicts: conflicts,
                    skippedConflicts: skipped
                )
            }
        }
        return try result.get()
    }

    /// `nil` nur, wenn die Datei fehlt (ENOENT); jeder andere Fehler (Rechte, TCC, E/A) wird geworfen.
    /// Einmal öffnen, dann höchstens `limit + 1` Bytes lesen – kein Fenster zwischen Größenprüfung und Lesen.
    static func readLimited(_ url: URL, limit: Int = maxBytes) throws -> Data? {
        let fd = open(url.path(percentEncoded: false), O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            if code == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        if fstat(fd, &info) == 0, Int(info.st_size) > limit {
            throw StoreError.tooLarge(bytes: Int(info.st_size))
        }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw StoreError.tooLarge(bytes: data.count) }
        return data
    }

    /// Lesbare Konfliktversionen; unlesbare, zu große oder neuere werden übersprungen (Fehlertext zurück).
    private func conflictVersions(of url: URL) -> ([ConflictVersion], [String]) {
        var conflicts: [ConflictVersion] = []
        var skipped: [String] = []
        for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] {
            do {
                guard let data = try SyncFileStore.readLimited(version.url) else { continue }
                conflicts.append(ConflictVersion(document: try SyncFileStore.decode(data), url: version.url))
            } catch {
                skipped.append(SyncFileStore.describe(error))
            }
        }
        return (conflicts, skipped)
    }

    /// Nach erfolgreichem Schreiben: die gelesenen (und damit eingemischten) Konfliktversionen als
    /// aufgelöst markieren und entfernen. Inzwischen neu hinzugekommene bleiben für die nächste Runde.
    public func resolveConflicts(_ conflicts: [ConflictVersion]) throws {
        guard !conflicts.isEmpty else { return }
        let handled = Set(conflicts.map(\.url.standardizedFileURL))
        var failure: (any Error)?
        try coordinate(reading: false) { url in
            for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
            where handled.contains(version.url.standardizedFileURL) {
                version.isResolved = true
                do {
                    try version.remove()
                } catch {
                    failure = error
                }
            }
        }
        if let failure { throw failure }
    }

    // MARK: Schreiben

    /// Schreibt nur, wenn die Datei noch dem gelesenen Stand (`knownFingerprint`) entspricht oder fehlt.
    public func write(_ document: SyncDocument, ifUnchangedSince knownFingerprint: String?) throws -> SaveOutcome {
        let data = try SyncFileStore.encodeForWriting(document)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        var outcome: Result<SaveOutcome, any Error>?
        try coordinate(reading: false) { url in
            outcome = Result {
                let current = try SyncFileStore.readLimited(url)
                // Fehlte die Datei beim Lesen, darf sie auch jetzt nicht da sein.
                let unchanged = knownFingerprint == nil
                    ? current == nil
                    : current.map(ConfigStore.fingerprint) == knownFingerprint
                guard unchanged else { return .conflict }
                try data.write(to: url, options: .atomic)
                return .saved(fingerprint: ConfigStore.fingerprint(data))
            }
        }
        guard let outcome else { throw CocoaError(.fileWriteUnknown) }
        return try outcome.get()
    }

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

// MARK: - Gerätelokaler Sync-Zustand

/// `<config>.sync-state.json` neben `config.json` (standardmäßig `config.sync-state.json`); nie in iCloud.
public struct SyncStateStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Neben der Konfigurationsdatei: `config.json` → `config.sync-state.json`.
    public init(configFileURL: URL) {
        let base = configFileURL.deletingPathExtension().lastPathComponent
        self.init(fileURL: configFileURL.deletingLastPathComponent().appending(path: "\(base).sync-state.json"))
    }

    /// `nil`, wenn die Datei fehlt.
    public func load() throws -> SyncState? {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return nil }
        return try SyncClock.makeDecoder().decode(SyncState.self, from: Data(contentsOf: fileURL))
    }

    public func save(_ state: SyncState) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = try SyncClock.makeEncoder().encode(state)
        data.append(0x0A)
        try data.write(to: fileURL, options: .atomic)
    }
}
