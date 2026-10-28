import Foundation

public enum AppBuildInfo {
    public static var displayValue: String {
        displayValue(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                     build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    }

    public static func displayValue(version: String?, build: String?) -> String {
        guard let version, !version.isEmpty else { return "—" }
        guard let build, !build.isEmpty else { return version }
        return "\(version) (\(build))"
    }
}
