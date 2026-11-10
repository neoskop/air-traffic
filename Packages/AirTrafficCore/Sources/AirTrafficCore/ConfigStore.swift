import Foundation

/// Lädt und speichert `config.json` (menschenlesbar, atomar).
public struct ConfigStore: Sendable {
    /// Überschreibt den Pfad der Konfigurationsdatei (Tests, `--decide`-Läufe).
    public static let pathEnvironmentKey = "AIRTRAFFIC_CONFIG_PATH"

    public enum StoreError: Error, LocalizedError, Equatable {
        case unsupportedSchemaVersion(Int)
        /// Schreibende Zugriffe von außen legen keine neue Konfiguration an.
        case missing(path: String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedSchemaVersion(let v):
                "Konfiguration hat Schema-Version \(v), unterstützt wird \(Config.currentSchemaVersion)."
            case .missing(let path):
                "Keine Konfiguration unter \(path) – Air Traffic einmal starten, dann erneut versuchen."
            }
        }
    }

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `AIRTRAFFIC_CONFIG_PATH` oder `~/Library/Application Support/Air Traffic/config.json`.
    public static func defaultFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment[pathEnvironmentKey], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return support.appending(path: "Air Traffic", directoryHint: .isDirectory)
            .appending(path: "config.json", directoryHint: .notDirectory)
    }

    public static func makeDefault() -> ConfigStore {
        ConfigStore(fileURL: defaultFileURL())
    }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false))
    }

    /// `nil`, wenn die Datei nicht existiert.
    public func load() throws -> Config? {
        guard exists else { return nil }
        return try ConfigStore.decode(Data(contentsOf: fileURL))
    }

    public func save(_ config: Config) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try ConfigStore.encode(config).write(to: fileURL, options: .atomic)
    }

    public static func encode(_ config: Config) throws -> Data {
        var data = try makeEncoder().encode(config)
        data.append(0x0A)
        return data
    }

    public static func decode(_ data: Data) throws -> Config {
        // Schema-Version zuerst: Eine Datei aus einer neueren Version kann Werte enthalten, die dieser
        // Stand nicht dekodieren kann. Das ist dann „neuere Version“, nicht „defekt“.
        if let version = (try? JSONDecoder().decode(SchemaProbe.self, from: data))?.schemaVersion,
           version > Config.currentSchemaVersion {
            throw StoreError.unsupportedSchemaVersion(version)
        }
        let config = try JSONDecoder().decode(Config.self, from: data)
        guard config.schemaVersion <= Config.currentSchemaVersion else {
            throw StoreError.unsupportedSchemaVersion(config.schemaVersion)
        }
        return config
    }

    private struct SchemaProbe: Decodable {
        var schemaVersion: Int?
    }

    /// Warum sich eine vorhandene Konfigurationsdatei nicht laden ließ – davon hängt ab, ob die App
    /// sie anfassen darf.
    public enum LoadFailure: Sendable, Equatable {
        /// Aus einer neueren Version: nicht verschieben, nicht überschreiben.
        case newerSchema(Int)
        /// Kein gültiges Konfigurations-JSON: beiseitelegen und neu beginnen.
        case corrupt
        /// Nicht lesbar (Rechte, Koordination, E/A): nicht verschieben, nicht überschreiben.
        case unreadable
    }

    public static func loadFailure(for error: any Error) -> LoadFailure {
        if case StoreError.unsupportedSchemaVersion(let version) = error { return .newerSchema(version) }
        if error is DecodingError { return .corrupt }
        return .unreadable
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
