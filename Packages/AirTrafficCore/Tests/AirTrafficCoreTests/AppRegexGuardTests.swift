import Foundation
import Testing

/// Die App-Schicht ruft `NSRegularExpression` nie direkt auf. Jeder Abgleich läuft über den Core
/// (Regex-Cache und Zeitbudget, z. B. `Rewriter.previewMatch`); ein Abgleich ohne Budget im
/// SwiftUI-`body` kann den Main-Thread einfrieren – dann öffnet Air Traffic keine Links mehr.
@Suite("App-Schicht: kein Regex ohne Zeitbudget")
struct AppRegexGuardTests {
    private static let appSources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // AirTrafficCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // AirTrafficCore
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()  // Repo
        .appending(path: "App/Sources", directoryHint: .isDirectory)

    @Test func appSourcesDoNotUseNSRegularExpression() throws {
        let enumerator = try #require(FileManager.default.enumerator(at: Self.appSources, includingPropertiesForKeys: nil))
        let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty, "keine Swift-Dateien unter \(Self.appSources.path)")
        // Nur die Dateinamen kommen in die Meldung, nicht der Inhalt der Dateien.
        let offenders = try files
            .filter { try String(contentsOf: $0, encoding: .utf8).contains("NSRegularExpression") }
            .map(\.lastPathComponent)
            .sorted()
        #expect(offenders.isEmpty, "Regex-Abgleich gehört in den Core (Rewriter.previewMatch, RuleEngine)")
    }
}
