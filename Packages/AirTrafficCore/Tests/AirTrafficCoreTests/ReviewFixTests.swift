import Foundation
import Testing
@testable import AirTrafficCore

// Befunde aus SPEC §27 (Review vom 2026-11-06). Kennungen K… = Core/CLI, A… = App (nur Core-Anteil).

private func u(_ text: String) -> URL { URL(string: text)! }

/// Katastrophales Backtracking: läuft garantiert ins Zeitbudget.
private let evilPattern = "^https://example\\.com/\\?q=(a|aa)+$"
private let evilURL = URL(string: "https://example.com/?q=" + String(repeating: "a", count: 3000) + "b")!

// MARK: - K1 SIGPIPE

@Suite("Prozesse mit vorzeitig beendetem Kind (§27 K1)")
struct SigpipeTests {
    /// Ohne `F_SETNOSIGPIPE` beendet SIGPIPE den ganzen Testprozess (Exit 141).
    @Test func childExitingBeforeReadingStdinIsNoCrash() async throws {
        let input = Data(repeating: 0x61, count: 1_000_000)
        for _ in 0..<50 {
            let result = try await SystemProcessRunner().run(ProcessInvocation(
                executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], stdin: input, timeout: .seconds(10)
            ))
            #expect(result.exitCode == 0)
        }
    }
}

// MARK: - K15 Prozess-Rennen

@Suite("Prozess-Start, Abbruch und Zeitlimit (§27 K15)")
struct ProcessRaceTests {
    /// Das Kind ist längst fertig, ein Enkel hält aber stdout offen: Das Zeitlimit läuft danach ab und
    /// darf das Ergebnis nicht mehr in „Zeitlimit“ verwandeln.
    @Test func timeoutAfterExitIsNoTimeout() async throws {
        let result = try await SystemProcessRunner().run(ProcessInvocation(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo fertig; (sleep 1) & exit 0"],
            timeout: .milliseconds(300)
        ))
        #expect(result.exitCode == 0)
        #expect(result.stdoutText == "fertig\n")
    }

    /// Abbruch direkt nach dem Start: Der Prozess darf nicht bis zum Ende weiterlaufen.
    @Test func cancelRightAfterStartStopsProcess() async {
        for delay in [0, 1, 5, 20] {
            let task = Task {
                try await SystemProcessRunner().run(ProcessInvocation(
                    executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: .seconds(30)
                ))
            }
            if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
            let start = ContinuousClock.now
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(ContinuousClock.now - start < .seconds(3), "Verzögerung \(delay) ms")
        }
    }
}

// MARK: - K2/K3 Kurzschluss und Parität

@Suite("Auswertung: Kurzschluss und Parität decide/check/test (§27 K2, K3)")
struct EvaluationParityTests {
    @Test func cheapConditionShortCircuitsSlowRegex() {
        let r1 = Rule(name: "Andere Domain", conditions: [
            .url(TextMatch(op: .regex, value: evilPattern)),
            .host(TextMatch(op: .equals, value: "nicht.example")),
        ], action: .prompt(.running))
        let r2 = Rule(name: "Harmlos", conditions: [.url(TextMatch(op: .regex, value: "example\\.com"))], action: .prompt(.all))
        let clock = ContinuousClock()
        let start = clock.now
        let decision = RuleEngine.decide(url: evilURL, context: LinkContext(), config: Config(rules: [r1, r2]))
        #expect(decision.matchedRuleID == r2.id, "Budget darf nicht von der nicht passenden Regel verbraucht werden")
        #expect(decision.warnings.isEmpty, "\(decision.warnings)")
        #expect(clock.now - start < .milliseconds(400))
    }

