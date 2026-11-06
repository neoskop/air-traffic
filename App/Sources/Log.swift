import os

enum Log {
    static let subsystem = "de.neoskop.AirTraffic"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let intake = Logger(subsystem: subsystem, category: "intake")
    static let opener = Logger(subsystem: subsystem, category: "opener")
    static let config = Logger(subsystem: subsystem, category: "config")
    static let chooser = Logger(subsystem: subsystem, category: "chooser")
    /// Nur Fehlerarten – nie Key, Prompt-Inhalt oder URLs.
    static let assistant = Logger(subsystem: subsystem, category: "assistant")
}
