import AppKit
import Observation
import Sparkle

/// Sparkle-Updates (SPEC §17): täglich prüfen, automatisch laden und installieren.
///
/// Air Traffic wird selten beendet. Darum wird ein geladenes Update nicht erst beim Beenden
/// installiert, sondern sofort (mit Neustart), sobald weder Chooser noch Einstellungen offen sind –
/// sonst beim nächsten Schließen eines der beiden Fenster.
@MainActor
@Observable
final class UpdateController: NSObject {
    @ObservationIgnored private(set) var controller: SPUStandardUpdaterController!

    /// `true`, solange Chooser oder Einstellungsfenster offen sind (vom AppDelegate gesetzt).
    @ObservationIgnored var isBusy: @MainActor () -> Bool = { false }

    /// Geladenes Update wartet auf ein ruhiges Fenster.
    @ObservationIgnored private var pendingInstall: (() -> Void)?

    // Spiegel der Sparkle-Eigenschaften für SwiftUI.
    private(set) var automaticallyChecks = false
    private(set) var automaticallyDownloads = false
    private(set) var lastCheck: Date?
    private(set) var canCheck = false

    /// `startingUpdater: false` für `--snapshot`: liest nur Einstellungen, prüft nichts.
    init(startingUpdater: Bool) {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        refresh()
    }

    var updater: SPUUpdater { controller.updater }

    func refresh() {
        automaticallyChecks = updater.automaticallyChecksForUpdates
        automaticallyDownloads = updater.automaticallyDownloadsUpdates
        lastCheck = updater.lastUpdateCheckDate
        canCheck = updater.canCheckForUpdates
    }

    func setAutomaticallyChecks(_ value: Bool) {
        updater.automaticallyChecksForUpdates = value
        refresh()
    }

    func setAutomaticallyDownloads(_ value: Bool) {
        updater.automaticallyDownloadsUpdates = value
        refresh()
    }

    /// „Nach Updates suchen …“ (Menü und Einstellungen).
    func checkForUpdates() {
        controller.checkForUpdates(nil)
        refresh()
    }

    /// Nach dem Schließen von Chooser oder Einstellungen aufrufen.
    func windowsDidClose() {
        // Erst nach dem Schließen auswerten (`isVisible` ist in `windowWillClose` noch gesetzt).
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.installIfIdle() }
        }
    }

    private func installIfIdle() {
        guard let install = pendingInstall, !isBusy() else { return }
        pendingInstall = nil
        Log.app.info("Update wird installiert, Air Traffic startet neu")
        install()
    }

    /// Marketing-Version und Build, z. B. „1.4 (7)“.
    static var versionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

extension UpdateController: SPUUpdaterDelegate {
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock: @escaping () -> Void
    ) -> Bool {
        Log.app.info("Update \(item.displayVersionString, privacy: .public) geladen")
        pendingInstall = immediateInstallationBlock
        installIfIdle()
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        refresh()
    }
}

extension UpdateController: @preconcurrency SPUStandardUserDriverDelegate {
    /// Hintergrund-App: Sparkle soll geplante Hinweise dezent zeigen statt Fenster nach vorn zu holen.
    var supportsGentleScheduledUpdateReminders: Bool { true }
}
