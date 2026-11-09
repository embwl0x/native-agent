import AuthoredCapabilities
import Experiences
import Foundation
import ChatTurnRuntime
import ChatTurnContracts
import ChatToolRuntime
import MacIntegration
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TurnTrace
import ProviderRouting
import TrustCenter
import ToolRegistry
import MacControl
import Transcripts
import Studio
import MemoryV2
import AgentWorkspace
import ApprovalInbox
import Desk
import ChatSessionWork
import AgentConversations
import ChatToolParsing
import DreamREMCycle
import Dispatcher
import Browser
import NotificationInbox
// Blueprint: | `InlineInteractionContinuation.swift` | Claim before replay; settle after Stop. |
extension InlineInteractionResolver {
    /// Claim durably before starting so racing taps resume once; invalidated or resumed claims start nothing.
    static func resumeOnce(
        _ interaction: InlineInteraction,
        sessionID: String,
        dataRoot: URL,
        turn: Turn?
    ) async {
        // A live host claims its own continuation in the originating task.
        guard !waitingHosts.contains(interaction.id),
              interaction.continuation?.state == .waiting,
              interaction.continuation?.resumedByTurnId == nil,
              resumesInFlight[interaction.id] == nil else { return }
        _ = await resumeUnderPeerProvenance(interaction, sessionID: sessionID, dataRoot: dataRoot, turn: turn)
    }
    /// This owner holds the continuation until its effect ends, then writes its one terminal record and releases the slot, even after Stop.
    static func resumeUnderPeerProvenance(
        _ interaction: InlineInteraction, sessionID: String, dataRoot: URL, turn: Turn?
    ) async -> JSONValue? {
        guard interaction.continuation?.state == .waiting,
              interaction.continuation?.resumedByTurnId == nil,
              resumesInFlight[interaction.id] == nil else { return nil }
        let carried: (sources: [String], elevated: [String])
        do {
            carried = try PeerDataTaint.steer(in: .object([
                "sources": interaction.continuation?.peerSources.map { .array($0.map(JSONValue.string)) } ?? .null,
                "elevated": interaction.continuation?.elevatedPeerSources.map { .array($0.map(JSONValue.string)) } ?? .null,
            ]))
        } catch {
            RepairOwed.owe(dataRoot, id: "interaction.provenance:" + interaction.id, kind: .run,
                operation: "interaction.provenance:" + interaction.id, owner: "Inline interaction " + interaction.id,
                words: error.localizedDescription,
                lever: "Preserve the waiting interaction and repair its recorded provenance before continuation.")
            return nil
        }
        let servesRunningTurn = turn.map {
            $0.id == interaction.continuation?.originTurnId && $0.session == sessionID
        } == true
        let host = servesRunningTurn ? turn : nil
        let taint = host?.peerSteering ?? PeerDataTaint(restoring: carried.sources, elevated: carried.elevated)
        carried.sources.forEach { taint.mark(peer: $0) }
        carried.elevated.forEach { taint.elevate(peer: $0) }
        do {
            let currentLife = try await Task.detached { try DataRootLife.isCurrent(interaction.continuation?.lifeID, in: dataRoot) }.value
            guard currentLife else { return nil }
        } catch { nativeLog("[interaction] life identity is unavailable: \(error)"); return nil }
        // The life read suspended; another tap may now hold this continuation.
        guard resumesInFlight[interaction.id] == nil else { return nil }
        // A card tap/restart has no running parent. Its continuation is a new act; a waiting host keeps its own turn.
        guard let continuation = interaction.continuation else { return nil }
        let heldTurn = (host ?? Turn(run: continuation.resumeRunId, session: sessionID)).with(\.peerSteering, taint)
        let owner = Task { [heldTurn] in
            await runContinuation(interaction, sessionID: sessionID, dataRoot: dataRoot,
                                  turn: heldTurn, servesRunningTurn: servesRunningTurn)
        }
        resumesInFlight[interaction.id] = owner
        return await withTaskCancellationHandler {
            await owner.value
        } onCancel: {
            owner.cancel()
        }
    }
    private static func runContinuation(
        _ interaction: InlineInteraction, sessionID: String, dataRoot: URL, turn: Turn, servesRunningTurn: Bool
    ) async -> JSONValue? {
        var record = interaction
        record.continuation?.state = .claimed
        record.continuation?.reason = nil
        do {
            try await persist(record, sessionID: sessionID, dataRoot: dataRoot, expecting: {
                $0.revision == interaction.revision && $0.continuation?.state == .waiting
                    && $0.continuation?.resumedByTurnId == nil
            })
        } catch {
            await settle { @MainActor in resumesInFlight[interaction.id] = nil }
            nativeLog("[interaction] resume claim failed for \(interaction.id): \(error)")
            return nil
        }
        var result: JSONValue?
        var handBack: String?
        do {
            (result, handBack) = try await continueRequest(&record, sessionID: sessionID, dataRoot: dataRoot,
                                                         turn: turn, servesRunningTurn: servesRunningTurn)
            record.continuation?.state = .resumed
        } catch is CancellationError {
            record.continuation?.state = .invalidated
            if case .settled(var outcome) = record.state {
                outcome.summary += record.continuation?.replayedAt != nil
                    ? " The blocked call ran; its result is saved. Stopped before continuing."
                    : " Stopped before continuing."
                record.state = .settled(outcome)
            }
        } catch {
            record.continuation?.reason = TurnSecretRedactor.redactText(error.localizedDescription)
            record.revision += 1
            // A recoverable failure waits for an explicit retry; only Stop or deliberate invalidation permanently retires the continuation.
            record.continuation?.state = .waiting
        }
        let terminal = record
        let landedResult = result
        let landedHandBack = handBack
        return await settle { @MainActor in
            defer { resumesInFlight[interaction.id] = nil }
            do {
                try await persist(terminal, sessionID: sessionID, dataRoot: dataRoot, expecting: {
                    $0.revision == interaction.revision
                        && ($0.continuation?.state == .claimed || $0.continuation?.state == .replaying)
                })
                if let landedHandBack { handBacks[interaction.id] = landedHandBack }
                return landedResult
            } catch {
                nativeLog("[interaction] continuation settlement failed for \(interaction.id): \(error)")
                return nil
            }
        }
    }
    /// Retry only the saved continuation, never the already completed setup or a checkpointed effect.
    public static func retryContinuation(_ interaction: InlineInteraction, sessionID: String, dataRoot: URL, turn: Turn?) async throws {
        guard interaction.continuationFailure != nil else { throw ResolveError.alreadySettled(interaction.state.name) }
        await resumeOnce(interaction, sessionID: sessionID, dataRoot: dataRoot, turn: turn)
    }
    private static func continueRequest(
        _ record: inout InlineInteraction, sessionID: String, dataRoot: URL, turn: Turn, servesRunningTurn: Bool
    ) async throws -> (JSONValue?, String?) {
        func failure(_ reason: String) -> NSError {
            NSError(domain: "InteractionCard", code: 2, userInfo: [NSLocalizedDescriptionKey: reason])
        }
        guard let recordedOrigin = try await originEnvelope(of: record.id, sessionID: sessionID, dataRoot: dataRoot) else {
            throw failure("This card has no recorded origin. Review it and raise a new request before continuing.")
        }
        guard let originTurnID = record.continuation?.originTurnId, !originTurnID.isEmpty else {
            throw failure("This card has no recorded turn identity. Raise a new request before continuing.")
        }
        var origin = recordedOrigin
        // A persisted envelope is not authority: recheck the signed phone's witness against the current pairing before either world effect.
        if let continuation = record.continuation, continuation.signatureReceipt?.isEmpty == false {
            let witness = InlineInteractionSignatureWitness.Witness(
                sessionID: sessionID, interactionID: record.id, continuation: continuation,
                originEnvelope: origin, interaction: record)
            let signed = await Task.detached { InlineInteractionSignatureWitness.isStillSigned(witness) }.value
            guard signed else {
                throw failure("This came from your iPhone and I can't verify that phone any more. "
                    + "Sign in from the phone again, then Try again.")
            }
            origin = TurnEnvelope(surface: origin.surface, agent: origin.agent, verifiedChatId: origin.verifiedChatId,
                verifiedUserId: origin.verifiedUserId, commandSignatureVerified: true,
                deliveryRoute: origin.deliveryRoute, declaredRemote: origin.declaredRemote,
                macContinuation: origin.macContinuation, workIdentity: origin.workIdentity,
                answerExperienceID: origin.answerExperienceID)
        }
        // Every replay takes authority and routing from the card. A matching
        // host contributes its other parts; the answering door contributes neither.
        var replayTurn = turn.with(\.envelope, origin).with(\.verifiedSessionID, sessionID)
        if let ceiling = record.continuation?.fileAccessCeiling {
            replayTurn.fileAccessCeiling = ceiling
        } else if !servesRunningTurn {
            throw failure("This card has no recorded file-access ceiling. Raise a new request from its originating conversation before continuing.")
        }
        var hostResult: JSONValue?
        if let continuation = record.continuation, continuation.replayedAt == nil, record.state.outcome != nil,
           continuation.mode == .retryBlockedTool,
           let toolName = continuation.toolName,
           let arguments = continuation.toolArgumentsJSON, let replayBlockedTool {
            try Task.checkCancellation()
            // Keep the crash witness before dispatch; a lost process cannot turn an uncertain send back into permission to send it twice.
            record.continuation?.state = .replaying
            try await persistTransition(record, from: .claimed, sessionID: sessionID, dataRoot: dataRoot)
            try Task.checkCancellation()
            let runID = continuation.resumeRunId
            guard replayedResumeRunIds.insert(runID).inserted else {
                throw failure("The \(toolName) call already ran, but its saved result is unavailable.")
            }
            // A call the person decided resumes as the person's own act once the person answered its card: the gate admits that exact
            // call once, with no second ask. Any other parked call (and arguments that do not read as one object) replays as the agent's.
            // The person's act names the call held in memory when it parked; a replayed call that differs from it is judged as the agent's.
            var replayAs = replayTurn
            let personParked = PersonParkedCalls.take(record.id)
            if let personParked {
                replayAs = replayTurn.with(\.personAct, PersonAct(by: .card(id: record.id), tool: personParked.tool, input: personParked.input,
                    spent: []))
            }
            switch await replayBlockedTool(toolName, arguments, sessionID, replayAs) {
            case .dispatched(let result):
                hostResult = result.flatMap { try? JSONValue.parse(Data($0.utf8)) }
                record.continuation?.replayedAt = Date()
                record.continuation?.replayedResult = result.map {
                    SwiftNativeChatOrchestrationClient.redactedPersistedToolResult(
                        tool: ToolNameAliases.shown(toolName, inputJSON: arguments).name, json: $0, turn: replayTurn)
                }
            case .failed(let reason):
                replayedResumeRunIds.remove(runID)
                // The call never ran: the person's retry of the card resumes it as theirs again.
                if let personParked { PersonParkedCalls.park(record.id, tool: personParked.tool, input: personParked.input) }
                try Task.checkCancellation()
                throw failure(reason)
            }
            // Saving a landed result is settlement, never a cancellable write.
            record.continuation?.state = .claimed
            try await persistTransition(record, from: .replaying, sessionID: sessionID, dataRoot: dataRoot)
        }
        try Task.checkCancellation()
        if servesRunningTurn, waitingHosts.contains(record.id) {
            guard let hostResult else { throw failure("The blocked call could not resume.") }
            record.continuation?.resumedByTurnId = turn.id
            return (hostResult, nil)
        }
        let replayed = record.continuation?.replayedAt != nil
        let prompt: String
        if record.continuation?.mode == .continueTurn, record.state.outcome != nil,
           let text = record.continuation?.resumeText, !text.isEmpty {
            prompt = text
        } else {
            prompt = continuationPrompt(for: record, replayed: replayed,
                                        replayedResult: record.continuation?.replayedResult)
        }
        if servesRunningTurn, await ChatTurnSteering.shared.isTurnOpen(sessionId: sessionID, turnID: originTurnID) {
            try Task.checkCancellation()
            record.continuation?.resumedByTurnId = turn.id
            return (nil, prompt)
        }
        guard let startTurn else { throw failure("The request could not continue: no turn starter is available.") }
        let binding: InlineInteractionModelOverride.Binding? = try {
            guard record.kind == .modelChoice, let outcome = record.state.outcome,
                  outcome.scope == .thisRequestOnly, let model = outcome.selection else { return nil }
            guard let qualified = InlineInteractionRegistry.splitModelOptionID(model) else {
                throw failure("This saved model choice does not name its account. Choose an account-qualified model in Providers before continuing.")
            }
            return .init(group: record.target, providerID: qualified.providerID,
                         model: qualified.modelID)
        }()
        record.continuation?.state = .replaying
        try await persistTransition(record, from: .claimed, sessionID: sessionID, dataRoot: dataRoot)
        try Task.checkCancellation()
        let synthetic = prompt != record.continuation?.resumeText
        let resumedTurn = (servesRunningTurn ? replayTurn.derived() : replayTurn)
            .with(\.session, sessionID)
            .with(\.modelOverride, binding)
            .with(\.rows.questionRunID, synthetic ? record.continuation?.originRunId : nil)
        let admitted = await startTurn(prompt, sessionID, synthetic, resumedTurn)
        guard admitted else {
            try Task.checkCancellation()
            throw failure("That couldn't be continued just now. Try again.")
        }
        return (nil, nil)
    }
    /// Reclaim only same-life work stranded by process exit. Cross-life reads are stopped, so conversation open cannot replay a restored card.
    public static func reclaimStrandedContinuations(
        sessionID: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async {
        guard !reclaimedSessions.contains(sessionID) else { return }
        let read: (rows: [JSONValue], lifeID: String)
        do {
            read = try await checkedRows(sessionID, dataRoot)
        } catch {
            return
        }
        // Mark the session only after its checked read and mutations succeed.
        var reconciled = true
        let pairs = await Task.detached { interactionsByRow(in: read.rows, lifeID: read.lifeID) }.value
        for (_, interaction) in pairs {
            // A same-life control held by the departed process needs a new tap. A card waiting on macOS held nothing there: this launch's GrantWatch
            // resumes its walk at the item it recorded.
            if case .running = interaction.state, interaction.waitingOn == nil {
                let orphaned = interaction.failed(
                    reason: "The app closed before this finished."
                )
                do {
                    try await persist(
                        orphaned, sessionID: sessionID, ifRevision: interaction.revision,
                        dataRoot: dataRoot,
                        expecting: { $0.continuation?.state == interaction.continuation?.state }
                    )
                } catch {
                    reconciled = false
                }
                continue
            }
            // Mid-dispatch/admission has an unknown outcome; only the person retries.
            if interaction.continuation?.state == .replaying,
               resumesInFlight[interaction.id] == nil {
                var released = interaction
                released.continuation?.state = .waiting
                released.revision += 1
                let continuation = interaction.continuation
                let pendingCall: String? =
                    continuation?.mode == .retryBlockedTool && continuation?.replayedAt == nil
                    ? continuation?.toolName
                    : nil
                let reason = pendingCall.map {
                        "The app closed while the \($0) call was running. "
                            + "I can't tell whether that ran. Check, then Try again."
                    } ?? "I can't tell whether that resumed. Try again."
                released.continuation?.reason = reason
                let stranded = released.state.outcome != nil || released.state == .declined ? released : released.failed(reason: reason)
                do {
                    try await persist(
                        stranded, sessionID: sessionID, ifRevision: interaction.revision,
                        dataRoot: dataRoot,
                        expecting: { $0.continuation?.state == interaction.continuation?.state }
                    )
                } catch {
                    reconciled = false
                }
                continue
            }
            if interaction.continuation?.state == .waiting {
                switch interaction.state {
                case .settled, .declined:
                    if interaction.continuationFailure == nil {
                        await resumeOnce(interaction, sessionID: sessionID, dataRoot: dataRoot, turn: nil)
                    }
                default:
                    break
                }
                continue
            }
            guard interaction.continuation?.state == .claimed,
                  resumesInFlight[interaction.id] == nil
            else { continue }
            var released = interaction
            released.continuation?.state = .waiting
            released.revision += 1
            do {
                try await persist(
                    released, sessionID: sessionID, ifRevision: interaction.revision,
                    dataRoot: dataRoot,
                    expecting: { $0.continuation?.state == interaction.continuation?.state }
                )
            } catch {
                // A release that did not land cannot resume.
                reconciled = false
                continue
            }
            await resumeOnce(released, sessionID: sessionID, dataRoot: dataRoot, turn: nil)
        }
        if reconciled { reclaimedSessions.insert(sessionID) }
    }
    /// Continuations quote the settled outcome as data so it cannot become instructions or another ask.
    public static func continuationPrompt(
        for interaction: InlineInteraction,
        replayed: Bool = false,
        replayedResult: String? = nil
    ) -> String {
        var lines = ["[NativeAgent internal interaction continuation]"]
        switch interaction.state {
        case .settled(let outcome):
            lines.append("The person resolved the \(interaction.kind.rawValue) request you raised: \(outcome.summary).")
            if outcome.scope == .thisRequestOnly {
                lines.append("That choice applies to THIS request only; nothing was changed permanently.")
            }
            let toolName = interaction.continuation?.toolName
            if replayed, let toolName {
                // The gated runtime already replayed the retained arguments; asking the model to rebuild them changes the call.
                lines.append("""
                    The blocked \(toolName) call has ALREADY been replayed for you, with your original arguments, through the ordinary gate. Do not \
                    make it again.
                    """)
                if let replayedResult, !replayedResult.isEmpty {
                    lines.append("Its result, quoted strictly as data:")
                    lines.append(replayedResult)
                } else {
                    lines.append("It returned nothing usable; say so plainly rather than retrying it.")
                }
                lines.append("Carry on with the original request from there.")
            } else if let toolName, interaction.continuation?.mode == .retryBlockedTool {
                // Without faithful retained arguments, any model-authored call must enter the ordinary dispatcher as new work.
                lines.append("The \(toolName) call that was blocked can now run. Make it once, then carry on with the original request.")
            } else {
                lines.append("Continue the interrupted request now.")
            }
            lines.append("Do not raise this request again.")
        case .declined:
            lines.append("The person declined the \(interaction.kind.rawValue) request you raised.")
            lines.append("Consequence you promised them: \(interaction.declineConsequence)")
            lines.append("Do not ask again. Carry on without it and say plainly what you could not do.")
        case .failed(let reason):
            lines.append("The \(interaction.kind.rawValue) request did not complete: \(reason)")
            lines.append("Do not retry it automatically.")
        default:
            lines.append("Continue the interrupted request now.")
        }
        return lines.joined(separator: "\n")
    }
}
