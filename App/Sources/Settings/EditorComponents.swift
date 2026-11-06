import AirTrafficCore
import AppKit
import SwiftUI

// MARK: - Texte

enum ActionText {
    static func describe(_ action: Action) -> String {
        switch action {
        case .open(let app): "Öffnen mit \(app.displayName)"
        case .openFirstRunning(let fallback):
            "Erster laufender Browser, sonst \(fallback?.displayName ?? "erster der Liste")"
        case .prompt(.all): "Auswahl zeigen (alle)"
        case .prompt(.running): "Auswahl zeigen (laufende)"
        }
    }

    /// Aktion in Worten für Testleiste (§15.4) und URL-Prüfung (§22.2):
    /// „öffnet ‹URL› in ‹App›“; ohne `url` nur „öffnet in ‹App›“.
    static func opens(_ action: Action, url: URL?, hypothetical: Bool = false) -> Text {
        let verb = hypothetical ? "würde öffnen" : "öffnet"
        let urlText = url.map { Text($0.absoluteString).font(DS.monoSmall).foregroundStyle(.primary) }
        switch action {
        case .open(let app):
            let appText = Text(app.displayName).fontWeight(.semibold).foregroundStyle(.primary)
            if let urlText { return Text("\(verb) \(urlText) in \(appText)") }
            return Text("\(verb) in \(appText)")
        case .openFirstRunning(let fallback):
            let rest = fallback.map { ", sonst in \($0.displayName)" } ?? ""
            if let urlText { return Text("\(verb) \(urlText) im ersten laufenden Browser\(rest)") }
            return Text("\(verb) im ersten laufenden Browser\(rest)")
        case .prompt(let scope):
            let which = scope == .all ? "alle Browser" : "laufende Browser"
            if let urlText {
                return Text("\(hypothetical ? "würde" : "zeigt") \(urlText) im Auswahlfenster\(hypothetical ? " zeigen" : "") (\(which))")
            }
            return Text("\(hypothetical ? "würde die Auswahl zeigen" : "zeigt die Auswahl") (\(which))")
        }
    }
}

enum RuleText {
    static func fieldName(_ c: Condition) -> String {
        switch c {
        case .url: "URL"
        case .host: "Host"
        case .path: "Pfad"
        case .sourceApp: "Quell-App"
        case .modifiers: "Modifier"
        case .linkType: "Linktyp"
        }
    }

    static func opName(_ op: TextOp) -> String {
        switch op {
        case .equals: "ist"
        case .notEquals: "ist nicht"
        case .contains: "enthält"
        case .notContains: "enthält nicht"
        case .beginsWith: "beginnt mit"
        case .endsWith: "endet mit"
        case .wildcard: "passt auf Muster (*, ?)"
        case .regex: "passt auf Regex"
        }
    }

    static func modifierSymbols(_ set: ModifierSet) -> String {
        let s = [(ModifierSet.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { set.contains($0.0) }.map(\.1).joined()
        return s.isEmpty ? "keine" : s
    }

    static func describe(_ c: Condition) -> String {
        switch c {
        case .url(let m), .host(let m), .path(let m):
            "\(fieldName(c)) \(opName(m.op)) „\(m.value)“"
        case .sourceApp(let id, let negated):
            "Quell-App \(negated ? "ist nicht" : "ist") \(id)"
        case .modifiers(let set, let negated):
            "Modifier \(negated ? "nicht genau" : "genau") \(modifierSymbols(set))"
        case .linkType(let t):
            "Linktyp \(t == .web ? "Web" : "Datei")"
        }
    }

    /// Kurzform eines Operators für Chips („Host ist github.com“).
    static func shortOpName(_ op: TextOp) -> String {
        switch op {
        case .wildcard: "Muster"
        case .regex: "Regex"
        default: opName(op)
        }
    }

    /// Kurztext einer Bedingung für Chips in der Regel-Liste.
    @MainActor
    static func chip(_ c: Condition) -> String {
        switch c {
        case .url(let m), .host(let m), .path(let m):
            "\(fieldName(c)) \(shortOpName(m.op)) \(m.value)"
        case .sourceApp(let id, let negated):
            "Quell-App \(negated ? "ist nicht" : "ist") \(Apps.displayName(forBundleIdentifier: id) ?? id)"
        case .modifiers(let set, let negated):
            "Modifier \(negated ? "nicht genau" : "genau") \(modifierSymbols(set))"
        case .linkType(let t):
            "Linktyp \(t == .web ? "Web" : "Datei")"
        }
    }

    static func summary(_ rule: Rule) -> String {
        let conditions: String
        switch rule.conditions.count {
        case 0: conditions = "immer"
        case 1: conditions = describe(rule.conditions[0])
        default:
            let mode = switch rule.match {
            case .all: "alle"
            case .any: "irgendeine"
            case .none: "keine"
            }
            conditions = "\(rule.conditions.count) Bedingungen (\(mode))"
        }
        let rewrite = RuleDescriber.rewriteChip(rule.rewrites).map { " · \($0)" } ?? ""
        return "\(conditions)\(rewrite) → \(ActionText.describe(rule.action))"
    }
}

// MARK: - Bindings

extension Binding where Value: Sendable {
    /// Element-Binding, das nach Löschen nicht abstürzt.
    static func element(
        of array: Binding<[Value]>, at index: Int, fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: { array.wrappedValue.indices.contains(index) ? array.wrappedValue[index] : fallback },
            set: { if array.wrappedValue.indices.contains(index) { array.wrappedValue[index] = $0 } }
        )
    }
}

// MARK: - App-Auswahl

/// Menü-Button: Browserliste + „Andere App …“.
struct AppMenu: View {
    let title: String
    let current: AppRef?
    let browsers: [AppRef]
    var noneTitle: String?
    let onSelect: (AppRef?) -> Void

