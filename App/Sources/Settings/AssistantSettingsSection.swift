import AirTrafficCore
import AppKit
import SwiftUI

/// Einstellungen → Allgemein → „KI-Assistent“ (§12.1, §16.3): Anbieter OpenRouter, Claude-Abo oder ChatGPT-Abo.
struct AssistantSettingsSection: View {
    @Bindable var model: AppModel
    @State private var keyInput = ""
    @State private var status: Status?
    @State private var testing = false
    @State private var searching = false
    @State private var testTask: Task<Void, Never>?

    struct Status: Equatable {
        var message: String
        var isError: Bool
    }

    private var provider: AssistantProvider { model.assistantProvider }
    private var trimmedInput: String { keyInput.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var providerBinding: Binding<AssistantProvider> {
        Binding(
            get: { model.assistantProvider },
            set: { newValue in
                guard newValue != model.assistantProvider else { return }
                testTask?.cancel()
                testing = false
                status = nil
                model.updateAssistant { $0.provider = newValue }
                refreshCLI()
            }
        )
    }

    private func stringBinding(_ keyPath: WritableKeyPath<AssistantSettings, String?>) -> Binding<String> {
        Binding(
            get: { model.config.assistant?[keyPath: keyPath] ?? "" },
            set: { value in model.updateAssistant { $0[keyPath: keyPath] = value } }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(symbol: "sparkles", title: "KI-Assistent", subtitle: "über \(provider.displayName)")
            purposeNote
            GroupCard {
                GroupRow(label: "Anbieter") {
                    Picker("Anbieter", selection: providerBinding) {
                        ForEach(AssistantProvider.allCases) { Text($0.pickerTitle).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                if let cli = provider.cli {
                    cliRows(cli)
                } else {
                    openRouterRows
                }
                if testing || status != nil {
                    GroupRow(label: " ", divider: false) {
                        HStack(spacing: 6) {
                            if testing {
                                ProgressView().controlSize(.small)
                                Text("Teste Verbindung …").font(DS.help).foregroundStyle(.secondary)
                            } else if let status {
                                StatusPill(status.isError ? .error : .ok, status.message, small: true)
                                    .textSelection(.enabled)
                                    .help(status.message)
                            }
                            Spacer()
                        }
                    }
                }
            }
            Text(footnote)
                .font(DS.small)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.top, 2)
        }
        .onAppear {
            model.refreshAssistantKey()
            refreshCLI()
        }
        .onDisappear {
            // Tab-Wechsel bricht den Test ab; die Anzeige darf nicht bei „Teste Verbindung …“ hängen (§27 A5).
            testTask?.cancel()
            testTask = nil
            testing = false
        }
    }

    /// Immer sichtbar: wofür die KI verwendet wird und was gesendet wird (§16.3).
    private var purposeNote: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DS.brand)
                .accessibilityHidden(true)
            (Text("Wofür? ").fontWeight(.semibold)
                + Text("Der KI-Assistent schlägt reguläre Ausdrücke für Bedingungen und Umschreibungen vor – nur, wenn du im Regel-Editor auf ✦ klickst. Gesendet werden dann nur deine Beschreibung und die Beispiel-URLs, nie automatisch."))
                .font(DS.help)
                .fixedSize(horizontal: false, vertical: true)
        }
        .tintedRow(DS.brand)
        .accessibilityElement(children: .combine)
    }

    private var footnote: String {
        switch provider {
        case .openRouter:
            "Beispiel-URLs und Beschreibung werden an OpenRouter gesendet. Der Key liegt nur im Schlüsselbund."
        case .claudeCLI, .codexCLI:
            "Nutzt dein bestehendes Abo über die installierte CLI; es fallen keine API-Kosten an."
        }
    }

    // MARK: OpenRouter

