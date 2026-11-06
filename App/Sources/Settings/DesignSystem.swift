import AirTrafficCore
import AppKit
import SwiftUI

// MARK: - Gestaltungssystem (SPEC §15.1)

/// Farben, Schriften und Abstände. Farben kommen aus dem Asset-Katalog; sonst nur
/// semantische Systemfarben.
enum DS {
    // Farben
    /// Text und Symbole in Markenfarbe (Stufensymbole, Abschnittskacheln, KI-Funken, Textknöpfe).
    static let brand = Color("Brand")
    static let green = Color("StatusGreen")
    static let orange = Color("StatusOrange")
    /// Schrift auf deckendem `orange` (§27 A18, ≥ 4,5:1): hell → Weiß auf dunklem Orange (6:1),
    /// dunkel → fast Schwarz auf hellem Orange (9:1).
    static let onOrange = Color(nsColor: NSColor(name: "AirTrafficOnOrange") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.11, green: 0.07, blue: 0.0, alpha: 1)
            : NSColor.white
    })
    static let red = Color("StatusRed")
    /// Deckkraft getönter Flächen zu den Statusfarben.
    static let tint = 0.15

    static let separator = Color(nsColor: .separatorColor)
    static let controlBackground = Color(nsColor: .controlBackgroundColor)
    static let windowBackground = Color(nsColor: .windowBackgroundColor)
    static let textBackground = Color(nsColor: .textBackgroundColor)
    /// Neutrale, leicht getönte Fläche (Chips, Suchfeld, Ergebnisblöcke).
    static let neutralFill = Color.primary.opacity(0.06)
    /// Feiner Rahmen von Feldern und Karten.
    static let hairline = Color.primary.opacity(0.14)

    // Typo
    static let title = Font.system(size: 20, weight: .semibold)
    static let cardTitle = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 13)
    static let help = Font.system(size: 12)
    static let small = Font.system(size: 11)
    static let mono = Font.system(size: 12, design: .monospaced)
    static let monoSmall = Font.system(size: 11.5, design: .monospaced)

    // Abstände und Radien
    static let s4: CGFloat = 4
    static let s8: CGFloat = 8
    static let s12: CGFloat = 12
    static let s20: CGFloat = 20
    static let cardRadius: CGFloat = 12
    static let fieldRadius: CGFloat = 6
    static let pillRadius: CGFloat = 11

    /// Farben der Gruppen-Legende ($1, $2 …), zyklisch.
    static let groupColors: [Color] = [.blue, .purple, .pink, .teal]
}

// MARK: - StatusPill

struct StatusPill: View {
    enum Kind { case ok, neutral, warning, error }

    let kind: Kind
    let text: String
    var symbol: String?
    var small = false

    init(_ kind: Kind, _ text: String, symbol: String? = nil, small: Bool = false) {
        self.kind = kind
        self.text = text
        self.symbol = symbol ?? Self.defaultSymbol(kind)
        self.small = small
    }

    private static func defaultSymbol(_ kind: Kind) -> String? {
        switch kind {
        case .ok: "checkmark"
        case .neutral: nil
        case .warning: "exclamationmark.triangle"
        case .error: "exclamationmark.circle"
        }
    }

    private var color: Color {
        switch kind {
        case .ok: DS.green
        case .neutral: .secondary
        case .warning: DS.orange
        case .error: DS.red
        }
    }

    private var fill: Color {
        switch kind {
        case .ok: DS.green.opacity(DS.tint)
        case .neutral: DS.neutralFill
        case .warning: DS.orange.opacity(DS.tint)
        case .error: DS.red.opacity(DS.tint)
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: small ? 9 : 10, weight: .bold))
            }
            Text(text).lineLimit(1)
        }
        .font(.system(size: small ? 11 : 12, weight: .medium))
        .foregroundStyle(color)
        .padding(.horizontal, small ? 8 : 9)
        .frame(minHeight: small ? 20 : 22)
        .background(Capsule().fill(fill))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Keycap

