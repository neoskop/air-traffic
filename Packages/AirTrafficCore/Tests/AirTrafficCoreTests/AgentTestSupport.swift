import Foundation
@testable import AirTrafficCore

/// Feste App-Liste statt LaunchServices.
struct FakeAppResolver: AppResolving {
    static let chrome = AppRef(bundleIdentifier: "com.google.Chrome", path: "/Applications/Google Chrome.app", displayName: "Google Chrome")
    static let safari = AppRef(bundleIdentifier: "com.apple.Safari", path: "/Applications/Safari.app", displayName: "Safari")
    static let figma = AppRef(bundleIdentifier: "com.figma.Desktop", path: "/Applications/Figma.app", displayName: "Figma")

    var apps: [AppRef] = [chrome, safari, figma]

    func resolveApp(_ query: String) -> AppRef? {
        apps.first {
            $0.displayName.caseInsensitiveCompare(query) == .orderedSame
                || $0.bundleIdentifier?.caseInsensitiveCompare(query) == .orderedSame
                || $0.path == query
        }
    }

    func isInstalled(_ app: AppRef) -> Bool {
        apps.contains { $0.refersToSameApp(as: app) }
    }

    func installedBrowsers() -> [AppRef] { [Self.chrome, Self.safari] }
}

/// Temporäre Config-Datei je Test.
struct TempConfig {
    let directory: URL
    let store: ConfigStore

    init(_ config: Config? = TempConfig.sample()) throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "AirTrafficAgentTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = ConfigStore(fileURL: directory.appending(path: "config.json"))
        if let config { try store.save(config) }
    }

    func api(now: @escaping @Sendable () -> Date = { Date() }) -> AgentAPI {
        AgentAPI(store: store, resolver: FakeAppResolver(), now: now)
    }

    func load() throws -> Config { try require(store.load()) }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    static let idA = UUID(uuidString: "11111111-aaaa-4000-8000-000000000001")!
    static let idB = UUID(uuidString: "11111111-bbbb-4000-8000-000000000002")!
    static let idC = UUID(uuidString: "22222222-cccc-4000-8000-000000000003")!

    static func sample() -> Config {
        Config(
            browsers: [FakeAppResolver.safari, FakeAppResolver.chrome],
            rules: [
                Rule(id: idA, name: "GitHub", conditions: [.host(TextMatch(op: .equals, value: "github.com"))],
                     action: .open(FakeAppResolver.chrome), testURL: "https://github.com/acme"),
                Rule(id: idB, name: "Alles Mögliche", action: .prompt(.all)),
                Rule(id: idC, name: "Doppelt", enabled: false, conditions: [.host(TextMatch(op: .equals, value: "a.example"))],
                     action: .prompt(.running)),
            ],
            defaultAction: .prompt(.all)
        )
    }
}

private func require<T>(_ value: T?) throws -> T {
    guard let value else { throw CocoaError(.fileReadNoSuchFile) }
    return value
}
