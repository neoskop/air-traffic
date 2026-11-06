import AirTrafficCore
import AppKit
import SwiftUI

struct ChooserRequest {
    var url: URL
    var sourceBundleIdentifier: String?
    /// Ersetzt „von ‹Quell-App›“, z. B. „über airtraffic://-Link“ (§26.4).
    var sourceLabel: String? = nil
    var scope: PromptScope
    var hint: String?

    func with(hint: String) -> ChooserRequest {
        var copy = self
        copy.hint = hint
        return copy
    }
}

/// Zustand des Chooser-Inhalts.
@MainActor
@Observable
final class ChooserState {
    var urlText: String
    var browsers: [AppRef]
    var selection = 0
    var hint: String?
    /// URL-Feld fokussiert → vollständiges Textfeld statt strukturierter Anzeige.
    var isEditingURL = false
    /// Kopfzeile: „von ‹App›“ bzw. `ChooserRequest.sourceLabel`.
    let sourceText: String?
    /// Herkunft der Anfrage, für ein erneutes Auswahlfenster nach einem Startfehler (§27 A2).
    let sourceBundleIdentifier: String?
    let sourceLabel: String?
    let sourceIcon: NSImage?
    /// Je Browser: läuft / nicht gefunden (beim Öffnen des Panels ermittelt).
    let running: [Bool]
    let missing: [Bool]

    init(request: ChooserRequest, browsers: [AppRef]) {
        urlText = request.url.absoluteString
        self.browsers = browsers
        running = browsers.map(Apps.isRunning)
        missing = browsers.map { Apps.url(for: $0) == nil }
        hint = request.hint
        sourceBundleIdentifier = request.sourceBundleIdentifier
        sourceLabel = request.sourceLabel
        if let label = request.sourceLabel {
            sourceText = label
            sourceIcon = nil
        } else if let id = request.sourceBundleIdentifier {
            sourceText = "von \(Apps.displayName(forBundleIdentifier: id) ?? id)"
            sourceIcon = Apps.icon(forBundleIdentifier: id)
        } else {
            sourceText = nil
            sourceIcon = nil
        }
    }

    /// Bearbeitete URL; `nil`, wenn ungültig.
    var editedURL: URL? {
        let text = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.scheme != nil else { return nil }
        return url
    }
}

/// Titelloses, schwebendes Panel, das Tastatureingaben bekommt (SPEC §21.3).
///
/// Nicht aktivierend: Es wird Key, ohne Air Traffic zur aktiven App zu machen. So bleibt der Space
/// stehen (auch ein Vollbild-Space), und die Tastatur geht trotzdem ans Panel. Tasten behandelt das
/// Panel selbst (`keyHandler`) statt über einen lokalen Event-Monitor – unabhängig davon, ob die App aktiv ist.
final class ChooserPanel: NSPanel {
    /// `true` = Ereignis verbraucht. Darf mehrfach für dasselbe Ereignis gefragt werden
    /// (Tastenkürzel, dann `keyDown`), solange es `false` liefert, ohne etwas zu tun.
    var keyHandler: ((NSEvent) -> Bool)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            // `.nonactivatingPanel` muss beim Erzeugen gesetzt sein (spätere Änderung greift im Window-Server nicht).
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        // Über Vollbild-Fenstern (Ebene normal) und schwebenden Paletten anderer Apps.
        level = .modalPanel
        // In jedem Space vorhanden, auch in Vollbild-Spaces; nicht in Mission Control / ⌘` .
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }
}

/// Zeigt Chooser-Anfragen nacheinander.
@MainActor
final class ChooserController: NSObject, NSWindowDelegate {
    weak var opener: Opener?
    private let model: AppModel
    private var queue: [ChooserRequest] = []
    private var panel: ChooserPanel?
    private var state: ChooserState?
    /// URL des gezeigten Eintrags (vor Bearbeitung) – zum Zusammenfassen gleicher Links (§26.8).
    private var shownURL: URL?
    /// Zeitpunkt, zu dem der gezeigte Eintrag erschien; Tasten zählen erst danach (§26.8).
    private var shownAt = Date.distantPast
    private var queuePolicy = ChooserQueuePolicy()
    /// Ziffern und ⏎ in dieser Zeit nach dem Erscheinen ignorieren (gegen Fehl-Tastendrücke).
    static let keyGuard: TimeInterval = 0.3
    private weak var urlField: NSTextField?
    /// Vorne liegende App beim Öffnen; bekommt bei Abbruch den Fokus zurück, falls Air Traffic aktiv wurde.
    private var previousApp: NSRunningApplication?
    /// Nach dem Schließen des Panels (z. B. wartendes Update installieren, §17).
    var onClose: (() -> Void)?

