import Foundation
import Testing
@testable import AirTrafficCore

private func u(_ s: String) -> URL { URL(string: s)! }

private let browserA = AppRef(bundleIdentifier: "com.example.a", path: "/Applications/A.app", displayName: "A")
private let browserB = AppRef(bundleIdentifier: "com.example.b", path: "/Applications/B.app", displayName: "B")

private func host(_ value: String, _ op: TextOp = .equals) -> Condition { .host(TextMatch(op: op, value: value)) }

/// URL-Erkennung im Suchfeld der Regel-Liste (SPEC §22.1).
@Suite("RuleCheck.url(from:)")
struct RuleCheckURLTests {
    @Test(arguments: [
        "https://github.com/acme/webshop/pull/42",
        "http://example.com",
        "HTTPS://Example.com/Pfad",
        "  https://example.com/a?b=c  ",
        "file:///Users/test/Dokument.pdf",
        "slack://channel?team=T1&id=C2",
        "x-acme://open.example/item/1",
    ])
    func recognizesURLs(text: String) {
        let url = RuleCheck.url(from: text)
        #expect(url != nil)
        #expect(url?.absoluteString == text.trimmingCharacters(in: .whitespaces))
    }

    @Test(arguments: [
        "",
        "   ",
        "github.com/acme",
        "github",
        "Pull Requests",
        "https://example.com/a b",
        "https://",
        "http:example.com",
        "mailto:test@example.com",
        "localhost:8080",
        "slack:open",
        "acme://",
    ])
    func keepsTextSearch(text: String) {
        #expect(RuleCheck.url(from: text) == nil)
    }
}

/// `RuleEngine.check` (SPEC §22.5).
@Suite("RuleEngine.check")
struct RuleCheckTests {
    let winner = Rule(name: "acme-Seiten", conditions: [host("acme.example", .endsWith)], action: .open(browserA))
    let shadowed = Rule(name: "Intranet", conditions: [host("intranet.acme.example")], action: .open(browserB))
    let disabled = Rule(name: "Aus", enabled: false, conditions: [host("intranet.acme.example")], action: .open(browserB))
    let other = Rule(
        name: "GitHub-PR",
        conditions: [host("github.com"), .path(TextMatch(op: .beginsWith, value: "/acme/"))],
        action: .open(browserB)
    )

    let url = u("https://intranet.acme.example/wiki/urlaub")

    @Test func statusPerRule() {
        let config = Config(rules: [other, disabled, winner, shadowed], defaultAction: .prompt(.all))
        let r = RuleEngine.check(url: url, context: LinkContext(), config: config)

        #expect(r.entries.map(\.ruleID) == [other.id, disabled.id, winner.id, shadowed.id])
        #expect(r.entries.map(\.position) == [1, 2, 3, 4])
        #expect(r.entries.map(\.matches) == [false, true, true, true])
        #expect(r.entries.map(\.status) == [.noMatch, .disabledMatch, .wins, .shadowed(by: winner.id)])
        #expect(r.matchCount == 3)
        #expect(r.decision.matchedRuleID == winner.id)
        #expect(r.decision.action == .open(browserA))
    }

    @Test func noRuleWins() {
        let config = Config(rules: [other, disabled], defaultAction: .prompt(.running))
        let r = RuleEngine.check(url: url, context: LinkContext(), config: config)
        #expect(r.decision.matchedRuleID == nil)
        #expect(r.decision.action == .prompt(.running))
        #expect(r.decision.finalURL == url)
        #expect(r.entries.map(\.status) == [.noMatch, .disabledMatch])
        #expect(r.matchCount == 1)

        let empty = RuleEngine.check(url: url, context: LinkContext(), config: Config(rules: []))
        #expect(empty.entries.isEmpty)
        #expect(empty.matchCount == 0)
        #expect(empty.decision.matchedRuleID == nil)
    }

    @Test func chainWithRewrite() {
        let pr = TestRules.githubPullRequestToLinearReview()
        let later = Rule(name: "Alles GitHub", conditions: [host("github.com")], action: .open(browserA))
        let config = Config(rules: [pr, later])
        let r = RuleEngine.check(url: u("https://github.com/acme/webshop/pull/7/files"), context: LinkContext(), config: config)
        #expect(r.entries.map(\.status) == [.wins, .shadowed(by: pr.id)])
        #expect(r.decision.finalURL == u("https://linear.review/acme/webshop/pull/7/files"))
        #expect(r.decision.originalURL == u("https://github.com/acme/webshop/pull/7/files"))
        #expect(r.decision.action == .open(TestRules.linearApp))
    }

