import Foundation
import Testing
@testable import AirTrafficCore

@Suite("Regel-Referenzen (§24.3)")
struct RuleRefTests {
    let rules = TempConfig.sample().rules

    @Test func fullUUIDInAnyCase() throws {
        #expect(try RuleRef.resolve(TempConfig.idB.uuidString, in: rules) == 1)
        #expect(try RuleRef.resolve(TempConfig.idB.uuidString.lowercased(), in: rules) == 1)
    }

    @Test func uniquePrefix() throws {
        #expect(try RuleRef.resolve("222222", in: rules) == 2)
        #expect(try RuleRef.resolve("11111111-AAAA", in: rules) == 0)
    }

    @Test func prefixTooShortOrAmbiguous() {
        #expect(throws: AgentError.notFound("22222")) { try RuleRef.resolve("22222", in: rules) }
        #expect {
            try RuleRef.resolve("111111", in: rules)
        } throws: { error in
            guard case AgentError.ambiguous(_, let candidates) = error else { return false }
            return candidates.count == 2 && candidates[0].hasPrefix("#1 GitHub") && candidates[1].hasPrefix("#2 Alles Mögliche")
        }
    }

    @Test func position() throws {
        #expect(try RuleRef.resolve("#3", in: rules) == 2)
        #expect(throws: AgentError.notFound("#4")) { try RuleRef.resolve("#4", in: rules) }
        #expect(throws: AgentError.notFound("#0")) { try RuleRef.resolve("#0", in: rules) }
    }

    @Test func exactName() throws {
        #expect(try RuleRef.resolve("Alles Mögliche", in: rules) == 1)
        #expect(throws: AgentError.notFound("github")) { try RuleRef.resolve("github", in: rules) }
    }

    @Test func duplicateNamesAreAmbiguous() {
        var rules = rules
        rules[0].name = "Doppelt"
        #expect {
            try RuleRef.resolve("Doppelt", in: rules)
        } throws: { error in
            guard case AgentError.ambiguous(_, let candidates) = error else { return false }
            return candidates.count == 2
        }
    }
}

@Suite("Regel-Eingabe und Validierung (§24.2, §24.4)")
struct RuleInputTests {
    let input = RuleInput(resolver: FakeAppResolver(), browsers: [FakeAppResolver.safari])

    @Test func shortFormAppByNameBundleIDAndPath() throws {
        for app in ["Google Chrome", "com.google.Chrome", "/Applications/Google Chrome.app", "google chrome"] {
            let output = try input.makeRule(from: ["name": "X", "action": ["type": "open", "app": .string(app)]])
            #expect(output.rule.action == .open(FakeAppResolver.chrome), "\(app)")
        }
    }

    @Test func browserListWinsForShortForm() throws {
        let listed = AppRef(bundleIdentifier: "com.apple.Safari", path: "/Applications/Safari.app", displayName: "Safari")
        let output = try input.makeRule(from: ["name": "X", "action": ["type": "openFirstRunning", "fallback": "safari"]])
        #expect(output.rule.action == .openFirstRunning(fallback: listed))
    }

    @Test func missingIDGetsNewUUIDAndDefaults() throws {
        let a = try input.makeRule(from: ["name": "X", "action": ["type": "prompt"]])
        let b = try input.makeRule(from: ["name": "X", "action": ["type": "prompt"]])
        #expect(a.rule.id != b.rule.id)
        #expect(a.rule.enabled && a.rule.match == .all && a.rule.action == .prompt(.all))
        #expect(a.position == nil)
    }

    @Test func keepsGivenIDAndPosition() throws {
        let output = try input.makeRule(from: [
            "id": .string(TempConfig.idA.uuidString), "name": "X", "position": 2, "action": ["type": "prompt"],
        ])
        #expect(output.rule.id == TempConfig.idA)
        #expect(output.position == 2)
    }

