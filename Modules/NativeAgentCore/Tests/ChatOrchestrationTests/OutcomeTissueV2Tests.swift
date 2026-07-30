@testable import ChatOrchestration
import CryptoKit
import Foundation
import NativeAgentCore
import PersistenceCore
import Testing

@Suite("Outcome Tissue V2")
struct OutcomeTissueV2Tests {
    @Test("response observation is closed, payload-free, and carries pre-outcome assignment")
    func responseObservationContract() throws {
        let result = TurnEngineResult(
            reply: "private completion that must not appear",
            modelUsed: "gpt-5.6",
            recalledIds: ["memory-private"],
            toolDispatches: [
                .init(
                    id: "provider-tool-call-1",
                    name: "read_file",
                    input: ["path": .string("/Users/secret")],
                    result: .object(["status": .string("ok"), "content": .string("secret")])
                ),
            ],
            elapsedMs: 120,
            rawLLMResponse: "private raw output",
            terminalObservation: .init(
                reasoningEffort: "high",
                toolSchemaCount: 4,
                contextSource: "fluid_context",
                contextSelectedAtomCount: 3,
                contextPacketCharacters: 900,
                contextExpandablePointerCount: 1
            )
        )
        let assignment = CausalInterventionAssignment(
            assignmentID: "assignment-1",
            intervention: "reasoning-high",
            evidenceClass: .generatedMechanism
        )
        let observation = try #require(OutcomeInterventionContext.$assignment.withValue(assignment) {
            ResponseOutcomeObservationV2.make(
                turnID: "turn-1",
                messageID: "message-1",
                sessionID: "session-1",
                surface: "chat",
                observedAt: Date(timeIntervalSince1970: 1_800_000_000),
                responsePersistence: "persisted",
                result: result
            )
        })
        #expect(observation.tools.count == 1)
        #expect(observation.tools[0].callID.count == 64)
        #expect(observation.tools[0].resultClass == "succeeded")
        #expect(observation.dimensionStates["provider"] == .unknown)
        #expect(observation.interventionAssignment == assignment)
        let raw = try observation.jsonValue.serialize(pretty: false)
        #expect(!raw.contains("private completion"))
        #expect(!raw.contains("private raw output"))
        #expect(!raw.contains("memory-private"))
        #expect(!raw.contains("/Users/secret"))
        #expect(!raw.contains("provider-tool-call-1"))
        #expect(ResponseOutcomeObservationV2(jsonValue: observation.jsonValue) == observation)
    }

    @Test("explicit live assignment wins over task-local laboratory context")
    func explicitAssignmentPrecedence() throws {
        let laboratory = CausalInterventionAssignment(
            assignmentID: "laboratory", intervention: "context_breadth",
            evidenceClass: .generatedMechanism
        )
        let live = CausalInterventionAssignment(
            assignmentID: "live-assignment", intervention: "reasoning_effort",
            evidenceClass: .controlledProduction,
            experimentID: "effort-canary", taskScenarioFamily: "coding",
            treatment: "high", baseline: "medium",
            eligibleAlternatives: ["medium", "high"], chosenAlternative: "high",
            confounderFlags: [], coverageFlags: ["adaptive", "five_percent"]
        )
        let observation = try #require(OutcomeInterventionContext.$assignment.withValue(laboratory) {
            ResponseOutcomeObservationV2.make(
                turnID: "turn-live", messageID: "message-live", sessionID: "session-live",
                surface: "chat", observedAt: Date(timeIntervalSince1970: 1_800_000_000),
                responsePersistence: "persisted", interventionAssignment: live
            )
        })
        #expect(observation.interventionAssignment == live)
    }

    @Test("invalid explicit assignment fails closed instead of falling through")
    func invalidExplicitAssignmentFailsClosed() throws {
        let laboratory = CausalInterventionAssignment(
            assignmentID: "laboratory", intervention: "context_breadth",
            evidenceClass: .generatedMechanism
        )
        let invalid = CausalInterventionAssignment(
            assignmentID: "/Users/private/payload", intervention: "reasoning_effort",
            evidenceClass: .controlledProduction,
            experimentID: "effort-canary", taskScenarioFamily: "coding",
            treatment: "high", baseline: "medium",
            eligibleAlternatives: ["medium", "high"], chosenAlternative: "high",
            confounderFlags: [], coverageFlags: ["adaptive", "five_percent"]
        )
        let observation = try #require(OutcomeInterventionContext.$assignment.withValue(laboratory) {
            ResponseOutcomeObservationV2.make(
                turnID: "turn-invalid", messageID: "message-invalid", sessionID: "session-invalid",
                surface: "chat", observedAt: Date(timeIntervalSince1970: 1_800_000_000),
                responsePersistence: "persisted", interventionAssignment: invalid
            )
        })
        #expect(observation.interventionAssignment == nil)

        let oversized = CausalInterventionAssignment(
            assignmentID: String(repeating: "a", count: 129),
            intervention: "reasoning_effort", evidenceClass: .controlledProduction,
            experimentID: "effort-canary", taskScenarioFamily: "coding",
            treatment: "high", baseline: "medium",
            eligibleAlternatives: ["medium", "high"], chosenAlternative: "high",
            confounderFlags: [], coverageFlags: ["adaptive", "five_percent"]
        )
        let oversizedObservation = try #require(ResponseOutcomeObservationV2.make(
            turnID: "turn-oversized", messageID: "message-oversized", sessionID: "session-oversized",
            surface: "chat", observedAt: Date(timeIntervalSince1970: 1_800_000_000),
            responsePersistence: "persisted", interventionAssignment: oversized
        ))
        #expect(oversizedObservation.interventionAssignment == nil)
    }

    @Test("tool prose never becomes an authoritative success fact")
    func toolProseStaysUnknown() throws {
        let result = TurnEngineResult(
            reply: "done", modelUsed: "model-a", recalledIds: [],
            toolDispatches: [.init(
                id: "tool-1", name: "read_file", input: [:],
                result: .object(["content": .string("successfully completed")])
            )],
            elapsedMs: 1, rawLLMResponse: "done"
        )
        let observation = try #require(ResponseOutcomeObservationV2.make(
            turnID: "turn-tool-prose", messageID: "message-tool-prose",
            sessionID: "session-tool-prose", surface: "chat",
            observedAt: Date(timeIntervalSince1970: 1_800_000_000),
            responsePersistence: "persisted", result: result
        ))
        #expect(observation.tools.first?.resultClass == "unknown")
        #expect(observation.dimensionStates["tools"] == .unverified)
    }

    @Test("motor anchors use exact owner locators and universal opaque identities")
    func exactMotorReferenceContract() throws {
        let workshopID = "11111111-1111-4111-8111-111111111111"
        let browserID = "22222222-2222-4222-8222-222222222222"
        let macID = "33333333-3333-4333-8333-333333333333"
        let approvalID = "44444444-4444-4444-8444-444444444444"
        let result = TurnEngineResult(
            reply: "done", modelUsed: "gpt-5.6", recalledIds: [],
            toolDispatches: [
                .init(name: "workshop_submit", input: [:], result: .object([
                    "id": .string(workshopID),
                    "status": .string("completed"),
                    "procedure_verified": .bool(true),
                ])),
                .init(name: "browser.navigate", input: [:], result: .object([
                    // App browser results use runId; the response anchor must
                    // bind the same owner key as resident cognition does.
                    "runId": .string(browserID),
                    "actionId": .string("browser.navigate"),
                    "status": .string("succeeded"),
                    "opened": .bool(true),
                ])),
                .init(name: "mac_focus_app", input: [:], result: .object([
                    "operationId": .string(macID),
                    "verification": .string("satisfied"),
                ])),
                .init(name: "external_send", input: [:], result: .object([
                    "actionId": .string("slack.post_message"),
                    "approvalId": .string(approvalID),
                    "status": .string("pending_approval"),
                ])),
                // Builder run ids have no shared motor owner and must not be
                // mislabeled as a late-settleable action.
                .init(name: "shell", input: [:], result: .object([
                    "runId": .string("builder-run-1"),
                    "status": .string("completed"),
                ])),
            ],
            elapsedMs: 1, rawLLMResponse: "done"
        )
        let observation = try #require(ResponseOutcomeObservationV2.make(
            turnID: "turn-motor", messageID: "message-motor",
            sessionID: "session-motor", surface: "chat",
            observedAt: Date(timeIntervalSince1970: 1_800_000_000),
            responsePersistence: "persisted", result: result
        ))

        #expect(observation.motorActions.count == 4)
        let byDomain = Dictionary(uniqueKeysWithValues: observation.motorActions.map {
            ($0.domain, $0)
        })
        #expect(byDomain["workshop_execution"]?.ownerActionID == workshopID)
        #expect(byDomain["workshop_execution"]?.verification == .verified)
        #expect(byDomain["browser"]?.ownerActionID == browserID)
        #expect(byDomain["browser"]?.verification == .verified)
        #expect(byDomain["mac_control"]?.ownerActionID == macID)
        #expect(byDomain["mac_control"]?.verification == .verified)
        #expect(byDomain["external_send"]?.ownerActionID == approvalID)
        #expect(byDomain["external_send"]?.verification == .unknown)
        #expect(observation.dimensionStates["motor"] == .unknown)
        for reference in observation.motorActions {
            let raw = try #require(reference.ownerActionID)
            #expect(reference.actionID == CausalTransitionEvidence.opaqueIdentity(raw))
        }
        #expect(!observation.motorActions.contains { $0.ownerActionID == "builder-run-1" })
        #expect(ResponseOutcomeObservationV2(jsonValue: observation.jsonValue) == observation)
    }

    @Test("canonical motor verification vocabulary preserves evidence quality")
    func canonicalMotorVerificationVocabulary() throws {
        let states: [(String, OutcomeEvidenceState)] = [
            ("satisfied", .verified),
            ("failed", .verified),
            ("unverified", .unverified),
            ("unknown", .unknown),
            ("pending", .observed),
            ("not_started", .observed),
            ("not_required", .observed),
        ]
        for (index, expected) in states.enumerated() {
            let id = String(format: "00000000-0000-4000-8000-%012d", index + 1)
            let result = TurnEngineResult(
                reply: "done", modelUsed: "gpt-5.6", recalledIds: [],
                toolDispatches: [.init(
                    name: "mac_focus_app",
                    input: [:],
                    result: .object([
                        "operationId": .string(id),
                        "verification": .string(expected.0),
                    ])
                )],
                elapsedMs: 1,
                rawLLMResponse: "done"
            )
            let observation = try #require(ResponseOutcomeObservationV2.make(
                turnID: "turn-verification-\(index)",
                messageID: "message-verification-\(index)",
                sessionID: "session-verification",
                surface: "chat",
                observedAt: Date(timeIntervalSince1970: 1_800_000_000),
                responsePersistence: "persisted",
                result: result
            ))
            #expect(observation.motorActions.first?.verification == expected.1)
            #expect(observation.dimensionStates["motor"] == expected.1)
        }
    }

    @Test("duplicate actions and dry runs do not manufacture motor evidence")
    func duplicateAndDryRunMotorReferences() throws {
        let approvalID = "55555555-5555-4555-8555-555555555555"
        let staged: JSONValue = .object([
            "approvalId": .string(approvalID),
            "status": .string("pending_approval"),
        ])
        let result = TurnEngineResult(
            reply: "done", modelUsed: "gpt-5.6", recalledIds: [],
            toolDispatches: [
                .init(name: "slack_post_message", input: [:], result: staged),
                .init(name: "slack_post_message", input: [:], result: staged),
                .init(name: "browser.navigate", input: [:], result: .object([
                    "id": .string("66666666-6666-4666-8666-666666666666"),
                    "status": .string("dry_run"),
                    "dryRun": .bool(true),
                ])),
            ],
            elapsedMs: 1,
            rawLLMResponse: "done"
        )
        let observation = try #require(ResponseOutcomeObservationV2.make(
            turnID: "turn-motor-dedupe", messageID: "message-motor-dedupe",
            sessionID: "session-motor-dedupe", surface: "chat",
            observedAt: Date(timeIntervalSince1970: 1_800_000_000),
            responsePersistence: "persisted", result: result
        ))
        #expect(observation.motorActions.count == 1)
        #expect(observation.motorActions.first?.domain == "external_send")
        #expect(observation.dimensionStates["motor"] == .unknown)
    }

    @Test("owner locators retain only canonical non-payload identifiers")
    func ownerLocatorPrivacy() throws {
        let result = TurnEngineResult(
            reply: "done", modelUsed: "gpt-5.6", recalledIds: [],
            toolDispatches: [.init(
                name: "mac_focus_app", input: [:],
                result: .object([
                    "operationId": .string("user-supplied-private-label"),
                    "verification": .string("satisfied"),
                ])
            )],
            elapsedMs: 1, rawLLMResponse: "done"
        )
        let observation = try #require(ResponseOutcomeObservationV2.make(
            turnID: "turn-owner-privacy", messageID: "message-owner-privacy",
            sessionID: "session-owner-privacy", surface: "chat",
            observedAt: Date(timeIntervalSince1970: 1_800_000_000),
            responsePersistence: "persisted", result: result
        ))
        let reference = try #require(observation.motorActions.first)
        #expect(reference.ownerActionID == nil)
        #expect(reference.actionID == CausalTransitionEvidence.opaqueIdentity(
            "user-supplied-private-label"
        ))
        #expect(!((try? observation.jsonValue.serialize(pretty: false)) ?? "")
            .contains("user-supplied-private-label"))
    }

    @Test("historical reconstruction joins supported rows and leaves missing evidence censored")
    func boundedHistoricalReconstruction() throws {
        let root = temporaryRoot("reconstruct")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let anchor = makeAnchor(turnID: "turn-a", messageID: "message-a", observedAt: now)
        let transcriptPath = root.appendingPathComponent("chat/messages/session-a.jsonl")
        try writeLines([transcriptRow(anchor)], to: transcriptPath)
        let tracePath = TurnTracePersistLane(dataRootOverride: root).path(for: now)
        try writeLines([
            TurnTraceEvent(
                turnId: "turn-a", ts: now.addingTimeInterval(-1), kind: "llm.call",
                sessionId: "session-a", surface: "chat",
                payload: .object([
                    "provider": .string("openai"), "model": .string("gpt-5.6"),
                    "durationMs": .int(100),
                ])
            ).jsonRow,
            terminal(turnID: "turn-a", now: now).jsonRow,
            .string("corrupt-supported-row"),
        ], to: tracePath)
        let feedbackPath = root.appendingPathComponent("context/feedback.jsonl")
        try writeLines([.object([
            "schema": .string(OutcomeFeedbackStore.schema),
            "eventId": .string("feedback-a"),
            "messageId": .string("message-a"),
            "turnId": .string("turn-a"),
            "sessionId": .string("session-a"),
            "reaction": .string("thumbs_up"),
            "observedAt": .string(iso(now.addingTimeInterval(1))),
            "payloadFree": .bool(true),
            "controlAuthority": .bool(false),
        ])], to: feedbackPath)

        let sourceBefore = try sourceDigest([transcriptPath, tracePath, feedbackPath])
        let report = try OutcomeTissueHistoricalReconstructor(dataRoot: root).reconstruct(now: now.addingTimeInterval(2))
        let sourceAfter = try sourceDigest([transcriptPath, tracePath, feedbackPath])
        let turn = try #require(report.turns.first)
        #expect(report.turns.count == 1)
        #expect(turn.providerFactCount == 1)
        #expect(turn.motorFactCount == 0)
        #expect(turn.explicitReactionCount == 1)
        #expect(turn.currentExactReaction?.kind == .thumbsUp)
        #expect(turn.currentExactReaction?.evidenceID == "feedback-a")
        #expect(turn.dimensionStates["provider"] == .observed)
        #expect(turn.dimensionStates["motor"] == .notApplicable)
        #expect(report.rejectedTraceRowCount == 1)
        #expect(sourceBefore == sourceAfter)
    }

    @Test("late canonical motor facts settle the response anchor without becoming authority")
    func historicalMotorSettlementJoin() throws {
        let root = temporaryRoot("motor-settlement")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let approvalID = "77777777-7777-4777-8777-777777777777"
        let actionIdentity = CausalTransitionEvidence.opaqueIdentity(approvalID)
        let anchor = makeAnchor(
            turnID: "turn-motor-late",
            messageID: "message-motor-late",
            observedAt: now,
            motorActions: [ResponseOutcomeMotorReference(
                actionID: actionIdentity,
                ownerActionID: approvalID,
                domain: "external_send",
                verification: .unknown
            )]
        )
        try writeLines(
            [transcriptRow(anchor)],
            to: root.appendingPathComponent("chat/messages/session-a.jsonl")
        )
        let tracePath = TurnTracePersistLane(dataRootOverride: root).path(for: now)
        try writeLines([
            TurnTraceEvent(
                turnId: "motor-\(actionIdentity)",
                ts: now.addingTimeInterval(1),
                kind: "motor.state",
                payload: .object([
                    "schema": .string("motor.action.read-model.v1"),
                    "domain": .string("external_send"),
                    "actionIdentity": .string(actionIdentity),
                    "phase": .string("waiting_external"),
                    "domainState": .string("outcomeUnknown"),
                    "verification": .string("unknown"),
                    "payloadFree": .bool(true),
                    "controlAuthority": .bool(false),
                ])
            ).jsonRow,
            TurnTraceEvent(
                turnId: "motor-\(actionIdentity)",
                ts: now.addingTimeInterval(2),
                kind: "motor.state",
                payload: .object([
                    "schema": .string("motor.action.read-model.v1"),
                    "domain": .string("external_send"),
                    "actionIdentity": .string(actionIdentity),
                    "phase": .string("succeeded"),
                    "domainState": .string("providerAccepted"),
                    "verification": .string("unverified"),
                    "payloadFree": .bool(true),
                    "controlAuthority": .bool(false),
                ])
            ).jsonRow,
        ], to: tracePath)

        let report = try OutcomeTissueHistoricalReconstructor(dataRoot: root)
            .reconstruct(now: now.addingTimeInterval(3))
        let turn = try #require(report.turns.first)
        #expect(turn.motorFactCount == 1)
        #expect(turn.dimensionStates["motor"] == .unverified)
    }

    @Test("equal-time contradictory motor facts remain ambiguous")
    func contradictoryMotorSettlementIsNotGuessed() throws {
        let root = temporaryRoot("motor-ambiguous")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let actionIdentity = CausalTransitionEvidence.opaqueIdentity("approval-ambiguous")
        let anchor = makeAnchor(
            turnID: "turn-motor-ambiguous",
            messageID: "message-motor-ambiguous",
            observedAt: now,
            motorActions: [ResponseOutcomeMotorReference(
                actionID: actionIdentity,
                domain: "external_send",
                verification: .unknown
            )]
        )
        try writeLines(
            [transcriptRow(anchor)],
            to: root.appendingPathComponent("chat/messages/session-a.jsonl")
        )
        let tiedAt = now.addingTimeInterval(1)
        let tracePath = TurnTracePersistLane(dataRootOverride: root).path(for: now)
        let payload: (String, String, String) -> JSONValue = { phase, state, verification in
            .object([
                "schema": .string("motor.action.read-model.v1"),
                "domain": .string("external_send"),
                "actionIdentity": .string(actionIdentity),
                "phase": .string(phase),
                "domainState": .string(state),
                "verification": .string(verification),
                "payloadFree": .bool(true),
                "controlAuthority": .bool(false),
            ])
        }
        try writeLines([
            TurnTraceEvent(
                turnId: "motor-\(actionIdentity)", ts: tiedAt, kind: "motor.state",
                payload: payload("succeeded", "providerAccepted", "unverified")
            ).jsonRow,
            TurnTraceEvent(
                turnId: "motor-\(actionIdentity)", ts: tiedAt, kind: "motor.state",
                payload: payload("failed", "remoteRejected", "failed")
            ).jsonRow,
        ], to: tracePath)

        let report = try OutcomeTissueHistoricalReconstructor(dataRoot: root)
            .reconstruct(now: now.addingTimeInterval(2))
        let turn = try #require(report.turns.first)
        #expect(turn.motorFactCount == 0)
        #expect(turn.dimensionStates["motor"] == .unknown)
    }

    @Test("duplicate transcript anchors are rejected rather than guessed")
    func duplicateAnchorsFailClosed() throws {
        let root = temporaryRoot("duplicate")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = makeAnchor(turnID: "turn-a", messageID: "message-a", observedAt: now)
        let second = makeAnchor(turnID: "turn-a", messageID: "message-b", observedAt: now)
        try writeLines(
            [transcriptRow(first), transcriptRow(second)],
            to: root.appendingPathComponent("chat/messages/session-a.jsonl")
        )
        let report = try OutcomeTissueHistoricalReconstructor(dataRoot: root).reconstruct(now: now)
        #expect(report.turns.isEmpty)
        #expect(report.rejectionReasons["ambiguous_duplicate_anchor"] == 2)
    }

    @Test("out-of-window anchors never enter the 14-day report")
    func retentionWindowIsBounded() throws {
        let root = temporaryRoot("retention")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = makeAnchor(
            turnID: "turn-old", messageID: "message-old",
            observedAt: now.addingTimeInterval(-15 * 24 * 60 * 60)
        )
        try writeLines(
            [transcriptRow(old)],
            to: root.appendingPathComponent("chat/messages/session-a.jsonl")
        )
        let report = try OutcomeTissueHistoricalReconstructor(dataRoot: root).reconstruct(now: now)
        #expect(report.turns.isEmpty)
        #expect(report.rejectionReasons["anchor_outside_window"] == 1)
    }

    private func makeAnchor(
        turnID: String,
        messageID: String,
        observedAt: Date,
        motorActions: [ResponseOutcomeMotorReference] = []
    ) -> ResponseOutcomeObservationV2 {
        ResponseOutcomeObservationV2(
            turnID: turnID,
            messageID: messageID,
            sessionID: "session-a",
            surface: "chat",
            observedAt: iso(observedAt),
            responsePersistence: "persisted",
            contextGenerationID: 7,
            contextSelectionReceiptID: "selection-a",
            providerModel: "gpt-5.6",
            reasoningEffort: "high",
            turnElapsedMs: 110,
            tools: [],
            motorActions: motorActions,
            dimensionStates: [
                "responsePersistence": .observed,
                "context": .observed,
                "provider": .censored,
                "tools": .observed,
                "motor": motorActions.isEmpty ? .notApplicable : .unknown,
                "reaction": .unknown,
            ],
            interventionAssignment: nil
        )
    }

    private func transcriptRow(_ anchor: ResponseOutcomeObservationV2) -> JSONValue {
        .object([
            "id": .string(anchor.messageID),
            "sessionId": .string(anchor.sessionID),
            "role": .string("assistant"),
            "content": .string("private transcript content"),
            "createdAt": .string(anchor.observedAt),
            "metadata": .object(["outcomeObservation": anchor.jsonValue]),
        ])
    }

    private func terminal(turnID: String, now: Date) -> TurnTraceEvent {
        TurnTraceEvent(
            turnId: turnID, ts: now, kind: "turn.terminal",
            sessionId: "session-a", surface: "chat",
            payload: .object([
                "schema": .string("metacognition.observed.v1"),
                "status": .string("completed"),
                "modelUsed": .string("gpt-5.6"),
                "reasoningEffort": .string("high"),
                "turnElapsedMs": .int(100),
                "contextSource": .string("fluid_context"),
                "contextSelectedAtomCount": .int(1),
                "contextPacketCharacters": .int(100),
                "contextExpandablePointerCount": .int(0),
                "toolSchemaCount": .int(0),
                "recalledMemoryCount": .int(0),
                "toolDispatchCount": .int(0),
                "failedToolDispatchCount": .int(0),
                "contextExpansionCount": .int(0),
            ])
        )
    }

    private func writeLines(_ rows: [JSONValue], to path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let raw = try rows.map { try $0.serialize(pretty: false) }.joined(separator: "\n") + "\n"
        try Data(raw.utf8).write(to: path)
    }

    private func sourceDigest(_ paths: [URL]) throws -> String {
        let bytes = try paths.sorted { $0.path < $1.path }.reduce(into: Data()) {
            $0.append(try Data(contentsOf: $1))
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private func temporaryRoot(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("outcome-tissue-\(suffix)-\(UUID().uuidString)", isDirectory: true)
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
