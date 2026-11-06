import AirTrafficCore
import AppKit

/// Löst App-Kurzformen über LaunchServices/NSWorkspace auf (SPEC §24.2). Nur lesend.
struct WorkspaceAppResolver: AppResolving {
    private static let probeURL = URL(string: "https://example.com")!

    func resolveApp(_ query: String) -> AppRef? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Pfad
        if text.contains("/") {
            let path = (text as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return appRef(for: URL(fileURLWithPath: path))
        }
        // Bundle-ID
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: text) {
            return appRef(for: url)
        }
        // Name: installierte Browser, dann übliche Programmordner
        let name = text.hasSuffix(".app") ? String(text.dropLast(4)) : text
        let candidates = NSWorkspace.shared.urlsForApplications(toOpen: Self.probeURL) + Self.applicationsInFolders()
        for url in candidates {
            let ref = appRef(for: url)
            if ref.displayName.caseInsensitiveCompare(name) == .orderedSame
                || url.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(name) == .orderedSame {
                return ref
            }
        }
        return nil
    }

    func isInstalled(_ app: AppRef) -> Bool {
        if let id = app.bundleIdentifier, !id.isEmpty, NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil {
            return true
        }
        return !app.path.isEmpty && FileManager.default.fileExists(atPath: app.path)
    }

    func installedBrowsers() -> [AppRef] {
        var result: [AppRef] = []
        for url in NSWorkspace.shared.urlsForApplications(toOpen: Self.probeURL) {
            let ref = appRef(for: url)
            guard ref.bundleIdentifier != "de.neoskop.AirTraffic",
                  !result.contains(where: { $0.refersToSameApp(as: ref) })
            else { continue }
            result.append(ref)
        }
        return result
    }

    private func appRef(for url: URL) -> AppRef {
        let bundle = Bundle(url: url)
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? AppRef.displayName(forPath: url.path(percentEncoded: false))
        return AppRef(bundleIdentifier: bundle?.bundleIdentifier, path: url.path(percentEncoded: false), displayName: name)
    }

    private static func applicationsInFolders() -> [URL] {
        let fm = FileManager.default
        let dirs = [
            "/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
            fm.homeDirectoryForCurrentUser.appending(path: "Applications").path(percentEncoded: false),
        ]
        return dirs.flatMap { dir in
            ((try? fm.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "app" }
        }
    }
}