struct Keycap: View {
    let text: String
    var size: CGFloat = 18
    /// Auf Akzentfläche (ausgewählte Zeile): abdunkelnde Überlagerung statt heller Taste.
    var onAccent = false

    init(_ text: String, size: CGFloat = 18, onAccent: Bool = false) {
        self.text = text
        self.size = size
        self.onAccent = onAccent
    }

    var body: some View {
        Text(text)
            .font(.system(size: size * 0.6, weight: .medium).monospacedDigit())
            .foregroundStyle(onAccent ? Color.white : Color.primary.opacity(0.8))
            .padding(.horizontal, size * 0.22)
            .frame(minWidth: size, minHeight: size)
            .background {
                if onAccent {
                    RoundedRectangle(cornerRadius: size * 0.28).fill(.black.opacity(0.22))
                } else {
                    RoundedRectangle(cornerRadius: size * 0.28)
                        .fill(Color(nsColor: .controlColor))
                        .shadow(color: DS.hairline, radius: 0, y: 1)
                        .overlay(RoundedRectangle(cornerRadius: size * 0.28).strokeBorder(DS.hairline, lineWidth: 0.5))
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Chip

struct Chip: View {
    let text: String
    var outlined = false
    var onAccent = false
    var maxWidth: CGFloat = 160
    /// Getönter Chip (z. B. orange „Freigabe nötig“, §26.1).
    var tint: Color?

    init(_ text: String, outlined: Bool = false, onAccent: Bool = false, maxWidth: CGFloat = 160, tint: Color? = nil) {
        self.text = text
        self.outlined = outlined
        self.onAccent = onAccent
        self.maxWidth = maxWidth
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(tint == nil ? DS.small : DS.small.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(foreground)
            .padding(.horizontal, 6)
            .frame(height: 17)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .fixedSize()
            .background {
                if let tint {
                    // Auf der Akzentfläche deckend mit `onOrange`-Schrift statt Weiß auf 85 % (§27 A18).
                    RoundedRectangle(cornerRadius: 5).fill(onAccent ? tint : tint.opacity(DS.tint))
                } else if outlined {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(onAccent ? Color.white.opacity(0.6) : DS.hairline, lineWidth: 0.5)
                } else {
                    RoundedRectangle(cornerRadius: 5).fill(onAccent ? Color.black.opacity(0.22) : DS.neutralFill)
                }
            }
    }
}

extension Chip {
    private var foreground: Color {
        if let tint { return onAccent ? DS.onOrange : tint }
        return onAccent ? .white : .secondary
    }
}

// MARK: - Knopf auf Orange (§27 A18)

/// Hervorgehobener Knopf in Orange mit kontraststarker Schrift (statt `.borderedProminent` + `.tint`).
struct OrangeProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(DS.onOrange)
            .padding(.horizontal, 10)
            .frame(minHeight: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(DS.orange))
            .overlay(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(configuration.isPressed ? 0.15 : 0)))
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - SectionHeader

/// Abschnittskopf mit 20-pt-Kachel in `Brand` 15 %.
struct SectionHeader: View {
    let symbol: String
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(spacing: 7) {
            BrandTile(symbol: symbol, size: 20)
            Text(title).font(DS.cardTitle)
            if let subtitle {
                Text(subtitle).font(DS.help).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct BrandTile: View {
    let symbol: String
    let size: CGFloat
    /// Volle Markenfläche mit hellem Symbol (KI-Sheet) statt 15-%-Tönung.
    var filled = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * (filled ? 0.5 : 0.58), weight: .semibold))
            .foregroundStyle(filled ? Color(nsColor: .textBackgroundColor) : DS.brand)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * (filled ? 0.3 : 0.3))
                    .fill(filled ? DS.brand : DS.brand.opacity(DS.tint))
            )
            .accessibilityHidden(true)
    }
}

// MARK: - Seiten

/// Seite eines Einstellungs-Tabs wie „Allgemein“ (§15, §23): zentriert, max. 600 pt, scrollt.
struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content }
                .frame(maxWidth: 600)
                .padding(.vertical, 20)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
        }
        .background(DS.textBackground)
    }
}

