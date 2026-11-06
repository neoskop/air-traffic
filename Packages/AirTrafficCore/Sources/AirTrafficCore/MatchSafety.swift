import Foundation
import Synchronization

// MARK: - Laufzeit-Schutz beim Regel-Abgleich (SPEC §26.3)

/// Grenzen, damit ein einzelner Link die App nicht blockiert.
public enum MatchLimits {
    /// Längere URLs werden nicht gegen Regeln geprüft (Auswahlfenster mit Hinweis).
    public static let maxURLLength = 8192
    /// Gesamtbudget für alle regulären Ausdrücke eines Links.
    public static let regexBudget: Duration = .milliseconds(500)

    public static let tooLongWarning = "Link zu lang für Regeln"

    /// URL ist zu lang für den Regel-Abgleich.
    public static func isTooLong(_ url: URL) -> Bool {
        url.absoluteString.utf16.count > maxURLLength
    }
}

/// Zeitbudget für Regex-Abgleiche eines Links. Nicht thread-sicher: gilt für einen einzelnen,
/// synchronen Durchlauf (`decide`, `test`, `check`).
public final class MatchBudget {
    private let clock = ContinuousClock()
    private let deadline: ContinuousClock.Instant
    /// Mindestens ein Abgleich wurde wegen der Frist abgebrochen.
    public private(set) var exhausted = false

    public init(_ duration: Duration = MatchLimits.regexBudget) {
        deadline = clock.now.advanced(by: duration)
    }

    var isExpired: Bool { clock.now >= deadline }

    func markExhausted() { exhausted = true }
}

/// Abbruch eines Regex-Abgleichs nach Ablauf des Budgets.
struct MatchTimeout: Error {}

/// Kompilierte reguläre Ausdrücke, gecacht nach Muster und Optionen (§27 K9: LRU statt Komplett-Leeren).
final class RegexCache: Sendable {
    private struct Key: Hashable {
        var pattern: String
        var options: UInt
    }

    private struct Entry {
        var regex: NSRegularExpression
        var lastUse: UInt64
    }

    private struct State {
        var entries: [Key: Entry] = [:]
        var tick: UInt64 = 0
    }

    static let defaultLimit = 512
    /// Gemeinsamer Cache für Engine, Umschreibungen und Editor.
    static let shared = RegexCache(limit: defaultLimit)

    let limit: Int
    private let state = Mutex(State())

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    var count: Int { state.withLock { $0.entries.count } }

    static func regex(_ pattern: String, options: NSRegularExpression.Options) throws -> NSRegularExpression {
        try shared.regex(pattern, options: options)
    }

    func regex(_ pattern: String, options: NSRegularExpression.Options) throws -> NSRegularExpression {
        let key = Key(pattern: pattern, options: options.rawValue)
        let cached: NSRegularExpression? = state.withLock { state in
            guard var entry = state.entries[key] else { return nil }
            state.tick += 1
            entry.lastUse = state.tick
            state.entries[key] = entry
            return entry.regex
        }
        if let cached { return cached }
        let regex = try NSRegularExpression(pattern: pattern, options: options)
        return state.withLock { state in
            // Ein anderer Thread kann denselben Ausdruck inzwischen eingetragen haben.
            if let existing = state.entries[key] { return existing.regex }
            if state.entries.count >= limit,
               let oldest = state.entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
                state.entries.removeValue(forKey: oldest)
            }
            state.tick += 1
            state.entries[key] = Entry(regex: regex, lastUse: state.tick)
            return regex
        }
    }
}

extension NSRegularExpression {
    /// Erster Treffer mit Frist: `.reportProgress` ruft den Block auch während langer Abgleiche auf,
    /// so lässt sich katastrophales Backtracking abbrechen. Wirft `MatchTimeout` nach Fristablauf.
    func firstMatch(in string: String, budget: MatchBudget?) throws -> NSTextCheckingResult? {
        let range = NSRange(string.startIndex..., in: string)
        guard let budget else { return firstMatch(in: string, range: range) }
        if budget.isExpired { budget.markExhausted(); throw MatchTimeout() }
        var found: NSTextCheckingResult?
        var timedOut = false
        enumerateMatches(in: string, options: [.reportProgress], range: range) { result, _, stop in
            if let result {
                found = result
                stop.pointee = true
            } else if budget.isExpired {
                timedOut = true
                stop.pointee = true
            }
        }
        if timedOut, found == nil {
            budget.markExhausted()
            throw MatchTimeout()
        }
        return found
    }

    /// Wie `stringByReplacingMatches(in:range:withTemplate:)`, aber mit Frist.
    func replacingMatches(in string: String, template: String, budget: MatchBudget?) throws -> String {
        let range = NSRange(string.startIndex..., in: string)
        guard let budget else { return stringByReplacingMatches(in: string, range: range, withTemplate: template) }
        if budget.isExpired { budget.markExhausted(); throw MatchTimeout() }
        var matches: [NSTextCheckingResult] = []
        var timedOut = false
        enumerateMatches(in: string, options: [.reportProgress], range: range) { result, _, stop in
            if let result {
                matches.append(result)
            }
            if budget.isExpired {
                timedOut = true
                stop.pointee = true
            }
        }
        if timedOut {
            budget.markExhausted()
            throw MatchTimeout()
        }
        let source = string as NSString
        var output = ""
        var cursor = 0
        for match in matches {
            output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            output += replacementString(for: match, in: string, offset: 0, template: template)
            cursor = match.range.location + match.range.length
        }
        output += source.substring(from: cursor)
        return output
    }
}

