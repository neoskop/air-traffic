import Foundation
import Testing
@testable import AirTrafficCore

@Suite("Config JSON")
struct ConfigTests {
    static func fullConfig() -> Config {
        let a = AppRef(bundleIdentifier: "com.example.a", path: "/Applications/A.app", displayName: "A")
        let noID = AppRef(bundleIdentifier: nil, path: "/Applications/Ohne ID.app", displayName: "Ohne ID")
        return Config(
            browsers: [a, noID],
            rules: [
                Rule(
                    name: "Text",
                    match: .any,
                    conditions: TextOp.allCases.enumerated().map { i, op in
                        let m = TextMatch(op: op, value: "v\(i)", caseSensitive: i.isMultiple(of: 2))
                        switch i % 3 {
                        case 0: return .url(m)
                        case 1: return .host(m)
                        default: return .path(m)
                        }
                    },
                    rewrites: [Rewrite(pattern: "^(a)$", template: "$1", caseSensitive: true)],
                    action: .open(a)
                ),
                Rule(
                    name: "Kontext",
                    enabled: false,
                    match: .none,
                    conditions: [
                        .sourceApp(bundleIdentifier: "com.apple.mail", negated: true),
                        .modifiers([.command, .option, .control, .shift], negated: false),
                        .modifiers([], negated: true),
                        .linkType(.web),
                        .linkType(.file),
                    ],
                    action: .openFirstRunning(fallback: noID)
                ),
                Rule(name: "Ohne Fallback", action: .openFirstRunning(fallback: nil)),
                Rule(name: "Laufende", action: .prompt(.running)),
                TestRules.githubPullRequestToLinearReview(),
            ],
            defaultAction: .prompt(.all)
        )
    }

    @Test func roundTripAllEnumCases() throws {
        let config = Self.fullConfig()
        let data = try ConfigStore.encode(config)
        let decoded = try ConfigStore.decode(data)
        #expect(decoded == config)
        // Stabil: erneutes Kodieren ergibt identische Bytes.
        #expect(try ConfigStore.encode(decoded) == data)
    }

    @Test func readableDiscriminatedJSON() throws {
        let json = String(decoding: try ConfigStore.encode(Self.fullConfig()), as: UTF8.self)
        #expect(json.contains(#""schemaVersion" : 1"#))
        #expect(json.contains(#""type" : "host""#))
        #expect(json.contains(#""type" : "sourceApp""#))
        #expect(json.contains(#""type" : "openFirstRunning""#))
        #expect(json.contains(#""modifiers" : ["#))
        #expect(json.contains(#""command""#))
        #expect(json.contains("https://linear.review/$1/$2/pull/$3$4"), "keine maskierten Schrägstriche")
        #expect(!json.contains("_0"), "keine Swift-Standardsynthese")
    }

    @Test func decodesHandwrittenJSON() throws {
        let json = """
        {
          "schemaVersion": 1,
          "browsers": [{"path": "/Applications/Safari.app", "displayName": "Safari", "bundleIdentifier": "com.apple.Safari"}],
          "rules": [{
            "id": "7D6D2F4C-5E2B-4C42-9C1B-4C2F3E2B9A11",
            "name": "GitHub",
            "match": "all",
            "conditions": [{"type": "host", "op": "equals", "value": "github.com"}],
            "action": {"type": "open", "app": {"path": "/Applications/Linear.app", "displayName": "Linear"}}
          }],
          "defaultAction": {"type": "prompt", "scope": "running"}
        }
        """
        let config = try ConfigStore.decode(Data(json.utf8))
        #expect(config.rules[0].enabled)
        #expect(config.rules[0].rewrites.isEmpty)
        #expect(config.rules[0].conditions == [.host(TextMatch(op: .equals, value: "github.com", caseSensitive: false))])
        #expect(config.defaultAction == .prompt(.running))
        #expect(config.browsers[0].bundleIdentifier == "com.apple.Safari")
    }

