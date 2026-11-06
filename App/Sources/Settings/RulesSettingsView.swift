import AirTrafficCore
import SwiftUI

/// Tab „Regeln“ (SPEC §13, §15.3, §22): Seitenleiste mit Suche bzw. URL-Prüfung und Liste, rechts der Editor.
///
/// §27 A6/A7: Liste und Editor sind eigene Views; die Zeilen kommen vorab berechnet aus
/// `AppModel.ruleList` (Prüfung und Filter nur bei Änderung neu, kein `if` im `ForEach`).
struct RulesSettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        HStack(spacing: 0) {
            RuleSidebar(model: model, undoManager: undoManager)
                .frame(width: 320)
            Divider()
            RuleEditorHost(model: model, onShowRule: showRule)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DS.textBackground)
        }
    }

    /// „Regel n zeigen“ im Vorrang-Hinweis (§14.2, §22.4): Regel auswählen; ist sie nicht sichtbar,
    /// im Prüfmodus „Alle Regeln“ zeigen, sonst Suche leeren.
    private func showRule(_ id: UUID) {
        if !model.ruleList.contains(id) {
            if model.ruleCheckURL != nil {
                model.ruleCheckShowsAll = true
            } else {
                model.ruleQuery = ""
            }
        }
        model.selectedRuleID = id
    }
}

// MARK: - Editor

/// Rechte Seite: Editor der ausgewählten Regel, gebunden per ID (§27 A1).
private struct RuleEditorHost: View {
    @Bindable var model: AppModel
    let onShowRule: (UUID) -> Void