    /// Panel offen oder weitere Anfragen in der Warteschlange.
    var isShowing: Bool { panel != nil || !queue.isEmpty }

    init(model: AppModel) {
        self.model = model
    }

    /// Höchstens 5 wartende Einträge, gleiche URLs zusammengefasst; läuft die Warteschlange über,
    /// wird verworfen und 10 s lang nur protokolliert (§26.8).
    func present(_ request: ChooserRequest) {
        switch queuePolicy.admit(request.url, showing: panel == nil ? nil : shownURL, queued: queue.map(\.url)) {
        case .accept:
            queue.append(request)
            if panel == nil { showNext() }
        case .merged:
            Log.chooser.info("Auswahlfenster: gleicher Link wird schon gezeigt oder wartet – zusammengefasst")
        case .dropped(let firstOfBurst):
            if firstOfBurst {
                Log.chooser.warning("Auswahlfenster: Warteschlange voll (\(ChooserQueuePolicy.maxQueued)) – Link verworfen, 10 s lang nur Log")
            } else {
                Log.chooser.notice("Auswahlfenster: Link verworfen (Warteschlange war voll)")
            }
        }
    }

    private func showNext() {
        // Höchstens ein Panel: ein verzögertes `showNext` nach `close` darf kein zweites öffnen (§27 A3).
        guard panel == nil, !queue.isEmpty else { return }
        let request = queue.removeFirst()
        shownURL = request.url
        shownAt = Date()

        var browsers = model.effectiveBrowsers
        if request.scope == .running {
            let running = browsers.filter(Apps.isRunning)
            if !running.isEmpty { browsers = running }
        }
        let state = ChooserState(request: request, browsers: browsers)
        if browsers.isEmpty, state.hint == nil {
            state.hint = "Keine Browser gefunden – in den Einstellungen hinzufügen."
        }
        self.state = state

        let maxWidth = (Self.screenUnderMouse()?.visibleFrame.width).map { $0 - 80 } ?? 900
        let view = ChooserView(
            state: state,
            maxWidth: maxWidth,
            onOpen: { [weak self] index in self?.open(index: index) },
            onFieldSubmit: { [weak self] in self?.open(index: nil) },
            onFieldEscape: { [weak self] in self?.leaveURLField() },
            onFocusField: { [weak self] in self?.focusURLField() },
            registerField: { [weak self] field in self?.urlField = field }
        )
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]

