import Foundation
import Testing
@testable import AirTrafficCore

// MARK: - 26.1 Freigabe

@Suite("Freigabe riskanter Agenten-Änderungen (§26.1)")
struct ApprovalTests {
    static let since = Date(timeIntervalSince1970: 1_800_000_000)

    static func redirect(_ id: UUID = TempConfig.idA, template: String = "https://review.example.com/$1") -> Rule {
        Rule(
            id: id, name: "GitHub",
            conditions: [.host(TextMatch(op: .equals, value: "github.com"))],
            rewrites: [Rewrite(pattern: "^https://github\\.com/(.*)$", template: template)],
            action: .open(FakeAppResolver.chrome)
        )
    }

    @Test func gateNewRuleAlwaysWaits() {
        let rule = RuleApproval.gate(old: nil, new: Rule(name: "X", action: .prompt(.all)), now: Self.since)
        #expect(rule.pendingChange?.previous == nil)
        #expect(rule.pendingChange?.since == Self.since)
        #expect(rule.effective == nil)
    }

    @Test func gateRiskyAndHarmlessChanges() {
        let approved = TempConfig.sample().rules[0]
        var renamed = approved
        renamed.name = "Neu"
        renamed.conditions = [.host(TextMatch(op: .equals, value: "gitlab.com"))]
        renamed.testURL = nil
        renamed.enabled = false
        #expect(RuleApproval.gate(old: approved, new: renamed, now: Self.since).pendingChange == nil)

        var rewritten = approved
        rewritten.rewrites = [Rewrite(pattern: "^(.*)$", template: "https://evil.example/?u=$1")]
        let gatedRewrite = RuleApproval.gate(old: approved, new: rewritten, now: Self.since)
        #expect(gatedRewrite.pendingChange?.previous == approved)
        #expect(gatedRewrite.pendingChange?.reason.contains("Umschreibungen") == true)
        #expect(gatedRewrite.effective == approved)

        var otherApp = approved
        otherApp.action = .open(FakeAppResolver.figma)
        #expect(RuleApproval.gate(old: approved, new: otherApp, now: Self.since).pendingChange?.reason.contains("Aktion") == true)
    }

    @Test func secondChangeKeepsLastApprovedAndRevertClears() {
        let approved = TempConfig.sample().rules[0]
        var first = approved
        first.rewrites = [Rewrite(pattern: "^(.*)$", template: "https://a.example/$1")]
        let pending = RuleApproval.gate(old: approved, new: first, now: Self.since)

        var second = pending
        second.rewrites = [Rewrite(pattern: "^(.*)$", template: "https://b.example/$1")]
        let again = RuleApproval.gate(old: pending, new: second, now: Self.since.addingTimeInterval(60))
        #expect(again.pendingChange?.previous == approved)
        #expect(again.pendingChange?.since == Self.since)

        var reverted = again
        reverted.rewrites = approved.rewrites
        reverted.name = "Umbenannt"
        let clear = RuleApproval.gate(old: again, new: reverted, now: Self.since)
        #expect(clear.pendingChange == nil)
        #expect(clear.name == "Umbenannt")

        // Neu angelegt bleibt neu, auch nach weiteren Änderungen.
        let new = RuleApproval.gate(old: nil, new: Rule(name: "N", action: .prompt(.all)), now: Self.since)
        var renamedNew = new
        renamedNew.name = "N2"
        #expect(RuleApproval.gate(old: new, new: renamedNew, now: Self.since).pendingChange?.previous == nil)
        #expect(RuleApproval.gate(old: new, new: renamedNew, now: Self.since).isPendingApproval)
    }

