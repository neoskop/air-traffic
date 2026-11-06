import AirTrafficCore
import Foundation
import UserNotifications

/// macOS-Mitteilung nach jeder Übernahme einer Änderung von außen (§26.1). Die Berechtigung wird beim
/// ersten Mal angefragt; ohne Berechtigung bleibt es bei der orangen Zeile im Einstellungsfenster.
@MainActor
final class ExternalChangeNotifier {
    nonisolated static let ruleIDKey = "ruleID"
    private static let identifier = "external-change"

    static let title = "Regeln von außen geändert"

    static func body(pendingCount: Int) -> String {
        pendingCount > 0 ? RuleApproval.countText(pendingCount) : "Keine Regel wartet auf Freigabe."
    }

    func post(for config: Config) {
        let pending = RuleApproval.pendingCount(in: config)
        let firstPending = config.rules.first(where: \.isPendingApproval)?.id
        let body = Self.body(pendingCount: pending)
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
            content.title = Self.title
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
