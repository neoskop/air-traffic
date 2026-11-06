import AppKit

// Schreiben in eine Pipe, deren Leser weg ist (KI-CLI, Debug-Ausgabe), darf die App nicht beenden (§27 K1).
signal(SIGPIPE, SIG_IGN)

// Debug-Schalter (`--decide`, `--suggest-regex`, `--snapshot`) gibt es nur im Debug-Build (§26.5).
// Der Release-Build ignoriert sie und startet normal.
#if DEBUG
// `--decide <url> [--source <bundleID>]` → Decision als JSON, kein Fenster.
if CommandLine.arguments.contains(DecideCommand.flag) {
    exit(DecideCommand.run(arguments: CommandLine.arguments))
}

// `--suggest-regex "<Beschreibung>" --example <url> … [--mode rewrite|condition] [--provider openrouter|claude|codex]`
// → geprüfter Regex-Vorschlag als JSON, kein Fenster.
if CommandLine.arguments.contains(SuggestRegexCommand.flag) {
    Task { @MainActor in
        exit(await SuggestRegexCommand.run(arguments: CommandLine.arguments))
    }
    dispatchMain()
}

// `--snapshot <dir>` → PNGs von Chooser und Einstellungen (hell/dunkel), kein sichtbares Fenster.
if CommandLine.arguments.contains(SnapshotCommand.flag) {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    Task { @MainActor in
        exit(await SnapshotCommand.run(arguments: CommandLine.arguments))
    }
    app.run()
}
#endif

let app = NSApplication.shared
// `NSApplication.delegate` ist weak – die Instanz lebt als globale Konstante.
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.run()
