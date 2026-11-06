import Foundation
@testable import AirTrafficCore

/// Regel aus SPEC §5 (GitHub PR → linear.review) als Test-Fixture.
enum TestRules {
    static let linearApp = AppRef(
        bundleIdentifier: "com.linear",
        path: "/Applications/Linear.app",
        displayName: "Linear"
    )

    /// GitHub-PR-Links als linear.review-URL in Linear öffnen (SPEC §5).
    static func githubPullRequestToLinearReview() -> Rule {
        Rule(
            name: "GitHub PR → Linear Review",
            match: .all,
            conditions: [
                .host(TextMatch(op: .equals, value: "github.com")),
                .path(TextMatch(op: .regex, value: #"^/[^/]+/[^/]+/pull/\d+"#)),
            ],
            rewrites: [
                Rewrite(
                    pattern: #"^https://github\.com/([^/]+)/([^/]+)/pull/(\d+)(.*)$"#,
                    template: "https://linear.review/$1/$2/pull/$3$4"
                ),
            ],
            action: .open(linearApp)
        )
    }
}