    @Test func modesStopEarly() {
        let slow = Condition.url(TextMatch(op: .regex, value: evilPattern))
        let yes = Condition.host(TextMatch(op: .equals, value: "example.com"))
        let no = Condition.host(TextMatch(op: .equals, value: "other.example"))
        for (mode, conditions, expected) in [
            (MatchMode.all, [slow, no], false),
            (.any, [slow, yes], true),
            (.none, [slow, yes], false),
        ] {
            let rule = Rule(name: "R", match: mode, conditions: conditions, action: .prompt(.all))
            let decision = RuleEngine.decide(url: evilURL, context: LinkContext(), config: Config(rules: [rule]))
            #expect((decision.matchedRuleID == rule.id) == expected, "\(mode)")
            #expect(decision.warnings.isEmpty, "\(mode): \(decision.warnings)")
        }
    }

    @Test func timeoutMeansNoMatchEverywhere() {
        let slow = Condition.url(TextMatch(op: .regex, value: evilPattern))
        let no = Condition.host(TextMatch(op: .equals, value: "other.example"))
        for (mode, conditions) in [(MatchMode.none, [slow]), (.any, [slow, no]), (.all, [slow])] {
            let rule = Rule(name: "R", match: mode, conditions: conditions, action: .prompt(.all))
            let config = Config(rules: [rule])
            let decision = RuleEngine.decide(url: evilURL, context: LinkContext(), config: config)
            let check = RuleEngine.check(url: evilURL, context: LinkContext(), config: config)
            let test = RuleEngine.test(rule: rule, url: evilURL, context: LinkContext(), config: config)
            #expect(decision.matchedRuleID == nil, "\(mode)")
            #expect(check.entries[0].matches == (decision.matchedRuleID == rule.id), "\(mode)")
            #expect(check.entries[0].status == .noMatch, "\(mode)")
            #expect(check.decision == decision, "\(mode)")
            #expect(!test.matches, "\(mode)")
            #expect(test.warnings.contains { $0.contains(TextMatcher.timeoutMessage) }, "\(mode)")
        }
    }
}

// MARK: - K4/K5 Wartende Regel

@Suite("Wartende Regel: effective und Verwerfen (§27 K4, K5)")
struct PendingEffectiveTests {
    @Test func effectiveTakesOnlyRewritesAndActionFromPrevious() {
        let r0 = Rule(name: "R", conditions: [.host(TextMatch(op: .equals, value: "a.example"))],
                      rewrites: [Rewrite(pattern: "^http:", template: "https:")], action: .prompt(.all), testURL: "https://a.example")
        var r1 = r0
        r1.action = .prompt(.running)
        r1.rewrites = []
        let p1 = RuleApproval.gate(old: r0, new: r1, now: Date())
        var r2 = p1
        r2.name = "Neu"
        r2.conditions = [.host(TextMatch(op: .equals, value: "b.example"))]
        r2.testURL = "https://b.example"
        let p2 = RuleApproval.gate(old: p1, new: r2, now: Date())
        #expect(p2.isPendingApproval)

        let effective = try! #require(p2.effective)
        #expect(effective.name == "Neu")
        #expect(effective.conditions == r2.conditions)
        #expect(effective.testURL == "https://b.example")
        #expect(effective.rewrites == r0.rewrites)
        #expect(effective.action == r0.action)
        #expect(effective.pendingChange == nil)

        let config = Config(rules: [p2])
        #expect(RuleEngine.decide(url: u("https://b.example/"), context: LinkContext(), config: config).matchedRuleID == p2.id)
        #expect(RuleEngine.decide(url: u("https://a.example/"), context: LinkContext(), config: config).matchedRuleID == nil)
    }

    @Test func newPendingRuleStaysSkipped() {
        var rule = RuleApproval.gate(old: nil, new: Rule(name: "Neu", action: .prompt(.running)), now: Date())
        rule.enabled = true
        #expect(rule.effective == nil)
        #expect(RuleEngine.decide(url: u("https://x.example"), context: LinkContext(), config: Config(rules: [rule])).matchedRuleID == nil)
    }

