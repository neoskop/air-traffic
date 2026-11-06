import Foundation

/// OpenRouter Chat Completions (§12.4). Loggt weder Key noch Inhalte.
public struct OpenRouterClient: LLMClient {
    public static let baseURL = URL(string: "https://openrouter.ai/api/v1/")!
    public static let chatCompletionsURL = baseURL.appending(path: "chat/completions")
    public static let keyURL = baseURL.appending(path: "key")
    public static let appTitle = "Air Traffic"
    public static let timeout: TimeInterval = 30

    /// Ergebnis von „Verbindung testen“ (`GET /key`).
    public struct KeyInfo: Sendable, Equatable {
        public var label: String?
        public var limitRemaining: Double?
    }

    private let apiKey: String
    private let session: URLSession

    /// `session` ist für Tests injizierbar (URLProtocol-Stub).
    public init(apiKey: String, session: URLSession? = nil) {
        self.apiKey = apiKey
        self.session = session ?? OpenRouterClient.makeSession()
    }

    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }

    // MARK: Requests

    public func makeChatRequest(_ request: LLMRequest) throws -> URLRequest {
        var urlRequest = baseRequest(url: OpenRouterClient.chatCompletionsURL, method: "POST")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(ChatBody(request))
        return urlRequest
    }

    public func makeKeyRequest() -> URLRequest {
        baseRequest(url: OpenRouterClient.keyURL, method: "GET")
    }

    private func baseRequest(url: URL, method: String) -> URLRequest {
        var urlRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: OpenRouterClient.timeout)
        urlRequest.httpMethod = method
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(OpenRouterClient.appTitle, forHTTPHeaderField: "X-Title")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        return urlRequest
    }

    // MARK: LLMClient

    public func complete(_ request: LLMRequest) async throws -> String {
        let data = try await send(makeChatRequest(request))
        let response: ChatResponse
        do {
            response = try JSONDecoder().decode(ChatResponse.self, from: data)
        } catch {
            throw LLMError.invalidResponse("kein gültiges JSON von OpenRouter")
        }
        if let error = response.error {
            if let code = error.code, let mapped = LLMError.from(status: code, message: error.message) { throw mapped }
            throw LLMError.invalidResponse(error.message ?? "Fehler ohne Beschreibung")
        }
        guard let content = response.choices?.first?.message?.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw LLMError.invalidResponse("leere Antwort")
        }
        return content
    }

    /// „Verbindung testen“: prüft den Key ohne Kosten.
    public func checkKey() async throws -> KeyInfo {
        let data = try await send(makeKeyRequest())
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data), let info = json["data"] else {
            throw LLMError.invalidResponse("unerwartete Antwort von /key")
        }
        var remaining: Double?
        if case .number(let n) = info["limit_remaining"] { remaining = n }
        return KeyInfo(label: info["label"]?.stringValue, limitRemaining: remaining)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .timedOut: throw LLMError.timeout
            default: throw LLMError.network(error.localizedDescription)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LLMError.network(error.localizedDescription)
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse("keine HTTP-Antwort")
        }
        if let error = LLMError.from(status: http.statusCode, message: OpenRouterClient.errorMessage(in: data)) {
            throw error
        }
        return data
    }

    static func errorMessage(in data: Data) -> String? {
        (try? JSONDecoder().decode(ChatResponse.self, from: data))?.error?.message
    }
}

// MARK: - Wire-Format

private struct ChatBody: Encodable {
    struct ResponseFormat: Encodable {
        struct Schema: Encodable {
            let name: String
            let strict: Bool
            let schema: JSONValue
        }

        let type = "json_schema"
        let json_schema: Schema
    }

    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let response_format: ResponseFormat?

    init(_ request: LLMRequest) {
        model = request.model
        messages = request.messages
        temperature = request.temperature
        response_format = request.responseSchema.map {
            ResponseFormat(json_schema: .init(name: $0.name, strict: true, schema: $0.schema))
        }
    }
}

private struct ChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message?
    }

    struct APIError: Decodable {
        let code: Int?
        let message: String?

        private enum CodingKeys: String, CodingKey { case code, message }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // OpenRouter liefert `code` meist als Zahl, gelegentlich als String.
            code = (try? c.decodeIfPresent(Int.self, forKey: .code))
                ?? (try? c.decodeIfPresent(String.self, forKey: .code)).flatMap { $0.flatMap(Int.init) }
            message = try? c.decodeIfPresent(String.self, forKey: .message)
        }
    }

    let choices: [Choice]?
    let error: APIError?
}
