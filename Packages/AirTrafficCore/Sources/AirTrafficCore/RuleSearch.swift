import Foundation

/// Volltextsuche über Regeln (SPEC §13.2): Name, Bedingungswerte, Umschreibungen, Ziel-App.
public enum RuleSearch {
    public static func matches(_ rule: Rule, query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return true }
        let haystack = searchableTexts(rule)
        // Jedes Suchwort muss irgendwo vorkommen.
        return terms.allSatisfy { term in
            haystack.contains { $0.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    public static func filter(_ rules: [Rule], query: String) -> [Rule] {
        rules.filter { matches($0, query: query) }
    }

    static func searchableTexts(_ rule: Rule) -> [String] {
        var texts = [rule.name]
        for condition in rule.conditions {
            switch condition {
            case .url(let m), .host(let m), .path(let m): texts.append(m.value)
            case .sourceApp(let bundleIdentifier, _): texts.append(bundleIdentifier)
            case .modifiers, .linkType: break
            }
        }
        for rewrite in rule.rewrites {
            texts.append(rewrite.pattern)
            texts.append(rewrite.template)
        }
        switch rule.action {
        case .open(let app): texts += [app.displayName, app.path, app.bundleIdentifier ?? ""]
        case .openFirstRunning(let fallback?): texts += [fallback.displayName, fallback.path]
        case .openFirstRunning(nil), .prompt: break
        }
        return texts
    }
}
