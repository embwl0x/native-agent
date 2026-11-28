import Foundation
import NativeAgentCore
import NativeAgentShared
import Observation
import PersistenceCore
import SenseCore
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
        let nowOn: [String: String]
        let name: String
    }

    private let source: FaceFeedSource
    private let pages: PartFaces
    private let dataRoot: URL
    private let approvals: ApprovalsFacade
    private let bodyField: BodyField?
    private var sent: [String: TurnFace] = [:]
    private var sentSessions: TurnSessionsFace?

    init(source: FaceFeedSource, pages: PartFaces, dataRoot: URL, approvals: ApprovalsFacade, bodyField: BodyField?) {
        self.bodyField = bodyField
        self.source = source
        self.pages = pages
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
        var placesChanged = false
        for session in sessions.union(sent.keys).sorted() {
            let state = input.lifecycles[session]
            let turn = state?.presentation
            let settled = state?.replyTextSettled == true
            let busy = input.busy.contains(session) && !settled
            let streams = input.streaming.contains(session) && !settled
            if streams { streaming.insert(session) }
            // Each step (one of her acts) keeps its turn's identity for it from start to end; the one running now is a row like the rest.
            var steps: [TurnFace.Step] = []
            for activity in turn?.activities ?? [] where !activity.phase.isTerminal {
                guard let state, let detail = activity.detail else { continue }
                let outcome: TurnFace.Step.Outcome?
                switch activity.outcome {
                case .ok: outcome = .ok
                case .refused: outcome = .refused
                case .failed: outcome = .failed
                case nil: outcome = nil
                }
                let digest = activity.unstartedID.map { SHA256Hex.of(utf8: $0) }
                let id = state.identity.turnId + "#" + String(activity.id) + (digest.map { "#" + $0 } ?? "")
                steps.append(.init(id: id, text: detail, outcome: outcome,
                                   isRunning: activity.runningCall != nil && !state.presentation.isTerminal, startedAt: activity.occurredAt,
                                   disposition: activity.disposition))
            }
            // While a step runs, that step is what she is doing on every line.
            let doing = turn?.runningStep?.detail
            let current = turn.flatMap { $0.isTerminal ? nil : doing ?? $0.writing?.line ?? $0.currentAction }
            let liveLine = turn.map { $0.currentAction ?? ($0.streamedTextLength > 0 ? "Writing the reply" : "Thinking") }
            let preview = input.previews[session]
            let waiting = turn?.phase == .waiting || turn?.phase == .retrying
            let what = waiting && doing == nil ? turn?.currentAction
                : preview?.imageError ?? (preview?.isShowable == true ? preview?.caption : doing ?? turn?.currentAction)
            let value = TurnFace(
                sessionID: session, turnID: state?.identity.turnId, activeTurnID: input.active[session],
                // The ending as it stands now: a turn waiting on an approval stops waiting once the approval is decided.
                phase: state.map { TurnCardReadout.phase(of: $0, approvals: approvalSnapshot.records,
                    parseTimestamp: NativeTimestampFormat.parseISO8601FractionalFirst) },
                isInFlight: inFlightSessions.contains(session),
                card: TurnCardReadout.card(for: state, sessionId: session, personaName: input.name,
                    approvals: approvalSnapshot.records, parseTimestamp: NativeTimestampFormat.parseISO8601FractionalFirst),
                isBusy: busy, isStreaming: streams, isReplying: input.replying.contains(session) && !settled,
                isThinking: (busy || streams) && turn.map { !$0.isTerminal && $0.streamedTextLength == 0 } != false,
                liveLine: current ?? liveLine,
                workPill: what.map { "Working · " + TodayWords.bounded($0, limit: 36) },
                steps: Array(steps.reversed()), preview: preview, approvalStatus: approvalSnapshot.status,
                nowOn: state.map { !$0.presentation.isTerminal } == true ? input.nowOn[session] : nil
            )
            if sent[session]?.nowOn != value.nowOn { placesChanged = true }
            if sent[session] != value {
                await source.post(value, at: .turn(session: session))
                let run = flight.first { $0.sessionId == session && $0.turnId == value.turnID }?.runId
                await postSteps(value, after: sent[session], run: run)
                sent[session] = value
            }
            if !sessions.contains(session) { sent[session] = nil }
        }
        if placesChanged { await bodyField?.places(sent.compactMapValues(\.nowOn), dataRoot: dataRoot) }
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
            NotificationCenter.default.post(TurnSessionsFace.Published())
        }
    }

    private func postSteps(_ turn: TurnFace, after previous: TurnFace?, run: String?) async {
        let subject = Self.liveStepSubject(turn)
        let prior = previous.flatMap(Self.liveStepSubject)
        let page = PageFaceKey.turnSteps(turn.sessionID)
        if prior != nil, prior != subject {
            await settle { [pages] in await pages.retireTransient(page: page) }
        }
        guard let subject, subject != prior || turn.steps != previous?.steps else { return }
        var actions: [PartFace.Action] = []
        if let run {
            let args: [String: PartFace.Value] = ["session": .string(turn.sessionID), "turn": .string(subject), "run": .string(run)]
            if await ChatTurnSteering.shared.canWithdrawUnstarted(in: .init(sessionId: turn.sessionID, turnId: subject),
                                                                 run: run, dataRoot: dataRoot) {
                let withdraw = ChatTurnSteering.OwnerAct.withdrawUnstarted.rawValue
                actions.append(.init(id: withdraw, label: "Withdraw unstarted steps", role: .primary, doors: ["mac"], call: .init(withdraw, args)))
            }
            let stop = ChatTurnSteering.OwnerAct.stop.rawValue
            actions.append(.init(id: stop, label: "Stop", doors: ["mac"], call: .init(stop, args)))
        }
        await pages.publishTransient(page: page, subject: subject,
            face: .turnSteps(Array(turn.steps.prefix(3).reversed())),
            levers: actions.isEmpty ? [] : [.init(id: "turn-controls", style: .note,
                rows: [.init(id: subject, title: "Remaining work", actions: actions)])])
    }

    private static func liveStepSubject(_ turn: TurnFace) -> String? {
        guard let id = turn.turnID, turn.activeTurnID == id, turn.phase?.isTerminal == false, !turn.steps.isEmpty else { return nil }
        return id
    }
}

