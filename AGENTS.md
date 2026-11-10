# Air Traffic – Hinweise für KI-Agenten und Mitwirkende

Air Traffic ist ein Browser-Verteiler für macOS: als Standardbrowser eingetragen, prüft er jeden Link
gegen Regeln, schreibt ihn bei Bedarf um und öffnet ihn in der passenden App. Überblick und Bedienung
stehen im `README.md`.

## Aufbau

- `Packages/AirTrafficCore/` – die gesamte Logik (Regeln, Umschreiben, Konfiguration, Kommandozeile, MCP,
  KI-Assistent). Nur Foundation und CryptoKit, **kein AppKit**. Hier liegen alle Tests.
- `App/` – AppKit-App mit SwiftUI-Ansichten. Sie hat keine Tests; Logik, die sich testen lässt, gehört in den Core.
- `CLI/` – dünne Hülle um `AgentCLI` und `MCPServer` aus dem Core (Produkt `airtraffic`).
- `SafariExtension/` – Web-Extension. `Packages/AirTrafficCore/Sources/AirTrafficCore/AirTrafficURL.swift`
  wird zusätzlich in dieses Target kompiliert (siehe `project.yml`) und darf deshalb nur Foundation nutzen.
- `project.yml` – XcodeGen; `AirTraffic.xcodeproj` wird erzeugt und nicht eingecheckt.

## Prüfen

```sh
scripts/verify.sh          # Core-Tests + Debug-Build; meldet die Build-Kopie danach wieder ab
scripts/verify.sh --core   # nur die Core-Tests (ohne Xcode)
```

Dasselbe läuft als GitHub-Action bei jedem Push auf `main` und in jedem Pull Request.

**Die gebaute App nie starten** (`open …/Air Traffic.app`): Sie hat dieselbe Bundle-ID wie die installierte
App, nutzt deren echte Konfiguration und den Schlüsselbund, startet die Update-Prüfung und kann sich bei
macOS als Standardbrowser-Kopie vordrängeln. Zum Ausprobieren gibt es die Debug-Schalter `--decide` und
`--snapshot` (README, „Debug-Schalter“) – immer mit `AIRTRAFFIC_CONFIG_PATH` auf eine Test-Datei
(z. B. `docs/demo-config.json`), nie mit der echten Konfiguration.

## Konventionen

- Kommentare, Commit-Nachrichten und alle Texte der Oberfläche auf Deutsch; Bezeichner auf Englisch.
- Swift 6 mit `SWIFT_STRICT_CONCURRENCY: complete`; der Build bleibt ohne Warnungen.
- Tests mit Swift Testing (`@Suite`, `@Test`, `#expect`) unter
  `Packages/AirTrafficCore/Tests/AirTrafficCoreTests/`. Keine Netzwerk- und keine echten KI-Aufrufe in Tests.
- `SafariExtension/Resources/*.js`: String-Literale nur ASCII, Umlaute als `\uXXXX` (ein Test prüft das).
- Logging über `Log` (`App/Sources/Log.swift`). Alles, was URLs oder Teile davon enthalten kann, mit
  `privacy: .private`; öffentlich bleiben nur Bundle-IDs, App-Pfade, Zähler und Regelnamen.
- Das Format von `config.json` bleibt abwärtskompatibel: neue Felder sind optional, `nil` wird nicht geschrieben.

## Was nicht aufgeweicht werden darf

Diese Punkte sind bewusste Sicherheitsentscheidungen (README, „Sicherheit“). Änderungen daran nur auf
ausdrücklichen Wunsch des Maintainers:

- **Freigabe:** Was über `airtraffic` oder MCP an Umschreibungen oder Aktion einer Regel geändert wird (auch
  neue Regeln), wirkt erst nach „Freigeben“ in der App. Es gibt keinen Befehl und kein Tool zum Freigeben,
  und `pendingChange` in Eingaben wird abgelehnt.
- **Schema nach dem Umschreiben:** nur `http`/`https`, das Schema der Original-URL oder eines, das literal am
  Anfang der Vorlage steht. `file:` nur, wenn der Link schon `file:` war. Air Traffic öffnet `airtraffic://`
  nie selbst.
- **Grenzen:** Links über 8192 Zeichen werden nicht gegen Regeln geprüft; reguläre Ausdrücke haben je Link
  zusammen höchstens 500 ms (`MatchLimits`), danach gilt „trifft nicht“. Kein Regex-Abgleich ohne dieses
  Budget, auch nicht in der Oberfläche.
- **Auswahlfenster:** höchstens 5 wartende Links, Tasten wirken erst 300 ms nach dem Erscheinen,
  `prompt=1` höchstens 3-mal in 10 s, dieselbe URL höchstens 3-mal in 5 s an eine App.
- **`airtraffic://`:** `url` nur http/https; `source` wird nur als `com.apple.Safari` übernommen.
- **Kommandozeile und MCP:** kein Netzwerk, kein Schlüsselbund, öffnen keine Links; Browserliste,
  Standardaktion und KI-Einstellungen nur lesend.
- **Debug-Schalter** (`--decide`, `--suggest-regex`, `--snapshot`) nur hinter `#if DEBUG`.

## Nicht anfassen

- `scripts/release.sh` nie mit einer Version aufrufen, außer als Probelauf mit **beiden** Schaltern
  `--dry-run --no-sign` – und auch das nur, wenn die Aufgabe es verlangt. Ohne `--dry-run` veröffentlicht
  das Skript ein Release; mit `--dry-run` allein signiert es und schickt die App zur Notarisierung an Apple.
  Aufrufe ohne Version (z. B. `--help`) sind unkritisch.
- `MARKETING_VERSION` und `CURRENT_PROJECT_VERSION` in `project.yml` sowie `appcast.xml` nicht von Hand
  ändern. Das macht der Release-Lauf des Maintainers.
- Nichts aus `build/`, `.build/` oder `*.xcodeproj` einchecken.
