import Foundation

// MARK: - Schutz gegen Spam und Schleifen (SPEC §26.8, §26.9)

/// Höchstens `limit` Ereignisse je `window` Sekunden (gleitendes Fenster).
public struct SlidingWindowLimiter: Sendable {
    public let limit: Int
    public let window: TimeInterval
    private var events: [Date] = []

    public init(limit: Int, window: TimeInterval) {
        self.limit = limit
        self.window = window
    }

    /// `true` = erlaubt (und gezählt); `false` = verwerfen.
    public mutating func allow(at now: Date = Date()) -> Bool {
        events.removeAll { now.timeIntervalSince($0) >= window }
        guard events.count < limit else { return false }
        events.append(now)
        return true
    }

    /// `airtraffic://` mit `prompt=1`: höchstens 3 pro 10 s.
    public static func promptLinks() -> SlidingWindowLimiter {
        SlidingWindowLimiter(limit: 3, window: 10)
    }
}

/// Schleifenbremse (§26.9): dieselbe URL höchstens 3-mal in 5 s an eine App übergeben.
public struct LoopBrake: Sendable {
    public static let hint = "Link kreist zwischen Apps"

    public let limit: Int
    public let window: TimeInterval
    private var history: [String: [Date]] = [:]

    public init(limit: Int = 3, window: TimeInterval = 5) {
        self.limit = limit
        self.window = window
    }

    /// `true` = übergeben (und gezählt); `false` = Auswahlfenster mit Hinweis.
    public mutating func allow(_ url: URL, at now: Date = Date()) -> Bool {
        // Alte Einträge aller URLs aufräumen, damit die Tabelle klein bleibt.
        history = history.compactMapValues { dates in
            let fresh = dates.filter { now.timeIntervalSince($0) < window }
            return fresh.isEmpty ? nil : fresh
        }
        let key = url.absoluteString
        let recent = history[key] ?? []
        guard recent.count < limit else { return false }
        history[key] = recent + [now]
        return true
    }
}

/// Warteschlange des Auswahlfensters (§26.8): höchstens 5 wartende Einträge, identische URLs werden
/// zusammengefasst; läuft sie über, wird verworfen und danach 10 s lang nur noch protokolliert.
public struct ChooserQueuePolicy: Sendable {
    public static let maxQueued = 5
    public static let quietPeriod: TimeInterval = 10

    public enum Verdict: Sendable, Equatable {
        /// Anzeigen bzw. einreihen.
        case accept
        /// Gleiche URL wird schon gezeigt oder wartet.
        case merged
        /// Verworfen; `firstOfBurst` = erster verworfener Eintrag (Log-Warnung).
        case dropped(firstOfBurst: Bool)
    }

    private var quietUntil: Date?

    public init() {}

    public mutating func admit(_ url: URL, showing: URL?, queued: [URL], at now: Date = Date()) -> Verdict {
        if let quietUntil, now < quietUntil { return .dropped(firstOfBurst: false) }
        quietUntil = nil
        if showing == url || queued.contains(url) { return .merged }
        guard queued.count < Self.maxQueued else {
            quietUntil = now.addingTimeInterval(Self.quietPeriod)
            return .dropped(firstOfBurst: true)
        }
        return .accept
    }
}