    var body: some View {
        if let id = model.selectedRuleID, let index = model.ruleIndex(id) {
            RuleEditorView(
                rule: model.ruleBinding(id, fallback: model.config.rules[index]),
                model: model,
                position: index + 1,
                onShowRule: onShowRule,
                checkURL: model.ruleCheckURL
            )
            // Nur neu aufbauen, wenn die ausgewählte Regel von außen geändert wurde (§24.5, §27 A12).
            .id("\(id)-\(model.editorResetCount)")
        } else {
            Text("Regel auswählen oder anlegen.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Seitenleiste

private struct RuleSidebar: View {
    @Bindable var model: AppModel
    let undoManager: UndoManager?
    @FocusState private var searchFocused: Bool

    private var query: String { model.ruleQuery }
    private var isFiltering: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    /// Inhalt ist eine URL, „Als Text suchen“ ist aber gewählt (§22.1).
    private var isForcedText: Bool {
        model.ruleQueryForcedText == query && RuleCheck.url(from: query) != nil
    }

    var body: some View {
        let list = model.ruleList
        VStack(alignment: .leading, spacing: 0) {
            searchField
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, isFiltering ? 4 : 6)
            if let check = list.check {
                modeRow
                RuleCheckCard(
                    result: check,
                    winner: check.decision.matchedRuleID.flatMap { model.rule(withID: $0) },
                    winnerPosition: check.decision.matchedRuleID.flatMap { list.positions[$0] },
                    defaultAction: model.config.defaultAction,
                    showsExtensionNote: model.extensionSettings != ExtensionSettings(),
                    source: $model.ruleCheckSource,
                    modifiers: $model.ruleCheckModifiers
                )
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
                checkCountRow(check)
            } else if isFiltering {
                HStack(spacing: 6) {
                    Text("\(list.rows.count) von \(model.config.rules.count) Regeln")
                        .font(DS.small)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if isForcedText {
                        TextLinkButton("Als URL prüfen") { model.ruleQueryForcedText = nil }
                            .help("Inhalt des Suchfelds als URL prüfen")
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, 12)
                .padding(.bottom, 4)
            }
            RuleListView(model: model, rows: list.rows, canReorder: !isFiltering, undoManager: undoManager)
                .overlay {
                    if model.config.rules.isEmpty {
                        emptyText("Keine Regeln.\nJeder Link nutzt die Standardaktion.")
                    } else if list.rows.isEmpty, list.check != nil {
                        emptyText("Keine Regel trifft. Mit „Alle Regeln“ siehst du, woran es scheitert.")
                    } else if list.rows.isEmpty {
                        emptyText("Keine Regel passt zu „\(query)“.")
                    }
                }

            Divider()
            HStack(spacing: 2) {
                IconButton("plus", help: "Neue Regel", tint: .primary, action: addNew)
                IconButton("minus", help: "Regel löschen", tint: .primary, action: removeSelected)
                    .disabled(model.selectedRuleID == nil)
                IconButton("plus.square.on.square", help: "Regel duplizieren", tint: .primary, action: duplicateSelected)
                    .disabled(model.selectedRuleID == nil)
                Spacer(minLength: 4)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        pendingCounter
                        footerLabel(list.check != nil)
                    }
                    pendingCounter
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func footerLabel(_ checking: Bool) -> some View {
        Text(footerText(checking: checking))
            .font(DS.small)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    /// Zähler wartender Regeln in der Fußleiste (§26.1); leer, wenn keine wartet.
    @ViewBuilder private var pendingCounter: some View {
        let count = model.pendingRuleCount
        if count > 0 {
            Label("\(count) Freigabe nötig", systemImage: "exclamationmark.triangle.fill")
                .font(DS.small.weight(.semibold))
                .foregroundStyle(DS.orange)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .fixedSize()
                .help(RuleApproval.countText(count))
                .accessibilityLabel(RuleApproval.countText(count))
        }
    }

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .font(DS.help)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding()
    }

    private func footerText(checking: Bool) -> String {
        if checking { return "Sortieren nur ohne Prüfung" }
        if isFiltering { return "Sortieren nur ohne Filter" }
        let count = model.config.rules.count
        return "\(count == 1 ? "1 Regel" : "\(count) Regeln") · oben gewinnt"
    }

    /// Zeile unter dem Suchfeld im Prüfmodus: Modus und Umschalter „Als Text suchen“ (§22.1).
    private var modeRow: some View {
        HStack(spacing: 6) {
            Label("URL wird geprüft", systemImage: "link")
                .font(DS.small)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            Spacer(minLength: 4)
            TextLinkButton("Als Text suchen") { model.ruleQueryForcedText = model.ruleQuery }
                .help("Inhalt des Suchfelds als Text in den Regeln suchen")
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.bottom, 6)
    }

    /// „x von y Regeln treffen“ + Umschalter „Nur Treffer“ / „Alle Regeln“ (§22.2).
    private func checkCountRow(_ check: RuleCheckResult) -> some View {
        let count = Text("\(check.matchCount) von \(check.entries.count) Regeln treffen")
            .font(DS.small)
            .foregroundStyle(.secondary)
        let picker = Picker("Ansicht", selection: $model.ruleCheckShowsAll) {
            Text("Nur Treffer").tag(false)
            Text("Alle Regeln").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .help("Nur passende Regeln oder alle Regeln zeigen")
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                count.fixedSize()
                Spacer(minLength: 4)
                picker
            }
            VStack(alignment: .leading, spacing: 4) {
                count
                picker
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.bottom, 4)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: model.ruleCheckURL == nil ? "magnifyingglass" : "link")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .accessibilityHidden(true)
            TextField(
                "Regeln durchsuchen oder URL prüfen",
                text: $model.ruleQuery,
                prompt: Text("Regeln durchsuchen oder URL prüfen")
            )
                .textFieldStyle(.plain)
                .font(DS.body)
                .focused($searchFocused)
                .onExitCommand { model.ruleQuery = ""; searchFocused = false }
                .accessibilityLabel("Regeln durchsuchen oder URL prüfen")
            if isFiltering {
                Button { model.ruleQuery = "" } label: { Keycap("esc", size: 16) }
                    .buttonStyle(.plain)
                    .help("Suche leeren (esc)")
                    .accessibilityLabel("Suche leeren")
            } else {
                Keycap("⌘F", size: 16)
            }
        }
        .padding(.horizontal, 6)
        .help("Regeln durchsuchen oder URL prüfen (⌘F)")
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7).fill(DS.neutralFill))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.accentColor, lineWidth: searchFocused ? 1 : 0)
        )
        .background {
            // ⌘F fokussiert die Suche.
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
    }

    // MARK: Aktionen

    /// „+“: im Prüfmodus mit geprüfter URL als Test-URL und „Host ist ‹host›“ (§22.3), Host in
    /// Unicode-Form (§27 A4).
    private func addNew() {
        guard let url = model.ruleCheckURL else {
            add(Rule(name: "Neue Regel"), actionName: "Neue Regel")
            return
        }
        let host = HostName.unicode(url) ?? ""
        let condition: Condition = host.isEmpty
            ? .linkType(url.isFileURL ? .file : .web)
            : .host(TextMatch(op: .equals, value: host))
        add(Rule(name: "Neue Regel", conditions: [condition], testURL: url.absoluteString), actionName: "Neue Regel")
    }

    private func add(_ rule: Rule, actionName: String) {
        let checking = model.ruleCheckURL != nil
        if !checking { model.ruleQuery = "" }  // neue Regel muss sichtbar sein
        let insertAt = model.ruleIndex(model.selectedRuleID).map { $0 + 1 } ?? model.config.rules.count
        model.insertRule(rule, at: insertAt, undoManager: undoManager, actionName: actionName)
        // Prüfmodus bleibt; trifft die neue Regel nicht, auf „Alle Regeln“ schalten.
        if checking, !model.ruleList.contains(rule.id) { model.ruleCheckShowsAll = true }
    }

    private func removeSelected() {
        guard let id = model.selectedRuleID else { return }
        model.deleteRule(id, undoManager: undoManager)
    }

    private func duplicateSelected() {
        guard let original = model.rule(withID: model.selectedRuleID) else { return }
        var copy = original
        copy.id = UUID()
        copy.name = original.name + " Kopie"
        add(copy, actionName: "Regel duplizieren")
    }
}

// MARK: - Liste

/// Liste aus vorab berechneten Zeilen; Schreiben nur per ID über das Model (§27 A1).
private struct RuleListView: View {
    @Bindable var model: AppModel
    let rows: [RuleRowModel]
    /// Umsortieren nur ohne Filter/Prüfung – in einer gefilterten Liste wäre das Ziel mehrdeutig.
    let canReorder: Bool
    let undoManager: UndoManager?