extension TurnsFacade {
    /// Capture owner values on their actor; projection and encoding never run on the drawing thread.
    func bindTurnFaces(source: FaceFeedSource, pages: PartFaces, approvals: ApprovalsFacade, persona: PersonaFacade, transcripts: TranscriptsFacade) {
        turnFaceProjection = TurnFaceProjection(source: source, pages: pages, dataRoot: dataRoot, approvals: approvals, bodyField: bodyField)
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
        turnFlightObserver = NotificationCenter.default.observeSynchronously(
            for: ChatCancelFlag.InFlightDidChange.self
        ) { [weak self, weak persona, weak transcripts] in
            Task { @MainActor in
                guard let self, let persona, let transcripts else { return }
                self.publishTurnFaces(persona: persona, transcripts: transcripts)
                transcripts.publishSessionFaces()
            }
        }
        let publish: @MainActor @Sendable () -> Void = { [weak self, weak persona, weak transcripts] in
            guard let self, let persona, let transcripts else { return }
            self.publishTurnFaces(persona: persona, transcripts: transcripts)
        }
        let profiles = Observations { _ = (persona.profile, persona.profileError) }
        approvalFaceChanges?.cancel()
        approvalFaceChanges = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await _ in await approvals.changes() {
                        guard !Task.isCancelled else { return }
                        await publish()
                    }
                }
                for await _ in profiles {
                    guard !Task.isCancelled else { break }
                    publish()
                }
                group.cancelAll()
            }
        }
        publish()
    }

    private func publishTurnFaces(persona: PersonaFacade, transcripts: TranscriptsFacade) {
        guard let projection = turnFaceProjection else { return }
        let input = TurnFaceProjection.Input(
            knownSessions: transcripts.sessions,
            lifecycles: runtime.lifecycleBySession, busy: runtime.busySessions, streaming: runtime.streamingSessions,
            replying: runtime.replyingSessions, active: runtime.activeTurnIDsBySession, previews: runtime.screenPreviewBySession,
            nowOn: runtime.nowOnBySession, name: persona.displayName
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