    @Test func engineSkipsNewAndUsesPreviousForChanged() throws {
        let github = try #require(URL(string: "https://github.com/acme/repo"))
        var config = TempConfig.sample()
        // Neue Regel ganz oben, die alles umleitet – wartet → wird übersprungen.
        let evil = RuleApproval.gate(old: nil, new: Rule(
            name: "Alles umleiten",
            rewrites: [Rewrite(pattern: "^(.*)$", template: "https://evil.example/?u=$1")],
            action: .open(FakeAppResolver.figma)
        ), now: Self.since)
        config.rules.insert(evil, at: 0)
        var decision = RuleEngine.decide(url: github, context: LinkContext(), config: config)
        #expect(decision.matchedRuleID == TempConfig.idA)
        #expect(decision.finalURL == github)

        // enable auf wartende neue Regel macht sie nicht wirksam.
        config.rules[0].enabled = true
        #expect(RuleEngine.decide(url: github, context: LinkContext(), config: config).matchedRuleID == TempConfig.idA)

        // Geänderte Regel: zuletzt freigegebener Stand (Chrome, ohne Umschreibung) gilt.
        let approved = config.rules[1]
        var changed = approved
        changed.rewrites = [Rewrite(pattern: "^(.*)$", template: "https://evil.example/?u=$1")]
        changed.action = .open(FakeAppResolver.figma)
        config.rules[1] = RuleApproval.gate(old: approved, new: changed, now: Self.since)
        decision = RuleEngine.decide(url: github, context: LinkContext(), config: config)
        #expect(decision.matchedRuleID == TempConfig.idA)
        #expect(decision.action == .open(FakeAppResolver.chrome))
        #expect(decision.finalURL == github)

        // An/aus bleibt sofort wirksam.
        config.rules[1].enabled = false
        #expect(RuleEngine.decide(url: github, context: LinkContext(), config: config).matchedRuleID == TempConfig.idB)

        // Nach Freigabe gilt die Änderung.
        config.rules[1].enabled = true
        config.rules[1] = RuleApproval.approve(config.rules[1])
        decision = RuleEngine.decide(url: github, context: LinkContext(), config: config)
        #expect(decision.action == .open(FakeAppResolver.figma))
        #expect(decision.finalURL.host() == "evil.example")
    }

    @Test func checkAndTestPrecedenceIgnorePending() throws {
        let url = try #require(URL(string: "https://github.com/acme"))
        var config = TempConfig.sample()
        let pending = RuleApproval.gate(old: nil, new: Rule(name: "Neu", action: .open(FakeAppResolver.figma)), now: Self.since)
        config.rules.insert(pending, at: 0)
        let check = RuleEngine.check(url: url, context: LinkContext(), config: config)
        #expect(check.entries[0].status == .pendingMatch)
        #expect(check.entries[1].status == .wins)
        // Vorrang im Regel-Test: die wartende Regel verdeckt nichts.
        let test = RuleEngine.test(rule: config.rules[1], url: url, context: LinkContext(), config: config)
        #expect(test.shadowedBy == nil)
    }

    @Test func discardRestoresPreviousOrDeletes() {
        let approved = TempConfig.sample().rules[0]
        var changed = approved
        changed.action = .prompt(.all)
        changed.name = "Anders"
        let pending = RuleApproval.gate(old: approved, new: changed, now: Self.since)
        #expect(RuleApproval.discard(pending) == approved)
        #expect(RuleApproval.approve(pending).pendingChange == nil)
        #expect(RuleApproval.approve(pending).action == .prompt(.all))
        let new = RuleApproval.gate(old: nil, new: changed, now: Self.since)
        #expect(RuleApproval.discard(new) == nil)
    }

