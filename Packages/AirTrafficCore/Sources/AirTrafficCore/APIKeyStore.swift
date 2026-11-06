import Foundation

/// Ablage des OpenRouter-API-Keys. In der App: Schlüsselbund (Generic Password), in Tests: Fake.
public protocol APIKeyStore: Sendable {
    /// `nil`, wenn kein Key gespeichert ist.
    func readKey() throws -> String?
    /// Existenz prüfen, ohne den Inhalt zu lesen (löst keine Schlüsselbund-Abfrage aus).
    func hasKey() -> Bool
    func saveKey(_ key: String) throws
    func deleteKey() throws
}

public enum APIKeyResolver {
    public static let environmentKey = "OPENROUTER_API_KEY"

    /// `OPENROUTER_API_KEY` (nicht leer), sonst Store; ohne Key → `LLMError.missingAPIKey`.
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        store: (any APIKeyStore)?
    ) throws -> String {
        if let key = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            return key
        }
        if let key = try store?.readKey()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            return key
        }
        throw LLMError.missingAPIKey
    }
}
