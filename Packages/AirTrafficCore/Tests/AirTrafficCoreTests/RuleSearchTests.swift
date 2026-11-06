import Foundation
import Testing
@testable import AirTrafficCore

@Suite("RuleSearch")
struct RuleSearchTests {
    static let chrome = AppRef(bundleIdentifier: "com.google.Chrome", path: "/Applications/Google Chrome.app", displayName: "Google Chrome")
    static let linear = AppRef(bundleIdentifier: "com.linear", path: "/Applications/Linear.app", displayName: "Linear")

    static let rules: [Rule] = [
        Rule(name: "Personio", conditions: [.url(TextMatch(op: .contains, value: "personio.de"))], action: .open(chrome)),
        Rule(
            name: "GitHub PR",
            conditions: [.host(TextMatch(op: .equals, value: "github.com"))],
            rewrites: [Rewrite(pattern: "^https://github\\.com/(.*)$", template: "https://linear.review/$1")],
            action: .open(linear)
        ),
        Rule(name: "Aus Slack", conditions: [.sourceApp(bundleIdentifier: "com.tinyspeck.slackmacgap", negated: false)], action: .prompt(.all)),
    ]

    @Test("leere Suche liefert alles")
    func emptyQuery() {
        #expect(RuleSearch.filter(Self.rules, query: "  ").count == 3)
    }

    @Test(arguments: [
        ("personio", ["Personio"]),          // Name
        ("PERSONIO.DE", ["Personio"]),       // Bedingungswert, Groß/klein egal
        ("github.com", ["GitHub PR"]),       // Host-Wert
        ("linear.review", ["GitHub PR"]),    // Umschreibungs-Vorlage
        ("chrome", ["Personio"]),            // Ziel-App
        ("slackmacgap", ["Aus Slack"]),      // Quell-App
        ("github linear", ["GitHub PR"]),    // alle Wörter müssen passen
        ("github chrome", []),
        ("gibtsnicht", []),
    ])
    func finds(query: String, expected: [String]) {
        #expect(RuleSearch.filter(Self.rules, query: query).map(\.name) == expected)
    }
}
