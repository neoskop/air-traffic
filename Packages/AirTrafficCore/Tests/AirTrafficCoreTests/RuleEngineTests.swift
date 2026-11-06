import Foundation
import Testing
@testable import AirTrafficCore

private func u(_ s: String) -> URL { URL(string: s)! }

private let browserA = AppRef(bundleIdentifier: "com.example.a", path: "/Applications/A.app", displayName: "A")
private let browserB = AppRef(bundleIdentifier: "com.example.b", path: "/Applications/B.app", displayName: "B")

@Suite("TextOps")
struct TextOpTests {
    struct Case: Sendable, CustomTestStringConvertible {
        var op: TextOp
        var value: String
        var subject: String
        var caseSensitive: Bool
        var expected: Bool
        var testDescription: String { "\(op) \(value) in \(subject) cs=\(caseSensitive) → \(expected)" }
    }

    static let cases: [Case] = [
        // equals / notEquals
        Case(op: .equals, value: "github.com", subject: "github.com", caseSensitive: false, expected: true),
        Case(op: .equals, value: "GitHub.com", subject: "github.com", caseSensitive: false, expected: true),
        Case(op: .equals, value: "GitHub.com", subject: "github.com", caseSensitive: true, expected: false),
        Case(op: .equals, value: "github.co", subject: "github.com", caseSensitive: false, expected: false),
        Case(op: .notEquals, value: "github.com", subject: "gitlab.com", caseSensitive: false, expected: true),
        Case(op: .notEquals, value: "GITHUB.COM", subject: "github.com", caseSensitive: false, expected: false),
        Case(op: .notEquals, value: "GITHUB.COM", subject: "github.com", caseSensitive: true, expected: true),
        // contains / notContains
        Case(op: .contains, value: "Pull", subject: "/a/b/pull/1", caseSensitive: false, expected: true),
        Case(op: .contains, value: "Pull", subject: "/a/b/pull/1", caseSensitive: true, expected: false),
        Case(op: .notContains, value: "issues", subject: "/a/b/pull/1", caseSensitive: false, expected: true),
        Case(op: .notContains, value: "PULL", subject: "/a/b/pull/1", caseSensitive: false, expected: false),
        Case(op: .notContains, value: "PULL", subject: "/a/b/pull/1", caseSensitive: true, expected: true),
        // beginsWith / endsWith
        Case(op: .beginsWith, value: "HTTPS://", subject: "https://x", caseSensitive: false, expected: true),
        Case(op: .beginsWith, value: "HTTPS://", subject: "https://x", caseSensitive: true, expected: false),
        Case(op: .beginsWith, value: "x", subject: "https://x", caseSensitive: false, expected: false),
        Case(op: .endsWith, value: ".PDF", subject: "https://x/doc.pdf", caseSensitive: false, expected: true),
        Case(op: .endsWith, value: ".PDF", subject: "https://x/doc.pdf", caseSensitive: true, expected: false),
        Case(op: .endsWith, value: ".pdf", subject: "https://x/doc.pdf?x=1", caseSensitive: false, expected: false),
        // wildcard (ganzer String wie LIKE)
        Case(op: .wildcard, value: "*.EXAMPLE.com", subject: "www.example.com", caseSensitive: false, expected: true),
        Case(op: .wildcard, value: "*.EXAMPLE.com", subject: "www.example.com", caseSensitive: true, expected: false),
        Case(op: .wildcard, value: "w?w.example.com", subject: "www.example.com", caseSensitive: false, expected: true),
        Case(op: .wildcard, value: "example", subject: "www.example.com", caseSensitive: false, expected: false),
        Case(op: .wildcard, value: "a.c", subject: "abc", caseSensitive: false, expected: false),
        Case(op: .wildcard, value: #"a\*c"#, subject: "a*c", caseSensitive: false, expected: true),
        // regex (Treffer irgendwo)
        Case(op: .regex, value: #"/pull/\d+"#, subject: "/a/b/pull/12/files", caseSensitive: false, expected: true),
        Case(op: .regex, value: "PULL", subject: "/a/b/pull/12", caseSensitive: false, expected: true),
        Case(op: .regex, value: "PULL", subject: "/a/b/pull/12", caseSensitive: true, expected: false),
        Case(op: .regex, value: "^/pull", subject: "/a/pull", caseSensitive: false, expected: false),
        Case(op: .regex, value: "([", subject: "anything", caseSensitive: false, expected: false),
    ]

    @Test(arguments: cases)
    func textOp(_ c: Case) {
        let match = TextMatch(op: c.op, value: c.value, caseSensitive: c.caseSensitive)
        #expect(TextMatcher.matches(match, c.subject) == c.expected)
    }

    @Test func allOpsCovered() {
        #expect(Set(Self.cases.map(\.op)) == Set(TextOp.allCases))
        for op in TextOp.allCases {
            #expect(Self.cases.contains { $0.op == op && $0.caseSensitive }, "caseSensitive-Fall für \(op)")
        }
    }

    @Test func fieldsUseHostPathAndURL() {
        let url = u("https://GitHub.com/owner/repo/pull/1?x=1")
        let ctx = LinkContext()
        #expect(RuleEngine.evaluate(.host(.init(op: .equals, value: "github.com")), url: url, context: ctx))
        #expect(RuleEngine.evaluate(.path(.init(op: .equals, value: "/owner/repo/pull/1")), url: url, context: ctx))
        #expect(RuleEngine.evaluate(.url(.init(op: .endsWith, value: "?x=1")), url: url, context: ctx))
        #expect(!RuleEngine.evaluate(.path(.init(op: .contains, value: "x=1")), url: url, context: ctx))
    }

    @Test func sourceModifiersAndLinkType() {
        let web = u("https://example.com")
        let file = URL(fileURLWithPath: "/tmp/page.html")
        let ctx = LinkContext(sourceBundleIdentifier: "com.tinyspeck.slackmacgap", modifiers: [.command, .shift])
        #expect(RuleEngine.evaluate(.sourceApp(bundleIdentifier: "com.tinyspeck.slackmacgap", negated: false), url: web, context: ctx))
        #expect(!RuleEngine.evaluate(.sourceApp(bundleIdentifier: "com.tinyspeck.slackmacgap", negated: true), url: web, context: ctx))
        #expect(RuleEngine.evaluate(.sourceApp(bundleIdentifier: "com.apple.mail", negated: true), url: web, context: ctx))
        #expect(!RuleEngine.evaluate(.sourceApp(bundleIdentifier: "com.apple.mail", negated: false), url: web, context: LinkContext()))
        #expect(RuleEngine.evaluate(.modifiers([.command, .shift], negated: false), url: web, context: ctx))
        #expect(!RuleEngine.evaluate(.modifiers([.command], negated: false), url: web, context: ctx), "exakte Menge")
        #expect(RuleEngine.evaluate(.modifiers([.command], negated: true), url: web, context: ctx))
        #expect(RuleEngine.evaluate(.linkType(.web), url: web, context: ctx))
        #expect(RuleEngine.evaluate(.linkType(.file), url: file, context: ctx))
        #expect(!RuleEngine.evaluate(.linkType(.web), url: file, context: ctx))
    }
}

@Suite("RuleEngine")
struct RuleEngineTests {
    let hit = Condition.host(.init(op: .equals, value: "example.com"))
    let miss = Condition.host(.init(op: .equals, value: "other.com"))
    let url = u("https://example.com/page")

    func decide(_ rules: [Rule], url: URL? = nil, defaultAction: Action = .prompt(.all)) -> Decision {
        RuleEngine.decide(
            url: url ?? self.url,
            context: LinkContext(),
            config: Config(browsers: [browserA, browserB], rules: rules, defaultAction: defaultAction)
        )
    }

    @Test(arguments: [
        (MatchMode.all, [true, true], true), (.all, [true, false], false), (.all, [false, false], false),
        (.any, [true, false], true), (.any, [false, false], false), (.any, [true, true], true),
        (.none, [false, false], true), (.none, [true, false], false), (.none, [true, true], false),
    ])
    func matchModes(mode: MatchMode, pattern: [Bool], expected: Bool) {
        let rule = Rule(name: "r", match: mode, conditions: pattern.map { $0 ? hit : miss }, action: .open(browserA))
        let d = decide([rule])
        #expect((d.matchedRuleID == rule.id) == expected)
    }

    @Test(arguments: MatchMode.allCases)
    func emptyConditionsAlwaysMatch(mode: MatchMode) {
        let rule = Rule(name: "leer", match: mode, conditions: [], action: .open(browserB))
        let d = decide([rule])
        #expect(d.matchedRuleID == rule.id)
        #expect(d.action == .open(browserB))
    }

    @Test func firstMatchingRuleWins() {
        let first = Rule(name: "1", conditions: [hit], action: .open(browserA))
        let second = Rule(name: "2", conditions: [hit], action: .open(browserB))
        #expect(decide([first, second]).matchedRuleID == first.id)
        #expect(decide([second, first]).matchedRuleID == second.id)
        let nonMatching = Rule(name: "0", conditions: [miss], action: .prompt(.running))
        #expect(decide([nonMatching, second, first]).matchedRuleID == second.id)
    }

    @Test func disabledRuleIsSkipped() {
        let disabled = Rule(name: "aus", enabled: false, conditions: [hit], action: .open(browserA))
        let enabled = Rule(name: "an", conditions: [hit], action: .open(browserB))
        let d = decide([disabled, enabled])
        #expect(d.matchedRuleID == enabled.id)
        #expect(decide([disabled]).matchedRuleID == nil)
    }

    @Test func defaultActionWithoutRewrite() {
        let rule = Rule(
            name: "nie",
            conditions: [miss],
            rewrites: [Rewrite(pattern: ".*", template: "https://rewritten.example")],
            action: .open(browserA)
        )
        let d = decide([rule], defaultAction: .openFirstRunning(fallback: browserB))
        #expect(d.matchedRuleID == nil)
        #expect(d.action == .openFirstRunning(fallback: browserB))
        #expect(d.finalURL == url)
        #expect(d.originalURL == url)
        #expect(d.warnings.isEmpty)
    }

    @Test func emptyConfigPrompts() {
        let d = RuleEngine.decide(url: url, context: LinkContext(), config: Config())
        #expect(d.action == .prompt(.all))
        #expect(d.matchedRuleID == nil)
    }

    @Test func invalidRegexConditionWarnsAndDoesNotMatch() {
        let rule = Rule(name: "kaputt", conditions: [.url(.init(op: .regex, value: "(["))], action: .open(browserA))
        let d = decide([rule])
        #expect(d.matchedRuleID == nil)
        #expect(d.warnings.count == 1)
        #expect(d.warnings[0].contains("kaputt"))
    }
}

@Suite("Rewrite")
struct RewriteTests {
    let config = Config(browsers: [browserA], rules: [TestRules.githubPullRequestToLinearReview()])

    func decide(_ s: String) -> Decision {
        RuleEngine.decide(url: u(s), context: LinkContext(), config: config)
    }

    @Test func githubPullRequestToLinearReview() {
        let d = decide("https://github.com/acme/webshop/pull/3776")
        #expect(d.finalURL.absoluteString == "https://linear.review/acme/webshop/pull/3776")
        #expect(d.originalURL.absoluteString == "https://github.com/acme/webshop/pull/3776")
        #expect(d.matchedRuleID == config.rules[0].id)
        #expect(d.action == .open(AppRef(bundleIdentifier: "com.linear", path: "/Applications/Linear.app", displayName: "Linear")))
        #expect(d.warnings.isEmpty)
    }

    @Test func githubPullRequestWithSuffix() {
        let d = decide("https://github.com/acme/webshop/pull/3776/files?w=1")
        #expect(d.finalURL.absoluteString == "https://linear.review/acme/webshop/pull/3776/files?w=1")
    }

    @Test func githubIssueDoesNotMatch() {
        let d = decide("https://github.com/acme/webshop/issues/12")
        #expect(d.matchedRuleID == nil)
        #expect(d.finalURL.absoluteString == "https://github.com/acme/webshop/issues/12")
        #expect(d.action == .prompt(.all))
    }

    @Test func multipleRewritesInSequence() {
        let rule = Rule(
            name: "kette",
            rewrites: [
                Rewrite(pattern: "^http://", template: "https://"),
                Rewrite(pattern: "[?&]utm_[^&]*", template: ""),
                Rewrite(pattern: "example\\.com", template: "example.org"),
                Rewrite(pattern: "nicht-vorhanden", template: "X"),
            ],
            action: .open(browserA)
        )
        let d = RuleEngine.decide(
            url: u("http://example.com/a?utm_source=x"),
            context: LinkContext(),
            config: Config(rules: [rule])
        )
        #expect(d.finalURL.absoluteString == "https://example.org/a")
        #expect(d.warnings.isEmpty)
    }

    @Test func rewriteCaseSensitivity() throws {
        #expect(try Rewriter.apply(Rewrite(pattern: "EXAMPLE", template: "x"), to: "https://example.com") == "https://x.com")
        #expect(try Rewriter.apply(Rewrite(pattern: "EXAMPLE", template: "x", caseSensitive: true), to: "https://example.com") == "https://example.com")
    }

    @Test func invalidRegexKeepsOriginalAndWarns() {
        let rule = Rule(
            name: "kaputt",
            rewrites: [
                Rewrite(pattern: "example", template: "changed"),
                Rewrite(pattern: "([", template: "x"),
            ],
            action: .open(browserA)
        )
        let original = u("https://example.com/")
        let d = RuleEngine.decide(url: original, context: LinkContext(), config: Config(rules: [rule]))
        #expect(d.finalURL == original)
        #expect(d.matchedRuleID == rule.id)
        #expect(d.warnings.count == 1)
        #expect(d.warnings[0].contains("ungültiger regulärer Ausdruck"))
        #expect(Rewriter.validationError(for: Rewrite(pattern: "([", template: "")) != nil)
        #expect(Rewriter.validationError(for: Rewrite(pattern: "^ok$", template: "")) == nil)
    }

    @Test(arguments: ["$1 $2", "", "kein schema"])
    func rewriteToInvalidURLKeepsOriginalAndWarns(template: String) {
        let rule = Rule(
            name: "ungültig",
            rewrites: [Rewrite(pattern: "^https://([^/]+)/(.*)$", template: template)],
            action: .open(browserA)
        )
        let original = u("https://example.com/path")
        let d = RuleEngine.decide(url: original, context: LinkContext(), config: Config(rules: [rule]))
        #expect(d.finalURL == original)
        #expect(d.warnings.count == 1)
        #expect(d.warnings[0].contains("keine gültige URL"))
    }
}
