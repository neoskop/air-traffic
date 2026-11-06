import Foundation

// MARK: - Nachrichten

public struct ChatMessage: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable {
        case system, user, assistant
    }

    public var role: Role
    public var content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }

    public static func system(_ content: String) -> ChatMessage { ChatMessage(role: .system, content: content) }
    public static func user(_ content: String) -> ChatMessage { ChatMessage(role: .user, content: content) }
    public static func assistant(_ content: String) -> ChatMessage { ChatMessage(role: .assistant, content: content) }
}

/// Minimaler JSON-Wert, damit Schemas `Sendable` bleiben und stabil kodiert werden.
public indirect enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

/// Strukturierte Ausgabe (`response_format` mit `json_schema`, strict).
public struct ResponseSchema: Sendable, Equatable {
    public var name: String
    public var schema: JSONValue

    public init(name: String, schema: JSONValue) {
        self.name = name
        self.schema = schema
    }
}

public struct LLMRequest: Sendable, Equatable {
    public var model: String
    public var messages: [ChatMessage]
    public var temperature: Double
    public var responseSchema: ResponseSchema?

    public init(model: String, messages: [ChatMessage], temperature: Double = 0, responseSchema: ResponseSchema? = nil) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.responseSchema = responseSchema
    }
}

/// Sprachmodell-Anbindung; `OpenRouterClient` in der App, Fakes in Tests.
public protocol LLMClient: Sendable {
    /// Liefert den Text der ersten Antwort. Wirft `LLMError` oder `CancellationError`.
    func complete(_ request: LLMRequest) async throws -> String
}

// MARK: - Fehler

/// Fehler des Assistenten, deutsch beschrieben (§12.4).
public enum LLMError: Error, LocalizedError, Equatable, Sendable {
    case missingAPIKey
    case unauthorized
    case paymentRequired
    case rateLimited
    case server(status: Int)
    case http(status: Int, message: String?)
    case timeout
    case network(String)
    case invalidResponse(String)

    /// Bildet einen HTTP-Status ab; `nil` für 2xx.
    public static func from(status: Int, message: String? = nil) -> LLMError? {
        switch status {
        case 200..<300: nil
        case 401: .unauthorized
        case 402: .paymentRequired
        case 429: .rateLimited
        case 500..<600: .server(status: status)
        default: .http(status: status, message: message)
        }
    }

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Kein OpenRouter-API-Key gespeichert. Bitte unter Einstellungen → Allgemein → KI-Assistent eintragen."
        case .unauthorized: "API-Key ungültig"
        case .paymentRequired: "Kein Guthaben bei OpenRouter"
        case .rateLimited: "Zu viele Anfragen, bitte kurz warten"
        case .server(let status): "OpenRouter-Serverfehler (HTTP \(status)), bitte später erneut versuchen"
        case .http(let status, let message):
            if let message, !message.isEmpty { "OpenRouter-Fehler (HTTP \(status)): \(message)" }
            else { "OpenRouter-Fehler (HTTP \(status))" }
        case .timeout: "Zeitüberschreitung: OpenRouter hat nicht rechtzeitig geantwortet"
        case .network(let detail): "Netzwerkfehler: \(detail)"
        case .invalidResponse(let detail): "Antwort des Modells nicht lesbar: \(detail)"
        }
    }
}