    @Test func codableRoundTripAndBackwardCompatible() throws {
        let approved = TempConfig.sample().rules[0]
        var changed = approved
        changed.rewrites = [Rewrite(pattern: "^(.*)$", template: "https://x.example/$1")]
        let pending = RuleApproval.gate(old: approved, new: changed, now: Self.since)
        let config = Config(rules: [pending, approved])
        let data = try ConfigStore.encode(config)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"pendingChange\""))
        #expect(text.contains("\"since\" : \"2027-01-15T08:00:00.000Z\""))
        // Ohne Änderung kein Feld (ältere Versionen lesen die Datei wie bisher).
        #expect(text.components(separatedBy: "\"pendingChange\"").count == 2)
        let decoded = try ConfigStore.decode(data)
        #expect(decoded == config)
        #expect(decoded.rules[0].pendingChange?.previous?.pendingChange == nil)
    }

    @Test func agentCannotSetPendingChangeOrApprove() throws {
        let temp = try TempConfig()
        defer { temp.remove() }
        let api = temp.api()
        let pendingJSON: JSONValue = ["since": "2026-01-01T00:00:00Z", "reason": "x"]
        #expect(throws: AgentError.invalid([RuleApproval.inputIssue])) {
            try api.createRule(["name": "X", "action": ["type": "prompt"], "pendingChange": pendingJSON])
        }
        #expect(throws: AgentError.invalid([RuleApproval.inputIssue])) {
            try api.updateRule("#1", patch: ["pendingChange": .null])
        }
        // Keine Freigabe per CLI oder MCP.
        let cli = AgentCLI(api: api, version: "test")
        var err = ""
        let io = AgentCLI.IO(readStdin: { nil }, out: { _ in }, err: { err += $0 })
        #expect(cli.run(["rules", "approve", "#1"], io: io) == AgentCLI.ExitCode.usage)
        #expect(!MCPTools.all.contains { $0.name.contains("approve") || $0.name.contains("pending") })
        #expect(MCPServer.instructions.contains("Freigabe"))
        #expect(RuleFormat.text.contains("Freigabe"))
    }

    @Test func agentUpdatesWaitAndListShowsTarget() throws {
        let temp = try TempConfig()
        defer { temp.remove() }
        let api = temp.api(now: { ApprovalTests.since })

        // Name ändern wirkt sofort.
        let renamed = try api.updateRule("GitHub", patch: ["name": "GitHub neu"])
        #expect(renamed.json["pendingApproval"] == false)
        #expect(try temp.load().rules[0].pendingChange == nil)

        // Umschreibung wartet; check ignoriert sie.
        let redirect = try api.updateRule("#1", patch: [
            "rewrites": [["pattern": "^https://github\\.com/(.*)$", "template": "https://review.example.com/$1"]],
        ])
        #expect(redirect.json["pendingApproval"] == true)
        #expect(redirect.text.contains("wartet auf Freigabe in Air Traffic"))
        #expect(redirect.json["checkAfterApproval"]?["finalURL"] == "https://review.example.com/acme")
        let stored = try temp.load().rules[0]
        #expect(stored.pendingChange?.previous?.rewrites.isEmpty == true)
        #expect(stored.pendingChange?.previous?.name == "GitHub neu")

        let check = try api.checkURL("https://github.com/acme")
        #expect(check.json["decision"]?["finalURL"] == "https://github.com/acme")

        // enable macht nichts wirksam; Liste nennt das Ziel.
        _ = try api.setRuleEnabled("#1", enabled: true)
        let list = try api.listRules()
        #expect(list.json["rules"]?.arrayValue?.first?["pendingApproval"] == true)
        #expect(list.json["rules"]?.arrayValue?.first?["summary"]?.stringValue?.contains("↻ review.example.com") == true)
        #expect(list.text.contains("⏳"))
        #expect(list.text.contains("1 Regel wartet auf Freigabe"))
    }

    @Test(arguments: [
        ("https://review.example.com/acme/$1/$2", "review.example.com"),
        ("linear://review/$1", "linear://review"),
        ("$1", nil),
        ("http://localhost:8080/x?$1", "localhost:8080"),
    ] as [(String, String?)])
    func rewriteTarget(template: String, expected: String?) {
        #expect(RuleDescriber.rewriteTarget([Rewrite(pattern: "x", template: template)]) == expected)
    }

    @Test func summaryShowsRewriteTarget() {
        let rule = Self.redirect()
        #expect(RuleDescriber.summary(rule).contains("↻ review.example.com"))
        // Letzte Umschreibung mit literalem Ziel gewinnt; ohne Ziel „umschreiben“.
        let chain = [Rewrite(pattern: "a", template: "https://first.example/$1"), Rewrite(pattern: "b", template: "$1")]
        #expect(RuleDescriber.rewriteChip(chain) == "↻ first.example")
        #expect(RuleDescriber.rewriteChip([Rewrite(pattern: "a", template: "$1")]) == "↻ umschreiben")
        #expect(RuleDescriber.rewriteChip([]) == nil)
        #expect(RuleApproval.countText(1) == "1 Regel wartet auf Freigabe")
        #expect(RuleApproval.countText(3) == "3 Regeln warten auf Freigabe")
    }
}