    @ViewBuilder private var openRouterRows: some View {
        GroupRow(label: "API-Key") {
            SecureField(
                "API-Key",
                text: $keyInput,
                prompt: Text(model.hasAssistantKey ? "Gespeichert – zum Ersetzen neu eingeben" : "sk-or-…")
            )
            .labelsHidden()
            .font(DS.body)
            .onSubmit(save)
            .modifier(FieldChrome())
            Button("Sichern", action: save).disabled(trimmedInput.isEmpty)
            Button("Entfernen", action: remove).disabled(!model.hasAssistantKey)
        }
        GroupRow(label: " ") {
            HStack {
                if model.hasAssistantKey {
                    StatusPill(.ok, "Key im Schlüsselbund", symbol: "key", small: true)
                } else {
                    StatusPill(.neutral, "Kein Key gespeichert", symbol: "key", small: true)
                }
                Spacer()
            }
        }
        GroupRow(label: "Modell", divider: testing || status != nil) {
            TextField("Modell", text: stringBinding(\.model), prompt: Text(AssistantSettings.defaultModel))
                .labelsHidden()
                .font(DS.mono)
                .modifier(FieldChrome())
            Button("Verbindung testen", action: testOpenRouter)
                .disabled(testing || (trimmedInput.isEmpty && !model.hasAssistantKey))
        }
    }

    // MARK: Claude Code / Codex

