import AirTrafficCore
import SwiftUI

/// Einstellungen → Allgemein → „iCloud-Sync“: Schalter, Status und „Jetzt synchronisieren“.
/// `sync == nil` (`--snapshot`): Abschnitt im Zustand „Aus“.
struct ICloudSyncSettingsSection: View {
    let sync: ICloudSync?

    static let helpText = "Synchronisiert Regeln, die Standardaktion, das Safari-Verhalten und die Darstellung. Browserliste und KI-Assistent bleiben auf diesem Mac. Regeln, die auf Freigabe warten, werden erst nach der Freigabe übertragen. Liegt in iCloud Drive – ohne erweiterten Datenschutz für iCloud nicht Ende-zu-Ende-verschlüsselt."

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter
    }()

    private var status: ICloudSync.Status { sync?.status ?? .off }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(symbol: "icloud", title: "iCloud-Sync")
            GroupCard {
                GroupRow {
                    Text("Regeln über iCloud synchronisieren").font(DS.body)
                    Spacer()
                    Toggle(
                        "Regeln über iCloud synchronisieren",
                        isOn: Binding(get: { sync?.isEnabled ?? false }, set: { sync?.setEnabled($0) })
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
                GroupRow(label: "Status") {
                    statusPill
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        if let detail = detail(now: context.date) {
                            Text(detail)
                                .font(DS.help)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    Spacer()
                    TextLinkButton("Jetzt synchronisieren", symbol: "arrow.triangle.2.circlepath") { sync?.syncNow() }
                        .disabled(sync?.canSyncNow != true)
                        .opacity(sync?.canSyncNow == true ? 1 : 0.5)
                        .fixedSize()
                }
                if case .failed(let message) = status {
                    Text(message)
                        .font(DS.help)
                        .foregroundStyle(DS.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    Divider().padding(.leading, 12)
                }
                Text(Self.helpText)
                    .font(DS.help)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        switch status {
        case .off: StatusPill(.neutral, "Aus")
        case .unavailable: StatusPill(.warning, "iCloud Drive nicht verfügbar")
        case .waiting: StatusPill(.neutral, "Wartet …", symbol: "clock")
        case .running: StatusPill(.neutral, "Läuft …", symbol: "arrow.triangle.2.circlepath")
        case .synced: StatusPill(.ok, "Synchronisiert")
        case .failed: StatusPill(.error, "Fehler")
        }
    }

    /// „Zuletzt: vor 2 Minuten · zuletzt geändert auf „MacBook““.
    private func detail(now: Date) -> String? {
        guard let sync, sync.isEnabled else { return nil }
        if status == .unavailable { return "iCloud Drive in den Systemeinstellungen einschalten" }
        guard let last = sync.lastSyncedAt else { return nil }
        var text = "Zuletzt: \(Self.relativeFormatter.localizedString(for: min(last, now), relativeTo: now))"
        if let device = sync.lastChangedOnOtherDevice {
            text += " · zuletzt geändert auf „\(device.name)“"
        }
        return text
    }
}
