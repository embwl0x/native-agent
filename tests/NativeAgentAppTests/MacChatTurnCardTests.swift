import Foundation
import Testing
import NativeAgentCore
@testable import NativeAgentApp

/// Desk 658.11 — one shared live-turn card. These tests pin the projection
/// (what the card says for each lifecycle state), the identity fence (which
/// surface may render it), and the structural guarantee that no second
/// progress surface survives alongside it.
@Suite("Mac Chat turn card", .serialized)
struct MacChatTurnCardTests {

    // MARK: - One card per accepted turn

    @Test func oneAcceptedTurnProjectsExactlyOneCardAndNoSprayOfActivity() throws {
        let identity = route(session: "session-a", turn: "turn-a")
        var state = MacChatTurnLifecycleState(identity: identity, startedAt: time(0))
        for step in 1...8 {
            state = reduce(state, .working(action: "Step \(step)"), at: TimeInterval(step))
        }

        // Many movements, still exactly one card, carrying only the latest
        // action — the card is a projection of state, not a feed of events.
        let card = try #require(project(state, at: 9))
        #expect(card.identity == identity)
        #expect(card.detail == "Step 8")
        #expect(state.presentation.activities.count > 1)
    }

    @Test func aReplacementTurnInTheSameSessionReplacesTheCardIdentity() throws {
        let first = reduce(
            MacChatTurnLifecycleState(identity: route(session: "s", turn: "turn-1"), startedAt: time(0)),
            .working(action: "First"),
            at: 1
        )
        let second = MacChatTurnLifecycleState(
            identity: route(session: "s", turn: "turn-2"),
            startedAt: time(10)
        )

        let a = try #require(project(first, at: 2))
        let b = try #require(project(second, at: 11))
        #expect(a.identity.turnId == "turn-1")
        #expect(b.identity.turnId == "turn-2")
        #expect(a.identity != b.identity)
    }

    // MARK: - Every phase projection

    @Test func everyLifecyclePhaseHasAnExplicitProjection() throws {
        // Swift's exhaustive switches already force a COMPILE error when a
        // phase is added, so asserting non-emptiness would prove nothing.
        // What a copy-pasted arm actually looks like is a DUPLICATE — a new
        // phase silently wearing another phase's words or icon.
        var titles: [String: TurnPresentationPhase] = [:]
        var symbols: [String: TurnPresentationPhase] = [:]
        for phase in TurnPresentationPhase.allCases {
            let title = MacChatTurnCardProjection.title(
                phase: phase,
                personaName: "Agent",
                delegateName: "Codex",
                cancellationPending: false
            )
            #expect(!title.isEmpty, "Phase \(phase) has no card title")
            if let owner = titles[title] {
                Issue.record("Phase \(phase) reuses \(owner)'s title \"\(title)\"")
            }
            titles[title] = phase

            let symbol = MacChatTurnCardProjection.symbolName(for: phase)
            #expect(!symbol.isEmpty, "Phase \(phase) has no card symbol")
            if let owner = symbols[symbol] {
                Issue.record("Phase \(phase) reuses \(owner)'s symbol \"\(symbol)\"")
            }
            symbols[symbol] = phase
        }
        #expect(titles.count == TurnPresentationPhase.allCases.count)
        #expect(symbols.count == TurnPresentationPhase.allCases.count)
    }

    @Test func liveWorkingFamilyPhasesReadAsMovingWork() throws {
        let expectations: [(TurnPresentationPhase, MacChatTurnCardModel.Tone, Bool)] = [
            (.acknowledged, .working, true),
            (.working, .working, true),
            (.tool, .working, true),
            (.delegation, .working, true),
            (.retrying, .working, true),
            (.waiting, .working, false),
            (.blocked, .attention, false),
            (.stalled, .attention, false),
        ]
        for (phase, tone, live) in expectations {
            #expect(MacChatTurnCardProjection.tone(for: phase) == tone, "tone for \(phase)")
            // `.stalled` is derived from elapsed silence, so it needs an
            // observation instant past the threshold; every other phase is
            // asserted by the owner and reads immediately.
            let observedAt: TimeInterval = phase == .stalled ? 200 : 2
            let card = try #require(project(nonTerminal(phase: phase), at: observedAt))
            #expect(card.phase == phase)
            #expect(card.tone == tone)
            #expect(card.showsLiveIndicator == live, "live indicator for \(phase)")
            #expect(card.isTerminal == false)
            #expect(card.secondsSinceMovement != nil)
        }
    }

