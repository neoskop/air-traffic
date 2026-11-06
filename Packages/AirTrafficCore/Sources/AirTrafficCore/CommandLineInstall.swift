import Foundation

/// Symlink `~/.local/bin/airtraffic` → `<App>/Contents/Helpers/airtraffic` (SPEC §24.7).
/// Ordner und Ziel sind Parameter, damit Tests in einem eigenen Verzeichnis laufen.
public enum CommandLineInstall {
    public static let toolName = "airtraffic"
    /// Pfad des Helpers relativ zum App-Bundle.
    public static let helperRelativePath = "Contents/Helpers/airtraffic"

    /// Befehle zum Einbinden als MCP-Server (zum Kopieren in der App).
    public static let claudeCommand = "claude mcp add --scope user air-traffic -- ~/.local/bin/airtraffic mcp"
    public static let codexCommand = "codex mcp add air-traffic -- ~/.local/bin/airtraffic mcp"
    /// Zeile für `~/.zshrc`, falls `~/.local/bin` nicht im `PATH` ist.
    public static let pathLine = #"export PATH="$HOME/.local/bin:$PATH""#

    public enum Status: Sendable, Equatable {
        case notInstalled
        /// Symlink zeigt auf genau diesen Helper.
        case installed
        /// Symlink zeigt auf eine andere App-Kopie (oder ein verschwundenes Ziel).
        case otherCopy(destination: String)
        /// An der Stelle liegt eine Datei oder ein Ordner, kein Symlink – wird nicht angefasst.
        case blocked
    }

    public enum InstallError: Error, LocalizedError, Equatable {
        case blocked(path: String)
        case helperMissing(path: String)

        public var errorDescription: String? {
            switch self {
            case .blocked(let path): "\(path) ist kein Symlink von Air Traffic und bleibt unverändert."
            case .helperMissing(let path): "Das Kommandozeilen-Tool fehlt im App-Bundle (\(path))."
            }
        }
    }

    /// `~/.local/bin/airtraffic`.
    public static func defaultLinkURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: ".local/bin", directoryHint: .isDirectory).appending(path: toolName)
    }

    public static func helperURL(inApp appURL: URL) -> URL {
        appURL.appending(path: helperRelativePath)
    }

    public static func status(link: URL, helper: URL) -> Status {
        let fm = FileManager.default
        let linkPath = link.path(percentEncoded: false)
        guard let destination = try? fm.destinationOfSymbolicLink(atPath: linkPath) else {
            // Kein Symlink: existiert etwas anderes dort?
            return (try? fm.attributesOfItem(atPath: linkPath)) == nil ? .notInstalled : .blocked
        }
        let absolute = destination.hasPrefix("/")
            ? destination
            : (link.deletingLastPathComponent().path(percentEncoded: false) as NSString).appendingPathComponent(destination)
        return normalized(absolute) == normalized(helper.path(percentEncoded: false))
            ? .installed
            : .otherCopy(destination: absolute)
    }

    /// Legt den Symlink an oder biegt einen bestehenden Symlink um („Aktualisieren“). Kein Admin.
    public static func install(link: URL, helper: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: helper.path(percentEncoded: false)) else {
            throw InstallError.helperMissing(path: helper.path(percentEncoded: false))
        }
        switch status(link: link, helper: helper) {
        case .installed:
            return
        case .blocked:
            throw InstallError.blocked(path: link.path(percentEncoded: false))
        case .otherCopy:
            try fm.removeItem(at: link)
        case .notInstalled:
            break
        }
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: link.path(percentEncoded: false), withDestinationPath: helper.path(percentEncoded: false))
    }

    /// Entfernt nur einen Symlink; Dateien und Ordner bleiben.
    public static func uninstall(link: URL) throws {
        let path = link.path(percentEncoded: false)
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil else {
            if (try? FileManager.default.attributesOfItem(atPath: path)) != nil { throw InstallError.blocked(path: path) }
            return
        }
        try FileManager.default.removeItem(at: link)
    }

    /// Ob `directory` in einem `PATH`-String vorkommt (`~` und `$HOME` aufgelöst, ohne Schrägstrich am Ende).
    public static func path(_ pathVariable: String, contains directory: URL, home: String = NSHomeDirectory()) -> Bool {
        let target = normalized(directory.path(percentEncoded: false))
        return pathVariable.split(separator: ":").contains { entry in
            var item = String(entry)
            if item.hasPrefix("~") { item = home + item.dropFirst() }
            item = item.replacingOccurrences(of: "$HOME", with: home)
            return normalized(item) == target
        }
    }

    private static func normalized(_ path: String) -> String {
        var result = (path as NSString).standardizingPath
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }
}
