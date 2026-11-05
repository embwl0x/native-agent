import AuthoredCapabilities
import Experiences
import Foundation
import NotificationInbox
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
import Privacy
// Blueprint: | `InlineInteractionResolver.swift` | Transcript CAS owns answers; asks are matters born with origin doors and verified answers settle decide |
/// Settle from the canonical owner's verification, never from a tap or transcript assertion. Setup grants no approval bypass: every continuation still passes
/// ordinary effect gates.
@MainActor
public enum InlineInteractionResolver {
    public static var platform: (any InlineInteractionPlatformPort)!

    /// The transcript supplies provenance; the record fixes its doors at birth, including the person's conversation mirror.
    @discardableResult
    static func fileMatter(_ card: InlineInteraction, sessionID: String, dataRoot: URL) async throws -> ForPerson.Filed {
        guard !card.state.isUnknown,
              InlineCards.model(card, descriptor: descriptor(for: card, dataRoot: dataRoot)).needsAttention else { return .unchanged }
        let origin = try await originEnvelope(of: card.id, sessionID: sessionID, dataRoot: dataRoot)
        let thread: Door?
        if let route = origin?.replyRoute, route.surface == "telegram" || route.surface == "slack" {
            guard let destination = route.destinationId, !destination.isEmpty else {
                throw ToolFailureError("The request has no origin destination; repair its transcript route.", effects: .none, owner: "interaction")
            }
            thread = route.surface == "telegram" ? .telegram(chat: destination, thread: route.threadId)
                : .slack(channel: destination, thread: route.threadId)
        } else { thread = nil }
        var doors = Door.person(thread: thread)
        if let anchor = try ApprovalChatCards.usersConversation(unless: sessionID, dataRoot: dataRoot) {
            doors.append(.conversation(anchor))
        }
        let choices: [PartFace.Action] = card.kind == .choose ? card.options.enumerated().map { index, option in
            .init(id: "interaction_choice_\(index)", label: NativeAppSecretRedactor.redactText(option.label))
        } : []
        let matter = Matter(id: "interaction:" + card.id, form: .ask, from: InlineInteractionDelivery.source,
            title: NativeAppSecretRedactor.redactText(card.title), summary: NativeAppSecretRedactor.redactText(card.why),
            symbol: "hand.raised.fill", badge: "REQUEST", open: "card:" + card.id,
            choices: choices + [.init(id: "act", label: "Open request"), .init(id: "reject", label: "Not now", role: .destructive)],
            evidence: [.init(source: Matter.messages(sessionID), id: card.id)])
        return try await ForPerson.at(dataRoot).tell(matter, doors: doors)
    }
    /// Inject the scene-owned turn starter so every surface shares continuation policy. Only the first real question shows a user bubble; internal continuation
    /// markers stay hidden. Report actual admission so a refused turn cannot strand a durable claim as resumed.
    public typealias TurnStarter = @MainActor (
        _ prompt: String, _ sessionID: String, _ hideUserBubble: Bool, _ turn: Turn
    ) async -> Bool
    public static var startTurn: TurnStarter?
    /// Replay retained arguments through ordinary gates; reconstructing them would make a different call. Distinguish a dispatched call with no result from a
    /// call that never ran so only real work is checkpointed.
    public enum ReplayOutcome: Sendable {
        /// The call reached the gated dispatcher and came back. The payload is its serialized result, or nil when it serialized to nothing.
        case dispatched(String?)
        /// The call never ran. Nothing happened to the world.
        case failed(String)
    }
    /// Carry the raising row's envelope so replay retains its origin restrictions instead of gaining local authority.
    public typealias ToolReplayer = @MainActor (
        _ toolName: String, _ argumentsJSON: String, _ sessionID: String,
        _ turn: Turn
    ) async -> ReplayOutcome
    public static var replayBlockedTool: ToolReplayer?
    /// Process-local ownership distinguishes live claims from those stranded by a relaunch.
    static var resumesInFlight: [String: Task<JSONValue?, Never>] = [:]
    static var waitingHosts: Set<String> = []
    /// Fence the call-to-checkpoint window within this process; the durable row owns cross-launch authority.
    static var replayedResumeRunIds: Set<String> = []
    static var reclaimedSessions: Set<String> = []
    /// Retain continuation results until the running turn takes them; that turn owns continuation, without starting another.
    static var handBacks: [String: String] = [:]
    public static func takeContinuationHandBack(id: String) -> String? {
        handBacks.removeValue(forKey: id)
    }
    public typealias ResolveError = SwiftNativeChatOrchestrationClient.InlineInteractionResolveError
    /// Only a missing transcript means no rows; report read failures once per session to preserve cards without log flooding.
    private static var loggedReadFailures: Set<String> = []
    static func checkedRows(_ sessionID: String, _ dataRoot: URL) async throws -> (rows: [JSONValue], lifeID: String) {
        do {
            let lifeID = try DataRootLife.current(in: dataRoot)
            let rows = try await SwiftNativePersistenceCore.readJSONL(path(sessionID, dataRoot))
            loggedReadFailures.remove(sessionID)
            return (rows, lifeID)
        } catch {
            if loggedReadFailures.insert(sessionID).inserted {
                nativeLog("[interaction] transcript read failed for \(sessionID): \(error)")
            }
            throw error
        }
    }
    public static func interaction(
        id: String,
        sessionID: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws -> InlineInteraction? {
        let read = try await checkedRows(sessionID, dataRoot)
        for row in read.rows {
            guard case .object(let object) = row,
                  case .object(let metadata)? = object["metadata"],
                  metadata["kind"] == .string(InlineInteractionWire.transcriptKind),
                  case .object(let raw)? = metadata[InlineInteractionWire.metadataKey],
                  raw["id"] == .string(id) else { continue }
            return try SwiftNativeChatOrchestrationClient.checkedInlineInteraction(in: row, lifeID: read.lifeID)
        }
        return nil
    }
    /// Read each card with its owning row in one checked snapshot so rendering preserves placement and surfaces failures.
    public static func checkedInteractionsByRow(
        sessionID: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> Result<[(rowID: String, interaction: InlineInteraction)], any Error> {
        do {
            let read = try await checkedRows(sessionID, dataRoot)
            return .success(interactionsByRow(in: read.rows, lifeID: read.lifeID))
        } catch {
            return .failure(error)
        }
    }
    public nonisolated static func interactionsByRow(
        in rows: [JSONValue], lifeID: String? = nil
    ) -> [(rowID: String, interaction: InlineInteraction)] {
        return rows.compactMap { row in
            guard case .object(let object) = row,
                  case .string(let rowID)? = object["id"]
            else { return nil }
            do {
                guard let interaction = try SwiftNativeChatOrchestrationClient.checkedInlineInteraction(in: row, lifeID: lifeID)
                else { return nil }
                return (rowID, interaction)
            } catch {
                // Display-only unavailable evidence, never an executable card or a replacement written over the damaged source.
                return (rowID, unavailableInteraction(rowID: rowID, error: error))
            }
        }
    }
    public nonisolated static func unavailableInteraction(rowID: String, error: any Error) -> InlineInteraction {
        InlineInteraction(id: "unavailable:" + rowID,
            kind: .unknown, target: "", title: "Saved request unavailable",
            why: TurnSecretRedactor.redactText(error.localizedDescription),
            primaryActionLabel: "", declineConsequence: "",
            state: .unknown("unavailable"), createdAt: .distantPast)
    }
    public static func descriptor(
        for interaction: InlineInteraction,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> InlineInteractionDescriptor {
        InlineInteractionRegistry.descriptor(
            kind: interaction.kind,
            target: interaction.target,
            // The descriptor must show the entire chain its tap grants.
            additionalTargets: interaction.additionalTargets,
            dataRoot: dataRoot
        )
    }
    public static func waitForAnswer(_ interaction: InlineInteraction, tool: String, input: [String: JSONValue],
                                     sessionID: String, dataRoot: URL, turn: Turn,
                                     invocation: ChatToolInvocation, deadlines: OperationDeadlines) async -> JSONValue {
        waitingHosts.insert(interaction.id)
        let result: JSONValue
        do {
            result = try await waitForAnswerBody(interaction, tool: tool, input: input,
                                                sessionID: sessionID, dataRoot: dataRoot, turn: turn,
                                                invocation: invocation, deadlines: deadlines)
        } catch {
            result = .object(["status": .string("failed"), "reason": .string("card_unavailable"),
                "detail": .string(TurnSecretRedactor.redactText(error.localizedDescription))])
        }
        await settle { @MainActor in _ = waitingHosts.remove(interaction.id) }
        return result
    }
    private static func waitForAnswerBody(
        _ interaction: InlineInteraction, tool: String, input: [String: JSONValue], sessionID: String, dataRoot: URL, turn: Turn,
        invocation: ChatToolInvocation, deadlines: OperationDeadlines
    ) async throws -> JSONValue {
        let changes = NotificationCenter.default.notifications(named: InlineInteractionWire.changedNotification)
            .compactMap { $0.object as? String }
        var card = interaction
        // Titled once, when first raised: an outer layer seeing the same card keeps its title.
        if let requester = turn.requester,
           try await Self.interaction(id: interaction.id, sessionID: sessionID, dataRoot: dataRoot) == nil {
            card.title = "\(requester) wants to ask: \(card.title)"
        }
        let blocked = InlineInteractionNeed.blocksTurn(interaction)
            && ToolNameAliases.ranTool(tool, input: input) != InlineInteractionWire.toolName
        let arguments = try? JSONValue.object(input).serialize(pretty: false)
        guard !blocked || arguments.map({
            SwiftNativeChatOrchestrationClient.redactedPersistedToolInput(tool: tool, json: $0, turn: turn) == $0
        }) == true else {
            return .object(["status": .string("failed"), "reason": .string("invalid_args"), "effects": .string("none"),
                "detail": .string("""
                    This card holds the turn and replays the call once answered, and the call's arguments would not be saved whole: they carry a \
                    secret or run past 4,000 characters. Nothing was asked; call again with no secret in the arguments and under that length.
                    """)])
        }
        guard let raised = await raise(card, sessionID: sessionID, resumable: InlineInteractionNeed.blocksTurn(interaction),
            toolName: blocked ? tool : nil, toolArgumentsJSON: blocked ? arguments : nil,
            toolCallId: blocked ? UUID().uuidString : nil,
            requestingTool: tool,
            origin: TurnEnvelope.current(turn: turn, surface: turn.envelope?.surface ?? "chat"), turn: turn, dataRoot: dataRoot) else {
            return .object(["status": .string("failed"), "reason": .string("card_unavailable"),
                "detail": .string("The card could not be saved; nothing was answered.")])
        }
        // The existing ask retains its continuation. A re-ask returns its pointer instead of adding a second host waiting to replay work.
        if raised.id != card.id || !InlineInteractionNeed.blocksTurn(raised) {
            return InlineInteractionNeed.envelope(invocation: invocation, raised)
        }
        func answer() async throws -> InlineInteraction? {
            guard let current = try await Self.interaction(id: raised.id, sessionID: sessionID, dataRoot: dataRoot),
                  current.state.isTerminal, current.state.failureReason == nil else { return nil }
            return current
        }
        let current: InlineInteraction? = try await deadlines.withHumanWait {
            if let result = try await answer() { return result }
            for await changed in changes where changed == sessionID {
                if let result = try await answer() { return result }
            }
            return InlineInteraction?.none
        }
        guard let current, !Task.isCancelled else {
            await invalidateContinuation(id: raised.id, sessionID: sessionID, dataRoot: dataRoot)
            return .object(["status": .string("failed"), "reason": .string("cancelled"),
                "detail": .string("The turn stopped while waiting for the card.")])
        }
        if blocked, current.state.outcome != nil {
            return await resumeUnderPeerProvenance(current, sessionID: sessionID, dataRoot: dataRoot, turn: turn)
                ?? .object(["status": .string("failed"), "reason": .string("continuation_refused"),
                    "detail": .string("The blocked call could not resume; check its card before continuing.")])
        }
        await invalidateContinuation(id: raised.id, sessionID: sessionID, dataRoot: dataRoot)
        guard case .object(var receipt) = receiptEnvelope(current) else { return receiptEnvelope(current) }
        if case .declined = current.state { receipt["reason"] = .string("declined"); receipt["effects"] = .string("none") }
        if let choice = current.state.outcome?.selection { receipt["answer"] = .string(choice) }
        return .object(receipt)
    }
    /// Permission-remedy asks use the same locked transcript filing boundary. A different conversation or access axis is a different ask.
    public static func filePermissionRequest(_ need: InlineInteraction, sessionID: String,
        origin: TurnEnvelope, turn: Turn, dataRoot: URL) async throws -> (id: String, sessionID: String) {
        // Continue after Allow without capturing the failed call, whose effects may already be unknown.
        guard let raised = await raise(need, sessionID: sessionID, requestingTool: "permissions.request",
                                      origin: origin, turn: turn, dataRoot: dataRoot) else {
            throw NSError(domain: "PermissionCard", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The permission card could not be saved; no card is up."])
        }
        return (raised.id, sessionID)
    }

    /// Persist a card outside a tool-receipt write, using `Continuation`'s input contract. The producer supplies the origin stamped into both the continuation
    /// witness and row. Nonresumable inputs, including attachments whose bytes are not retained, are invalidated in the same atomic write.
    @discardableResult
    public static func raise(
        _ interaction: InlineInteraction,
        sessionID: String,
        resumeText: String? = nil,
        resumable: Bool = true,
        toolName: String? = nil,
        toolArgumentsJSON: String? = nil,
        toolCallId: String? = nil,
        requestingTool: String? = nil,
        origin: TurnEnvelope,
        turn: Turn,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> InlineInteraction? {
        let stamped: InlineInteraction
        do {
            stamped = try await SwiftNativeChatOrchestrationClient.fileInlineInteraction(
                interaction, sessionID: sessionID, resumeText: resumeText, resumable: resumable,
                toolName: toolName, toolArgumentsJSON: toolArgumentsJSON, toolCallId: toolCallId,
                requestingTool: requestingTool, origin: origin, dataRoot: dataRoot, turn: turn)
        } catch {
            nativeLog("[interaction] raise failed for \(interaction.id): \(error)")
            return nil
        }
        do { try await fileMatter(stamped, sessionID: sessionID, dataRoot: dataRoot) }
        catch { nativeLog("[interaction] matter filing failed for \(stamped.id): \(error)") }
        await ApprovalChatCards.publishInteractionChange(id: stamped.id, sessionID: sessionID, dataRoot: dataRoot)
        NotificationCenter.default.post(name: InlineInteractionWire.changedNotification, object: sessionID)
        NotificationCenter.default.post(name: .chatTurnCompleted, object: sessionID)
        return stamped
    }
    /// The card's primary action was tapped and the existing control is being opened. Marks the row `running` so a second tap — or the phone — sees that
    /// this is already in flight.
    @discardableResult
    public static func begin(
        id: String,
        sessionID: String,
        expectedRevision: Int? = nil,
        byAgent: Bool = false,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws -> InlineInteraction {
        try await refuseAgentOnUsersCard(id, byAgent: byAgent, dataRoot: dataRoot)
        var current = try await require(id: id, sessionID: sessionID, dataRoot: dataRoot)
        try checkRevision(current, expectedRevision)
        if current.continuation?.state == .stopped {
            guard !byAgent else { throw ResolveError.alreadySettled("stopped") }
            let previous = current.continuation
            current.continuation = .init(mode: .continueTurn, resumeRunId: UUID().uuidString,
                resumeText: previous?.resumeText, peerSources: previous?.peerSources,
                elevatedPeerSources: previous?.elevatedPeerSources)
            current.continuation?.originTurnId = previous?.originTurnId
            current.continuation?.originRunId = previous?.originRunId
            current.continuation?.lifeID = try DataRootLife.current(in: dataRoot)
        }
        // Failed cards remain answerable; running controls refuse another tap to prevent duplicate mutations.
        switch current.state {
        case .pending, .failed, .stopped:
            break
        default:
            throw ResolveError.alreadySettled(current.state.name)
        }
        let descriptor = descriptor(for: current, dataRoot: dataRoot)
        guard descriptor.isActionable else {
            throw ResolveError.noControl(
                descriptor.unavailableReason ?? "No control for \(current.target)."
            )
        }
        // Same-life retries keep admission and landed replay; a new life starts fresh.
        let running = current.running()
        try await persist(
            running, sessionID: sessionID, ifRevision: current.revision, dataRoot: dataRoot
        )
        return running
    }
    /// Verify completion with the owner before continuing; scope determines whether a model choice persists. Retain non-tap attribution so agent-made answers
    /// cannot look like the person's tap. Preserve the owner's refusal and verification note on the shared receipt.
    @discardableResult
    public static func complete(
        id: String,
        sessionID: String,
        selection: String? = nil,
        scope: InlineInteraction.Scope? = nil,
        expectedRevision: Int? = nil,
        attribution: String? = nil,
        setupError: String? = nil,
        note: String? = nil,
        byAgent: Bool = false,
        turn: Turn?,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws -> InlineInteraction {
        try await refuseAgentOnUsersCard(id, byAgent: byAgent, dataRoot: dataRoot)
        let current = try await require(id: id, sessionID: sessionID, dataRoot: dataRoot)
        try checkRevision(current, expectedRevision)
        guard current.state.isOpen else {
            throw ResolveError.alreadySettled(current.state.name)
        }
        var verification: Verification
        if let setupError {
            verification = .failure(setupError)
        } else {
            verification = await verify(
                current, selection: selection, scope: scope, dataRoot: dataRoot
            )
        }
        if case .success(var outcome) = verification, let note, !note.isEmpty {
            outcome.summary += " \u{00B7} \(note)"
            verification = .success(outcome)
        }
        return try await finish(current, verification: verification, sessionID: sessionID,
                                attribution: attribution, turn: turn, dataRoot: dataRoot)
    }
    static func finish(
        _ current: InlineInteraction, verification: Verification, sessionID: String,
        attribution: String? = nil, turn: Turn?, dataRoot: URL
    ) async throws -> InlineInteraction {
        switch verification {
        case .failure(let reason):
            // An unverified card stays answerable and cannot claim connection.
            let failed = current.failed(reason: String(TurnSecretRedactor.redactText(reason).prefix(1_000)))
            try await persist(
                failed, sessionID: sessionID, ifRevision: current.revision, dataRoot: dataRoot
            )
            // Automatic continuation after failure would raise the same card repeatedly.
            return failed
        case .success(let outcome):
            var stamped = outcome
            if let attribution = attribution?.trimmingCharacters(in: .whitespacesAndNewlines),
               !attribution.isEmpty {
                stamped.summary = stamped.summary.isEmpty
                    ? attribution
                    : "\(stamped.summary) \u{2014} \(attribution)"
            }
            let settled = current.settled(stamped)
            try await persist(
                settled, sessionID: sessionID, ifRevision: current.revision, dataRoot: dataRoot
            )
            try await settleMatter(settled.id, evidence: .init(source: Matter.messages(sessionID), id: settled.id), dataRoot: dataRoot)
            if [.permission, .capability].contains(settled.kind) {
                for target in settled.allTargets {
                    guard let id = SystemPermissionPreflight.grantTarget(target) else { continue }
                    // The grant settles the bare ask and the ask in the mode it granted.
                    let asks: [[String: JSONValue]] = [["capability": .string(id)]]
                        + (settled.mode.map { [["capability": .string(id), "mode": .string($0.rawValue)]] } ?? [])
                    for args in asks {
                        RepairOwed.settle(dataRoot, operation: AppActionBinding.repairOperation("permissions.request", args),
                                         evidence: .init(source: "interaction", id: settled.id))
                    }
                }
            }
            await resumeOnce(settled, sessionID: sessionID, dataRoot: dataRoot, turn: turn)
            return settled
        }
    }
    /// Decline resumes with the promised consequence so the request can act on refusal. Agent withdrawal retires continuation because the current turn already
    /// knows the outcome.
    @discardableResult
    public static func decline(
        id: String,
        sessionID: String,
        expectedRevision: Int? = nil,
        resume: Bool = true,
        turn: Turn?,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws -> InlineInteraction {
        let current = try await require(id: id, sessionID: sessionID, dataRoot: dataRoot)
        try checkRevision(current, expectedRevision)
        guard current.state.isOpen || current.state.isRetryable || current.continuation?.state == .stopped else {
            throw ResolveError.alreadySettled(current.state.name)
        }
        var declined = current.declined()
        if !resume || current.continuation?.state == .stopped { declined.continuation?.state = .invalidated }
        try await persist(
            declined, sessionID: sessionID, ifRevision: current.revision, dataRoot: dataRoot
        )
        try await settleMatter(declined.id, evidence: nil, reason: resume ? .cancelled : .expired, dataRoot: dataRoot)
        if resume { await resumeOnce(declined, sessionID: sessionID, dataRoot: dataRoot, turn: turn) }
        return declined
    }

    private static func settleMatter(_ id: String, evidence: Experience.Ref?, reason: ObligationPhase.LetGo = .abandoned,
                                     dataRoot: URL) async throws {
        let result: Result<Void, Error> = await settle {
            do {
                try await ForPerson.at(dataRoot).answered("interaction:" + id, evidence: evidence, letGo: reason)
                return .success(())
            } catch { return .failure(error) }
        }
        try result.get()
    }
    /// A mirror in the person's conversation is theirs under every posture; agent decline remains allowed.
    private static func refuseAgentOnUsersCard(_ id: String, byAgent: Bool, dataRoot: URL) async throws {
        guard byAgent, try await ApprovalChatCards.isMirroredToUser(id, dataRoot: dataRoot) else { return }
        throw ResolveError.usersCard
    }
    /// Restore answerability when authority changes during begin I/O so an unperformed action cannot leave the card running.
    @discardableResult
    public static func returnToPending(
        _ interaction: InlineInteraction,
        sessionID: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws -> InlineInteraction {
        var reverted = interaction
        reverted.state = .pending
        reverted.revision += 1
        reverted.waitingOn = nil
        // Undo only this caller's exact running revision so stale state cannot resurrect a moved card.
        try await persist(
            reverted, sessionID: sessionID, dataRoot: dataRoot,
            expecting: { current in
                guard case .running = current.state else { return false }
                return current.revision == interaction.revision
            }
        )
        return reverted
    }
    /// Dismissal, Stop, or a cleared conversation: the card stops being a thing that can restart a turn. It stays in scrollback as a record.
    public static func invalidateContinuation(
        id: String,
        sessionID: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async {
        if let owner = resumesInFlight[id] {
            owner.cancel()
            await settle { _ = await owner.value }
            return
        }
        // Reserve ownership before the read: a resume cannot acquire the same waiting row while its dismissal is suspended on storage.
        let owner = Task<JSONValue?, Never> {
            await settle { @MainActor in
                defer { resumesInFlight[id] = nil }
                let found: InlineInteraction?
                do { found = try await interaction(id: id, sessionID: sessionID, dataRoot: dataRoot) }
                catch {
                    RepairOwed.owe(dataRoot, id: "interaction-stop-\(id)", kind: .act,
                        operation: "interaction.stop", owner: "transcript", words: error.localizedDescription)
                    return nil
                }
                guard var current = found,
                      let state = current.continuation?.state,
                      state != .resumed, state != .invalidated else { return nil }
                let revision = current.revision
                current.continuation?.state = .invalidated
                current.revision += 1
                do {
                    try await persist(current, sessionID: sessionID, dataRoot: dataRoot, expecting: {
                        $0.revision == revision && $0.continuation?.state == state
                    })
                } catch { nativeLog("[interaction] stop settlement failed for \(id): \(error)") }
                return nil
            }
        }
        resumesInFlight[id] = owner
        await settle { _ = await owner.value }
    }
}