        let panel = ChooserPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 240))
        // Transparentes Panel; Form, Glas/Material und Radius kommen aus dem SwiftUI-Inhalt.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.contentViewController = hosting
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = .clear
        panel.delegate = self
        panel.setContentSize(hosting.view.fittingSize)
        center(panel)
        panel.invalidateShadow()
        self.panel = panel

        panel.keyHandler = { [weak self] event in
            MainActor.assumeIsolated { self?.handleKey(event) ?? false }
        }
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        // Kein `NSApp.activate()`: das würde in den Space mit Air-Traffic-Fenstern wechseln (§21.3).
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        // URL-Feld zunächst nicht fokussiert, damit 1–9 und Pfeile direkt wirken.
        panel.makeFirstResponder(nil)
        state.isEditingURL = false
        // `NSApp.isActive` meldet bei einem Key-Panel ohne Aktivierung ebenfalls true; maßgeblich ist die vorderste App.
        Log.chooser.info(
            "Chooser gezeigt (\(browsers.count) Browser), Key: \(panel.isKeyWindow), aktiver Space: \(panel.isOnActiveSpace), Air Traffic vorne: \(Self.isFrontmost), vorher vorne: \(front.map(Self.name) ?? "?", privacy: .public)"
        )
    }

    private static var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    private static func name(_ app: NSRunningApplication) -> String {
        "\(app.bundleIdentifier ?? "?") (pid \(app.processIdentifier))"
    }

    private static func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    private func center(_ panel: NSPanel) {
        guard let visible = Self.screenUnderMouse()?.visibleFrame else { panel.center(); return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
    }

    // MARK: Aktionen

    private func open(index: Int?) {
        guard let state, let panel else { return }
        let target = index ?? state.selection
        guard state.browsers.indices.contains(target) else { NSSound.beep(); return }
        guard let url = state.editedURL else {
            state.hint = "Ungültige URL."
            NSSound.beep()
            return
        }
        guard !AirTrafficURL.isAirTrafficURL(url) else {
            state.hint = "airtraffic://-Links öffnet Air Traffic nicht selbst."
            NSSound.beep()
            return
        }
        // ⌥ gedrückt → App nicht aktivieren.
        let activates = !NSEvent.modifierFlags.contains(.option)
        let app = state.browsers[target]
        let retry = ChooserRequest(
            url: url,
            sourceBundleIdentifier: state.sourceBundleIdentifier,
            sourceLabel: state.sourceLabel,
            scope: .all,
            hint: nil
        )
        let onFailure: @MainActor (String) -> Void = { [weak self] hint in self?.present(retry.with(hint: hint)) }
        if opener?.open(url, with: app, activates: activates, onFailure: onFailure) == true {
            // Mit Aktivierung geht der Fokus an den Browser, sonst zurück an die vorherige App.
            close(panel, restoreFocus: !activates)
        } else {
            state.hint = "„\(app.displayName)“ wurde nicht gefunden."
            NSSound.beep()
        }
    }

    private func copyURL() {
        guard let state else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(state.urlText, forType: .string)
    }

    private func leaveURLField() {
        panel?.makeFirstResponder(nil)
        state?.isEditingURL = false
    }

    private func focusURLField() {
        guard let panel, let urlField else { return }
        state?.isEditingURL = true
        panel.makeFirstResponder(urlField)
    }

    private var isEditingURL: Bool {
        guard let editor = panel?.firstResponder as? NSTextView, let urlField else { return false }
        return editor.delegate === urlField
    }

    /// `restoreFocus`: Abbruch – ist Air Traffic doch vorderste App geworden (z. B. Kaltstart per Link),
    /// geht der Fokus an die vorherige App zurück, solange keine Einstellungen offen sind. Im Normalfall
    /// bleibt die vorherige App vorne, und das Schließen des Panels gibt ihr den Fokus von selbst zurück.
    private func close(_ panel: ChooserPanel, restoreFocus: Bool = false) {
        panel.keyHandler = nil
        panel.delegate = nil
        panel.orderOut(nil)
        self.panel = nil
        state = nil
        shownURL = nil
        urlField = nil
        let previous = previousApp
        previousApp = nil
        if restoreFocus, Self.isFrontmost, !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            if let previous, !previous.isTerminated {
                Log.chooser.info("Fokus zurück an \(Self.name(previous), privacy: .public)")
                previous.activate()
            } else {
                // Vorherige App unbekannt (Air Traffic war beim Öffnen schon vorne): abgeben statt aktiv bleiben.
                NSApp.hide(nil)
            }
        }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.showNext()
                self?.onClose?()
            }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        // Fokusverlust schließt das Panel; der Fokus liegt schon dort, wohin geklickt wurde.
        guard let panel, (notification.object as? NSPanel) === panel else { return }
        close(panel)
    }

    // MARK: Tastatur

    private enum Key {
        static let tab: UInt16 = 48
        static let returnKey: UInt16 = 36
        static let enter: UInt16 = 76
        static let escape: UInt16 = 53
        static let left: UInt16 = 123
        static let right: UInt16 = 124
    }

    /// `true` = Ereignis verbraucht.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let panel, event.window === panel, let state else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers ?? ""

        if isEditingURL {
            // Ohne Hauptmenü gibt es keine Standard-Tastenkürzel → selbst weiterreichen.
            if flags.contains(.command) {
                let actions: [String: Selector] = [
                    "c": #selector(NSText.copy(_:)), "v": #selector(NSText.paste(_:)),
                    "x": #selector(NSText.cut(_:)), "a": #selector(NSText.selectAll(_:)),
                    "z": flags.contains(.shift) ? Selector(("redo:")) : Selector(("undo:")),
                ]
                if let action = actions[chars.lowercased()] {
                    NSApp.sendAction(action, to: nil, from: self)
                    return true
                }
            }
            return false  // Enter/Esc behandelt das Feld selbst.
        }

        if flags.contains(.command) {
            if chars.lowercased() == "c" { copyURL(); return true }
            return false
        }
        // Kurz nach dem Erscheinen: Ziffern und ⏎ verbrauchen, aber nichts öffnen (§26.8).
        let tooEarly = Date().timeIntervalSince(shownAt) < Self.keyGuard
        switch event.keyCode {
        case Key.escape: close(panel, restoreFocus: true); return true
        case Key.returnKey, Key.enter:
            if tooEarly { return true }
            open(index: nil)
            return true
        case Key.tab: focusURLField(); return true
        case Key.left:
            if !state.browsers.isEmpty { state.selection = max(0, state.selection - 1) }
            return true
        case Key.right:
            if !state.browsers.isEmpty { state.selection = min(state.browsers.count - 1, state.selection + 1) }
            return true
        default: break
        }
        if let digit = Int(chars), (1...9).contains(digit) {
            if tooEarly { return true }
            open(index: digit - 1)
            return true
        }
        return false
    }
}