    @Test func unknownFieldsNameTheField() {
        #expect {
            try input.makeRule(from: [
                "name": "X", "colour": "red",
                "conditions": [["type": "host", "op": "equals", "value": "a", "flags": "i"]],
                "action": ["type": "open", "app": "Safari", "newWindow": true],
            ])
        } throws: { error in
            guard case AgentError.invalid(let issues) = error else { return false }
            let fields = Set(issues.map(\.field))
            return fields == ["colour", "conditions[0].flags", "action.newWindow"]
        }
    }

    @Test func validationErrorsNameFieldAndReason() {
        #expect {
            try input.makeRule(from: [
                "name": "  ",
                "conditions": [["type": "url", "op": "regex", "value": "(unclosed"]],
                "rewrites": [["pattern": "[", "template": "$1"]],
                "action": ["type": "prompt"],
            ])
        } throws: { error in
            guard case AgentError.invalid(let issues) = error else { return false }
            return Set(issues.map(\.field)) == ["name", "conditions[0].value", "rewrites[0].pattern"]
                && issues.allSatisfy { !$0.reason.isEmpty }
        }
    }

    @Test func invalidEnumsAndTypes() {
        #expect {
            try input.makeRule(from: [
                "name": "X", "enabled": "ja", "match": "some",
                "conditions": [["type": "host", "op": "is", "value": 3], ["type": "modifiers", "modifiers": ["hyper"]]],
                "action": ["type": "prompt", "scope": "none"],
            ])
        } throws: { error in
            guard case AgentError.invalid(let issues) = error else { return false }
            return Set(issues.map(\.field)) == [
                "enabled", "match", "conditions[0].op", "conditions[0].value", "conditions[1].modifiers[0]", "action.scope",
            ]
        }
    }

    @Test func allProblemsAtOnce() {
        #expect {
            try input.makeRule(from: [
                "name": "", "conditions": [["type": "url", "op": "regex", "value": "("]],
                "action": ["type": "open", "app": "Netscape"],
            ])
        } throws: { error in
            guard case AgentError.invalid(let issues) = error else { return false }
            return Set(issues.map(\.field)) == ["name", "conditions[0].value", "action.app"]
        }
    }

    @Test func unresolvableAppIsError() {
        #expect {
            try input.makeRule(from: ["name": "X", "action": ["type": "open", "app": "Netscape"]])
        } throws: { error in
            guard case AgentError.invalid(let issues) = error else { return false }
            return issues.map(\.field) == ["action.app"] && issues[0].reason.contains("Netscape")
        }
    }

    @Test func missingActionIsError() {
        #expect(throws: AgentError.invalid([FieldIssue("action", "fehlt")])) {
            try input.makeRule(from: ["name": "X"])
        }
    }

    @Test func missingAppPathIsWarningOnly() throws {
        let output = try input.makeRule(from: [
            "name": "X",
            "action": ["type": "open", "app": ["bundleIdentifier": "org.example.gone", "path": "/Applications/Gone.app"]],
        ])
        #expect(output.rule.action == .open(AppRef(bundleIdentifier: "org.example.gone", path: "/Applications/Gone.app", displayName: "Gone")))
        #expect(output.warnings.count == 1 && output.warnings[0].hasPrefix("action.app"))
    }

    @Test func notAnObject() {
        #expect(throws: AgentError.self) { try input.makeRule(from: ["a", "b"]) }
    }

    @Test func patchReplacesFieldsAndWholeLists() throws {
        let rule = TempConfig.sample().rules[0]
        let output = try input.apply(patch: [
            "name": "Neu",
            "conditions": [["type": "url", "op": "contains", "value": "x"]],
            "testURL": nil,
        ], to: rule)
        #expect(output.rule.id == rule.id)
        #expect(output.rule.name == "Neu")
        #expect(output.rule.conditions == [.url(TextMatch(op: .contains, value: "x"))])
        #expect(output.rule.action == rule.action)
        #expect(output.rule.testURL == nil)
    }

    @Test func patchCannotChangeID() {
        let rule = TempConfig.sample().rules[0]
        #expect(throws: AgentError.invalid([FieldIssue("id", "kann nicht geändert werden")])) {
            try input.apply(patch: ["id": .string(UUID().uuidString)], to: rule)
        }
    }
}
