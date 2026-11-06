import Foundation

/// Kompakte Beschreibung des Regelformats für Agenten (`airtraffic schema`, MCP `describe_rule_format`, §24.2).
public enum RuleFormat {
    /// Host → App.
    public static let exampleHost: JSONValue = [
        "name": "Figma in der App",
        "conditions": [["type": "host", "op": "endsWith", "value": "figma.com"]],
        "action": ["type": "open", "app": "Figma"],
        "testURL": "https://www.figma.com/file/abc123/Entwurf",
    ]

    /// Regex-Umschreibung (GitHub-PR → Review-Tool).
    public static let exampleRewrite: JSONValue = [
        "name": "Pull Requests im Review-Tool",
        "match": "all",
        "conditions": [
            ["type": "host", "op": "equals", "value": "github.com"],
            ["type": "path", "op": "regex", "value": "^/acme/[^/]+/pull/\\d+"],
        ],
        "rewrites": [[
            "pattern": "^https://github\\.com/acme/([^/]+)/pull/(\\d+).*$",
            "template": "https://review.example.com/acme/$1/$2",
        ]],
        "action": ["type": "open", "app": "com.google.Chrome"],
        "testURL": "https://github.com/acme/webshop/pull/42/files",
    ]

    /// Quell-App → Auswahl.
    public static let exampleSourceApp: JSONValue = [
        "name": "Links aus Slack: Auswahl zeigen",
        "conditions": [["type": "sourceApp", "bundleIdentifier": "com.tinyspeck.slackmacgap"]],
        "action": ["type": "prompt", "scope": "running"],
    ]

    public static var json: JSONValue {
        [
            "rule": [
                "id": "UUID; fehlt beim Anlegen → neu",
                "name": "Text, nicht leer",
                "enabled": "true|false (Standard true)",
                "match": "all|any|none – wie Bedingungen verknüpft werden (Standard all; keine Bedingungen = passt immer)",
                "conditions": "Liste von Bedingungen",
                "rewrites": "Liste von Umschreibungen, nacheinander angewendet",
                "action": "was passiert, wenn die Regel greift",
                "testURL": "optional: Beispiel-URL für die Prüfung nach jeder Änderung",
                "position": "nur Ausgabe/Eingabe für Agenten: 1-basiert, oben gewinnt",
            ],
            "conditionTypes": [
                "url": "ganze URL als Text: {type, op, value, caseSensitive?}",
                "host": "Host, z. B. github.com: {type, op, value, caseSensitive?}",
                "path": "Pfad, z. B. /acme/pull/1: {type, op, value, caseSensitive?}",
                "sourceApp": "App, aus der der Link kommt: {type, bundleIdentifier, negated?}",
                "modifiers": "gedrückte Tasten (genau diese Menge): {type, modifiers: [command|option|control|shift], negated?}",
                "linkType": "{type, linkType: web|file}",
            ],
            "textOperators": .array(TextOp.allCases.map { .string($0.rawValue) }),
            "textOperatorNotes": "wildcard: * und ? über den ganzen Text; regex: NSRegularExpression, sucht irgendwo (mit ^…$ verankern); caseSensitive Standard false",
            "matchModes": ["all", "any", "none"],
            "actions": [
                "open": "{type: open, app} – app als Name („Google Chrome“), Bundle-ID („com.google.Chrome“), Pfad oder Objekt {bundleIdentifier, path, displayName}",
                "openFirstRunning": "{type: openFirstRunning, fallback?} – oberster laufender Browser der Liste, sonst fallback",
                "prompt": "{type: prompt, scope: all|running} – Auswahlfenster",
            ],
            "rewrites": "{pattern, template, caseSensitive?}: Regex auf die ganze URL; template mit $1, $2 … für Gruppen; ersetzt nur, wenn pattern trifft; Ergebnis muss eine gültige URL mit erlaubtem Schema sein (siehe schemes)",
            "order": "Regeln werden von oben nach unten geprüft; die erste aktive passende Regel gewinnt. Wenn keine passt: Standardaktion (get_settings).",
            "approval": "Neue Regeln und Änderungen an rewrites oder action warten auf Freigabe durch den Nutzer in der App (pendingApproval: true, Feld pendingChange) und wirken bis dahin nicht – geänderte Regeln gelten im zuletzt freigegebenen Stand. Name, conditions, testURL, position und enabled wirken sofort. Agenten können nicht freigeben; pendingChange in Eingaben ist ein Fehler.",
            "schemes": "Nach den Umschreibungen ist nur http/https erlaubt, das Schema der Original-URL oder ein Schema, das literal am Anfang der Vorlage steht (z. B. linear://…). Sonst bleibt die Original-URL.",
            "examples": [exampleHost, exampleRewrite, exampleSourceApp],
        ]
    }

    public static var text: String {
        """
        Regelformat von Air Traffic (gleiches JSON wie config.json)

        Regel: {id?, name, enabled?, match?, conditions?, rewrites?, action, testURL?}
          - Oben gewinnt: die erste aktive Regel, deren Bedingungen passen. Sonst die Standardaktion.
          - match: all (Standard) | any | none. Keine Bedingungen = passt immer.
          - id fehlt beim Anlegen → neue UUID. Ausgaben enthalten zusätzlich position (1-basiert).
          - Unbekannte Felder sind ein Fehler.

        Bedingungen (conditions[]):
          url | host | path   {type, op, value, caseSensitive?}
                              op: \(TextOp.allCases.map(\.rawValue).joined(separator: ", "))
                              wildcard: * und ? über den ganzen Text; regex: sucht irgendwo, mit ^…$ verankern
          sourceApp           {type, bundleIdentifier, negated?}
          modifiers           {type, modifiers: [command, option, control, shift], negated?} – genau diese Tasten
          linkType            {type, linkType: web | file}

        Umschreibungen (rewrites[], nacheinander):
          {pattern, template, caseSensitive?} – Regex auf die ganze URL, template mit $1, $2 …;
          ersetzt nur, wenn pattern trifft. Ergebnis-Schema: http/https, das der Original-URL oder
          literal am Anfang der Vorlage (z. B. linear://…) – sonst bleibt die Original-URL.

        Freigabe:
          Neue Regeln und Änderungen an rewrites oder action warten auf Freigabe durch den Nutzer in
          Air Traffic (pendingApproval) und wirken bis dahin nicht; geänderte Regeln gelten im zuletzt
          freigegebenen Stand. Name, conditions, testURL, Position und an/aus wirken sofort.
          Agenten können nicht freigeben; pendingChange in Eingaben wird abgelehnt.

        Aktion (action):
          {type: "open", app}                 app = Name, Bundle-ID, Pfad oder {bundleIdentifier, path, displayName}
          {type: "openFirstRunning", fallback?}
          {type: "prompt", scope: "all" | "running"}

        Beispiel 1 – Host → App:
        \(exampleHost.jsonString(pretty: true))

        Beispiel 2 – Regex-Umschreibung:
        \(exampleRewrite.jsonString(pretty: true))

        Beispiel 3 – Quell-App → Auswahl:
        \(exampleSourceApp.jsonString(pretty: true))
        """
    }
}
