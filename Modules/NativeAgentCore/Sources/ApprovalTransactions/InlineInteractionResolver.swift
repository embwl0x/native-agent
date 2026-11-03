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
// Blueprint: | `InlineInteractionResolver.swift` | Control/continuation resolution uses the chat owner's transcript CAS and stopped projection; all filing reuses an open ask under the transcript lock by conversation, tool and subject, preserving its continuation; same-life stranded claims alone may reclaim/replay. The person's Resume replaces stopped continuations with fresh work without captured blocked calls. Existing setup admission, Stop settlement and slot ownership remain canonical |
/// The one place an inline card settles and the one place a suspended request
/// resumes.
///
/// The shape is deliberately the same as the approval executor's: find the row
/// by a durable identifier, replace it in place so the card BECOMES the
/// receipt, and continue the conversation once. The differences are the two
/// that matter:
///
///  * **It verifies with the owner, never with the card.** A tap on "Connect
///    Slack" does not settle anything. Connectors is asked whether Slack is
///    connected; Trust is re-read for a grant; the routing snapshot is asked
///    which model a group now runs. The transcript holds interaction state, it
///    holds no authority, and a transcript that says "connected" over a store
///    that says otherwise loses.
///
///  * **It does NOT reuse the approval bypass.** Approval replay installs a
///    single-tool autonomy resolver on purpose; this must not. Connecting an
///    account is not permission to send from it. Everything after a settled
///    card goes through the ordinary gate, so an action that needed approval
///    before setup still needs approval after it — including under Full Mac
///    and YOLO, where the flows that need a PERSON (OAuth, API keys, the OS
///    permission prompts) still need that person.
@MainActor
public enum InlineInteractionResolver {
    public static var platform: (any InlineInteractionPlatformPort)!
    /// How a resumed request re-enters the app.
    ///
    /// Injected at launch rather than reached through a singleton, because
    /// there isn't one: `AppModel` is constructed once by the scene and owned
    /// by it. Keeping the seam explicit also means the resolver is callable
    /// from anywhere a card can be resolved — the chat view, and later the
    /// phone's signed action route — without either of them owning the
    /// continuation policy.
    /// `hideUserBubble` is false only when the resumed text IS the person's
    /// own question being asked for real for the first time — the no-provider
    /// card, whose original user row was deliberately never persisted. Every
    /// internal continuation marker stays hidden.
    ///
    /// It returns whether the turn was ACTUALLY ADMITTED. A starter that
    /// swallows its own rejection lets the durable `.claimed` write stand over
    /// a turn that never ran, and the card is then stranded forever: it reads
    /// as resumed, and nothing — not a second tap, not a relaunch — can start
    /// the request it was supposed to unblock.
    public typealias TurnStarter = @MainActor (
        _ prompt: String, _ sessionID: String, _ hideUserBubble: Bool
    ) async -> Bool
    public static var startTurn: TurnStarter?
    /// Replays ONE blocked call through the ordinary gated dispatcher.
    ///
    /// The point is that the model is never asked to reconstruct the arguments
    /// it wrote before the card interrupted it. The runtime kept them; the
    /// runtime replays them. Injected rather than reached for, for the same
    /// reason as `startTurn`, and deliberately NOT given any autonomy bypass:
    /// a call that needed approval before setup still needs it after.
    /// The answer is TYPED, because "nil" conflated two opposite facts: a call
    /// that ran and returned nothing, and a call that never ran at all. Only
    /// the first may be recorded as replayed — recording the second would
    /// strand the request with a call nobody ever made.
    public enum ReplayOutcome: Sendable {
        /// The call reached the gated dispatcher and came back. The payload is
        /// its serialized result, or nil when it serialized to nothing.
        case dispatched(String?)
        /// The call never ran. Nothing happened to the world.
        case failed(String)
    }
    ///
    /// `origin` is the envelope of the turn that RAISED the card, read back off
    /// the same transcript row. Without it a replay ran as a trusted local Mac
    /// call whatever it came from: a card raised on the phone with
    /// `remote_from_ios_allowed` false, or from a Telegram chat that is not on
    /// the allowlist, resolved into a call the gate would have refused at
    /// origin. The origin surface is the one that has to answer for the call.
    public typealias ToolReplayer = @MainActor (
        _ toolName: String, _ argumentsJSON: String, _ sessionID: String,
        _ origin: TurnEnvelope?
    ) async -> ReplayOutcome
    public static var replayBlockedTool: ToolReplayer?
    /// Interactions whose resume is in flight in THIS process. A relaunch has
    /// none, which is what makes a leftover `.claimed` on disk provably
    /// stranded rather than possibly live.
    static var resumesInFlight: [String: Task<JSONValue?, Never>] = [:]
    static var waitingHosts: Set<String> = []
    /// Continuations whose blocked call this PROCESS has already replayed,
    /// keyed on `resumeRunId`. The durable checkpoint on the row is the
    /// authority across launches; this is what makes the window between the
    /// call and that write non-repeatable within one launch.
    static var replayedResumeRunIds: Set<String> = []
    static var reclaimedSessions: Set<String> = []
    /// What a card's continuation handed back to the turn that settled it,
    /// keyed by interaction id, until that turn's own tool call takes it.
    static var handBacks: [String: String] = [:]
    /// The continuation this resolve handed back to the turn that is running
    /// RIGHT NOW, if the card was settled from inside one. Non-nil means no
    /// second turn was started and none will be: the caller's own turn is the
    /// continuation, and this is what it carries on from.
    public static func takeContinuationHandBack(id: String) -> String? {
        handBacks.removeValue(forKey: id)
    }
    public typealias ResolveError = SwiftNativeChatOrchestrationClient.InlineInteractionResolveError
    /// The transcript read, with its failure VISIBLE.
    ///
    /// A missing file is not a failure — it reads as no rows. A read that
    /// actually failed is: swallowing it into an empty array made every card in
    /// the conversation vanish with no error anywhere, which reads to the
    /// person as "the app forgot what I asked for". The error is logged once
    /// per session so a repeating refresh cannot flood the log.
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
    /// Every interaction in a session PAIRED WITH THE TRANSCRIPT ROW it was
    /// raised on. The card belongs under that row and nowhere else, so the
    /// renderer needs the row identity the reader is scrolling past — not just
    /// the interaction. One checked transcript read supplies both.
    /// The checked form: a read failure is returned, not flattened to "no
    /// cards", so the renderer can keep the last good projection on screen.
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
                // Display-only unavailable evidence, never an executable card
                // or a replacement written over the damaged source.
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
    /// The descriptor the card renders from: display name, which control
    /// opens, and whether it can be completed on this device at all.
    public static func descriptor(
        for interaction: InlineInteraction,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> InlineInteractionDescriptor {
        InlineInteractionRegistry.descriptor(
            kind: interaction.kind,
            target: interaction.target,
            // The whole chain, because the whole chain is what a tap grants.
            additionalTargets: interaction.additionalTargets,
            dataRoot: dataRoot
        )
    }
    /// The same card, with its answer returned to the part already running.
    public static func waitForAnswer(_ interaction: InlineInteraction, tool: String, input: [String: JSONValue],
                                     sessionID: String, dataRoot: URL) async -> JSONValue {
        waitingHosts.insert(interaction.id)
        let result: JSONValue
        do {
            result = try await waitForAnswerBody(interaction, tool: tool, input: input,
                                                sessionID: sessionID, dataRoot: dataRoot)
        } catch {
            result = .object(["status": .string("failed"), "reason": .string("card_unavailable"),
                "detail": .string(TurnSecretRedactor.redactText(error.localizedDescription))])
        }
        await settle { @MainActor in _ = waitingHosts.remove(interaction.id) }
        return result
    }
    private static func waitForAnswerBody(
        _ interaction: InlineInteraction, tool: String, input: [String: JSONValue], sessionID: String, dataRoot: URL
    ) async throws -> JSONValue {
        let changes = NotificationCenter.default.notifications(named: InlineInteractionWire.changedNotification)
            .compactMap { $0.object as? String }
        var card = interaction
        // Titled once, when first raised: an outer layer seeing the same card keeps its title.
        if let requester = SkillRunContext.requester,
           try await Self.interaction(id: interaction.id, sessionID: sessionID, dataRoot: dataRoot) == nil {
            card.title = "\(requester) wants to ask: \(card.title)"
        }
        let blocked = InlineInteractionNeed.blocksTurn(interaction)
            && ToolNameAliases.ranTool(tool, input: input) != InlineInteractionWire.toolName
        let arguments = try? JSONValue.object(input).serialize(pretty: false)
        guard !blocked || arguments.map({
            SwiftNativeChatOrchestrationClient.redactedPersistedToolInput(tool: tool, json: $0) == $0
        }) == true else {
            return .object(["status": .string("failed"), "reason": .string("invalid_args"), "effects": .string("none"),
                "detail": .string("This card holds the turn and replays the call once answered, and the call's arguments would not be saved whole: they carry a secret or run past 4,000 characters. Nothing was asked; call again with no secret in the arguments and under that length.")])
        }
        guard let raised = await raise(card, sessionID: sessionID, resumable: InlineInteractionNeed.blocksTurn(interaction),
            toolName: blocked ? tool : nil, toolArgumentsJSON: blocked ? arguments : nil,
            toolCallId: blocked ? UUID().uuidString : nil,
            requestingTool: tool,
            origin: TurnEnvelope.current(surface: ChatToolSessionContext.envelope?.surface ?? "chat"), dataRoot: dataRoot) else {
            return .object(["status": .string("failed"), "reason": .string("card_unavailable"),
                "detail": .string("The card could not be saved; nothing was answered.")])
        }
        // The existing ask retains its continuation. A re-ask returns its
        // pointer instead of adding a second host waiting to replay work.
        if raised.id != card.id || !InlineInteractionNeed.blocksTurn(raised) {
            return InlineInteractionNeed.envelope(raised)
        }
        func answer() async throws -> InlineInteraction? {
            guard let current = try await Self.interaction(id: raised.id, sessionID: sessionID, dataRoot: dataRoot),
                  current.state.isTerminal, current.state.failureReason == nil else { return nil }
            return current
        }
        let current: InlineInteraction? = try await TurnDeadline.withHumanWait {
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
            return await resumeUnderPeerProvenance(current, sessionID: sessionID, dataRoot: dataRoot)
                ?? .object(["status": .string("failed"), "reason": .string("continuation_refused"),
                    "detail": .string("The blocked call could not resume; check its card before continuing.")])
        }
        await invalidateContinuation(id: raised.id, sessionID: sessionID, dataRoot: dataRoot)
        guard case .object(var receipt) = receiptEnvelope(current) else { return receiptEnvelope(current) }
        if case .declined = current.state { receipt["reason"] = .string("declined"); receipt["effects"] = .string("none") }
        if let choice = current.state.outcome?.selection { receipt["answer"] = .string(choice) }
        return .object(receipt)
    }
    /// Permission-remedy asks use the same locked transcript filing boundary.
    /// A different conversation or access axis is a different ask.
    public static func filePermissionRequest(_ need: InlineInteraction, sessionID: String,
        origin: TurnEnvelope, dataRoot: URL) async throws -> (id: String, sessionID: String) {
        // Continue after Allow without capturing the failed call, whose
        // effects may already be unknown.
        guard let raised = await raise(need, sessionID: sessionID, requestingTool: "permissions.request",
                                      origin: origin, dataRoot: dataRoot) else {
            throw NSError(domain: "PermissionCard", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The permission card could not be saved; no card is up."])
        }
        return (raised.id, sessionID)
    }

    /// Persist a card outside a tool-receipt write, using `Continuation`'s input contract.
    /// The producer supplies the origin stamped into both the continuation witness and row.
    /// Nonresumable inputs, including attachments whose bytes are not retained,
    /// are invalidated in the same atomic write.
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
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> InlineInteraction? {
        let stamped: InlineInteraction
        do {
            stamped = try await SwiftNativeChatOrchestrationClient.fileInlineInteraction(
                interaction, sessionID: sessionID, resumeText: resumeText, resumable: resumable,
                toolName: toolName, toolArgumentsJSON: toolArgumentsJSON, toolCallId: toolCallId,
                requestingTool: requestingTool, origin: origin, dataRoot: dataRoot)
        } catch {
            nativeLog("[interaction] raise failed for \(interaction.id): \(error)")
            return nil
        }
        await ApprovalChatCards.publishInteractionChange(id: stamped.id, sessionID: sessionID, dataRoot: dataRoot)
        NotificationCenter.default.post(name: InlineInteractionWire.changedNotification, object: sessionID)
        NotificationCenter.default.post(name: .chatTurnCompleted, object: sessionID)
        return stamped
    }
    /// The card's primary action was tapped and the existing control is being
    /// opened. Marks the row `running` so a second tap — or the phone — sees
    /// that this is already in flight.
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
            current.continuation?.lifeID = try DataRootLife.current(in: dataRoot)
        }
        // `failed` is retryable BY DESIGN: the card keeps its control and its
        // "Try again", and a failure settled nothing. Treating it as closed
        // here is what made that button a silent no-op.
        //
        // `running` is NOT. It used to be admitted because it is `isOpen`, so
        // a second `interaction_act` arriving while the first was still
        // validating a token began the same card again and ran the mutation
        // twice. A control is already open on a running card; the second
        // caller is told so, and the revision this call acquired is what the
        // settle is compared against.
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
    /// The control closed. Ask the OWNER whether the thing is actually done;
    /// settle on the answer, and only then continue the request.
    ///
    /// `selection` is the option/model the person picked, where the kind has
    /// one. `scope` decides whether a model choice binds to this request only
    /// or is written through Providers.
    ///
    /// `attribution` is WHO settled it, when that was not a hand on the
    /// trackpad. It lands on the settled card's own one-line receipt, which is
    /// what the chat card, the transcript row and every notification read — so
    /// an agent-made answer cannot be mistaken for a tap anywhere it shows.
    /// Nil for a tap, which needs no explaining.
    ///
    /// `setupError` is the owner's own refusal from the save the card just
    /// ran (a token the service rejected, a sign-in that did not finish): the
    /// card fails in those words instead of a generic "still isn't connected".
    /// `note` is how the owner checked it, added to the settled receipt.
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
                                attribution: attribution, dataRoot: dataRoot)
    }
    static func finish(
        _ current: InlineInteraction, verification: Verification, sessionID: String,
        attribution: String? = nil, dataRoot: URL
    ) async throws -> InlineInteraction {
        switch verification {
        case .failure(let reason):
            // Not verified is NOT settled. The card keeps its control, the
            // person can try again, and nothing anywhere reads as connected.
            let failed = current.failed(reason: String(TurnSecretRedactor.redactText(reason).prefix(1_000)))
            try await persist(
                failed, sessionID: sessionID, ifRevision: current.revision, dataRoot: dataRoot
            )
            // Deliberately no automatic retry and no automatic continuation:
            // a failure that resumes the turn by itself produces a second
            // identical card, and then a third.
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
            if [.permission, .capability].contains(settled.kind) {
                for target in settled.allTargets {
                    guard let capability = SystemPermissionPreflight.cardSettingsCapability(target) else { continue }
                    let id = AppleScriptExecution.automationTarget(target).map { "applescript:" + $0 } ?? capability.rawValue
                    // The grant settles the bare ask and the ask in the mode it granted.
                    let asks: [[String: JSONValue]] = [["capability": .string(id)]] + (settled.mode.map { [["capability": .string(id), "mode": .string($0.rawValue)]] } ?? [])
                    for args in asks {
                        RepairOwed.settle(dataRoot, operation: AppActionBinding.repairOperation("permissions.request", args),
                                         evidence: .init(source: "interaction", id: settled.id))
                    }
                }
            }
            await resumeOnce(settled, sessionID: sessionID, dataRoot: dataRoot)
            return settled
        }
    }
    /// "No." Settles as declined and resumes the request with the consequence
    /// the card promised, so Agent acts on the refusal rather than waiting
    /// forever or silently retrying the same wall.
    ///
    /// `resume: false` is Agent withdrawing her own card (the inbox tool): she
    /// already knows the outcome, so the continuation is retired with the
    /// card instead of re-running the request that raised it.
    @discardableResult
    public static func decline(
        id: String,
        sessionID: String,
        expectedRevision: Int? = nil,
        resume: Bool = true,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws -> InlineInteraction {
        let current = try await require(id: id, sessionID: sessionID, dataRoot: dataRoot)
        try checkRevision(current, expectedRevision)
        guard current.state.isOpen || current.continuation?.state == .stopped else {
            throw ResolveError.alreadySettled(current.state.name)
        }
        var declined = current.declined()
        if !resume || current.continuation?.state == .stopped { declined.continuation?.state = .invalidated }
        try await persist(
            declined, sessionID: sessionID, ifRevision: current.revision, dataRoot: dataRoot
        )
        if resume { await resumeOnce(declined, sessionID: sessionID, dataRoot: dataRoot) }
        return declined
    }
    /// The one gate on the agent answering: a card mirrored into User's
    /// conversation (`ApprovalChatCards`) is his under every posture, whether
    /// she reaches it by card.answer or by its inbox note. User's own taps (Mac,
    /// phone, Telegram owner) are not the agent and pass. Not now is `decline`,
    /// which stays hers.
    private static func refuseAgentOnUsersCard(_ id: String, byAgent: Bool, dataRoot: URL) async throws {
        guard byAgent, try await ApprovalChatCards.isMirroredToUser(id, dataRoot: dataRoot) else { return }
        throw ResolveError.usersCard
    }
    /// Undo a `begin` that must not carry through: the card goes back to
    /// answerable, exactly as it was before the agent touched it.
    ///
    /// The agent marks a card running BEFORE it acts, and that mark costs
    /// transcript I/O — long enough for the Trust posture behind an authority
    /// change to drop in another window. A refusal at that point must leave the
    /// card pending for the person, not `running` with nobody running it.
    @discardableResult
    public static func returnToPending(
        _ interaction: InlineInteraction,
        sessionID: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws -> InlineInteraction {
        var reverted = interaction
        reverted.state = .pending
        reverted.revision += 1
        // CAS, because this write is an UNDO: it is only correct over the
        // exact `running` row this caller's own `begin` wrote. A row that
        // moved in between — settled on the glass, reclaimed by a relaunch —
        // must not be dragged back to pending by a stale local copy, so the
        // loss is thrown and the caller reports the row that actually won.
        try await persist(
            reverted, sessionID: sessionID, dataRoot: dataRoot,
            expecting: { current in
                guard case .running = current.state else { return false }
                return current.revision == interaction.revision
            }
        )
        return reverted
    }
    /// Dismissal, Stop, or a cleared conversation: the card stops being a
    /// thing that can restart a turn. It stays in scrollback as a record.
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
        // Reserve ownership before the read: a resume cannot acquire the same
        // waiting row while its dismissal is suspended on storage.
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