    var body: some View {
        Menu {
            if let noneTitle {
                Button(noneTitle) { onSelect(nil) }
                Divider()
            }
            // Offset statt Pfad: doppelte Einträge bleiben unterscheidbar (§27 A19).
            ForEach(Array(browsers.enumerated()), id: \.offset) { _, app in
                Button {
                    onSelect(app)
                } label: {
                    Label { Text(app.displayName) } icon: { Image(nsImage: Apps.icon(for: app)) }
                }
            }
            if !browsers.isEmpty { Divider() }
            Button("Andere App …") {
                if let app = Apps.chooseApplication() { onSelect(app) }
            }
        } label: {
            HStack(spacing: 6) {
                if let current {
                    Image(nsImage: Apps.icon(for: current)).resizable().frame(width: 16, height: 16)
                }
                Text(title)
            }
        }
        .fixedSize()
    }
}

/// Aktion kompakt: Art (mit App / erster laufender Browser / Auswahl zeigen) + zweites Menü
/// (App mit Icon / Ersatz-App / alle | laufende Browser).
struct ActionEditor: View {
    @Binding var action: Action
    let browsers: [AppRef]

    private enum Kind: Hashable { case open, firstRunning, prompt }

    private var kind: Binding<Kind> {
        Binding(
            get: {
                switch action {
                case .open: .open
                case .openFirstRunning: .firstRunning
                case .prompt: .prompt
                }
            },
            set: { newKind in
                switch newKind {
                case .open:
                    if case .open = action { return }
                    let current: AppRef? = if case .openFirstRunning(let f) = action { f } else { nil }
                    action = .open(current ?? browsers.first ?? AppRef(
                        bundleIdentifier: "com.apple.Safari",
                        path: "/Applications/Safari.app",
                        displayName: "Safari"
                    ))
                case .firstRunning:
                    if case .openFirstRunning = action { return }
                    action = .openFirstRunning(fallback: nil)
                case .prompt:
                    if case .prompt = action { return }
                    action = .prompt(.all)
                }
            }
        )
    }

    private var scope: Binding<PromptScope> {
        Binding(
            get: { if case .prompt(let scope) = action { scope } else { .all } },
            set: { action = .prompt($0) }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            Picker("Aktion", selection: kind) {
                Text("mit App").tag(Kind.open)
                Text("erster laufender Browser").tag(Kind.firstRunning)
                Text("Auswahl zeigen").tag(Kind.prompt)
            }
            .labelsHidden()
            .fixedSize()
            .help("Aktion")

            switch action {
            case .open(let app):
                AppMenu(title: app.displayName, current: app, browsers: browsers) { selected in
                    if let selected { action = .open(selected) }
                }
                .help("App, die geöffnet wird")
            case .openFirstRunning(let fallback):
                AppMenu(
                    title: fallback.map { "sonst \($0.displayName)" } ?? "sonst erster der Liste",
                    current: fallback,
                    browsers: browsers,
                    noneTitle: "Erster Browser der Liste"
                ) { action = .openFirstRunning(fallback: $0) }
                .help("Wenn keiner läuft")
            case .prompt:
                Picker("Browser", selection: scope) {
                    Text("alle Browser").tag(PromptScope.all)
                    Text("laufende Browser").tag(PromptScope.running)
                }
                .labelsHidden()
                .fixedSize()
                .help("Welche Browser die Auswahl zeigt")
            }
        }
    }
}

/// Quell-App: Icon + Name + Bundle-ID (editierbar) plus Menü aus laufenden/installierten Apps.
struct SourceAppField: View {
    @Binding var bundleIdentifier: String
    @FocusState private var focused: Bool

