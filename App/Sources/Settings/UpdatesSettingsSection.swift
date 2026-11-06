import SwiftUI

/// Einstellungen → Tab „Updates“ (SPEC §17, §25).
struct UpdatesSettingsSection: View {
    let updates: UpdateController?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(symbol: "arrow.triangle.2.circlepath", title: "Updates")
            GroupCard {
                GroupRow(label: "Version") {
                    Text(UpdateController.versionText)
                        .font(DS.mono)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Spacer()
                }
                switchRow(
                    "Täglich nach Updates suchen",
                    isOn: updates?.automaticallyChecks ?? false,
                    set: { updates?.setAutomaticallyChecks($0) }
                )
                .disabled(updates == nil)
                switchRow(
                    "Updates automatisch installieren",
                    isOn: updates?.automaticallyDownloads ?? false,
                    set: { updates?.setAutomaticallyDownloads($0) }
                )
                .disabled(updates == nil || updates?.automaticallyChecks == false)
                GroupRow(divider: false) {
                    Text(lastCheckText)
                        .font(DS.help)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Jetzt suchen") { updates?.checkForUpdates() }
                        .disabled(updates?.canCheck != true)
                }
            }
        }
        .onAppear { updates?.refresh() }
    }

    private var lastCheckText: String {
        guard let date = updates?.lastCheck else { return "Zuletzt geprüft: noch nie" }
        return "Zuletzt geprüft: \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private func switchRow(_ title: String, isOn: Bool, set: @escaping @MainActor @Sendable (Bool) -> Void) -> some View {
        GroupRow {
            Text(title).font(DS.body)
            Spacer()
            Toggle(title, isOn: Binding(get: { isOn }, set: set))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}
