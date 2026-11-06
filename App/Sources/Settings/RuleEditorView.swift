import AirTrafficCore
import SwiftUI

/// Regel-Editor (SPEC §14, §15.4): Kopf, Ablauf „Wenn → Umschreiben → Öffnen“, Testleiste unten.
struct RuleEditorView: View {
    @Binding var rule: Rule
    @Bindable var model: AppModel
    /// Position in der Gesamtliste (1-basiert).
    let position: Int
    /// „Regel n zeigen“ im Vorrang-Hinweis: diese Regel in der Liste auswählen.
    let onShowRule: (UUID) -> Void
    /// URL-Prüfung aktiv (§22.4): Testleiste nutzt diese URL und die Simulation aus `model`
    /// statt der gespeicherten Test-URL; `rule.testURL` bleibt unverändert.
    var checkURL: URL?
    @State private var assistRequest: RegexAssistantRequest?
    @State private var showKeyHint = false
    @State private var simulatedSource = ""
    @State private var simulatedModifiers: ModifierSet = []
    @State private var editorHeight: CGFloat = 560
    @State private var resultHeight: CGFloat = 20
    /// Stabile Identität je Bedingung/Umschreibung statt Index (Fokus bleibt beim Löschen, §27 A20).
    @State private var conditionIDs: [UUID] = []
    @State private var rewriteIDs: [UUID] = []
    /// Suche nach der KI-CLI vor dem Öffnen des Sheets; ein neuer Klick bricht die alte ab (§27 A13).
    @State private var assistTask: Task<Void, Never>?
    @Environment(\.undoManager) private var undoManager

    init(rule: Binding<Rule>, model: AppModel, position: Int, onShowRule: @escaping (UUID) -> Void, checkURL: URL? = nil) {
        _rule = rule
        self.model = model
        self.position = position
        self.onShowRule = onShowRule
        self.checkURL = checkURL
        let current = rule.wrappedValue
        _conditionIDs = State(initialValue: current.conditions.map { _ in UUID() })
        _rewriteIDs = State(initialValue: current.rewrites.map { _ in UUID() })
    }

    /// Test-URL der Regel (§14.1); leer = nil, damit nichts geschrieben wird.
    private var testURLText: Binding<String> {
        Binding(
            get: { rule.testURL ?? "" },
            set: { rule.testURL = $0.isEmpty ? nil : $0 }
        )
    }