// MARK: - SwiftUI

struct ChooserView: View {
    @Bindable var state: ChooserState
    /// Sichtbare Bildschirmbreite − 80.
    var maxWidth: CGFloat = 900
    /// Erscheinen animieren (120 ms); `false` für Snapshots.
    var animatesIn = true
    let onOpen: (Int) -> Void
    let onFieldSubmit: () -> Void
    let onFieldEscape: () -> Void
    let onFocusField: () -> Void
    let registerField: (NSTextField) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var appeared = false

    static let tileWidth: CGFloat = 96
    static let tileSpacing: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            urlRow
            tiles
                .padding(.top, 14)
                .padding(.bottom, 12)
            footer
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .frame(width: chooserWidth)
        .background { panelBackground }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(reduceTransparency ? 0 : 0.18), lineWidth: 0.5)
        )
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.985)
        .onAppear {
            guard animatesIn else { appeared = true; return }
            withAnimation(.easeOut(duration: 0.12)) { appeared = true }
        }
    }

    @ViewBuilder private var panelBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        if reduceTransparency {
            shape.fill(Color(nsColor: .windowBackgroundColor))
        } else if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: .rect(cornerRadius: 22))
        } else {
            shape.fill(.regularMaterial)
        }
    }

    // MARK: Kopf

    @ViewBuilder private var header: some View {
        if state.sourceText != nil || state.hint != nil {
            HStack(spacing: 6) {
                if let source = state.sourceText {
                    if let icon = state.sourceIcon {
                        Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                    }
                    Text(source).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let hint = state.hint {
                    Label(hint, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(DS.orange)
                        .lineLimit(2)
                }
            }
            .padding(.bottom, 10)
        }
    }

    // MARK: URL

    private var urlRow: some View {
        ZStack(alignment: .leading) {
            URLTextField(
                text: $state.urlText,
                onSubmit: onFieldSubmit,
                onEscape: onFieldEscape,
                onEditingChanged: { state.isEditingURL = $0 },
                register: registerField
            )
            .opacity(state.isEditingURL ? 1 : 0)
            .accessibilityHidden(!state.isEditingURL)

            if !state.isEditingURL {
                StructuredURL(text: state.urlText)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onFocusField)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("URL \(state.urlText)")
                    .accessibilityHint("Tab oder Klick zum Bearbeiten")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(.default, onFocusField)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.055)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(state.isEditingURL ? Color.accentColor : DS.separator,
                              lineWidth: state.isEditingURL ? 1 : 0.5)
        )
    }

    // MARK: Kacheln

    private var tiles: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Self.tileSpacing) {
                    ForEach(Array(state.browsers.enumerated()), id: \.offset) { index, app in
                        BrowserTile(
                            app: app,
                            number: index < 9 ? index + 1 : nil,
                            selected: index == state.selection,
                            running: state.running[index],
                            missing: state.missing[index]
                        )
                        .id(index)
                        .onTapGesture { onOpen(index) }
                        .onHover { inside in if inside { state.selection = index } }
                        .accessibilityAction { onOpen(index) }
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.09), value: state.selection)
            }
            .scrollDisabled(!overflows)
            .onChange(of: state.selection) { _, index in
                guard overflows else { return }
                withAnimation(.easeOut(duration: 0.09)) { proxy.scrollTo(index) }
            }
        }
        .frame(height: 100)
    }

    // MARK: Fußzeile

    private var footer: some View {
        HStack(spacing: 14) {
            hint("⏎", "Öffnen")
            hint("⌥⏎", "im Hintergrund")
            hint("⇥", "URL bearbeiten")
            hint("⌘C", "kopieren")
            Spacer(minLength: 0)
            hint("esc", "Abbrechen")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.top, 10)
        .overlay(alignment: .top) { Divider() }
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Keycap(key)
            Text(text)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(text): \(key)")
    }

    // MARK: Breite

    private var contentWidth: CGFloat {
        CGFloat(state.browsers.count) * (Self.tileWidth + Self.tileSpacing) - Self.tileSpacing
    }

    private var overflows: Bool { contentWidth > chooserWidth - 40 }

    /// `min(max(n × 104 + 40, 520), 900)`, höchstens sichtbare Bildschirmbreite − 80.
    var chooserWidth: CGFloat {
        let n = CGFloat(state.browsers.count)
        return min(min(max(n * 104 + 40, 520), 900), maxWidth)
    }
}

