import Foundation
import Testing
@testable import AirTrafficCore

@Suite("ChoosyImporter")
struct ChoosyImporterTests {
    static func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
    }

    /// Deterministische Bundle-IDs statt echter Installationen.
    static let fakeBundleIDs: @Sendable (String) -> String? = { path in
        switch path {
        case "/Applications/Example Browser.app": "com.example.browser"
        case "/Applications/Other Browser.app": "com.example.other"
        default: nil
        }
    }

    func importFixture() throws -> ImportResult {
        try ChoosyImporter.importConfig(
            behavioursURL: Self.fixture("behaviours.plist"),
            preferencesURL: Self.fixture("choosy-preferences.plist"),
            bundleIdentifierForPath: Self.fakeBundleIDs
        )
    }

    let example = AppRef(bundleIdentifier: "com.example.browser", path: "/Applications/Example Browser.app", displayName: "Example Browser")
    let other = AppRef(bundleIdentifier: "com.example.other", path: "/Applications/Other Browser.app", displayName: "Other Browser")

    @Test func importsFixture() throws {
        let result = try importFixture()
        let rules = result.config.rules

        #expect(result.config.browsers == [example, other], "Duplikate entfernt, Reihenfolge erhalten")
        #expect(rules.map(\.name) == ["Wiki", "Intranet", "PDFs", "Video calls", "Admin", "Old site", "From mail (prüfen)"])

        // CONTAINS
        #expect(rules[0].match == .all)
        #expect(rules[0].conditions == [.url(TextMatch(op: .contains, value: "wiki.example.org"))])
        #expect(rules[0].action == .open(example))
        #expect(rules[0].enabled)
        // BEGINSWITH
        #expect(rules[1].conditions == [.url(TextMatch(op: .beginsWith, value: "https://intranet.example.com"))])
        #expect(rules[1].action == .open(other))
        // ENDSWITH, unbekanntes Verhalten
        #expect(rules[2].conditions == [.url(TextMatch(op: .endsWith, value: ".pdf"))])
        #expect(rules[2].action == .prompt(.all))
        #expect(result.report.contains { $0.ruleID == rules[2].id && $0.message.contains("Verhalten 2 nicht bekannt") })
        // OR aus zwei CONTAINS
        #expect(rules[3].match == .any)
        #expect(rules[3].conditions == [
            .url(TextMatch(op: .contains, value: "meet.example.net")),
            .url(TextMatch(op: .contains, value: "video.example.net")),
        ])
        // AND aus zwei CONTAINS
        #expect(rules[4].match == .all)
        #expect(rules[4].conditions == [
            .url(TextMatch(op: .contains, value: "example.com")),
            .url(TextMatch(op: .contains, value: "/admin")),
        ])
        // deaktivierte Regel bleibt deaktiviert, ohne Markierung
        #expect(!rules[5].enabled)
        #expect(rules[5].conditions == [.url(TextMatch(op: .contains, value: "old.example.com"))])
        // unbekanntes Feld → deaktiviert + (prüfen) + Hinweis
        #expect(!rules[6].enabled)
        #expect(rules[6].conditions.isEmpty)
        #expect(result.rulesNeedingReview.map(\.id) == [rules[6].id])
        #expect(result.report.contains { $0.ruleID == rules[6].id && $0.message.contains("sourceApp") })
        // TRUEPREDICATE als letzte → Standardaktion, keine Regel
        #expect(result.config.defaultAction == .prompt(.all))
        #expect(result.report.contains { $0.ruleName == "Everything else" && $0.message.contains("Standardaktion") })
        #expect(result.config.schemaVersion == 1)
    }

    @Test func importedRulesBehaveLikeChoosy() throws {
        let config = try importFixture().config
        func decide(_ s: String) -> Decision {
            RuleEngine.decide(url: URL(string: s)!, context: LinkContext(), config: config)
        }
        #expect(decide("https://WIKI.example.org/page").action == .open(example))
        #expect(decide("https://intranet.example.com/x").action == .open(other))
        #expect(decide("https://example.com/admin/users").action == .open(other))
        #expect(decide("https://old.example.com/").matchedRuleID == nil)
        #expect(decide("https://nothing.example/").action == .prompt(.all))
    }

    @Test func trueSetsDefaultOpenAction() {
        let result = ChoosyImporter.importConfig(
            behaviours: [
                ["title": "A", "enabled": true, "predicate": "URL CONTAINS \"a.example\"", "behaviour": 0],
                ["title": "Rest", "enabled": true, "predicate": "TRUEPREDICATE", "behaviour": 6,
                 "behaviourArgument": ["path": "/Applications/Example Browser.app"]],
            ],
            browserPaths: [],
            bundleIdentifierForPath: Self.fakeBundleIDs
        )
        #expect(result.config.rules.count == 1)
        #expect(result.config.defaultAction == .open(example))
    }

    @Test func trueNotLastBecomesUnconditionalRule() {
        let result = ChoosyImporter.importConfig(
            behaviours: [
                ["title": "Immer", "predicate": "TRUEPREDICATE", "behaviour": 6, "behaviourArgument": ["path": "/x/Y.app"]],
                ["title": "Nie erreicht", "predicate": "URL CONTAINS \"x\"", "behaviour": 6, "behaviourArgument": ["path": "/x/Y.app"]],
            ],
            browserPaths: [],
            bundleIdentifierForPath: { _ in nil }
        )
        #expect(result.config.rules.count == 2)
        #expect(result.config.rules[0].conditions.isEmpty)
        #expect(result.config.rules[0].action == .open(AppRef(bundleIdentifier: nil, path: "/x/Y.app", displayName: "Y")))
    }

    @Test(arguments: [
        ("URL == \"https://a.example\"", TextOp.equals, "https://a.example"),
        ("URL != \"https://a.example\"", .notEquals, "https://a.example"),
        ("URL LIKE[c] \"*.example.com*\"", .wildcard, "*.example.com*"),
        ("URL MATCHES \"https://.*\\\\.example\\\\.com/.*\"", .regex, #"^(?:https://.*\.example\.com/.*)$"#),
        ("url CONTAINS \"x\"", .contains, "x"),
    ])
    func operators(format: String, op: TextOp, value: String) {
        #expect(ChoosyImporter.parsePredicate(format) == .conditions(.all, [.url(TextMatch(op: op, value: value))]))
    }

    @Test func flattening() {
        // NOT → none
        #expect(ChoosyImporter.parsePredicate("NOT URL CONTAINS \"a\"")
            == .conditions(.none, [.url(TextMatch(op: .contains, value: "a"))]))
        // NOT(a OR b) → none
        #expect(ChoosyImporter.parsePredicate("NOT (URL CONTAINS \"a\" OR URL CONTAINS \"b\")")
            == .conditions(.none, [.url(.init(op: .contains, value: "a")), .url(.init(op: .contains, value: "b"))]))
        // gleichartige Verschachtelung wird flach
        #expect(ChoosyImporter.parsePredicate("(URL CONTAINS \"a\" AND URL CONTAINS \"b\") AND URL CONTAINS \"c\"")
            == .conditions(.all, ["a", "b", "c"].map { .url(.init(op: .contains, value: $0)) }))
        // a AND NOT b → negierter Operator
        #expect(ChoosyImporter.parsePredicate("URL CONTAINS \"a\" AND NOT URL CONTAINS \"b\"")
            == .conditions(.all, [.url(.init(op: .contains, value: "a")), .url(.init(op: .notContains, value: "b"))]))
    }

    @Test(arguments: [
        "URL CONTAINS \"a\" OR (URL CONTAINS \"b\" AND URL CONTAINS \"c\")",
        "URL CONTAINS",
        "modifierKeys == 1",
        "runningBrowsers CONTAINS \"com.example\"",
        "",
    ])
    func unsupportedPredicates(format: String) {
        guard case .unsupported = ChoosyImporter.parsePredicate(format) else {
            Issue.record("erwartet .unsupported für \(format)")
            return
        }
    }

    @Test func unsupportedRuleIsDisabledAndMarked() {
        let result = ChoosyImporter.importConfig(
            behaviours: [["title": "Mix", "enabled": true,
                          "predicate": "URL CONTAINS \"a\" OR (URL CONTAINS \"b\" AND URL CONTAINS \"c\")",
                          "behaviour": 6, "behaviourArgument": ["path": "/x/Y.app"]]],
            browserPaths: [],
            bundleIdentifierForPath: { _ in nil }
        )
        #expect(result.config.rules[0].name == "Mix (prüfen)")
        #expect(!result.config.rules[0].enabled)
        #expect(result.report.contains { $0.message.contains("Mischform") })
    }

    @Test func missingFilesProduceNotes() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "none-\(UUID().uuidString)")
        let result = try ChoosyImporter.importConfig(
            behavioursURL: dir.appending(path: "behaviours.plist"),
            preferencesURL: dir.appending(path: "prefs.plist")
        )
        #expect(result.config.rules.isEmpty)
        #expect(result.report.count == 2)
        #expect(!ChoosyImporter.choosyFilesExist(
            behavioursURL: dir.appending(path: "behaviours.plist"),
            preferencesURL: dir.appending(path: "prefs.plist")
        ))
    }
}