    @Test func delegationNamesTheDelegateAndFallsBackWhenUnnamed() throws {
        let named = MacChatTurnCardProjection.title(
            phase: .delegation, personaName: "Agent", delegateName: "Codex", cancellationPending: false
        )
        #expect(named.contains("Codex"))
        let unnamed = MacChatTurnCardProjection.title(
            phase: .delegation, personaName: "Agent", delegateName: nil, cancellationPending: false
        )
        #expect(!unnamed.isEmpty)
        #expect(!unnamed.contains("Codex"))
    }

    @Test func completedTurnsResolveToNoCardRatherThanPermanentChrome() throws {
        let completed = reduce(
            MacChatTurnLifecycleState(identity: route(session: "s", turn: "t"), startedAt: time(0)),
            .completed,
            at: 4
        )
        #expect(completed.presentation.phase == .completed)
        // The answer in the transcript is the success surface. A permanent
        // "Completed" chip would be noise, not honesty.
        #expect(project(completed, at: 10) == nil)
        #expect(MacChatTurnCardProjection.isVisible(completed, sessionId: "s") == false)
    }

    @Test func outcomeUnknownLooksLikeNeitherSuccessNorError() throws {
        let unknown = reduce(
            MacChatTurnLifecycleState(identity: route(session: "s", turn: "t"), startedAt: time(0)),
            .outcomeUnknown(reason: nil),
            at: 5
        )
        let card = try #require(project(unknown, at: 60))

        #expect(card.phase == .outcomeUnknown)
        #expect(card.tone == .unresolved)
        #expect(card.tone != MacChatTurnCardProjection.tone(for: .completed))
        #expect(card.tone != MacChatTurnCardProjection.tone(for: .failed))
        #expect(card.symbolName == "questionmark.circle")
        #expect(card.title == "Outcome unknown")
        #expect(try #require(card.detail).contains("without proof"))
        #expect(card.showsLiveIndicator == false)
        #expect(card.isTerminal)
    }