/// Kopfkarte einer Seite: großes App-Symbol, Titel, Beschreibung, rechts optional Steuerelemente.
struct PageHeaderCard<Trailing: View, Footer: View>: View {
    let icon: NSImage
    let title: String
    let detail: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 14) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 52, height: 52)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(DS.help)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if Trailing.self != EmptyView.self {
                    Spacer(minLength: 8)
                    trailing
                } else {
                    Spacer(minLength: 0)
                }
            }
            footer
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: DS.cardRadius).fill(DS.controlBackground))
        .overlay(RoundedRectangle(cornerRadius: DS.cardRadius).strokeBorder(DS.separator, lineWidth: 0.5))
    }
}

extension PageHeaderCard where Footer == EmptyView {
    init(icon: NSImage, title: String, detail: String, @ViewBuilder trailing: () -> Trailing) {
        self.init(icon: icon, title: title, detail: detail, trailing: trailing, footer: { EmptyView() })
    }
}

extension PageHeaderCard where Trailing == EmptyView, Footer == EmptyView {
    init(icon: NSImage, title: String, detail: String) {
        self.init(icon: icon, title: title, detail: detail, trailing: { EmptyView() }, footer: { EmptyView() })
    }
}

// MARK: - Karten

/// Gruppierte Karte (Allgemein, Browser).
struct GroupCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 10).fill(DS.controlBackground))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DS.separator, lineWidth: 0.5))
    }
}

/// Zeile einer `GroupCard`: Beschriftung links (130 pt), Inhalt rechts.
struct GroupRow<Value: View>: View {
    var label: String?
    var divider = true
    @ViewBuilder let value: Value

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let label {
                    Text(label).font(DS.body).frame(width: 130, alignment: .leading)
                }
                HStack(spacing: 8) { value }
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 40)
            if divider { Divider().padding(.leading, 12) }
        }
    }
}

/// Abschnittskarte im Regel-Editor mit Kopf (Symbol, Titel, Untertitel, rechts Steuerelemente).
struct StageCard<Trailing: View, Content: View>: View {
    let symbol: String
    let title: String
    var subtitle: String?
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.brand)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(title).font(DS.cardTitle)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle).font(DS.help).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            if Content.self != EmptyView.self {
                Divider()
                VStack(alignment: .leading, spacing: 0) { content }
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
            }
        }
        .background(RoundedRectangle(cornerRadius: DS.cardRadius).fill(DS.controlBackground))
        .overlay(RoundedRectangle(cornerRadius: DS.cardRadius).strokeBorder(DS.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
    }
}

// MARK: - PipelineNode

struct PipelineNode: View {
    enum State: Equatable {
        case passed, failed, idle
        case neutral(Int)
    }

