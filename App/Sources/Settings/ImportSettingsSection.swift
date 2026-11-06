import AirTrafficCore
import AppKit
import SwiftUI

/// Einstellungen → Allgemein, ganz unten (§25): „Import & Konfiguration“: Choosy-Import, Datei-Pfad + „Im Finder zeigen“, „Air Traffic beenden“.
struct ImportSettingsSection: View {
    @Bindable var model: AppModel
    @State private var preview: ImportPreview?
    @State private var importError: String?
    @State private var choosyAvailable = ChoosyImporter.choosyFilesExist()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(symbol: "square.and.arrow.down", title: "Import & Konfiguration")
            GroupCard {
                if choosyAvailable {
                    GroupRow(label: "Choosy") {
                        Text("Regeln und Browser übernehmen").font(DS.body).foregroundStyle(.secondary)
                        Button("Importieren …", action: runImport)
                    }
                    if let importError {
                        Text(importError)
                            .font(DS.help)
                            .foregroundStyle(DS.red)
                            .textSelection(.enabled)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        Divider().padding(.leading, 12)
                    }
                }
                GroupRow(label: "Datei") {
                    Text(abbreviatedConfigPath)
                        .font(DS.mono)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(model.store.fileURL.path(percentEncoded: false))
                    Button("Im Finder zeigen", action: revealConfig)
                        .help("Konfigurationsordner im Finder zeigen")
                        .fixedSize()
                }
                GroupRow(divider: false) {
                    Button("Air Traffic beenden") { NSApp.terminate(nil) }
                }
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
        .sheet(item: $preview) { preview in
            ImportPreviewView(
                result: preview.result,
                onReplace: { model.applyImport(preview.result, replace: true); self.preview = nil },
                onAppend: { model.applyImport(preview.result, replace: false); self.preview = nil },
                onCancel: { self.preview = nil }
            )
        }
    }

    private var abbreviatedConfigPath: String {
        (model.store.fileURL.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    }

    private func refresh() {
        choosyAvailable = ChoosyImporter.choosyFilesExist()
    }

    private func runImport() {
        importError = nil
        do {
            let result = try ChoosyImporter.importConfig(
                behavioursURL: ChoosyImporter.defaultBehavioursURL,
                preferencesURL: ChoosyImporter.defaultPreferencesURL
            )
            preview = ImportPreview(result: result)
        } catch {
            importError = error.localizedDescription
        }
    }

    private func revealConfig() {
        let file = model.store.fileURL
        if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            let dir = file.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        }
    }
}

struct ImportPreview: Identifiable {
    let id = UUID()
    let result: ImportResult
}

struct ImportPreviewView: View {
    let result: ImportResult
    let onReplace: () -> Void
    let onAppend: () -> Void
    let onCancel: () -> Void

    private var reviewIDs: Set<UUID> { Set(result.rulesNeedingReview.map(\.id)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Aus Choosy importieren").font(.title2.bold())
            Text("\(result.config.rules.count) Regeln, \(result.config.browsers.count) Browser, Standardaktion: \(ActionText.describe(result.config.defaultAction))")
                .foregroundStyle(.secondary)

            List {
                Section("Regeln") {
                    ForEach(result.config.rules) { rule in
                        HStack {
                            Image(systemName: rule.enabled ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(rule.enabled ? .green : .secondary)
                            VStack(alignment: .leading) {
                                Text(rule.name)
                                Text(RuleText.summary(rule)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if reviewIDs.contains(rule.id) {
                                Text("prüfen")
                                    .font(.caption.bold())
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(.orange.opacity(0.25)))
                            }
                        }
                    }
                }
                if !result.config.browsers.isEmpty {
                    Section("Browser") {
                        ForEach(Array(result.config.browsers.enumerated()), id: \.offset) { _, app in
                            Text("\(app.displayName) – \(app.path)")
                        }
                    }
                }
                if !result.report.isEmpty {
                    Section("Hinweise") {
                        ForEach(result.report) { note in
                            VStack(alignment: .leading) {
                                if let name = note.ruleName { Text(name).bold() }
                                Text(note.message).font(.callout).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 280)

            HStack {
                Button("Abbrechen", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Anhängen", action: onAppend)
                Button("Ersetzen", action: onReplace).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 520)
    }
}
