import Foundation

// Literale und Umwandlungen für `JSONValue` (Agenten-Schnittstelle §24, MCP-Schemata).

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue {
    /// Kodiert einen `Encodable`-Wert (z. B. `Rule`) über `JSONEncoder` in einen `JSONValue`.
    public init(encoding value: some Encodable) throws {
        let data = try JSONEncoder().encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Dekodiert einen `Decodable`-Wert aus diesem JSON.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    /// Ganzzahl, wenn die Zahl ganzzahlig ist.
    public var intValue: Int? {
        if case .number(let n) = self, n.rounded() == n, abs(n) < 1e15 { return Int(n) }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Kurzname des Typs für Fehlermeldungen.
    var typeName: String {
        switch self {
        case .string: "Text"
        case .number: "Zahl"
        case .bool: "Wahrheitswert"
        case .null: "null"
        case .array: "Liste"
        case .object: "Objekt"
        }
    }

    /// Kompakt (eine Zeile, sortierte Schlüssel) oder lesbar eingerückt.
    public func jsonString(pretty: Bool = false) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Parst Text als JSON; `nil` bei ungültigem JSON.
    public static func parse(_ text: String) -> JSONValue? {
        parse(Data(text.utf8))
    }

    public static func parse(_ data: Data) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}