// MARK: - 26.2 Schema

@Suite("Schema nach dem Umschreiben (§26.2)")
struct RewriteSchemeTests {
    static let catchAll = "^https://example\\.com/\\?u=(.*)$"

    @Test(arguments: [
        "file:///etc/passwd",
        "smb://server/share",
        "javascript:alert(1)",
        "vscode://file/etc/hosts",
    ])
    func groupSchemesAreRejected(target: String) throws {
        let url = try #require(URL(string: "https://example.com/?u=\(target)"))
        let output = Rewriter.apply([Rewrite(pattern: Self.catchAll, template: "$1")], to: url)
        #expect(output.url == url)
        #expect(output.warnings.count == 1)
        #expect(output.warnings[0].contains("Schema"))
    }

    @Test func literalSchemeInTemplateIsAllowed() throws {
        let url = try #require(URL(string: "https://linear.app/acme/issue/ABC-1"))
        let rewrite = Rewrite(pattern: "^https://linear\\.app/(.*)$", template: "linear://$1")
        let output = Rewriter.apply([rewrite], to: url)
        #expect(output.url.absoluteString == "linear://acme/issue/ABC-1")
        #expect(output.warnings.isEmpty)
        #expect(output.notes == ["Schemawechsel „https:“ → „linear:“"])
        // Der Regel-Test zeigt den Schemawechsel als Warnung.
        let rule = Rule(name: "L", rewrites: [rewrite], action: .prompt(.all))
        let test = RuleEngine.test(rule: rule, url: url, context: LinkContext(), config: Config(rules: [rule]))
        #expect(test.warnings.contains("Schemawechsel „https:“ → „linear:“"))
    }

    @Test func fileToFileAndHTTPAreAllowed() throws {
        let file = try #require(URL(string: "file:///tmp/a.pdf"))
        let output = Rewriter.apply([Rewrite(pattern: "a\\.pdf$", template: "b.pdf")], to: file)
        #expect(output.url.absoluteString == "file:///tmp/b.pdf")
        #expect(output.warnings.isEmpty)

        let http = try #require(URL(string: "https://example.com/?u=http://other.example/x"))
        let unwrapped = Rewriter.apply([Rewrite(pattern: Self.catchAll, template: "$1")], to: http)
        #expect(unwrapped.url.absoluteString == "http://other.example/x")
    }

    @Test func groupCannotFakeLiteralScheme() {
        #expect(Rewriter.literalScheme(of: "$1://x") == nil)
        #expect(Rewriter.literalScheme(of: "linear://$1") == "linear")
        #expect(Rewriter.literalScheme(of: "x-acme+v1.2:$1") == "x-acme+v1.2")
        #expect(Rewriter.literalScheme(of: "\\$1file:") == nil)
        #expect(!Rewriter.isAllowedScheme("file", original: "https", templates: ["$1"]))
        #expect(Rewriter.isAllowedScheme("FILE", original: "file", templates: ["$1"]))
    }
}

// MARK: - 26.3 Laufzeit

@Suite("Laufzeit-Schutz beim Regel-Abgleich (§26.3)")
struct MatchSafetyTests {
    static func elapsed(_ body: () -> Void) -> Duration {
        let clock = ContinuousClock()
        let start = clock.now
        body()
        return clock.now - start
    }