    @Test func rejectsUnknownDiscriminatorAndFutureSchema() {
        let unknown = #"{"schemaVersion":1,"browsers":[],"rules":[],"defaultAction":{"type":"teleport"}}"#
        #expect(throws: DecodingError.self) { try ConfigStore.decode(Data(unknown.utf8)) }
        let future = #"{"schemaVersion":2,"browsers":[],"rules":[],"defaultAction":{"type":"prompt","scope":"all"}}"#
        #expect(throws: ConfigStore.StoreError.unsupportedSchemaVersion(2)) { try ConfigStore.decode(Data(future.utf8)) }
    }

    @Test func decisionJSON() throws {
        let d = Decision(
            originalURL: URL(string: "https://example.com")!,
            finalURL: URL(string: "https://example.org")!,
            matchedRuleID: nil,
            action: .prompt(.all),
            warnings: []
        )
        let data = try ConfigStore.makeEncoder().encode(d)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(#""matchedRuleID" : null"#))
        #expect(json.contains(#""finalURL" : "https://example.org""#))
        #expect(try JSONDecoder().decode(Decision.self, from: data) == d)
    }

    @Test func storeSavesAtomicallyAndLoads() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "AirTrafficTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(fileURL: dir.appending(path: "sub/config.json"))
        #expect(try store.load() == nil)
        let config = Self.fullConfig()
        try store.save(config)
        #expect(store.exists)
        #expect(try store.load() == config)
    }

    @Test func assistantRoundTripWithAndWithout() throws {
        var config = Self.fullConfig()
        let without = String(decoding: try ConfigStore.encode(config), as: UTF8.self)
        #expect(!without.contains("assistant"), "fehlt = nicht geschrieben")
        #expect(try ConfigStore.decode(Data(without.utf8)).assistant == nil)
        #expect(config.assistantModel == "anthropic/claude-haiku-5.5")

        config.assistant = AssistantSettings(model: "openai/gpt-x")
        let data = try ConfigStore.encode(config)
        #expect(String(decoding: data, as: UTF8.self).contains(#""model" : "openai/gpt-x""#))
        let decoded = try ConfigStore.decode(data)
        #expect(decoded == config)
        #expect(decoded.assistantModel == "openai/gpt-x")

        config.assistant = AssistantSettings(model: nil)
        let empty = try ConfigStore.decode(try ConfigStore.encode(config))
        #expect(empty.assistant == AssistantSettings(model: nil))
        #expect(empty.assistantModel == AssistantSettings.defaultModel)
        config.assistant = AssistantSettings(model: "  ")
        #expect(config.assistantModel == AssistantSettings.defaultModel)
    }

    @Test func oldConfigWithoutAssistantStillLoads() throws {
        let json = #"{"schemaVersion":1,"browsers":[],"rules":[],"defaultAction":{"type":"prompt","scope":"all"}}"#
        let config = try ConfigStore.decode(Data(json.utf8))
        #expect(config.assistant == nil)
        let withAssistant = #"{"schemaVersion":1,"assistant":{},"defaultAction":{"type":"prompt","scope":"all"}}"#
        #expect(try ConfigStore.decode(Data(withAssistant.utf8)).assistantModel == AssistantSettings.defaultModel)
    }

    @Test func extensionSettingsRoundTripWithAndWithout() throws {
        var config = Self.fullConfig()
        let without = String(decoding: try ConfigStore.encode(config), as: UTF8.self)
        #expect(!without.contains("extensionSettings"), "fehlt = nicht geschrieben")
        #expect(try ConfigStore.decode(Data(without.utf8)).extensionSettings == nil)

        let safari = AppRef(bundleIdentifier: "com.apple.Safari", path: "/Applications/Safari.app", displayName: "Safari")
        config.extensionSettings = ExtensionSettings(applyRules: false, fallbackAction: .open(safari))
        let data = try ConfigStore.encode(config)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""applyRules" : false"#))
        #expect(text.contains(#""fallbackAction""#))
        #expect(try ConfigStore.decode(data) == config)

        config.extensionSettings = ExtensionSettings()
        let defaults = String(decoding: try ConfigStore.encode(config), as: UTF8.self)
        #expect(!defaults.contains("fallbackAction"), "nil = nicht geschrieben")
        #expect(try ConfigStore.decode(Data(defaults.utf8)) == config)
        #expect(ExtensionSettings().isDefault)
        #expect(!ExtensionSettings(applyRules: false).isDefault)
    }

