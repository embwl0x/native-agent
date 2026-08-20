import Foundation
import Testing
@testable import NativeAgentCore

@Suite("Surface-neutral turn presentation kernel")
struct TurnPresentationTests {
    @Test func initialStateIsAcknowledgedAndTimerFree() {
        let instant = time(40)
        let state = TurnPresentationReducer.initialState(at: instant)

        #expect(state.phase == .acknowledged)
        #expect(state.startedAt == instant)
        #expect(state.lastMovementAt == instant)
        #expect(state.endedAt == nil)
        #expect(state.currentAction == nil)
        #expect(state.delegateName == nil)
        #expect(state.activities.isEmpty)
        #expect(!state.isTerminal)
    }

    @Test func lifecycleTransitionsCoverEveryPhaseAndRecordSafeActivity() {
        let cases: [(TurnPresentationLifecycleEvent, TurnPresentationPhase)] = [
            (.working(action: "Planning"), .working),
            (.tool(name: "read_file", action: "Reading"), .tool),
            (.delegation(delegate: "Worker", action: "Reviewing"), .delegation),
            (.retrying(action: "Trying again"), .retrying),
            (.waiting(action: "Waiting for approval"), .waiting),
            (.blocked(reason: "Approval required"), .blocked),
            (.stalled(reason: "No movement"), .stalled),
            (.completed(summary: "Delivered"), .completed),
            (.failed(reason: "Provider failed"), .failed),
            (.canceled(reason: "Stopped"), .canceled),
            (.outcomeUnknown(reason: "Delivery uncertain"), .outcomeUnknown),
        ]

        for (event, phase) in cases {
            let state = TurnPresentationReducer.reduce(
                TurnPresentationReducer.initialState(at: time(0)),
                lifecycle: event,
                at: time(1)
            )
            #expect(state.phase == phase)
            #expect(state.activities.count == 1)
            #expect(state.activities[0].phase == phase)
            #expect((state.endedAt != nil) == phase.isTerminal)
        }
    }

    @Test func movementIsMonotonicAndDuplicateActivityIsCoalesced() {
        let initial = TurnPresentationReducer.initialState(at: time(10))
        let working = TurnPresentationReducer.reduce(
            initial,
            lifecycle: .working(action: "Planning"),
            at: time(20)
        )
        let duplicate = TurnPresentationReducer.reduce(
            working,
            lifecycle: .working(action: "Planning"),
            at: time(30)
        )
        let tool = TurnPresentationReducer.recordActivity(
            duplicate,
            phase: .tool,
            detail: "Reading a file",
            delegateName: nil,
            at: time(15)
        )

        #expect(duplicate == working)
        #expect(tool.lastMovementAt == time(20))
        #expect(tool.activities.count == 2)
        #expect(tool.activities.last?.occurredAt == time(20))
        #expect(tool.activities.last?.detail == "Reading a file")
    }

    @Test func detailHistoryRetainsOnlyTheNewestBoundedEntries() {
        var state = TurnPresentationReducer.initialState(at: time(0))
        let total = TurnPresentationReducer.detailHistoryLimit + 5
        for index in 0..<total {
            state = TurnPresentationReducer.reduce(
                state,
                lifecycle: .working(action: "Step \(index)"),
                at: time(TimeInterval(index + 1))
            )
        }

        #expect(state.activities.count == TurnPresentationReducer.detailHistoryLimit)
        #expect(state.activities.first?.detail == "Step 5")
        #expect(state.activities.last?.detail == "Step \(total - 1)")
    }

    @Test func allTerminalStatesAreImmutableAgainstLateEvidence() {
        let terminals: [TurnPresentationLifecycleEvent] = [
            .completed(summary: "Delivered"),
            .failed(reason: "Failed"),
            .canceled(reason: "Stopped"),
            .outcomeUnknown(reason: "Uncertain"),
        ]

        for terminal in terminals {
            let settled = TurnPresentationReducer.reduce(
                TurnPresentationReducer.initialState(at: time(0)),
                lifecycle: terminal,
                at: time(5)
            )
            let lifecycleLate = TurnPresentationReducer.reduce(
                settled,
                lifecycle: .working(action: "Late"),
                at: time(10)
            )
            let activityLate = TurnPresentationReducer.recordActivity(
                lifecycleLate,
                phase: .tool,
                detail: "Late tool",
                delegateName: nil,
                at: time(11)
            )
            let streamLate = TurnPresentationReducer.recordStreamProgress(
                activityLate,
                accumulatedUTF16Length: 500,
                at: time(12)
            )

            #expect(lifecycleLate == settled)
            #expect(activityLate == settled)
            #expect(streamLate == settled)
            #expect(streamLate.endedAt == time(5))
        }
    }

