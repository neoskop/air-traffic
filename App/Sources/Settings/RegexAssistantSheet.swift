import AirTrafficCore
import SwiftUI

/// Auftrag an das Sheet: Modus, Vorbelegung und was „Übernehmen“ tut.
struct RegexAssistantRequest: Identifiable {
    let id = UUID()
    let mode: RegexAssistantMode
    /// Untertitel, z. B. „Neue Umschreibung“.
    let context: String
    let examples: [String]
    /// Vorhandenes Muster/Vorlage, das verfeinert werden soll.
    let current: RegexSuggestion?
    let caseSensitive: Bool
    /// Muster, Vorlage (nur Umschreiben), Beispiel-URLs.
    let apply: @MainActor (_ pattern: String, _ template: String?, _ examples: [String]) -> Void
}

/// Sheet „Regex mit KI erstellen“ (§12.3).
struct RegexAssistantSheet: View {
    let request: RegexAssistantRequest
    /// „Anbieter · Modell“ (Anzeige im Kopf, §16.4).
    let subtitle: String
    /// Empfänger für den Datenschutzhinweis, z. B. „Claude Code (Anthropic)“.
    let recipient: String
    let makeAssistant: @MainActor () throws -> RegexAssistant
    @Environment(\.dismiss) private var dismiss
    private enum Editor: Hashable { case examples, description }
    @FocusState private var editorFocus: Editor?
    /// Fokussierte einzeilige Felder (Muster, Vorlage, Verfeinern).
    @State private var focusedFields: Set<String> = []
    private var inputFocused: Bool { editorFocus != nil || !focusedFields.isEmpty }

    @State private var examplesText: String
    @State private var descriptionText = ""
    @State private var refineText = ""

    @State private var pattern = ""
    @State private var template = ""
    @State private var explanation = ""
    /// Antwort war auch nach der Reparaturrunde nicht fehlerfrei.
    @State private var unresolved = false
    @State private var repaired = false
    @State private var conversation: RegexConversation?

    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var isRunning = false
    /// Schon übernommen: ein Doppelklick darf nicht zweimal einfügen (§27 A13).
    @State private var applied = false

    init(
        request: RegexAssistantRequest,
        subtitle: String,
        recipient: String,
        makeAssistant: @escaping @MainActor () throws -> RegexAssistant
    ) {
        self.request = request
        self.subtitle = subtitle
        self.recipient = recipient
        self.makeAssistant = makeAssistant
        _examplesText = State(initialValue: request.examples.joined(separator: "\n"))
    }

    private var isRewrite: Bool { request.mode.isRewrite }
    private var examples: [String] { RegexAssistant.examples(from: examplesText) }
    private var hasResult: Bool { conversation != nil }

    /// Live-Prüfung der (ggf. bearbeiteten) Werte.
    private var validation: RegexValidation {
        RegexAssistant.validate(
            pattern: pattern,
            template: isRewrite ? template : nil,
            caseSensitive: request.caseSensitive,
            mode: request.mode,
            examples: examples
        )
    }