    @Test func extensionSettingsDefaultsWhenFieldsMissing() throws {
        let json = #"{"schemaVersion":1,"extensionSettings":{},"defaultAction":{"type":"prompt","scope":"all"}}"#
        let config = try ConfigStore.decode(Data(json.utf8))
        #expect(config.extensionSettings == ExtensionSettings(applyRules: true, fallbackAction: nil))
        let partial = #"{"schemaVersion":1,"extensionSettings":{"fallbackAction":{"type":"prompt","scope":"running"}}}"#
        #expect(try ConfigStore.decode(Data(partial.utf8)).extensionSettings == ExtensionSettings(fallbackAction: .prompt(.running)))
    }

    @Test func appearanceRoundTripWithAndWithout() throws {
        var config = Self.fullConfig()
        let without = String(decoding: try ConfigStore.encode(config), as: UTF8.self)
        #expect(!without.contains("appearance"), "fehlt = nicht geschrieben")
        #expect(try ConfigStore.decode(Data(without.utf8)).effectiveAppearance == .system)

        for value in [AppAppearance.light, .dark] {
            config.appearance = value
            let data = try ConfigStore.encode(config)
            #expect(String(decoding: data, as: UTF8.self).contains(#""appearance" : "\#(value.rawValue)""#))
            let decoded = try ConfigStore.decode(data)
            #expect(decoded == config)
            #expect(decoded.effectiveAppearance == value)
        }

        config.appearance = .system
        #expect(config.appearance == nil, "system wird als nil gespeichert")
        let system = String(decoding: try ConfigStore.encode(config), as: UTF8.self)
        #expect(!system.contains("appearance"))
        #expect(Config(appearance: .system).appearance == nil)
    }

    @Test func appearanceMissingOrUnknownLoadsAsSystem() throws {
        let old = #"{"schemaVersion":1,"defaultAction":{"type":"prompt","scope":"all"}}"#
        let config = try ConfigStore.decode(Data(old.utf8))
        #expect(config.appearance == nil)
        #expect(config.effectiveAppearance == .system)

        let explicit = #"{"schemaVersion":1,"appearance":"system"}"#
        #expect(try ConfigStore.decode(Data(explicit.utf8)).appearance == nil)
        let unknown = #"{"schemaVersion":1,"appearance":"sepia"}"#
        #expect(try ConfigStore.decode(Data(unknown.utf8)).effectiveAppearance == .system)
        let dark = #"{"schemaVersion":1,"appearance":"dark"}"#
        #expect(try ConfigStore.decode(Data(dark.utf8)).appearance == .dark)
    }

    @Test func testURLRoundTripWithAndWithout() throws {
        var config = Self.fullConfig()
        let without = String(decoding: try ConfigStore.encode(config), as: UTF8.self)
        #expect(!without.contains("testURL"), "nil = nicht geschrieben")
        #expect(try ConfigStore.decode(Data(without.utf8)).rules.allSatisfy { $0.testURL == nil })

        config.rules[0].testURL = "https://github.com/acme/webshop/pull/3776"
        let data = try ConfigStore.encode(config)
        #expect(String(decoding: data, as: UTF8.self).contains(#""testURL" : "https://github.com/acme"#))
        let decoded = try ConfigStore.decode(data)
        #expect(decoded == config)
        #expect(decoded.rules[0].testURL == "https://github.com/acme/webshop/pull/3776")
        #expect(decoded.rules[1].testURL == nil)
        #expect(try ConfigStore.encode(decoded) == data)
    }

    @Test func environmentOverridesPath() {
        let url = ConfigStore.defaultFileURL(environment: ["AIRTRAFFIC_CONFIG_PATH": "/tmp/x/config.json"])
        #expect(url.path == "/tmp/x/config.json")
        let standard = ConfigStore.defaultFileURL(environment: [:])
        #expect(standard.path.hasSuffix("Library/Application Support/Air Traffic/config.json"))
    }
}