    @Test func discardKeepsEnabledState() {
        let r0 = Rule(name: "R", enabled: true, action: .prompt(.all))
        var r1 = r0
        r1.action = .prompt(.running)
        var pending = RuleApproval.gate(old: r0, new: r1, now: Date())
        pending.enabled = false
        let restored = try! #require(RuleApproval.discard(pending))
        #expect(!restored.enabled)
        #expect(restored.action == r0.action)
        #expect(restored.pendingChange == nil)
    }
}

// MARK: - K6 Choosy

@Suite("Choosy: deaktiviertes TRUEPREDICATE am Ende (§27 K6)")
struct ChoosyDisabledFallbackTests {
    @Test func disabledTruePredicateBecomesDisabledRule() {
        let result = ChoosyImporter.importConfig(behaviours: [
            ["title": "a", "enabled": true, "predicate": "URL CONTAINS 'x'", "behaviour": 6, "behaviourArgument": ["path": "/Applications/Safari.app"]],
            ["title": "Fallback (aus)", "enabled": false, "predicate": "TRUEPREDICATE", "behaviour": 6, "behaviourArgument": ["path": "/Applications/Firefox.app"]],
        ], browserPaths: [], bundleIdentifierForPath: { _ in nil })
        #expect(result.config.defaultAction == .prompt(.all))
        #expect(result.config.rules.count == 2)
        guard result.config.rules.count == 2 else { return }
        let last = result.config.rules[1]
        #expect(last.name == "Fallback (aus)")
        #expect(!last.enabled)
        #expect(last.conditions.isEmpty)
        #expect(result.report.contains { $0.ruleID == last.id && $0.message.contains("deaktiviert") })
    }

    @Test func enabledTruePredicateStillBecomesDefault() {
        let result = ChoosyImporter.importConfig(behaviours: [
            ["title": "Rest", "enabled": true, "predicate": "TRUEPREDICATE", "behaviour": 6, "behaviourArgument": ["path": "/x/Y.app"]],
        ], browserPaths: [], bundleIdentifierForPath: { _ in nil })
        #expect(result.config.rules.isEmpty)
        #expect(result.config.defaultAction != .prompt(.all))
    }
}

// MARK: - K7 Platzhalter Groß/Klein

@Suite("Platzhalter mit voller Groß/Klein-Faltung (§27 K7)")
struct WildcardFoldingTests {
    static func reference(_ pattern: String, _ subject: String) -> Bool {
        let regex = try! TextMatcher.wildcardRegex(pattern, caseSensitive: false)
        return regex.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)) != nil
    }

    @Test func fullCaseFoldingLikePreviousRegex() {
        for (pattern, subject) in [
            ("*straße*", "/STRASSE/1"), ("*STRASSE*", "straße"), ("*ς*", "Σ"), ("*σ*", "ς"), ("*Σ*", "ς"),
            ("*ﬀ*", "FF"), ("*ff*", "ﬀ"), ("*ǅ*", "ǆ"), ("*K*", "\u{212A}"), ("https://*.bücher.de/*", "HTTPS://WWW.BÜCHER.DE/x"),
        ] {
            #expect(Self.reference(pattern, subject), "Referenz \(pattern) / \(subject)")
            #expect(WildcardPattern(pattern, caseSensitive: false).matches(subject), "\(pattern) / \(subject)")
        }
        #expect(!WildcardPattern("*straße*", caseSensitive: true).matches("/STRASSE/1"))
        #expect(!WildcardPattern("*ß*", caseSensitive: false).matches("s"))
    }
}

// MARK: - K8 Lesebefehle ohne Konfiguration

@Suite("Lesebefehle bei fehlender Konfiguration (§27 K8)")
struct MissingConfigReadTests {
    final class Capture: @unchecked Sendable {
        var out = ""
        var err = ""
    }

