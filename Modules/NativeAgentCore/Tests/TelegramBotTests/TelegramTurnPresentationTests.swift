import Foundation
import PersistenceCore
import Testing
@testable import TelegramBot

@Suite("Telegram turn presentation reducer")
struct TelegramTurnPresentationTests {
    @Test func explicitLifecycleCoversEveryPhase() {
        let cases: [(TelegramTurnPresentationLifecycleEvent, TelegramTurnPresentationPhase)] = [
            (.acknowledged, .acknowledged),
            (.working(action: "Planning"), .working),
            (.tool(name: "read_file", action: "Reading a file"), .tool),
            (.delegation(delegate: "Codex", action: "Reviewing"), .delegation),
            (.retrying(action: "Trying again"), .retrying),
            (.waiting(action: "Waiting for approval"), .waiting),
            (.blocked(reason: "Approval required"), .blocked),
            (.stalled(reason: "No movement"), .stalled),
            (.completed(summary: "Done"), .completed),
            (.failed(reason: "Provider failed"), .failed),
            (.canceled(reason: "Stopped by user"), .canceled),
            (.outcomeUnknown(reason: "Delivery could not be confirmed"), .outcomeUnknown),
        ]

        for (event, expectedPhase) in cases {
            let initial = TelegramTurnPresentationReducer.initialState(at: time(0))
            let reduced = TelegramTurnPresentationReducer.reduce(
                initial,
                lifecycle: event,
                at: time(1)
            )
            #expect(reduced.phase == expectedPhase)
            #expect((reduced.endedAt != nil) == expectedPhase.isTerminal)
        }
    }

