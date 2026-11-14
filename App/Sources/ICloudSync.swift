import AirTrafficCore
import Foundation
import Observation

/// iCloud-Sync der Regeln und geräteunabhängigen Einstellungen über `sync.json` in iCloud Drive.
///
/// Läuft nur in der normal gestarteten App (nie in `--snapshot` oder anderen Debug-Schaltern), nur wenn
/// die Konfiguration gespeichert werden darf und der Sync eingeschaltet ist. Auslöser: App-Start, eigenes
/// Speichern und Übernahme von außen (entprellt), Änderungen im Sync-Ordner, alle 5 Minuten und
/// „Jetzt synchronisieren“. Runden überlappen nie. Alle Zugriffe auf iCloud Drive laufen abseits des
/// Main Threads.
@MainActor
@Observable
final class ICloudSync {
    enum Status: Equatable {
        case off
        /// iCloud Drive (bzw. `AIRTRAFFIC_SYNC_DIR`) fehlt.
        case unavailable
        /// Eingeschaltet, noch keine Runde abgeschlossen.
        case waiting
        case running
        case synced
        case failed(String)
    }

    /// Entprellung nach eigenem Speichern und Änderungen von außen.
    static let debounce: Duration = .seconds(2)
    /// Rückfall, falls eine Ordner-Benachrichtigung ausbleibt.
    static let fallbackInterval: Duration = .seconds(300)
    /// Wartezeiten nach fehlgeschlagener Übernahme (Sicherung oder Speichern): 5 s → 30 s → 5 min.
    static let backoff: [Duration] = [.seconds(5), .seconds(30), .seconds(300)]

    private(set) var status: Status = .off
    private(set) var state: SyncState

    var isEnabled: Bool { state.enabled }
    var lastSyncedAt: Date? { state.lastSyncedAt }
    /// Gerät, das `sync.json` zuletzt geschrieben hat – `nil`, wenn das dieser Mac war.
    var lastChangedOnOtherDevice: SyncDevice? {
        guard let by = state.lastRemoteUpdate?.by, by.deviceID != state.deviceID else { return nil }
        return by
    }

    var canSyncNow: Bool { isEnabled && status != .running && model.persists && !model.isReadOnly }

    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private let fileStore: SyncFileStore
    @ObservationIgnored private let stateStore: SyncStateStore
    @ObservationIgnored private let availabilityRoot: URL
    @ObservationIgnored private var started = false
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var needsAnotherRound = false
    /// Fehlgeschlagene Übernahmen in Folge (für den Backoff).
    @ObservationIgnored private var adoptionFailures = 0
    /// Vor diesem Zeitpunkt startet keine automatische Runde (Backoff); „Jetzt synchronisieren“ gilt sofort.
    @ObservationIgnored private var backoffUntil: ContinuousClock.Instant?
    /// Zählt Ein- und Ausschalten: Eine Runde, die während eines `await` davon überholt wurde, speichert nichts.
    @ObservationIgnored private var generation = 0
    /// Konfliktversionen, die sich in dieser Sitzung nicht auflösen ließen: schon eingemischt, werden
    /// nicht erneut eingemischt und lösen kein Schreiben aus.
    @ObservationIgnored private var unresolvableConflicts = Set<URL>()
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: ConfigFileWatcher?

    init(model: AppModel, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.model = model
        fileStore = SyncFileStore.makeDefault(environment: environment)
        availabilityRoot = SyncFileStore.availabilityRoot(environment: environment)
        stateStore = SyncStateStore(configFileURL: model.store.fileURL)
        do {
            state = try stateStore.load() ?? SyncState()
        } catch {
            // Ohne lesbaren Zustand bleibt der Sync aus; beim Einschalten gilt er als erster Sync.
            Log.sync.error("Sync-Zustand nicht lesbar: \(String(describing: error), privacy: .private)")
            state = SyncState()
        }
        status = state.enabled ? (state.lastSyncedAt == nil ? .waiting : .synced) : .off
    }

    /// Beim App-Start: Zeitgeber und erste Runde, wenn eingeschaltet. Die Ordnerbeobachtung entsteht in
    /// der Runde, nach der Verfügbarkeitsprüfung abseits des Main Threads.
    func start() {
        guard !started else { return }
        started = true
        guard state.enabled else { return }
        activate()
        scheduleSync(after: .zero)
    }

    /// Ausschalten setzt den Zustand bis auf die Geräte-ID zurück; erneutes Einschalten ist ein erster Sync.
    func setEnabled(_ enabled: Bool) {
        guard enabled != state.enabled else { return }
        var next = enabled ? state : state.resetForDisabling()
        next.enabled = enabled
        do {
            try stateStore.save(next)
        } catch {
            status = .failed("Einstellung nicht gespeichert: \(error.localizedDescription)")
            Log.sync.error("Sync-Zustand nicht speicherbar: \(String(describing: error), privacy: .private)")
            return
        }
        state = next
        generation += 1
        resetBackoff()
        Log.sync.info("iCloud-Sync \(enabled ? "eingeschaltet" : "ausgeschaltet", privacy: .public)")
        if enabled {
            status = .waiting
            activate()
            scheduleSync(after: .zero)
        } else {
            deactivate()
            status = .off
        }
    }

