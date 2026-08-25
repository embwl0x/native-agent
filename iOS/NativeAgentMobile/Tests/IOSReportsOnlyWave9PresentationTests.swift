import Foundation
import NativeAgentShared
import XCTest
@testable import NativeAgentMobile

private actor Wave9BridgeRecorder {
    private var messages: [BridgeMessage] = []
    func append(_ message: BridgeMessage) { messages.append(message) }
    func first() -> BridgeMessage? { messages.first }
}

/// Executable projection contracts for remaining `ios.screens` REPORTS-ONLY
/// rows. These call the reducers used by the shipping SwiftUI screens; they do
/// not inspect source text, assert visual styling, or hand-build action
/// envelopes.
@MainActor
final class IOSReportsOnlyWave9PresentationTests: XCTestCase {
    private func tool(
        id: String,
        name: String,
        kind: String? = nil,
        status: String? = nil,
        description: String? = nil,
        autoRun: Bool? = nil
    ) -> ToolRecord {
        ToolRecord(
            id: id,
            name: name,
            kind: kind,
            status: status,
            description: description,
            autoRun: autoRun,
            riskClass: nil,
            updatedAt: nil
        )
    }

    private func skill(_ id: String, state: String?, source: String? = nil) throws -> SkillManifestEntry {
        var fields: [String: Any] = ["id": id, "name": "Skill \(id)"]
        if let state { fields["state"] = state }
        if let source { fields["source"] = source }
        return try JSONDecoder().decode(
            SkillManifestEntry.self,
            from: JSONSerialization.data(withJSONObject: fields)
        )
    }

