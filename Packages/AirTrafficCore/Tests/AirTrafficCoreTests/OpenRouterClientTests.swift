import Foundation
import Synchronization
import Testing
@testable import AirTrafficCore

/// URLProtocol-Stub: kein echtes Netz. Antwort pro Test über `StubURLProtocol.respond`.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int
        var body: Data
        var error: URLError?
    }

    private static let state = Mutex<(reply: Reply?, requests: [URLRequest])>((nil, []))

    static func respond(status: Int, json: String) {
        state.withLock { $0 = (Reply(status: status, body: Data(json.utf8)), []) }
    }

    static func fail(_ code: URLError.Code) {
        state.withLock { $0 = (Reply(status: 0, body: Data(), error: URLError(code)), []) }
    }

    static var requests: [URLRequest] { state.withLock { $0.requests } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var recorded = request
        if recorded.httpBody == nil, let stream = request.httpBodyStream {
            recorded.httpBody = Self.read(stream)
        }
        let reply = Self.state.withLock { s -> Reply? in
            s.requests.append(recorded)
            return s.reply
        }
        guard let reply else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

@Suite("OpenRouterClient", .serialized)
struct OpenRouterClientTests {
    static let okResponse = #"""
    {"id":"gen-1","choices":[{"message":{"role":"assistant","content":"{\"pattern\":\"^a$\",\"template\":null,\"explanation\":\"x\"}"}}]}
    """#

    func client() -> OpenRouterClient {
        OpenRouterClient(apiKey: "sk-or-test", session: StubURLProtocol.session())
    }

    func request() -> LLMRequest {
        LLMRequest(
            model: "anthropic/claude-sonnet-5.5",
            messages: [.system("SYS"), .user("USER")],
            temperature: 0,
            responseSchema: RegexAssistant.responseSchema
        )
    }

    @Test func chatRequestShape() async throws {
        StubURLProtocol.respond(status: 200, json: Self.okResponse)
        let content = try await client().complete(request())
        #expect(content == #"{"pattern":"^a$","template":null,"explanation":"x"}"#)

        let sent = try #require(StubURLProtocol.requests.first)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-test")
        #expect(sent.value(forHTTPHeaderField: "X-Title") == "Air Traffic")
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(sent.timeoutInterval == 30)

        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(sent.httpBody))
        #expect(body["model"] == .string("anthropic/claude-sonnet-5.5"))
        #expect(body["temperature"] == .number(0))
        #expect(body["messages"] == .array([
            .object(["role": .string("system"), "content": .string("SYS")]),
            .object(["role": .string("user"), "content": .string("USER")]),
        ]))
        let format = try #require(body["response_format"])
        #expect(format["type"] == .string("json_schema"))
        #expect(format["json_schema"]?["strict"] == .bool(true))
        #expect(format["json_schema"]?["name"] == .string("regex_suggestion"))
        #expect(format["json_schema"]?["schema"] == RegexAssistant.responseSchema.schema)
        #expect(format["json_schema"]?["schema"]?["additionalProperties"] == .bool(false))
    }

    @Test func requestWithoutSchemaOmitsResponseFormat() throws {
        var r = request()
        r.responseSchema = nil
        let urlRequest = try client().makeChatRequest(r)
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(urlRequest.httpBody))
        #expect(body["response_format"] == nil)
    }

    @Test(arguments: [
        (401, LLMError.unauthorized),
        (402, LLMError.paymentRequired),
        (429, LLMError.rateLimited),
        (500, LLMError.server(status: 500)),
        (503, LLMError.server(status: 503)),
        (400, LLMError.http(status: 400, message: "Ungültiges Modell")),
    ])
    func httpErrorsAreMapped(status: Int, expected: LLMError) async {
        StubURLProtocol.respond(status: status, json: #"{"error":{"code":\#(status),"message":"Ungültiges Modell"}}"#)
        await #expect(throws: expected) { try await client().complete(request()) }
    }

    @Test func errorInsideOKBodyIsMapped() async {
        StubURLProtocol.respond(status: 200, json: #"{"error":{"code":402,"message":"Insufficient credits"}}"#)
        await #expect(throws: LLMError.paymentRequired) { try await client().complete(request()) }
    }

    @Test func networkAndTimeout() async {
        StubURLProtocol.fail(.timedOut)
        await #expect(throws: LLMError.timeout) { try await client().complete(request()) }
        StubURLProtocol.fail(.notConnectedToInternet)
        await #expect { try await client().complete(request()) } throws: { error in
            if case LLMError.network = error { true } else { false }
        }
    }

    @Test func unparsableOrEmptyResponse() async {
        StubURLProtocol.respond(status: 200, json: "<html>")
        await #expect(throws: LLMError.self) { try await client().complete(request()) }
        StubURLProtocol.respond(status: 200, json: #"{"choices":[{"message":{"content":"  "}}]}"#)
        await #expect(throws: LLMError.invalidResponse("leere Antwort")) { try await client().complete(request()) }
    }

    @Test func checkKeyRequestAndParsing() async throws {
        StubURLProtocol.respond(status: 200, json: #"{"data":{"label":"sk-or-v1-abc...","limit_remaining":12.5,"usage":1}}"#)
        let info = try await client().checkKey()
        #expect(info == OpenRouterClient.KeyInfo(label: "sk-or-v1-abc...", limitRemaining: 12.5))
        let sent = try #require(StubURLProtocol.requests.first)
        #expect(sent.httpMethod == "GET")
        #expect(sent.url?.absoluteString == "https://openrouter.ai/api/v1/key")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-test")

        StubURLProtocol.respond(status: 401, json: #"{"error":{"code":401,"message":"No auth"}}"#)
        await #expect(throws: LLMError.unauthorized) { try await client().checkKey() }
    }

    @Test func endToEndWithAssistant() async throws {
        let content = #"{\"pattern\":\"^https://github\\\\.com/(.*)$\",\"template\":\"https://linear.review/$1\",\"explanation\":\"Host ersetzt.\"}"#
        StubURLProtocol.respond(status: 200, json: #"{"choices":[{"message":{"content":"\#(content)"}}]}"#)
        let turn = try await RegexAssistant(client: client(), model: "m")
            .start(mode: .rewrite, examples: ["https://github.com/a/b/pull/1?x=1#y"], description: "d")
        #expect(turn.validation.results[0].output == "https://linear.review/a/b/pull/1?x=1#y")
        #expect(!turn.repaired)
    }
}
