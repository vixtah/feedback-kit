import Foundation

/// What an app tells FeedbackKit: where reports go, how to authorise them, and what to
/// attach. Closures are read when the reporter opens (on the main actor), so they can
/// return live values such as the current screen or the signed-in name.
public struct FeedbackConfig {
    /// Short app identifier sent in the context, e.g. `"taskmanager"` or `"riftbound"`.
    public var appID: String
    /// The server prefix the feedback routes are mounted under; the report goes to
    /// `{baseURL}/feedback`.
    public var baseURL: URL
    /// Headers for every request, e.g. `["X-App-Token": token]`.
    public var headers: @Sendable () -> [String: String]
    /// What's on screen when the device is shaken, e.g. `"Today"` or `"task 123"`.
    public var screen: () -> String?
    /// Product context, such as Riftbound’s game ID and turn.
    public var context: () -> [String: String]
    /// Optional extra text, e.g. the last two minutes of the app's network log; capped
    /// at ``FeedbackLimits/maxDiagnosticsBytes``.
    public var diagnostics: (() -> String?)?
    /// The Info.plist key holding the build's git SHA (e.g. `"RiftboundBuildSHA"`).
    public var buildSHAInfoKey: String
    /// Who is reporting (an account or display name), when the app knows.
    public var reporter: () -> String?

    public init(
        appID: String,
        baseURL: URL,
        headers: @escaping @Sendable () -> [String: String] = { [:] },
        screen: @escaping () -> String? = { nil },
        diagnostics: (() -> String?)? = nil,
        buildSHAInfoKey: String,
        reporter: @escaping () -> String? = { nil },
        context: @escaping () -> [String: String] = { [:] }
    ) {
        self.appID = appID
        self.baseURL = baseURL
        self.headers = headers
        self.screen = screen
        self.diagnostics = diagnostics
        self.buildSHAInfoKey = buildSHAInfoKey
        self.reporter = reporter
        self.context = context
    }
}

/// The caps both halves of the kit agree on.
public enum FeedbackLimits {
    public static let maxTextLength = 4000
    public static let maxDiagnosticsBytes = 64 * 1024
    public static let jpegQuality: CGFloat = 0.6
    public static let screenshotScale: CGFloat = 1.5
    public static let requestTimeout: TimeInterval = 60
    public static let maxQueued = 20

    /// `text` cut to ``maxTextLength`` characters.
    public static func clampText(_ text: String) -> String {
        text.count > maxTextLength ? String(text.prefix(maxTextLength)) : text
    }

    static let truncationMarker = "[…earlier lines cut]\n"

    /// `text` cut to at most ``maxDiagnosticsBytes`` of UTF-8, keeping the end (the most
    /// recent lines of a log) behind a marker, and never splitting a character.
    public static func truncateDiagnostics(_ text: String, maxBytes: Int = maxDiagnosticsBytes) -> String {
        guard text.utf8.count > maxBytes else { return text }
        let budget = maxBytes - truncationMarker.utf8.count
        let utf8 = text.utf8
        var cut = utf8.index(utf8.endIndex, offsetBy: -max(budget, 0))
        // Step forward to the next character boundary so the result stays valid text.
        while cut < utf8.endIndex, cut.samePosition(in: text) == nil {
            cut = utf8.index(after: cut)
        }
        return truncationMarker + text[cut...]
    }
}