    var body: some View {
        List(selection: $model.selectedRuleID) {
            ForEach(rows) { row in
                RuleRow(row: row, model: model)
                    .equatable()
                    .tag(row.id)
                    .listRowSeparator(.hidden)
            }
            .onMove(perform: canReorder ? { from, to in
                model.moveRules(fromOffsets: from, toOffset: to, undoManager: undoManager)
            } : nil)
        }
        // Seitenleisten-Optik; `.inset` statt `.sidebar`, damit die Auswahl als deckende
        // Akzentfläche erscheint (wie im Mockup) und nicht als Vibrancy-Hervorhebung.
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        // Wechselt die Zeilenart (Chips ↔ Status-Zeile, „Nur Treffer“ ↔ „Alle Regeln“), baut die Liste
        // neu auf statt Zeilen anderer Höhe einzufügen: Das Einfügen löste in AppKit „reentrant
        // operation in its NSTableView delegate“ aus (§27 A6/A7). Filtern, Löschen, Umsortieren diffen weiter.
        .id(RuleListMode(checking: model.ruleCheckURL != nil, showsAll: model.ruleCheckShowsAll))
    }
}

/// Darstellungsart der Liste; ein Wechsel ersetzt die Tabelle.
private struct RuleListMode: Hashable {
    var checking: Bool
    var showsAll: Bool
}

// MARK: - URL-Prüfung

/// Ergebniskarte der URL-Prüfung (§22.2): was bei einem echten Klick passiert.
private struct RuleCheckCard: View {
    let result: RuleCheckResult
    let winner: Rule?
    let winnerPosition: Int?
    let defaultAction: Action
    let showsExtensionNote: Bool
    @Binding var source: String
    @Binding var modifiers: ModifierSet

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if winner != nil {
                    StatusPill(.ok, "Regel \(winnerPosition.map(String.init) ?? "?") greift", small: true).fixedSize()
                } else {
                    StatusPill(.neutral, "Keine Regel greift", small: true).fixedSize()
                }
                Spacer(minLength: 4)
                ViewThatFits(in: .horizontal) {
                    SimulationButton(source: $source, modifiers: $modifiers)
                    SimulationButton(source: $source, modifiers: $modifiers, compact: true)
                }
                .controlSize(.small)
            }
            if let winner {
                Text(winner.name.isEmpty ? "Ohne Namen" : winner.name)
                    .font(DS.cardTitle)
                    .fixedSize(horizontal: false, vertical: true)
                // URL nur, wenn Umschreibungen sie ändern (§22.2). Aktion aus der Entscheidung: bei einer
                // wartenden Änderung gilt der freigegebene Stand (§26.1).
                let rewritten = result.decision.finalURL != result.decision.originalURL
                ActionText.opens(result.decision.action, url: rewritten ? result.decision.finalURL : nil)
                    .font(DS.help)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Standardaktion: \(ActionText.opens(defaultAction, url: nil))")
                    .font(DS.help)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let from = result.decision.originalURL.scheme?.lowercased(),
               let to = result.decision.finalURL.scheme?.lowercased(), from != to {
                Label("Schemawechsel „\(from):“ → „\(to):“", systemImage: "exclamationmark.triangle")
                    .font(DS.small)
                    .foregroundStyle(DS.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(result.decision.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.circle")
                    .font(DS.small)
                    .foregroundStyle(DS.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsExtensionNote {
                Text("Links aus der Safari-Erweiterung verhalten sich anders (Tab „Safari“).")
                    .font(DS.small)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(DS.neutralFill))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ergebnis der URL-Prüfung")
    }
}

/// Status einer Regel in der Liste im Prüfmodus (§22.3).
struct RuleCheckLine: Equatable {
    enum Kind { case wins, shadowed, disabledMatch, pending, noMatch }
    let kind: Kind
    let text: String
}

/// Symbol des Ziels einer Regel (App-Icon, Ersatz-App, `safari` bzw. `square.grid.2x2`).
struct RuleTargetIcon: View {
    let action: Action
    let size: CGFloat

    var body: some View {
        Group {
            switch action {
            case .open(let app):
                Image(nsImage: Apps.icon(for: app)).resizable()
            case .openFirstRunning(let fallback?):
                Image(nsImage: Apps.icon(for: fallback)).resizable()
            case .openFirstRunning(nil):
                symbol("safari")
            case .prompt:
                symbol("square.grid.2x2")
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.22).fill(DS.neutralFill))
    }
}

/// Zeile der Regel-Liste: bekommt den Wert und schreibt An/Aus per ID (§27 A1).
private struct RuleRow: View, Equatable {
    let row: RuleRowModel
    let model: AppModel
    @Environment(\.backgroundProminence) private var prominence

    private var rule: Rule { row.rule }
    private var position: Int { row.position }
    /// Prüfmodus (§22.3): Status-Zeile statt Chips.
    private var checkLine: RuleCheckLine? { row.checkLine }
    private var onAccent: Bool { prominence == .increased }

    nonisolated static func == (a: RuleRow, b: RuleRow) -> Bool {
        MainActor.assumeIsolated { a.row == b.row && a.model === b.model }
    }

    private var enabled: Binding<Bool> {
        let id = rule.id
        let model = model
        return Binding(get: { row.rule.enabled }, set: { value in model.updateRule(id) { $0.enabled = value } })
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Toggle("Aktiv", isOn: enabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help(rule.enabled ? "Regel ist aktiv" : "Regel ist aus")
                .accessibilityLabel("Regel „\(displayName)“ aktiv")
            RuleTargetIcon(action: rule.action, size: 20)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(displayName)
                        .font(rule.enabled ? DS.cardTitle : .system(size: 13, weight: .medium))
                        .foregroundStyle(rule.enabled && checkLine?.kind != .noMatch ? .primary : .secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(position)")
                        .font(DS.small.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Position \(position)")
                }
                if let checkLine {
                    statusLine(checkLine)
                } else {
                    chips
                }
            }
        }
        .padding(.vertical, 3)
    }

    /// Symbol + Text, nie nur Farbe (§22.3).
    @ViewBuilder private func statusLine(_ line: RuleCheckLine) -> some View {
        if line.kind == .disabledMatch {
            Chip(line.text, outlined: true, onAccent: onAccent, maxWidth: 200)
        } else {
            let (symbol, color): (String, Color) = switch line.kind {
            case .wins: ("checkmark", DS.green)
            case .shadowed: ("exclamationmark.triangle", DS.orange)
            case .pending: ("clock", DS.orange)
            case .disabledMatch, .noMatch: ("xmark", .secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .bold))
                    .accessibilityHidden(true)
                Text(line.text)
                    .font(line.kind == .wins ? DS.small.weight(.semibold) : DS.small)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(onAccent ? Color.white : color)
            .accessibilityElement(children: .combine)
        }
    }

    private var displayName: String { rule.name.isEmpty ? "Ohne Namen" : rule.name }

    private struct ChipItem {
        var text: String
        var outlined = false
        var warning = false
    }

    /// Alle Chips in Anzeigereihenfolge; „Freigabe nötig“ (orange) zuerst, dann das Ziel der Umschreibung
    /// („↻ review.example.com“) vor den Bedingungen, damit es auch in schmalen Zeilen sichtbar bleibt (§26.1).
    private var chipItems: [ChipItem] {
        var items: [ChipItem] = []
        if rule.isPendingApproval { items.append(ChipItem(text: "Freigabe nötig", warning: true)) }
        if !rule.enabled { items.append(ChipItem(text: "Aus", outlined: true)) }
        if let rewrite = RuleDescriber.rewriteChip(rule.rewrites) { items.append(ChipItem(text: rewrite)) }
        items += rule.conditions.prefix(2).map { ChipItem(text: RuleText.chip($0)) }
        if rule.conditions.isEmpty { items.append(ChipItem(text: "immer")) }
        return items
    }

    /// So viele Chips wie in die Zeile passen; der Rest wird als „+n“ zusammengefasst, nie hart abgeschnitten.
    private var chips: some View {
        let items = chipItems
        let extra = max(rule.conditions.count - 2, 0)
        return ViewThatFits(in: .horizontal) {
            ForEach(Array(stride(from: items.count, through: 1, by: -1)), id: \.self) { shown in
                chipRow(Array(items.prefix(shown)), more: items.count - shown + extra)
            }
            // Notfalls nur der erste Chip, stärker gekürzt, plus „+n“.
            chipRow(Array(items.prefix(1)), more: items.count - 1 + extra, compress: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    private func chipRow(_ items: [ChipItem], more: Int, compress: Bool = false) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Chip(item.text, outlined: item.outlined, onAccent: onAccent, maxWidth: compress ? 130 : 160,
                     tint: item.warning ? DS.orange : nil)
            }
            if more > 0 { Chip("+\(more)", onAccent: onAccent) }
        }
    }
}
