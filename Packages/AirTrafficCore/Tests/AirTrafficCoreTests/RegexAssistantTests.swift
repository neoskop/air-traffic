import Foundation
import Synchronization
import Testing
@testable import AirTrafficCore

/// Liefert vorbereitete Antworten der Reihe nach und merkt sich die Anfragen.
final class FakeLLMClient: LLMClient {
    private let state: Mutex<(replies: [Result<String, LLMError>], requests: [LLMRequest])>

    init(_ replies: [String]) {
        state = Mutex((replies.map { .success($0) }, []))
    }

    init(results: [Result<String, LLMError>]) {
        state = Mutex((results, []))
    }

    var requests: [LLMRequest] { state.withLock { $0.requests } }

    func complete(_ request: LLMRequest) async throws -> String {
        let next: Result<String, LLMError> = state.withLock { s in
            s.requests.append(request)
            return s.replies.isEmpty ? .failure(.invalidResponse("keine Fake-Antwort mehr")) : s.replies.removeFirst()
        }
        return try next.get()
    }
}

struct FakeKeyStore: APIKeyStore {
    var key: String?
    func readKey() throws -> String? { key }
    func hasKey() -> Bool { key != nil }
    func saveKey(_ key: String) throws {}
    func deleteKey() throws {}
}

@Suite("RegexAssistant")
struct RegexAssistantTests {
    static let prExample = "https://github.com/acme/webshop/pull/3776/files?w=1"
    static let goodRewrite = #"""
    {"pattern": "^https://github\\.com/(.*)$", "template": "https://linear.review/$1", "explanation": "Ersetzt den Host."}
    """#

    // MARK: Prompt

    @Test func systemPromptCoversContract() {
        let p = RegexAssistant.systemPrompt
        #expect(p.contains("NSRegularExpression"))
        #expect(p.contains("entire URL"))
        #expect(p.contains("case-insensitive"))
        #expect(p.contains("$1"))
        #expect(p.contains(#"literal "$" as "\$""#))
        #expect(p.contains("query string and the fragment"))
        #expect(p.contains("Match only the URLs the user describes"))
        #expect(p.contains(#"{"pattern": string, "template": string or null, "explanation": string}"#))
    }

    @Test func initialMessageContainsExamplesDescriptionAndMode() {
        let rewrite = RegexAssistant.initialMessage(
            mode: .rewrite,
            examples: [Self.prExample, "https://github.com/a/b/pull/1"],
            description: "Ersetze github.com durch linear.review, Rest bleibt gleich"
        )
        #expect(rewrite.contains("Mode: REWRITE"))
        #expect(rewrite.contains(Self.prExample))
        #expect(rewrite.contains("https://github.com/a/b/pull/1"))
        #expect(rewrite.contains("Ersetze github.com durch linear.review, Rest bleibt gleich"))
        #expect(!rewrite.contains("Current pattern"))

        let condition = RegexAssistant.initialMessage(mode: .condition(.url), examples: [Self.prExample], description: "PRs")
        #expect(condition.contains("Mode: CONDITION"))
        #expect(condition.contains("template null"))
        #expect(!condition.contains("Mode: REWRITE"))

        let host = RegexAssistant.initialMessage(mode: .condition(.host), examples: [Self.prExample], description: "x")
        #expect(host.contains("host only"))
        #expect(host.contains(#"(host: "github.com")"#))
    }

    @Test func initialMessageIncludesExistingRewriteAndCaseSensitivity() {
        let text = RegexAssistant.initialMessage(
            mode: .rewrite,
            examples: [],
            description: "Auch Issues",
            current: RegexSuggestion(pattern: "^a(.*)$", template: "b$1"),
            caseSensitive: true
        )
        #expect(text.contains("Current pattern: ^a(.*)$"))
        #expect(text.contains("Current template: b$1"))
        #expect(text.contains("case-SENSITIVE"))
    }

    @Test func requestUsesModelSchemaAndTemperatureZero() async throws {
        let fake = FakeLLMClient([Self.goodRewrite])
        _ = try await RegexAssistant(client: fake, model: "test/model")
            .start(mode: .rewrite, examples: [Self.prExample], description: "d")
        let request = try #require(fake.requests.first)
        #expect(request.model == "test/model")
        #expect(request.temperature == 0)
        #expect(request.responseSchema == RegexAssistant.responseSchema)
        #expect(request.messages.map(\.role) == [.system, .user])
        #expect(request.messages[0].content == RegexAssistant.systemPrompt)
    }

    // MARK: Parsing

    @Test func parsesPlainJSON() throws {
        let s = try RegexAssistant.parse(Self.goodRewrite)
        #expect(s.pattern == #"^https://github\.com/(.*)$"#)
        #expect(s.template == "https://linear.review/$1")
        #expect(s.explanation == "Ersetzt den Host.")
    }

    @Test func parsesCodeBlockAndSurroundingText() throws {
        let fenced = "Hier ist das Ergebnis:\n```json\n{\"pattern\": \"^x$\", \"template\": null, \"explanation\": \"E\"}\n```\nViel Erfolg!"
        let s = try RegexAssistant.parse(fenced)
        #expect(s == RegexSuggestion(pattern: "^x$", template: nil, explanation: "E"))

        let bare = "```\n{\"pattern\": \"a\", \"template\": \"b\", \"explanation\": \"\"}\n```"
        #expect(try RegexAssistant.parse(bare).template == "b")

        let prose = "Sure: {\"pattern\": \"a\", \"template\": \"b\", \"explanation\": \"c\"} – done"
        #expect(try RegexAssistant.parse(prose).pattern == "a")
    }

    @Test func missingTemplateAndExplanationAreTolerated() throws {
        let s = try RegexAssistant.parse(#"{"pattern": "^a$"}"#)
        #expect(s.template == nil)
        #expect(s.explanation == "")
    }

    @Test func rejectsBrokenResponses() {
        for broken in ["", "Ich kann das nicht.", "{\"pattern\": ", "```json\n{not json}\n```", #"{"template": "x"}"#, #"{"pattern": 3}"#] {
            #expect(throws: LLMError.self, "\(broken)") { try RegexAssistant.parse(broken) }
        }
    }

    // MARK: Validierung

    @Test func validationRewriteTableAndPflichtfall() {
        let v = RegexAssistant.validate(
            pattern: #"^https://github\.com/([^/]+)/([^/]+)/pull/(\d+)(.*)$"#,
            template: "https://linear.review/$1/$2/pull/$3$4",
            mode: .rewrite,
            examples: [Self.prExample, "https://github.com/acme/webshop/issues/12"]
        )
        #expect(v.isValid)
        #expect(v.results[0].matches)
        #expect(v.results[0].output == "https://linear.review/acme/webshop/pull/3776/files?w=1")
        #expect(!v.results[1].matches)
        #expect(v.results[1].output == "https://github.com/acme/webshop/issues/12")
        #expect(v.hints.isEmpty)
    }

    @Test func validationDetectsBadPatternMissingTemplateAndInvalidURL() {
        let bad = RegexAssistant.validate(pattern: "([", template: "x", mode: .rewrite, examples: [Self.prExample])
        #expect(!bad.isValid)
        #expect(!bad.patternCompiles)
        if case .invalidPattern = bad.problems.first {} else { Issue.record("invalidPattern erwartet") }

        let empty = RegexAssistant.validate(pattern: "", template: "x", mode: .rewrite, examples: [])
        #expect(empty.problems == [.emptyPattern])

        let noTemplate = RegexAssistant.validate(pattern: "^(.*)$", template: nil, mode: .rewrite, examples: [])
        #expect(noTemplate.problems == [.missingTemplate])
        #expect(noTemplate.patternCompiles)

        let invalidURL = RegexAssistant.validate(pattern: "^https://(.*)$", template: "not a url $1", mode: .rewrite, examples: [Self.prExample])
        #expect(invalidURL.problems.count == 1)
        if case .invalidResultURL(let input, _) = invalidURL.problems.first { #expect(input == Self.prExample) }
        else { Issue.record("invalidResultURL erwartet") }
        #expect(!invalidURL.results[0].outputIsValidURL)
    }

    @Test func validationConditionUsesTargetAndCaseSensitivity() {
        let host = RegexAssistant.validate(pattern: #"^github\.com$"#, template: "ignored", mode: .condition(.host), examples: [Self.prExample, "https://gitlab.com/x"])
        #expect(host.isValid)
        #expect(host.results.map(\.matches) == [true, false])
        #expect(host.results[0].output == nil)

        let path = RegexAssistant.validate(pattern: #"^/[^/]+/[^/]+/pull/\d+"#, template: nil, mode: .condition(.path), examples: [Self.prExample])
        #expect(path.results[0].matches)

        let insensitive = RegexAssistant.validate(pattern: "GITHUB", template: nil, mode: .condition(.url), examples: [Self.prExample])
        #expect(insensitive.results[0].matches)
        let sensitive = RegexAssistant.validate(pattern: "GITHUB", template: nil, caseSensitive: true, mode: .condition(.url), examples: [Self.prExample])
        #expect(!sensitive.results[0].matches)
        #expect(sensitive.hints == ["Das Muster trifft keine der Beispiel-URLs."])
    }

    @Test func invalidExampleIsHintNotProblem() {
        let v = RegexAssistant.validate(pattern: "^(.*)$", template: "$1", mode: .rewrite, examples: ["kein url"])
        #expect(v.isValid)
        #expect(!v.results[0].inputIsValidURL)
        #expect(v.hints.contains { $0.contains("keine gültige URL") })
    }

    @Test func examplesFromMultilineText() {
        #expect(RegexAssistant.examples(from: "  https://a.example/ \n\n\thttps://b.example/\r\n") == ["https://a.example/", "https://b.example/"])
    }

    // MARK: Reparaturrunde & Verlauf

    @Test func repairRoundAfterInvalidPattern() async throws {
        let fake = FakeLLMClient([
            #"{"pattern": "^https://github\\.com/((.*)$", "template": "https://linear.review/$1", "explanation": "kaputt"}"#,
            Self.goodRewrite,
        ])
        let turn = try await RegexAssistant(client: fake, model: "m")
            .start(mode: .rewrite, examples: [Self.prExample], description: "github → linear.review")

        #expect(turn.repaired)
        #expect(turn.validation.isValid)
        #expect(turn.warnings.isEmpty)
        #expect(turn.suggestion.template == "https://linear.review/$1")
        #expect(turn.validation.results[0].output == "https://linear.review/acme/webshop/pull/3776/files?w=1")

        #expect(fake.requests.count == 2)
        let repair = try #require(fake.requests[1].messages.last)
        #expect(repair.role == .user)
        #expect(repair.content.contains("failed local validation"))
        #expect(repair.content.contains("does not compile"))
        #expect(fake.requests[1].messages.map(\.role) == [.system, .user, .assistant, .user])
        #expect(turn.conversation.messages.count == 5)
    }

    @Test func repairRoundAfterInvalidResultURL() async throws {
        let fake = FakeLLMClient([
            #"{"pattern": "^https://(.*)$", "template": "linear review $1", "explanation": ""}"#,
            Self.goodRewrite,
        ])
        let turn = try await RegexAssistant(client: fake, model: "m").start(mode: .rewrite, examples: [Self.prExample], description: "d")
        #expect(turn.repaired)
        #expect(fake.requests[1].messages.last?.content.contains("not a valid absolute URL") == true)
    }

    @Test func onlyOneRepairRoundThenWarning() async throws {
        let bad = #"{"pattern": "((", "template": "x", "explanation": ""}"#
        let fake = FakeLLMClient([bad, bad, Self.goodRewrite])
        let turn = try await RegexAssistant(client: fake, model: "m").start(mode: .rewrite, examples: [Self.prExample], description: "d")
        #expect(fake.requests.count == 2)
        #expect(turn.repaired)
        #expect(!turn.validation.isValid)
        #expect(turn.warnings.first?.contains("Reparaturrunde") == true)
        #expect(turn.suggestion.pattern == "((")
    }

    @Test func noRepairWhenValid() async throws {
        let fake = FakeLLMClient([Self.goodRewrite])
        let turn = try await RegexAssistant(client: fake, model: "m").start(mode: .rewrite, examples: [Self.prExample], description: "d")
        #expect(!turn.repaired)
        #expect(fake.requests.count == 1)
    }

    @Test func unparsableAnswerGetsRepairThenThrows() async throws {
        let repaired = FakeLLMClient(["Das geht so nicht.", Self.goodRewrite])
        let turn = try await RegexAssistant(client: repaired, model: "m").start(mode: .rewrite, examples: [Self.prExample], description: "d")
        #expect(turn.repaired)
        #expect(repaired.requests[1].messages.last?.content.contains("could not be parsed") == true)

        let hopeless = FakeLLMClient(["nein", "immer noch nein"])
        await #expect(throws: LLMError.self) {
            try await RegexAssistant(client: hopeless, model: "m").start(mode: .rewrite, examples: [], description: "d")
        }
    }

    @Test func conditionModeDropsTemplate() async throws {
        let fake = FakeLLMClient([#"{"pattern": "github\\.com", "template": "x", "explanation": "e"}"#])
        let turn = try await RegexAssistant(client: fake, model: "m").start(mode: .condition(.url), examples: [Self.prExample], description: "d")
        #expect(turn.suggestion.template == nil)
        #expect(turn.validation.results[0].matches)
    }

    @Test func refineKeepsHistory() async throws {
        let fake = FakeLLMClient([
            Self.goodRewrite,
            #"{"pattern": "^https://github\\.com/(.*)\\?.*$", "template": "https://linear.review/$1", "explanation": "Ohne Query."}"#,
        ])
        let assistant = RegexAssistant(client: fake, model: "m")
        let first = try await assistant.start(mode: .rewrite, examples: [Self.prExample], description: "github → linear.review")
        var edited = first.suggestion
        edited.template = "https://linear.review/$1#edited"
        let second = try await assistant.refine(first.conversation, instruction: "Query entfernen", examples: [Self.prExample], current: edited)

        #expect(second.suggestion.explanation == "Ohne Query.")
        #expect(second.validation.results[0].output == "https://linear.review/acme/webshop/pull/3776/files")
        let messages = fake.requests[1].messages
        #expect(messages.map(\.role) == [.system, .user, .assistant, .user])
        #expect(messages[1].content.contains("github → linear.review"))
        #expect(messages[2].content == Self.goodRewrite)
        #expect(messages[3].content.contains("Query entfernen"))
        #expect(messages[3].content.contains("#edited"), "vom Nutzer bearbeiteter Stand geht mit")
        #expect(second.conversation.messages.count == 5)
    }

    @Test func clientErrorsPropagate() async {
        let fake = FakeLLMClient(results: [.failure(.paymentRequired)])
        await #expect(throws: LLMError.paymentRequired) {
            try await RegexAssistant(client: fake, model: "m").start(mode: .rewrite, examples: [], description: "d")
        }
    }

    // MARK: Fehler & Key

    @Test func httpStatusMapping() {
        #expect(LLMError.from(status: 200) == nil)
        #expect(LLMError.from(status: 401) == .unauthorized)
        #expect(LLMError.from(status: 402) == .paymentRequired)
        #expect(LLMError.from(status: 429) == .rateLimited)
        #expect(LLMError.from(status: 500) == .server(status: 500))
        #expect(LLMError.from(status: 503) == .server(status: 503))
        #expect(LLMError.from(status: 400, message: "bad") == .http(status: 400, message: "bad"))

        #expect(LLMError.unauthorized.localizedDescription == "API-Key ungültig")
        #expect(LLMError.paymentRequired.localizedDescription == "Kein Guthaben bei OpenRouter")
        #expect(LLMError.rateLimited.localizedDescription == "Zu viele Anfragen, bitte kurz warten")
        #expect(LLMError.server(status: 502).localizedDescription.contains("502"))
        #expect(LLMError.timeout.localizedDescription.contains("Zeitüberschreitung"))
        #expect(LLMError.network("offline").localizedDescription.contains("Netzwerkfehler"))
        #expect(LLMError.invalidResponse("x").localizedDescription.contains("nicht lesbar"))
    }

    @Test func apiKeyResolution() throws {
        #expect(try APIKeyResolver.resolve(environment: ["OPENROUTER_API_KEY": " env "], store: FakeKeyStore(key: "store")) == "env")
        #expect(try APIKeyResolver.resolve(environment: ["OPENROUTER_API_KEY": ""], store: FakeKeyStore(key: "store")) == "store")
        #expect(throws: LLMError.missingAPIKey) { try APIKeyResolver.resolve(environment: [:], store: FakeKeyStore(key: nil)) }
        #expect(throws: LLMError.missingAPIKey) { try APIKeyResolver.resolve(environment: [:], store: nil) }
    }
}