    private var trimmedTestURL: String {
        (rule.testURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Geprüfte URL (§22.4) bzw. gültige Test-URL (mit Schema) oder nil.
    private var testURL: URL? {
        if let checkURL { return checkURL }
        guard !trimmedTestURL.isEmpty, let url = URL(string: trimmedTestURL),
              let scheme = url.scheme, !scheme.isEmpty
        else { return nil }
        return url
    }

    private var testContext: LinkContext {
        if checkURL != nil { return model.ruleCheckContext }
        let id = simulatedSource.trimmingCharacters(in: .whitespaces)
        return LinkContext(sourceBundleIdentifier: id.isEmpty ? nil : id, modifiers: simulatedModifiers)
    }

    /// Im Prüfmodus gilt die Simulation der URL-Prüfung (§22.2), sonst die eigene des Editors.
    private var simulationSource: Binding<String> {
        checkURL == nil ? $simulatedSource : $model.ruleCheckSource
    }

    private var simulationModifiers: Binding<ModifierSet> {
        checkURL == nil ? $simulatedModifiers : $model.ruleCheckModifiers
    }

    var body: some View {
        let result = testURL.map {
            RuleEngine.test(rule: rule, url: $0, context: testContext, config: model.config)
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let pending = rule.pendingChange {
                    PendingApprovalCard(
                        rule: rule,
                        pending: pending,
                        testURL: testURL,
                        onApprove: { model.approveRule(rule.id) },
                        onDiscard: { model.discardPendingChange(rule.id, undoManager: undoManager) }
                    )
                }
                header
                pipeline(result)
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 20)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { testBar(result) }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { editorHeight = $0 }
        .sheet(item: $assistRequest) { request in
            RegexAssistantSheet(
                request: request,
                subtitle: model.assistantSubtitle,
                recipient: model.assistantProvider.recipient,
                makeAssistant: model.makeRegexAssistant
            )
        }
        .onDisappear { assistTask?.cancel() }
        .alert(unavailableTitle, isPresented: $showKeyHint) {
            Button("Zu „Allgemein“") { model.settingsTab = .general }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(unavailableMessage)
        }
    }

    // MARK: Kopf

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            RuleTargetIcon(action: rule.action, size: 40)
            VStack(alignment: .leading, spacing: 1) {
                InlineNameField(text: $rule.name)
                Text(position == 1
                     ? "Regel 1 von \(model.config.rules.count) · wird als erste geprüft"
                     : "Regel \(position) von \(model.config.rules.count)")
                    .font(DS.help)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
            }
            Spacer(minLength: 12)
            Toggle("Aktiv", isOn: $rule.enabled)
                .toggleStyle(.switch)
                .font(DS.body)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Ablauf

    private func pipeline(_ result: RuleTestResult?) -> some View {
        let matched = result?.matches == true
        let nodes: [PipelineNode.State] = if let result {
            [
                result.matches ? .passed : .failed,
                result.matches && !rule.rewrites.isEmpty ? .passed : .idle,
                result.matches ? .passed : .idle,
            ]
        } else {
            [.neutral(1), .neutral(2), .neutral(3)]
        }
        let rail = matched ? DS.green.opacity(0.55) : DS.separator
        return VStack(alignment: .leading, spacing: 12) {
            PipelineRow(node: nodes[0], railBelow: rail) { conditionsCard(result) }
            PipelineRow(node: nodes[1], railBelow: rail) { rewritesCard(result) }
            PipelineRow(node: nodes[2], railBelow: nil) { actionCard }
        }
    }

    private func conditionsCard(_ result: RuleTestResult?) -> some View {
        StageCard(symbol: "line.3.horizontal.decrease", title: "Wenn", subtitle: "diese Bedingungen zutreffen:") {
            Picker("Passt, wenn", selection: $rule.match) {
                Text("alle").tag(MatchMode.all)
                Text("eine").tag(MatchMode.any)
                Text("keine").tag(MatchMode.none)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("alle / irgendeine / keine Bedingung muss zutreffen")
        } content: {
            let ids = StableIDs.sync(conditionIDs, count: rule.conditions.count)
            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                ConditionRow(
                    condition: .element(of: $rule.conditions, at: index, fallback: .linkType(.web)),
                    testResult: result.flatMap {
                        $0.conditionResults.indices.contains(index) ? $0.conditionResults[index] : nil
                    },
                    onDelete: { removeCondition(id) },
                    onAssist: { target, match in assistCondition(at: index, target: target, match: match) }
                )
                Divider()
            }
            .onChange(of: ids) { conditionIDs = ids }
            if rule.conditions.isEmpty {
                Text("Ohne Bedingungen passt die Regel immer.")
                    .font(DS.help)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            TextLinkButton("Bedingung", symbol: "plus") {
                conditionIDs = StableIDs.sync(conditionIDs, count: rule.conditions.count) + [UUID()]
                rule.conditions.append(.host(TextMatch(op: .equals, value: "")))
            }
            .padding(.top, 8)
            .help("Bedingung hinzufügen")
        }
    }

    private var rewriteSubtitle: String {
        switch rule.rewrites.count {
        case 0: "keine – URL bleibt unverändert"
        case 1: "1 Schritt"
        case let n: "\(n) Schritte, nacheinander"
        }
    }

    private func rewritesCard(_ result: RuleTestResult?) -> some View {
        StageCard(symbol: "wand.and.rays", title: "Umschreiben", subtitle: rewriteSubtitle) {
            Button { assistRewrite(at: nil) } label: {
                Label("Neue mit KI …", systemImage: "sparkles")
            }
            .help("Neue Umschreibung mit KI beschreiben")
        } content: {
            let ids = StableIDs.sync(rewriteIDs, count: rule.rewrites.count)
            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                RewriteRow(
                    rewrite: .element(of: $rule.rewrites, at: index, fallback: Rewrite(pattern: "", template: "")),
                    number: rule.rewrites.count > 1 ? index + 1 : nil,
                    step: result.flatMap { rewriteStep($0, at: index) },
                    onDelete: { removeRewrite(id) },
                    onAssist: { assistRewrite(at: index) }
                )
            }
            .onChange(of: ids) { rewriteIDs = ids }
            TextLinkButton("Umschreibung", symbol: "plus") {
                rewriteIDs = StableIDs.sync(rewriteIDs, count: rule.rewrites.count) + [UUID()]
                rule.rewrites.append(Rewrite(pattern: "^(.*)$", template: "$1"))
            }
            .padding(.top, 8)
            .help("Umschreibung hinzufügen")
            Text("Regulärer Ausdruck auf die gesamte URL; in der Vorlage stehen $1, $2 … für Gruppen. Umschreibungen laufen nacheinander.")
                .font(DS.small)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
    }

    private var actionCard: some View {
        StageCard(symbol: "arrow.up.forward.app", title: "Öffnen") {
            ActionEditor(action: $rule.action, browsers: model.config.browsers)
        } content: {
            EmptyView()
        }
    }

    // MARK: Testleiste

    private func testBar(_ result: RuleTestResult?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Label("Test", systemImage: "flask")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                    .frame(width: 52, alignment: .leading)
                if let checkURL {
                    checkURLField(checkURL)
                } else {
                    DSTextField("Test-URL", text: testURLText, prompt: "https://…", mono: true)
                }
                SimulationButton(source: simulationSource, modifiers: simulationModifiers)
            }
            if let checkURL {
                saveCheckURLRow(checkURL)
            }

            ScrollView {
                testResults(result)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { resultHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(resultHeight, max(editorHeight * 0.4 - 40, 40)))
        }
        .padding(.horizontal, 22)
        .padding(.top, 9)
        .padding(.bottom, 10)
        .background(DS.windowBackground)
        .overlay(alignment: .top) { Divider() }
    }

    /// Geprüfte URL statt Eingabefeld (§22.4): nicht editierbar; Pill „aus URL-Prüfung“ in der Zeile darunter.
    private func checkURLField(_ url: URL) -> some View {
        HStack(spacing: 6) {
            Text(url.absoluteString)
                .font(DS.mono)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(url.absoluteString)
        }
        .modifier(FieldChrome())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Test-URL aus URL-Prüfung: \(url.absoluteString)")
    }

    private func saveCheckURLRow(_ url: URL) -> some View {
        let isSaved = trimmedTestURL == url.absoluteString
        return HStack(spacing: 8) {
            StatusPill(.neutral, "aus URL-Prüfung", symbol: "link", small: true)
                .fixedSize()
            Button("Als Test-URL speichern") { rule.testURL = url.absoluteString }
                .controlSize(.small)
                .disabled(isSaved)
                .help(isSaved ? "Ist bereits die Test-URL dieser Regel" : "Geprüfte URL als Test-URL dieser Regel speichern")
        }
        .padding(.leading, 60)
    }

    @ViewBuilder private func testResults(_ result: RuleTestResult?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if let result {
                let shadowRule = result.shadowedBy.flatMap { id in model.rule(withID: id) }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if result.matches {
                        StatusPill(.ok, shadowRule == nil ? "Trifft" : "Diese Regel trifft")
                            .fixedSize()
                        ActionText.opens(rule.action, url: result.finalURL, hypothetical: shadowRule != nil)
                            .font(DS.help)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        StatusPill(.neutral, notMatchedText(result), symbol: "xmark").fixedSize()
                    }
                    if !rule.enabled {
                        StatusPill(.neutral, "Regel ist aus – Test läuft trotzdem").fixedSize()
                    }
                    if rule.isPendingApproval {
                        StatusPill(.warning, "Vorschau – wirkt erst nach Freigabe", symbol: "clock").fixedSize()
                    }
                    Spacer(minLength: 0)
                }
                if let shadowRule, let shadowIndex = model.config.rules.firstIndex(where: { $0.id == shadowRule.id }) {
                    shadowRow(shadowRule, number: shadowIndex + 1)
                }
                ForEach(result.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.circle")
                        .font(DS.help)
                        .foregroundStyle(DS.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .tintedRow(DS.red)
                }
            } else if trimmedTestURL.isEmpty {
                StatusPill(.neutral, "Test-URL eingeben, um die Regel zu prüfen", symbol: nil).fixedSize()
            } else {
                StatusPill(.neutral, "Keine gültige URL", symbol: "exclamationmark.triangle").fixedSize()
            }
        }
        .padding(.leading, 60)
    }

    private func notMatchedText(_ result: RuleTestResult) -> String {
        guard rule.match == .all, let index = result.conditionResults.firstIndex(of: false),
              rule.conditions.indices.contains(index)
        else { return "Trifft nicht" }
        return "Trifft nicht · Bedingung \(index + 1) (\(RuleText.fieldName(rule.conditions[index]))) nicht erfüllt"
    }

    private func actionPhrase(_ action: Action) -> String {
        switch action {
        case .open(let app): "öffnet \(app.displayName)"
        case .openFirstRunning: "öffnet den ersten laufenden Browser"
        case .prompt: "zeigt die Auswahl"
        }
    }

    private func shadowRow(_ other: Rule, number: Int) -> some View {
        let name = other.name.isEmpty ? "Ohne Namen" : other.name
        let emphasized = Text("„\(name)“ (Regel \(number))").fontWeight(.semibold)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .semibold))
                .accessibilityHidden(true)
            // Wirksamer Stand: bei wartender Änderung die freigegebene Aktion (§26.1).
            Text("Bei einem echten Klick greift zuerst \(emphasized) und \(actionPhrase((other.effective ?? other).action)). Diese Regel wird für diese URL nie erreicht.")
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button("Regel \(number) zeigen") { onShowRule(other.id) }
                .foregroundStyle(.primary)
                .fixedSize()
        }
        .font(DS.help)
        .foregroundStyle(DS.orange)
        .tintedRow(DS.orange)
        .accessibilityElement(children: .combine)
    }

    /// Eingabe und Zwischenergebnis der Umschreibung `index` für die Test-URL.
    private func rewriteStep(_ result: RuleTestResult, at index: Int) -> RewriteStep? {
        guard result.rewriteSteps.indices.contains(index) else { return nil }
        let input = index == 0 ? (testURL?.absoluteString ?? "") : result.rewriteSteps[index - 1]
        return RewriteStep(input: input, output: result.rewriteSteps[index])
    }

    /// Entfernt genau die Zeile mit dieser Identität (§27 A20).
    private func removeCondition(_ id: UUID) {
        let ids = StableIDs.sync(conditionIDs, count: rule.conditions.count)
        guard let index = ids.firstIndex(of: id), rule.conditions.indices.contains(index) else { return }
        conditionIDs = ids.filter { $0 != id }
        rule.conditions.remove(at: index)
    }

    private func removeRewrite(_ id: UUID) {
        let ids = StableIDs.sync(rewriteIDs, count: rule.rewrites.count)
        guard let index = ids.firstIndex(of: id), rule.rewrites.indices.contains(index) else { return }
        rewriteIDs = ids.filter { $0 != id }
        rule.rewrites.remove(at: index)
    }

    // MARK: KI-Assistent

    /// Alert ohne Verfügbarkeit nennt den aktiven Anbieter (§16.4).
    private var unavailableTitle: String {
        switch model.assistantProvider {
        case .openRouter: "Kein API-Key für den KI-Assistenten"
        case .claudeCLI, .codexCLI: "\(model.assistantProvider.displayName) nicht gefunden"
        }
    }

    private var unavailableMessage: String {
        switch model.assistantProvider {
        case .openRouter:
            "Trage unter Allgemein → „KI-Assistent“ einen OpenRouter-API-Key ein oder wähle einen anderen Anbieter."
        case .claudeCLI, .codexCLI:
            "Der KI-Assistent nutzt „\(model.assistantProvider.pickerTitle)“, aber die CLI wurde nicht gefunden. "
                + "Unter Allgemein → „KI-Assistent“ kannst du den Pfad wählen oder einen anderen Anbieter einstellen."
        }
    }

    private func openAssistant(_ request: RegexAssistantRequest) {
        assistTask?.cancel()
        assistTask = nil
        model.refreshAssistantKey()
        if model.assistantAvailable {
            assistRequest = request
            return
        }
        // CLI evtl. nur über die Login-Shell auffindbar. Ein weiterer Klick ersetzt diese Suche.
        assistTask = Task {
            await model.refreshAssistantAvailability()
            guard !Task.isCancelled else { return }
            if model.assistantAvailable {
                assistRequest = request
            } else {
                showKeyHint = true
            }
        }
    }

    /// `index == nil` → neue Umschreibung; sonst diese ersetzen/verfeinern.
    ///
    /// Übernahme per Regel-ID und gemerktem Wert der Umschreibung statt festem Index (§27 A13): wurde
    /// die Liste inzwischen geändert, trifft sie dieselbe Umschreibung oder legt eine neue an.
    private func assistRewrite(at index: Int?) {
        let existing = index.flatMap { rule.rewrites.indices.contains($0) ? rule.rewrites[$0] : nil }
        let ruleID = rule.id
        let model = model
        openAssistant(RegexAssistantRequest(
            mode: .rewrite,
            context: index.map { "Umschreibung \($0 + 1) ersetzen oder verfeinern" } ?? "Neue Umschreibung",
            examples: assistantExamples(beforeRewrite: index ?? rule.rewrites.count),
            current: existing.map { RegexSuggestion(pattern: $0.pattern, template: $0.template) },
            caseSensitive: existing?.caseSensitive ?? false,
            apply: { pattern, template, examples in
                let template = template ?? ""
                model.updateRule(ruleID) { rule in
                    if let existing, let target = StableIDs.locate(existing, preferred: index, in: rule.rewrites) {
                        rule.rewrites[target].pattern = pattern
                        rule.rewrites[target].template = template
                    } else {
                        rule.rewrites.append(Rewrite(pattern: pattern, template: template))
                    }
                    Self.adoptTestURL(examples, into: &rule)
                }
            }
        ))
    }

    private func assistCondition(at index: Int, target: RegexTarget, match: TextMatch) {
        guard rule.conditions.indices.contains(index) else { return }
        let original = rule.conditions[index]
        let ruleID = rule.id
        let model = model
        openAssistant(RegexAssistantRequest(
            mode: .condition(target),
            context: "Bedingung \(index + 1): \(target == .url ? "URL" : target == .host ? "Host" : "Pfad") passt auf Regex",
            examples: assistantExamples(beforeRewrite: 0),
            current: match.value.isEmpty ? nil : RegexSuggestion(pattern: match.value, template: nil),
            caseSensitive: match.caseSensitive,
            apply: { pattern, _, examples in
                model.updateRule(ruleID) { rule in
                    guard let target = StableIDs.locate(original, preferred: index, in: rule.conditions) else { return }
                    switch rule.conditions[target] {
                    case .url(var m): m.value = pattern; rule.conditions[target] = .url(m)
                    case .host(var m): m.value = pattern; rule.conditions[target] = .host(m)
                    case .path(var m): m.value = pattern; rule.conditions[target] = .path(m)
                    default: return
                    }
                    Self.adoptTestURL(examples, into: &rule)
                }
            }
        ))
    }

    /// Noch keine Test-URL? Dann die erste Beispiel-URL aus dem Sheet übernehmen.
    private static func adoptTestURL(_ examples: [String], into rule: inout Rule) {
        let current = (rule.testURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard current.isEmpty, let first = examples.first else { return }
        rule.testURL = first
    }

    /// Vorbelegung der Beispiel-URLs im KI-Sheet (§14.1): Test-URL nach den Umschreibungen vor `index`.
    private func assistantExamples(beforeRewrite index: Int) -> [String] {
        // Im Prüfmodus die geprüfte URL – dieselbe, die Bedingungen und Zwischenschritte zeigen.
        let base = checkURL?.absoluteString ?? trimmedTestURL
        guard !base.isEmpty else { return [] }
        var text = base
        for rewrite in rule.rewrites.prefix(index) {
            guard let next = try? Rewriter.apply(rewrite, to: text) else { break }
            text = next
        }
        return [text]
    }
}

