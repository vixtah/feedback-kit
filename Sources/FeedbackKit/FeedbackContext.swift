import Foundation

/// The facts sent alongside a report so it can be found and fixed; sent as the flat
/// string map `context`.
public struct FeedbackContext: Equatable, Sendable {
    public var appID: String
    /// `"1.4 (212)"`: CFBundleShortVersionString (CFBundleVersion).
    public var version: String
    /// The build's git SHA from the app's Info.plist key, or `"development"`.
    public var buildSHA: String
    public var osVersion: String
    public var deviceModel: String
    public var screen: String?
    public var reporter: String?
    public var extra: [String: String] = [:]

    public init(appID: String, version: String, buildSHA: String, osVersion: String,
                deviceModel: String, screen: String? = nil, reporter: String? = nil) {
        self.appID = appID
        self.version = version
        self.buildSHA = buildSHA
        self.osVersion = osVersion
        self.deviceModel = deviceModel
        self.screen = screen
        self.reporter = reporter
    }

    /// Builds the context from an Info.plist dictionary (`Bundle.main.infoDictionary` by
    /// default) and the device; the parameters make it testable.
    public static func build(
        appID: String,
        buildSHAInfoKey: String,
        info: [String: Any] = Bundle.main.infoDictionary ?? [:],
        osVersion: String = currentOSVersion(),
        deviceModel: String = currentDeviceModel(),
        screen: String? = nil,
        reporter: String? = nil
    ) -> FeedbackContext {
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let sha = (info[buildSHAInfoKey] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "development"
        return FeedbackContext(appID: appID, version: "\(short) (\(build))", buildSHA: sha,
                               osVersion: osVersion, deviceModel: deviceModel,
                               screen: screen.flatMap { $0.isEmpty ? nil : $0 },
                               reporter: reporter.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// The `context` map: `app`, `version`, `build` (the SHA), `ios`, `device`, and
    /// `screen` / `reporter` when known.
    public var dictionary: [String: String] {
        var out = ["app": appID, "version": version, "build": buildSHA, "ios": osVersion,
                   "device": deviceModel]
        if let screen { out["screen"] = screen }
        if let reporter { out["reporter"] = reporter }
        return out.merging(extra) { original, _ in original }
    }

    /// `"26.0"` or `"26.0.1"`, as `UIDevice.systemVersion` spells it (readable off the
    /// main actor).
    public static func currentOSVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion == 0 ? "\(v.majorVersion).\(v.minorVersion)"
            : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// The hardware model (`"iPhone17,1"`); the simulated model on a simulator.
    public static func currentDeviceModel() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var machine = utsname()
        uname(&machine)
        return withUnsafeBytes(of: &machine.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