    @Test func existingProgressEventsMapWithoutRenderingModelOutput() {
        var state = TelegramTurnPresentationReducer.initialState(at: time(0))

        state = TelegramTurnPresentationReducer.reduce(
            state,
            progress: .status(text: "Planning the response"),
            at: time(1)
        )
        #expect(state.phase == .working)
        #expect(state.currentAction == "Planning the response")

        state = TelegramTurnPresentationReducer.reduce(
            state,
            progress: .toolUse(
                name: "read_skill",
                input: .object(["name": .string("builder")])
            ),
            at: time(2)
        )
        #expect(state.phase == .tool)
        #expect(state.currentAction == "Loading skill: builder")

        state = TelegramTurnPresentationReducer.reduce(
            state,
            progress: .toolResult(name: "read_skill", output: .string("secret output")),
            at: time(3)
        )
        #expect(state.phase == .working)
        #expect(state.currentAction == "Finished tool: read_skill")
        #expect(!(state.currentAction ?? "").contains("secret output"))

        state = TelegramTurnPresentationReducer.reduce(
            state,
            progress: .notice(kind: "invoke_started", text: "Invoking Claude"),
            at: time(4)
        )
        #expect(state.phase == .delegation)
        #expect(state.delegateName == "Claude")

        state = TelegramTurnPresentationReducer.reduce(
            state,
            progress: .status(text: "Draft stalled; retrying"),
            at: time(5)
        )
        #expect(state.phase == .retrying)

        state = TelegramTurnPresentationReducer.reduce(
            state,
            progress: .notice(kind: "waiting_external", text: "Waiting for result"),
            at: time(6)
        )
        #expect(state.phase == .waiting)

        state = TelegramTurnPresentationReducer.reduce(
            state,
            progress: .notice(kind: "approval_required", text: "Approval required"),
            at: time(7)
        )
        #expect(state.phase == .blocked)

        state = TelegramTurnPresentationReducer.reduce(
            state,
            progress: .notice(kind: "invoke_timeout", text: "Claude timed out"),
            at: time(8)
        )
        #expect(state.phase == .stalled)
        #expect(state.delegateName == "Claude")

        state = TelegramTurnPresentationReducer.reduce(
            state,
            progress: .textDelta(accumulated: "model answer text"),
            at: time(9)
        )
        #expect(state.phase == .working)
        #expect(state.currentAction == nil)
        #expect(!TelegramTurnPresentationRenderer.render(state, at: time(9))
            .contains("model answer text"))
    }

    @Test func duplicateAndCoalescedProgressDoesNotInventMovement() {
        let initial = TelegramTurnPresentationReducer.initialState(at: time(0))
        let working = TelegramTurnPresentationReducer.reduce(
            initial,
            progress: .status(text: "Planning"),
            at: time(1)
        )
        let duplicateStatus = TelegramTurnPresentationReducer.reduce(
            working,
            progress: .status(text: "Planning"),
            at: time(30)
        )
        #expect(duplicateStatus == working)

        let firstDelta = TelegramTurnPresentationReducer.reduce(
            duplicateStatus,
            progress: .textDelta(accumulated: "abc"),
            at: time(31)
        )
        let duplicateDelta = TelegramTurnPresentationReducer.reduce(
            firstDelta,
            progress: .textDelta(accumulated: "abc"),
            at: time(50)
        )
        #expect(duplicateDelta == firstDelta)

        let longerDelta = TelegramTurnPresentationReducer.reduce(
            duplicateDelta,
            progress: .textDelta(accumulated: "abcd"),
            at: time(51)
        )
        #expect(longerDelta.lastMovementAt == time(51))
        #expect(longerDelta.currentAction == nil)
    }

    @Test func everyTerminalStateIsImmutableAgainstLateLifecycleAndProgress() {
        let terminals: [TelegramTurnPresentationLifecycleEvent] = [
            .completed(summary: "Delivered"),
            .failed(reason: "Provider failed"),
            .canceled(reason: "Stopped"),
            .outcomeUnknown(reason: "Delivery uncertain"),
        ]

        for terminal in terminals {
            let initial = TelegramTurnPresentationReducer.initialState(at: time(0))
            let settled = TelegramTurnPresentationReducer.reduce(
                initial,
                lifecycle: terminal,
                at: time(10)
            )
            let afterProgress = TelegramTurnPresentationReducer.reduce(
                settled,
                progress: .toolUse(name: "dangerous_late_tool", input: nil),
                at: time(20)
            )
            let afterLifecycle = TelegramTurnPresentationReducer.reduce(
                afterProgress,
                lifecycle: .working(action: "late work"),
                at: time(30)
            )

            #expect(afterProgress == settled)
            #expect(afterLifecycle == settled)
            #expect(afterLifecycle.phase.isTerminal)
            #expect(afterLifecycle.endedAt == time(10))
        }
    }

    @Test func everyRenderedStringIsRedactedSingleLineAndBounded() {
        let openAISecret = ["sk", "proj", "ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890"]
            .joined(separator: "-")
        let telegramSecret = ["7123456789", "AAH-secret_Token123"]
            .joined(separator: ":")
        let namedSecret = ["abcdefghijk", "123456789"].joined()
        let longTail = String(repeating: "x", count: 300)
        let initial = TelegramTurnPresentationReducer.initialState(at: time(0))
        let state = TelegramTurnPresentationReducer.reduce(
            initial,
            lifecycle: .delegation(
                delegate: "Codex\nAPI_KEY=\(namedSecret)",
                action: "Using \(openAISecret) at /bot\(telegramSecret)/sendMessage \(longTail)"
            ),
            at: time(1)
        )

        let action = state.currentAction ?? ""
        let delegate = state.delegateName ?? ""
        let rendered = TelegramTurnPresentationRenderer.render(state, at: time(2))

        #expect(!action.contains(openAISecret))
        #expect(!action.contains(telegramSecret))
        #expect(!delegate.contains(namedSecret))
        #expect(action.contains("[REDACTED_OPENAI_KEY]"))
        #expect(action.contains("bot<redacted>"))
        #expect(delegate.contains("[REDACTED_NAMED_SECRET]"))
        #expect(action.count <= TelegramTurnPresentationReducer.textLimit)
        #expect(delegate.count <= TelegramTurnPresentationReducer.textLimit)
        #expect(!action.contains("\n"))
        #expect(!delegate.contains("\n"))
        #expect(!rendered.contains(openAISecret))
        #expect(!rendered.contains(telegramSecret))
    }

    @Test func stalledThresholdIsDerivedWithoutMutatingState() {
        let initial = TelegramTurnPresentationReducer.initialState(at: time(0))
        let working = TelegramTurnPresentationReducer.reduce(
            initial,
            lifecycle: .working(action: "Thinking"),
            at: time(1)
        )

        let before = TelegramTurnPresentationRenderer.render(
            working,
            at: time(90),
            stalledAfter: 90
        )
        let atThreshold = TelegramTurnPresentationRenderer.render(
            working,
            at: time(91),
            stalledAfter: 90
        )
        #expect(before.hasPrefix("Working ·"))
        #expect(atThreshold.hasPrefix("Stalled ·"))
        #expect(working.phase == .working)

        let waiting = TelegramTurnPresentationReducer.reduce(
            initial,
            lifecycle: .waiting(action: "Waiting for approval"),
            at: time(1)
        )
        #expect(TelegramTurnPresentationRenderer.render(
            waiting,
            at: time(1_000),
            stalledAfter: 90
        ).hasPrefix("Waiting ·"))
    }

    @Test func renderingIsDeterministicAndTerminalElapsedFreezes() {
        let initial = TelegramTurnPresentationReducer.initialState(at: time(0))
        let delegated = TelegramTurnPresentationReducer.reduce(
            initial,
            lifecycle: .delegation(delegate: "Codex", action: "Reviewing tests"),
            at: time(65)
        )
        let expected = """
        Delegated work · elapsed 2m 5s · moved 1m 0s ago
        Action: Reviewing tests
        Delegate: Codex
        """
        let first = TelegramTurnPresentationRenderer.render(
            delegated,
            at: time(125),
            stalledAfter: 1_000
        )
        let second = TelegramTurnPresentationRenderer.render(
            delegated,
            at: time(125),
            stalledAfter: 1_000
        )
        #expect(first == expected)
        #expect(second == first)

        let completed = TelegramTurnPresentationReducer.reduce(
            delegated,
            lifecycle: .completed(summary: "Done"),
            at: time(130)
        )
        let later = TelegramTurnPresentationRenderer.render(completed, at: time(190))
        #expect(later.hasPrefix("Completed · elapsed 2m 10s · moved 1m 0s ago"))
    }

    private func time(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }
}
