import AirTrafficCore
import AppKit

/// Führt eine `Decision` aus: App öffnen oder Chooser zeigen.
@MainActor
final class Opener {
    private let model: AppModel
    private let chooser: ChooserController
    /// Dieselbe URL höchstens 3-mal in 5 s automatisch an eine App (§26.9).
    private var loopBrake = LoopBrake()

    init(model: AppModel, chooser: ChooserController) {
        self.model = model
        self.chooser = chooser
    }

    /// `sourceLabel`: Text statt „von ‹Quell-App›“ im Auswahlfenster (z. B. „über airtraffic://-Link“, §26.4).
    func execute(_ decision: Decision, context: LinkContext, sourceLabel: String? = nil) {
        var url = decision.finalURL
        var hint = decision.warnings.first
        // Schleifenschutz (§20.1): Air Traffic öffnet `airtraffic://` nie selbst – auch nicht nach Umschreibungen.
        guard !AirTrafficURL.isAirTrafficURL(url) else {
            Log.opener.error("airtraffic-Link als Ziel verworfen (Schleifenschutz)")
            return
        }
        // `file:` nur, wenn die Original-URL schon `file:` war (§26.2) – zusätzlich zur Prüfung im Rewriter.
        if url.isFileURL, !decision.originalURL.isFileURL {
            Log.opener.error("Umschreibung auf file: verworfen – Original-URL verwendet")
            url = decision.originalURL
            hint = "Umschreibung auf file: verworfen"
        }
        let request = ChooserRequest(
            url: url,
            sourceBundleIdentifier: context.sourceBundleIdentifier,
            sourceLabel: sourceLabel,
            scope: .all,
            hint: hint
        )

        switch decision.action {
        case .open(let app):
            openOrPrompt(url, app: app, request: request)

        case .openFirstRunning(let fallback):
            let browsers = model.effectiveBrowsers
            let target = browsers.first(where: Apps.isRunning) ?? fallback ?? browsers.first
            guard let target else {
                chooser.present(request.with(hint: "Kein Browser konfiguriert."))
                return
            }
            openOrPrompt(url, app: target, request: request)

        case .prompt(let scope):
            var r = request
            r.scope = scope
            chooser.present(r)
        }
    }

    private func openOrPrompt(_ url: URL, app: AppRef, request: ChooserRequest) {
        var target = app
        // Schleifenschutz: Ziel ist Air Traffic selbst → erster Browser.
        if Apps.isSelf(target) {
            guard let first = model.effectiveBrowsers.first else {
                chooser.present(request.with(hint: "Ziel wäre Air Traffic selbst; kein Browser konfiguriert."))
                return
            }
            Log.opener.notice("Schleifenschutz: \(app.displayName, privacy: .public) → \(first.displayName, privacy: .public)")
            target = first
        }
        // Schleifenbremse (§26.9): kreist ein Link zwischen Apps, entscheidet der Nutzer.
        guard loopBrake.allow(url) else {
            Log.opener.warning("Schleifenbremse: Link mehr als 3-mal in 5 s – Auswahlfenster")
            chooser.present(request.with(hint: LoopBrake.hint))
            return
        }
        if !open(url, with: target, activates: true, onFailure: { [chooser] hint in
            chooser.present(request.with(hint: hint))
        }) {
            chooser.present(request.with(hint: "„\(target.displayName)“ wurde nicht gefunden."))
        }
    }

    /// Öffnet die URL mit der App. `false`, wenn die App nicht auffindbar ist.
    ///
    /// Scheitert der Start erst später (Completion von `NSWorkspace.open`), ruft `onFailure` mit einem
    /// Hinweis auf – der Link geht dann nicht verloren, sondern landet im Auswahlfenster (§5, §27 A2).
    @discardableResult
    func open(
        _ url: URL, with app: AppRef, activates: Bool, onFailure: (@MainActor (String) -> Void)? = nil
    ) -> Bool {
        guard !AirTrafficURL.isAirTrafficURL(url) else {
            Log.opener.error("airtraffic-Link als Ziel verworfen (Schleifenschutz)")
            return false
        }
        guard let appURL = Apps.url(for: app), !Apps.isSelf(appURL) else {
            Log.opener.error("App nicht gefunden: \(app.displayName, privacy: .public) (\(app.path, privacy: .public))")
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activates
        Log.opener.info("Öffne \(url.absoluteString, privacy: .private) mit \(appURL.lastPathComponent, privacy: .public)")
        let name = app.displayName
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { _, error in
            guard let error else { return }
            // Fehlermeldungen von LaunchServices können die URL enthalten (§26.7).
            Log.opener.error("Öffnen fehlgeschlagen: \(error.localizedDescription, privacy: .private)")
            Task { @MainActor in onFailure?("„\(name)“ konnte nicht gestartet werden.") }
        }
        return true
    }
}
