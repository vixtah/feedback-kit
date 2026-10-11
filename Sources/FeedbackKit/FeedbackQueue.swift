import Foundation

/// Reports that couldn't be sent, one JSON file each, oldest first; kept to
/// ``FeedbackLimits/maxQueued`` by dropping the oldest.
public struct FeedbackQueue: Sendable {
    public let directory: URL
    public let limit: Int

    public init(directory: URL, limit: Int = FeedbackLimits.maxQueued) {
        self.directory = directory
        self.limit = limit
    }

    /// `Application Support/FeedbackKit/queue`.
    public static var standard: FeedbackQueue {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return FeedbackQueue(directory: base.appendingPathComponent("FeedbackKit/queue", isDirectory: true))
    }

    /// Saves `payload`; answers its entry id (the file name).
    @discardableResult
    public func enqueue(_ payload: FeedbackPayload) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A millisecond stamp first, always past the newest entry's, so names sort oldest first.
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let newest = entries().last.flatMap { Int64($0.prefix { $0.isNumber }) } ?? 0
        let id = String(format: "%015lld-%@.json", max(now, newest + 1), UUID().uuidString)
        try payload.encoded().write(to: directory.appendingPathComponent(id), options: .atomic)
        for old in entries().dropLast(limit) { remove(old) }
        return id
    }

    /// Entry ids, oldest first.
    public func entries() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted()
    }

    public func load(_ id: String) -> FeedbackPayload? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(id)) else { return nil }
        return try? JSONDecoder().decode(FeedbackPayload.self, from: data)
    }

    public func remove(_ id: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id))
    }
}
