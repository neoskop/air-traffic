import AirTrafficCore
import AppKit
import UniformTypeIdentifiers

/// NSWorkspace-Helfer rund um `AppRef`.
@MainActor
enum Apps {
    static let probeURL = URL(string: "https://example.com")!

    /// Erst Bundle-ID, sonst Pfad.
    static func url(for ref: AppRef) -> URL? {
        if let id = ref.bundleIdentifier, !id.isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return url
        }
        guard !ref.path.isEmpty, FileManager.default.fileExists(atPath: ref.path) else { return nil }
        return URL(fileURLWithPath: ref.path)
    }

    static func appRef(for url: URL) -> AppRef {
        let bundle = Bundle(url: url)
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? AppRef.displayName(forPath: url.path(percentEncoded: false))
        return AppRef(
            bundleIdentifier: bundle?.bundleIdentifier,
            path: url.path(percentEncoded: false),
            displayName: name
        )
    }

    // MARK: Cache (§27 A8, A9)

    /// Icons und Namen je Bundle-ID bzw. Pfad; dieselbe `NSImage`-Instanz für dieselbe App.
    /// Geleert, wenn Apps starten oder enden (dann können sich Pfad und Name ändern).
    private static var iconCache: [String: NSImage] = [:]
    private static var bundleIconCache: [String: NSImage?] = [:]
    private static var nameCache: [String: String?] = [:]
    private static var runningAppsCache: [AppRef]?
    private static var observers: [NSObjectProtocol] = []

    private static func observeWorkspaceIfNeeded() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { invalidateCaches() }
            })
        }
    }

    static func invalidateCaches() {
        iconCache.removeAll()
        bundleIconCache.removeAll()
        nameCache.removeAll()
        runningAppsCache = nil
    }

    private static func cacheKey(_ ref: AppRef) -> String {
        if let id = ref.bundleIdentifier, !id.isEmpty { return "id:" + id.lowercased() }
        return "path:" + ref.path
    }

    static func icon(for ref: AppRef) -> NSImage {
        observeWorkspaceIfNeeded()
        let key = cacheKey(ref)
        if let cached = iconCache[key] { return cached }
        let icon = url(for: ref).map { NSWorkspace.shared.icon(forFile: $0.path(percentEncoded: false)) }
            ?? NSWorkspace.shared.icon(for: .applicationBundle)
        iconCache[key] = icon
        return icon
    }

    static func icon(forBundleIdentifier id: String) -> NSImage? {
        observeWorkspaceIfNeeded()
        let key = id.lowercased()
        if let cached = bundleIconCache[key] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            .map { NSWorkspace.shared.icon(forFile: $0.path(percentEncoded: false)) }
        bundleIconCache[key] = icon
        return icon
    }

    static func displayName(forBundleIdentifier id: String) -> String? {
        observeWorkspaceIfNeeded()
        let key = id.lowercased()
        if let cached = nameCache[key] { return cached }
        let name: String? = if let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first,
                               let localized = running.localizedName {
            localized
        } else {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { appRef(for: $0).displayName }
        }
        nameCache[key] = name
        return name
    }

    /// Ob die URL auf Air Traffic selbst zeigt (Schleifenschutz).
    static func isSelf(_ url: URL) -> Bool {
        if url.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL { return true }
        guard let ownID = Bundle.main.bundleIdentifier else { return false }
        return Bundle(url: url)?.bundleIdentifier == ownID
    }

    static func isSelf(_ ref: AppRef) -> Bool {
        if let id = ref.bundleIdentifier, id == Bundle.main.bundleIdentifier { return true }
        return url(for: ref).map(isSelf) ?? false
    }

    /// Browser, die https öffnen können (ohne Air Traffic); der aktuelle Standard zuerst.
    static func installedBrowsers() -> [AppRef] {
        var urls = NSWorkspace.shared.urlsForApplications(toOpen: probeURL)
        if let current = NSWorkspace.shared.urlForApplication(toOpen: probeURL),
           let index = urls.firstIndex(of: current) {
            urls.insert(urls.remove(at: index), at: 0)
        }
        var result: [AppRef] = []
        for url in urls where !isSelf(url) {
            let ref = appRef(for: url)
            if !result.contains(where: { $0.refersToSameApp(as: ref) }) { result.append(ref) }
        }
        return result
    }

    static func runningBundleIdentifiers() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    static func isRunning(_ ref: AppRef) -> Bool {
        let running = NSWorkspace.shared.runningApplications
        if let id = ref.bundleIdentifier {
            return running.contains { $0.bundleIdentifier?.caseInsensitiveCompare(id) == .orderedSame }
        }
        let path = (ref.path as NSString).standardizingPath
        return running.contains { $0.bundleURL?.standardizedFileURL.path(percentEncoded: false) == path }
    }

    static var isAirTrafficDefaultBrowser: Bool {
        guard let current = NSWorkspace.shared.urlForApplication(toOpen: probeURL) else { return false }
        return isSelf(current)
    }

    /// Laufende Apps mit Oberfläche (für Quell-App-Picker); zwischengespeichert bis eine App
    /// startet oder endet (§27 A9).
    static func runningRegularApps() -> [AppRef] {
        observeWorkspaceIfNeeded()
        if let cached = runningAppsCache { return cached }
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleURL != nil }
            .compactMap { $0.bundleURL.map(appRef(for:)) }
            .filter { $0.bundleIdentifier != nil && !isSelf($0) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        runningAppsCache = apps
        return apps
    }

    private static var installedAppsCache: [AppRef]?

    /// Apps aus /Applications, /System/Applications und ~/Applications (oberste Ebene).
    static func installedApps() -> [AppRef] {
        if let cached = installedAppsCache { return cached }
        let fm = FileManager.default
        let dirs = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            fm.homeDirectoryForCurrentUser.appending(path: "Applications"),
        ]
        var result: [AppRef] = []
        for dir in dirs {
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for item in items where item.pathExtension == "app" {
                let ref = appRef(for: item)
                if ref.bundleIdentifier != nil, !result.contains(where: { $0.refersToSameApp(as: ref) }) {
                    result.append(ref)
                }
            }
        }
        result.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        installedAppsCache = result
        return result
    }

    /// NSOpenPanel für eine `.app` (Ordner /Applications).
    static func chooseApplication(message: String = "App auswählen") -> AppRef? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.prompt = "Auswählen"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return appRef(for: url)
    }
}

extension ModifierSet {
    init(_ flags: NSEvent.ModifierFlags) {
        var set: ModifierSet = []
        if flags.contains(.command) { set.insert(.command) }
        if flags.contains(.option) { set.insert(.option) }
        if flags.contains(.control) { set.insert(.control) }
        if flags.contains(.shift) { set.insert(.shift) }
        self = set
    }
}