// MARK: - Platzhalter ohne Regex

/// `*` und `?` über den ganzen Text, `\` maskiert das nächste Zeichen (wie NSPredicate `LIKE`).
///
/// Linearer Glob-Abgleich ohne Backtracking-Explosion: Bei einem Fehlschlag springt er nur zum
/// letzten `*` zurück (O(n·m) im schlechtesten Fall). Verglichen wird je Unicode-Skalar, wie `.`
/// im bisherigen regulären Ausdruck. Ohne Groß/Klein werden Muster-Literale und Text voll gefaltet
/// (`folding(.caseInsensitive)`, §27 K7): `ß` = `SS`, `ς` = `Σ`, `ﬀ` = `FF` wie im regulären Ausdruck.
/// `?` steht dabei für einen Skalar des gefalteten Texts.
public struct WildcardPattern: Sendable {
    enum Token: Sendable, Equatable {
        case literal(Unicode.Scalar)
        case any
        case star
    }

    let tokens: [Token]
    let caseSensitive: Bool

    public init(_ pattern: String, caseSensitive: Bool) {
        var tokens: [Token] = []
        var literal = String.UnicodeScalarView()
        func flushLiteral() {
            guard !literal.isEmpty else { return }
            let text = String(literal)
            let folded = caseSensitive ? text : Self.fold(text)
            tokens += folded.unicodeScalars.map(Token.literal)
            literal = String.UnicodeScalarView()
        }
        var escaping = false
        for scalar in pattern.unicodeScalars {
            if escaping {
                literal.append(scalar)
                escaping = false
                continue
            }
            switch scalar {
            case "\\": escaping = true
            case "*":
                flushLiteral()
                // Mehrere `*` hintereinander sind gleichbedeutend mit einem.
                if tokens.last != .star { tokens.append(.star) }
            case "?":
                flushLiteral()
                tokens.append(.any)
            default: literal.append(scalar)
            }
        }
        if escaping { literal.append("\\") }
        flushLiteral()
        self.tokens = tokens
        self.caseSensitive = caseSensitive
    }

    public func matches(_ subject: String) -> Bool {
        let subject = Array((caseSensitive ? subject : Self.fold(subject)).unicodeScalars)
        let pattern = tokens

        var t = 0, p = 0
        var starP = -1, starT = 0
        while t < subject.count {
            if p < pattern.count {
                switch pattern[p] {
                case .star:
                    starP = p
                    starT = t
                    p += 1
                    continue
                case .any:
                    t += 1; p += 1
                    continue
                case .literal(let scalar) where scalar == subject[t]:
                    t += 1; p += 1
                    continue
                case .literal:
                    break
                }
            }
            guard starP >= 0 else { return false }
            // Zurück zum letzten `*`, das ein Zeichen mehr schluckt.
            p = starP + 1
            starT += 1
            t = starT
        }
        while p < pattern.count, pattern[p] == .star { p += 1 }
        return p == pattern.count
    }

    /// Volle Groß/Klein-Faltung; reines ASCII ohne Umweg über Foundation.
    static func fold(_ text: String) -> String {
        if text.utf8.allSatisfy({ $0 < 0x80 }) { return text.lowercased() }
        return text.folding(options: .caseInsensitive, locale: nil)
    }
}

// MARK: - Hostnamen (IDN, §27 A4)

/// Unicode- und Punycode-Form eines Hostnamens (`bücher.de` ↔ `xn--bcher-kva.de`).
public enum HostName {
    /// Unicode-Form (zum Anzeigen); unverändert, wenn nicht umwandelbar.
    public static func unicode(_ host: String) -> String {
        guard host.lowercased().contains("xn--"),
              let decoded = URLComponents(string: "https://" + host)?.host, !decoded.isEmpty
        else { return host }
        return decoded
    }

    /// Unicode-Host einer URL (`URL.host` liefert bei IDN die Punycode-Form).
    public static func unicode(_ url: URL) -> String? {
        guard let host = url.host(percentEncoded: false) else { return nil }
        return unicode(host)
    }

    /// ASCII-Form (Punycode); unverändert bei reinem ASCII oder wenn nicht umwandelbar.
    public static func ascii(_ host: String) -> String {
        guard !host.utf8.allSatisfy({ $0 < 0x80 }),
              let encoded = URL(string: "https://" + host)?.host(percentEncoded: false), !encoded.isEmpty
        else { return host }
        return encoded
    }

    /// Anzeigeform gegen Homograph-Spoofing: Unicode nur, wenn alle Nicht-ASCII-Zeichen lateinische
    /// Buchstaben sind (z. B. `bücher.de`); gemischte oder andere Schriften (`аpple.com` mit kyrillischem а)
    /// bleiben Punycode (`xn--pple-43d.com`).
    public static func display(_ host: String) -> String {
        let unicode = unicode(ascii(host))
        let latinOnly = unicode.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0..<0x80: true
            case 0xD7, 0xF7: false  // × ÷
            case 0xC0...0x24F, 0x1E00...0x1EFF: true  // Latin-1, Latin Extended-A/B, Additional
            default: false
            }
        }
        return latinOnly ? unicode : ascii(host)
    }

    /// Beide Formen ohne Duplikat, ASCII zuerst.
    static func forms(_ host: String) -> [String] {
        let ascii = ascii(host)
        let unicode = unicode(ascii)
        return unicode == ascii ? [ascii] : [ascii, unicode]
    }
}
