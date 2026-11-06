import Foundation

/// Version aus der eingebetteten Info.plist des Tools, sonst aus der umgebenden App.
enum ToolVersion {
    static var current: String {
        if let version = version(of: Bundle.main.infoDictionary) { return version }
        // …/Air Traffic.app/Contents/Helpers/airtraffic → …/Air Traffic.app/Contents/Info.plist
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let plist = executable.deletingLastPathComponent().deletingLastPathComponent().appending(path: "Info.plist")
        if let dict = NSDictionary(contentsOf: plist) as? [String: Any], let version = version(of: dict) { return version }
        return "unbekannt"
    }

    private static func version(of info: [String: Any]?) -> String? {
        guard let short = info?["CFBundleShortVersionString"] as? String, !short.isEmpty else { return nil }
        if let build = info?["CFBundleVersion"] as? String, !build.isEmpty { return "\(short) (\(build))" }
        return short
    }
}