    let state: State
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            switch state {
            case .passed:
                Circle().fill(DS.green)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(colorScheme == .dark ? Color(red: 0.016, green: 0.141, blue: 0.059) : .white)
            case .failed:
                Circle().fill(DS.controlBackground)
                Circle().strokeBorder(DS.hairline, lineWidth: 1.5)
                Image(systemName: "xmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(.secondary)
            case .idle:
                Circle().fill(DS.controlBackground)
                Circle().strokeBorder(DS.hairline, lineWidth: 1.5)
                Image(systemName: "minus").font(.system(size: 10, weight: .heavy)).foregroundStyle(.secondary)
            case .neutral(let n):
                Circle().fill(DS.controlBackground)
                Circle().strokeBorder(DS.hairline, lineWidth: 1.5)
                Text("\(n)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 24, height: 24)
        .background(Circle().fill(DS.textBackground).padding(-3))
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        switch state {
        case .passed: "durchlaufen"
        case .failed: "nicht erfüllt"
        case .idle: "nicht verwendet"
        case .neutral(let n): "Stufe \(n)"
        }
    }
}

/// Kleines ✓/✗ am Ende einer Bedingungszeile.
struct ConditionStatus: View {
    let passed: Bool

    var body: some View {
        Image(systemName: passed ? "checkmark" : "xmark")
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(passed ? DS.green : Color.secondary)
            .frame(width: 18, height: 18)
            .background(Circle().fill(passed ? DS.green.opacity(DS.tint) : DS.neutralFill))
            .help(passed ? "Trifft für die Test-URL zu" : "Trifft für die Test-URL nicht zu")
            .accessibilityLabel(passed ? "Bedingung erfüllt" : "Bedingung nicht erfüllt")
    }
}

// MARK: - Knöpfe

/// Groß-/Kleinschreibung-Schalter; eingeschaltet getönt mit Akzent.
struct AaToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            Text("Aa")
                .font(.system(size: 12, weight: isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .frame(width: 24, height: 22)
                .background {
                    if isOn {
                        RoundedRectangle(cornerRadius: DS.fieldRadius).fill(Color.accentColor.opacity(0.14))
                        RoundedRectangle(cornerRadius: DS.fieldRadius).strokeBorder(Color.accentColor, lineWidth: 0.5)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Groß-/Kleinschreibung beachten")
        .accessibilityLabel("Groß-/Kleinschreibung beachten")
        .accessibilityValue(isOn ? "an" : "aus")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Symbol-Knopf ohne Rahmen; immer mit Hilfe und VoiceOver-Beschriftung.
struct IconButton: View {
    let symbol: String
    let help: String
    var tint: Color = .secondary
    let action: () -> Void

    init(_ symbol: String, help: String, tint: Color = .secondary, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Textknopf in Markenfarbe („+ Bedingung“, „Status prüfen“).
struct TextLinkButton: View {
    let title: String
    var symbol: String?
    let action: () -> Void

    init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                Text(title)
            }
            .font(DS.body)
            .foregroundStyle(DS.brand)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Felder

/// Rahmen eines einzeiligen Eingabefelds (Radius 6, feiner Rahmen).
struct FieldChrome: ViewModifier {
    var isFocused = false
    var height: CGFloat = 24

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 7)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: DS.fieldRadius).fill(DS.textBackground))
            .overlay(
                RoundedRectangle(cornerRadius: DS.fieldRadius)
                    .strokeBorder(isFocused ? Color.accentColor : DS.hairline, lineWidth: isFocused ? 1 : 0.5)
            )
            .background(
                RoundedRectangle(cornerRadius: DS.fieldRadius + 2)
                    .fill(Color.accentColor.opacity(isFocused ? 0.25 : 0))
                    .padding(-2.5)
            )
    }
}

/// Einzeiliges Textfeld im Stil des Gestaltungssystems (fokussiert: Akzentrahmen).
struct DSTextField: View {
    let title: String
    @Binding var text: String
    var prompt: String?
    var mono = false
    var isError = false
    var onSubmit: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    @FocusState private var focused: Bool

    init(_ title: String, text: Binding<String>, prompt: String? = nil, mono: Bool = false,
         isError: Bool = false, onSubmit: (() -> Void)? = nil, onFocusChange: ((Bool) -> Void)? = nil) {
        self.title = title
        _text = text
        self.prompt = prompt
        self.mono = mono
        self.isError = isError
        self.onSubmit = onSubmit
        self.onFocusChange = onFocusChange
    }

    var body: some View {
        TextField(title, text: $text, prompt: prompt.map { Text($0) })
            .labelsHidden()
            .font(mono ? DS.mono : DS.body)
            .foregroundStyle(isError ? DS.red : Color.primary)
            .focused($focused)
            .onSubmit { onSubmit?() }
            .onChange(of: focused) { _, now in onFocusChange?(now) }
            .modifier(FieldChrome(isFocused: focused))
            .accessibilityLabel(title)
    }
}

/// Mehrzeiliges Eingabefeld (TextEditor) mit Rahmen, Radius 8.
struct DSTextEditor: View {
    @Binding var text: String
    var mono = false
    var minHeight: CGFloat = 40

    var body: some View {
        TextEditor(text: $text)
            .font(mono ? DS.mono : DS.body)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 5)
            .padding(.vertical, 6)
            .frame(minHeight: minHeight)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 8).fill(DS.textBackground))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DS.hairline, lineWidth: 0.5))
    }
}