    @Test func readCommandsExitWithNoInput() throws {
        let temp = try TempConfig(nil)
        defer { temp.remove() }
        for args in [["rules", "list"], ["rules", "get", "#1"], ["check", "https://example.com"], ["browsers", "list"], ["settings"], ["rules", "list", "--json"]] {
            let capture = Capture()
            let io = AgentCLI.IO(readStdin: { nil }, out: { capture.out += $0 }, err: { capture.err += $0 })
            let code = AgentCLI(api: temp.api(), version: "t").run(args, io: io)
            #expect(code == AgentCLI.ExitCode.noInput, "\(args): \(capture.out) \(capture.err)")
            #expect(capture.err.contains("Keine Konfiguration"), "\(args)")
            #expect(!capture.out.contains("Keine Regeln"), "\(args)")
        }
        // Formatbeschreibung braucht keine Konfiguration.
        let io = AgentCLI.IO(readStdin: { nil }, out: { _ in }, err: { _ in })
        #expect(AgentCLI(api: temp.api(), version: "t").run(["schema"], io: io) == AgentCLI.ExitCode.ok)
    }
}

// MARK: - K11 Schema nur aus angewendeten Umschreibungen

@Suite("Literales Schema nur aus angewendeten Umschreibungen (§27 K11)")
struct AppliedSchemeTests {
    @Test func templateOfNonMatchingRewriteDoesNotAllowScheme() {
        let rewrites = [
            Rewrite(pattern: "^trifft-nie$", template: "javascript:alert(1)"),
            Rewrite(pattern: "^https://x\\.example/(.*)$", template: "$1"),
        ]
        let output = Rewriter.apply(rewrites, to: u("https://x.example/javascript:alert(2)"))
        #expect(output.url == u("https://x.example/javascript:alert(2)"), "Schema „javascript:“ stammt nicht aus einer angewendeten Vorlage")
        #expect(output.warnings.count == 1)
    }

    @Test func templateOfAppliedRewriteAllowsScheme() {
        let output = Rewriter.apply([Rewrite(pattern: "^https://linear\\.app/(.*)$", template: "linear://$1")], to: u("https://linear.app/acme/issue/1"))
        #expect(output.url == u("linear://acme/issue/1"))
        #expect(output.warnings.isEmpty)
    }
}

// MARK: - K12 MCP-IDs

@Suite("MCP: Request-IDs roh, keine Batch-Version (§27 K12)")
struct MCPRawIDTests {
    func server() throws -> (MCPServer, TempConfig) {
        let temp = try TempConfig()
        return (MCPServer(api: temp.api(), version: "t"), temp)
    }

    @Test func largeIntegerIDsAreReturnedExactly() throws {
        let (server, temp) = try server()
        defer { temp.remove() }
        for raw in ["9007199254740993", "12345678901234567890", "-42", "0", "1"] {
            let line = try #require(server.handle(line: #"{"jsonrpc":"2.0","id":\#(raw),"method":"ping"}"#))
            #expect(line.contains(#""id":\#(raw),"#) || line.contains(#""id":\#(raw)}"#), "\(raw): \(line)")
        }
        let text = try #require(server.handle(line: #"{"jsonrpc":"2.0","id":"a\"b","method":"ping"}"#))
        #expect(JSONValue.parse(text)?["id"] == "a\"b")
        let error = try #require(server.handle(line: #"{"jsonrpc":"2.0","id":9007199254740993,"method":"nope"}"#))
        #expect(error.contains(#""id":9007199254740993"#), "\(error)")
    }

    @Test func batchVersionIsNotNegotiated() throws {
        let (server, temp) = try server()
        defer { temp.remove() }
        #expect(!MCPServer.supportedProtocolVersions.contains("2025-03-26"))
        let line = try #require(server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#))
        #expect(JSONValue.parse(line)?["result"]?["protocolVersion"] == .string(MCPServer.defaultProtocolVersion))
    }
}

// MARK: - K13 Regeln ohne id

@Suite("Regeln ohne id bekommen stabile IDs (§27 K13)")
struct MissingRuleIDTests {
    static let json = """
    {"schemaVersion": 1, "browsers": [], "defaultAction": {"type": "prompt", "scope": "all"},
     "rules": [{"name": "Ohne ID", "action": {"type": "prompt", "scope": "all"}},
               {"id": "11111111-AAAA-4000-8000-000000000001", "name": "Mit ID", "action": {"type": "prompt", "scope": "all"}}]}
    """

