import SwiftUI
import UIKit
import XCTest
@testable import FeedbackKit

/// Answers every request from `StubProtocol.handler` and records it; nothing reaches the
/// network. An unset handler fails like an offline device.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    private static let lock = NSLock()

    static func reset() {
        lock.withLock { handler = nil; requests = [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var request = request
        // URLSession moves the body to a stream; read it back for assertions.
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            request.httpBody = data
        }
        let handler = Self.lock.withLock { Self.requests.append(request); return Self.handler }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let (status, body) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class FeedbackKitTests: XCTestCase {
    var queueDir: URL!
    var session: URLSession!
    let base = URL(string: "https://example.invalid/api/app")!

    override func setUp() {
        super.setUp()
        StubProtocol.reset()
        queueDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FeedbackKitTests-\(UUID().uuidString)", isDirectory: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: queueDir)
        StubProtocol.reset()
        super.tearDown()
    }

    func makeClient(limit: Int = FeedbackLimits.maxQueued) -> FeedbackClient {
        FeedbackClient(baseURL: base, headers: { ["X-App-Token": "secret"] }, session: session,
                       queue: FeedbackQueue(directory: queueDir, limit: limit))
    }

    func payload(_ text: String = "it broke") -> FeedbackPayload {
        FeedbackPayload(kind: .bug, text: text, context: ["app": "test"])
    }

    func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: payload

    func testPayloadEncodingWithEverything() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        let p = FeedbackPayload(kind: .idea, text: "  dark mode \n", context: ["screen": "Today"],
                                diagnostics: "GET /x 200", screenshotJPEG: jpeg)
        let body = try json(p.encoded())
        XCTAssertEqual(Set(body.keys), ["kind", "text", "context", "diagnostics", "screenshot"])
        XCTAssertEqual(body["kind"] as? String, "idea")
        XCTAssertEqual(body["text"] as? String, "dark mode")
        XCTAssertEqual(body["context"] as? [String: String], ["screen": "Today"])
        XCTAssertEqual(body["diagnostics"] as? String, "GET /x 200")
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(body["screenshot"] as? String)), jpeg)
    }

    func testPayloadOmitsAbsentOptionals() throws {
        let p = FeedbackPayload(kind: .bug, text: "x", context: [:], diagnostics: "")
        XCTAssertEqual(Set(try json(p.encoded()).keys), ["kind", "text", "context"])
    }

    func testTextIsCappedAt4000Characters() {
        let p = FeedbackPayload(kind: .bug, text: String(repeating: "é", count: 4100), context: [:])
        XCTAssertEqual(p.text.count, 4000)
        XCTAssertEqual(FeedbackLimits.clampText("short"), "short")
    }

    func testDiagnosticsTruncatedTo64KBKeepingTheEnd() {
        let small = "line\n"
        XCTAssertEqual(FeedbackLimits.truncateDiagnostics(small), small)

        let log = (0..<20_000).map { "request \($0) ✓" }.joined(separator: "\n")
        XCTAssertGreaterThan(log.utf8.count, 64 * 1024)
        let cut = FeedbackLimits.truncateDiagnostics(log)
        XCTAssertLessThanOrEqual(cut.utf8.count, 64 * 1024)
        XCTAssertGreaterThan(cut.utf8.count, 64 * 1024 - 8)
        XCTAssertTrue(cut.hasPrefix(FeedbackLimits.truncationMarker))
        XCTAssertTrue(cut.hasSuffix("request 19999 ✓"))

        // Multi-byte characters are never split.
        let emoji = String(repeating: "😀", count: 20)  // 80 bytes
        let short = FeedbackLimits.truncateDiagnostics(emoji, maxBytes: 50)
        XCTAssertLessThanOrEqual(short.utf8.count, 50)
        XCTAssertTrue(short.dropFirst(FeedbackLimits.truncationMarker.count).allSatisfy { $0 == "😀" })

        let p = FeedbackPayload(kind: .bug, text: "x", context: [:], diagnostics: log)
        XCTAssertEqual(p.diagnostics, cut)
    }

    func testScreenshotJPEG() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        let jpeg = try XCTUnwrap(FeedbackScreenshot.jpeg(image))
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8])
        XCTAssertEqual(FeedbackLimits.jpegQuality, 0.6)
        XCTAssertEqual(FeedbackLimits.screenshotScale, 1.5)
    }

    // MARK: context

    func testContextFromInfoPlist() {
        let info: [String: Any] = ["CFBundleShortVersionString": "1.4", "CFBundleVersion": "212",
                                   "MyBuildSHA": "4ecfbd1a"]
        let c = FeedbackContext.build(appID: "taskmanager", buildSHAInfoKey: "MyBuildSHA", info: info,
                                      osVersion: "26.0", deviceModel: "iPhone17,1",
                                      screen: "task 123", reporter: "vic")
        XCTAssertEqual(c.dictionary, ["app": "taskmanager", "version": "1.4 (212)", "build": "4ecfbd1a",
                                      "ios": "26.0", "device": "iPhone17,1", "screen": "task 123",
                                      "reporter": "vic"])
    }

    func testContextDefaultsWhenUnknown() {
        let c = FeedbackContext.build(appID: "a", buildSHAInfoKey: "Missing", info: [:],
                                      osVersion: "26.0", deviceModel: "x", screen: "", reporter: nil)
        XCTAssertEqual(c.dictionary, ["app": "a", "version": "? (?)", "build": "development",
                                      "ios": "26.0", "device": "x"])
        XCTAssertFalse(FeedbackContext.currentDeviceModel().isEmpty)
        XCTAssertTrue(FeedbackContext.currentOSVersion().first?.isNumber ?? false)
    }

    // MARK: client

    func testSendPostsJSONWithHeaders() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"id": 42}"#.utf8)) }
        let receipt = try await makeClient().send(payload())
        XCTAssertEqual(receipt.id, 42)
        let request = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://example.invalid/api/app/feedback")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-App-Token"), "secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(try json(XCTUnwrap(request.httpBody))["text"] as? String, "it broke")
        let built = try await makeClient().request(for: payload())
        XCTAssertEqual(built.timeoutInterval, 60)
        XCTAssertTrue(FeedbackQueue(directory: queueDir).entries().isEmpty)
    }

    func testOfflineFailureQueuesThenRetrySends() async throws {
        let client = makeClient()
        do {
            try await client.send(payload("first"))
            XCTFail("expected a failure")
        } catch FeedbackSendError.queued(let id, _) {
            XCTAssertEqual(client.queue.entries(), [id])
            XCTAssertEqual(client.queue.load(id), payload("first"))
        }
        StubProtocol.handler = { _ in (500, Data("down".utf8)) }
        do {
            try await client.send(payload("second"))
            XCTFail("expected a failure")
        } catch FeedbackSendError.queued {}
        XCTAssertEqual(client.queue.entries().count, 2)

        // Still failing: nothing sent, nothing lost.
        let none = await client.retryQueued()
        XCTAssertEqual(none, 0)
        XCTAssertEqual(client.queue.entries().count, 2)

        StubProtocol.requests = []
        StubProtocol.handler = { _ in (200, Data(#"{"id": 1}"#.utf8)) }
        let sent = await client.retryQueued()
        XCTAssertEqual(sent, 2)
        XCTAssertTrue(client.queue.entries().isEmpty)
        let texts = try StubProtocol.requests.map { try json(XCTUnwrap($0.httpBody))["text"] as? String }
        XCTAssertEqual(texts, ["first", "second"])  // oldest first
    }

    func testRejectedReportIsNotQueuedAndQueuedRejectsAreDropped() async throws {
        StubProtocol.handler = { _ in (413, Data("screenshot too large".utf8)) }
        let client = makeClient()
        do {
            try await client.send(payload())
            XCTFail("expected a failure")
        } catch FeedbackSendError.rejected(let status, let body) {
            XCTAssertEqual(status, 413)
            XCTAssertEqual(body, "screenshot too large")
        }
        XCTAssertTrue(client.queue.entries().isEmpty)

        try client.queue.enqueue(payload())
        let sent = await client.retryQueued()
        XCTAssertEqual(sent, 0)
        XCTAssertTrue(client.queue.entries().isEmpty)
    }

    func testQueueKeepsTheNewest20() throws {
        let queue = FeedbackQueue(directory: queueDir)
        for n in 0..<25 { try queue.enqueue(payload("report \(n)")) }
        let entries = queue.entries()
        XCTAssertEqual(entries.count, 20)
        XCTAssertEqual(queue.load(entries[0])?.text, "report 5")
        XCTAssertEqual(queue.load(entries[19])?.text, "report 24")
    }

    func testStandardQueueLocation() {
        XCTAssertTrue(FeedbackQueue.standard.directory.path.hasSuffix("Application Support/FeedbackKit/queue"))
    }

    func testUnreadableQueueEntryIsDropped() async throws {
        try FileManager.default.createDirectory(at: queueDir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: queueDir.appendingPathComponent("0-bad.json"))
        StubProtocol.handler = { _ in (200, Data(#"{"id": 1}"#.utf8)) }
        let sent = await makeClient().retryQueued()
        XCTAssertEqual(sent, 0)
        XCTAssertTrue(FeedbackQueue(directory: queueDir).entries().isEmpty)
    }

    // MARK: sheet

    @MainActor func testSheetLaysOut() {
        let shot = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 80)).image { _ in }
        let context = FeedbackContext(appID: "a", version: "1 (1)", buildSHA: "abc", osVersion: "26.0",
                                      deviceModel: "x", screen: "Today")
        let sheet = FeedbackSheet(screenshot: shot, context: context, diagnostics: "log",
                                  client: makeClient()) {}
        let host = UIHostingController(rootView: sheet)
        // Sizing evaluates the sheet's body without a window.
        XCTAssertGreaterThan(host.sizeThatFits(in: CGSize(width: 390, height: 844)).height, 0)
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }
}
