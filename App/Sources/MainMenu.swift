import AppKit
import Sparkle

/// Minimales Hauptmenü, solange das Einstellungsfenster offen ist (sonst kein ⌘C/⌘V in Textfeldern).
@MainActor
enum MainMenu {
    /// `updates`: Sparkle-Updater für „Nach Updates suchen …“ (§17); fehlt im Snapshot.
    static func make(updates: UpdateController? = nil) -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu(title: "Air Traffic")
        appMenu.addItem(withTitle: "Über Air Traffic", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        if let updates {
            // Ziel ist Sparkles Controller: er aktiviert den Eintrag nur, wenn gerade gesucht werden kann.
            let check = appMenu.addItem(
                withTitle: "Nach Updates suchen …",
                action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                keyEquivalent: ""
            )
            check.target = updates.controller
        }
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Air Traffic ausblenden", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Air Traffic beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, to: main)

        let edit = NSMenu(title: "Bearbeiten")
        edit.addItem(withTitle: "Widerrufen", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Wiederholen", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Ausschneiden", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Kopieren", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Einsetzen", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Alles auswählen", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, to: main)

        let window = NSMenu(title: "Fenster")
        window.addItem(withTitle: "Im Dock ablegen", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Schließen", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(window, to: main)
        NSApp.windowsMenu = window

        return main
    }

    private static func add(_ submenu: NSMenu, to main: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        main.addItem(item)
    }
}