    @Test func modifyWritesGeneratedIDsBack() throws {
        let temp = try TempConfig(nil)
        defer { temp.remove() }
        try Data(Self.json.utf8).write(to: temp.store.fileURL)
        // Ändert inhaltlich nichts – die vergebene ID muss trotzdem in die Datei.
        let result = try temp.api().setRuleEnabled("#1", enabled: true)
        let id = try #require(result.json["rule"]?["id"]?.stringValue)
        let first = try temp.load()
        let second = try temp.load()
        #expect(first.rules[0].id == second.rules[0].id)
        #expect(first.rules[0].id.uuidString.lowercased() == id)
        #expect(first.rules[1].id == TempConfig.idA)
        #expect(try temp.api().getRule(id).json["rule"]?["name"] == "Ohne ID")
    }

    @Test func detectsMissingIDs() throws {
        #expect(ConfigStore.hasRulesWithoutID(Data(Self.json.utf8)))
        #expect(!ConfigStore.hasRulesWithoutID(try ConfigStore.encode(TempConfig.sample())))
    }
}

// MARK: - K14 since

@Suite("pendingChange.since byte-stabil (§27 K14)")
struct SinceRoundTripTests {
    @Test func roundTripIsByteStable() throws {
        for k in 0..<200 {
            let since = Date(timeIntervalSinceReferenceDate: 780_000_000 + Double(k) * 1.2345)
            var data = try ConfigStore.encode(Config(rules: [
                Rule(name: "P", action: .prompt(.all), pendingChange: PendingChange(since: since, reason: "x", previous: nil)),
            ]))
            for _ in 0..<5 {
                let again = try ConfigStore.encode(try ConfigStore.decode(data))
                #expect(again == data, "k = \(k)")
                data = again
            }
        }
        #expect(PendingChange.formatDate(Date(timeIntervalSince1970: 1.2345)) == "1970-01-01T00:00:01.235Z")
        #expect(PendingChange.formatDate(Date(timeIntervalSince1970: 59.9996)) == "1970-01-01T00:01:00.000Z")
    }
}

// MARK: - A4 IDN (Core-Anteil)

@Suite("Host-Bedingungen mit Unicode und Punycode (§27 A4)")
struct IDNHostTests {
    func matches(_ m: TextMatch, _ url: String) -> Bool {
        RuleEngine.evaluate(.host(m), url: u(url), context: LinkContext())
    }

    @Test func unicodeAndPunycodeAreEquivalent() {
        for url in ["https://bücher.de/", "https://xn--bcher-kva.de/", "https://BÜCHER.de/x"] {
            #expect(matches(TextMatch(op: .equals, value: "bücher.de"), url), "\(url)")
            #expect(matches(TextMatch(op: .equals, value: "xn--bcher-kva.de"), url), "\(url)")
            #expect(!matches(TextMatch(op: .notEquals, value: "bücher.de"), url), "\(url)")
            #expect(matches(TextMatch(op: .endsWith, value: "ücher.de"), url), "\(url)")
            #expect(matches(TextMatch(op: .wildcard, value: "*bücher.de"), url), "\(url)")
            #expect(matches(TextMatch(op: .regex, value: "^bücher\\.de$"), url), "\(url)")
            #expect(!matches(TextMatch(op: .notContains, value: "xn--bcher"), url), "\(url)")
        }
        #expect(!matches(TextMatch(op: .equals, value: "bücher.de"), "https://buecher.de/"))
        #expect(matches(TextMatch(op: .notEquals, value: "bücher.de"), "https://buecher.de/"))
    }

    @Test func hostForms() {
        #expect(HostName.unicode("xn--bcher-kva.de") == "bücher.de")
        #expect(HostName.ascii("bücher.de") == "xn--bcher-kva.de")
        #expect(HostName.unicode("example.com") == "example.com")
        #expect(HostName.unicode(u("https://xn--bcher-kva.de/a")) == "bücher.de")
    }
}

