import Foundation

public enum FeedbackSendError: Error, LocalizedError {
    /// Not delivered (offline, timeout, server error); saved as queue entry `entryID` and
    /// retried by ``FeedbackClient/retryQueued()``.
    case queued(entryID: String, underlying: Error)
    /// The server refused it (a 4xx other than 401/403/408/429); retrying won't help, so it was
    /// not queued.
    case rejected(status: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case let .queued(_, underlying):
            return "\(underlying.localizedDescription) It's saved and will be sent next time."
        case let .rejected(status, body):
            return "The server refused it (\(status))\(body.isEmpty ? "" : ": \(body.prefix(200))")."
        }
    }
}

/// Sends reports to `POST {baseURL}/feedback` and keeps the ones that fail on disk.
public actor FeedbackClient {
    public nonisolated let baseURL: URL
    private let headers: @Sendable () -> [String: String]
    private let session: URLSession
    public nonisolated let queue: FeedbackQueue

    public init(baseURL: URL, headers: @escaping @Sendable () -> [String: String] = { [:] },
                session: URLSession = .shared, queue: FeedbackQueue = .standard) {
        self.baseURL = baseURL
        self.headers = headers
        self.session = session
        self.queue = queue
    }

    public init(config: FeedbackConfig, session: URLSession = .shared, queue: FeedbackQueue = .standard) {
        self.init(baseURL: config.baseURL, headers: config.headers, session: session, queue: queue)
    }

    /// Sends `payload`. On a transport failure or a server error it is queued and
    /// ``FeedbackSendError/queued(entryID:underlying:)`` is thrown.
    @discardableResult
    public func send(_ payload: FeedbackPayload) async throws -> FeedbackReceipt {
        do {
            return try await deliver(payload)
        } catch let error as FeedbackSendError {
            throw error
        } catch {
            let id = try queue.enqueue(payload)
            throw FeedbackSendError.queued(entryID: id, underlying: error)
        }
    }

    /// Sends every queued report, oldest first, until one fails to reach the server.
    /// Refused ones are dropped. Answers how many were delivered.
    @discardableResult
    public func retryQueued() async -> Int {
        guard Self.claim(queue.directory) else { return 0 }
        defer { Self.release(queue.directory) }
        var sent = 0
        for id in queue.entries() {
            guard let payload = queue.load(id) else { queue.remove(id); continue }
            do {
                _ = try await deliver(payload)
                queue.remove(id)
                sent += 1
            } catch FeedbackSendError.rejected {
                queue.remove(id)
            } catch {
                break  // still offline; keep the rest for next time
            }
        }
        return sent
    }

    /// The request for `payload`, exposed for tests.
    public func request(for payload: FeedbackPayload) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("feedback"))
        request.httpMethod = "POST"
        request.timeoutInterval = FeedbackLimits.requestTimeout
        for (name, value) in headers() { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try payload.encoded()
        return request
    }

    private func deliver(_ payload: FeedbackPayload) async throws -> FeedbackReceipt {
        let (data, response) = try await session.data(for: try request(for: payload))
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if (200...299).contains(status) {
            let receipt = try JSONDecoder().decode(FeedbackReceipt.self, from: data)
            guard receipt.id > 0 else { throw URLError(.badServerResponse) }
            return receipt
        }
        if (400...499).contains(status), ![401, 403, 408, 429].contains(status) {
            throw FeedbackSendError.rejected(status: status, body: String(decoding: data, as: UTF8.self))
        }
        throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "The server answered \(status)."])
    }

    // One retry pass per queue directory at a time, across client instances.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var retrying: Set<String> = []

    private static func claim(_ dir: URL) -> Bool {
        lock.withLock { retrying.insert(dir.path).inserted }
    }

    private static func release(_ dir: URL) {
        lock.withLock { _ = retrying.remove(dir.path) }
    }
}