    private func turnSummary(
        id: String = "turn-1",
        wallMs: Int = 1_500,
        tokens: Int? = 42,
        ttft: Int? = 90,
        kinds: [String: Int] = ["tool.call": 2, "chat.reply": 3]
    ) throws -> TurnSummaryRecord {
        var fields: [String: Any] = [
            "id": id,
            "startedAt": "2026-08-24T12:00:00Z",
            "lastAt": "2026-08-24T12:00:01Z",
            "eventCount": 5,
            "wallMs": wallMs,
            "kinds": kinds,
        ]
        if let tokens { fields["llmTokens"] = tokens }
        if let ttft { fields["ttftMs"] = ttft }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            TurnSummaryRecord.self,
            from: JSONSerialization.data(withJSONObject: fields)
        )
    }

    // ios.tools.catalog.search
    func test_toolSearchFindsNameDescriptionAndKindWithoutTreatingWhitespaceAsAFilter() {
        let tools = [
            tool(id: "a", name: "Calendar", kind: "connector"),
            tool(id: "b", name: "Workspace writer", description: "Safely rewrites a checked file"),
            tool(id: "c", name: "Terminal", kind: "shell"),
        ]

        XCTAssertEqual(ToolCatalogPresentation.visibleTools(tools, query: "").map(\.id), ["a", "b", "c"])
        XCTAssertEqual(ToolCatalogPresentation.visibleTools(tools, query: "  ").map(\.id), ["a", "b", "c"])
        XCTAssertEqual(ToolCatalogPresentation.visibleTools(tools, query: "CALENDAR").map(\.id), ["a"])
        XCTAssertEqual(ToolCatalogPresentation.visibleTools(tools, query: "rewrites").map(\.id), ["b"])
        XCTAssertEqual(ToolCatalogPresentation.visibleTools(tools, query: "shell").map(\.id), ["c"])
    }

    // ios.tools.catalog.row.status / ios.tools.catalog.autoRunBadge
    func test_toolRowProjectionKeepsUnknownStatusNeutralAndMarksOnlyExplicitAutoRun() {
        XCTAssertEqual(ToolCatalogPresentation.status(for: tool(id: "a", name: "A", status: "policy_locked")), .known("Policy Locked"))
        XCTAssertEqual(ToolCatalogPresentation.status(for: tool(id: "b", name: "B", status: "")), .unknown)
        XCTAssertEqual(ToolCatalogPresentation.status(for: tool(id: "c", name: "C")), .unknown)
        XCTAssertEqual(ToolCatalogPresentation.automaticity(for: tool(id: "a", name: "A", autoRun: true)), .automatic)
        XCTAssertEqual(ToolCatalogPresentation.automaticity(for: tool(id: "b", name: "B", autoRun: false)), .manual)
        XCTAssertEqual(ToolCatalogPresentation.automaticity(for: tool(id: "c", name: "C")), .unknown)
        XCTAssertEqual(ToolCatalogPresentation.contentState(isLoading: false, error: "Sync failed", toolCount: 0, visibleCount: 0), .syncError("Sync failed"))
        XCTAssertEqual(ToolCatalogPresentation.contentState(isLoading: false, error: nil, toolCount: 0, visibleCount: 0), .unpublished)
        XCTAssertEqual(ToolCatalogPresentation.contentState(isLoading: false, error: nil, toolCount: 1, visibleCount: 0), .noMatches)
    }

    // ios.skills.filter.quarantinedBucketMissing / ios.skills.row / ios.skills.stateChip
    func test_skillProjectionKeepsEveryNormalizedStateReachableAndUnknownRowsVisible() throws {
        let active = try skill("active", state: "enabled")
        let installed = try skill("installed", state: "available")
        let drafted = try skill("drafted", state: "draft")
        let dormant = try skill("dormant", state: "disabled")
        let quarantined = try skill("quarantined", state: "quarantine")
        let unknown = try skill("unknown", state: "future_state")
        let blank = try skill("blank", state: "")
        let all = [active, installed, drafted, dormant, quarantined, unknown, blank]

        XCTAssertEqual(SkillLifecyclePresentation.filtered(all, state: "active").map(\.id), ["active"])
        XCTAssertEqual(SkillLifecyclePresentation.filtered(all, state: "installed").map(\.id), ["installed"])
        XCTAssertEqual(SkillLifecyclePresentation.filtered(all, state: "drafted").map(\.id), ["drafted"])
        XCTAssertEqual(SkillLifecyclePresentation.filtered(all, state: "dormant").map(\.id), ["dormant"])
        XCTAssertEqual(SkillLifecyclePresentation.filtered(all, state: "quarantined").map(\.id), ["quarantined"])
        XCTAssertEqual(SkillLifecyclePresentation.filtered(all, state: "unknown").map(\.id), ["unknown", "blank"])
        XCTAssertEqual(SkillLifecyclePresentation.filtered(all, state: nil).map(\.id), ["active", "installed", "drafted", "dormant", "quarantined", "unknown", "blank"])
        XCTAssertEqual(SkillLifecyclePresentation.stateLabel(for: quarantined), "Quarantined")
        XCTAssertEqual(SkillLifecyclePresentation.stateLabel(for: unknown), "Unknown: future_state")
        XCTAssertEqual(SkillLifecyclePresentation.stateLabel(for: blank), "State unknown")
        XCTAssertEqual(SkillSourcePresentation.label(for: SkillSourcePresentation.source(for: try skill("blank-source", state: "active", source: ""))), "UNKNOWN")
        XCTAssertEqual(SkillSourcePresentation.label(for: SkillSourcePresentation.source(for: try skill("missing-source", state: "active"))), "UNKNOWN")
    }

    // ios.kg.search / ios.kg.emptyState
    func test_knowledgeGraphProjectionSearchesEveryPublishedFieldAndDistinguishesEmptyFromLoading() {
        XCTAssertEqual(KnowledgeGraphPresentation.contentState(isLoading: true, hasPublishedSnapshot: false, entityCount: 0, query: ""), .loading)
        XCTAssertEqual(KnowledgeGraphPresentation.contentState(isLoading: false, hasPublishedSnapshot: false, entityCount: 0, query: ""), .unpublished)
        XCTAssertEqual(KnowledgeGraphPresentation.contentState(isLoading: false, hasPublishedSnapshot: true, entityCount: 0, query: ""), .emptyPublished)
        XCTAssertEqual(KnowledgeGraphPresentation.contentState(isLoading: false, hasPublishedSnapshot: true, entityCount: 0, query: "Agent"), .noMatches)
        XCTAssertEqual(KnowledgeGraphPresentation.contentState(isLoading: true, hasPublishedSnapshot: true, entityCount: 1, query: ""), .content)

        XCTAssertTrue(KnowledgeGraphPresentation.matches(query: "", name: "Agent", type: "person", summary: nil, aliases: nil))
        XCTAssertTrue(KnowledgeGraphPresentation.matches(query: "PERSON", name: "Agent", type: "person", summary: nil, aliases: nil))
        XCTAssertTrue(KnowledgeGraphPresentation.matches(query: "habits", name: "Agent", type: "person", summary: "Tracks working habits", aliases: nil))
        XCTAssertTrue(KnowledgeGraphPresentation.matches(query: "assistant", name: "Agent", type: "person", summary: nil, aliases: ["Local Assistant"]))
        XCTAssertFalse(KnowledgeGraphPresentation.matches(query: "missing", name: "Agent", type: "person", summary: nil, aliases: ["Local Assistant"]))
        XCTAssertEqual(KnowledgeGraphPresentation.bounded(Array(0...200), maximum: 200), Array(0...199))
    }

    // ios.turninspector.rowMetrics / ios.turninspector.kindsMix
    func test_turnInspectorMetricsAndKindsStayCompleteAndDeterministicallyOrdered() throws {
        let detailed = try turnSummary()
        XCTAssertEqual(
            TurnInspectorPresentation.metrics(for: detailed).map { "\($0.label)=\($0.value)" },
            ["events=5", "wall=1.5 s", "tok=42", "ttft=90 ms"]
        )
        XCTAssertEqual(TurnInspectorPresentation.kindsText(detailed.kinds), "chat.reply ×3 · tool.call ×2")

        let sparse = try turnSummary(wallMs: 999, tokens: nil, ttft: nil, kinds: ["turn": 1])
        XCTAssertEqual(TurnInspectorPresentation.metrics(for: sparse).map(\.label), ["events", "wall", "tok", "ttft"])
        XCTAssertEqual(TurnInspectorPresentation.metrics(for: sparse).map(\.value), ["5", "999 ms", "Unknown", "Unknown"])
        XCTAssertEqual(TurnInspectorPresentation.kindsText(sparse.kinds), "turn ×1")
        let longKinds = [
            "com.nativeagent.very.long.first.event.name": 7,
            "com.nativeagent.very.long.second.event.name": 6,
            "com.nativeagent.very.long.third.event.name": 5,
            "com.nativeagent.very.long.fourth.event.name": 4,
            "com.nativeagent.very.long.fifth.event.name": 3,
            "com.nativeagent.very.long.sixth.event.name": 2,
            "com.nativeagent.very.long.seventh.event.name": 1,
        ]
        let disclosure = TurnInspectorPresentation.kindsText(longKinds)
        XCTAssertTrue(disclosure.contains("com.nativeagent.very.long.first.event.name ×7"))
        XCTAssertTrue(disclosure.hasSuffix("+1 more"))
    }

    // ios.turninspector.emptyState / ios.turninspector.list
    func test_turnInspectorReloadRetainsLastProvenSnapshotWhenTheReplacementIsUnreadable() async throws {
        let engine = iCloudSyncEngine.shared
        let priorSnapshotDir = engine.snapshotDir
        let priorSummaries = engine.turnSummaries
        let priorLastSync = engine.lastSyncAt
        let priorError = engine.syncError
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-wave9-turns-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            engine.snapshotDir = priorSnapshotDir
            engine.turnSummaries = priorSummaries
            engine.lastSyncAt = priorLastSync
            engine.syncError = priorError
            try? FileManager.default.removeItem(at: root)
        }

        let snapshot = """
        {"summaries":[{"id":"relaunch-turn","startedAt":"2026-08-24T12:00:00Z","lastAt":"2026-08-24T12:00:01Z","eventCount":2,"wallMs":700,"kinds":{"chat.reply":2}}],"truncated":false,"totalTurnsSeen":1}
        """
        let path = root.appendingPathComponent("turn_summaries.json")
        try Data(snapshot.utf8).write(to: path, options: .atomic)
        engine.snapshotDir = root
        engine.turnSummaries = nil

        let firstStore = TurnInspectorStore()
        await firstStore.refresh()
        XCTAssertEqual(firstStore.file?.summaries.map(\.id), ["relaunch-turn"])
        XCTAssertEqual(TurnInspectorPresentation.contentState(for: firstStore.file), .content(truncated: false, visibleCount: 1, totalCount: 1))

        // A recreated screen reads the persisted snapshot, rather than relying
        // on the first view's in-memory state.
        let relaunchedStore = TurnInspectorStore()
        await relaunchedStore.refresh()
        XCTAssertEqual(relaunchedStore.file?.summaries.map(\.id), ["relaunch-turn"])

        try Data("not json".utf8).write(to: path, options: .atomic)
        await relaunchedStore.refresh()
        XCTAssertEqual(relaunchedStore.file?.summaries.map(\.id), ["relaunch-turn"])
        XCTAssertEqual(engine.turnSummaries?.summaries.map(\.id), ["relaunch-turn"])
    }

    // ios.chatStore.streamingHint (ios.sync)
    func test_chatStreamingHintFollowsTheSignedProgressDeltaFinalAndTimeoutLifecycle() async throws {
        let suite = "NativeAgentMobileTests.wave9.streamingHint.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "NativeAgent.unifiedSession.v1")
        defer { defaults.removePersistentDomain(forName: suite) }
        let secret = Data(repeating: 0x5A, count: 32)
        let pairing = PairingStore()
        pairing.iCloudPairingSecret = secret
        defer { pairing.iCloudPairingSecret = nil }
        let cloud = MockDeviceCloud()
        let ios = MockDeviceSyncTransport(role: .ios, cloud: cloud)
        let mac = MockDeviceSyncTransport(role: .mac, cloud: cloud)
        let bridge = iCloudBridge(deviceTransport: ios, pairingStore: pairing, userDefaults: defaults)
        let client = MacBridgeClient(bridge: bridge)
        let store = ChatStore(defaults: defaults, restoreQueuedSends: false, iCloudReplyTimeoutSeconds: 1)
        let observer = client.observeICloudReplies { store.receiveICloudReply($0) }
        defer { client.removeICloudReplyObserver(observer) }
        // bridge.setup() owns this registration in production but also touches
        // shared singletons; mirror its exact incoming closure here, awaited so
        // the registration cannot race the first mac→ios drain.
        await ios.observeIncoming { [weak bridge] message in
            await bridge?.handleIncomingFromTransport(message) ?? false
        }
        let recorder = Wave9BridgeRecorder()
        await mac.observeIncoming { message in await recorder.append(message); return true }

        XCTAssertEqual(store.send(text: "check", client: client, emitHaptic: false), .started)
        // The mock transport delivers explicitly via drainIncoming() (no
        // background timers), and the store's send lands in the cloud from an
        // internal task — so poll drain-then-check under a bounded deadline.
        let sendDeadline = Date().addingTimeInterval(5)
        while Date() < sendDeadline {
            _ = await mac.drainIncoming()
            // Both legs must land: the Mac transport observed the outbound AND
            // the store's send task registered its pending placeholder (that
            // registration happens after the transport send returns, so the
            // recorder alone can win the race).
            if await recorder.first() != nil, store.hasPendingICloudReplies { break }
            await Task.yield()
        }
        XCTAssertTrue(store.hasPendingICloudReplies)
        let firstOutbound = await recorder.first()
        let outbound = try XCTUnwrap(firstOutbound)
        let progress = try BridgeMessage.make(sender: "mac", text: "Reading calendar", sessionID: outbound.sessionID, correlationID: outbound.id, metadata: ["kind": "progress"]).signed(with: secret)
        try await mac.send(progress)
        _ = await ios.drainIncoming()
        let placeholder = try XCTUnwrap(store.messages.last(where: { $0.role == .assistant }))
        XCTAssertEqual(store.streamingHint(for: placeholder), "Reading calendar")

        let toolUse = try BridgeMessage.make(sender: "mac", text: "calendar.search", sessionID: outbound.sessionID, correlationID: outbound.id, metadata: ["kind": "tool_use", "toolSeq": "1"]).signed(with: secret)
        try await mac.send(toolUse)
        _ = await ios.drainIncoming()
        let afterTool = try XCTUnwrap(store.messages.last(where: { $0.id == placeholder.id }))
        XCTAssertEqual(afterTool.toolEvents.map(\.name), ["calendar.search"])
        XCTAssertNotEqual(store.streamingHint(for: afterTool), "Reading calendar")

        let delta = try BridgeMessage.make(sender: "mac", text: "Found your next event", sessionID: outbound.sessionID, correlationID: outbound.id, metadata: ["kind": "text_delta", "seq": "1"]).signed(with: secret)
        try await mac.send(delta)
        _ = await ios.drainIncoming()
        XCTAssertNotEqual(store.streamingHint(for: placeholder), "Reading calendar")

        let final = try BridgeMessage.make(sender: "mac", text: "Found your next event.", sessionID: outbound.sessionID, correlationID: outbound.id, metadata: ["kind": "final"]).signed(with: secret)
        try await mac.send(final)
        _ = await ios.drainIncoming()
        XCTAssertFalse(store.messages.last?.isStreaming ?? true)
        XCTAssertFalse(store.hasPendingICloudReplies)

        // A fresh mounted store uses the completed transport lifecycle's
        // persisted transcript, not the original instance's memory.
        let relaunchedStore = ChatStore(defaults: defaults, restoreQueuedSends: false, iCloudReplyTimeoutSeconds: 1)
        XCTAssertEqual(relaunchedStore.messages.last?.text, "Found your next event.")

        let timeoutStore = ChatStore(defaults: defaults, restoreQueuedSends: false, iCloudReplyTimeoutSeconds: 0)
        XCTAssertEqual(timeoutStore.send(text: "timeout", client: client, emitHaptic: false), .started)
        let timeoutDeadline = Date().addingTimeInterval(5)
        while Date() < timeoutDeadline, timeoutStore.errorBanner == nil { await Task.yield() }
        XCTAssertTrue(timeoutStore.errorBanner?.contains("Reply timed out") == true)
    }
}
