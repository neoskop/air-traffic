import Foundation
import Testing
@testable import AirTrafficCore

private func u(_ s: String) -> URL { URL(string: s)! }

@Suite("AirTrafficURL.parse")
struct AirTrafficURLParseTests {
    @Test func decodesPercentEncodedURL() throws {
        let request = try AirTrafficURL.parse(
            u("airtraffic://open?url=https%3A%2F%2Fgithub.com%2Facme%2Fwebshop%2Fpull%2F42%3Fw%3D1%26x%3D%C3%A4%23files")
        )
        #expect(request.url.absoluteString == "https://github.com/acme/webshop/pull/42?w=1&x=%C3%A4#files")
        #expect(request.source == nil)
        #expect(request.prompt == false)
    }

    @Test func acceptsUnencodedSimpleURL() throws {
        let request = try AirTrafficURL.parse(u("airtraffic://open?url=https://example.com/a/b"))
        #expect(request.url == u("https://example.com/a/b"))
    }

    @Test func plusStaysPlus() throws {
        let request = try AirTrafficURL.parse(u("airtraffic://open?url=https%3A%2F%2Fexample.com%2Fs%3Fq%3Da%2Bb"))
        #expect(request.url.absoluteString == "https://example.com/s?q=a+b")
    }

    @Test func sourceAndPrompt() throws {
        let request = try AirTrafficURL.parse(
            u("airtraffic://open?url=https%3A%2F%2Fexample.com&source=com.apple.Safari&prompt=1")
        )
        #expect(request.source == "com.apple.Safari")
        #expect(request.prompt)
    }

    @Test(arguments: [
        ("prompt=1", true), ("prompt=true", true), ("prompt=0", false), ("prompt=", false), ("", false),
    ])
    func promptValues(query: String, expected: Bool) throws {
        let suffix = query.isEmpty ? "" : "&\(query)"
        let request = try AirTrafficURL.parse(u("airtraffic://open?url=https%3A%2F%2Fexample.com\(suffix)"))
        #expect(request.prompt == expected)
    }

    @Test func emptySourceIsNil() throws {
        let request = try AirTrafficURL.parse(u("airtraffic://open?url=https%3A%2F%2Fexample.com&source="))
        #expect(request.source == nil)
    }

    @Test func schemeAndHostAreCaseInsensitive() throws {
        let request = try AirTrafficURL.parse(u("AirTraffic://OPEN/?url=http%3A%2F%2Fexample.com"))
        #expect(request.url == u("http://example.com"))
    }

