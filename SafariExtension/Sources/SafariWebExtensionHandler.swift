import AppKit
import SafariServices
import os

/// Native-Messaging-Gegenstelle der Safari-Erweiterung (SPEC §20.2).
///
/// `background.js` schickt `{ action: "open", url, prompt }`. Der Handler baut daraus
/// `airtraffic://open?url=…&source=com.apple.Safari[&prompt=1]` und öffnet ihn mit
/// `NSWorkspace` – so erscheint in Safari keine Rückfrage „Diese Seite möchte … öffnen“.
/// Nur http/https; alles andere wird verworfen.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private static let log = Logger(subsystem: "de.neoskop.AirTraffic", category: "safari-extension")
    /// Quell-App für die Regeln von Air Traffic.
    private static let source = "com.apple.Safari"

    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]
        let result = Self.handle(message)

        let reply = NSExtensionItem()
        reply.userInfo = [SFExtensionMessageKey: result]
        context.completeRequest(returningItems: [reply], completionHandler: nil)
    }

    private static func handle(_ message: [String: Any]?) -> [String: Any] {
        guard let message, message["action"] as? String == "open" else {
            log.error("Unbekannte Nachricht")
            return ["ok": false, "error": "unknown-action"]
        }
        guard let text = message["url"] as? String, let link = URL(string: text) else {
            log.error("Nachricht ohne gültige URL")
            return ["ok": false, "error": "invalid-url"]
        }
        let prompt = message["prompt"] as? Bool ?? false

        // Über den Parser von Air Traffic zurücklesen: prüft http/https und die Kodierung.
        let target = AirTrafficURL.make(.init(url: link, source: source, prompt: prompt))
        do throws(AirTrafficURL.ParseError) {
            _ = try AirTrafficURL.parse(target)
        } catch {
            log.error("Link verworfen: \(error.description, privacy: .private)")
            return ["ok": false, "error": "unsupported-url"]
        }

        guard NSWorkspace.shared.open(target) else {
            log.error("airtraffic:// ließ sich nicht öffnen – Air Traffic nicht installiert?")
            return ["ok": false, "error": "open-failed"]
        }
        log.info("An Air Traffic übergeben (Auswahl: \(prompt))")
        return ["ok": true]
    }
}
