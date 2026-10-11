import Foundation

public enum FeedbackKind: String, Codable, CaseIterable, Sendable {
    case bug, idea
}

/// The JSON body of `POST {baseURL}/feedback`:
/// `{kind, text, context, diagnostics?, screenshot?}`, `screenshot` a base64 JPEG.
public struct FeedbackPayload: Codable, Equatable, Sendable {
    public var requestID: String?
    public var kind: FeedbackKind
    public var text: String
    public var context: [String: String]
    public var diagnostics: String?
    public var screenshot: String?

    /// Trims and caps `text`, caps `diagnostics` (dropping it when empty) and base64s the
    /// JPEG.
    public init(kind: FeedbackKind, text: String, context: [String: String],
                diagnostics: String? = nil, screenshotJPEG: Data? = nil,
                requestID: String = UUID().uuidString) {
        self.requestID = requestID
        self.kind = kind
        self.text = FeedbackLimits.clampText(text.trimmingCharacters(in: .whitespacesAndNewlines))
        self.context = context
        if let diagnostics, !diagnostics.isEmpty {
            self.diagnostics = FeedbackLimits.truncateDiagnostics(diagnostics)
        }
        self.screenshot = screenshotJPEG?.base64EncodedString()
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self)
    }
}

/// The server's answer to a report: its id.
public struct FeedbackReceipt: Decodable, Equatable, Sendable {
    public let id: Int
}
