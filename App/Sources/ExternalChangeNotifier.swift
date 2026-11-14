import AirTrafficCore
import Foundation
import UserNotifications

/// macOS-Mitteilung nach jeder Übernahme einer Änderung von außen oder aus iCloud. Die Berechtigung wird
/// beim ersten Mal angefragt; ohne Berechtigung bleibt es bei der orangen Zeile im Einstellungsfenster.
@MainActor
final class ExternalChangeNotifier {
    nonisolated static let ruleIDKey = "ruleID"
    private static let identifier = "external-change"

    static let title = "Regeln von außen geändert"
    static let syncTitle = "Regeln über iCloud aktualisiert"

    static func body(pendingCount: Int) -> String {
        pendingCount > 0 ? RuleApproval.countText(pendingCount) : "Keine Regel wartet auf Freigabe."
    }

    /// Nach iCloud-Sync: Zusammenfassung, dazu wartende Regeln, falls es welche gibt.
    static func syncBody(summary: String, pendingCount: Int) -> String {
        let text = summary.prefix(1).uppercased() + summary.dropFirst()
        return pendingCount > 0 ? "\(text). \(RuleApproval.countText(pendingCount))." : "\(text)."
    }

    /// `syncSummary` gesetzt = Änderung kam über iCloud.
    func post(for config: Config, syncSummary: String? = nil) {
        let pending = RuleApproval.pendingCount(in: config)
        let firstPending = config.rules.first(where: \.isPendingApproval)?.id
        let title = syncSummary == nil ? Self.title : Self.syncTitle
        let body = syncSummary.map { Self.syncBody(summary: $0, pendingCount: pending) } ?? Self.body(pendingCount: pending)
        Task {
            let center = UNUserNotificationCenter.current()
            let status = await center.notificationSettings().authorizationStatus
            switch status {
            case .notDetermined:
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
                guard granted else {
                    Log.app.info("Mitteilungen nicht erlaubt – nur Hinweis im Einstellungsfenster")
                    return
                }
            case .denied:
                return
            default:
                break
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if let firstPending { content.userInfo = [Self.ruleIDKey: firstPending.uuidString] }
            // Gleiche Kennung: eine neue Mitteilung ersetzt die vorige.
            let request = UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil)
            do {
                try await center.add(request)
            } catch {
                Log.app.error("Mitteilung nicht zugestellt: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