// MARK: - K9 Regex-Cache

@Suite("Regex-Cache mit LRU (§27 K9, K17)")
struct RegexLRUTests {
    @Test func evictsLeastRecentlyUsedInsteadOfClearing() throws {
        let cache = RegexCache(limit: 3)
        let a = try cache.regex("a", options: [])
        _ = try cache.regex("b", options: [])
        _ = try cache.regex("c", options: [])
        #expect(try cache.regex("a", options: []) === a, "a frisch benutzt")
        _ = try cache.regex("d", options: [])
        #expect(cache.count == 3, "nicht komplett geleert")
        #expect(try cache.regex("a", options: []) === a, "a bleibt, b fliegt")
        let b2 = try cache.regex("b", options: [])
        #expect(try cache.regex("b", options: []) === b2)
    }

    @Test func sharedCacheHoldsFiveHundredTwelve() {
        #expect(RegexCache.shared.limit == 512)
    }

    /// Ersetzt die frühere Fassung, die vom globalen Cache abhing (paralleles Leeren → flackernd).
    @Test func ownCacheReturnsSameInstance() throws {
        let cache = RegexCache(limit: 8)
        let a = try cache.regex("^cache-test$", options: [.caseInsensitive])
        let b = try cache.regex("^cache-test$", options: [.caseInsensitive])
        let c = try cache.regex("^cache-test$", options: [])
        #expect(a === b)
        #expect(a !== c)
    }
}

// MARK: - K10 Umschreibungen in einem Durchlauf

@Suite("Umschreibungen in einem Durchlauf (§27 K10)")
struct RewriteSinglePassTests {
    @Test func stepsComeFromTheSameRun() {
        let rewrites = [
            Rewrite(pattern: "[?&]utm_[^&]*", template: ""),
            Rewrite(pattern: "^http://", template: "https://"),
            Rewrite(pattern: "trifft-nicht", template: "x"),
        ]
        let url = u("http://example.com/a?utm_source=x")
        let run = Rewriter.run(rewrites, on: url, budget: MatchBudget(), collectSteps: true)
        #expect(run.steps == ["http://example.com/a", "https://example.com/a", "https://example.com/a"])
        #expect(run.output.url.absoluteString == run.steps.last)
        #expect(run.output == Rewriter.apply(rewrites, to: url))
        let test = RuleEngine.test(rule: Rule(name: "R", rewrites: rewrites, action: .prompt(.all)), url: url, context: LinkContext(), config: Config())
        #expect(test.rewriteSteps == run.steps)
        #expect(test.finalURL == run.output.url)
    }

    @Test func failingStepKeepsTextAndFallsBackToOriginal() {
        let rewrites = [Rewrite(pattern: "([", template: "x"), Rewrite(pattern: "^http:", template: "https:")]
        let url = u("http://example.com")
        let run = Rewriter.run(rewrites, on: url, budget: MatchBudget(), collectSteps: true)
        #expect(run.steps == ["http://example.com", "https://example.com"])
        #expect(run.output.url == url)
        #expect(run.output.warnings.count == 1)
    }
}

// MARK: - K16 Sperre

@Suite("App-Auflösung außerhalb der Dateisperre (§27 K16)")
struct ResolveOutsideLockTests {
    final class SpyResolver: AppResolving, @unchecked Sendable {
        let base = FakeAppResolver()
        let lock = NSLock()
        var callsInsideLock = 0
        var calls = 0

        func note() {
            lock.withLock {
                calls += 1
                if ConfigStore.isInsideModify { callsInsideLock += 1 }
            }
        }

        func resolveApp(_ query: String) -> AppRef? { note(); return base.resolveApp(query) }
        func isInstalled(_ app: AppRef) -> Bool { note(); return base.isInstalled(app) }
        func installedBrowsers() -> [AppRef] { base.installedBrowsers() }
    }

