import Foundation

// Getrennt von `AirTrafficURL.swift`, weil jene Datei auch in die Safari-Erweiterung kompiliert wird
// und dort weder `RuleEngine` noch `Config` existieren.
extension AirTrafficURL.Request {
    /// Einziger erlaubter Wert für `source` – den setzt die eigene Safari-Erweiterung (§26.4).
    public static let trustedSource = "com.apple.Safari"

    /// `source` ist gesetzt, aber nicht erlaubt (wird ignoriert, Warnung im Log).
    public var hasUntrustedSource: Bool {
        guard let source else { return false }
        return source != Self.trustedSource
    }

    /// Kontext für die Regeln: `source` ersetzt die per Absender-PID ermittelte Quell-App – aber nur,
    /// wenn es `com.apple.Safari` ist; andere Werte werden ignoriert (§26.4).
    public func context(from base: LinkContext) -> LinkContext {
        var context = base
        if let source, source == Self.trustedSource { context.sourceBundleIdentifier = source }
        return context
    }
}

extension AirTrafficURL {
    /// Entscheidung für einen `airtraffic://open`-Link (SPEC §20.1, §21.2).
    ///
    /// - Mit `prompt`: Umschreibungen der passenden Regel, danach immer das Auswahlfenster mit allen
    ///   Browsern – unabhängig von `extensionSettings`.
    /// - Sonst mit `applyRules` (Standard): normaler Ablauf (§5); passt keine Regel, gilt
    ///   `fallbackAction` bzw. – wenn nil – die globale Standardaktion.
    /// - Sonst ohne Regeln: Link unverändert, Aktion `fallbackAction` bzw. globale Standardaktion.
    public static func decide(_ request: Request, context: LinkContext, config: Config) -> Decision {
        let ruleContext = request.context(from: context)
        // Zu lang für Regeln (§26.3): Auswahl mit Hinweis, unabhängig von den Erweiterungs-Einstellungen.
        if MatchLimits.isTooLong(request.url) {
            return RuleEngine.decide(url: request.url, context: ruleContext, config: config)
        }
        if request.prompt {
            var decision = RuleEngine.decide(url: request.url, context: ruleContext, config: config)
            decision.action = .prompt(.all)
            return decision
        }

        let settings = config.extensionSettings ?? ExtensionSettings()
        let fallback = settings.fallbackAction ?? config.defaultAction
        guard settings.applyRules else {
            return Decision(originalURL: request.url, finalURL: request.url, matchedRuleID: nil, action: fallback, warnings: [])
        }
        var decision = RuleEngine.decide(url: request.url, context: ruleContext, config: config)
        if decision.matchedRuleID == nil { decision.action = fallback }
        return decision
    }
}
