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
}