    @ViewBuilder private func cliRows(_ cli: AssistantCLI) -> some View {
        let found = model.cliStatus[cli]
        let configuredPath = model.config.assistant?.path(for: cli)
        GroupRow(label: "Programm") {
            HStack(spacing: 6) {
                if searching && found == nil {
                    ProgressView().controlSize(.small)
                    Text("Suche \(cli.executableName) …").font(DS.help).foregroundStyle(.secondary)
                } else if let url = found?.url {
                    let text = ["Gefunden", abbreviated(url.path(percentEncoded: false)), found?.version]
                        .compactMap { $0 }
                        .joined(separator: " · ")
                    StatusPill(.ok, text, small: true)
                        .truncationMode(.middle)
                        .help(url.path(percentEncoded: false))
                } else if found != nil {
                    StatusPill(.warning, "Nicht gefunden", small: true)
                }
                Spacer(minLength: 0)
                IconButton("arrow.clockwise", help: "Erneut suchen") { refreshCLI(forgetShellPath: true) }
                    .disabled(searching)
            }
        }
        if found != nil, found?.url == nil {
            GroupRow(label: " ") {
                Text(cli.installHint)
                    .font(DS.help)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        if cli == .codex {
            GroupRow(label: " ") {
                Label("Codex darf dabei Dateien lesen (Sandbox nur lesend).", systemImage: "eye")
                    .font(DS.help)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        GroupRow(label: "Pfad", divider: configuredPath.map { cli.accepts(path: $0) } != false) {
            Text(configuredPath.map(abbreviated) ?? "Automatisch suchen")
                .font(configuredPath == nil ? DS.body : DS.mono)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(configuredPath ?? "Konfigurierter Pfad → bekannte Orte → Login-Shell")
            Button("Pfad …") { choosePath(for: cli) }
                .help("\(cli.displayName)-Programm selbst wählen")
            Button("Automatisch") { setPath(nil, for: cli) }
                .disabled(configuredPath == nil)
                .help("Pfad vergessen und automatisch suchen")
        }
        // Nur Dateien namens claude/codex werden gestartet (§26.6); sonst gilt die automatische Suche.
        if let configuredPath, !cli.accepts(path: configuredPath) {
            GroupRow(label: " ") {
                Label(cli.invalidPathHint, systemImage: "exclamationmark.triangle.fill")
                    .font(DS.help)
                    .foregroundStyle(DS.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help("Konfigurierter Pfad wird ignoriert; Air Traffic sucht automatisch.")
            }
        }
        GroupRow(label: "Modell", divider: testing || status != nil) {
            TextField(
                "Modell",
                text: stringBinding(cli == .claude ? \.claudeModel : \.codexModel),
                prompt: Text(cli == .claude ? AssistantSettings.defaultClaudeModel : "Standard der CLI")
            )
            .labelsHidden()
            .font(DS.mono)
            .modifier(FieldChrome())
            Button("Verbindung testen") { testCLI(cli) }
                .disabled(testing || found?.url == nil)
        }
    }

    private func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    /// `forgetShellPath`: „Erneut suchen“ fragt die Login-Shell neu (§27 A17).
    private func refreshCLI(forgetShellPath: Bool = false) {
        guard let cli = model.assistantProvider.cli else { return }
        searching = true
        Task {
            if forgetShellPath { await LoginShell.shared.invalidateCache() }
            await model.refreshCLIStatus(cli)
            searching = false
        }
    }

    private func setPath(_ path: String?, for cli: AssistantCLI) {
        model.updateAssistant { settings in
            switch cli {
            case .claude: settings.claudePath = path
            case .codex: settings.codexPath = path
            }
        }
        status = nil
        refreshCLI()
    }

    private func choosePath(for cli: AssistantCLI) {
        let panel = NSOpenPanel()
        panel.title = "\(cli.displayName) wählen"
        panel.message = "Wähle die Programmdatei „\(cli.executableName)“."
        panel.prompt = "Wählen"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        // Symlinks wie /opt/homebrew/bin/claude nicht auflösen – maßgeblich ist der Dateiname (§26.6).
        panel.resolvesAliases = false
        let current = model.cliStatus[cli]?.url ?? URL(fileURLWithPath: "/opt/homebrew/bin/\(cli.executableName)")
        panel.directoryURL = current.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setPath(url.path(percentEncoded: false), for: cli)
    }

    // MARK: Aktionen

    private func save() {
        guard !trimmedInput.isEmpty else { return }
        do {
            try model.saveAssistantKey(trimmedInput)
            keyInput = ""
            status = Status(message: "Key gesichert", isError: false)
        } catch {
            status = Status(message: error.localizedDescription, isError: true)
        }
    }

    private func remove() {
        do {
            try model.deleteAssistantKey()
            status = Status(message: "Key entfernt", isError: false)
        } catch {
            status = Status(message: error.localizedDescription, isError: true)
        }
    }

    /// `GET /api/v1/key` – mit dem eingegebenen Key, sonst mit dem gespeicherten.
    private func testOpenRouter() {
        let key: String
        do {
            key = trimmedInput.isEmpty ? try APIKeyResolver.resolve(store: model.keyStore) : trimmedInput
        } catch {
            status = Status(message: error.localizedDescription, isError: true)
            return
        }
        runTest {
            let info = try await OpenRouterClient(apiKey: key).checkKey()
            var message = "Verbindung OK"
            if let remaining = info.limitRemaining {
                message += String(format: " – Restguthaben/Limit: %.2f", remaining)
            }
            return message
        }
    }

    /// Mini-Anfrage mit kurzem JSON-Echo über die CLI (§16.3).
    private func testCLI(_ cli: AssistantCLI) {
        let provider = model.assistantProvider
        let client: any LLMClient
        do {
            client = try model.makeLLMClient(for: provider)
        } catch {
            status = Status(message: error.localizedDescription, isError: true)
            return
        }
        let modelName = model.config.assistantModel(for: provider)
        let name = cli.displayName
        runTest {
            let start = ContinuousClock.now
            try await AssistantConnectionCheck.run(client: client, model: modelName)
            let seconds = Double((ContinuousClock.now - start).components.seconds)
            return "Verbindung OK – \(name) antwortet (\(Int(max(seconds, 1))) s)"
        }
    }

    private func runTest(_ operation: @escaping @Sendable () async throws -> String) {
        testTask?.cancel()
        testing = true
        status = nil
        testTask = Task {
            // Auch bei Abbruch und Fehler zurücksetzen – außer ein neuerer Test läuft schon (§27 A5).
            defer { if !Task.isCancelled { testing = false } }
            do {
                let message = try await operation()
                guard !Task.isCancelled else { return }
                status = Status(message: message, isError: false)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                Log.assistant.error("Verbindungstest fehlgeschlagen: \(error.localizedDescription, privacy: .private)")
                status = Status(message: error.localizedDescription, isError: true)
            }
        }
    }
}
