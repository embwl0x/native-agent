import Foundation
import Testing
import ChatOrchestration
import NativeAgentCore
@testable import NativeAgentApp

@Suite("Mac live turn activity transport")
struct MacChatTurnActivityTests {
    @Test func toolUseAndResultBecomeTypedSafeActivityWithoutPayloadRetention() throws {
        let identity = route(session: "session-a", turn: "turn-a")
        let rawSecret = ["sk", "proj", String(repeating: "A", count: 36)]
            .joined(separator: "-")
        let use = try #require(MacChatTurnActivityBoundary.activity(
            from: .toolUse(
                name: "read_file",
                input: .object(["path": .string(rawSecret)])
            ),
            identity: identity,
            at: time(1)
        ))
        let result = try #require(MacChatTurnActivityBoundary.activity(
            from: .toolResult(
                name: "read_file",
                output: .object(["contents": .string(rawSecret)])
            ),
            identity: identity,
            at: time(2)
        ))

        #expect(use.source == .toolUse)
        #expect(use.phase == .tool)
        #expect(use.toolDisplayName == "read_file")
        #expect(use.actionSummary == "Using tool: read_file")
        #expect(result.source == .toolResult)
        #expect(result.phase == .working)
        #expect(result.actionSummary == "Finished tool: read_file")
        #expect(!String(reflecting: use).contains(rawSecret))
        #expect(!String(reflecting: result).contains(rawSecret))
    }

    @Test func noticesAndToolsConvergeOnOneReducerWithOrderedTimestamps() throws {
        let identity = route(session: "session-a", turn: "turn-a")
        var state = MacChatTurnLifecycleState(identity: identity, startedAt: time(0))
        let tool = try #require(MacChatTurnActivityBoundary.activity(
            from: .toolUse(name: "bash", input: .object(["command": .string("ignored")])),
            identity: identity,
            at: time(3)
        ))
        let notice = try #require(MacChatTurnActivityBoundary.activity(
            from: .notice(kind: "tool_loop_recovery", text: "Trying a narrower call"),
            identity: identity,
            at: time(7)
        ))

        state = reduce(state, activity: tool)
        state = reduce(state, activity: notice)

        #expect(state.presentation.phase == .retrying)
        #expect(state.presentation.lastMovementAt == time(7))
        #expect(state.presentation.activities.map(\.occurredAt) == [time(3), time(7)])
        #expect(state.presentation.activities.map(\.detail) == [
            "Using tool: bash",
            "Trying a narrower call",
        ])
    }

    @MainActor
    @Test func appModelRoutesConcurrentAndBackgroundSessionsWithoutSelectedSessionBleed() throws {
        let model = AppModel()
        model.activeChatSessionId = "selected"
        let selected = try #require(model.beginChatTurnLifecycle(
            sessionId: "selected",
            turnId: "turn-selected",
            at: time(0)
        ))
        let detached = try #require(model.beginChatTurnLifecycle(
            sessionId: "detached",
            turnId: "turn-detached",
            at: time(0)
        ))

        model.receiveChatTurnActivity(try activity(
            .toolUse(name: "read_file", input: .object([:])),
            identity: detached,
            at: 1
        ))
        model.receiveChatTurnActivity(try activity(
            .toolUse(name: "git_status", input: .object([:])),
            identity: selected,
            at: 2
        ))

        #expect(model.activeChatSessionId == "selected")
        #expect(model.chatTurnLifecycle(for: "selected")?.presentation.currentAction == "Using tool: git_status")
        #expect(model.chatTurnLifecycle(for: "detached")?.presentation.currentAction == "Using tool: read_file")
        #expect(model.chatTurnLifecycle(for: "selected")?.identity.turnId == "turn-selected")
        #expect(model.chatTurnLifecycle(for: "detached")?.identity.turnId == "turn-detached")
    }

    @MainActor
    @Test func staleAndLateEventsCannotOverwriteTheCurrentTurn() throws {
        let model = AppModel()
        let current = try #require(model.beginChatTurnLifecycle(
            sessionId: "session-a",
            turnId: "current",
            at: time(0)
        ))
        let stale = route(session: "session-a", turn: "stale")

        model.receiveChatTurnActivity(try activity(
            .toolUse(name: "stale_tool", input: .object([:])),
            identity: stale,
            at: 1
        ))
        #expect(model.chatTurnLifecycle(for: "session-a")?.presentation.activities.isEmpty == true)

        model.receiveChatTurnActivity(try activity(
            .toolUse(name: "current_tool", input: .object([:])),
            identity: current,
            at: 2
        ))
        let closed = try #require(model.closeChatTurnLifecycleIntake(
            sessionId: "session-a",
            turnId: "current",
            at: time(3)
        ))
        model.receiveChatTurnActivity(try activity(
            .toolResult(name: "current_tool", output: .string("late raw result")),
            identity: current,
            at: 4
        ))

        #expect(closed.presentation.phase == .outcomeUnknown)
        #expect(closed.terminalEvidence == .interruptedOutcomeUnknown)
        #expect(model.chatTurnLifecycle(for: "session-a") == closed)
        #expect(model.activeChatTurnLifecycleIDsBySession["session-a"] == nil)
    }

    @MainActor
    @Test func sessionSwitchDoesNotRedirectAnInflightTurnsActivity() throws {
        let model = AppModel()
        model.activeChatSessionId = "session-a"
        let identity = try #require(model.beginChatTurnLifecycle(
            sessionId: "session-a",
            turnId: "turn-a",
            at: time(0)
        ))

        model.activeChatSessionId = "session-b"
        model.receiveChatTurnActivity(try activity(
            .toolUse(name: "read_file", input: .object([:])),
            identity: identity,
            at: 1
        ))

        #expect(model.chatTurnLifecycle(for: "session-a")?.presentation.currentAction == "Using tool: read_file")
        #expect(model.chatTurnLifecycle(for: "session-b") == nil)
        #expect(model.activeChatSessionId == "session-b")
    }

    @MainActor
    @Test func cancellationRequestIsNonterminalAndTerminalStateRejectsLateActivity() throws {
        let model = AppModel()
        let identity = try #require(model.beginChatTurnLifecycle(
            sessionId: "session-a",
            turnId: "turn-a",
            at: time(0)
        ))

        let requested = try #require(model.requestChatTurnCancellation(
            sessionId: "session-a",
            turnId: "turn-a",
            at: time(1)
        ))
        #expect(requested.cancellationRequestedAt == time(1))
        #expect(requested.presentation.isTerminal == false)
        #expect(requested.terminalEvidence == nil)

        let completed = try #require(model.applyChatTurnLifecycleInput(
            MacChatTurnLifecycleInput(
                identity: identity,
                kind: .completed,
                occurredAt: time(2)
            )
        ))
        model.receiveChatTurnActivity(try activity(
            .toolUse(name: "late_tool", input: .object([:])),
            identity: identity,
            at: 3
        ))

        #expect(completed.presentation.phase == .completed)
        #expect(completed.terminalEvidence == .finalResponsePersisted)
        #expect(model.chatTurnLifecycle(for: "session-a") == completed)
    }

    @MainActor
    @Test func sessionRebindingMovesOnlyTheExactTurnGeneration() throws {
        let model = AppModel()
        let identity = try #require(model.beginChatTurnLifecycle(
            sessionId: "placeholder",
            turnId: "turn-a",
            at: time(0)
        ))
        model.receiveChatTurnActivity(try activity(
            .toolUse(name: "read_file", input: .object([:])),
            identity: identity,
            at: 1
        ))

        model.migrateChatTurnLifecycleIntake(
            from: "placeholder",
            to: "canonical",
            turnId: "turn-a"
        )

        #expect(model.chatTurnLifecycle(for: "placeholder") == nil)
        #expect(model.activeChatTurnLifecycleIDsBySession["placeholder"] == nil)
        #expect(model.activeChatTurnLifecycleIDsBySession["canonical"] == "turn-a")
        #expect(model.chatTurnLifecycle(for: "canonical")?.identity == route(
            session: "canonical",
            turn: "turn-a"
        ))
        #expect(model.chatTurnLifecycle(for: "canonical")?.presentation.currentAction == "Using tool: read_file")
    }

    @MainActor
    @Test func migrationNeverOverwritesAConcurrentCanonicalTurn() throws {
        let model = AppModel()
        let placeholder = try #require(model.beginChatTurnLifecycle(
            sessionId: "placeholder",
            turnId: "placeholder-turn",
            at: time(0)
        ))
        let canonical = try #require(model.beginChatTurnLifecycle(
            sessionId: "canonical",
            turnId: "canonical-turn",
            at: time(0)
        ))
        model.receiveChatTurnActivity(try activity(
            .toolUse(name: "placeholder_tool", input: .object([:])),
            identity: placeholder,
            at: 1
        ))
        model.receiveChatTurnActivity(try activity(
            .toolUse(name: "canonical_tool", input: .object([:])),
            identity: canonical,
            at: 2
        ))

        model.migrateChatTurnLifecycleIntake(
            from: "placeholder",
            to: "canonical",
            turnId: "placeholder-turn"
        )

        #expect(model.chatTurnLifecycle(for: "placeholder") == nil)
        #expect(model.chatTurnLifecycle(for: "canonical")?.identity.turnId == "canonical-turn")
        #expect(model.chatTurnLifecycle(for: "canonical")?.presentation.currentAction == "Using tool: canonical_tool")
    }

    @Test func boundaryRedactsAndBoundsEveryStoredDisplayString() throws {
        let identity = route(session: "session-a", turn: "turn-a")
        let providerSecret = ["sk", "proj", String(repeating: "A", count: 36)]
            .joined(separator: "-")
        let localPath = ["", "Users", "private-user", "workspace"].joined(separator: "/")
        let telegramSecret = String(repeating: "1", count: 9)
            + ":" + String(repeating: "z", count: 40)
        let raw = "Retry \(providerSecret) at \(localPath) with \(telegramSecret) "
            + String(repeating: "tail ", count: 80)
        let event = try #require(MacChatTurnActivityBoundary.activity(
            from: .notice(kind: "tool_loop_recovery", text: raw),
            identity: identity,
            at: time(1)
        ))
        let toolEvent = try #require(MacChatTurnActivityBoundary.activity(
            from: .toolUse(
                name: "tool-\(providerSecret)",
                input: .object(["raw": .string(telegramSecret)])
            ),
            identity: identity,
            at: time(2)
        ))
        let stored = reduce(
            MacChatTurnLifecycleState(identity: identity, startedAt: time(0)),
            activity: event
        )
        let detail = stored.presentation.currentAction ?? ""
        let noticeText = event.userVisibleNoticeText ?? ""

        #expect(!detail.contains(providerSecret))
        #expect(!detail.contains(localPath))
        #expect(!detail.contains(telegramSecret))
        #expect(!noticeText.contains(providerSecret))
        #expect(!noticeText.contains(localPath))
        #expect(!noticeText.contains(telegramSecret))
        #expect(detail.contains("[REDACTED_OPENAI_KEY]"))
        #expect(detail.contains("[REDACTED_LOCAL_HOME:"))
        #expect(detail.count <= TurnPresentationReducer.textLimit)
        #expect(noticeText.count <= 512)
        #expect(!(toolEvent.toolDisplayName ?? "").contains(providerSecret))
        #expect((toolEvent.toolDisplayName ?? "").contains("[REDACTED_OPENAI_KEY]"))
    }

    @Test func detailHistoryIsBoundedAndDuplicateProgressCoalesces() throws {
        let identity = route(session: "session-a", turn: "turn-a")
        var state = MacChatTurnLifecycleState(identity: identity, startedAt: time(0))
        let total = TurnPresentationReducer.detailHistoryLimit + 4
        for index in 0..<total {
            state = reduce(
                state,
                activity: try activity(
                    .notice(kind: "progress", text: "Step \(index)"),
                    identity: identity,
                    at: TimeInterval(index + 1)
                )
            )
        }
        let duplicate = try activity(
            .notice(kind: "progress", text: "Step \(total - 1)"),
            identity: identity,
            at: 100
        )
        let coalesced = reduce(state, activity: duplicate)

        #expect(state.presentation.activities.count == TurnPresentationReducer.detailHistoryLimit)
        #expect(state.presentation.activities.first?.detail == "Step 4")
        #expect(coalesced == state)
    }

    @MainActor
    @Test func knownNoticeCopyStillUsesTheExistingNotificationPresentationPath() throws {
        let model = AppModel()
        let identity = try #require(model.beginChatTurnLifecycle(
            sessionId: "session-a",
            turnId: "turn-a",
            at: time(0)
        ))
        let box = NoticeCapture()
        let token = NotificationCenter.default.addObserver(
            forName: .nativeAgentTurnNotice,
            object: nil,
            queue: nil
        ) { note in
            box.kind = note.userInfo?["kind"] as? String
            box.text = note.userInfo?["text"] as? String
            box.sessionId = note.userInfo?["sessionId"] as? String
        }
        defer { NotificationCenter.default.removeObserver(token) }

        model.receiveChatTurnActivity(try activity(
            .notice(
                kind: "slow_turn",
                text: "Still working on it - a complex reply can take a moment."
            ),
            identity: identity,
            at: 1
        ))

        #expect(box.kind == "slow_turn")
        #expect(box.text == "Still working on it - a complex reply can take a moment.")
        #expect(box.sessionId == "session-a")
        #expect(ChatTurnNoticePresentation.destination(for: box.kind ?? "") == .chatTop)
    }

    @MainActor
    @Test func existingLongRecoveryNoticeCopyIsNotCollapsedToCardDetailLength() throws {
        let model = AppModel()
        let identity = try #require(model.beginChatTurnLifecycle(
            sessionId: "session-a",
            turnId: "turn-a",
            at: time(0)
        ))
        let existingCopy = "No progress detected: this exact tool batch has returned the same result eight rounds in a row. Change the arguments, use a narrower query or a different tool, or answer from the results already available."
        let box = NoticeCapture()
        let token = NotificationCenter.default.addObserver(
            forName: .nativeAgentTurnNotice,
            object: nil,
            queue: nil
        ) { note in
            box.text = note.userInfo?["text"] as? String
        }
        defer { NotificationCenter.default.removeObserver(token) }

        model.receiveChatTurnActivity(try activity(
            .notice(kind: "tool_loop_recovery", text: existingCopy),
            identity: identity,
            at: 1
        ))

        #expect(box.text == existingCopy)
        #expect(model.chatTurnLifecycle(for: "session-a")?.presentation.currentAction?.count == TurnPresentationReducer.textLimit)
    }

    @MainActor
    @Test func pruningPreservesActiveAuthorityThenRemovesOnlyTheClosedSession() throws {
        let model = AppModel()
        model.chatTurnLifecycleStore = MacChatTurnLifecycleStore(
            storage: ActivityLifecycleMemoryStorage()
        )
        _ = model.beginChatTurnLifecycle(sessionId: "a", turnId: "ta", at: time(0))
        _ = model.beginChatTurnLifecycle(sessionId: "b", turnId: "tb", at: time(0))

        model.pruneSessionChatState("a")

        #expect(model.chatTurnLifecycle(for: "a") != nil)
        #expect(model.activeChatTurnLifecycleIDsBySession["a"] == "ta")
        _ = model.closeChatTurnLifecycleIntake(sessionId: "a", turnId: "ta", at: time(1))
        model.pruneSessionChatState("a")

        #expect(model.chatTurnLifecycle(for: "a") == nil)
        #expect(model.activeChatTurnLifecycleIDsBySession["a"] == nil)
        #expect(model.chatTurnLifecycle(for: "b") != nil)
        #expect(model.activeChatTurnLifecycleIDsBySession["b"] == "tb")
    }

    @Test func architectureKeepsTheSeamSurfaceNeutralAndAddsNoCardOrParallelBus() throws {
        let activitySource = try AppSourceScraping.appSource("MacChatTurnActivity.swift")
        let runtimeSource = try AppSourceScraping.appSource("NativeClient+ChatRuntime.swift")
        let stateSource = try AppSourceScraping.appSource("AppModel+ChatState.swift")
        let chatSource = try AppSourceScraping.appSource("ChatView.swift")
        let iosSource = try AppSourceScraping.appSource("AppDelegate+ICloudRuntimeForwarding.swift")

        #expect(activitySource.contains("import NativeAgentCore"))
        #expect(activitySource.contains("TurnPresentationReducer"))
        #expect(!activitySource.contains("import TelegramBot"))
        #expect(!activitySource.contains("import SwiftUI"))
        #expect(!activitySource.contains("JSONValue"))
        #expect(!activitySource.contains("replyMarkup"))
        #expect(runtimeSource.contains("MacChatTurnActivityBoundary.activity("))
        #expect(!runtimeSource.contains("this wrapper swallows tool events"))
        #expect(!runtimeSource.contains("NotificationCenter.default.post("))
        #expect(stateSource.contains("name: .nativeAgentTurnNotice"))
        #expect(!stateSource.contains("nativeAgentTurnActivity"))
        #expect(!chatSource.contains("MacChatTurnActivity"))
        #expect(iosSource.contains("case .toolUse(let name, _)"))
        #expect(iosSource.contains("case .toolResult(let name, _)"))
    }

    private func activity(
        _ event: TurnStreamEvent,
        identity: MacChatTurnIdentity,
        at seconds: TimeInterval
    ) throws -> MacChatTurnActivity {
        try #require(MacChatTurnActivityBoundary.activity(
            from: event,
            identity: identity,
            at: time(seconds)
        ))
    }

    private func reduce(
        _ state: MacChatTurnLifecycleState,
        activity: MacChatTurnActivity
    ) -> MacChatTurnLifecycleState {
        MacChatTurnLifecycleReducer.reduce(
            state,
            input: MacChatTurnLifecycleInput(
                identity: activity.identity,
                kind: .activity(activity),
                occurredAt: activity.occurredAt
            )
        )
    }

    private func route(session: String, turn: String) -> MacChatTurnIdentity {
        MacChatTurnIdentity(sessionId: session, turnId: turn)
    }

    private func time(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }
}

private actor ActivityLifecycleMemoryStorage: MacChatTurnLifecycleStorage {
    private var records: [MacChatPersistedTurnLifecycle] = []

    func load() async throws -> [MacChatPersistedTurnLifecycle] { records }
    func save(_ records: [MacChatPersistedTurnLifecycle]) async throws {
        self.records = records
    }
}

private final class NoticeCapture: @unchecked Sendable {
    var kind: String?
    var text: String?
    var sessionId: String?
}