    @Test func missingURL() {
        #expect(throws: AirTrafficURL.ParseError.missingURL) {
            try AirTrafficURL.parse(u("airtraffic://open"))
        }
        #expect(throws: AirTrafficURL.ParseError.missingURL) {
            try AirTrafficURL.parse(u("airtraffic://open?url="))
        }
        #expect(throws: AirTrafficURL.ParseError.missingURL) {
            try AirTrafficURL.parse(u("airtraffic://open?source=com.apple.Safari"))
        }
    }

    @Test func invalidURL() {
        #expect(throws: AirTrafficURL.ParseError.invalidURL("kein link")) {
            try AirTrafficURL.parse(u("airtraffic://open?url=kein%20link"))
        }
        #expect(throws: AirTrafficURL.ParseError.invalidURL("https:///pfad")) {
            try AirTrafficURL.parse(u("airtraffic://open?url=https%3A%2F%2F%2Fpfad"))
        }
    }

    @Test(arguments: [
        ("javascript%3Aalert(1)", "javascript"),
        ("file%3A%2F%2F%2Fetc%2Fpasswd", "file"),
        ("ftp%3A%2F%2Fexample.com", "ftp"),
        ("airtraffic%3A%2F%2Fopen%3Furl%3Dhttps%253A%252F%252Fexample.com", "airtraffic"),
        ("JavaScript%3Aalert(1)", "javascript"),
    ])
    func rejectsNonWebSchemes(encoded: String, scheme: String) {
        #expect(throws: AirTrafficURL.ParseError.unsupportedScheme(scheme)) {
            try AirTrafficURL.parse(u("airtraffic://open?url=\(encoded)"))
        }
    }

    @Test(arguments: ["airtraffic://settings?url=https%3A%2F%2Fexample.com", "airtraffic://open/x?url=https%3A%2F%2Fexample.com", "airtraffic:open"])
    func ignoresOtherTargets(string: String) {
        #expect {
            try AirTrafficURL.parse(u(string))
        } throws: { error in
            if case .unsupportedTarget = error as? AirTrafficURL.ParseError { return true }
            return false
        }
    }

    @Test func rejectsOtherSchemes() {
        #expect(throws: AirTrafficURL.ParseError.notAirTraffic) {
            try AirTrafficURL.parse(u("https://open?url=https%3A%2F%2Fexample.com"))
        }
        #expect(AirTrafficURL.isAirTrafficURL(u("AIRTRAFFIC://open")))
        #expect(!AirTrafficURL.isAirTrafficURL(u("https://example.com")))
    }

    @Test(arguments: [
        "https://example.com/",
        "https://github.com/acme/webshop/pull/42/files?w=1&x=2#diff-abc",
        "https://example.com/s?q=a+b&r=c%20d&e=%26%3D",
        "http://user@example.com:8080/p;x?y=1",
        "https://xn--mnchen-3ya.de/stra%C3%9Fe",
    ])
    func makeRoundTrips(link: String) throws {
        let original = AirTrafficURL.Request(url: u(link), source: "com.apple.Safari", prompt: true)
        let built = AirTrafficURL.make(original)
        #expect(built.scheme == "airtraffic")
        #expect(built.host() == "open")
        #expect(try AirTrafficURL.parse(built) == original)
        #expect(try AirTrafficURL.parse(AirTrafficURL.make(.init(url: u(link)))) == .init(url: u(link)))
    }

    @Test func makeEncodesSeparators() {
        let built = AirTrafficURL.make(.init(url: u("https://example.com/?a=1&b=2#c")))
        #expect(built.absoluteString == "airtraffic://open?url=https%3A%2F%2Fexample.com%2F%3Fa%3D1%26b%3D2%23c")
    }
}

@Suite("AirTrafficURL.decide")
struct AirTrafficURLDecideTests {
    private static let browserA = AppRef(bundleIdentifier: "com.example.a", path: "/Applications/A.app", displayName: "A")

    private let config = Config(
            browsers: [Self.browserA],
            rules: [
                Rule(
                    name: "Aus Safari",
                    conditions: [.sourceApp(bundleIdentifier: "com.apple.Safari", negated: false), .host(.init(op: .equals, value: "safari.example"))],
                    action: .open(Self.browserA)
                ),
                TestRules.githubPullRequestToLinearReview(),
            ],
            defaultAction: .openFirstRunning(fallback: nil)
        )

    @Test func normalFlowAppliesRuleAndRewrite() {
        let request = AirTrafficURL.Request(url: u("https://github.com/acme/webshop/pull/3776"))
        let d = AirTrafficURL.decide(request, context: LinkContext(), config: config)
        #expect(d.finalURL == u("https://linear.review/acme/webshop/pull/3776"))
        #expect(d.action == .open(TestRules.linearApp))
    }

    @Test func promptKeepsRewriteButAlwaysShowsChooser() {
        let request = AirTrafficURL.Request(url: u("https://github.com/acme/webshop/pull/3776/files?w=1"), prompt: true)
        let d = AirTrafficURL.decide(request, context: LinkContext(), config: config)
        #expect(d.matchedRuleID == config.rules[1].id)
        #expect(d.finalURL == u("https://linear.review/acme/webshop/pull/3776/files?w=1"))
        #expect(d.action == .prompt(.all))
    }

    @Test func promptWithoutMatchingRule() {
        let request = AirTrafficURL.Request(url: u("https://example.com/"), prompt: true)
        let d = AirTrafficURL.decide(request, context: LinkContext(), config: config)
        #expect(d.matchedRuleID == nil)
        #expect(d.finalURL == u("https://example.com/"))
        #expect(d.action == .prompt(.all))
    }

