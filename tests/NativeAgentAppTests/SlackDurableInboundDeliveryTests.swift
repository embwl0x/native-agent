import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

private actor DurableSlackRecorder {
    var posts: [[String: JSONValue]] = []
    var generations = 0
    var acknowledgements = 0
    var postResult: JSONValue = .object(["ok": .bool(true)])

    func post(_ input: [String: JSONValue]) -> JSONValue {
        posts.append(input)
        return postResult
    }
    func generate() -> SlackSocketModeReply {
        generations += 1
        return SlackSocketModeReply(text: "fresh reply")
    }
    func acknowledge() { acknowledgements += 1 }
    func setPostResult(_ value: JSONValue) { postResult = value }
}

private final class DurableSlackHistoryProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var response: [String: JSONValue] = [:]
    nonisolated(unsafe) static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let bytes = Data(try! JSONValue.object(Self.response).serialize(pretty: false).utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class DurableSlackLifecycleSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var events: Set<String> = []

    func mark(_ event: String) {
        lock.lock()
        defer { lock.unlock() }
        events.insert(event)
    }

    func contains(_ event: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return events.contains(event)
    }
}

@Suite(.serialized)
struct SlackDurableInboundDeliveryTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SlackDurable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func inbound(_ id: String = "1.000", thread: String? = nil) -> SlackInboundMessage {
        SlackInboundMessage(eventId: "T1:C1:\(id)", teamId: "T1", channelId: "C1", userId: "U1", eventType: "app_mention", text: "hello", ts: id, threadTs: thread, channelType: "channel", isDirectMessage: false)
    }

    private func loop(
        root: URL,
        recorder: DurableSlackRecorder,
        history: Bool = false,
        lifecycleSignal: DurableSlackLifecycleSignal? = nil,
        chatHandler: SlackSocketModeChatHandler? = nil
    ) -> SlackSocketModeLoop {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DurableSlackHistoryProtocol.self]
        let socketFactory: (@Sendable (URL) -> SlackSocketConnection)?
        if let lifecycleSignal {
            socketFactory = { _ in
                SlackSocketConnection(
                    resume: { lifecycleSignal.mark("socket_resumed") },
                    cancel: { lifecycleSignal.mark("socket_cancelled") },
                    receive: {
                        if !lifecycleSignal.contains("hello_received") {
                            lifecycleSignal.mark("hello_received")
                            return .string("{\"type\":\"hello\"}")
                        }
                        lifecycleSignal.mark("receive_waiting")
                        while !Task.isCancelled { try await Task.sleep(nanoseconds: 10_000_000) }
                        throw CancellationError()
                    },
                    send: { _ in },
                    sendPing: { $0(nil) }
                )
            }
        } else {
            socketFactory = nil
        }
        return SlackSocketModeLoop(
            config: SlackSocketModeConfig(botToken: "xoxb-snapshot", appToken: "xapp-test", botUserId: "UBOT", teamId: "T1", enabled: true, historyPollEnabled: history, historyPollInterval: 60, historyConversationRefreshInterval: 600, allowedChannelIds: ["C1"], allowedUserIds: [], requireMention: true),
            dataRoot: root,
            session: URLSession(configuration: configuration),
            outbound: SlackSocketModeOutbound(postMessage: { await recorder.post($0) }, uploadFile: { await recorder.post($0) }),
            socketConnectionFactory: socketFactory,
            chatHandler: chatHandler ?? { _ in await recorder.generate() }
        )
    }

    private func acceptedHistory(_ inbound: SlackInboundMessage, fingerprint: String) -> [String: JSONValue] {
        var message: [String: JSONValue] = [
            "user": .string("UBOT"),
            "ts": .string("2.000"),
            "metadata": SlackSocketModeLoop.deliveryMetadata(eventId: inbound.eventId, fingerprint: fingerprint),
        ]
        if let thread = inbound.replyThreadTs { message["thread_ts"] = .string(thread) }
        return ["ok": .bool(true), "has_more": .bool(false), "messages": .array([.object(message)])]
    }

    @Test func claimSurvivesCrashAfterAckBeforeGeneration() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = DurableSlackRecorder()
        let message = inbound()
        let first = loop(root: root, recorder: recorder)
        _ = try await first.claimInboundBeforeAcknowledging(message) {
            // ACK cannot run until the durable row is readable by a fresh owner.
            let disk = SlackInboundDeliveryJournal(dataRoot: root)
            let stored = try await disk.record(eventId: message.eventId)
            #expect(stored?.phase == .claimed)
            await recorder.acknowledge()
        }
        #expect(await recorder.acknowledgements == 1)
        #expect(await recorder.generations == 0)
        let restarted = loop(root: root, recorder: recorder)
        #expect(await restarted.handleDurableInbound(message))
        #expect(await recorder.generations == 1)
        #expect(await recorder.posts.count == 1)
    }

    @Test func malformedJournalNeverAcknowledgesOrOverwritesEvidence() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("slack", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("inbound_delivery_journal.json")
        let bytes = Data("not-json".utf8)
        try bytes.write(to: path)
        let recorder = DurableSlackRecorder()
        do {
            _ = try await loop(root: root, recorder: recorder).claimInboundBeforeAcknowledging(inbound()) {
                await recorder.acknowledge()
            }
            Issue.record("Malformed journal unexpectedly admitted an envelope")
        } catch {}
        #expect(await recorder.acknowledgements == 0)
        #expect(try Data(contentsOf: path) == bytes)
    }

    @Test func journalPublicationIsPrivateInsideAnExistingPublicDirectory() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("slack", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let journal = SlackInboundDeliveryJournal(dataRoot: root)
        let message = inbound()
        _ = try await journal.claim(message)
        let path = SlackInboundDeliveryJournal.path(dataRoot: root)
        let first = try FileManager.default.attributesOfItem(atPath: path.path)
        #expect((first[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        _ = try await journal.prepare(eventId: message.eventId, reply: .make(text: "private reply", uploads: []))
        let replacement = try FileManager.default.attributesOfItem(atPath: path.path)
        #expect((replacement[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(!FileManager.default.fileExists(atPath: path.path + ".tmp"))
    }

    @Test func canonicalTickRecoversPreparedReplyBeforeSocketOpenFailure() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = SlackInboundDeliveryJournal(dataRoot: root)
        let message = inbound()
        _ = try await journal.claim(message)
        _ = try await journal.prepare(eventId: message.eventId, reply: .make(text: "recovered without socket", uploads: []))
        DurableSlackHistoryProtocol.response = ["ok": .bool(false), "error": .string("invalid_auth")]
        DurableSlackHistoryProtocol.requests = []
        let recorder = DurableSlackRecorder()
        let outcome = await loop(root: root, recorder: recorder).tickOutcome()
        if case .failed = outcome {} else { Issue.record("Socket open should still report its failure") }
        #expect(await recorder.generations == 0)
        #expect(await recorder.posts.count == 1)
        #expect(try await journal.record(eventId: message.eventId)?.phase == .delivered)
        #expect(DurableSlackHistoryProtocol.requests.first?.url?.path == "/api/apps.connections.open")
    }

    @Test func heldRecoveryGenerationDoesNotBlockSocketOpenOrReceiveAndStopsWithTick() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = SlackInboundDeliveryJournal(dataRoot: root)
        let message = inbound()
        _ = try await journal.claim(message)
        DurableSlackHistoryProtocol.response = ["ok": .bool(true), "url": .string("wss://slack.invalid/test")]
        DurableSlackHistoryProtocol.requests = []
        let signal = DurableSlackLifecycleSignal()
        let recorder = DurableSlackRecorder()
        let loop = loop(root: root, recorder: recorder, lifecycleSignal: signal) { _ in
            signal.mark("generation_started")
            defer { signal.mark("generation_finished") }
            while !Task.isCancelled { try await Task.sleep(nanoseconds: 10_000_000) }
            throw CancellationError()
        }
        let tick = Task { await loop.tickOutcome() }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline,
              !(signal.contains("generation_started") && signal.contains("receive_waiting")) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        // Recovery is still held while the real receive loop has consumed
        // hello and is already waiting for the next inbound envelope.
        #expect(signal.contains("generation_started"))
        #expect(signal.contains("socket_resumed"))
        #expect(signal.contains("receive_waiting"))
        #expect(!signal.contains("generation_finished"))
        tick.cancel()
        _ = await tick.value
        #expect(signal.contains("generation_finished"))
        #expect(signal.contains("socket_cancelled"))
        #expect(await loop.inFlightHandlingCount == 0)
        #expect(await recorder.posts.isEmpty)
        #expect(try await journal.record(eventId: message.eventId)?.phase == .generating)
    }

    @Test func preparedReplyRestartsWithoutGeneratingAnotherTurnAndDeliveredReplayDoesNothing() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let message = inbound()
        let journal = SlackInboundDeliveryJournal(dataRoot: root)
        _ = try await journal.claim(message)
        _ = try await journal.prepare(eventId: message.eventId, reply: .make(text: "saved reply", uploads: []))
        let recorder = DurableSlackRecorder()
        #expect(await loop(root: root, recorder: recorder).handleDurableInbound(message))
        #expect(await recorder.generations == 0)
        #expect(await recorder.posts.first?["text"] == .string("saved reply"))
        #expect(await loop(root: root, recorder: recorder).handleDurableInbound(message))
        #expect(await recorder.posts.count == 1)
    }

    @Test func crashDuringGenerationDoesNotReplayPotentialToolEffects() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let message = inbound()
        let journal = SlackInboundDeliveryJournal(dataRoot: root)
        _ = try await journal.claim(message)
        _ = try await journal.beginGeneration(eventId: message.eventId)
        let recorder = DurableSlackRecorder()
        #expect(await loop(root: root, recorder: recorder).handleDurableInbound(message) == false)
        #expect(await recorder.generations == 0)
        #expect(await recorder.posts.isEmpty)
        #expect(try await journal.record(eventId: message.eventId)?.phase == .outcomeUnknown)
    }

    @Test func crashAfterSlackAcceptanceReconcilesCorrectThreadWithoutResending() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let message = inbound(thread: "0.500")
        let journal = SlackInboundDeliveryJournal(dataRoot: root)
        let prepared = SlackPreparedReply.make(text: "saved reply", uploads: [])
        _ = try await journal.claim(message)
        _ = try await journal.prepare(eventId: message.eventId, reply: prepared)
        _ = try await journal.beginDispatch(eventId: message.eventId)
        DurableSlackHistoryProtocol.response = acceptedHistory(message, fingerprint: prepared.fingerprint)
        DurableSlackHistoryProtocol.requests = []
        let recorder = DurableSlackRecorder()
        #expect(await loop(root: root, recorder: recorder).handleDurableInbound(message))
        #expect(await recorder.posts.isEmpty)
        #expect(await recorder.generations == 0)
        #expect(try await journal.record(eventId: message.eventId)?.phase == .delivered)
        let request = try #require(DurableSlackHistoryProtocol.requests.first)
        #expect(request.url?.path == "/api/conversations.replies")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "ts", value: "0.500")))
        #expect(query.contains(URLQueryItem(name: "include_all_metadata", value: "true")))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer xoxb-snapshot")
    }

    @Test func historyAbsenceOrPermissionFailureNeverAuthorizesBlindResend() async throws {
        let responses: [[String: JSONValue]] = [
            ["ok": .bool(true), "has_more": .bool(false), "messages": .array([])],
            ["ok": .bool(false), "error": .string("missing_scope")],
        ]
        for response in responses {
            let root = try root()
            defer { try? FileManager.default.removeItem(at: root) }
            let message = inbound()
            let journal = SlackInboundDeliveryJournal(dataRoot: root)
            _ = try await journal.claim(message)
            _ = try await journal.prepare(eventId: message.eventId, reply: .make(text: "saved", uploads: []))
            _ = try await journal.beginDispatch(eventId: message.eventId)
            DurableSlackHistoryProtocol.response = response
            let recorder = DurableSlackRecorder()
            #expect(await loop(root: root, recorder: recorder).handleDurableInbound(message) == false)
            #expect(await recorder.posts.isEmpty)
            #expect(await recorder.generations == 0)
            #expect(try await journal.record(eventId: message.eventId)?.phase == .outcomeUnknown)
        }
    }

    @Test func ambiguousImageCompletionIsNotReplayedEvenWhenTextIsProven() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let message = inbound()
        let journal = SlackInboundDeliveryJournal(dataRoot: root)
        let prepared = SlackPreparedReply.make(text: "image", uploads: [SlackPreparedUpload(path: "/missing/image.png", name: "image.png", mime: "image/png")])
        _ = try await journal.claim(message)
        _ = try await journal.prepare(eventId: message.eventId, reply: prepared)
        _ = try await journal.beginDispatch(eventId: message.eventId)
        DurableSlackHistoryProtocol.response = acceptedHistory(message, fingerprint: prepared.fingerprint)
        let recorder = DurableSlackRecorder()
        #expect(await loop(root: root, recorder: recorder).handleDurableInbound(message) == false)
        #expect(await recorder.posts.isEmpty)
        #expect(try await journal.record(eventId: message.eventId)?.phase == .outcomeUnknown)
    }

    @Test func onlyUniqueCompleteMatchingBotAndThreadEvidenceCounts() {
        let message = inbound()
        let valid = acceptedHistory(message, fingerprint: "fp")
        #expect(SlackSocketModeLoop.hasUniqueAcceptedReply(response: valid, inbound: message, fingerprint: "fp", botUserId: "UBOT"))
        #expect(!SlackSocketModeLoop.hasUniqueAcceptedReply(response: valid, inbound: message, fingerprint: "other", botUserId: "UBOT"))
        #expect(!SlackSocketModeLoop.hasUniqueAcceptedReply(response: valid, inbound: message, fingerprint: "fp", botUserId: "OTHER"))
        #expect(!SlackSocketModeLoop.hasUniqueAcceptedReply(response: valid, inbound: inbound(thread: "0.500"), fingerprint: "fp", botUserId: "UBOT"))
        var incomplete = valid
        incomplete["has_more"] = .bool(true)
        #expect(!SlackSocketModeLoop.hasUniqueAcceptedReply(response: incomplete, inbound: message, fingerprint: "fp", botUserId: "UBOT"))
        var duplicate = valid
        if case .array(let rows)? = valid["messages"] { duplicate["messages"] = .array(rows + rows) }
        #expect(!SlackSocketModeLoop.hasUniqueAcceptedReply(response: duplicate, inbound: message, fingerprint: "fp", botUserId: "UBOT"))
    }

    @Test func pendingCapacityBackpressuresRatherThanEvictingAcceptedWork() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = SlackInboundDeliveryJournal(dataRoot: root, terminalCap: 1, pendingCap: 1)
        _ = try await journal.claim(inbound("1.000"))
        do {
            _ = try await journal.claim(inbound("2.000"))
            Issue.record("Expected pending admission backpressure")
        } catch {}
        #expect(try await journal.unresolved().count == 1)
        #expect(try await journal.record(eventId: inbound("1.000").eventId) != nil)
    }

    @Test func explicitPreAcceptanceRejectionRetriesPreparedArtifactNotGeneration() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = DurableSlackRecorder()
        await recorder.setPostResult(.object(["ok": .bool(false), "error": .string("not_in_channel")]))
        let message = inbound()
        #expect(await loop(root: root, recorder: recorder).handleDurableInbound(message) == false)
        await recorder.setPostResult(.object(["ok": .bool(true)]))
        #expect(await loop(root: root, recorder: recorder).handleDurableInbound(message))
        #expect(await recorder.generations == 1)
        #expect(await recorder.posts.count == 2)
        #expect(!SlackSocketModeLoop.isProvenSlackRejection(.object(["ok": .bool(false), "error": .string("internal_error")])))
        #expect(!SlackSocketModeLoop.isProvenSlackRejection(.object(["ok": .bool(false), "error": .string("fatal_error")])))
    }
}