    @Test(arguments: [
        "https://intranet.acme.example/wiki/urlaub",
        "https://github.com/acme/webshop/pull/7",
        "https://github.com/other/x",
        "https://news.example.com/?utm_source=mail",
        "file:///tmp/a.pdf",
    ])
    func decisionEqualsDecide(text: String) {
        let pr = TestRules.githubPullRequestToLinearReview()
        let broken = Rule(name: "Kaputt", conditions: [.path(TextMatch(op: .regex, value: "(["))], action: .open(browserA))
        let config = Config(rules: [broken, disabled, pr, other, winner, shadowed], defaultAction: .prompt(.all))
        let ctx = LinkContext(sourceBundleIdentifier: "com.apple.mail", modifiers: [.option])
        let r = RuleEngine.check(url: u(text), context: ctx, config: config)
        #expect(r.decision == RuleEngine.decide(url: u(text), context: ctx, config: config))
        #expect(!r.decision.warnings.isEmpty, "Warnung der ungültigen Regex wie bei decide")
    }

    @Test func simulationOfSourceAppAndModifiers() {
        let slack = Rule(
            name: "Slack mit ⌘",
            conditions: [
                .sourceApp(bundleIdentifier: "com.tinyspeck.slackmacgap", negated: false),
                .modifiers([.command], negated: false),
            ],
            action: .prompt(.all)
        )
        let config = Config(rules: [slack, winner])

        let plain = RuleEngine.check(url: url, context: LinkContext(), config: config)
        #expect(plain.entries.map(\.status) == [.noMatch, .wins])
        #expect(plain.entries[0].firstFailedCondition == 0)

        let onlySource = LinkContext(sourceBundleIdentifier: "com.tinyspeck.slackmacgap")
        let partial = RuleEngine.check(url: url, context: onlySource, config: config)
        #expect(partial.entries[0].firstFailedCondition == 1, "Modifier fehlt")

        let full = LinkContext(sourceBundleIdentifier: "com.tinyspeck.slackmacgap", modifiers: [.command])
        let simulated = RuleEngine.check(url: url, context: full, config: config)
        #expect(simulated.entries.map(\.status) == [.wins, .shadowed(by: slack.id)])
        #expect(simulated.decision.matchedRuleID == slack.id)
        #expect(simulated.entries[0].firstFailedCondition == nil)
    }

    @Test func firstFailedConditionOnlyForMatchModeAll() {
        var rule = other
        let config = { (r: Rule) in Config(rules: [r]) }
        let gitlab = u("https://gitlab.com/acme/x")

        #expect(RuleEngine.check(url: gitlab, context: LinkContext(), config: config(rule)).entries[0].firstFailedCondition == 0)
        let wrongPath = u("https://github.com/other/x")
        #expect(RuleEngine.check(url: wrongPath, context: LinkContext(), config: config(rule)).entries[0].firstFailedCondition == 1)

        rule.match = .any
        let any = RuleEngine.check(url: u("https://gitlab.com/x"), context: LinkContext(), config: config(rule)).entries[0]
        #expect(!any.matches)
        #expect(any.firstFailedCondition == nil)

        rule.match = .none
        let none = RuleEngine.check(url: wrongPath, context: LinkContext(), config: config(rule)).entries[0]
        #expect(!none.matches, "Host passt → „keine“ trifft nicht")
        #expect(none.firstFailedCondition == nil)

        // Passende Regel hat keine fehlgeschlagene Bedingung.
        rule.match = .all
        let ok = RuleEngine.check(url: u("https://github.com/acme/x"), context: LinkContext(), config: config(rule)).entries[0]
        #expect(ok.matches)
        #expect(ok.firstFailedCondition == nil)
    }

    @Test func emptyConditionsAlwaysMatch() {
        let always = Rule(name: "Immer", action: .open(browserA))
        let alwaysOff = Rule(name: "Immer, aus", enabled: false, action: .open(browserB))
        let config = Config(rules: [alwaysOff, always, winner])
        let r = RuleEngine.check(url: u("https://example.com"), context: LinkContext(), config: config)
        #expect(r.entries.map(\.status) == [.disabledMatch, .wins, .noMatch])
        #expect(r.entries.map(\.firstFailedCondition) == [nil, nil, 0])
        #expect(r.decision.matchedRuleID == always.id)
    }
}