    @Test func createAndUpdateResolveAppsBeforeLocking() throws {
        let temp = try TempConfig()
        defer { temp.remove() }
        let spy = SpyResolver()
        let api = AgentAPI(store: temp.store, resolver: spy)
        let created = try api.createRule(["name": "Figma", "conditions": [["type": "host", "op": "equals", "value": "figma.com"]], "action": ["type": "open", "app": "Figma"]])
        let id = try #require(created.json["rule"]?["id"]?.stringValue)
        _ = try api.updateRule(id, patch: ["action": ["type": "open", "app": "com.figma.Desktop"]])
        #expect(spy.calls > 0)
        #expect(spy.callsInsideLock == 0)
        let rule = try #require(temp.load().rules.last)
        #expect(rule.action == .open(FakeAppResolver.figma))
    }

    @Test func errorsStillComeFromTheLockedRun() throws {
        let temp = try TempConfig()
        defer { temp.remove() }
        let api = AgentAPI(store: temp.store, resolver: SpyResolver())
        #expect(throws: AgentError.self) {
            try api.createRule(["name": "X", "action": ["type": "open", "app": "Gibt es nicht"]])
        }
        #expect(try temp.load().rules.count == 3)
    }
}

// MARK: - A10/A15 Liste in der App

@Suite("Auswahl nach Löschen und Rückgängig in der Liste (§27 A10, A15)")
struct RuleListEditingTests {
    static let ids = (0..<5).map { _ in UUID() }
    static let rules = ids.enumerated().map { Rule(id: $1, name: "R\($0)", action: .prompt(.all)) }

    @Test func nextSelectionComesFromVisibleRules() {
        let visible = [Self.ids[1], Self.ids[3], Self.ids[4]]
        #expect(RuleListEditing.selection(afterRemoving: Self.ids[3], visible: visible) == Self.ids[4])
        #expect(RuleListEditing.selection(afterRemoving: Self.ids[4], visible: visible) == Self.ids[3])
        #expect(RuleListEditing.selection(afterRemoving: Self.ids[1], visible: [Self.ids[1]]) == nil)
        // Gefilterte Liste: Regel 2 ist sichtbar-nächste, nicht Regel 3 der Gesamtliste.
        #expect(RuleListEditing.selection(afterRemoving: Self.ids[1], visible: visible) == Self.ids[3])
    }

    @Test func reorderRestoresOrderAndKeepsNewRules() {
        var moved = Self.rules
        moved.append(moved.removeFirst())
        let extra = Rule(name: "Neu", action: .prompt(.all))
        moved.append(extra)
        let restored = RuleListEditing.reorder(moved, to: Self.ids)
        #expect(restored.map(\.id) == Self.ids + [extra.id])
    }

    @Test func reinsertPutsRuleBackOnce() {
        var rules = Self.rules
        let removed = rules.remove(at: 2)
        RuleListEditing.reinsert(removed, at: 2, into: &rules)
        RuleListEditing.reinsert(removed, at: 2, into: &rules)
        #expect(rules.map(\.id) == Self.ids)
        var short = [Self.rules[0]]
        RuleListEditing.reinsert(Self.rules[4], at: 9, into: &short)
        #expect(short.map(\.id) == [Self.ids[0], Self.ids[4]])
    }
}


@Suite("Hostanzeige gegen Homographen (§27 A4)")
struct HostDisplayTests {
    @Test func latinIDNIsShownAsUnicode() {
        #expect(HostName.display("xn--bcher-kva.de") == "bücher.de")
        #expect(HostName.display("bücher.de") == "bücher.de")
        #expect(HostName.display("example.com") == "example.com")
    }

    @Test func nonLatinOrMixedStaysPunycode() {
        // kyrillisches а in „аpple.com“
        #expect(HostName.display("xn--pple-43d.com") == "xn--pple-43d.com")
        #expect(HostName.display("\u{0430}pple.com") == "xn--pple-43d.com")
    }
}
