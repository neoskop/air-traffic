import AirTrafficCore
import AppKit
import Darwin

/// Absender des aktuellen Apple Events (§26.4).
struct AppleEventSender: Equatable {
    var pid: pid_t?
    var bundleIdentifier: String?
    /// Pfad der ausführbaren Datei (`proc_pidpath`).
    var executablePath: String?

    /// Das Programm liegt in `<eigene App>/Contents/PlugIns/` – also die eigene Safari-Erweiterung.
    var isOwnExtension: Bool {
        guard let executablePath else { return false }
        return AppleEventSender.isInsideOwnPlugIns(executablePath)
    }

    static func isInsideOwnPlugIns(_ path: String, bundlePath: String = Bundle.main.bundlePath) -> Bool {
        let plugIns = (URL(fileURLWithPath: bundlePath).resolvingSymlinksInPath().path(percentEncoded: false) as NSString)
            .appendingPathComponent("Contents/PlugIns") + "/"
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path(percentEncoded: false)
        return resolved.hasPrefix(plugIns)
    }
}

/// Nimmt Links entgegen, erfasst den Kontext und lässt jede URL einzeln entscheiden.
///
/// `decide` läuft im Hintergrund (§26.3); die Reihenfolge eingehender Links bleibt erhalten, weil jede
/// Entscheidung auf die vorherige wartet. Kontext (Quell-App, Modifier) wird sofort beim Eingang erfasst.
@MainActor
final class LinkIntake {
    private let model: AppModel
    private let opener: Opener
    /// Letzte eingereihte Entscheidung; die nächste wartet auf sie.
    private var tail: Task<Void, Never>?
    /// `airtraffic://` mit `prompt=1`: höchstens 3 pro 10 s (§26.8).
    private var promptLimiter = SlidingWindowLimiter.promptLinks()

    /// Hinweis im Auswahlfenster statt „von Safari“, wenn ein `airtraffic://`-Link nicht von der
    /// eigenen Erweiterung kommt (§26.4).
    static let viaLinkLabel = "über airtraffic://-Link"

    init(model: AppModel, opener: Opener) {
        self.model = model
        self.opener = opener
    }

    func receive(_ urls: [URL]) {
        let sender = Self.currentSender()
        let context = Self.captureContext(sender: sender)
        Log.intake.info(
            "\(urls.count) URL(s) von \(context.sourceBundleIdentifier ?? "unbekannt", privacy: .public), PID \(sender.pid.map(String.init) ?? "?", privacy: .public)"
        )
        for url in urls {
            if AirTrafficURL.isAirTrafficURL(url) {
                receiveAirTrafficURL(url, context: context, sender: sender)
                continue
            }
            let config = model.config
            enqueue(context: context, sourceLabel: nil) {
                RuleEngine.decide(url: url, context: context, config: config)
            }
        }
    }

    /// `airtraffic://open?url=…[&source=…][&prompt=1]` (SPEC §20.1), z. B. aus der Safari-Erweiterung.
    private func receiveAirTrafficURL(_ url: URL, context: LinkContext, sender: AppleEventSender) {
        let request: AirTrafficURL.Request
        do throws(AirTrafficURL.ParseError) {
            request = try AirTrafficURL.parse(url)
        } catch {
            // Beschreibung kann URL-Teile enthalten (§26.7).
            Log.intake.error("airtraffic-Link ignoriert: \(error.description, privacy: .private)")
            return
        }
        if request.hasUntrustedSource {
            Log.intake.warning(
                "airtraffic-Link: source „\(request.source ?? "", privacy: .private)“ ignoriert (nur \(AirTrafficURL.Request.trustedSource, privacy: .public)); Quelle = Absender"
            )
        }
        if request.prompt, !promptLimiter.allow() {
            Log.intake.warning("airtraffic-Link mit prompt=1 verworfen: mehr als 3 in 10 s")
            return
        }
        let fromExtension = sender.isOwnExtension
        let linkContext = request.context(from: context)
        Log.intake.info(
            "airtraffic-Link, Quelle \(linkContext.sourceBundleIdentifier ?? "unbekannt", privacy: .public), von der Erweiterung: \(fromExtension), Absender \(sender.bundleIdentifier ?? "?", privacy: .public), Auswahl: \(request.prompt)"
        )
        let config = model.config
        enqueue(context: linkContext, sourceLabel: fromExtension ? nil : Self.viaLinkLabel) {
            AirTrafficURL.decide(request, context: context, config: config)
        }
    }

    /// Entscheidet im Hintergrund und führt danach auf dem Main Actor aus – in Eingangsreihenfolge.
    private func enqueue(
        context: LinkContext,
        sourceLabel: String?,
        decide: @escaping @Sendable () -> Decision
    ) {
        let previous = tail
        tail = Task { [weak self] in
            await previous?.value
            let decision = await Task.detached(priority: .userInitiated, operation: decide).value
            self?.execute(decision, context: context, sourceLabel: sourceLabel)
        }
    }

    private func execute(_ decision: Decision, context: LinkContext, sourceLabel: String?) {
        for warning in decision.warnings {
            // Warnungen enthalten URL-Teile (§26.7).
            Log.intake.warning("\(warning, privacy: .private)")
        }
        opener.execute(decision, context: context, sourceLabel: sourceLabel)
    }

    /// Quell-App (aus dem aktuellen Apple Event), Modifier, laufende Apps.
    static func captureContext(sender: AppleEventSender) -> LinkContext {
        LinkContext(
            sourceBundleIdentifier: sender.bundleIdentifier,
            modifiers: ModifierSet(NSEvent.modifierFlags),
            runningBundleIdentifiers: Apps.runningBundleIdentifiers()
        )
    }

    /// Absender-PID aus dem Apple Event (`keySenderPIDAttr`), dazu Bundle-ID und Programmpfad.
    static func currentSender() -> AppleEventSender {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let descriptor = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))
        else { return AppleEventSender() }
        let pid = pid_t(descriptor.int32Value)
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { return AppleEventSender() }
        return AppleEventSender(
            pid: pid,
            bundleIdentifier: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
            executablePath: executablePath(of: pid)
        )
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