    /// Bisherige Regex-Umsetzung als Referenz.
    static func reference(_ pattern: String, _ subject: String, caseSensitive: Bool) -> Bool {
        guard let regex = try? TextMatcher.wildcardRegex(pattern, caseSensitive: caseSensitive) else { return false }
        return regex.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)) != nil
    }

    @Test func wildcardEquivalentToPreviousRegex() {
        let patterns = [
            "", "*", "?", "**", "a*", "*a", "*a*", "a?c", "*://*.zoom.us/*", "https://*.example.com/*",
            "*.PDF", "\\*literal*", "a\\?b", "trailing\\", "*a*b*c*d*", "Ä*ß?", "*?*?", "?*", "x*y*z", "*/pull/*",
            "file:///*", "*\n*",
        ]
        let subjects = [
            "", "a", "abc", "aXc", "https://acme.zoom.us/j/1", "http://zoom.us/", "https://a.example.com/x",
            "Report.pdf", "*literal text", "a?b", "aXb", "trailing\\", "abcd", "xaybzcwd", "äXßY", "ÄbcßD",
            "xyz", "https://github.com/acme/pull/1", "file:///tmp/a", "line\nbreak", "ab",
        ]
        for pattern in patterns {
            for subject in subjects {
                for caseSensitive in [false, true] {
                    let expected = Self.reference(pattern, subject, caseSensitive: caseSensitive)
                    let actual = WildcardPattern(pattern, caseSensitive: caseSensitive).matches(subject)
                    #expect(actual == expected, "Muster „\(pattern)“, Text „\(subject)“, caseSensitive \(caseSensitive)")
                }
            }
        }
    }

    @Test func pathologicalWildcardsAreFast() {
        let zoom = String(repeating: "://.zoom.us", count: 60_000 / 11)
        let letters = String(repeating: "a", count: 60_000)
        let time = Self.elapsed {
            #expect(!TextMatcher.matches(TextMatch(op: .wildcard, value: "*://*.zoom.us/*"), zoom))
            #expect(!TextMatcher.matches(TextMatch(op: .wildcard, value: "*a*b*c*d*"), letters))
            #expect(TextMatcher.matches(TextMatch(op: .wildcard, value: "*a*a*a*a*"), letters))
        }
        #expect(time < .seconds(1), "Dauer \(time)")
    }

    @Test func catastrophicRegexStopsAtBudget() throws {
        let pattern = "^https://example\\.com/\\?q=(a|aa)+$"
        let rule = Rule(name: "Böse", conditions: [.url(TextMatch(op: .regex, value: pattern))], action: .prompt(.running))
        let fallback = Rule(name: "Danach", action: .prompt(.all))
        let config = Config(rules: [rule, fallback])

        // Über decide (URL unter 8192 Zeichen): Regel gilt als „trifft nicht“, die nächste greift.
        let medium = try #require(URL(string: "https://example.com/?q=" + String(repeating: "a", count: 8_000) + "b"))
        var decision: Decision?
        let time = Self.elapsed {
            decision = RuleEngine.decide(url: medium, context: LinkContext(), config: config)
        }
        #expect(decision?.matchedRuleID == fallback.id)
        #expect(decision?.warnings == ["Regel „Böse“: Zeitlimit überschritten"])
        #expect(time < .seconds(1), "Dauer \(time)")

        // Direkt gegen 60 000 Zeichen.
        let long = try #require(URL(string: "https://example.com/?q=" + String(repeating: "a", count: 60_000) + "b"))
        var warnings: [String] = []
        let budget = MatchBudget()
        let regexTime = Self.elapsed {
            #expect(!RuleEngine.matches(rule: rule, url: long, context: LinkContext(), warnings: &warnings, budget: budget))
        }
        #expect(regexTime < .seconds(1), "Dauer \(regexTime)")
        #expect(warnings == ["Regel „Böse“: Zeitlimit überschritten"])
        #expect(budget.exhausted)
    }

    @Test func rewriteTimeoutKeepsOriginal() throws {
        let url = try #require(URL(string: "https://example.com/" + String(repeating: "a", count: 5_000) + "b"))
        let budget = MatchBudget(.milliseconds(50))
        let output = Rewriter.apply([Rewrite(pattern: "^https://example\\.com/(a|aa)+$", template: "https://x.example/")], to: url, budget: budget)
        #expect(output.url == url)
        #expect(output.warnings.first?.contains("Zeitlimit überschritten") == true)
    }

    @Test func longURLsSkipRulesAndPrompt() throws {
        let long = try #require(URL(string: "https://example.com/?q=" + String(repeating: "x", count: 9_000)))
        let config = Config(rules: [Rule(name: "Alles", action: .open(FakeAppResolver.chrome))], defaultAction: .open(FakeAppResolver.safari))
        let decision = RuleEngine.decide(url: long, context: LinkContext(), config: config)
        #expect(decision.action == .prompt(.all))
        #expect(decision.matchedRuleID == nil)
        #expect(decision.warnings == [MatchLimits.tooLongWarning])
        #expect(RuleEngine.check(url: long, context: LinkContext(), config: config).entries.allSatisfy { $0.status == .noMatch })

        // Auch über airtraffic:// ohne prompt und mit eigener Ersatzaktion.
        var ext = config
        ext.extensionSettings = ExtensionSettings(applyRules: true, fallbackAction: .open(FakeAppResolver.figma))
        let fromExtension = AirTrafficURL.decide(.init(url: long), context: LinkContext(), config: ext)
        #expect(fromExtension.action == .prompt(.all))
        #expect(fromExtension.warnings == [MatchLimits.tooLongWarning])

        let short = try #require(URL(string: "https://example.com/?q=" + String(repeating: "x", count: 8_000)))
        #expect(RuleEngine.decide(url: short, context: LinkContext(), config: config).action == .open(FakeAppResolver.chrome))
    }

    @Test func regexCacheReturnsSameInstance() throws {
        // Eigene Instanz statt des globalen Caches, den parallele Tests füllen (§27 K17).
        let cache = RegexCache(limit: RegexCache.defaultLimit)
        let a = try cache.regex("^cache-test$", options: [.caseInsensitive])
        let b = try cache.regex("^cache-test$", options: [.caseInsensitive])
        let c = try cache.regex("^cache-test$", options: [])
        #expect(a === b)
        #expect(a !== c)
    }
}

