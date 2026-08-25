import Foundation
import PersistenceCore
import Testing

@testable import NativeAgentApp

@Suite("Mounted chat first-render telemetry", .serialized)
struct ChatFirstRenderTelemetryTests {
    @Test("a visible assistant bubble emits exactly one correlated durable render milestone")
    func visibleAssistantBubbleEmitsOnceAfterTheStreamStateHasSettled() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-first-render-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = TurnFirstRenderRegistry(maximumEntries: 4)
        let bus = TurnTraceBus(persistLane: TurnTracePersistLane(dataRootOverride: root))
        let turnID = "first-render-turn-\(UUID().uuidString)"
        let sessionID = "first-render-session"
        await registry.register(turnId: turnID, sessionId: sessionID, surface: "chat")
        TurnTraceBus.fire(TurnTraceEvent(
            turnId: turnID,
            kind: "turn.terminal",
            sessionId: sessionID,
            surface: "chat",
            payload: .object(["status": .string("completed")])
        ), on: bus)

        // This is the mounted MessageBubble's predicate. It deliberately has
        // no `isSessionStreaming` requirement: a fast turn may finish before
        // SwiftUI commits the bubble's onAppear/onChange callback.
        let eligibility = ChatFirstRenderTelemetry.eligibility(
            role: "assistant",
            content: "The visible reply",
            isLastAssistant: true,
            messageSessionID: sessionID,
            activeSessionID: "other-active-tab"
        )
        let outcome = await ChatFirstRenderTelemetry.emit(
            eligibility: eligibility,
            registry: registry,
            bus: bus
        )
        guard case .emitted(let emitted) = outcome else {
            Issue.record("Expected a first-render emission, got \(outcome)")
            return
        }
        #expect(emitted.turnId == turnID)
        #expect(emitted.kind == "surface.firstRender")
        #expect(emitted.sessionId == sessionID)
        #expect(emitted.surface == "chat")

        #expect(await ChatFirstRenderTelemetry.emit(
            eligibility: eligibility,
            registry: registry,
            bus: bus
        ) == .noPendingTurn)

        let reader = TurnTraceRecentReader(dataRootOverride: root)
        let deadline = Date().addingTimeInterval(3)
        var durableRows: [TurnTraceEvent] = []
        repeat {
            if let snapshot = try? await reader.read() {
                durableRows = snapshot.events.filter { $0.turnId == turnID }
            }
            if Set(durableRows.map(\.kind)) == ["turn.terminal", "surface.firstRender"] { break }
            try await Task.sleep(for: .milliseconds(10))
        } while Date() < deadline

        #expect(durableRows.filter { $0.kind == "surface.firstRender" }.count == 1)
        #expect(durableRows.contains { $0.kind == "turn.terminal" })
        #expect(durableRows.first(where: { $0.kind == "surface.firstRender" })?.sessionId == sessionID)
    }

    @Test("ineligible or unregistered bubbles do not consume another turn's first-render claim")
    func adverseEligibilityAndMissingRegistrationStayExplicit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-first-render-adverse-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = TurnFirstRenderRegistry(maximumEntries: 4)
        let bus = TurnTraceBus(persistLane: TurnTracePersistLane(dataRootOverride: root))
        let sessionID = "first-render-adverse-session"
        await registry.register(turnId: "first-render-adverse-turn", sessionId: sessionID, surface: "chat")

        let userEligibility = ChatFirstRenderTelemetry.eligibility(
            role: "user",
            content: "Not an assistant bubble",
            isLastAssistant: true,
            messageSessionID: sessionID,
            activeSessionID: sessionID
        )
        #expect(userEligibility == .notAssistant)
        #expect(await ChatFirstRenderTelemetry.emit(
            eligibility: userEligibility,
            registry: registry,
            bus: bus
        ) == .ineligible(.notAssistant))

        let malformedSessionEligibility = ChatFirstRenderTelemetry.eligibility(
            role: "assistant",
            content: "Visible but corrupt session identity",
            isLastAssistant: true,
            messageSessionID: "  ",
            activeSessionID: sessionID
        )
        #expect(malformedSessionEligibility == .missingSessionID)

        let validEligibility = ChatFirstRenderTelemetry.eligibility(
            role: "assistant",
            content: "The actual visible reply",
            isLastAssistant: true,
            messageSessionID: sessionID,
            activeSessionID: sessionID
        )
        let validOutcome = await ChatFirstRenderTelemetry.emit(
            eligibility: validEligibility,
            registry: registry,
            bus: bus
        )
        guard case .emitted = validOutcome else {
            Issue.record("A valid visible assistant bubble did not claim the pending turn: \(validOutcome)")
            return
        }
        #expect(await ChatFirstRenderTelemetry.emit(
            eligibility: validEligibility,
            registry: registry,
            bus: bus
        ) == .noPendingTurn)
    }
}
