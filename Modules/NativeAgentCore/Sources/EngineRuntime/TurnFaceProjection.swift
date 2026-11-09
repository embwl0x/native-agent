import ChatTurnRuntime
import Foundation
import NativeAgentCore
import NativeAgentShared
import Observation
import PersistenceCore
import Transcripts
// Blueprint: | `TurnFaceProjection.swift` | `TurnFaceProjection`: off-main finished turn faces, ordered from canonical owners and deduplicated before posting |

/// The retained values are the send cache, never lifecycle or approval authority.
actor TurnFaceProjection {
    struct Input: Sendable {
        let knownSessions: [ChatSession]
        let lifecycles: [String: MacChatTurnLifecycleState]
        let busy: Set<String>
        let streaming: Set<String>
        let replying: Set<String>
        let active: [String: String]
        let previews: [String: TurnFace.Preview]
        let name: String
    }

    private let source: FaceFeedSource
    private let dataRoot: URL
    private let approvals: ApprovalsFacade
    private var sent: [String: TurnFace] = [:]
    private var sentSessions: TurnSessionsFace?

    init(source: FaceFeedSource, dataRoot: URL, approvals: ApprovalsFacade) {
        self.source = source
        self.dataRoot = dataRoot
        self.approvals = approvals
    }

    func sessionsFace() -> TurnSessionsFace? { sentSessions }

    func post(_ input: Input) async {
        let approvalSnapshot = await approvals.snapshot()
        let flight = ChatCancelFlag.inFlightTurns(dataRoot: dataRoot)
        let sessions = Set(input.knownSessions.map(\.id)).union(input.lifecycles.keys).union(input.busy).union(input.streaming)
            .union(input.replying).union(input.active.keys).union(input.previews.keys).union(flight.map(\.sessionId))
        var streaming: Set<String> = []
        let inFlightSessions = Set(flight.map(\.sessionId))
        for session in sessions.union(sent.keys).sorted() {
            let state = input.lifecycles[session]
            let turn = state?.presentation
            let settled = state?.replyTextSettled == true
            let busy = input.busy.contains(session) && !settled
            let streams = input.streaming.contains(session) && !settled
            if streams { streaming.insert(session) }
            var steps: [TurnFace.Step] = []
            for activity in turn?.activities ?? [] where !activity.phase.isTerminal {
                guard let detail = activity.detail, steps.last?.text != detail else { continue }
                let outcome: TurnFace.Step.Outcome?
                switch activity.outcome {
                case .ok: outcome = .ok
                case .refused: outcome = .refused
                case .failed: outcome = .failed
                case nil: outcome = nil
                }
                steps.append(.init(text: detail, outcome: outcome))
            }
            let current = turn.flatMap { $0.isTerminal ? nil : $0.writing?.line ?? $0.currentAction }
            if let current, steps.last?.text == current { steps.removeLast() }
            let liveLine = turn.map { $0.currentAction ?? ($0.streamedTextLength > 0 ? "Writing the reply" : "Thinking") }
            let preview = input.previews[session]
            let waiting = turn?.phase == .waiting || turn?.phase == .retrying
            let what = waiting ? turn?.currentAction
                : preview?.imageError ?? (preview?.isShowable == true ? preview?.caption : turn?.currentAction)
            let value = TurnFace(
                sessionID: session, turnID: state?.identity.turnId, activeTurnID: input.active[session], phase: turn?.phase,
                isInFlight: inFlightSessions.contains(session),
                card: TurnCardReadout.card(for: state, sessionId: session, personaName: input.name,
                    approvals: approvalSnapshot.records, parseTimestamp: NativeTimestampFormat.parseISO8601FractionalFirst),
                hasReservation: input.busy.contains(session),
                isBusy: busy, isStreaming: streams, isReplying: input.replying.contains(session) && !settled,
                isThinking: (busy || streams) && turn.map { !$0.isTerminal && $0.streamedTextLength == 0 } != false,
                liveLine: current ?? liveLine,
                workPill: what.map { "Working · " + TodayWords.bounded($0, limit: 36) },
                steps: Array(steps.reversed()), preview: preview, approvalStatus: approvalSnapshot.status
            )
            if sent[session] != value {
                await source.post(value, at: .turn(session: session))
                sent[session] = value
            }
            if !sessions.contains(session) { sent[session] = nil }
        }
        var roster = TurnSessionsFace(activeTurnIDs: input.active,
            inFlightTurnIDs: Set(flight.map(\.turnId)), streamingSessionIDs: streaming)
        roster.movements = input.lifecycles.keys.sorted().compactMap { session in
            guard let state = input.lifecycles[session] else { return nil }
            let runID = flight.first { $0.sessionId == session && $0.turnId == state.identity.turnId }?.runId
            return TurnCardReadout.movement(for: state, runID: runID)
        }
        if sentSessions != roster {
            await source.post(roster, at: .turns)
            sentSessions = roster
            NotificationCenter.default.post(name: .turnSessionsFacePublished, object: nil)
        }
    }
}