/// Unfokussierte URL: Schloss bei https, Host halbfett, Rest sekundär; gekürzt wird im Pfad.
private struct StructuredURL: View {
    let text: String

    /// Host wird im Text in der Kodierung gesucht, in der er dort steht (Punycode oder Unicode),
    /// angezeigt in Unicode; der Tooltip nennt bei IDN beide Formen (§27 A4).
    private var parts: (secure: Bool, host: String, hostHelp: String, rest: String)? {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespaces)),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }
        let candidates = [components.encodedHost, components.percentEncodedHost, host, HostName.ascii(host)]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        guard let hostRange = candidates.lazy.compactMap({ text.range(of: $0, options: .caseInsensitive) }).first
        else { return nil }
        let written = String(text[hostRange])
        let unicode = HostName.unicode(written)
        var hostText = HostName.display(written)
        var rest = String(text[hostRange.upperBound...])
        if let port = components.port, rest.hasPrefix(":\(port)") {
            hostText += ":\(port)"
            rest.removeFirst(":\(port)".count)
        }
        let ascii = HostName.ascii(unicode)
        let help = ascii.caseInsensitiveCompare(unicode) == .orderedSame ? hostText : "\(unicode) (\(ascii))"
        return (scheme == "https", hostText, help, rest)
    }

    var body: some View {
        HStack(spacing: 8) {
            if let parts {
                Image(systemName: parts.secure ? "lock" : "globe")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                HStack(spacing: 0) {
                    // Lange Hosts vorne kürzen („…evil.example“), damit die registrierbare Domain
                    // sichtbar bleibt (§26.8); voller Host im Tooltip, die ganze URL für VoiceOver.
                    Text(parts.host)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .layoutPriority(1)
                        .help(parts.hostHelp)
                    Text(parts.rest).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            } else {
                Text(text).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// NSTextField, damit Fokus und Enter/Esc genau steuerbar sind.
struct URLTextField: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onEscape: () -> Void
    var onEditingChanged: (Bool) -> Void = { _ in }
    let register: (NSTextField) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusReportingTextField(string: text)
        field.delegate = context.coordinator
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.lineBreakMode = .byTruncatingMiddle
        field.cell?.usesSingleLineMode = true
        field.placeholderString = "URL"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.onBecomeFirstResponder = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onEditingChanged(true)
        }
        field.setAccessibilityLabel("URL")
        register(field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: URLTextField

        init(parent: URLTextField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onEditingChanged(false)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.text = control.stringValue
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true
            default:
                return false
            }
        }
    }
}

/// Meldet, wenn das Feld Fokus bekommt (Klick oder Tab) – dann wechselt die Anzeige zum Textfeld.
final class FocusReportingTextField: NSTextField {
    var onBecomeFirstResponder: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onBecomeFirstResponder?() }
        return accepted
    }
}