    @Test func streamMovementStoresOnlyLengthAndCoalescesDuplicates() {
        let initial = TurnPresentationReducer.initialState(at: time(0))
        let first = TurnPresentationReducer.recordStreamProgress(
            initial,
            accumulatedUTF16Length: 17,
            at: time(2)
        )
        let duplicate = TurnPresentationReducer.recordStreamProgress(
            first,
            accumulatedUTF16Length: 17,
            at: time(8)
        )

        #expect(first.phase == .working)
        #expect(first.lastMovementAt == time(2))
        #expect(first.currentAction == nil)
        #expect(first.activities.last?.detail == nil)
        #expect(duplicate == first)
    }

    @Test func stallClassificationIsDerivedWithoutMutatingLifecycleTruth() {
        let working = TurnPresentationReducer.reduce(
            TurnPresentationReducer.initialState(at: time(0)),
            lifecycle: .working(action: "Thinking"),
            at: time(1)
        )
        let waiting = TurnPresentationReducer.reduce(
            TurnPresentationReducer.initialState(at: time(0)),
            lifecycle: .waiting(action: "Waiting"),
            at: time(1)
        )

        #expect(TurnPresentationReducer.effectivePhase(
            working,
            secondsSinceMovement: 89,
            stalledAfter: 90
        ) == .working)
        #expect(TurnPresentationReducer.effectivePhase(
            working,
            secondsSinceMovement: 90,
            stalledAfter: 90
        ) == .stalled)
        #expect(TurnPresentationReducer.effectivePhase(
            waiting,
            secondsSinceMovement: 1_000,
            stalledAfter: 90
        ) == .waiting)
        #expect(working.phase == .working)
    }

    @Test func sanitizationRedactsNormalizesAndTruncatesBeforeStateEntry() {
        let providerSecret = ["sk", "proj", String(repeating: "A", count: 36)]
            .joined(separator: "-")
        let keyName = ["API", "KEY"].joined(separator: "_")
        let namedSecret = [keyName, String(repeating: "b", count: 24)]
            .joined(separator: "=")
        let longTail = String(repeating: "x", count: 300)
        let state = TurnPresentationReducer.reduce(
            TurnPresentationReducer.initialState(at: time(0)),
            lifecycle: .delegation(
                delegate: "Worker\n\(namedSecret)",
                action: "Using \(providerSecret) \(longTail)"
            ),
            at: time(1)
        )

        let action = state.currentAction ?? ""
        let delegate = state.delegateName ?? ""
        #expect(!action.contains(providerSecret))
        #expect(!delegate.contains(namedSecret))
        #expect(action.contains("[REDACTED_OPENAI_KEY]"))
        #expect(delegate.contains("[REDACTED_NAMED_SECRET]"))
        #expect(!action.contains("\n"))
        #expect(!delegate.contains("\n"))
        #expect(action.count <= TurnPresentationReducer.textLimit)
        #expect(delegate.count <= TurnPresentationReducer.textLimit)
        #expect(state.activities.last?.detail == state.currentAction)
    }

    @Test func codableCompatibilityPreservesPersistedPhaseRawValues() throws {
        let decodedPhase = try JSONDecoder().decode(
            TurnPresentationPhase.self,
            from: Data(#""outcome_unknown""#.utf8)
        )
        let encodedPhase = try JSONEncoder().encode(TurnPresentationPhase.delegation)

        #expect(decodedPhase == .outcomeUnknown)
        #expect(TurnPresentationPhase.outcomeUnknown.rawValue == "outcome_unknown")
        #expect(String(decoding: encodedPhase, as: UTF8.self) == #""delegation""#)
    }

    @Test func dependencyDirectionKeepsTheKernelSurfaceNeutral() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let coreURL = packageRoot
            .appendingPathComponent("Sources/NativeAgentCore/TurnPresentation.swift")
        let adapterURL = packageRoot
            .appendingPathComponent("Sources/TelegramBot/TelegramTurnPresentation.swift")
        let coreSource = try String(contentsOf: coreURL, encoding: .utf8)
        let adapterSource = try String(contentsOf: adapterURL, encoding: .utf8)
        let imports = coreSource
            .split(separator: "\n")
            .filter { $0.hasPrefix("import ") }
            .map(String.init)

        #expect(imports == ["import Foundation"])
        #expect(!coreSource.contains("Telegram"))
        #expect(!coreSource.contains("ChatProgressEvent"))
        #expect(!coreSource.contains("chatId"))
        #expect(!coreSource.contains("messageId"))
        #expect(!coreSource.contains("replyMarkup"))
        #expect(adapterSource.contains("import NativeAgentCore"))
        #expect(adapterSource.contains("typealias TelegramTurnPresentationState = TurnPresentationState"))
        #expect(adapterSource.contains("TurnPresentationReducer.reduce("))
    }

    private func time(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }
}