// MARK: - Browser-Kachel (Chooser und Vorschau)

struct BrowserTile: View {
    enum Size {
        case regular, mini
        var tile: CGSize { self == .regular ? CGSize(width: 96, height: 100) : CGSize(width: 72, height: 72) }
        var icon: CGFloat { self == .regular ? 44 : 32 }
        var font: CGFloat { self == .regular ? 12 : 10.5 }
        var keycap: CGFloat { self == .regular ? 16 : 14 }
        var inset: CGFloat { self == .regular ? 6 : 4 }
    }

    let app: AppRef
    let number: Int?
    var selected = false
    var size: Size = .regular
    var running = false
    var missing = false
    @Environment(\.colorScheme) private var colorScheme

    /// Im Dunkelmodus ist der Akzent (v. a. Petrol bei „Mehrfarbig“) auf Glas zu schwach → aufhellen.
    private var ring: Color {
        colorScheme == .dark ? Color.accentColor.mix(with: .white, by: 0.35) : Color.accentColor
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: Apps.icon(for: app))
                .resizable()
                .frame(width: size.icon, height: size.icon)
                .saturation(missing ? 0 : 1)
                .opacity(missing ? 0.55 : 1)
            Text(app.displayName)
                .font(.system(size: size.font))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4)
                .padding(.top, size == .regular ? 6 : 4)
            if size == .regular {
                Circle()
                    .fill(.secondary)
                    .frame(width: 4, height: 4)
                    .opacity(running ? 1 : 0)
                    .padding(.top, 4)
            }
        }
        .frame(width: size.tile.width, height: size.tile.height)
        .overlay(alignment: .topTrailing) {
            if let number { Keycap("\(number)", size: size.keycap).padding(size.inset) }
        }
        .overlay(alignment: .topLeading) {
            if missing {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DS.orange)
                    .padding(size.inset + 1)
            }
        }
        .background {
            if selected {
                RoundedRectangle(cornerRadius: DS.cardRadius).fill(ring.opacity(colorScheme == .dark ? 0.2 : 0.12))
                RoundedRectangle(cornerRadius: DS.cardRadius).strokeBorder(ring, lineWidth: 2)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: DS.cardRadius))
        .help(app.path)
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var accessibilityText: String {
        var parts = [app.displayName]
        if let number { parts.append("Taste \(number)") }
        if running { parts.append("läuft") }
        if missing { parts.append("nicht gefunden") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Hilfen

extension View {
    /// Getönte Hinweiszeile (orange/rot), voller Text.
    func tintedRow(_ color: Color) -> some View {
        self
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(DS.tint)))
    }
}

/// Gemeinsames Präfix/Suffix zweier Strings; der Mittelteil der Ausgabe ist „geändert“.
enum TextDiff {
    static func changedRange(from input: String, to output: String) -> Range<String.Index>? {
        guard input != output else { return nil }
        let a = Array(input), b = Array(output)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let start = output.index(output.startIndex, offsetBy: prefix)
        let end = output.index(output.endIndex, offsetBy: -suffix)
        return start < end ? start..<end : nil
    }
}

/// Fließlayout: Elemente nebeneinander, bei Platzmangel nächste Zeile (Pills, Gruppen-Legende).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height)
                )
                x += min(size.width, bounds.width) + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            let itemWidth = min(size.width, width)
            if !current.indices.isEmpty, current.width + spacing + itemWidth > width {
                rows.append(current)
                current = Row()
            }
            current.width += (current.indices.isEmpty ? 0 : spacing) + itemWidth
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