// MARK: - 26.4 Quelle

@Suite("Quell-App aus airtraffic:// (§26.4)")
struct AirTrafficSourceTests {
    @Test func onlySafariIsAccepted() throws {
        let base = LinkContext(sourceBundleIdentifier: "com.apple.Terminal")
        let url = try #require(URL(string: "https://example.com"))
        #expect(AirTrafficURL.Request(url: url, source: "com.apple.Safari").context(from: base).sourceBundleIdentifier == "com.apple.Safari")
        let forged = AirTrafficURL.Request(url: url, source: "com.tinyspeck.slackmacgap")
        #expect(forged.context(from: base).sourceBundleIdentifier == "com.apple.Terminal")
        #expect(forged.hasUntrustedSource)
        #expect(forged.context(from: LinkContext()).sourceBundleIdentifier == nil)
        #expect(!AirTrafficURL.Request(url: url).hasUntrustedSource)
    }

    @Test func forgedSourceDoesNotTriggerSourceRule() throws {
        let slack = Rule(name: "Slack", conditions: [.sourceApp(bundleIdentifier: "com.tinyspeck.slackmacgap", negated: false)],
                         action: .open(FakeAppResolver.figma))
        let config = Config(rules: [slack], defaultAction: .prompt(.all))
        let link = try #require(URL(string: "airtraffic://open?url=https%3A%2F%2Fexample.com&source=com.tinyspeck.slackmacgap"))
        let decision = AirTrafficURL.decide(try AirTrafficURL.parse(link), context: LinkContext(), config: config)
        #expect(decision.matchedRuleID == nil)
    }
}

// MARK: - 26.6 KI-CLI-Pfade

@Suite("KI-CLI-Pfade (§26.6)")
struct CLIPathTests {
    static func locator(_ executables: Set<String>) -> CLILocator {
        CLILocator(homeDirectory: "/Users/test", isExecutable: { executables.contains($0) }, shellLookup: { _ in nil })
    }