    var body: some View {
        // Prüfung (Regex über alle Beispiele) einmal je Render, für Ergebnis und Fußzeile (§27 A14).
        let validation = hasResult ? validation : nil
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    inputSection
                    if let validation { resultSection(validation) }
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 14)
            }
            footer(validation)
        }
        .frame(width: 640)
        .frame(minHeight: 420, idealHeight: 620, maxHeight: 620)
        .background(DS.textBackground)
        .onDisappear { task?.cancel() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            BrandTile(symbol: "sparkles", size: 34, filled: true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Regex mit KI erstellen").font(.system(size: 15, weight: .semibold))
                Text("\(request.context) · \(subtitle)")
                    .font(DS.help)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 6)
    }

    private func sectionTitle(_ title: String, trailing: String? = nil) -> some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            if let trailing { Text(trailing).font(DS.small).foregroundStyle(.secondary) }
        }
        .padding(.leading, 1)
    }

    // MARK: Eingabe

    @ViewBuilder private var inputSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle("Beispiel-URLs", trailing: "eine pro Zeile")
            DSTextEditor(text: $examplesText, mono: true, minHeight: 56)
                .focused($editorFocus, equals: .examples)
                .accessibilityLabel("Beispiel-URLs, eine pro Zeile")
        }
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle("Beschreibung")
            DSTextEditor(text: $descriptionText, minHeight: 44)
                .focused($editorFocus, equals: .description)
                .accessibilityLabel("Beschreibung")
            Text(isRewrite
                 ? "z. B. „Ersetze github.com durch linear.review, Rest bleibt gleich“"
                 : "z. B. „Nur Pull-Requests auf github.com“")
                .font(DS.small)
                .foregroundStyle(.secondary)
        }
        HStack(spacing: 8) {
            if isRunning {
                ProgressView().controlSize(.small)
                Text("Frage das Modell …").font(DS.help).foregroundStyle(.secondary)
                Button("Abbrechen", action: cancelRequest)
            }
            Spacer()
            Keycap("⌘⏎")
            Button(hasResult ? "Neu erstellen" : "Erstellen", action: create)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isRunning || descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        if let error {
            Label(error, systemImage: "exclamationmark.circle")
                .font(DS.help)
                .foregroundStyle(DS.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .tintedRow(DS.red)
        }
    }

    // MARK: Ergebnis

    @ViewBuilder private func resultSection(_ validation: RegexValidation) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                sectionTitle("Ergebnis")
                if repaired {
                    StatusPill(.neutral, "einmal automatisch nachgebessert", symbol: "wrench.adjustable", small: true)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    fieldLabel("Muster")
                    DSTextField("Muster", text: $pattern, mono: true, isError: !validation.patternCompiles,
                                onFocusChange: trackFocus("pattern"))
                }
                if isRewrite {
                    HStack(spacing: 8) {
                        fieldLabel("Vorlage")
                        DSTextField("Vorlage", text: $template, prompt: "Vorlage mit $1 …", mono: true,
                                    onFocusChange: trackFocus("template"))
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    if !explanation.isEmpty {
                        Text(explanation)
                            .font(DS.help)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if unresolved, !validation.isValid {
                        StatusPill(.warning, "Auch nach Reparatur nicht fehlerfrei – bitte prüfen", small: true)
                    }
                    ForEach(validation.problems.map(\.germanDescription), id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.circle")
                            .font(DS.small)
                            .foregroundStyle(DS.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(validation.hints, id: \.self) { hint in
                        Label(hint, systemImage: "info.circle")
                            .font(DS.small)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 60)

                exampleTable(validation.results)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(DS.controlBackground))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DS.separator, lineWidth: 0.5))
        }

        VStack(alignment: .leading, spacing: 5) {
            sectionTitle("Verfeinern")
            HStack(spacing: 8) {
                DSTextField(
                    "Folgeanweisung",
                    text: $refineText,
                    prompt: "z. B. „Query-Parameter entfernen“",
                    onSubmit: refine,
                    onFocusChange: trackFocus("refine")
                )
                Button("Verfeinern", action: refine)
                    .disabled(isRunning || refineText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func trackFocus(_ name: String) -> (Bool) -> Void {
        { focused in
            if focused { focusedFields.insert(name) } else { focusedFields.remove(name) }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text).font(DS.small).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
    }

    @ViewBuilder private func exampleTable(_ rows: [RegexExampleResult]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                Divider()
                Text("Keine Beispiel-URLs.").font(DS.help).foregroundStyle(.secondary).padding(.vertical, 6)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Divider()
                HStack(alignment: .top, spacing: 8) {
                    ConditionStatus(passed: row.inputIsValidURL && row.matches)
                        .accessibilityLabel(row.matches ? "trifft" : "trifft nicht")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.input).foregroundStyle(.secondary)
                        if isRewrite { rewriteCell(row) } else { conditionCell(row) }
                    }
                    .font(DS.monoSmall)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder private func rewriteCell(_ row: RegexExampleResult) -> some View {
        if !row.inputIsValidURL {
            Text("Beispiel ist keine gültige URL").font(DS.small).foregroundStyle(DS.orange)
        } else if !row.matches {
            Text("trifft nicht – bleibt unverändert").foregroundStyle(.secondary)
        } else if let output = row.output {
            Text("→ \(output)").foregroundStyle(row.outputIsValidURL ? Color.primary : DS.red)
        }
    }

    @ViewBuilder private func conditionCell(_ row: RegexExampleResult) -> some View {
        if !row.inputIsValidURL {
            Text("keine gültige URL").font(DS.small).foregroundStyle(DS.orange)
        } else if row.matches {
            Text("trifft").foregroundStyle(DS.green)
        } else {
            Text("trifft nicht").foregroundStyle(.secondary)
        }
    }

    // MARK: Fußzeile

    private func footer(_ validation: RegexValidation?) -> some View {
        HStack(spacing: 8) {
            Text("Beispiele und Beschreibung gehen an \(recipient).")
                .font(DS.small)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Abbrechen", role: .cancel) {
                task?.cancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button("Übernehmen") {
                guard !applied else { return }
                applied = true
                task?.cancel()
                request.apply(pattern, isRewrite ? template : nil, examples)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            // ⏎ übernimmt nur, solange kein Eingabefeld fokussiert ist (dort bleibt ⏎ Zeilenumbruch/Absenden).
            .keyboardShortcut(inputFocused ? nil : .defaultAction)
            .disabled(applied || isRunning || validation?.patternCompiles != true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(DS.windowBackground)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: Ablauf

    private func create() {
        let examples = examples
        let description = descriptionText
        let mode = request.mode
        let current = request.current
        let caseSensitive = request.caseSensitive
        run { assistant in
            try await assistant.start(mode: mode, examples: examples, description: description, current: current, caseSensitive: caseSensitive)
        }
    }

    private func refine() {
        let instruction = refineText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let conversation, !instruction.isEmpty, !isRunning else { return }
        let examples = examples
        let current = RegexSuggestion(pattern: pattern, template: isRewrite ? template : nil, explanation: explanation)
        run(clearRefine: true) { assistant in
            try await assistant.refine(conversation, instruction: instruction, examples: examples, current: current)
        }
    }

    private func run(
        clearRefine: Bool = false,
        _ operation: @escaping @Sendable (RegexAssistant) async throws -> RegexAssistantTurn
    ) {
        let assistant: RegexAssistant
        do {
            assistant = try makeAssistant()
        } catch {
            self.error = error.localizedDescription
            return
        }
        task?.cancel()
        error = nil
        isRunning = true
        task = Task {
            do {
                let turn = try await operation(assistant)
                guard !Task.isCancelled else { return }
                show(turn)
                if clearRefine { refineText = "" }
            } catch is CancellationError {
                // Abgebrochen – Zustand bleibt.
            } catch {
                guard !Task.isCancelled else { return }
                Log.assistant.error("KI-Anfrage fehlgeschlagen: \(error.localizedDescription, privacy: .private)")
                self.error = error.localizedDescription
            }
            if !Task.isCancelled { isRunning = false }
        }
    }

    private func cancelRequest() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    private func show(_ turn: RegexAssistantTurn) {
        conversation = turn.conversation
        pattern = turn.suggestion.pattern
        template = turn.suggestion.template ?? ""
        explanation = turn.suggestion.explanation
        unresolved = !turn.validation.isValid
        repaired = turn.repaired
    }
}
