import Foundation
import Testing

/// SPEC §21.1: Safari liest Hintergrund-Skripte nicht zuverlässig als UTF-8 – String-Literale in
/// `SafariExtension/Resources/*.js` enthalten nur ASCII (Umlaute als `\uXXXX`). Kommentare dürfen Umlaute haben.
@Suite("Safari-Erweiterung: ASCII in Skripten")
struct SafariExtensionScriptTests {
    private static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // AirTrafficCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // AirTrafficCore
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()  // Repo
        .appending(path: "SafariExtension/Resources", directoryHint: .isDirectory)

    @Test func scriptStringLiteralsAreASCII() throws {
        let scripts = try FileManager.default.contentsOfDirectory(at: Self.resources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "js" }
        #expect(!scripts.isEmpty, "keine .js-Dateien unter \(Self.resources.path)")
        for script in scripts {
            let source = try String(contentsOf: script, encoding: .utf8)
            let offenders = JSLiterals.nonASCIIStringLiterals(in: source)
            #expect(offenders.isEmpty, "\(script.lastPathComponent): Nicht-ASCII in String-Literalen (als \\uXXXX schreiben): \(offenders)")
        }
    }

    @Test func scannerFindsNonASCIIOnlyInLiterals() {
        let source = """
        // Kommentar mit Ümlaut und „Anführung“
        /* Block: öffnen */
        const a = "Mit Air Traffic \\u00f6ffnen";
        const b = 'ausw\u{E4}hlen';
        const c = `Men\u{FC} ${a}`;
        const d = "escaped \\" quote öffnen";
        """
        #expect(JSLiterals.nonASCIIStringLiterals(in: source) == [
            "'ausw\u{E4}hlen'", "`Men\u{FC} ${a}`", "\"escaped \\\" quote öffnen\"",
        ])
    }
}

/// Minimaler Scanner: überspringt Kommentare, liefert String-Literale ("…", '…', `…`) mit Nicht-ASCII.
private enum JSLiterals {
    static func nonASCIIStringLiterals(in source: String) -> [String] {
        let chars = Array(source)
        var offenders: [String] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if c == "/", next == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
            } else if c == "/", next == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
            } else if c == "\"" || c == "'" || c == "`" {
                let start = i
                i += 1
                while i < chars.count, chars[i] != c {
                    if chars[i] == "\\" { i += 1 }
                    i += 1
                }
                let literal = String(chars[start...min(i, chars.count - 1)])
                if !literal.unicodeScalars.allSatisfy(\.isASCII) { offenders.append(literal) }
                i += 1
            } else {
                i += 1
            }
        }
        return offenders
    }
}