    @Test func provenTerminalsLeaveNoPermanentChromeBehind() throws {
        // The card has no dismiss control and nothing clears a settled turn
        // until the user sends again, so a rendered terminal is permanent
        // chrome. Only a terminal the transcript cannot express earns that.
        for proven in [
            MacChatTurnLifecycleInput.Kind.completed,
            .failed(reason: "Provider refused the request"),
            .cancellationConfirmed,
        ] {
            let settled = reduce(
                MacChatTurnLifecycleState(identity: route(session: "s", turn: "t"), startedAt: time(0)),
                proven,
                at: 3
            )
            #expect(settled.presentation.isTerminal)
            #expect(
                MacChatTurnCardProjection.isVisible(settled, sessionId: "s") == false,
                "\(settled.presentation.phase) is carried by the transcript and must not linger as a card"
            )
            #expect(project(settled, at: 40) == nil)
        }
    }

    @Test func stoppingATurnClearsTheCardRatherThanStrandingIt() throws {
        // Regression guard: before the lifecycle owned visibility this gate
        // was `isBusy`, so Stop made the row vanish. Cancellation must still
        // end with nothing floating over the transcript.
        let requested = reduce(
            MacChatTurnLifecycleState(identity: route(session: "s", turn: "t"), startedAt: time(0)),
            .cancellationRequested,
            at: 2
        )
        #expect(try #require(project(requested, at: 3)).cancellationPending)

        let confirmed = reduce(requested, .cancellationConfirmed, at: 4)
        #expect(MacChatTurnCardProjection.isVisible(confirmed, sessionId: "s") == false)
        #expect(project(confirmed, at: 5) == nil)
        // ...and it stays gone however long the session sits open.
        #expect(project(confirmed, at: 86_400) == nil)
    }

    @Test func terminalTonesStayDistinctSoUnknownReadsAsNeitherOutcome() throws {
        // The tones are still separate registers even though only
        // outcome-unknown renders today — a future surface that shows a
        // proven terminal must not inherit the wrong colour.
        let tones = [
            MacChatTurnCardProjection.tone(for: .failed),
            MacChatTurnCardProjection.tone(for: .canceled),
            MacChatTurnCardProjection.tone(for: .outcomeUnknown),
            MacChatTurnCardProjection.tone(for: .completed),
        ]
        #expect(tones[0] == .failed)
        #expect(tones[1] == .canceled)
        #expect(tones[2] == .unresolved)
        #expect(Set(tones.map(String.init(describing:))).count == 4)
    }

    @Test func pendingCancellationIsHonestThatStoppingIsNotStopped() throws {
        let requested = reduce(
            MacChatTurnLifecycleState(identity: route(session: "s", turn: "t"), startedAt: time(0)),
            .cancellationRequested,
            at: 2
        )
        let card = try #require(project(requested, at: 3))
        #expect(card.cancellationPending)
        #expect(card.isTerminal == false)
        #expect(card.title.contains("Stopping"))
    }

    // MARK: - Elapsed and movement, no card-local clock

    @Test func elapsedTracksTheObservationInstantWhileLiveAndFreezesWhenTerminal() throws {
        let live = nonTerminal(phase: .working)
        #expect(try #require(project(live, at: 5)).elapsed == 5)
        #expect(try #require(project(live, at: 42)).elapsed == 42)

        // Outcome-unknown is the one terminal the card still renders, so it is
        // the only one whose frozen elapsed is observable here.
        let settled = reduce(live, .outcomeUnknown(reason: nil), at: 7)
        // Terminal elapsed is derived from the recorded end, so later
        // observations can never inflate a settled turn's duration.
        #expect(try #require(project(settled, at: 8)).elapsed == 7)
        #expect(try #require(project(settled, at: 9_999)).elapsed == 7)
        #expect(try #require(project(settled, at: 9_999)).secondsSinceMovement == nil)
    }

    @Test func movementPhraseStaysQuietUntilMovementActuallyGoesQuiet() throws {
        #expect(MacChatTurnCardFormat.movementPhrase(nil) == nil)
        #expect(MacChatTurnCardFormat.movementPhrase(5) == nil)
        #expect(MacChatTurnCardFormat.movementPhrase(19.9) == nil)
        #expect(MacChatTurnCardFormat.movementPhrase(20) == "no movement for 20s")
        #expect(MacChatTurnCardFormat.movementPhrase(125) == "no movement for 2m 5s")
    }

    @Test func durationFormattingIsCalmAcrossScales() {
        #expect(MacChatTurnCardFormat.duration(0) == "0s")
        #expect(MacChatTurnCardFormat.duration(59) == "59s")
        #expect(MacChatTurnCardFormat.duration(60) == "1m")
        #expect(MacChatTurnCardFormat.duration(3_599) == "59m 59s")
        #expect(MacChatTurnCardFormat.duration(3_600) == "1h")
        #expect(MacChatTurnCardFormat.duration(7_860) == "2h 11m")
        #expect(MacChatTurnCardFormat.duration(-5) == "0s")
        #expect(MacChatTurnCardFormat.duration(.infinity) == "0s")
    }

    // MARK: - Stall renders and recovers

    @Test func stallIsObservationalAndRecoversOnFreshMovement() throws {
        let identity = route(session: "s", turn: "t")
        let working = reduce(
            MacChatTurnLifecycleState(identity: identity, startedAt: time(0)),
            .working(action: "Reading the repository"),
            at: 1
        )

        // Below the threshold the card still reads as work in progress.
        let calm = try #require(project(working, at: 60))
        #expect(calm.phase == .working)
        #expect(calm.showsLiveIndicator)

        // Past it, the card says so — without claiming the turn failed.
        let stalled = try #require(project(working, at: 200))
        #expect(stalled.phase == .stalled)
        #expect(stalled.tone == .attention)
        #expect(stalled.tone != .failed)
        #expect(stalled.isTerminal == false)
        #expect(stalled.showsLiveIndicator == false)
        #expect(try #require(MacChatTurnCardFormat.movementPhrase(stalled.secondsSinceMovement))
            .hasPrefix("no movement"))

        // Fresh movement clears it with no extra state anywhere.
        let moved = reduce(working, .working(action: "Still reading"), at: 200)
        let recovered = try #require(project(moved, at: 201))
        #expect(recovered.phase == .working)
        #expect(recovered.showsLiveIndicator)
        #expect(recovered.tone == .working)
    }

    @Test func stallNeverOverwritesASettledTerminalCard() throws {
        for terminal in [
            MacChatTurnLifecycleInput.Kind.failed(reason: nil),
            .cancellationConfirmed,
            .outcomeUnknown(reason: nil),
        ] {
            let settled = reduce(
                MacChatTurnLifecycleState(identity: route(session: "s", turn: "t"), startedAt: time(0)),
                terminal,
                at: 1
            )
            // The effective phase is what the card would render, whether or
            // not this terminal is one the card shows. No terminal may drift.
            let effective = settled.effectivePhase(at: time(100_000))
            #expect(effective != .stalled, "A settled turn must never drift to stalled")
            #expect(effective == settled.presentation.phase)
            if let card = project(settled, at: 100_000) {
                #expect(card.phase == settled.presentation.phase)
            }
        }
    }

    // MARK: - Terminal immutability in the view layer

    @Test func aTerminalCardIsIdenticalNoMatterWhenItIsObserved() throws {
        let settled = reduce(
            MacChatTurnLifecycleState(identity: route(session: "s", turn: "t"), startedAt: time(0)),
            .outcomeUnknown(reason: "Interrupted"),
            at: 6
        )
        let first = try #require(project(settled, at: 7))
        for instant in [10.0, 500.0, 86_400.0] {
            #expect(try #require(project(settled, at: instant)) == first)
        }
    }

    @Test func lateActivityCannotReanimateOrMutateASettledCard() throws {
        let identity = route(session: "s", turn: "t")
        let settled = reduce(
            MacChatTurnLifecycleState(identity: identity, startedAt: time(0)),
            .outcomeUnknown(reason: "Interrupted mid-flight"),
            at: 3
        )
        let before = try #require(project(settled, at: 4))

        // The owner refuses the late event; the view has no path to disagree.
        let after = MacChatTurnLifecycleReducer.reduce(
            settled,
            input: MacChatTurnLifecycleInput(
                identity: identity,
                kind: .working(action: "A late straggler event"),
                occurredAt: time(9)
            )
        )
        #expect(after == settled)
        #expect(try #require(project(after, at: 10)) == before)
    }

    // MARK: - Identity isolation

    @Test func aCardNeverRendersForAnotherSession() throws {
        let state = nonTerminal(phase: .working, session: "session-a", turn: "turn-a")
        #expect(MacChatTurnCardProjection.card(
            for: state, sessionId: "session-b", personaName: "Agent", at: time(2)
        ) == nil)
        #expect(MacChatTurnCardProjection.isVisible(state, sessionId: "session-b") == false)
        #expect(MacChatTurnCardProjection.card(
            for: state, sessionId: "", personaName: "Agent", at: time(2)
        ) == nil)
        #expect(MacChatTurnCardProjection.card(
            for: nil, sessionId: "session-a", personaName: "Agent", at: time(2)
        ) == nil)
    }

    @Test @MainActor func concurrentDetachedTurnsEachRenderOnlyTheirOwnSurface() throws {
        let model = AppModel()
        _ = model.beginChatTurnLifecycle(sessionId: "session-a", turnId: "turn-a", at: time(0))
        _ = model.beginChatTurnLifecycle(sessionId: "session-b", turnId: "turn-b", at: time(0))
        _ = model.applyChatTurnLifecycleInput(MacChatTurnLifecycleInput(
            identity: route(session: "session-a", turn: "turn-a"),
            kind: .working(action: "Session A work"),
            occurredAt: time(1)
        ))
        _ = model.applyChatTurnLifecycleInput(MacChatTurnLifecycleInput(
            identity: route(session: "session-b", turn: "turn-b"),
            kind: .blocked(reason: "Session B is blocked"),
            occurredAt: time(1)
        ))

        let a = try #require(MacChatTurnCardProjection.card(
            for: model.chatTurnLifecycle(for: "session-a"),
            sessionId: "session-a", personaName: "Agent", at: time(2)
        ))
        let b = try #require(MacChatTurnCardProjection.card(
            for: model.chatTurnLifecycle(for: "session-b"),
            sessionId: "session-b", personaName: "Agent", at: time(2)
        ))
        #expect(a.identity.turnId == "turn-a")
        #expect(a.detail == "Session A work")
        #expect(a.phase == .working)
        #expect(b.identity.turnId == "turn-b")
        #expect(b.detail == "Session B is blocked")
        #expect(b.phase == .blocked)

        // Cross-render is impossible in either direction.
        #expect(MacChatTurnCardProjection.card(
            for: model.chatTurnLifecycle(for: "session-a"),
            sessionId: "session-b", personaName: "Agent", at: time(2)
        ) == nil)
        #expect(model.chatTurnLifecycle(for: "session-c") == nil)
    }

    @Test @MainActor func aStaleTurnsEventsCannotEnterTheReplacementTurnsCard() throws {
        let model = AppModel()
        _ = model.beginChatTurnLifecycle(sessionId: "s", turnId: "turn-old", at: time(0))
        _ = model.beginChatTurnLifecycle(sessionId: "s", turnId: "turn-new", at: time(10))
        _ = model.applyChatTurnLifecycleInput(MacChatTurnLifecycleInput(
            identity: route(session: "s", turn: "turn-old"),
            kind: .working(action: "Ghost of the previous turn"),
            occurredAt: time(11)
        ))

        let card = try #require(MacChatTurnCardProjection.card(
            for: model.chatTurnLifecycle(for: "s"), sessionId: "s", personaName: "Agent", at: time(12)
        ))
        #expect(card.identity.turnId == "turn-new")
        #expect(card.detail == nil)
        #expect(card.phase == .acknowledged)
    }

    @Test @MainActor func queuedTurnsDoNotOpenASecondCardBeforeTheyAreAccepted() throws {
        let model = AppModel()
        _ = model.beginChatTurnLifecycle(sessionId: "s", turnId: "turn-live", at: time(0))

        // Two real turns waiting behind the live one. A queued turn is not an
        // accepted turn, so it must open no lifecycle and no second card.
        model.queuedChatTurnsBySession["s"] = [
            QueuedChatTurn(id: "queued-1", text: "next", createdAt: time(1)),
            QueuedChatTurn(id: "queued-2", text: "after that", createdAt: time(2)),
        ]

        #expect(model.queuedChatTurnsBySession["s"]?.count == 2)
        #expect(model.chatTurnLifecycleBySession.count == 1)
        for queuedId in ["queued-1", "queued-2"] {
            #expect(model.chatTurnLifecycleBySession.values.allSatisfy {
                $0.identity.turnId != queuedId
            }, "\(queuedId) opened a lifecycle before it was accepted")
        }
        let card = try #require(MacChatTurnCardProjection.card(
            for: model.chatTurnLifecycle(for: "s"), sessionId: "s", personaName: "Agent", at: time(1)
        ))
        #expect(card.identity.turnId == "turn-live")
    }

    // MARK: - Restart repair projection

    @Test @MainActor func restartRepairProjectsOutcomeUnknownInsteadOfAFreshSpinnerOrASilentDrop() async throws {
        let model = AppModel()
        let interrupted = reduce(
            MacChatTurnLifecycleState(identity: route(session: "session-a", turn: "turn-a"), startedAt: time(0)),
            .working(action: "Was working when the app exited"),
            at: 1
        )
        let record = try #require(MacChatPersistedTurnLifecycle(state: interrupted))
        model.chatTurnLifecycleStore = MacChatTurnLifecycleStore(
            storage: CardRepairMemoryStorage([record]),
            maximumRecords: 4
        )

        await model.repairChatTurnLifecyclesIfNeeded(
            knownSessionIds: ["session-a"],
            at: time(100)
        ) { _ in .absent }

        let repaired = try #require(model.chatTurnLifecycle(for: "session-a"))
        let card = try #require(MacChatTurnCardProjection.card(
            for: repaired, sessionId: "session-a", personaName: "Agent", at: time(101)
        ))
        // Not a silent drop, not a fresh spinner, not a soft success.
        #expect(card.phase == .outcomeUnknown)
        #expect(card.tone == .unresolved)
        #expect(card.isTerminal)
        #expect(card.showsLiveIndicator == false)
        #expect(card.secondsSinceMovement == nil)
    }

    @Test @MainActor func restartRepairOfAProvablyCompletedTurnLeavesNoCardBehind() async throws {
        let model = AppModel()
        let interrupted = reduce(
            MacChatTurnLifecycleState(identity: route(session: "session-a", turn: "turn-a"), startedAt: time(0)),
            .working(action: "Was working when the app exited"),
            at: 1
        )
        model.chatTurnLifecycleStore = MacChatTurnLifecycleStore(
            storage: CardRepairMemoryStorage([try #require(MacChatPersistedTurnLifecycle(state: interrupted))]),
            maximumRecords: 4
        )

        await model.repairChatTurnLifecyclesIfNeeded(
            knownSessionIds: ["session-a"],
            at: time(100)
        ) { _ in .completed }

        #expect(model.chatTurnLifecycle(for: "session-a")?.presentation.phase == .completed)
        #expect(MacChatTurnCardProjection.card(
            for: model.chatTurnLifecycle(for: "session-a"),
            sessionId: "session-a", personaName: "Agent", at: time(101)
        ) == nil)
    }

    // MARK: - Exactly one progress surface

    @Test func bothWindowsComposeTheOneCardHostAndNoRivalProgressSurface() throws {
        let chatView = try AppSourceScraping.appSource("ChatView.swift")
        let detached = try AppSourceScraping.appSource("DetachedChatPanelView.swift")
        let composer = try AppSourceScraping.appSource("ChatComposerChrome.swift")

        #expect(occurrences(of: "MacChatTurnCardHost(", in: chatView) == 1)
        #expect(occurrences(of: "MacChatTurnCardHost(", in: detached) == 1)

        // The retired rows are gone, not merely unused.
        for source in [chatView, detached, composer] {
            #expect(!source.contains("ChatThinkingRow"))
            #expect(!source.contains("DetachedThinkingRow"))
        }

        // The detached window's own typing chip was a second live progress
        // surface stacked under the card. Both windows now show one thing.
        #expect(!detached.contains("TypingIndicator("))
        #expect(!detached.contains("showDetachedTyping"))

        // The detached card is gated on the same time-invariant truth as the
        // main window, so an idle window gains no phantom stack spacing.
        #expect(detached.contains("MacChatTurnCardProjection.isVisible("))
    }

    @Test func noOtherAppSourceRendersARivalTurnProgressSurface() throws {
        let root = try AppSourceScraping.appSourcesRoot()
        // TypingIndicator was the detached window's own chip. Deleting its one
        // call site left the component orphaned in the tree — alive enough for
        // someone to reach for again. The sweep names it so it cannot come
        // back, and so a dead rival cannot sit here green.
        let retired = ["ChatThinkingRow", "DetachedThinkingRow", "TypingIndicator"]
        for url in try AppSourceScraping.swiftSourceURLs(under: root) {
            let source = try String(contentsOf: url, encoding: .utf8)
            for name in retired {
                #expect(
                    !source.contains(name),
                    "\(url.lastPathComponent) still references retired progress surface \(name)"
                )
            }
            if url.lastPathComponent != "MacChatTurnCard.swift" {
                // The VIEW is what must stay singular. Match the declaration
                // exactly: a prefix match also catches value types that merely
                // start with the same name (e.g. the 658.12 approval value),
                // which are projections, not rival surfaces.
                for declaration in ["struct MacChatTurnCard:", "struct MacChatTurnCard "] {
                    #expect(
                        !source.contains(declaration),
                        "\(url.lastPathComponent) declares a second card component"
                    )
                }
            }
        }
    }

    @Test func cardVisibilityIsTheOneTruthSharedByLayoutAndTheCardItself() throws {
        let actions = try AppSourceScraping.appSource("ChatView+SessionActions.swift")
        // The layout gate must read the lifecycle owner's projection, not a
        // parallel busy flag that could disagree with what the card renders.
        let body = try #require(showThinkingRowBody(in: actions))
        #expect(body.contains("MacChatTurnCardProjection.isVisible("))
        // The gate must not fall back to a parallel busy/streaming flag that
        // could disagree with what the card itself renders.
        #expect(!body.contains("isBusy"))
        #expect(!body.contains("isChatStreaming"))
        #expect(!body.contains("busySessions"))
    }

    @Test func theTimingReadoutIsSpokenAsWordsNotPunctuation() throws {
        var state = MacChatTurnLifecycleState(
            identity: route(session: "s", turn: "t"),
            startedAt: time(0)
        )
        state = reduce(state, .working(action: "Thinking"), at: 1)
        let card = try #require(project(state, at: 61))

        // The visual string is deliberately terse and dot-separated; read
        // verbatim by VoiceOver that is punctuation noise.
        #expect(card.spokenMeta.contains("elapsed"))
        #expect(card.spokenMeta.contains("no movement for"))
        #expect(!card.spokenMeta.contains("\u{00B7}"))

        // And it must be wired, not merely available — an unreferenced
        // accessibility helper is the same as no accessibility at all.
        let source = try AppSourceScraping.appSource("MacChatTurnCard.swift")
        #expect(source.contains(".accessibilityLabel(model.spokenMeta)"))
    }

    @Test func aSettledCardNeverSwallowsTranscriptClicks() throws {
        let source = try AppSourceScraping.appSource("MacChatTurnCard.swift")
        // The card floats over the transcript, so a card with nothing to click
        // must become inert rather than eat the strip it covers. Desk 658.12
        // made "has controls" the truth (a settled turn can still hold a
        // pending approval); assert the VALUE, not just the modifier string.
        #expect(source.contains(".allowsHitTesting(model.hasControls)"))
        let settled = reduce(
            MacChatTurnLifecycleState(identity: route(session: "s", turn: "t"), startedAt: time(0)),
            .outcomeUnknown(reason: nil),
            at: 1
        )
        let card = try #require(project(settled, at: 2))
        #expect(card.isTerminal)
        #expect(card.approval == nil)
        #expect(card.hasControls == false)
    }

    @Test func theTitleIsNeverTruncatedInFavourOfTheElapsedReadout() throws {
        let source = try AppSourceScraping.appSource("MacChatTurnCard.swift")
        let title = try #require(source.range(of: "Text(model.title)"))
        let meta = try #require(source.range(of: "Text(meta)"))
        // Guard the ordering explicitly: slicing an inverted range would TRAP
        // rather than fail this test if the two rows were ever swapped.
        #expect(title.lowerBound < meta.lowerBound, "The title must precede the meta readout")
        guard title.lowerBound < meta.lowerBound else { return }
        let titleRow = String(source[title.lowerBound..<meta.lowerBound])
        // Title outranks both the meta readout and the Stop control, so a
        // narrow detached window truncates those first.
        #expect(titleRow.contains(".layoutPriority(2)"))
        #expect(occurrences(of: ".layoutPriority(2)", in: source) == 1)
        #expect(occurrences(of: ".layoutPriority(1)", in: source) == 1)
    }

    @Test func theTranscriptReservesMoreRoomThanTheCardCanOccupy() throws {
        // Two single-line rows inside GlassCard's 16pt vertical padding, plus
        // the 6pt overlay inset. Pinned so a future taller card cannot silently
        // start covering the last transcript line.
        #expect(MacChatTurnCardMetrics.floatingClearance >= 68)

        // ...and the constant must be what the transcript actually reserves.
        // Asserting the constant alone false-greens: someone could hardcode
        // the old 56 back at both sites and this test would never notice.
        let chatView = try AppSourceScraping.appSource("ChatView.swift")
        #expect(occurrences(of: "MacChatTurnCardMetrics.floatingClearance", in: chatView) == 2)
        #expect(!chatView.contains(".frame(height: 56)"))
        #expect(!chatView.contains("showThinkingRow ? 56"))
    }

    @Test func derivedTimeIsQuantizedSoStreamingTokensDoNotRerenderTheCard() throws {
        let identity = route(session: "s", turn: "t")
        var state = MacChatTurnLifecycleState(identity: identity, startedAt: time(0))
        state = reduce(state, .working(action: "Streaming"), at: 10)

        // Two observations inside the same displayed second must project the
        // identical model — otherwise every streamed token re-renders the glass.
        let a = try #require(project(state, at: 10.1))
        let b = try #require(project(state, at: 10.9))
        #expect(a == b)
        #expect(a.elapsed == 10)
        #expect(a.secondsSinceMovement == 0)

        let next = try #require(project(state, at: 11.0))
        #expect(next.elapsed == 11)
        #expect(next != a)
    }

    @Test func waitingDoesNotClaimMotionItCannotEscape() throws {
        // The shared kernel refuses to stall a waiting turn, so a live pulse
        // here would animate forever while nothing moves.
        let waiting = nonTerminal(phase: .waiting)
        let card = try #require(project(waiting, at: 100_000))
        #expect(card.phase == .waiting)
        #expect(card.showsLiveIndicator == false)
        #expect(card.isTerminal == false)
    }

    @Test func theCardOwnsNoClockOfItsOwn() throws {
        let source = try AppSourceScraping.appSource("MacChatTurnCard.swift")
        // One SwiftUI schedule, entered only on the live branch.
        #expect(occurrences(of: "TimelineView(", in: source) == 1)
        #expect(source.contains("if let state, !state.presentation.isTerminal {"))
        #expect(!source.contains("Timer."))
        #expect(!source.contains("Task.sleep"))
        #expect(!source.contains("@State"))
    }

    // MARK: - Helpers

    private func time(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_800_000_000).addingTimeInterval(offset)
    }

    private func route(session: String, turn: String) -> MacChatTurnIdentity {
        MacChatTurnIdentity(sessionId: session, turnId: turn)
    }

    private func reduce(
        _ state: MacChatTurnLifecycleState,
        _ kind: MacChatTurnLifecycleInput.Kind,
        at offset: TimeInterval
    ) -> MacChatTurnLifecycleState {
        MacChatTurnLifecycleReducer.reduce(
            state,
            input: MacChatTurnLifecycleInput(
                identity: state.identity,
                kind: kind,
                occurredAt: time(offset)
            )
        )
    }

    private func nonTerminal(
        phase: TurnPresentationPhase,
        session: String = "s",
        turn: String = "t"
    ) -> MacChatTurnLifecycleState {
        let initial = MacChatTurnLifecycleState(
            identity: route(session: session, turn: turn),
            startedAt: time(0)
        )
        switch phase {
        case .acknowledged:
            return initial
        case .working:
            return reduce(initial, .working(action: nil), at: 0)
        case .tool:
            return reduce(initial, .activity(activity(
                session: session, turn: turn, phase: .tool, action: "Using tool: read_file"
            )), at: 0)
        case .delegation:
            return reduce(initial, .activity(activity(
                session: session, turn: turn, phase: .delegation, action: "Handing off", delegate: "Codex"
            )), at: 0)
        case .retrying:
            return reduce(initial, .retrying(action: nil), at: 0)
        case .waiting:
            return reduce(initial, .waiting(action: nil), at: 0)
        case .blocked:
            return reduce(initial, .blocked(reason: nil), at: 0)
        case .stalled:
            // `.stalled` is derived, never asserted: hold at working and let
            // the observation instant cross the threshold.
            return reduce(initial, .working(action: nil), at: 0)
        case .completed, .failed, .canceled, .outcomeUnknown:
            return initial
        }
    }

    private func activity(
        session: String,
        turn: String,
        phase: TurnPresentationPhase,
        action: String?,
        delegate: String? = nil
    ) -> MacChatTurnActivity {
        MacChatTurnActivity(
            identity: route(session: session, turn: turn),
            source: .toolUse,
            phase: phase,
            toolDisplayName: nil,
            actionSummary: action,
            userVisibleNoticeText: nil,
            delegateDisplayName: delegate,
            occurredAt: time(0)
        )
    }

    private func project(
        _ state: MacChatTurnLifecycleState,
        at offset: TimeInterval
    ) -> MacChatTurnCardModel? {
        MacChatTurnCardProjection.card(
            for: state,
            sessionId: state.identity.sessionId,
            personaName: "Agent",
            at: time(offset)
        )
    }

    private func showThinkingRowBody(in source: String) -> String? {
        guard let start = source.range(of: "var showThinkingRow: Bool {"),
              let end = source.range(
                  of: "\n    }",
                  range: start.upperBound..<source.endIndex
              ) else { return nil }
        return String(source[start.upperBound..<end.lowerBound])
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var range = haystack.startIndex..<haystack.endIndex
        while let match = haystack.range(of: needle, range: range) {
            count += 1
            range = match.upperBound..<haystack.endIndex
        }
        return count
    }
}

/// In-memory lifecycle storage for the restart-repair projection tests.
private actor CardRepairMemoryStorage: MacChatTurnLifecycleStorage {
    private var stored: [MacChatPersistedTurnLifecycle]

    init(_ initial: [MacChatPersistedTurnLifecycle] = []) {
        stored = initial
    }

    func load() async throws -> [MacChatPersistedTurnLifecycle] {
        stored
    }

    func save(_ records: [MacChatPersistedTurnLifecycle]) async throws {
        stored = records
    }
}
