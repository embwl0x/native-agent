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
    nonisolated(unsafe) static var failDownload = false
    nonisolated(unsafe) static var statusCode = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        if Self.failDownload {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        let bytes = Data(try! JSONValue.object(Self.response).serialize(pretty: false).utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.statusCode, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
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
        closeReason: String? = nil,
        chatHandler: SlackSocketModeChatHandler? = nil,
        progressChatHandler: SlackSocketModeProgressChatHandler? = nil
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
                        if let closeReason {
                            // End the session only once a chat turn is really
                            // in flight, so the teardown race is deterministic.
                            var waited = 0
                            while !lifecycleSignal.contains("generation_started"), waited < 500 {
                                try await Task.sleep(nanoseconds: 10_000_000)
                                waited += 1
                            }
                            return .string("{\"type\":\"disconnect\",\"reason\":\"\(closeReason)\"}")
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
            chatHandler: chatHandler ?? { _ in await recorder.generate() },
            progressChatHandler: progressChatHandler
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

    @Test(arguments: ["not-json", "[]", "{}", "{\"sessions\":[]}", "{\"sessions\":{\"other\":false}}", "{\"sessions\":{\"other\":{\"activeSessionId\":\"\"}}}"])
    func damagedSessionMapsRefuseAndPreserveEvidence(_ contents: String) async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("slack")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("session_map.json")
        let bytes = Data(contents.utf8)
        try bytes.write(to: path)
        for _ in 0..<2 {
            do {
                _ = try await SlackSessionStore(dataRoot: root).activeSessionId(for: inbound())
                Issue.record("Damaged session authority must refuse mutation")
            } catch is SlackSessionStorageError {}
        }
        #expect(try Data(contentsOf: path) == bytes)
        #expect(try Data(contentsOf: path.appendingPathExtension("damaged")) == bytes)
        try FileManager.default.removeItem(at: path)
        do {
            _ = try await SlackSessionStore(dataRoot: root).activeSessionId(for: inbound())
            Issue.record("Missing original with quarantine evidence must not bootstrap")
        } catch is SlackSessionStorageError {}
    }

    @Test func missingSessionMapBootstrapsAndConcurrentTurnsAdoptOneSession() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SlackSessionStore(dataRoot: root)
        let message = inbound()
        let ids = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 { group.addTask { try await store.activeSessionId(for: message) } }
            var result: Set<String> = []
            for try await id in group { result.insert(id) }
            return result
        }
        #expect(ids.count == 1)
        let followup = try await store.activeSessionId(for: inbound("2.000", thread: "1.000"))
        #expect(ids.contains(followup))
    }

    @Test func unreadableSessionMapRefusesWithoutQuarantine() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("slack/session_map.json")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        do {
            _ = try await SlackSessionStore(dataRoot: root).activeSessionId(for: inbound())
            Issue.record("Unreadable storage must refuse")
        } catch is SlackSessionStorageError {}
        #expect(!FileManager.default.fileExists(atPath: path.appendingPathExtension("damaged").path))
    }

    @Test func oldJournalPayloadRetainsTopLevelReplyDestination() throws {
        let message = inbound()
        let encoded = try JSONEncoder().encode(SlackDurableInboundPayload(message))
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "opensReplyThread")
        let legacy = try JSONDecoder().decode(SlackDurableInboundPayload.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.inbound.replyThreadTs == nil)
        #expect(SlackDurableInboundPayload(message).inbound.replyThreadTs == "1.000")
    }

    @Test func oversizedImageSettlesButDownloadFailureRemainsRetryable() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = DurableSlackRecorder()
        let loop = loop(root: root, recorder: recorder)
        let oversized = SlackInboundMessage(eventId: "large", teamId: "T1", channelId: "C1", userId: "U1", eventType: "app_mention", text: "", ts: "3.000", threadTs: nil, channelType: "channel", isDirectMessage: false, files: [SlackInboundFile(downloadURL: "https://slack.invalid/file", mimeType: "image/png", name: nil, byteSize: 11 * 1_024 * 1_024)])
        #expect(await loop.handleDurableInbound(oversized))
        #expect(await recorder.generations == 0)
        let transient = SlackInboundMessage(eventId: "transient", teamId: "T1", channelId: "C1", userId: "U1", eventType: "app_mention", text: "", ts: "4.000", threadTs: nil, channelType: "channel", isDirectMessage: false, files: [SlackInboundFile(downloadURL: "https://slack.invalid/file", mimeType: "image/png", name: nil, byteSize: 50)])
        DurableSlackHistoryProtocol.response = [:]
        // Inject a transport timeout without making a network request.
        DurableSlackHistoryProtocol.failDownload = true
        defer { DurableSlackHistoryProtocol.failDownload = false }
        #expect(await loop.handleDurableInbound(transient) == false)
        #expect(try await SlackInboundDeliveryJournal(dataRoot: root).record(eventId: transient.eventId)?.phase == .claimed)
        #expect(await recorder.posts.count == 1)
        #expect(await recorder.generations == 0)
    }

    @Test func progressAndFinalShareAnchorAndFollowupSessionWhileDMStaysUnthreaded() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = DurableSlackRecorder()
        let store = SlackSessionStore(dataRoot: root)
        let message = inbound()
        let expected = try await store.activeSessionId(for: message)
        let loop = loop(root: root, recorder: recorder, progressChatHandler: { message, progress in
            let actual = try await store.activeSessionId(for: message)
            #expect(actual == expected)
            await progress("provider_retry", "Reconnecting")
            return await recorder.generate()
        })
        #expect(await loop.handleDurableInbound(message))
        #expect(await loop.handleDurableInbound(inbound("2.000", thread: "1.000")))
        let posts = await recorder.posts
        #expect(posts.count == 4)
        #expect(posts.allSatisfy { $0["thread_ts"] == .string("1.000") })
        let dm = SlackInboundMessage(eventId: "dm", teamId: "T1", channelId: "D1", userId: "U1", eventType: "message", text: "hello", ts: "3.000", threadTs: nil, channelType: "im", isDirectMessage: true)
        let dmLoop = self.loop(root: root, recorder: recorder, progressChatHandler: { _, progress in
            await progress("provider_retry", "Reconnecting")
            return SlackSocketModeReply(text: "done")
        })
        #expect(await dmLoop.handleDurableInbound(dm))
        #expect(await recorder.posts.suffix(2).allSatisfy { $0["thread_ts"] == nil })
    }

    @Test(arguments: [400, 401, 403, 404, 410, 422, 408, 425, 429, 500, 503])
    func attachmentHTTPFailuresSettleOnlyWhenPermanent(_ status: Int) async throws {
        let root = try root()
        defer {
            DurableSlackHistoryProtocol.statusCode = 200
            try? FileManager.default.removeItem(at: root)
        }
        DurableSlackHistoryProtocol.statusCode = status
        let recorder = DurableSlackRecorder()
        let loop = loop(root: root, recorder: recorder)
        let message = SlackInboundMessage(eventId: "http", teamId: "T1", channelId: "C1", userId: "U1", eventType: "app_mention", text: "", ts: "1.000", threadTs: nil, channelType: "channel", isDirectMessage: false, files: [SlackInboundFile(downloadURL: "https://slack.invalid/file", mimeType: "image/png", name: "image.png", byteSize: 50)])
        let permanent = status < 500 && ![408, 425, 429].contains(status)
        _ = await loop.handleDurableInbound(message)
        _ = await loop.handleDurableInbound(message)
        #expect(try await SlackInboundDeliveryJournal(dataRoot: root).record(eventId: "http")?.phase == (permanent ? .delivered : .claimed))
        #expect(await recorder.generations == 0)
        #expect(await recorder.posts.count == (permanent ? 1 : 0))
        if permanent {
            let post = await recorder.posts.first
            guard case .string(let text)? = post?["text"] else {
                Issue.record("Expected durable unreadable-attachment notice")
                return
            }
            #expect(text.contains("attachments could not be read"))
        }
    }

    @Test func unsupportedFileSettlesBeforeNextMessageAndTextGetsMissingAttachmentNotice() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = DurableSlackRecorder()
        let loop = loop(root: root, recorder: recorder)
        for (id, text) in [("pdf", ""), ("pdf-text", "Summarize this")] {
            let message = SlackInboundMessage(eventId: id, teamId: "T1", channelId: "C1", userId: "U1", eventType: "app_mention", text: text, ts: id, threadTs: nil, channelType: "channel", isDirectMessage: false, files: [SlackInboundFile(downloadURL: "https://slack.invalid/file", mimeType: "application/pdf", name: "report.pdf", byteSize: 50)])
            #expect(await loop.handleDurableInbound(message))
            #expect(try await SlackInboundDeliveryJournal(dataRoot: root).record(eventId: id)?.phase == .delivered)
            #expect(await loop.handleDurableInbound(message))
        }
        #expect(await recorder.generations == 1)
        #expect(await recorder.posts.count == 2)
        #expect(await recorder.posts.allSatisfy {
            guard case .string(let text)? = $0["text"] else { return false }
            return text.contains("attachments could not be read")
        })
        #expect(await loop.handleDurableInbound(inbound("next")))
        #expect(await recorder.generations == 2)
    }

    /// Damaged bytes used to be terminal: every later load threw `.malformed`,
    /// so inbound admission AND recovery stayed dead until a human deleted the
    /// file. The evidence must still survive untouched — it is now preserved in
    /// a quarantine file beside the journal, and the journal itself heals.
    @Test func malformedJournalQuarantinesEvidenceInsteadOfRefusingIntakeForever() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("slack", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("inbound_delivery_journal.json")
        let bytes = Data("not-json".utf8)
        try bytes.write(to: path)
        let recorder = DurableSlackRecorder()
        let message = inbound()
        let claim = try await loop(root: root, recorder: recorder).claimInboundBeforeAcknowledging(message) {
            await recorder.acknowledge()
        }
        guard case .claimed = claim else {
            Issue.record("A quarantined journal must admit the envelope")
            return
        }
        #expect(await recorder.acknowledgements == 1)
        // Evidence: renamed aside, byte-identical, never deleted or overwritten.
        let quarantined = SlackInboundDeliveryJournal.quarantinedEvidencePaths(dataRoot: root)
        #expect(quarantined.count == 1)
        #expect(try Data(contentsOf: #require(quarantined.first)) == bytes)
        // Journal: healed, durable, and holding the freshly accepted claim.
        let journal = SlackInboundDeliveryJournal(dataRoot: root)
        #expect(try await journal.record(eventId: message.eventId)?.phase == .claimed)
        let read = try SlackInboundDeliveryJournal.recoverySummary(dataRoot: root)
        let summary = try #require(read)
        #expect(summary.quarantinedCount == 1)
        #expect(summary.hasQuarantinedEvidence)
        #expect(summary.pendingCount == 1)
    }

    /// A read failure says nothing about the CONTENT. Quarantining on it would
    /// rename a healthy journal aside on a transient I/O or permission error.
    @Test func unreadableJournalStillRefusesIntakeWithoutQuarantining() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("slack", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A directory at the journal path reads as "exists" but cannot be read.
        let path = directory.appendingPathComponent("inbound_delivery_journal.json")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let recorder = DurableSlackRecorder()
        do {
            _ = try await loop(root: root, recorder: recorder).claimInboundBeforeAcknowledging(inbound()) {
                await recorder.acknowledge()
            }
            Issue.record("An unreadable journal must not admit an envelope")
        } catch {}
        #expect(await recorder.acknowledgements == 0)
        #expect(SlackInboundDeliveryJournal.quarantinedEvidencePaths(dataRoot: root).isEmpty)
        #expect(FileManager.default.fileExists(atPath: path.path))
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

    /// The turn is never replayed (its tool effects may already have landed),
    /// but the sender is TOLD, once, on Slack — fable51 #9. Before this, the
    /// message was consumed and only the error log knew.
    @Test func crashDuringGenerationDoesNotReplayPotentialToolEffects() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let message = inbound(thread: "0.500")
        let journal = SlackInboundDeliveryJournal(dataRoot: root)
        _ = try await journal.claim(message)
        _ = try await journal.beginGeneration(eventId: message.eventId)
        let recorder = DurableSlackRecorder()
        #expect(await loop(root: root, recorder: recorder).handleDurableInbound(message) == false)
        #expect(await recorder.generations == 0)
        #expect(try await journal.record(eventId: message.eventId)?.phase == .outcomeUnknown)

        // ONE honest notice, in the thread the lost message lives in — and no
        // regenerated reply.
        #expect(await recorder.posts.count == 1)
        #expect(await recorder.posts.first?["text"] == .string(SlackSocketModeLoop.lostTurnNotice))
        #expect(await recorder.posts.first?["thread_ts"] == .string("0.500"))

        // A restart loop cannot repeat it: the durable phase flip routes every
        // later pass into reconciliation instead.
        #expect(await loop(root: root, recorder: recorder).handleDurableInbound(message) == false)
        #expect(await recorder.posts.count == 1)
        #expect(await recorder.generations == 0)
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

    /// A session that ends ON PURPOSE must not guillotine a chat turn: the row
    /// would stay `.generating`, recovery would park it `outcome_unknown`, and
    /// nothing auto-retries it — the user's message silently never gets a reply.
    @Test func plannedTeardownLetsAnInFlightGenerationFinishInsteadOfParkingItUnanswered() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = SlackInboundDeliveryJournal(dataRoot: root)
        let message = inbound()
        _ = try await journal.claim(message)
        DurableSlackHistoryProtocol.response = ["ok": .bool(true), "url": .string("wss://slack.invalid/test")]
        DurableSlackHistoryProtocol.requests = []
        let signal = DurableSlackLifecycleSignal()
        let recorder = DurableSlackRecorder()
        let loop = loop(
            root: root,
            recorder: recorder,
            lifecycleSignal: signal,
            closeReason: "refresh_requested"
        ) { _ in
            signal.mark("generation_started")
            try await Task.sleep(nanoseconds: 300_000_000)
            signal.mark("generation_finished")
            return await recorder.generate()
        }
        _ = await loop.tickOutcome()
        #expect(signal.contains("generation_started"))
        #expect(signal.contains("generation_finished"))
        #expect(await recorder.generations == 1)
        #expect(await recorder.posts.count == 1)
        #expect(try await journal.record(eventId: message.eventId)?.phase == .delivered)
    }

    @Test func teardownGraceCoversPlannedTeardownOnlyAndNeverDelaysABrokenSocket() {
        let planned = SlackSocketModeLoop.inFlightCompletionGrace
        #expect(SlackSocketModeLoop.teardownGrace(closing: nil, recyclePlanned: true) == planned)
        #expect(SlackSocketModeLoop.teardownGrace(closing: nil, recyclePlanned: false) == 0)
        // The recycle timer cancels the socket, which surfaces as a transport
        // error rather than a Slack `disconnect` frame.
        #expect(SlackSocketModeLoop.teardownGrace(
            closing: SlackSocketModeError.api("socket cancelled"), recyclePlanned: true) == planned)
        #expect(SlackSocketModeLoop.teardownGrace(
            closing: SlackSocketModeError.api("socket died"), recyclePlanned: false) == 0)
        #expect(SlackSocketModeLoop.teardownGrace(
            closing: SlackSocketSessionClosure.disconnect(reason: "refresh_requested"),
            recyclePlanned: false) == planned)
        for fatal in ["link_disabled", "too_many_connections", "too_many_websockets"] {
            #expect(SlackSocketModeLoop.teardownGrace(
                closing: SlackSocketSessionClosure.disconnect(reason: fatal),
                recyclePlanned: true) == 0)
        }
    }
}