    @Test func onlyExactFileNamesAreAccepted() {
        #expect(AssistantCLI.claude.accepts(path: "/opt/homebrew/bin/claude"))
        #expect(AssistantCLI.claude.accepts(path: "~/bin/claude"))
        #expect(AssistantCLI.codex.accepts(path: "/usr/local/bin/codex"))
        #expect(!AssistantCLI.claude.accepts(path: "/bin/sh"))
        #expect(!AssistantCLI.claude.accepts(path: "/tmp/claude.sh"))
        #expect(!AssistantCLI.claude.accepts(path: "/tmp/Claude"))
        #expect(!AssistantCLI.codex.accepts(path: "/usr/local/bin/claude"))
        #expect(!AssistantCLI.claude.accepts(path: "/tmp/claude/"))
        #expect(AssistantCLI.codex.invalidPathHint == "Pfad ungültig – Datei muss codex heißen")
    }

    @Test func invalidConfiguredPathIsIgnored() {
        let locator = Self.locator(["/bin/sh", "/opt/homebrew/bin/claude"])
        #expect(locator.locateWithoutShell(.claude, configuredPath: "/bin/sh")?.path == "/opt/homebrew/bin/claude")
        #expect(Self.locator(["/bin/sh"]).locateWithoutShell(.claude, configuredPath: "/bin/sh") == nil)
    }

    @Test func versionCheckStartsOnlyValidNames() async {
        let runner = FakeProcessRunner(result: ProcessResult(exitCode: 0, stdout: Data("claude 1.2.3".utf8)))
        #expect(await CLITransport.version(of: URL(fileURLWithPath: "/bin/sh"), runner: runner) == nil)
        #expect(runner.calls.isEmpty)
        #expect(await CLITransport.version(of: URL(fileURLWithPath: "/opt/homebrew/bin/claude"), runner: runner) == "1.2.3")
        #expect(runner.calls.count == 1)
    }
}

// MARK: - 26.8, 26.9 Spam und Schleifen