extension TurnsFacade {
    /// Capture owner values on their actor; projection and encoding never run on the drawing thread.
    func bindTurnFaces(source: FaceFeedSource, approvals: ApprovalsFacade, persona: PersonaFacade, transcripts: TranscriptsFacade) {
        turnFaceProjection = TurnFaceProjection(source: source, dataRoot: dataRoot, approvals: approvals)
        transcripts.bindSessionFaces()
        transcripts.sessionIndexDidPublish = { [weak self, weak persona, weak transcripts] in
            guard let self, let persona, let transcripts else { return }
            self.publishTurnFaces(persona: persona, transcripts: transcripts)
        }
        runtime.faceDidChange = { [weak self, weak persona, weak transcripts] in
            guard let self, let persona, let transcripts else { return }
            publishTurnFaces(persona: persona, transcripts: transcripts)
            transcripts.publishSessionFaces()
        }
        turnFlightObserver = NotificationCenter.default.addObserver(
            forName: ChatCancelFlag.inFlightDidChange, object: nil, queue: nil
        ) { [weak self, weak persona, weak transcripts] _ in
            Task { @MainActor in
                guard let self, let persona, let transcripts else { return }
                self.publishTurnFaces(persona: persona, transcripts: transcripts)
                transcripts.publishSessionFaces()
            }
        }
        approvalFaceChanges = Task { [weak self, weak persona, weak transcripts] in
            for await _ in await approvals.changes() {
                guard let self, let persona, let transcripts else { return }
                self.publishTurnFaces(persona: persona, transcripts: transcripts)
            }
        }
        observeTurnFaceDependencies(persona: persona, transcripts: transcripts)
    }

    private func observeTurnFaceDependencies(persona: PersonaFacade, transcripts: TranscriptsFacade) {
        withObservationTracking {
            _ = (persona.profile, persona.profileError)
        } onChange: { [weak self, weak persona, weak transcripts] in
            Task { @MainActor in
                guard let self, let persona, let transcripts else { return }
                self.observeTurnFaceDependencies(persona: persona, transcripts: transcripts)
            }
        }
        publishTurnFaces(persona: persona, transcripts: transcripts)
    }

    private func publishTurnFaces(persona: PersonaFacade, transcripts: TranscriptsFacade) {
        guard let projection = turnFaceProjection else { return }
        let input = TurnFaceProjection.Input(
            knownSessions: transcripts.sessions,
            lifecycles: runtime.lifecycleBySession, busy: runtime.busySessions, streaming: runtime.streamingSessions,
            replying: runtime.replyingSessions, active: runtime.activeTurnIDsBySession, previews: runtime.screenPreviewBySession,
            name: persona.displayName
        )
        // The newest input replaces one still waiting: a burst of changes is one projection of the latest state.
        pendingTurnFaceInput = input
        guard turnFacePublication == nil else { return }
        turnFacePublication = Task.detached { [weak self] in
            while let input = await self?.takeTurnFaceInput() { await projection.post(input) }
        }
    }

    private func takeTurnFaceInput() -> TurnFaceProjection.Input? {
        defer { pendingTurnFaceInput = nil }
        if pendingTurnFaceInput == nil { turnFacePublication = nil }
        return pendingTurnFaceInput
    }
}
