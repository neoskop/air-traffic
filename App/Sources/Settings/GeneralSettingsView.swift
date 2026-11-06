import AirTrafficCore
import AppKit
import SwiftUI

/// Einstellungen → Allgemein (§23.4): Problem-Hinweis · Status · „Wenn keine Regel passt“ ·
/// KI-Assistent · Darstellung · Import & Konfiguration (§25). Safari, CLI & MCP und Updates haben eigene Tabs.
struct GeneralSettingsView: View {
    @Bindable var model: AppModel
    @State private var isDefault = Apps.isAirTrafficDefaultBrowser
    @State private var defaultError: String?

    var body: some View {
        SettingsPage {
            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(DS.help)
                    .foregroundStyle(DS.orange)
                    .textSelection(.enabled)
                    .tintedRow(DS.orange)
            }

            statusCard

            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(symbol: "arrow.right", title: "Wenn keine Regel passt")
                GroupCard {
                    GroupRow(label: "Aktion", divider: false) {
                        ActionEditor(action: $model.config.defaultAction, browsers: model.config.browsers)
                    }
                }
            }

            AssistantSettingsSection(model: model)

            appearanceSection

            ImportSettingsSection(model: model)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    // MARK: Darstellung (§23.1)

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(symbol: "circle.lefthalf.filled", title: "Darstellung")
            GroupCard {
                GroupRow(label: "Modus") {
                    Picker("Darstellung", selection: $model.appearance) {
                        ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                Text("System folgt der Einstellung in macOS.")
                    .font(DS.help)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        }
    }

    // MARK: Status

    private var statusCard: some View {
        PageHeaderCard(
            icon: NSApp.applicationIconImage,
            title: isDefault ? "Air Traffic ist dein Standardbrowser" : "Air Traffic ist nicht Standardbrowser",
            detail: statusDetail
        ) {
            VStack(alignment: .trailing, spacing: 6) {
                if isDefault {
                    StatusPill(.ok, "Standardbrowser")
                } else {
                    Button("Als Standardbrowser festlegen", action: makeDefault)
                        .buttonStyle(.borderedProminent)
                }
                TextLinkButton("Status prüfen", action: refresh)
            }
        } footer: {
            if let defaultError {
                Text(defaultError).font(DS.help).foregroundStyle(DS.red).textSelection(.enabled)
            }
        }
    }

    private var statusDetail: String {
        guard isDefault else { return "Links öffnen direkt im bisherigen Browser – Regeln greifen nicht." }
        let count = model.config.rules.filter(\.enabled).count
        let rules = count == 1 ? "1 Regel" : "\(count) Regeln"
        return "Jeder Link läuft durch \(rules). Ohne Treffer: \(ActionText.describe(model.config.defaultAction))."
    }

    private func refresh() {
        isDefault = Apps.isAirTrafficDefaultBrowser
    }

    /// Nur auf Knopfdruck – macOS fragt selbst nach.
    private func makeDefault() {
        defaultError = nil
        let appURL = Bundle.main.bundleURL
        let workspace = NSWorkspace.shared
        workspace.setDefaultApplication(at: appURL, toOpenURLsWithScheme: "http") { error in
            Task { @MainActor in
                if let error {
                    defaultError = "http: \(error.localizedDescription)"
                    refresh()
                    return
                }
                NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: "https") { error in
                    Task { @MainActor in
                        if let error { defaultError = "https: \(error.localizedDescription)" }
                        refresh()
                    }
                }
            }
        }
    }
}

extension AppAppearance {
    /// Titel im Picker „Darstellung“.
    var title: String {
        switch self {
        case .system: "System"
        case .light: "Hell"
        case .dark: "Dunkel"
        }
    }
}
