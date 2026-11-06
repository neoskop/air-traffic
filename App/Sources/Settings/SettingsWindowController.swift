import AirTrafficCore
import AppKit
import SwiftUI

/// Einstellungsfenster mit Toolbar-Tabs (SPEC §15.2). Solange offen: Dock-Icon + Hauptmenü
/// (`.regular`), danach `.accessory`.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    /// Kleinste Inhaltsgröße (ohne Toolbar), bei der Regel-Liste und Editor nicht abgeschnitten werden.
    static let minSize = NSSize(width: 870, height: 560)

    private let model: AppModel
    let tabs: SettingsTabViewController
    private static let frameAutosaveName = "AirTrafficSettings"
    /// Beim Start lag schon ein Fensterrahmen in den Einstellungen (§27 A16).
    private let hasSavedFrame: Bool
    private var didPlaceWindow = false
    /// Nach dem Schließen (z. B. wartendes Update installieren, §17).
    var onClose: (() -> Void)?

    /// `autosavesFrame: false` für Snapshots – der gespeicherte Fensterrahmen bleibt unberührt.
    init(model: AppModel, autosavesFrame: Bool = true) {
        self.model = model
        tabs = SettingsTabViewController(model: model)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.minSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        window.contentViewController = tabs
        window.contentMinSize = Self.minSize
        window.setContentSize(Self.minSize)
        // Nur ohne gespeicherten Rahmen zentrieren (§27 A16).
        hasSavedFrame = autosavesFrame
            && UserDefaults.standard.object(forKey: "NSWindow Frame \(Self.frameAutosaveName)") != nil
        if autosavesFrame { window.setFrameAutosaveName(Self.frameAutosaveName) }
        super.init(window: window)
        window.delegate = self
        tabs.syncFromModel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = MainMenu.make(updates: model.updates)
        if let window, window.isVisible != true {
            ensureMinimumSize()
            // Gespeicherte Position (Autosave) respektieren; sonst nur beim ersten Zeigen zentrieren.
            if !hasSavedFrame, !didPlaceWindow { window.center() }
            didPlaceWindow = true
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Ein gespeicherter Rahmen von vor §13 kann kleiner als die Mindestgröße sein.
    func ensureMinimumSize() {
        guard let window else { return }
        let content = window.contentRect(forFrameRect: window.frame).size
        if content.width < Self.minSize.width || content.height < Self.minSize.height {
            window.setContentSize(NSSize(
                width: max(content.width, Self.minSize.width),
                height: max(content.height, Self.minSize.height)
            ))
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        onClose?()
    }
}

/// `NSTabViewController` im Toolbar-Stil; `model.settingsTab` bleibt die Quelle.
@MainActor
final class SettingsTabViewController: NSTabViewController {
    private let model: AppModel
    private static let order = SettingsTab.allCases

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        // Kein Größen-Animieren je Tab: alle Tabs teilen sich die Fenstergröße.
        transitionOptions = []
        canPropagateSelectedChildViewControllerTitle = false

        for tab in Self.order {
            switch tab {
            case .general: add(GeneralSettingsView(model: model), tab: tab)
            case .browsers: add(BrowsersSettingsView(model: model), tab: tab)
            case .rules: add(RulesSettingsView(model: model), tab: tab)
            case .safari: add(SafariSettingsView(model: model), tab: tab)
            case .cli: add(SettingsPage { CommandLineSettingsSection() }, tab: tab)
            case .updates: add(SettingsPage { UpdatesSettingsSection(updates: model.updates) }, tab: tab)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func add(_ view: some View, tab: SettingsTab) {
        let root = view
            .safeAreaInset(edge: .top, spacing: 0) { ExternalChangeBanner(model: model) }
            .frame(
            minWidth: SettingsWindowController.minSize.width,
            maxWidth: .infinity,
            minHeight: SettingsWindowController.minSize.height,
            maxHeight: .infinity
        )
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = []
        let item = NSTabViewItem(viewController: hosting)
        item.label = tab.label
        item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.label)
        addTabViewItem(item)
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        let tab = Self.order[selectedTabViewItemIndex]
        if model.settingsTab != tab { model.settingsTab = tab }
        updateTitle()
    }

    /// Beobachtet `model.settingsTab` (z. B. Alert „Zu ‚Allgemein‘“) und wählt den Tab.
    func syncFromModel() {
        let tab = withObservationTracking {
            model.settingsTab
        } onChange: { [weak self] in
            Task { @MainActor in self?.syncFromModel() }
        }
        let index = Self.order.firstIndex(of: tab) ?? 0
        if selectedTabViewItemIndex != index { selectedTabViewItemIndex = index }
        updateTitle()
    }

    func updateTitle() {
        guard tabViewItems.indices.contains(selectedTabViewItemIndex) else { return }
        view.window?.title = tabViewItems[selectedTabViewItemIndex].label
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updateTitle()
    }
}


/// Orange Zeile oben im Einstellungsfenster, wenn die Regeln von außen geändert wurden (§24.5).
/// Verschwindet nach 6 s oder bei Klick.
struct ExternalChangeBanner: View {
    let model: AppModel

    /// Mit Zähler wartender Regeln (§26.1) – auch ohne Mitteilungs-Berechtigung sichtbar.
    private var text: String {
        let base = "Regeln wurden von außen geändert und neu geladen."
        let pending = model.pendingRuleCount
        return pending > 0 ? "\(base) \(RuleApproval.countText(pending)) (Tab „Regeln“)." : base
    }

    var body: some View {
        if model.showsExternalChangeNotice {
            Button(action: model.dismissExternalChangeNotice) {
                Label(text, systemImage: "arrow.triangle.2.circlepath")
                    .font(DS.help)
                    .foregroundStyle(DS.orange)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.orange.opacity(DS.tint))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Klicken zum Ausblenden")
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
