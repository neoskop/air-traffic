import AirTrafficCore
import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    let chooser: ChooserController
    let opener: Opener
    let intake: LinkIntake
    let updates: UpdateController
    private let notifier = ExternalChangeNotifier()
    private var settingsController: SettingsWindowController?

    var settings: SettingsWindowController {
        if let settingsController { return settingsController }
        let controller = SettingsWindowController(model: model)
        controller.onClose = { [weak self] in self?.updates.windowsDidClose() }
        settingsController = controller
        return controller
    }

    /// Kam seit dem Start ein Link? Dann beim Kaltstart kein Einstellungsfenster.
    private var receivedLink = false

    override init() {
        model = AppModel(store: .makeDefault())
        chooser = ChooserController(model: model)
        opener = Opener(model: model, chooser: chooser)
        intake = LinkIntake(model: model, opener: opener)
        updates = UpdateController(startingUpdater: true)
        super.init()
        // Darstellung aus der Config, bevor das erste Fenster (Auswahl oder Einstellungen) erscheint (§23.1).
        model.appliesAppearance = true
        chooser.opener = opener
        model.updates = updates
        chooser.onClose = { [weak self] in self?.updates.windowsDidClose() }
        updates.isBusy = { [weak self] in
            guard let self else { return false }
            return self.chooser.isShowing || self.settingsController?.window?.isVisible == true
        }
        // Mitteilung bei Änderungen von außen (§26.1); Klick öffnet die erste wartende Regel.
        model.onExternalChange = { [weak self] config in self?.notifier.post(for: config) }
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("Gestartet, Konfiguration: \(self.model.store.fileURL.path, privacy: .public)")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !self.receivedLink else { return }
            self.showSettings()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        receivedLink = true
        intake.receive(urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.flushPendingSave()
    }

    func showSettings() {
        settings.show()
    }

    /// Einstellungen → Regeln mit der Regel aus der Mitteilung bzw. der ersten wartenden.
    func showPendingRule(_ id: UUID?) {
        let target = id.flatMap { model.rule(withID: $0)?.id } ?? model.firstPendingRuleID
        model.ruleQuery = ""
        model.settingsTab = .rules
        if let target { model.selectedRuleID = target }
        showSettings()
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let id = (response.notification.request.content.userInfo[ExternalChangeNotifier.ruleIDKey] as? String)
            .flatMap(UUID.init(uuidString:))
        await MainActor.run { self.showPendingRule(id) }
    }

    /// Auch zeigen, wenn Air Traffic gerade vorne ist.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