    /// „Jetzt synchronisieren“ – auch während eines Backoffs.
    func syncNow() {
        scheduleSync(after: .zero, ignoringBackoff: true)
    }

    /// Anstoß aus dem Model nach Speichern bzw. Übernahme von außen. Eine Änderung von außen, die nicht aus
    /// der eigenen Runde stammt, setzt den Backoff zurück.
    func diskStateChanged(external: Bool) {
        if external, !isRunning { resetBackoff() }
        scheduleSync()
    }

    /// Entprellte Runde; läuft gerade eine, folgt danach eine weitere. Ein laufender Backoff wird dabei
    /// nicht verkürzt (außer mit `ignoringBackoff`).
    func scheduleSync(after requested: Duration = ICloudSync.debounce, ignoringBackoff: Bool = false) {
        guard canRun else { return }
        var delay = requested
        if !ignoringBackoff, let backoffUntil {
            delay = max(delay, backoffUntil - ContinuousClock.now)
        }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            await self?.runRound()
        }
    }

    // MARK: Ablauf

    private var canRun: Bool { started && state.enabled && model.persists && !model.isReadOnly }

    /// Nach einem `await`: Runde gilt noch (nicht aus- oder neu eingeschaltet, Konfiguration beschreibbar).
    private func isCurrent(_ roundGeneration: Int) -> Bool { canRun && roundGeneration == generation }

    private func activate() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: ICloudSync.fallbackInterval)
                guard !Task.isCancelled else { return }
                await self?.runRound()
            }
        }
    }

    private func deactivate() {
        debounceTask?.cancel()
        debounceTask = nil
        timerTask?.cancel()
        timerTask = nil
        watcher?.stop()
        watcher = nil
    }

    /// Sync-Ordner beobachten – erst nach der Verfügbarkeitsprüfung bzw. dem ersten Schreiben; existiert
    /// er noch nicht, beim nächsten Mal erneut versuchen.
    private func armWatcher() {
        guard state.enabled, watcher?.isWatchingDirectory != true else { return }
        watcher?.stop()
        watcher = ConfigFileWatcher(fileURL: fileStore.fileURL) { [weak self] in self?.scheduleSync() }
    }

    /// Eine Runde: ausstehendes Speichern schreiben → `sync.json` abseits des Main Threads lesen → mergen →
    /// lokale Änderungen sichern und sofort speichern → Sync-Zustand schreiben → `sync.json` schreiben.
    /// Beim ersten Sync ohne gelesene Datei wird der Zustand erst nach erfolgreichem Anlegen gespeichert.
    private func runRound() async {
        guard canRun else { return }
        guard !isRunning else {
            needsAnotherRound = true
            return
        }
        isRunning = true
        let roundGeneration = generation
        let statusBefore = status
        var retryAfter: Duration?
        defer {
            isRunning = false
            if !state.enabled {
                status = .off
            } else if status == .running, retryAfter == nil {
                // Abgebrochen (ausgeschaltet, schreibgeschützt): nicht bei „Läuft …“ stehen bleiben.
                status = statusBefore == .running ? .waiting : statusBefore
            }
            // Weitere Runde und Wiederholung angefordert: der größere Verzug gilt (ein Backoff ohnehin,
            // siehe `scheduleSync`).
            let delays = [needsAnotherRound ? ICloudSync.debounce : nil, retryAfter].compactMap { $0 }
            needsAnotherRound = false
            if state.enabled, let delay = delays.max() { scheduleSync(after: delay) }
        }

        let root = availabilityRoot
        let available = await Task.detached(priority: .utility) { SyncFileStore.isAvailable(root: root) }.value
        guard isCurrent(roundGeneration) else { return }
        guard available else {
            status = .unavailable
            return
        }
        armWatcher()
        status = .running

        flushModel()
        let store = fileStore
        let read: (snapshot: SyncFileStore.Snapshot, deviceName: String)
        do {
            // Koordiniertes Lesen kann beim Herunterladen aus iCloud blockieren.
            read = try await Task.detached(priority: .utility) {
                (try store.read(), Host.current().localizedName ?? "Mac")
            }.value
        } catch {
            if isCurrent(roundGeneration) { fail(error) }
            return
        }
        guard isCurrent(roundGeneration) else { return }
        // Änderungen während des Lesens gehören in diese Runde. Wartete schon ein anderer Anstoß
        // (Sync-Ordner, Knopf), folgt nach dieser Runde eine weitere.
        if debounceTask != nil { needsAnotherRound = true }
        flushModel()
        guard isCurrent(roundGeneration) else { return }

        for skipped in read.snapshot.skippedConflicts {
            Log.sync.error("Konfliktversion übersprungen: \(skipped, privacy: .private)")
        }
        let conflicts = read.snapshot.conflicts.filter { !unresolvableConflicts.contains($0.url.standardizedFileURL) }
        let documents = (read.snapshot.document.map { [$0] } ?? []) + conflicts.map(\.document)
        let commit = SyncStateCommit.plan(previous: state, readRemoteDocument: read.snapshot.document != nil)
        let device = SyncDevice(deviceID: state.deviceID, name: read.deviceName)
        let result = SyncEngine.sync(config: model.config, state: state, remote: documents, device: device, now: Date())

        // Grenzen vor allem anderen: Was nicht geschrieben werden darf, wird auch nicht übernommen.
        if result.remoteChanged {
            do {
                _ = try SyncFileStore.encodeForWriting(result.document)
            } catch {
                fail(error)
                return
            }
        }

        if result.localChanged {
            switch model.adoptSynced(result.config, summary: result.summary.text) {
            case .saved:
                break
            case .conflict:
                // Änderung von außen ist jetzt übernommen; Zustand nicht schreiben, entprellt neu mergen.
                // Kein Fehler – der Backoff-Zähler bleibt.
                status = .waiting
                retryAfter = ICloudSync.debounce
                return
            case .failed(let message):
                status = .failed(message)
                let delay = nextBackoff()
                retryAfter = delay
                Log.sync.error("iCloud-Stand nicht übernommen, neuer Versuch in \(String(describing: delay), privacy: .public)")
                return
            }
        }

        var next = result.state
        next.enabled = true
        if commit == .beforeWrite, !saveState(next) { return }

        var written: SyncFileStore.SaveOutcome?
        if result.remoteChanged {
            let document = result.document
            let fingerprint = read.snapshot.fingerprint
            do {
                written = try await Task.detached(priority: .utility) {
                    try store.write(document, ifUnchangedSince: fingerprint)
                }.value
            } catch {
                guard isCurrent(roundGeneration) else { return }
                fail(error)
                return
            }
            // Während des Schreibens aus- oder neu eingeschaltet: keinen veralteten Zustand speichern.
            guard isCurrent(roundGeneration) else { return }
            if written == .conflict {
                // Anderer Mac hat inzwischen geschrieben: gleich noch einmal.
                Log.sync.info("sync.json inzwischen geändert – neue Runde")
                retryAfter = .milliseconds(500)
            }
            armWatcher()
        }
        if commit.commitsAfterWrite(written), !saveState(next) { return }

        // Eingemischte Konfliktversionen auflösen – nach dem Schreiben oder wenn nichts Neues dabei war.
        if !conflicts.isEmpty, written != .conflict {
            await resolve(conflicts)
            guard isCurrent(roundGeneration) else { return }
        }

        resetBackoff()
        Log.sync.info(
            "Sync-Runde fertig: lokal \(result.localChanged ? result.summary.text : "unverändert", privacy: .public), iCloud \(result.remoteChanged ? "geschrieben" : "unverändert", privacy: .public), Regeln: \(result.document.rules.count)"
        )
        status = retryAfter == nil ? .synced : .running
    }

    /// `false` = Fehler (steht im Status).
    private func saveState(_ next: SyncState) -> Bool {
        do {
            try stateStore.save(next)
        } catch {
            fail(error)
            return false
        }
        state = next
        return true
    }

    private func resolve(_ conflicts: [SyncFileStore.ConflictVersion]) async {
        let store = fileStore
        let failure: String? = await Task.detached(priority: .utility) {
            do {
                try store.resolveConflicts(conflicts)
                return nil
            } catch {
                return String(describing: error)
            }
        }.value
        guard let failure else { return }
        // Nicht bei jeder Runde neu versuchen: für diese Sitzung merken, der Inhalt ist eingemischt.
        unresolvableConflicts.formUnion(conflicts.map(\.url.standardizedFileURL))
        Log.sync.error("Konfliktversionen nicht aufgelöst: \(failure, privacy: .private)")
    }

    private func nextBackoff() -> Duration {
        let delay = ICloudSync.backoff[min(adoptionFailures, ICloudSync.backoff.count - 1)]
        adoptionFailures += 1
        backoffUntil = ContinuousClock.now + delay
        return delay
    }

    private func resetBackoff() {
        adoptionFailures = 0
        backoffUntil = nil
    }

    /// Ausstehendes Speichern sofort schreiben; dessen eigener Anstoß entfällt, weil diese Runde ihn abdeckt.
    private func flushModel() {
        model.flushPendingSave()
        debounceTask?.cancel()
        debounceTask = nil
    }

    private func fail(_ error: any Error) {
        let message = SyncFileStore.describe(error)
        status = .failed(message)
        Log.sync.error("iCloud-Sync fehlgeschlagen: \(String(describing: error), privacy: .private)")
    }
}