// MARK: - Freigabe (§26.1)

/// Orange Karte oben im Editor: Änderung von außen mit Vorher/Nachher, Ergebnis-Vorschau und
/// „Freigeben“/„Verwerfen“. Bearbeiten in der App gibt nicht frei – nur der Knopf.
private struct PendingApprovalCard: View {
    let rule: Rule
    let pending: PendingChange
    let testURL: URL?
    let onApprove: () -> Void
    let onDiscard: () -> Void

    private var previous: Rule? { pending.previous }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Von außen geändert – wartet auf Freigabe")
                        .font(DS.cardTitle)
                    Text("\(pending.reason) · seit \(pending.since.formatted(date: .abbreviated, time: .shortened))")
                        .font(DS.small)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }
            .foregroundStyle(DS.orange)

            Text(previous == nil
                 ? "Diese Regel wurde über die Kommandozeile oder einen KI-Agenten angelegt. Sie gilt erst, wenn du sie freigibst."
                 : "Umschreibungen oder Aktion wurden über die Kommandozeile oder einen KI-Agenten geändert. Bis zur Freigabe gilt der vorherige Stand.")
                .font(DS.help)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    columnTitle("Vorher")
                    columnTitle("Nachher")
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    rowTitle("Umschreiben")
                    rewrites(previous?.rewrites, isNew: previous == nil)
                    rewrites(rule.rewrites, isNew: false)
                        .modifier(ChangedMark(changed: previous?.rewrites != rule.rewrites))
                }
                GridRow {
                    rowTitle("Öffnen")
                    action(previous?.action)
                    action(rule.action)
                        .modifier(ChangedMark(changed: previous?.action != rule.action))
                }
                if let testURL {
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        rowTitle("Test-URL")
                        preview(previous, url: testURL)
                        preview(rule, url: testURL)
                    }
                }
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(previous == nil ? "Verwerfen (Regel löschen)" : "Verwerfen", role: .destructive, action: onDiscard)
                    .help(previous == nil ? "Neue Regel löschen" : "Vorherigen Stand wiederherstellen")
                Button("Freigeben", action: onApprove)
                    // Eigene Fläche statt `.borderedProminent`: weiße Schrift auf hellem Orange hätte im
                    // Dunkelmodus zu wenig Kontrast (§27 A18).
                    .buttonStyle(OrangeProminentButtonStyle())
                    .help("Änderung übernehmen – gilt danach für echte Links")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.cardRadius).fill(DS.orange.opacity(DS.tint)))
        .overlay(RoundedRectangle(cornerRadius: DS.cardRadius).strokeBorder(DS.orange.opacity(0.55), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Von außen geändert – wartet auf Freigabe")
    }

    private func columnTitle(_ text: String) -> some View {
        Text(text).font(DS.small.weight(.semibold)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rowTitle(_ text: String) -> some View {
        Text(text).font(DS.small).foregroundStyle(.secondary).frame(width: 82, alignment: .leading)
    }

    @ViewBuilder private func rewrites(_ list: [Rewrite]?, isNew: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if isNew {
                Text("– (neu angelegt)").font(DS.help).foregroundStyle(.secondary)
            } else if let list, !list.isEmpty {
                ForEach(Array(list.enumerated()), id: \.offset) { _, rewrite in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(rewrite.pattern).font(DS.monoSmall)
                        Text("→ \(rewrite.template)").font(DS.monoSmall).foregroundStyle(.primary)
                    }
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("keine").font(DS.help).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func action(_ action: Action?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if let action {
                Text(ActionText.describe(action)).font(DS.help)
                if let path = Self.appPath(action) {
                    Text(path).font(DS.monoSmall).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } else {
                Text("–").font(DS.help).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func preview(_ rule: Rule?, url: URL) -> some View {
        Group {
            if let rule {
                let output = Rewriter.apply(rule.rewrites, to: url)
                VStack(alignment: .leading, spacing: 2) {
                    ActionText.opens(rule.action, url: output.url)
                    ForEach(output.warnings, id: \.self) { warning in
                        Text(warning).foregroundStyle(DS.red)
                    }
                }
            } else {
                Text("Regel gilt nicht").foregroundStyle(.secondary)
            }
        }
        .font(DS.help)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func appPath(_ action: Action) -> String? {
        switch action {
        case .open(let app): app.path.isEmpty ? app.bundleIdentifier : app.path
        case .openFirstRunning(let fallback?): fallback.path.isEmpty ? fallback.bundleIdentifier : fallback.path
        case .openFirstRunning(nil), .prompt: nil
        }
    }
}

/// Hebt geänderte Werte in der Spalte „Nachher“ hervor.
private struct ChangedMark: ViewModifier {
    let changed: Bool

    func body(content: Content) -> some View {
        content
            .padding(changed ? 4 : 0)
            .background {
                if changed { RoundedRectangle(cornerRadius: 5).fill(DS.orange.opacity(0.12)) }
            }
            .accessibilityHint(changed ? "geändert" : "")
    }
}

// MARK: - Bausteine

/// Zeile im Ablauf: Knoten links, Schiene zur nächsten Stufe, Karte rechts.
private struct PipelineRow<Content: View>: View {
    let node: PipelineNode.State
    let railBelow: Color?
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PipelineNode(state: node).padding(.top, 8)
            content
        }
        .background(alignment: .topLeading) {
            if let railBelow {
                // Von Knotenmitte bis zur Mitte des nächsten Knotens (Zeilenabstand 12).
                Rectangle()
                    .fill(railBelow)
                    .frame(width: 2)
                    .padding(.top, 20)
                    .padding(.bottom, -32)
                    .offset(x: 11)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Regelname als Inline-Textfeld (Titel 20 semibold, feiner Rahmen bei Hover und Fokus).
private struct InlineNameField: View {
    @Binding var text: String
    @FocusState private var focused: Bool
    @State private var hovering = false

    var body: some View {
        TextField("Name", text: $text, prompt: Text("Ohne Namen"))
            .textFieldStyle(.plain)
            .font(DS.title)
            .focused($focused)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: DS.fieldRadius)
                    .fill(focused ? DS.textBackground : (hovering ? DS.neutralFill : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.fieldRadius)
                    .strokeBorder(
                        focused ? Color.accentColor : DS.hairline,
                        lineWidth: focused ? 1 : (hovering ? 0.5 : 0)
                    )
            )
            .onHover { hovering = $0 }
            .accessibilityLabel("Regelname")
    }
}

/// Eingabe und Ergebnis einer Umschreibung für die Test-URL.
private struct RewriteStep {
    let input: String
    let output: String
}

private struct ConditionRow: View {
    @Binding var condition: Condition
    /// Ergebnis für die Test-URL; nil = keine gültige Test-URL.
    let testResult: Bool?
    let onDelete: () -> Void
    let onAssist: (RegexTarget, TextMatch) -> Void

    private enum Kind: Hashable, CaseIterable {
        case url, host, path, sourceApp, modifiers, linkType
    }

    private var kind: Binding<Kind> {
        Binding(
            get: {
                switch condition {
                case .url: .url
                case .host: .host
                case .path: .path
                case .sourceApp: .sourceApp
                case .modifiers: .modifiers
                case .linkType: .linkType
                }
            },
            set: { newKind in
                let text: TextMatch = switch condition {
                case .url(let m), .host(let m), .path(let m): m
                default: TextMatch(op: .equals, value: "")
                }
                switch newKind {
                case .url: condition = .url(text)
                case .host: condition = .host(text)
                case .path: condition = .path(text)
                case .sourceApp: condition = .sourceApp(bundleIdentifier: "", negated: false)
                case .modifiers: condition = .modifiers([.command], negated: false)
                case .linkType: condition = .linkType(.web)
                }
            }
        )
    }

    var body: some View {
        // Einmal je Render statt in Feld und Fehlerzeile getrennt (§27 A14).
        let regexError = regexError
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Picker("Feld", selection: kind) {
                    Text("URL").tag(Kind.url)
                    Text("Host").tag(Kind.host)
                    Text("Pfad").tag(Kind.path)
                    Text("Quell-App").tag(Kind.sourceApp)
                    Text("Modifier").tag(Kind.modifiers)
                    Text("Linktyp").tag(Kind.linkType)
                }
                .labelsHidden()
                .fixedSize()
                .help("Feld")

                operatorPicker

                Spacer(minLength: 0)
                if let testResult { ConditionStatus(passed: testResult) }
            }
            HStack(spacing: 6) {
                valueEditor(isError: regexError != nil)
                tools
            }
            if let error = regexError {
                Text(error).font(DS.small).foregroundStyle(DS.red).textSelection(.enabled)
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder private var operatorPicker: some View {
        switch condition {
        case .url(let m), .host(let m), .path(let m):
            Picker("Operator", selection: textBinding(m, \.op)) {
                ForEach(TextOp.allCases, id: \.self) { Text(RuleText.opName($0)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Operator")
        case .sourceApp(let id, let negated):
            Picker("Operator", selection: Binding(
                get: { negated },
                set: { condition = .sourceApp(bundleIdentifier: id, negated: $0) }
            )) {
                Text("ist").tag(false)
                Text("ist nicht").tag(true)
            }
            .labelsHidden()
            .fixedSize()
        case .modifiers(let set, let negated):
            Picker("Operator", selection: Binding(
                get: { negated },
                set: { condition = .modifiers(set, negated: $0) }
            )) {
                Text("sind genau").tag(false)
                Text("sind nicht genau").tag(true)
            }
            .labelsHidden()
            .fixedSize()
        case .linkType:
            EmptyView()
        }
    }

    @ViewBuilder private func valueEditor(isError: Bool) -> some View {
        switch condition {
        case .url(let m), .host(let m), .path(let m):
            DSTextField("Wert", text: textBinding(m, \.value), mono: true, isError: isError)
        case .sourceApp(let id, let negated):
            SourceAppField(bundleIdentifier: Binding(
                get: { id },
                set: { condition = .sourceApp(bundleIdentifier: $0, negated: negated) }
            ))
        case .modifiers(let set, let negated):
            ModifierToggles(modifiers: Binding(
                get: { set },
                set: { condition = .modifiers($0, negated: negated) }
            ))
            Spacer(minLength: 0)
        case .linkType(let type):
            Picker("Linktyp", selection: Binding(
                get: { type },
                set: { condition = .linkType($0) }
            )) {
                Text("Web (http/https)").tag(LinkType.web)
                Text("Datei").tag(LinkType.file)
            }
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var tools: some View {
        switch condition {
        case .url(let m), .host(let m), .path(let m):
            AaToggle(isOn: textBinding(m, \.caseSensitive))
            if m.op == .regex {
                IconButton("sparkles", help: "Regex mit KI erstellen", tint: DS.brand) { onAssist(regexTarget, m) }
            }
        default:
            EmptyView()
        }
        IconButton("minus", help: "Bedingung entfernen", action: onDelete)
    }

    private var regexTarget: RegexTarget {
        switch condition {
        case .host: .host
        case .path: .path
        default: .url
        }
    }

    private var regexError: String? {
        switch condition {
        case .url(let m), .host(let m), .path(let m):
            guard m.op == .regex else { return nil }
            return Rewriter.validationError(for: Rewrite(pattern: m.value, template: "", caseSensitive: m.caseSensitive))
                .map { "Ungültiger regulärer Ausdruck: \($0)" }
        default:
            return nil
        }
    }

    private func textBinding<T>(_ current: TextMatch, _ keyPath: WritableKeyPath<TextMatch, T>) -> Binding<T> {
        Binding(
            get: { current[keyPath: keyPath] },
            set: { newValue in
                var m = current
                m[keyPath: keyPath] = newValue
                switch condition {
                case .url: condition = .url(m)
                case .host: condition = .host(m)
                case .path: condition = .path(m)
                default: break
                }
            }
        )
    }
}

private struct RewriteRow: View {
    @Binding var rewrite: Rewrite
    /// Schrittnummer (ab 2 Schritten), sonst nil.
    let number: Int?
    /// Zwischenergebnis für die Test-URL; nil = keine gültige Test-URL.
    let step: RewriteStep?
    let onDelete: () -> Void
    let onAssist: () -> Void

    var body: some View {
        // Fehler und Regex einmal je Render (§27 A14); der Regex kommt aus dem Cache des Core.
        let error = Rewriter.validationError(for: rewrite)
        let regex = error == nil ? Self.regex(for: rewrite) : nil
        VStack(alignment: .leading, spacing: 0) {
            if let number {
                HStack(spacing: 6) {
                    Text("\(number)")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(DS.neutralFill))
                    Text("Schritt \(number)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            HStack(spacing: 8) {
                label("Muster")
                DSTextField("Muster", text: $rewrite.pattern, prompt: "Regex", mono: true, isError: error != nil)
                AaToggle(isOn: $rewrite.caseSensitive)
                IconButton("sparkles", help: "Diesen Schritt mit KI verfeinern", tint: DS.brand, action: onAssist)
                IconButton("minus", help: "Umschreibung entfernen", action: onDelete)
            }
            .padding(.vertical, 5)
            HStack(spacing: 8) {
                label("Vorlage")
                DSTextField("Vorlage", text: $rewrite.template, prompt: "Vorlage mit $1 …", mono: true)
                Color.clear.frame(width: 24 + 22 + 22 + 16, height: 1)
            }
            .padding(.vertical, 5)
            preview(error: error, regex: regex)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(DS.small).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
    }

    @ViewBuilder private func preview(error: String?, regex: NSRegularExpression?) -> some View {
        Group {
            if let error {
                Text("Ungültiger regulärer Ausdruck: \(error)")
                    .font(DS.small)
                    .foregroundStyle(DS.red)
                    .textSelection(.enabled)
            } else if let step {
                let match = regex?.firstMatch(in: step.input, range: NSRange(step.input.startIndex..., in: step.input))
                if match == nil {
                    Text("Muster trifft nicht – URL bleibt unverändert")
                        .font(DS.small)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        groupLegend(captureGroups(match, in: step.input))
                        resultBlock(step)
                        if Rewriter.validURL(step.output) == nil {
                            Text("Ergebnis ist keine gültige URL – es würde die Original-URL verwendet.")
                                .font(DS.small)
                                .foregroundStyle(DS.red)
                        }
                    }
                }
            }
        }
        .padding(.leading, 60)
        .padding(.vertical, 2)
    }

    /// „Gruppen: $1 = … $2 = …“ für den ersten Treffer des Musters.
    @ViewBuilder private func groupLegend(_ groups: [String]) -> some View {
        if !groups.isEmpty {
            FlowLayout(spacing: 6, lineSpacing: 4) {
                Text("Gruppen:").font(DS.small).foregroundStyle(.secondary)
                ForEach(Array(groups.enumerated()), id: \.offset) { index, value in
                    let color = DS.groupColors[index % DS.groupColors.count]
                    Text("$\(index + 1) = \(value)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.14)))
                        .textSelection(.enabled)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private static func regex(for rewrite: Rewrite) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: rewrite.pattern, options: rewrite.caseSensitive ? [] : [.caseInsensitive])
    }

    private func captureGroups(_ match: NSTextCheckingResult?, in input: String) -> [String] {
        guard let match, match.numberOfRanges > 1 else { return [] }
        return (1..<match.numberOfRanges).map { i in
            Range(match.range(at: i), in: input).map { String(input[$0]) } ?? ""
        }
    }

    /// Eingabe (sekundär) und „→ Ausgabe“, geänderter Mittelteil grün hinterlegt; immer vollständig.
    private func resultBlock(_ step: RewriteStep) -> some View {
        var output = AttributedString("→ ")
        if let changed = TextDiff.changedRange(from: step.input, to: step.output) {
            output += AttributedString(String(step.output[..<changed.lowerBound]))
            var middle = AttributedString(String(step.output[changed]))
            middle.backgroundColor = DS.green.opacity(DS.tint)
            middle.foregroundColor = DS.green
            output += middle
            output += AttributedString(String(step.output[changed.upperBound...]))
        } else {
            output += AttributedString(step.output)
        }
        return VStack(alignment: .leading, spacing: 2) {
            Text(step.input).foregroundStyle(.secondary)
            Text(output).foregroundStyle(.primary)
        }
        .font(DS.monoSmall)
        .lineSpacing(2)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(DS.neutralFill))
    }
}

// MARK: - Stabile Zeilen-IDs (§27 A20)

/// Identitäten für Listen ohne eigene ID (Bedingungen, Umschreibungen), solange der Editor lebt.
enum StableIDs {
    /// Passt die Liste an die Anzahl an: fehlende hinten ergänzen, überzählige hinten streichen.
    static func sync(_ ids: [UUID], count: Int) -> [UUID] {
        if ids.count == count { return ids }
        if ids.count > count { return Array(ids.prefix(count)) }
        return ids + (ids.count..<count).map { _ in UUID() }
    }

    /// Index des gemerkten Elements: bevorzugt an `preferred`, sonst das erste gleiche; nil, wenn weg.
    static func locate<Element: Equatable>(_ element: Element, preferred: Int?, in list: [Element]) -> Int? {
        if let preferred, list.indices.contains(preferred), list[preferred] == element { return preferred }
        return list.firstIndex(of: element)
    }
}
