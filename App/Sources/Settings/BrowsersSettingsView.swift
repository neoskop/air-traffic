import AirTrafficCore
import SwiftUI

/// Tab „Browser“ (SPEC §15.7): Vorschau des Auswahlfensters und die geordnete Liste aus demselben Zustand.
struct BrowsersSettingsView: View {
    @Bindable var model: AppModel
    /// Ausgewählte Zeile als Position: Pfade können doppelt vorkommen (§27 A19).
    @State private var selection: Int?

    private static let rowHeight: CGFloat = 50

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                preview

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Reihenfolge").font(DS.cardTitle).accessibilityAddTraits(.isHeader)
                        Spacer()
                        TextLinkButton("Installierte Browser erkennen", action: detect)
                    }
                    .padding(.horizontal, 4)

                    list

                    HStack(spacing: 2) {
                        IconButton("plus", help: "Browser hinzufügen", tint: .primary, action: add)
                        IconButton("minus", help: "Ausgewählten Browser entfernen", tint: .primary, action: remove)
                            .disabled(selection == nil)
                        Spacer()
                        Text("Ziehen zum Sortieren · oben = Taste 1")
                            .font(DS.small)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 2)
                }
            }
            .frame(maxWidth: 600)
            .padding(.vertical, 20)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
        }
        .background(DS.textBackground)
    }

    // MARK: Vorschau

    private var preview: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Vorschau Auswahlfenster")
                Spacer()
                Text("Taste = Nummer")
            }
            .font(DS.small)
            .foregroundStyle(.secondary)

            if model.config.browsers.isEmpty {
                Text("Keine Browser – das Auswahlfenster nutzt dann die installierten Browser.")
                    .font(DS.help)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 72)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(model.config.browsers.enumerated()), id: \.offset) { index, app in
                            BrowserTile(
                                app: app,
                                number: index < 9 ? index + 1 : nil,
                                size: .mini,
                                missing: Apps.url(for: app) == nil
                            )
                        }
                    }
                    .frame(minWidth: 540)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .background(RoundedRectangle(cornerRadius: DS.cardRadius).fill(DS.neutralFill))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Vorschau Auswahlfenster")
    }

    // MARK: Liste

    private var list: some View {
        List(selection: $selection) {
            ForEach(Array(model.config.browsers.enumerated()), id: \.offset) { index, app in
                BrowserRow(app: app, number: index + 1)
                    .tag(index)
            }
            .onMove { from, to in
                // Auswahl wandert mit der verschobenen Zeile.
                var positions = Array(model.config.browsers.indices)
                positions.move(fromOffsets: from, toOffset: to)
                model.config.browsers.move(fromOffsets: from, toOffset: to)
                if let selection { self.selection = positions.firstIndex(of: selection) }
            }
        }
        .listStyle(.plain)
        .scrollDisabled(true)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, Self.rowHeight)
        .frame(height: max(CGFloat(model.config.browsers.count), 1) * Self.rowHeight + 2)
        .background(DS.controlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DS.separator, lineWidth: 0.5))
        .overlay {
            if model.config.browsers.isEmpty {
                Text("Keine Browser").font(DS.help).foregroundStyle(.secondary)
            }
        }
    }

    private func add() {
        guard let app = Apps.chooseApplication(message: "Browser oder App auswählen") else { return }
        guard !Apps.isSelf(app) else { return }
        if let existing = model.config.browsers.firstIndex(where: { $0.refersToSameApp(as: app) }) {
            selection = existing
        } else {
            model.config.browsers.append(app)
            selection = model.config.browsers.count - 1
        }
    }

    /// Entfernt genau den gewählten Eintrag, nicht alle mit demselben Pfad (§27 A19).
    private func remove() {
        guard let selection, model.config.browsers.indices.contains(selection) else { return }
        model.config.browsers.remove(at: selection)
        self.selection = nil
    }

    /// Fügt fehlende installierte Browser hinten an; bestehende Reihenfolge bleibt.
    private func detect() {
        var list = model.config.browsers
        for app in Apps.installedBrowsers() where !list.contains(where: { $0.refersToSameApp(as: app) }) {
            list.append(app)
        }
        model.config.browsers = list
    }
}

private struct BrowserRow: View {
    let app: AppRef
    let number: Int
    @Environment(\.backgroundProminence) private var prominence

    private var onAccent: Bool { prominence == .increased }

    var body: some View {
        HStack(spacing: 12) {
            Keycap("\(number)", size: 20, onAccent: onAccent)
                .opacity(number <= 9 ? 1 : 0)
            Image(nsImage: Apps.icon(for: app)).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.displayName).font(DS.body)
                Text(app.path)
                    .font(DS.small)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if Apps.url(for: app) == nil {
                StatusPill(.warning, "nicht gefunden")
            }
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .help("Ziehen zum Sortieren")
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}
