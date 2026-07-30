import Foundation
@testable import NativeAgentEvaluation
import Testing
@testable import ChatOrchestration
import CognitiveSubstrate
import NativeAgentCore
import PersistenceCore
import SystemOps
import TrustCenter

private func makeTurnPlanTempRoot(_ tag: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("turnplan-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func fixedTurnPlanDate() -> Date {
    ISO8601DateFormatter().date(from: "2026-06-20T12:00:00Z")!
}

private func readTurnPlanTraceRows(_ root: URL) throws -> [[String: JSONValue]] {
    let path = root
        .appendingPathComponent("traces", isDirectory: true)
        .appendingPathComponent("events.jsonl")
    let text = try String(contentsOf: path, encoding: .utf8)
    return text
        .split(separator: "\n", omittingEmptySubsequences: true)
        .compactMap { line in
            guard case .object(let obj)? = try? JSONValue.parse(Data(line.utf8)) else {
                return nil
            }
            return obj
        }
}

private func makePlanner(root: URL, id: String = "turn-plan-test") -> TurnPlanner {
    TurnPlanner(
        dataRoot: root,
        router: SwiftNativeRouterPlanClient(
            now: { fixedTurnPlanDate() },
            idFactory: { id }
        ),
        clock: { fixedTurnPlanDate() }
    )
}

@Suite("TurnPlanning")
struct TurnPlanningTests {
    @Test("build task produces capability context and builder preload")
    func buildTaskPlan() async throws {
        let root = try makeTurnPlanTempRoot("build")
        let plan = try await makePlanner(root: root).plan(
            message: "swift build is failing",
            surface: "chat",
            sessionId: "session-1",
            fileAccess: "auto",
            approvalAvailable: true
        )

        #expect(plan.goalType == "build_task")
        #expect(plan.contextMode == "capability")
        #expect(plan.recommendedSurface == "chat")
        #expect(plan.requiresApprovalHint == false)
        #expect(plan.preloadGroupNames.contains("builder"))
        #expect(plan.policySnapshot.fullMacActive == false)
        #expect(plan.policySnapshot.surfaceTrusted == true)
        #expect(plan.policySnapshot.policyDecision?.policySource == "turn_plan")
        #expect(plan.policySnapshot.policyDecision?.outcome == .allow)
        #expect(plan.policySnapshot.policyDecision?.requestedAction == "build_task")
        #expect(plan.contextHint?.contains("goal=build_task") == true)
        #expect(plan.contextHint?.contains("preload=builder") == true)
    }

    // FIX 2 / B1.2: connector-target routing. github-shaped requests used to
    // fall to chat/minimal; now they route to a `connector` goal on a
    // `capability` context, and a mutating connector verb carries risk=high +
    // an approval hint instead of the chat low-risk default.
    @Test("read-only github request routes to connector goal at low risk")
    func connectorReadPlan() async throws {
        let root = try makeTurnPlanTempRoot("connector-read")
        let plan = try await makePlanner(root: root).plan(
            message: "list my open github pull requests",
            surface: "chat",
            sessionId: "session-conn-1",
            fileAccess: "auto",
            approvalAvailable: true
        )

        #expect(plan.goalType == "connector")
        #expect(plan.contextMode == "capability")
        #expect(plan.recommendedSurface == "chat")
        #expect(plan.risk == "low")
        #expect(plan.requiresApprovalHint == false)
        #expect(plan.contextHint?.contains("goal=connector") == true)
    }

    @Test("mutating github request carries high risk and an approval hint")
    func connectorMutatePlan() async throws {
        let root = try makeTurnPlanTempRoot("connector-mutate")
        let plan = try await makePlanner(root: root).plan(
            message: "merge the github pull request and close the issue",
            surface: "chat",
            sessionId: "session-conn-2",
            fileAccess: "auto",
            approvalAvailable: true
        )

        #expect(plan.goalType == "connector")
        #expect(plan.contextMode == "capability")
        #expect(plan.risk == "high")
        #expect(plan.requiresApprovalHint == true)
        #expect(plan.contextHint?.contains("approval_hint=true") == true)
    }

    // FIX 3 / B1.3: TurnPlanTraceRecorder.append is now fire-and-forget off the
    // TTFT path — the file-locked disk write runs on a serial writer chain. This
    // pins that per-turn ordering survives: five appends enqueued in order land
    // in the trace file in that same order.
    @Test("fire-and-forget trace appends preserve enqueue order")
    func traceAppendsPreserveOrder() async throws {
        let root = try makeTurnPlanTempRoot("trace-order")
        let plan = try await makePlanner(root: root, id: "order-plan").plan(
            message: "swift build is failing",
            surface: "chat",
            sessionId: "session-order",
            fileAccess: "auto",
            approvalAvailable: true
        )
        // Isolated writer so the assertion is independent of any concurrent test
        // enqueuing on the shared writer.
        let writer = TurnPlanTraceWriter()
        for i in 0..<5 {
            await TurnPlanTraceRecorder.append(
                plan,
                runId: "run-\(i)",
                surface: "chat",
                dataRoot: root,
                turnTraceBus: nil,
                now: fixedTurnPlanDate(),
                writer: writer
            )
        }
        await writer.drain()

        let rows = try readTurnPlanTraceRows(root)
        #expect(rows.count == 5)
        let runIds: [String] = rows.compactMap { row in
            guard case .object(let payload)? = row["payload"],
                  case .string(let runId)? = payload["runId"] else { return nil }
            return runId
        }
        #expect(runIds == ["run-0", "run-1", "run-2", "run-3", "run-4"])
    }

    @Test("memory update plan carries memory context without fake preload")
    func memoryUpdatePlan() async throws {
        let root = try makeTurnPlanTempRoot("memory")
        let plan = try await makePlanner(root: root).plan(
            message: "remember my preference for terse status updates",
            surface: "chat",
            sessionId: "session-2",
            fileAccess: "auto",
            approvalAvailable: true
        )

        #expect(plan.goalType == "memory_update")
        #expect(plan.contextMode == "memory")
        #expect(plan.matchedCapabilityIds.contains("feature:memory_system"))
        #expect(!plan.preloadGroupNames.contains("memory"))
        #expect(plan.contextHint?.contains("context=memory") == true)
    }

    @Test("fallback-only router rows do not become matched capability ids")
    func fallbackCapabilityRowsAreFiltered() async throws {
        let root = try makeTurnPlanTempRoot("fallback")
        let plan = try await makePlanner(root: root).plan(
            message: "qpzrn blarg",
            surface: "chat",
            sessionId: "session-3",
            fileAccess: "auto",
            approvalAvailable: true
        )

        #expect(plan.goalType == "chat")
        #expect(plan.contextMode == "minimal")
        #expect(plan.matchedCapabilityIds.isEmpty)
        #expect(plan.contextHint == nil)
    }

    @Test("single-letter x trigger noise is filtered from capability ids")
    func singleLetterXTriggerNoiseIsFiltered() async throws {
        let root = try makeTurnPlanTempRoot("x-noise")
        let plan = try await makePlanner(root: root).plan(
            message: "Codex bridge smoke includes swift build only for routing",
            surface: "chat",
            sessionId: "session-x-noise",
            fileAccess: "auto",
            approvalAvailable: true
        )

        #expect(plan.goalType == "build_task")
        #expect(!plan.matchedCapabilityIds.contains { $0.hasPrefix("connector_action:x.") })
    }

    @Test("git status requests plan as build capability turns")
    func gitStatusPlansAsBuildTask() async throws {
        let root = try makeTurnPlanTempRoot("git-status")
        let plan = try await makePlanner(root: root).plan(
            message: "check git status in the NativeAgent repo",
            surface: "chat",
            sessionId: "session-git-status",
            fileAccess: "auto",
            approvalAvailable: true
        )

        #expect(plan.goalType == "build_task")
        #expect(plan.contextMode == "capability")
        #expect(plan.preloadGroupNames.contains("builder"))
    }

    @Test("resident repo route supplies builder readiness when lexical preload misses")
    func dirtyRepoRouteOwnsBuilderReadiness() async throws {
        let root = try makeTurnPlanTempRoot("dirty-repo-readiness")
        let message = "Weve got a dirty repo because I did not have Codex commit anything until the upgrades were good; can you see what we did today?"
        #expect(ToolPreloadHeuristics.predict(userMessage: message) == nil)

        let plan = try await makePlanner(root: root).plan(
            message: message,
            surface: "telegram",
            sessionId: "session-dirty-repo",
            fileAccess: "auto",
            approvalAvailable: true
        )

        #expect(plan.goalType == "build_task")
        #expect(plan.preloadGroupNames.first == "builder")
        #expect(plan.preloadPrediction?.matchedPatterns.contains("resident-route:builder") == true)
        #expect(plan.preloadPrediction?.candidateTools.contains("git_status") == true)
    }

    @Test("generic find language does not turn resident readiness into web tooling")
    func genericFindDoesNotPreloadResearch() async throws {
        let root = try makeTurnPlanTempRoot("generic-find-readiness")
        let plan = try await makePlanner(root: root).plan(
            message: "Can you help me find my keys?",
            surface: "chat",
            sessionId: "session-generic-find",
            fileAccess: "auto",
            approvalAvailable: true
        )

        #expect(plan.goalType == "research")
        #expect(plan.preloadPrediction == nil)
    }

    @Test("repo stands requests plan as build capability turns")
    func repoStandsPlansAsBuildTask() async throws {
        let root = try makeTurnPlanTempRoot("repo-stands")
        let plan = try await makePlanner(root: root).plan(
            message: "Can you check where the NativeAgent repo stands right now? I just need the short version.",
            surface: "chat",
            sessionId: "session-repo-stands",
            fileAccess: "auto",
            approvalAvailable: true
        )

        #expect(plan.goalType == "build_task")
        #expect(plan.contextMode == "capability")
        #expect(plan.preloadGroupNames.contains("builder"))
    }

    @Test("calendar today requests carry day-scoped guidance")
    func calendarTodayCarriesDayScopedGuidance() async throws {
        let root = try makeTurnPlanTempRoot("calendar-today")
        let plan = try await makePlanner(root: root).plan(
            message: "do I have anything on my calendar today?",
            surface: "chat",
            sessionId: "session-calendar-today",
            fileAccess: "auto",
            approvalAvailable: true
        )

        #expect(plan.goalType == "schedule")
        #expect(plan.contextMode == "ops")
        #expect(plan.risk == "low")
        #expect(plan.requiresApprovalHint == false)
        #expect(plan.contextHint?.contains("day=today") == true)
        #expect(plan.contextHint?.contains("instead of a broad hours window") == true)
    }

    @Test("handoff doc requests plan as file capability turns")
    func handoffPlansAsFileWork() async throws {
        let root = try makeTurnPlanTempRoot("handoff")
        let plan = try await makePlanner(root: root).plan(
            message: "can you look at the NativeAgent handoff and tell me what the next risky thing is?",
            surface: "chat",
            sessionId: "session-handoff",
            fileAccess: "auto",
            approvalAvailable: true
        )

        #expect(plan.goalType == "file_work")
        #expect(plan.contextMode == "capability")
        #expect(plan.preloadGroupNames.contains("files"))
        #expect(plan.contextHint?.contains("goal=file_work") == true)
        #expect(plan.contextHint?.contains("preload=files") == true)
        #expect(plan.contextHint?.contains("first locate and read that artifact") == true)
        #expect(plan.contextHint?.contains("repo/git tools as secondary evidence") == true)
        #expect(plan.contextHint?.contains("For long docs or handoffs, prefer targeted file_excerpt or grep first") == true)
        #expect(plan.contextHint?.contains("read the full file only when the answer needs it") == true)
        #expect(plan.contextHint?.contains("docs/HANDOFF_CURRENT.md") == true)
        #expect(plan.contextHint?.contains("Do not answer requested files, docs, or handoffs from memory") == true)
        #expect(plan.contextHint?.contains("use agent_introspect only when the user asks about live runtime status") == true)
    }

    @Test("domain path research requests preload browser instead of files")
    func domainPathResearchPlansBrowserPreload() async throws {
        let root = try makeTurnPlanTempRoot("domain-browser")
        let plan = try await makePlanner(root: root).plan(
            message: "can you read openai.com/news and tell me the newest headline?",
            surface: "chat",
            sessionId: "session-domain-browser",
            fileAccess: "auto",
            approvalAvailable: true
        )

        #expect(plan.goalType == "research")
        #expect(plan.contextMode == "research")
        #expect(plan.preloadGroupNames.contains("browser"))
        #expect(!plan.preloadGroupNames.contains("files"))
        #expect(plan.contextHint?.contains("preload=browser") == true)
        #expect(plan.contextHint?.contains("official source") == true)
        #expect(plan.contextHint?.contains("search result") == true)
    }

    @Test("plain news search requests preload research tools")
    func plainNewsSearchPlansResearchPreload() async throws {
        let root = try makeTurnPlanTempRoot("plain-news")
        let plan = try await makePlanner(root: root).plan(
            message: "can you search for OpenAI news and tell me what useful links show up?",
            surface: "chat",
            sessionId: "session-plain-news",
            fileAccess: "auto",
            approvalAvailable: true
        )

        #expect(plan.goalType == "research")
        #expect(plan.contextMode == "research")
        #expect(plan.preloadGroupNames.contains("research"))
        #expect(!plan.preloadGroupNames.contains("builder"))
        #expect(plan.contextHint?.contains("preload=research") == true)
        #expect(plan.contextHint?.contains("social shortlink") == true)
        #expect(plan.contextHint?.contains("do not ask to continue") == true)
    }

    @Test("turn plan trace row stores metadata but not raw user message")
    func traceRowIsMetadataOnly() async throws {
        let root = try makeTurnPlanTempRoot("trace")
        let rawMessage = "swift build is failing with secret prompt sauce"
        let plan = try await makePlanner(root: root, id: "trace-plan").plan(
            message: rawMessage,
            surface: "chat",
            sessionId: "session-4",
            fileAccess: "read_only",
            approvalAvailable: false
        )

        await TurnPlanTraceRecorder.append(
            plan,
            runId: "run-123",
            surface: "chat",
            dataRoot: root,
            turnTraceBus: nil,
            now: fixedTurnPlanDate()
        )
        // FIX 3 / B1.3: the disk write is now fire-and-forget off the TTFT path;
        // drain the serial writer chain so the row has landed before we read it.
        await TurnPlanTraceWriter.shared.drain()

        let path = root
            .appendingPathComponent("traces", isDirectory: true)
            .appendingPathComponent("events.jsonl")
        let rawTrace = try String(contentsOf: path, encoding: .utf8)
        #expect(!rawTrace.contains(rawMessage))
        #expect(!rawTrace.contains("secret prompt sauce"))

        let rows = try readTurnPlanTraceRows(root)
        #expect(rows.count == 1)
        guard let row = rows.first else { return }
        if case .string(let kind)? = row["kind"] {
            #expect(kind == "turn.plan")
        } else {
            Issue.record("trace row missing kind")
        }
        guard case .object(let payload)? = row["payload"] else {
            Issue.record("trace row missing payload")
            return
        }
        if case .string(let goal)? = payload["goalType"] {
            #expect(goal == "build_task")
        } else {
            Issue.record("payload missing goalType")
        }
        if case .int(let chars)? = payload["messageChars"] {
            #expect(chars == Int64(rawMessage.count))
        } else {
            Issue.record("payload missing messageChars")
        }
        if case .string(let runId)? = payload["runId"] {
            #expect(runId == "run-123")
        } else {
            Issue.record("payload missing runId")
        }
        if case .bool(let approvalAvailable)? = payload["approvalAvailable"] {
            #expect(approvalAvailable == false)
        } else {
            Issue.record("payload missing approvalAvailable")
        }
        #expect(payload["metacognitiveShadow"] == nil)
        #expect(payload["turnId"] == nil)
        guard case .object(let policyDecision)? = payload["policyDecision"] else {
            Issue.record("payload missing policyDecision")
            return
        }
        if case .string(let outcome)? = policyDecision["outcome"] {
            #expect(outcome == "allow")
        } else {
            Issue.record("policyDecision missing outcome")
        }
        if case .string(let source)? = policyDecision["policySource"] {
            #expect(source == "turn_plan")
        } else {
            Issue.record("policyDecision missing policySource")
        }
        if case .string(let action)? = policyDecision["requestedAction"] {
            #expect(action == "build_task")
        } else {
            Issue.record("policyDecision missing requestedAction")
        }
        if case .bool(let remote)? = policyDecision["remoteSurface"] {
            #expect(remote == false)
        } else {
            Issue.record("policyDecision missing remoteSurface")
        }
    }

    @Test("metacognitive shadow recommends less machinery for minimal chat")
    func metacognitiveShadowMinimalChat() async throws {
        let root = try makeTurnPlanTempRoot("shadow-minimal")
        let plan = try await makePlanner(root: root).plan(
            message: "qpzrn blarg",
            surface: "chat",
            sessionId: "shadow-chat",
            fileAccess: "auto",
            approvalAvailable: true
        )
        let recommendation = MetacognitiveShadowEvaluator.recommend(plan: plan, posture: nil)
        #expect(recommendation.computeLane == .frontierStandard)
        #expect(recommendation.toolLane == .none)
        #expect(recommendation.contextLane == .minimal)
        #expect(recommendation.feasibleAffordances == ["respond"])
    }

    @Test("metacognitive shadow remains advisory under constrained posture")
    func metacognitiveShadowConstrainedPosture() async throws {
        let root = try makeTurnPlanTempRoot("shadow-posture")
        let plan = try await makePlanner(root: root).plan(
            message: "swift build is failing",
            surface: "chat",
            sessionId: "shadow-build",
            fileAccess: "auto",
            approvalAvailable: true
        )
        let posture = OrganismBehaviorPosture(
            generatedAt: fixedTurnPlanDate(),
            enabled: true,
            posture: "conserving",
            toolStrategy: .lightweightOnly,
            loopBudget: .conserve
        )
        let recommendation = MetacognitiveShadowEvaluator.recommend(plan: plan, posture: posture)
        #expect(recommendation.computeLane == .frontierStandard)
        #expect(recommendation.toolLane == .lazy)
        #expect(recommendation.contextLane == .planned)
        #expect(recommendation.reasonCodes.contains("organism_conserve"))
        #expect(recommendation.reasonCodes.contains("lightweight_posture"))
        guard case .object(let trace) = recommendation.traceValue else {
            Issue.record("shadow trace is not an object")
            return
        }
        #expect(trace["controlAuthority"] == .bool(false))
    }

    @Test("metacognitive evaluation compares recommendations with observed turn traces")
    func metacognitiveShadowEvaluation() {
        let plan = TurnTraceEvent(
            turnId: "turn-a",
            kind: "turn.plan",
            payload: .object([
                "metacognitiveShadow": .object([
                    "schema": .string("metacognition.shadow.v5"),
                    "computeLane": .string("frontier_standard"),
                    "toolLane": .string("lazy"),
                    "contextLane": .string("planned"),
                    "governor": .object([
                        "schema": .string("metacognition.governor.shadow.v1"),
                        "controlAuthority": .bool(false),
                        "selectedAffordance": .string("use_tools"),
                    ]),
                ]),
            ])
        )
        let provider = TurnTraceEvent(
            turnId: "turn-a",
            kind: "llm.call",
            payload: .object([
                "provider": .string("openai"),
                "model": .string("gpt-5.6"),
                "durationMs": .int(640),
            ])
        )
        let tool = TurnTraceEvent(
            turnId: "turn-a",
            kind: "tool.dispatch",
            payload: .object([
                "phase": .string("end"),
                "status": .string("ok"),
                "name": .string("context_expand"),
            ])
        )
        let terminal = TurnTraceEvent(
            turnId: "turn-a",
            kind: "turn.terminal",
            payload: .object([
                "schema": .string("metacognition.observed.v1"),
                "status": .string("completed"),
                "modelUsed": .string("gpt-5.6"),
                "reasoningEffort": .string("high"),
                "turnElapsedMs": .int(760),
                "contextSource": .string("fluid_context"),
                "contextSelectedAtomCount": .int(6),
                "contextPacketCharacters": .int(2_048),
                "contextExpandablePointerCount": .int(2),
                "toolSchemaCount": .int(12),
                "recalledMemoryCount": .int(3),
                "toolDispatchCount": .int(1),
                "failedToolDispatchCount": .int(0),
                "contextExpansionCount": .int(1),
            ])
        )
        let noToolPlan = TurnTraceEvent(
            turnId: "turn-b",
            kind: "turn.plan",
            payload: .object([
                "metacognitiveShadow": .object([
                    "schema": .string("metacognition.shadow.v5"),
                    "computeLane": .string("frontier_standard"),
                    "toolLane": .string("none"),
                    "contextLane": .string("minimal"),
                ]),
            ])
        )

        let evaluation = MetacognitiveShadowEvaluation.evaluate(
            events: [plan, provider, tool, terminal, noToolPlan]
        )
        #expect(evaluation.turns.count == 2)
        #expect(evaluation.toolLaneAgreementRate == 1)
        #expect(evaluation.correlatedTurnCount == 1)
        #expect(evaluation.incompleteCorrelationCount == 1)
        #expect(evaluation.correlationCoverageRate == 0.5)
        #expect(evaluation.evidenceStatus == .correlationIncomplete)
        #expect(evaluation.legacyExcludedRecommendationCount == 0)
        #expect(evaluation.completeObservedMeasurementCount == 1)
        #expect(evaluation.observedMeasurementCoverageRate == 0.5)
        #expect(evaluation.providerCounts == ["openai": 1])
        #expect(evaluation.modelCounts == ["gpt-5.6": 1])
        #expect(evaluation.providerModelCounts == ["gpt-5.6": 1])
        #expect(evaluation.reasoningEffortCounts == ["high": 1])
        #expect(evaluation.contextSourceCounts == ["fluid_context": 1])
        #expect(evaluation.affordanceCounts == ["use_tools": 1])
        #expect(evaluation.turnLatency.count == 1)
        #expect(evaluation.turnLatency.mean == 760)
        #expect(evaluation.providerLatency.mean == 640)
        #expect(evaluation.contextPacketCharacters.mean == 2_048)
        #expect(evaluation.contextSelectedAtoms.mean == 6)
        let first = evaluation.turns.first { $0.turnId == "turn-a" }
        #expect(first?.providerCallCount == 1)
        #expect(first?.toolDispatchCount == 1)
        #expect(first?.contextExpansionCount == 1)
        #expect(first?.failedToolDispatchCount == 0)
        #expect(first?.hasCompleteObservedMeasurements == true)
        #expect(first?.terminalModelUsed == "gpt-5.6")
        #expect(first?.terminalReasoningEffort == "high")
        #expect(first?.recommendedAffordance == "use_tools")

        let blankProvider = TurnTraceEvent(
            turnId: "turn-a",
            kind: "llm.call",
            payload: .object([
                "provider": .string("   "),
                "model": .string("gpt-5.6"),
                "durationMs": .int(640),
            ])
        )
        let blankEvaluation = MetacognitiveShadowEvaluation.evaluate(
            events: [plan, blankProvider, tool, terminal]
        )
        #expect(blankEvaluation.completeObservedMeasurementCount == 0)
        #expect(blankEvaluation.turns.first?.observedProviders.isEmpty == true)
    }

    @Test("provider receipt without terminal counts never proves a no-tool agreement")
    func metacognitiveShadowRequiresTerminalCounts() {
        let plan = TurnTraceEvent(
            turnId: "turn-dropped-tools",
            kind: "turn.plan",
            payload: .object([
                "metacognitiveShadow": .object([
                    "schema": .string("metacognition.shadow.v5"),
                    "computeLane": .string("frontier_standard"),
                    "toolLane": .string("none"),
                    "contextLane": .string("minimal"),
                ]),
            ])
        )
        let provider = TurnTraceEvent(turnId: "turn-dropped-tools", kind: "llm.call")
        let evaluation = MetacognitiveShadowEvaluation.evaluate(events: [plan, provider])
        #expect(evaluation.correlatedTurnCount == 0)
        #expect(evaluation.toolLaneAgreementRate == 0)
        #expect(evaluation.completeObservedMeasurementCount == 0)
        #expect(evaluation.observedMeasurementCoverageRate == 0)
    }

    @Test("metacognitive evaluation never fills missing observed measurements from recommendations")
    func metacognitiveShadowObservedMeasurementsFailClosed() {
        let plan = TurnTraceEvent(
            turnId: "turn-partial-observation",
            kind: "turn.plan",
            payload: .object([
                "metacognitiveShadow": .object([
                    "schema": .string("metacognition.shadow.v5"),
                    "computeLane": .string("frontier_deep"),
                    "toolLane": .string("none"),
                    "contextLane": .string("expanded"),
                ]),
            ])
        )
        let provider = TurnTraceEvent(
            turnId: "turn-partial-observation",
            kind: "llm.call",
            payload: .object(["provider": .string("anthropic")])
        )
        let terminal = TurnTraceEvent(
            turnId: "turn-partial-observation",
            kind: "turn.terminal",
            payload: .object([
                "status": .string("completed"),
                "toolDispatchCount": .int(0),
            ])
        )

        let evaluation = MetacognitiveShadowEvaluation.evaluate(events: [plan, provider, terminal])
        let turn = evaluation.turns.first
        #expect(turn?.hasCorrelatedProviderOutcome == true)
        #expect(turn?.hasCompleteObservedMeasurements == false)
        #expect(turn?.observedProviders == ["anthropic"])
        #expect(turn?.observedModels == [])
        #expect(turn?.providerDurationMs == nil)
        #expect(turn?.terminalModelUsed == nil)
        #expect(turn?.terminalReasoningEffort == nil)
        #expect(turn?.turnElapsedMs == nil)
        #expect(turn?.contextSource == nil)
        #expect(turn?.contextSelectedAtomCount == nil)
        #expect(evaluation.completeObservedMeasurementCount == 0)
        #expect(evaluation.modelCounts.isEmpty)
        #expect(evaluation.turnLatency.count == 0)
        #expect(evaluation.turnLatency.mean == nil)
    }

    @Test("metacognitive evaluation never scores an uncorrelated no-tool plan as agreement")
    func metacognitiveShadowIncompleteTraceFailsClosed() {
        let plan = TurnTraceEvent(
            turnId: "turn-unjoined",
            kind: "turn.plan",
            surface: "telegram",
            payload: .object([
                "metacognitiveShadow": .object([
                    "schema": .string("metacognition.shadow.v5"),
                    "computeLane": .string("frontier_standard"),
                    "toolLane": .string("none"),
                    "contextLane": .string("minimal"),
                ]),
            ])
        )

        let evaluation = MetacognitiveShadowEvaluation.evaluate(events: [plan])
        #expect(evaluation.turns.count == 1)
        #expect(evaluation.correlatedTurnCount == 0)
        #expect(evaluation.incompleteCorrelationCount == 1)
        #expect(evaluation.correlationCoverageRate == 0)
        #expect(evaluation.toolLaneAgreementRate == 0)
        #expect(evaluation.evidenceStatus == .correlationIncomplete)
        #expect(evaluation.surfaceCounts == ["telegram": 1])
        #expect(evaluation.turns[0].toolLaneMatchedObservedUse == false)
    }

    @Test("metacognitive v5 starts a terminal-counted hermetic epoch and reports earlier rows")
    func metacognitiveShadowExcludesLegacyCorrelationEpoch() {
        let legacy = TurnTraceEvent(
            turnId: "legacy-turn",
            kind: "turn.plan",
            payload: .object([
                "metacognitiveShadow": .object([
                    "schema": .string("metacognition.shadow.v2"),
                    "computeLane": .string("frontier_standard"),
                    "toolLane": .string("none"),
                    "contextLane": .string("minimal"),
                ]),
            ])
        )
        let misleadingLegacyOutcome = TurnTraceEvent(turnId: "legacy-turn", kind: "llm.call")

        let evaluation = MetacognitiveShadowEvaluation.evaluate(
            events: [legacy, misleadingLegacyOutcome]
        )
        #expect(evaluation.turns.isEmpty)
        #expect(evaluation.legacyExcludedRecommendationCount == 1)
        #expect(evaluation.evidenceStatus == .noRecommendations)
        #expect(evaluation.toolLaneAgreementRate == 0)
    }

    @Test("structured turns preserve an ambient trace identity and mint only for direct callers")
    func structuredTurnTraceIdentityPreservesOuterStory() {
        let inherited = TurnTraceContext.$turnId.withValue("outer-turn") {
            StructuredTurnTraceIdentity.currentOrMint()
        }
        #expect(inherited == "outer-turn")

        let minted = StructuredTurnTraceIdentity.currentOrMint()
        #expect(!minted.isEmpty)
        #expect(minted != "outer-turn")
    }

    @Test("context hint appends to dynamic segment and preserves stable prefix")
    func contextHintPreservesPromptSegments() throws {
        let policy = TurnPolicySnapshot(
            permissionLevel: "balanced",
            autonomyDefault: "supervised",
            fullMacActive: false,
            developerMode: false,
            remoteSurface: false,
            surfaceTrusted: true,
            fileAccess: "auto",
            approvalAvailable: true,
            remoteIOSAllowed: false
        )
        let plan = TurnPlan(
            id: "plan-context",
            messageCharCount: 12,
            goalType: "build_task",
            contextMode: "capability",
            recommendedSurface: "chat",
            risk: "low",
            requiresApprovalHint: false,
            matchedCapabilityIds: ["feature:build"],
            preloadPrediction: ToolPreloadHeuristics.Prediction(
                groups: [.init(group: "builder", matchedPatterns: ["swift build"])],
                candidateTools: ["swift_build"]
            ),
            policySnapshot: policy,
            receiptHints: [],
            createdAt: "2026-06-20T12:00:00.000+00:00"
        )
        let context = TurnContext(
            surface: "chat",
            personaDocs: [:],
            recalled: [],
            modelId: "test-model",
            reasoningEffort: "low",
            toolsAvailable: [],
            systemPrompt: "stable\n\ndynamic",
            userMessage: "swift build",
            systemSegments: SystemPromptSegments(stable: "stable", dynamic: "dynamic")
        )

        let planned = SwiftNativeTurnEngine.contextByAppendingTurnPlanHint(
            context,
            turnPlan: plan
        )

        #expect(planned.systemSegments?.stable == "stable")
        #expect(planned.systemSegments?.dynamic.contains("Turn route: goal=build_task") == true)
        #expect(planned.systemPrompt == planned.systemSegments?.combined)
        #expect(planned.systemPrompt?.hasPrefix("stable\n\n") == true)
    }

    @Test("telegram surface trust uses verified chat id and allowlist")
    func telegramSurfaceTrustUsesAllowlist() async throws {
        let root = try makeTurnPlanTempRoot("telegram")
        let telegramDir = root.appendingPathComponent("telegram", isDirectory: true)
        try FileManager.default.createDirectory(at: telegramDir, withIntermediateDirectories: true)
        let config: JSONValue = .object([
            "allowed_chat_ids": .array([.string("12345")]),
        ])
        try config.serializedData(pretty: true).write(
            to: telegramDir.appendingPathComponent("config.json")
        )

        let trusted = try await ChatToolSessionContext.$verifiedChatId.withValue("12345") {
            try await makePlanner(root: root).plan(
                message: "telegram bot config",
                surface: "telegram",
                sessionId: "telegram:other",
                fileAccess: "auto",
                approvalAvailable: true
            )
        }
        #expect(trusted.policySnapshot.remoteSurface == true)
        #expect(trusted.policySnapshot.surfaceTrusted == true)
        #expect(trusted.policySnapshot.policyDecision?.remoteSurface == true)
        #expect(trusted.policySnapshot.policyDecision?.surfaceTrusted == true)

        let untrusted = try await ChatToolSessionContext.$verifiedChatId.withValue("999") {
            try await makePlanner(root: root).plan(
                message: "telegram bot config",
                surface: "telegram",
                sessionId: "telegram:999",
                fileAccess: "auto",
                approvalAvailable: true
            )
        }
        #expect(untrusted.policySnapshot.remoteSurface == true)
        #expect(untrusted.policySnapshot.surfaceTrusted == false)
        #expect(untrusted.policySnapshot.policyDecision?.remoteSurface == true)
        #expect(untrusted.policySnapshot.policyDecision?.surfaceTrusted == false)
    }
}
