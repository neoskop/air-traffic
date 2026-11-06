import AirTrafficCore
import AppKit
import SwiftUI

/// Einstellungen → Tab „CLI & MCP“ (SPEC §24.7, §25).
struct CommandLineSettingsSection: View {
    /// Symlink-Ort und Helper; Parameter, damit Snapshots und Tests nichts im echten Home anfassen müssen.
    var linkURL = CommandLineInstall.defaultLinkURL()
    var helperURL = CommandLineInstall.helperURL(inApp: Bundle.main.bundleURL)

    @State private var status: CommandLineInstall.Status = .notInstalled
    /// `nil` = noch unbekannt (Login-Shell wird gefragt).
    @State private var onPath: Bool?
    @State private var error: String?
    @State private var copied: String?

    private var helperExists: Bool {
        FileManager.default.isExecutableFile(atPath: helperURL.path(percentEncoded: false))
    }

    private var displayLink: String {
        (linkURL.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(symbol: "terminal", title: "Kommandozeile & KI-Agenten")
            GroupCard {
                if let error {
                    Text(error)
                        .font(DS.help)
                        .foregroundStyle(DS.red)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    Divider().padding(.leading, 12)
                }
                GroupRow(label: "Status") {
                    statusPill
                    Spacer()
                    statusButtons
                }
                if status == .installed, onPath == false {
                    pathHint
                    Divider().padding(.leading, 12)
                }
                commandRow(title: "Claude Code", command: CommandLineInstall.claudeCommand)
                Divider().padding(.leading, 12)
                commandRow(title: "Codex", command: CommandLineInstall.codexCommand)
                Divider().padding(.leading, 12)
                Text("Mit dem Befehl „airtraffic“ und als MCP-Server können KI-Agenten wie Claude Code oder Codex deine Regeln auflisten, URLs prüfen und Regeln anlegen, ändern, umsortieren oder löschen – mit derselben Logik wie diese App. Vor jeder Änderung legt Air Traffic eine Sicherung der Konfiguration an (Ordner „backups“); geänderte Regeln erscheinen hier sofort. Neue Regeln und Änderungen an Umschreibungen oder Aktion wirken erst, wenn du sie im Tab „Regeln“ freigibst.")
                    .font(DS.help)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // PATH kann sich inzwischen geändert haben (z. B. ~/.zprofile ergänzt, §27 A17).
            Task {
                await LoginShell.shared.invalidateCache()
                await refresh()
            }
        }
    }

    // MARK: Status

    @ViewBuilder
    private var statusPill: some View {
        switch status {
        case .installed:
            StatusPill(.ok, "Installiert: \(displayLink)")
        case .notInstalled:
            StatusPill(.neutral, "Nicht installiert")
        case .otherCopy(let destination):
            StatusPill(.warning, "Zeigt auf eine andere App-Kopie")
                .help(destination)
        case .blocked:
            StatusPill(.warning, "\(displayLink) ist belegt")
                .help("An dieser Stelle liegt eine Datei, die nicht von Air Traffic stammt. Sie bleibt unverändert.")
        }
    }

    @ViewBuilder
    private var statusButtons: some View {
        switch status {
        case .installed:
            Button("Entfernen", action: uninstall)
                .help("Löscht nur den Symlink \(displayLink)")
        case .notInstalled:
            Button("Installieren", action: install)
                .disabled(!helperExists)
                .help("Legt den Symlink \(displayLink) an (kein Administrator nötig)")
        case .otherCopy:
            Button("Entfernen", action: uninstall)
            Button("Aktualisieren", action: install)
                .disabled(!helperExists)
                .help("Symlink auf diese App-Kopie umstellen")
        case .blocked:
            EmptyView()
        }
    }

    private var pathHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("~/.local/bin ist nicht im PATH deiner Login-Shell. Diese Zeile in ~/.zshrc ergänzen:", systemImage: "exclamationmark.triangle")
                .font(DS.help)
                .foregroundStyle(DS.orange)
                .fixedSize(horizontal: false, vertical: true)
            commandBlock(CommandLineInstall.pathLine)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Befehle

    private func commandRow(title: String, command: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(DS.body)
            commandBlock(command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func commandBlock(_ command: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(command)
                .font(DS.monoSmall)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: DS.fieldRadius).fill(DS.neutralFill))
            Button(copied == command ? "Kopiert" : "Kopieren") { copy(command) }
                .fixedSize()
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = text
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copied == text { copied = nil }
        }
    }

    // MARK: Aktionen

    private func refresh() async {
        status = CommandLineInstall.status(link: linkURL, helper: helperURL)
        guard status == .installed else { return }
        if let path = await LoginShell.shared.path() {
            onPath = CommandLineInstall.path(path, contains: linkURL.deletingLastPathComponent())
        } else {
            onPath = nil
        }
    }

    private func install() {
        error = nil
        do {
            try CommandLineInstall.install(link: linkURL, helper: helperURL)
        } catch {
            self.error = "Installieren fehlgeschlagen: \(error.localizedDescription)"
        }
        Task { await refresh() }
    }

    private func uninstall() {
        error = nil
        do {
            try CommandLineInstall.uninstall(link: linkURL)
        } catch {
            self.error = "Entfernen fehlgeschlagen: \(error.localizedDescription)"
        }
        Task { await refresh() }
    }
}