    private var name: String? {
        let id = bundleIdentifier.trimmingCharacters(in: .whitespaces)
        return id.isEmpty ? nil : Apps.displayName(forBundleIdentifier: id)
    }

    var body: some View {
        HStack(spacing: 6) {
            if let icon = Apps.icon(forBundleIdentifier: bundleIdentifier) {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            }
            if let name {
                Text(name).font(DS.body).lineLimit(1).fixedSize()
                Text("·").foregroundStyle(.secondary)
            }
            TextField("Bundle-ID", text: $bundleIdentifier, prompt: Text("com.example.app"))
                .labelsHidden()
                .font(DS.body)
                .foregroundStyle(.secondary)
                .focused($focused)
                .frame(minWidth: 120)
            Menu {
                Section("Laufend") {
                    ForEach(Array(Apps.runningRegularApps().enumerated()), id: \.offset) { _, app in
                        Button(app.displayName) { bundleIdentifier = app.bundleIdentifier ?? "" }
                    }
                }
                Menu("Installiert") {
                    ForEach(Array(Apps.installedApps().enumerated()), id: \.offset) { _, app in
                        Button(app.displayName) { bundleIdentifier = app.bundleIdentifier ?? "" }
                    }
                }
                Divider()
                Button("Andere App …") {
                    if let id = Apps.chooseApplication()?.bundleIdentifier { bundleIdentifier = id }
                }
            } label: {
                Image(systemName: "app.badge")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("App auswählen")
            .accessibilityLabel("App auswählen")
        }
        .modifier(FieldChrome(isFocused: focused))
    }
}

struct ModifierToggles: View {
    @Binding var modifiers: ModifierSet

    var body: some View {
        HStack(spacing: 2) {
            toggle(.control, "⌃", "Control")
            toggle(.option, "⌥", "Option")
            toggle(.shift, "⇧", "Shift")
            toggle(.command, "⌘", "Command")
        }
    }

    private func toggle(_ flag: ModifierSet, _ symbol: String, _ help: String) -> some View {
        Toggle(symbol, isOn: Binding(
            get: { modifiers.contains(flag) },
            set: { if $0 { modifiers.insert(flag) } else { modifiers.remove(flag) } }
        ))
        .toggleStyle(.button)
        .help(help)
    }
}

// MARK: - Simulation

/// „Simulieren …“ mit Popover (§15.4): Quell-App und Modifier; Punkt bei aktiver Simulation.
/// Genutzt von der Testleiste und der URL-Prüfung (§22.2).
struct SimulationButton: View {
    @Binding var source: String
    @Binding var modifiers: ModifierSet
    /// Nur Symbol (enge Seitenleiste).
    var compact = false
    @State private var isPresented = false

    private var active: Bool {
        !source.trimmingCharacters(in: .whitespaces).isEmpty || !modifiers.isEmpty
    }

    var body: some View {
        Button { isPresented.toggle() } label: {
            if compact {
                Image(systemName: "slider.horizontal.3")
            } else {
                Label("Simulieren …", systemImage: "slider.horizontal.3")
            }
        }
        .overlay(alignment: .topTrailing) {
            if active {
                Circle().fill(Color.accentColor).frame(width: 7, height: 7).offset(x: 2, y: -2)
                    .accessibilityHidden(true)
            }
        }
        .help("Quell-App und Modifier simulieren")
        .accessibilityLabel("Simulieren")
        .accessibilityValue(active ? "Simulation aktiv" : "")
        .popover(isPresented: $isPresented, arrowEdge: .top) { popover }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Weitere Bedingungen simulieren").font(DS.cardTitle)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Quell-App").font(DS.body)
                    SourceAppField(bundleIdentifier: $source).frame(width: 300)
                }
                GridRow {
                    Text("Modifier").font(DS.body)
                    ModifierToggles(modifiers: $modifiers)
                }
            }
        }
        .padding(14)
    }
}