    @Test func sourceOverridesSenderApp() {
        let url = u("https://safari.example/")
        let sender = LinkContext(sourceBundleIdentifier: "de.neoskop.AirTraffic.SafariExtension")
        let withSource = AirTrafficURL.Request(url: url, source: "com.apple.Safari")
        #expect(AirTrafficURL.decide(withSource, context: sender, config: config).matchedRuleID == config.rules[0].id)
        #expect(withSource.context(from: sender).sourceBundleIdentifier == "com.apple.Safari")

        let withoutSource = AirTrafficURL.Request(url: url)
        #expect(AirTrafficURL.decide(withoutSource, context: sender, config: config).matchedRuleID == nil)
        let fromSafari = LinkContext(sourceBundleIdentifier: "com.apple.Safari")
        #expect(AirTrafficURL.decide(withoutSource, context: fromSafari, config: config).matchedRuleID == config.rules[0].id)
    }

    // MARK: Eigenes Verhalten (§21.2)

    private static let browserB = AppRef(bundleIdentifier: "com.example.b", path: "/Applications/B.app", displayName: "B")

    private func config(_ settings: ExtensionSettings?) -> Config {
        var c = config
        c.extensionSettings = settings
        return c
    }

    @Test func defaultSettingsMatchNilSettings() {
        for link in ["https://github.com/acme/webshop/pull/3776", "https://example.com/"] {
            let request = AirTrafficURL.Request(url: u(link), source: "com.apple.Safari")
            #expect(
                AirTrafficURL.decide(request, context: LinkContext(), config: config(ExtensionSettings()))
                    == AirTrafficURL.decide(request, context: LinkContext(), config: config(nil))
            )
        }
        let d = AirTrafficURL.decide(.init(url: u("https://example.com/")), context: LinkContext(), config: config(nil))
        #expect(d.matchedRuleID == nil)
        #expect(d.action == .openFirstRunning(fallback: nil), "nil = globale Standardaktion")
    }

    @Test func ownFallbackWhenNoRuleMatches() {
        let c = config(ExtensionSettings(fallbackAction: .open(Self.browserB)))
        let none = AirTrafficURL.decide(.init(url: u("https://example.com/")), context: LinkContext(), config: c)
        #expect(none.matchedRuleID == nil)
        #expect(none.action == .open(Self.browserB))

        // Passt eine Regel, gilt weiter deren Aktion samt Umschreibung.
        let hit = AirTrafficURL.decide(.init(url: u("https://github.com/acme/webshop/pull/3776")), context: LinkContext(), config: c)
        #expect(hit.matchedRuleID == config.rules[1].id)
        #expect(hit.finalURL == u("https://linear.review/acme/webshop/pull/3776"))
        #expect(hit.action == .open(TestRules.linearApp))
    }

    @Test func rulesOffSkipsConditionsAndRewrites() {
        let request = AirTrafficURL.Request(url: u("https://github.com/acme/webshop/pull/3776"), source: "com.apple.Safari")
        let global = AirTrafficURL.decide(request, context: LinkContext(), config: config(ExtensionSettings(applyRules: false)))
        #expect(global.matchedRuleID == nil)
        #expect(global.finalURL == request.url, "keine Umschreibung")
        #expect(global.action == .openFirstRunning(fallback: nil), "nil = globale Standardaktion")

        let own = AirTrafficURL.decide(
            request, context: LinkContext(),
            config: config(ExtensionSettings(applyRules: false, fallbackAction: .prompt(.running)))
        )
        #expect(own.matchedRuleID == nil)
        #expect(own.finalURL == request.url)
        #expect(own.action == .prompt(.running))
    }

    @Test(arguments: [
        ExtensionSettings(applyRules: false, fallbackAction: .open(browserB)),
        ExtensionSettings(applyRules: true, fallbackAction: .open(browserB)),
        ExtensionSettings(applyRules: false),
    ])
    func promptUnchangedBySettings(settings: ExtensionSettings) {
        for link in ["https://github.com/acme/webshop/pull/3776", "https://example.com/"] {
            let request = AirTrafficURL.Request(url: u(link), prompt: true)
            let withSettings = AirTrafficURL.decide(request, context: LinkContext(), config: config(settings))
            #expect(withSettings == AirTrafficURL.decide(request, context: LinkContext(), config: config(nil)))
            #expect(withSettings.action == .prompt(.all))
        }
    }

    @Test func settingsDoNotAffectRuleEngine() {
        let c = config(ExtensionSettings(applyRules: false, fallbackAction: .open(Self.browserB)))
        let d = RuleEngine.decide(url: u("https://example.com/"), context: LinkContext(), config: c)
        #expect(d.action == .openFirstRunning(fallback: nil), "Standardbrowser-Links bleiben unberührt")
    }
}