@Suite("Auswahlfenster gegen Spam, Schleifenbremse (§26.8, §26.9)")
struct AbuseGuardTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func promptLinksAtMostThreePerTenSeconds() {
        var limiter = SlidingWindowLimiter.promptLinks()
        do { let ok = limiter.allow(at: Self.t0); #expect(ok) }
        do { let ok = limiter.allow(at: Self.t0.addingTimeInterval(1)); #expect(ok) }
        do { let ok = limiter.allow(at: Self.t0.addingTimeInterval(2)); #expect(ok) }
        do { let ok = limiter.allow(at: Self.t0.addingTimeInterval(3)); #expect(!ok) }
        do { let ok = limiter.allow(at: Self.t0.addingTimeInterval(9.9)); #expect(!ok) }
        do { let ok = limiter.allow(at: Self.t0.addingTimeInterval(10)); #expect(ok) }
    }

    @Test func queueMergesAndCapsThenStaysQuiet() throws {
        var policy = ChooserQueuePolicy()
        let shown = try #require(URL(string: "https://a.example/0"))
        var queued: [URL] = []
        do { let verdict = policy.admit(shown, showing: shown, queued: queued, at: Self.t0); #expect(verdict == .merged) }
        for i in 1...5 {
            let url = try #require(URL(string: "https://a.example/\(i)"))
            do { let verdict = policy.admit(url, showing: shown, queued: queued, at: Self.t0); #expect(verdict == .accept) }
            queued.append(url)
        }
        do { let verdict = policy.admit(queued[2], showing: shown, queued: queued, at: Self.t0); #expect(verdict == .merged) }
        let sixth = try #require(URL(string: "https://a.example/6"))
        do { let verdict = policy.admit(sixth, showing: shown, queued: queued, at: Self.t0); #expect(verdict == .dropped(firstOfBurst: true)) }
        // 10 s nur Log – auch wenn die Warteschlange wieder Platz hat.
        do { let verdict = policy.admit(sixth, showing: shown, queued: [], at: Self.t0.addingTimeInterval(9)); #expect(verdict == .dropped(firstOfBurst: false)) }
        do { let verdict = policy.admit(sixth, showing: shown, queued: [], at: Self.t0.addingTimeInterval(10)); #expect(verdict == .accept) }
    }

    @Test func loopBrakeAllowsThreeInFiveSeconds() throws {
        var brake = LoopBrake()
        let url = try #require(URL(string: "https://loop.example/"))
        let other = try #require(URL(string: "https://other.example/"))
        do { let ok = brake.allow(url, at: Self.t0); #expect(ok) }
        do { let ok = brake.allow(url, at: Self.t0.addingTimeInterval(1)); #expect(ok) }
        do { let ok = brake.allow(url, at: Self.t0.addingTimeInterval(2)); #expect(ok) }
        do { let ok = brake.allow(url, at: Self.t0.addingTimeInterval(3)); #expect(!ok) }
        do { let ok = brake.allow(other, at: Self.t0.addingTimeInterval(3)); #expect(ok) }
        do { let ok = brake.allow(url, at: Self.t0.addingTimeInterval(5.5)); #expect(ok) }
        #expect(LoopBrake.hint == "Link kreist zwischen Apps")
    }
}

// MARK: - 26.10 Sicherungen

@Suite("Aufbewahrung der Sicherungen (§26.10)")
struct BackupRetentionTests {
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func url(_ date: Date, suffix: String = "") -> URL {
        URL(fileURLWithPath: "/b/config-\(ConfigStore.backupStamp(date))\(suffix).json")
    }

    @Test func keepsLast24HoursUpToLimit() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let urls = (0..<120).map { Self.url(now.addingTimeInterval(-Double($0) * 60)) }
        let keep = ConfigStore.backupsToKeep(urls, now: now, calendar: Self.utc)
        // 100 neueste der letzten 24 h; dazu die älteste des Tages (Stand vor der ersten Änderung).
        #expect(urls.prefix(100).allSatisfy(keep.contains))
        #expect(keep.contains(urls[119]))
        #expect(keep.count == 101)
    }

    @Test func keepsNewestAndOldestPerDayFor14Days() throws {
        // 2027-01-20 12:00 UTC
        let now = try #require(Self.utc.date(from: DateComponents(year: 2027, month: 1, day: 20, hour: 12)))
        var urls: [URL] = []
        var expected = Set<URL>()
        for day in 1...20 {
            let base = try #require(Self.utc.date(byAdding: .day, value: -day, to: now))
            let morning = Self.utc.startOfDay(for: base).addingTimeInterval(8 * 3600)
            let items = [morning, morning.addingTimeInterval(3600), morning.addingTimeInterval(7200)].map { Self.url($0) }
            urls += items
            // 08:00–10:00 des Vortags liegen schon > 24 h zurück; es zählt nur die Tagesregel.
            if day < ConfigStore.dailyBackupDays {
                expected.insert(items[0])  // älteste = vor der ersten Änderung des Tages
                expected.insert(items[2])  // neueste
            }
        }
        let unknown = URL(fileURLWithPath: "/b/config-kaputt.json")
        urls.append(unknown)
        expected.insert(unknown)
        let keep = ConfigStore.backupsToKeep(urls, now: now, calendar: Self.utc)
        #expect(keep == expected)
    }

    @Test func pruneRemovesOnlyExpired() throws {
        let temp = try TempConfig()
        defer { temp.remove() }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // Drei Sicherungen vor 20 Tagen, drei heute.
        for offset in [20.0 * 86_400 + 2, 20.0 * 86_400 + 1, 20.0 * 86_400, 3, 2, 1] {
            try temp.store.writeBackup(Data("x".utf8), now: now.addingTimeInterval(-offset))
        }
        let names = temp.store.backups().map(\.lastPathComponent)
        #expect(names.count == 3)
        #expect(names.allSatisfy { $0.hasPrefix("config-\(ConfigStore.backupStamp(now).prefix(10))") })
        #expect(ConfigStore.backupDate(Self.url(now, suffix: "-2")) == now)
    }
}
