import Foundation
import Testing
@testable import AirTrafficCore

private func u(_ s: String) -> URL { URL(string: s)! }

private let browserA = AppRef(bundleIdentifier: "com.example.a", path: "/Applications/A.app", displayName: "A")

/// `RuleEngine.test` für den Abschnitt „Test“ im Regel-Editor (SPEC §14.3).
@Suite("RuleEngine.test")
struct RuleTestTests {
    let pr = "https://github.com/acme/webshop/pull/3776"

    func test(_ rule: Rule, _ url: String, config: Config? = nil, context: LinkContext = LinkContext()) -> RuleTestResult {
        RuleEngine.test(rule: rule, url: u(url), context: context, config: config ?? Config(rules: [rule]))
    }

    @Test func matchesAndRewrites() {
        let rule = TestRules.githubPullRequestToLinearReview()
        let r = test(rule, pr)
        #expect(r.matches)
        #expect(r.conditionResults == [true, true])
        #expect(r.rewriteSteps == ["https://linear.review/acme/webshop/pull/3776"])
        #expect(r.finalURL == u("https://linear.review/acme/webshop/pull/3776"))
        #expect(r.warnings.isEmpty)
        #expect(r.shadowedBy == nil)
    }

    @Test func doesNotMatchWithResultPerCondition() {
        let rule = TestRules.githubPullRequestToLinearReview()
        let issue = test(rule, "https://github.com/acme/webshop/issues/12")
        #expect(!issue.matches)
        #expect(issue.conditionResults == [true, false], "Host passt, Pfad nicht")

        let other = test(rule, "https://gitlab.com/a/b/pull/1")
        #expect(!other.matches)
        #expect(other.conditionResults == [false, true])
    }

    @Test(arguments: [
        (MatchMode.all, false), (MatchMode.any, true), (MatchMode.none, false),
    ])
    func matchModeUsesConditionResults(mode: MatchMode, expected: Bool) {
        var rule = TestRules.githubPullRequestToLinearReview()
        rule.match = mode
        let r = test(rule, "https://github.com/a/b/issues/1")
        #expect(r.conditionResults == [true, false])
        #expect(r.matches == expected)
    }

    @Test func emptyConditionsMatch() {
        let r = test(Rule(name: "Immer", action: .open(browserA)), "https://example.com")
        #expect(r.matches)
        #expect(r.conditionResults.isEmpty)
        #expect(r.rewriteSteps.isEmpty)
        #expect(r.finalURL == u("https://example.com"))
    }

    @Test func contextIsUsedForConditions() {
        let rule = Rule(
            name: "Slack mit ⌘",
            conditions: [
                .sourceApp(bundleIdentifier: "com.tinyspeck.slackmacgap", negated: false),
                .modifiers([.command], negated: false),
            ],
            action: .open(browserA)
        )
        #expect(test(rule, "https://example.com").conditionResults == [false, false])
        let ctx = LinkContext(sourceBundleIdentifier: "com.tinyspeck.slackmacgap", modifiers: [.command])
        let r = test(rule, "https://example.com", context: ctx)
        #expect(r.conditionResults == [true, true])
        #expect(r.matches)
    }

    @Test func intermediateStepsForTwoRewrites() {
        let rule = Rule(
            name: "Zwei Schritte",
            rewrites: [
                Rewrite(pattern: "^http://", template: "https://"),
                Rewrite(pattern: #"\?utm_[^#]*"#, template: ""),
            ],
            action: .open(browserA)
        )
        let r = test(rule, "http://example.com/a?utm_source=x")
        #expect(r.rewriteSteps == ["https://example.com/a?utm_source=x", "https://example.com/a"])
        #expect(r.finalURL == u("https://example.com/a"))

        // Zweites Muster trifft nicht → Zwischenergebnis unverändert.
        let plain = test(rule, "http://example.com/b")
        #expect(plain.rewriteSteps == ["https://example.com/b", "https://example.com/b"])
    }

    @Test func warningsForInvalidRegexAndInvalidResult() {
        let rule = Rule(
            name: "Kaputt",
            conditions: [.path(TextMatch(op: .regex, value: "(["))],
            rewrites: [Rewrite(pattern: "([", template: "x")],
            action: .open(browserA)
        )
        let r = test(rule, "https://example.com")
        #expect(r.conditionResults == [false])
        #expect(r.rewriteSteps == ["https://example.com"])
        #expect(r.finalURL == u("https://example.com"))
        #expect(r.warnings.count == 2)
        #expect(r.warnings[0].hasPrefix("Bedingung 1: ungültiger regulärer Ausdruck"))
        #expect(r.warnings[1].hasPrefix("Umschreibung 1: ungültiger regulärer Ausdruck"))

        let noURL = Rule(name: "Kein Schema", rewrites: [Rewrite(pattern: "^.*$", template: "kein url")], action: .open(browserA))
        let bad = test(noURL, "https://example.com")
        #expect(bad.rewriteSteps == ["kein url"])
        #expect(bad.finalURL == u("https://example.com"), "ungültiges Ergebnis → Original-URL")
        #expect(bad.warnings.count == 1)
    }

    @Test func shadowedByEarlierEnabledRule() {
        let catchAll = Rule(name: "Alles GitHub", conditions: [.host(TextMatch(op: .equals, value: "github.com"))], action: .open(browserA))
        let unrelated = Rule(name: "Anders", conditions: [.host(TextMatch(op: .equals, value: "gitlab.com"))], action: .open(browserA))
        let rule = TestRules.githubPullRequestToLinearReview()
        let later = Rule(name: "Danach", action: .open(browserA))
        let config = Config(rules: [unrelated, catchAll, rule, later])

        #expect(test(rule, pr, config: config).shadowedBy == catchAll.id)
        // Nur frühere Regeln zählen: die Regel selbst und spätere nicht.
        #expect(test(unrelated, pr, config: config).shadowedBy == nil)
        #expect(test(later, pr, config: config).shadowedBy == catchAll.id)
        // URL, auf die die frühere Regel nicht passt.
        #expect(test(rule, "https://example.com", config: config).shadowedBy == nil)
    }

    @Test func earlierDisabledRuleDoesNotShadow() {
        var catchAll = Rule(name: "Alles", action: .open(browserA))
        catchAll.enabled = false
        let rule = TestRules.githubPullRequestToLinearReview()
        let r = test(rule, pr, config: Config(rules: [catchAll, rule]))
        #expect(r.shadowedBy == nil)
        #expect(r.matches)
    }

    @Test func ruleNotInConfigIsNeverShadowed() {
        let catchAll = Rule(name: "Alles", action: .open(browserA))
        let r = test(TestRules.githubPullRequestToLinearReview(), pr, config: Config(rules: [catchAll]))
        #expect(r.shadowedBy == nil)
        #expect(r.matches)
    }

    @Test func disabledRuleItselfIsStillEvaluated() {
        var rule = TestRules.githubPullRequestToLinearReview()
        rule.enabled = false
        let config = Config(rules: [rule])
        let r = test(rule, pr, config: config)
        #expect(r.matches)
        #expect(r.conditionResults == [true, true])
        #expect(r.finalURL == u("https://linear.review/acme/webshop/pull/3776"))
        // Gegenprobe: `decide` überspringt die deaktivierte Regel.
        #expect(RuleEngine.decide(url: u(pr), context: LinkContext(), config: config).matchedRuleID == nil)
    }
}
