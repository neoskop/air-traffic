// Debug-Schalter: nur im Debug-Build (§26.5); der Release-Build kennt den Befehl nicht.
#if DEBUG
import AirTrafficCore
import AppKit

/// `--decide <url> [--source <bundleID>]`: lädt die Konfiguration, druckt die `Decision`
/// als JSON auf stdout und öffnet nichts. `<url>` darf auch ein `airtraffic://open?…`-Link sein (§20.1). Schreibt keine Konfiguration (auch nicht beim Erststart).
@MainActor
enum DecideCommand {
    static let flag = "--decide"
    static let sourceFlag = "--source"

    static func run(arguments: [String]) -> Int32 {
        guard let urlString = value(after: flag, in: arguments) else {
            printError("Aufruf: \(flag) <url> [\(sourceFlag) <bundleID>]")
            return 64
        }
        guard let url = URL(string: urlString), url.scheme != nil else {
            printError("Ungültige URL: \(urlString)")
            return 65
        }

        let store = ConfigStore.makeDefault()
        let config: Config
        do {
            config = try store.load() ?? AppModel.firstRunConfig()
        } catch {
            printError("Konfiguration \(store.fileURL.path) nicht lesbar: \(error.localizedDescription)")
            return 66
        }

        let context = LinkContext(
            sourceBundleIdentifier: value(after: sourceFlag, in: arguments),
            modifiers: [],
            runningBundleIdentifiers: Apps.runningBundleIdentifiers()
        )
        let decision: Decision
        if AirTrafficURL.isAirTrafficURL(url) {
            // Wie ein eingehender airtraffic://-Link (§20.1); öffnet nichts.
            do throws(AirTrafficURL.ParseError) {
                decision = AirTrafficURL.decide(try AirTrafficURL.parse(url), context: context, config: config)
            } catch {
                printError("airtraffic-Link ignoriert: \(error.description)")
                return 65
            }
        } else {
            decision = RuleEngine.decide(url: url, context: context, config: config)
        }

        do {
            var data = try ConfigStore.makeEncoder().encode(decision)
            data.append(0x0A)
            FileHandle.standardOutput.write(data)
            return 0
        } catch {
            printError("JSON-Fehler: \(error)")
            return 70
        }
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
#endif
