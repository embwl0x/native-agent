import Foundation
import Testing
@testable import TelegramBot
import NativeAgentTestSupport
import PersistenceCore

private final class TelegramOffsetCursorURLProtocol: ConfigurableURLProtocolStub {}

private final class TelegramOffsetCursorRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var requestCount = 0

    func recordRequest() {
        lock.withLock { requestCount += 1 }
    }

    func count() -> Int {
        lock.withLock { requestCount }
    }
}

// MARK: - Coverage ledger: telegram.offsetCursor

@Suite struct TelegramOffsetCursorEvalTests {
    @Test func advance_reloadsAcrossRestart_andNeverRegresses() async throws {
        let root = try makeTelegramOffsetCursorRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cursorURL = root
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")

        let firstProcess = TelegramOffsetCursor(fileURL: cursorURL)
        #expect(try firstProcess.load() == 0)
        #expect(try await firstProcess.advance(to: 41) == 41)

        // A reconstructed cursor is the restart boundary, not a shared object.
        let restartedProcess = TelegramOffsetCursor(fileURL: cursorURL)
        #expect(try restartedProcess.load() == 41)
        #expect(try await restartedProcess.advance(to: 12) == 41)

        let laterProcess = TelegramOffsetCursor(fileURL: cursorURL)
        #expect(try await laterProcess.advance(to: 97) == 97)
        #expect(try TelegramOffsetCursor(fileURL: cursorURL).load() == 97)

        let wire = try JSONValue.parse(Data(contentsOf: cursorURL))
        guard case .object(let object) = wire,
              case .int(let offset)? = object["offset"] else {
            Issue.record("cursor writer did not persist the canonical offset wire shape")
            return
        }
        #expect(offset == 97)
    }

    @Test func malformedCursor_stopsTheRealPollBeforeAnyNetworkRequest() async throws {
        let root = try makeTelegramOffsetCursorRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cursorURL = root
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")
        try FileManager.default.createDirectory(
            at: cursorURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let malformed = Data(#"{"offset":"replay-everything"}"#.utf8)
        try malformed.write(to: cursorURL)

        let capture = TelegramOffsetCursorRequestCapture()
        let session = TelegramOffsetCursorURLProtocol.makeSession { request in
            capture.recordRequest()
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://api.telegram.org")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (response, Data(#"{"ok":true,"result":[]}"#.utf8))
        }
        let loop = TelegramPollLoop(
            interval: 60,
            token: "cursor-eval-token",
            allowedChatIds: [77],
            session: session,
            dataRoot: root,
            offsetURL: cursorURL,
            syncCommandMenu: nil
        )

        let outcome = await loop.tickOutcome()
        guard case .failed(let message) = outcome else {
            Issue.record("malformed cursor must make the Telegram poll fail visibly")
            return
        }
        #expect(message.contains("offset cursor unavailable"))
        #expect(capture.count() == 0)
        #expect(try Data(contentsOf: cursorURL) == malformed)
    }
}

private func makeTelegramOffsetCursorRoot() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("telegram_offset_cursor_eval_\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
