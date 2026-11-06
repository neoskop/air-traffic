import Foundation

/// URL-Schema `airtraffic://open?url=<prozentkodiert>[&source=<bundleID>][&prompt=1]` (SPEC §20.1).
///
/// Nur Foundation: die Datei wird zusätzlich in die Safari-Erweiterung kompiliert
/// (`SafariWebExtensionHandler` baut damit die URL), deshalb keine Abhängigkeiten auf den Rest des Cores.
public enum AirTrafficURL {
    public static let scheme = "airtraffic"
    static let openHost = "open"

    /// Inhalt einer gültigen `airtraffic://open`-URL.
    public struct Request: Sendable, Equatable {
        /// Zu öffnender Link, immer http/https.
        public var url: URL
        /// Überschreibt die Quell-App für Regeln; nil → Absender-PID.
        public var source: String?
        /// `prompt=1`: nach den Umschreibungen immer das Auswahlfenster.
        public var prompt: Bool

        public init(url: URL, source: String? = nil, prompt: Bool = false) {
            self.url = url
            self.source = source
            self.prompt = prompt
        }
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        /// Anderes Schema als `airtraffic`.
        case notAirTraffic
        /// Anderer Host/Pfad als `open` bzw. `/`.
        case unsupportedTarget(String)
        case missingURL
        case invalidURL(String)
        /// Nur http/https sind erlaubt (kein `javascript:`, `file:` …).
        case unsupportedScheme(String)

        public var description: String {
            switch self {
            case .notAirTraffic: "Kein airtraffic://-Link"
            case .unsupportedTarget(let target): "Unbekanntes Ziel „\(target)“ (erwartet airtraffic://open)"
            case .missingURL: "Parameter url fehlt"
            case .invalidURL(let value): "Ungültige URL „\(value)“"
            case .unsupportedScheme(let scheme): "Schema „\(scheme)“ nicht erlaubt (nur http/https)"
            }
        }
    }

    /// Ist das ein `airtraffic:`-Link (gleich welcher Host)?
    public static func isAirTrafficURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme
    }

    /// Reine Zerlegung, ohne Seiteneffekte.
    public static func parse(_ url: URL) throws(ParseError) -> Request {
        guard isAirTrafficURL(url) else { throw .notAirTraffic }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw .invalidURL(url.absoluteString)
        }
        let host = (components.host ?? "").lowercased()
        let path = components.path
        guard host == openHost, path.isEmpty || path == "/" else {
            throw .unsupportedTarget(host + path)
        }

        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let raw = value("url"), !raw.isEmpty else { throw .missingURL }
        guard let target = URL(string: raw), let targetScheme = target.scheme?.lowercased() else {
            throw .invalidURL(raw)
        }
        guard targetScheme == "http" || targetScheme == "https" else {
            throw .unsupportedScheme(targetScheme)
        }
        guard let targetHost = target.host(), !targetHost.isEmpty else { throw .invalidURL(raw) }

        let source = value("source").flatMap { $0.isEmpty ? nil : $0 }
        let prompt = value("prompt").map { ["1", "true", "yes"].contains($0.lowercased()) } ?? false
        return Request(url: target, source: source, prompt: prompt)
    }

    /// Baut die URL für `parse` (Gegenstück, von der Safari-Erweiterung genutzt).
    /// Kodiert alle Werte strikt (nur unreservierte Zeichen bleiben), damit `&`, `=`, `#`, `+`
    /// im Link nicht als Trenner gelesen werden.
    public static func make(_ request: Request) -> URL {
        var query = "url=" + encode(request.url.absoluteString)
        if let source = request.source, !source.isEmpty { query += "&source=" + encode(source) }
        if request.prompt { query += "&prompt=1" }
        // Alle Bestandteile sind ASCII und kodiert – URL(string:) kann hier nicht scheitern.
        return URL(string: "\(scheme)://\(openHost)?\(query)")!
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}
