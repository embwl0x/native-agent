import Foundation
import Testing
@testable import TelegramBot

private final class TelegramDownloadProbe: @unchecked Sendable {
    let reportedSize: Int?
    let body: Data
    let finishesBody: Bool
    let status: Int
    private let lock = NSLock()
    private var eventsStorage: [String] = []

    init(reportedSize: Int?, body: Data, finishesBody: Bool, status: Int = 200) {
        self.reportedSize = reportedSize
        self.body = body
        self.finishesBody = finishesBody
        self.status = status
    }

    func record(_ event: String) {
        lock.lock()
        defer { lock.unlock() }
        eventsStorage.append(event)
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return eventsStorage
    }
}

private final class TelegramDownloadProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var probe: TelegramDownloadProbe!
    private var activeProbe: TelegramDownloadProbe?
    private var label = ""
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let probe = Self.probe!
        activeProbe = probe
        if request.url!.path.hasSuffix("/getFile") { label = "metadata" }
        else if request.url!.path == "/bystander" { label = "bystander" }
        else { label = "body" }
        probe.record("start-\(label)")
        let response = HTTPURLResponse(
            url: request.url!, statusCode: label == "body" ? probe.status : 200,
            httpVersion: "HTTP/1.1", headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if label == "metadata" {
            var result: [String: Any] = ["file_path": "photos/fixture.jpg"]
            if let size = probe.reportedSize { result["file_size"] = size }
            let data = try! JSONSerialization.data(withJSONObject: ["ok": true, "result": result])
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } else {
            client?.urlProtocol(self, didLoad: probe.body)
            if label == "body", probe.finishesBody { client?.urlProtocolDidFinishLoading(self) }
        }
    }

    override func stopLoading() { activeProbe?.record("stop-\(label)") }
}

@Suite("Telegram downloads enforce the existing cap during transfer", .serialized)
struct TelegramMediaDownloadLifetimeTests {
    private func session(_ probe: TelegramDownloadProbe) -> URLSession {
        TelegramDownloadProtocol.probe = probe
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TelegramDownloadProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(1)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return condition()
    }

    @Test(arguments: [Optional<Int>.none, .some(1)])
    func missingOrUnderreportedSizeStopsAtFirstExcessByte(reportedSize: Int?) async throws {
        // Exceed URLSession's small-chunk coalescing threshold while keeping
        // the transport open. The downloader may retain only the 32-byte cap.
        let probe = TelegramDownloadProbe(reportedSize: reportedSize, body: Data(repeating: 65, count: 64 * 1024), finishesBody: false)
        let session = session(probe)
        defer { session.invalidateAndCancel() }
        let bystander = session.dataTask(with: URL(string: "https://fixture.invalid/bystander")!)
        bystander.resume()
        defer { bystander.cancel() }
        #expect(await waitUntil { probe.events.contains("start-bystander") })
        let downloader = TelegramMediaDownloader(session: session)
        let download = Task {
            try await downloader.download(token: "fixture-token", attachment: .init(kind: "photo", fileId: "fixture"), maxBytes: 32)
        }
        guard await waitUntil({ probe.events.contains("stop-body") }) else {
            download.cancel()
            _ = await download.result
            Issue.record("Overflow did not close the held request within one second")
            return
        }
        do {
            _ = try await download.value
            Issue.record("Expected overflow before the held body reaches EOF")
        } catch let error as TelegramMediaDownloadError {
            #expect(error == .oversized(reportedBytes: 33, capBytes: 32))
        }
        #expect(!probe.events.contains("stop-bystander"))
        #expect(bystander.state == .running)
    }

    @Test(arguments: [0, 31, 32])
    func validBodyThroughExactCapPreservesAttachment(size: Int) async throws {
        let body = Data(repeating: 66, count: size)
        let probe = TelegramDownloadProbe(reportedSize: nil, body: body, finishesBody: true)
        let session = session(probe)
        defer { session.invalidateAndCancel() }
        let downloader = TelegramMediaDownloader(session: session)
        let result = try await downloader.download(
            token: "fixture-token", attachment: .init(kind: "photo", fileId: "fixture", mimeType: "image/jpeg"), maxBytes: 32
        )
        #expect(result.bytes == body)
        #expect(result.sizeBytes == size)
        #expect(result.kind == "photo")
        #expect(result.fileId == "fixture")
        #expect(result.mimeType == "image/jpeg")
        #expect(result.captureFilename == "fixture.jpg")
    }

    @Test func reportedOversizeStillAvoidsBodyRequest() async throws {
        let probe = TelegramDownloadProbe(reportedSize: 33, body: Data(), finishesBody: false)
        let session = session(probe)
        defer { session.invalidateAndCancel() }
        let downloader = TelegramMediaDownloader(session: session)
        do {
            _ = try await downloader.download(token: "fixture-token", attachment: .init(kind: "voice", fileId: "fixture"), maxBytes: 32)
            Issue.record("Expected metadata preflight rejection")
        } catch let error as TelegramMediaDownloadError {
            #expect(error == .oversized(reportedBytes: 33, capBytes: 32))
        }
        #expect(!probe.events.contains("start-body"))
    }

    @Test func stopClosesHeldBodyAndStaysCancellation() async throws {
        let probe = TelegramDownloadProbe(reportedSize: nil, body: Data([1, 2]), finishesBody: false)
        let session = session(probe)
        defer { session.invalidateAndCancel() }
        let downloader = TelegramMediaDownloader(session: session)
        let download = Task {
            try await downloader.download(token: "fixture-token", attachment: .init(kind: "voice", fileId: "fixture"), maxBytes: 32)
        }
        #expect(await waitUntil { probe.events.contains("start-body") })
        try await Task.sleep(for: .milliseconds(50))
        download.cancel()
        do {
            _ = try await download.value
            Issue.record("Expected cancelled download, never a partial attachment")
        } catch {
            #expect(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
        #expect(await waitUntil { probe.events.contains("stop-body") })
    }

    @Test func httpFailureClosesUnreadBodyWithoutBecomingOversize() async throws {
        let probe = TelegramDownloadProbe(reportedSize: nil, body: Data(repeating: 65, count: 64 * 1024), finishesBody: false, status: 503)
        let session = session(probe)
        defer { session.invalidateAndCancel() }
        let downloader = TelegramMediaDownloader(session: session)
        do {
            _ = try await downloader.download(token: "fixture-token", attachment: .init(kind: "photo", fileId: "fixture"), maxBytes: 32)
            Issue.record("Expected HTTP failure")
        } catch let error as TelegramMediaDownloadError {
            #expect(error == .httpError(status: 503))
        }
        #expect(await waitUntil { probe.events.contains("stop-body") })
    }
}
