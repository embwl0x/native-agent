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
// Blueprint: | `InlineInteractionResolver.swift` | Control/continuation resolution uses the chat owner's transcript CAS and stopped projection; same-life stranded claims alone may reclaim/replay. The person's Resume replaces stopped continuations with fresh work without captured blocked calls. Existing setup admission, Stop settlement and slot ownership remain canonical |

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
    private static var resumesInFlight: [String: Task<JSONValue?, Never>] = [:]
    private static var waitingHosts: Set<String> = []
    /// Continuations whose blocked call this PROCESS has already replayed,
    /// keyed on `resumeRunId`. The durable checkpoint on the row is the
    /// authority across launches; this is what makes the window between the
    /// call and that write non-repeatable within one launch.
    private static var replayedResumeRunIds: Set<String> = []
    private static var reclaimedSessions: Set<String> = []
    /// What a card's continuation handed back to the turn that settled it,
    /// keyed by interaction id, until that turn's own tool call takes it.
    private static var handBacks: [String: String] = [:]

    /// The continuation this resolve handed back to the turn that is running
    /// RIGHT NOW, if the card was settled from inside one. Non-nil means no
    /// second turn was started and none will be: the caller's own turn is the
    /// continuation, and this is what it carries on from.
    public static func takeContinuationHandBack(id: String) -> String? {
        handBacks.removeValue(forKey: id)
    }

    // MARK: - Errors

    public typealias ResolveError = SwiftNativeChatOrchestrationClient.InlineInteractionResolveError

    // MARK: - Reading

    /// Every interaction row in a session, newest last. Reads the transcript
    /// and nothing else, so a relaunch rebuilds pending cards from disk.
    public static func interactions(
        sessionID: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> [InlineInteraction] {
        (try? await checkedRows(sessionID, dataRoot))?.compactMap { interaction(in: $0) } ?? []
    }

    /// The transcript read, with its failure VISIBLE.
    ///
    /// A missing file is not a failure — it reads as no rows. A read that
    /// actually failed is: swallowing it into an empty array made every card in
    /// the conversation vanish with no error anywhere, which reads to the
    /// person as "the app forgot what I asked for". The error is logged once
    /// per session so a repeating refresh cannot flood the log.
    private static var loggedReadFailures: Set<String> = []

    private static func checkedRows(_ sessionID: String, _ dataRoot: URL) async throws -> [JSONValue] {
        do {
            let lifeID = try DataRootLife.current(in: dataRoot)
            let rows = try await SwiftNativePersistenceCore().readJSONL(path(sessionID, dataRoot)).map { row in
                guard let card = SwiftNativeChatOrchestrationClient.inlineInteraction(in: row, lifeID: lifeID),
                      case .object(var object) = row, case .object(var metadata)? = object["metadata"] else { return row }
                let encoder = InlineInteractionWire.encoder()
                metadata[InlineInteractionWire.metadataKey] = try JSONValue.parse(encoder.encode(card))
                object["metadata"] = .object(metadata)
                return JSONValue.object(object)
            }
            loggedReadFailures.remove(sessionID)
            return rows
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
    ) async -> InlineInteraction? {
        await interactions(sessionID: sessionID, dataRoot: dataRoot).first { $0.id == id }
    }

    /// The session a card lives in: the one given, or, when that session only
    /// holds a mirror of the card (the inbox names the mirror's session), the
    /// session the mirror points back to. Settling writes there and nowhere else.
    public static func homeSession(
        id: String,
        sessionID: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> String {
        guard let rows = try? await checkedRows(sessionID, dataRoot) else { return sessionID }
        if rows.contains(where: { interaction(in: $0)?.id == id }) { return sessionID }
        for row in rows {
            guard case .object(let object) = row, case .object(let metadata)? = object["metadata"],
                  metadata["kind"] == .string("interaction_mirror"), metadata["interactionId"] == .string(id),
                  case .string(let home)? = metadata["interactionSessionId"], !home.isEmpty, home != sessionID
            else { continue }
            return home
        }
        return sessionID
    }

    /// Every interaction in a session PAIRED WITH THE TRANSCRIPT ROW it was
    /// raised on. The card belongs under that row and nowhere else, so the
    /// renderer needs the row identity the reader is scrolling past — not just
    /// the interaction. Same single read as `interactions`.
    /// The checked form: a read failure is returned, not flattened to "no
    /// cards", so the renderer can keep the last good projection on screen.
    public static func checkedInteractionsByRow(
        sessionID: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> Result<[(rowID: String, interaction: InlineInteraction)], any Error> {
        do {
            return .success(interactionsByRow(in: try await checkedRows(sessionID, dataRoot)))
        } catch {
            return .failure(error)
        }
    }

    public static func interactionsByRow(
        sessionID: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> [(rowID: String, interaction: InlineInteraction)] {
        (try? await checkedRows(sessionID, dataRoot)).map { interactionsByRow(in: $0) } ?? []
    }

    public nonisolated static func interactionsByRow(
        in rows: [JSONValue], lifeID: String? = nil
    ) -> [(rowID: String, interaction: InlineInteraction)] {
        rows.compactMap { row in
            guard case .object(let object) = row,
                  case .string(let rowID)? = object["id"],
                  let interaction = SwiftNativeChatOrchestrationClient.inlineInteraction(in: row, lifeID: lifeID)
            else { return nil }
            return (rowID, interaction)
        }
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

    // MARK: - Raising without a turn

    /// The same card, with its answer returned to the part already running.
    public static func waitForAnswer(_ interaction: InlineInteraction, tool: String, input: [String: JSONValue],
                                     sessionID: String, dataRoot: URL) async -> JSONValue {
        waitingHosts.insert(interaction.id)
        let result = await waitForAnswerBody(interaction, tool: tool, input: input,
                                             sessionID: sessionID, dataRoot: dataRoot)
        await settle { @MainActor in _ = waitingHosts.remove(interaction.id) }
        return result
    }

    private static func waitForAnswerBody(
        _ interaction: InlineInteraction, tool: String, input: [String: JSONValue], sessionID: String, dataRoot: URL
    ) async -> JSONValue {
        let changes = NotificationCenter.default.notifications(named: InlineInteractionWire.changedNotification)
            .compactMap { $0.object as? String }
        var card = interaction
        // Titled once, when first raised: an outer layer seeing the same card keeps its title.
        if let requester = SkillRunContext.requester,
           await Self.interaction(id: interaction.id, sessionID: sessionID, dataRoot: dataRoot) == nil {
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
            origin: TurnEnvelope.current(surface: ChatToolSessionContext.envelope?.surface ?? "chat"), dataRoot: dataRoot) else {
            return .object(["status": .string("failed"), "reason": .string("card_unavailable"),
                "detail": .string("The card could not be saved; nothing was answered.")])
        }
        if !InlineInteractionNeed.blocksTurn(raised) { return InlineInteractionNeed.envelope(raised) }
        func answer() async -> InlineInteraction? {
            guard let current = await Self.interaction(id: raised.id, sessionID: sessionID, dataRoot: dataRoot),
                  current.state.isTerminal, current.state.failureReason == nil else { return nil }
            return current
        }
        let current: InlineInteraction? = await TurnDeadline.withHumanWait {
            if let result = await answer() { return result }
            for await changed in changes where changed == sessionID {
                if let result = await answer() { return result }
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

    /// Persist a card for a request that never reached the engine.
    ///
    /// Every other need is raised BY a tool, so the tool-receipt writer puts
    /// it on the row it was already writing. One case has no tool and no turn:
    /// no provider is connected, so there is nothing to call and nothing to
    /// suspend. The person still asked for something, and the thing that
    /// unblocks them is the same control — so the same card is written
    /// directly, and the same resolver resumes it.
    ///
    /// `resumeText` is the person's own message, held because this path
    /// deliberately does not persist the user row.
    ///
    /// `resumable: false` writes the card with its continuation ALREADY
    /// invalidated, in this one atomic write. A turn whose input had
    /// attachments must never replay — the bytes do not travel — and
    /// invalidating afterwards was a second write whose loss was swallowed,
    /// leaving a resumable card behind.
    @discardableResult
    public static func raise(
        _ interaction: InlineInteraction,
        sessionID: String,
        resumeText: String? = nil,
        resumable: Bool = true,
        toolName: String? = nil,
        toolArgumentsJSON: String? = nil,
        toolCallId: String? = nil,
        origin: TurnEnvelope? = nil,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> InlineInteraction? {
        var stamped = SwiftNativeChatOrchestrationClient.scrubbedCardDisplay(interaction)
        let resumeRunId = "interaction-\(stamped.id)"
        let steer = PeerDataTaint.carried(
            peerBridge: PeerTurnEffectPolicy.isPeerBridge(surface: ChatToolSessionContext.envelope?.surface ?? "chat"),
            peerID: ChatToolSessionContext.envelope?.verifiedUserId
        )
        var continuation = InlineInteraction.Continuation(
            toolCallId: toolCallId,
            toolName: toolName,
            toolArgumentsJSON: toolArgumentsJSON,
            mode: toolName == nil ? .continueTurn : .retryBlockedTool,
            state: resumable ? .waiting : .invalidated,
            resumeRunId: resumeRunId,
            resumeText: resumeText,
            peerSources: steer.sources,
            elevatedPeerSources: steer.elevated
        )
        do { continuation.lifeID = try DataRootLife.current(in: dataRoot) }
        catch { nativeLog("[interaction] life identity is unavailable: \(error)"); return nil }
        // Same reason as the tool-raised card: a signed turn's card resumes as
        // a signed turn only through a receipt re-verified against the live
        // pairing material — and bound to this row, so it cannot be moved to
        // another card. This path persists no envelope on the row, so the
        // witness carries none either; the replay side rebuilds exactly that.
        continuation.signatureReceipt = InlineInteractionSignatureWitness.receipt(
            for: .init(
                sessionID: sessionID,
                interactionID: stamped.id,
                continuation: continuation,
                originEnvelope: origin,
                interaction: stamped
            )
        )
        stamped.continuation = continuation
        guard let encoded = InlineInteractionNeed.encode(stamped) else { return nil }
        let envelope = receiptEnvelope(stamped)
        var metadata: [String: JSONValue] = [
            "kind": .string(InlineInteractionWire.transcriptKind),
            "toolName": .string(InlineInteractionWire.toolName),
            "inputJSON": .string("{}"),
            "resultSummary": .string((try? envelope.serialize(pretty: false)) ?? ""),
            "resultStatus": .string(InlineInteractionWire.waitingStatus),
            "ok": .bool(false),
            InlineInteractionWire.metadataKey: encoded,
            "interactionId": .string(stamped.id),
        ]
        if let origin { metadata["envelope"] = origin.persistedMetadata() }
        let row: JSONValue = .object([
            "id": .string(UUID().uuidString.lowercased()),
            "sessionId": .string(sessionID),
            "role": .string("tool"),
            "content": .string(""),
            "createdAt": .string(ISO8601DateFormatter().string(from: Date())),
            "source": .string("chat"),
            "runId": .string(stamped.continuation?.resumeRunId ?? stamped.id),
            "metadata": .object(metadata),
        ])
        let persistence = SwiftNativePersistenceCore()
        let file = path(sessionID, dataRoot)
        do {
            try await SwiftNativeChatOrchestrationClient.appendTranscriptRow(
                row, to: file, persistence: persistence, interaction: stamped)
        } catch {
            nativeLog("[interaction] raise failed for \(stamped.id): \(error)")
            return nil
        }
        await ApprovalChatCards.publishInteractionChange(id: stamped.id, sessionID: sessionID, dataRoot: dataRoot)
        NotificationCenter.default.post(name: InlineInteractionWire.changedNotification, object: sessionID)
        NotificationCenter.default.post(name: .chatTurnCompleted, object: sessionID)
        return stamped
    }

    // MARK: - Transitions

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

    private static func finish(
        _ current: InlineInteraction, verification: Verification, sessionID: String,
        attribution: String? = nil, dataRoot: URL
    ) async throws -> InlineInteraction {
        switch verification {
        case .failure(let reason):
            // Not verified is NOT settled. The card keeps its control, the
            // person can try again, and nothing anywhere reads as connected.
            let failed = current.failed(reason: reason)
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
                    let id = SystemAppleScriptAdapter.automationTarget(target).map { "applescript:" + $0 } ?? capability.rawValue
                    RepairOwed.settle(dataRoot, operation: "permissions.request:" + id + (capability == .calendars && settled.mode == .write ? ":write" : ""),
                                     evidence: .init(source: "interaction", id: settled.id))
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
        guard byAgent, await ApprovalChatCards.isMirroredToUser(id, dataRoot: dataRoot) else { return }
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
                guard var current = await interaction(id: id, sessionID: sessionID, dataRoot: dataRoot),
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

    // MARK: - Verification
    //
    // One rule, six kinds: ask the canonical owner, never the card, and never
    // the transcript. Each of these re-reads live state AFTER the control
    // closed, which is also what makes a cancelled sheet settle as "not done"
    // instead of as success.

    private enum Verification {
        case success(InlineInteraction.Outcome)
        case failure(String)
    }

    /// Settle a waiting card ONLY if its owner now says it is done; otherwise
    /// write nothing. For re-checks while the person is away in System
    /// Settings: a grant still in progress must not fail the card under them.
    @discardableResult
    public static func completeIfVerified(
        id: String,
        sessionID: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> Bool {
        guard let current = await interaction(id: id, sessionID: sessionID, dataRoot: dataRoot),
              current.state.isOpen
        else { return true }
        guard !Task.isCancelled else { return false }
        guard case .success(let outcome) = await verify(
            current, selection: current.target, scope: nil, dataRoot: dataRoot
        ) else { return false }
        return (try? await finish(
            current, verification: .success(outcome), sessionID: sessionID, dataRoot: dataRoot
        ))?.state.outcome != nil
    }

    /// READ SIDE ONLY. A card whose thing is already done — connected in the
    /// sheet, on the Connectors page, by Agent, before a relaunch — draws as
    /// the receipt its owner would give now. Nothing is written and nothing
    /// resumes: the owner's live state is the answer, every read. Kinds that
    /// need a pick (model, choose) are left to their own controls; Mail reads
    /// macOS's live grant instead of its AppleScript probe.
    public static func liveProjection(
        _ interaction: InlineInteraction,
        dataRoot: URL
    ) async -> InlineInteraction {
        switch interaction.state {
        case .pending, .running, .failed, .declined: break
        default: return interaction
        }
        switch interaction.kind {
        case .connector, .permission, .apiKey, .capability: break
        default: return interaction
        }
        if interaction.kind == .connector, interaction.target == "mail" {
            // Mail's own check is an AppleScript round trip; the cheap read is
            // macOS's live Automation grant (never prompts; Mail not running
            // reads as unknown, so the card stays), plus read access here.
            guard await MacIntegrationPermissionStore(dataRoot: dataRoot).allows(MacIntegrationID.mail, mode: .read),
                  await platform.probeAppleEventApp("Mail") == "granted"
            else { return interaction }
            return interaction.settled(.init(selection: "mail", summary: "Mail connected"),
                                       at: interaction.settledAt ?? interaction.createdAt)
        }
        guard case .success(let outcome) = await verify(
            interaction, selection: interaction.target, scope: nil, dataRoot: dataRoot
        ) else { return interaction }
        return interaction.settled(outcome, at: interaction.settledAt ?? interaction.createdAt)
    }

    private static func verify(
        _ interaction: InlineInteraction,
        selection: String?,
        scope: InlineInteraction.Scope?,
        dataRoot: URL
    ) async -> Verification {
        switch interaction.kind {
        case .connector:
            if interaction.target == "mail" {
                let store = MacIntegrationPermissionStore(dataRoot: dataRoot)
                guard await store.allows(MacIntegrationID.mail, mode: .read) else {
                    return .failure("Mail read access is off or unavailable in Trust → Mac → Mail.")
                }
                let result = try? await platform.mailListRecent(input: ["limit": .int(1)])
                guard case .object(let object) = result, object["status"] == .string("completed") else {
                    return .failure("Mail still needs an enabled account and access to its inbox.")
                }
                return .success(.init(selection: "mail", summary: "Mail connected"))
            }
            if interaction.target == "chrome" {
                let status = await platform.chromeConnectionStatus()
                guard status.enabled, status.connected else {
                    return .failure("Chrome isn't connected yet. "
                        + platform.chromeSteps)
                }
                return .success(.init(selection: "chrome", summary: "Chrome connected"))
            }
            if interaction.target == "iphone" {
                guard await platform.pairedPhoneCount() > 0 else {
                    return .failure("No iPhone is paired yet: open NativeAgent on the iPhone, then choose Pair here when the codes match.")
                }
                return .success(.init(selection: "iphone", summary: "iPhone paired"))
            }
            // Connectors' own derived auth state — the same field the
            // Connectors page shows. A pasted-but-invalid token does not read
            // as connected here, which is the point.
            let target = InlineInteractionRegistry.canonicalConnectorID(interaction.target)
            let records = (try? await platform.connectorRecords(root: dataRoot)) ?? []
            guard let record = records.first(where: {
                InlineInteractionRegistry.canonicalConnectorID($0.id) == target
            }) else {
                return .failure("\(interaction.title) isn't in Connectors on this Mac.")
            }
            // Telegram's row says `configured` (a saved, enabled bot) rather
            // than `connected`; with health ok that is its connected.
            // Telegram's row says `configured` (a saved, enabled bot); its health is a
            // separate reading that only a successful poll proves.
            guard record.authState == "connected"
                || (target == "telegram" && record.authState == "configured" && record.healthStatus != "disabled")
            else {
                return .failure(
                    "\(InlineInteractionRegistry.connectorDisplayName(target, dataRoot: dataRoot)) still isn't connected."
                )
            }
            return .success(.init(
                selection: target,
                summary: "\(InlineInteractionRegistry.connectorDisplayName(target, dataRoot: dataRoot)) connected"
            ))

        case .permission:
            // EVERY capability in the chain, re-read from ITS OWN owner. A
            // chain asked once must be granted once — a partial grant is not a
            // settled card.
            //
            // Two owners, not one. MacIntegration capabilities live in the
            // permission store; Trust's Mac Control categories live in
            // `trust/policy.json` behind the posture gate, and before this a
            // card for one of those could never settle because only the store
            // was ever asked.
            let store = MacIntegrationPermissionStore(dataRoot: dataRoot)
            let granted = (try? await store.currentChecked()) ?? [:]
            var missing: [String] = []
            for capability in interaction.allTargets {
                if capability == "applescript" || capability == "automation" {
                    return .failure("Automation consent is per app. Request permission with target applescript:<bundle_id>.")
                }
                if InlineInteractionRegistry.isMacControlCategory(capability) {
                    if !InlineInteractionRegistry.macControlCategoryAllowed(
                        capability, dataRoot: dataRoot
                    ) {
                        missing.append(capability)
                    }
                    continue
                }
                if !MacIntegrationID.all.contains(capability),
                   SystemPermissionPreflight.cardSettingsCapability(capability) != nil { continue }
                let permission = granted[capability]
                // Only the axis that was asked for. A read need settles on
                // read; it does not wait for a write the card never requested,
                // and it is not settled by a write alone.
                let mode = interaction.mode
                let readOK = (permission?.read ?? false)
                let writeOK = (permission?.write ?? false)
                let allowed: Bool
                switch mode {
                case .read: allowed = readOK
                case .write: allowed = writeOK
                case .readWrite, .none:
                    // BOTH axes, because both is what the card said. A
                    // `read_write` need asked for both, and a legacy need with
                    // no mode is drawn as "covering reading and changing" and
                    // granted on both axes — so one axis landing is a partial
                    // grant, and a partial grant is not a settled card.
                    let promisedRead = MacIntegrationID.supportsRead(capability)
                    let promisedWrite = MacIntegrationID.supportsWrite(capability)
                    allowed = (!promisedRead || readOK) && (!promisedWrite || writeOK)
                }
                if !allowed { missing.append(capability) }
            }
            guard missing.isEmpty else {
                let names = missing.map { InlineInteractionRegistry.macCapabilityDisplayName($0) }
                // A launch-applied grant's probe can stay denied until the
                // process restarts, so a denial does not prove the switch is off.
                var seen: Set<SystemPermissionCapability> = []
                let launchApplied = missing.compactMap(SystemPermissionPreflight.cardSettingsCapability).filter {
                    SystemPermissionPreflight.appliesAtLaunch.contains($0) && seen.insert($0).inserted
                }
                let restart = launchApplied.isEmpty ? "" : " If you turned "
                    + InlineInteractionRegistry.englishList(launchApplied.map(\.displayName))
                    + " on, it takes effect only after I restart. Tell me to restart and I will, then Try again here."
                return .failure(
                    "Still not allowed: \(InlineInteractionRegistry.englishList(names))." + restart
                )
            }
            // On in System Settings, but a grant macOS applies only at launch
            // is not this process's until it restarts: the card does not
            // settle on a probe that agrees too early.
            let atLaunch = SystemPermissionPreflight.awaitingLaunch(interaction.allTargets)
            guard atLaunch.isEmpty else {
                let names = InlineInteractionRegistry.englishList(atLaunch.map(\.displayName))
                return .failure(
                    "\(names) is on, and it takes effect only after I restart. "
                    + "Tell me to restart and I will, then Try again here."
                )
            }
            if let blocked = await platform.cardBlockReason(interaction.allTargets, mode: interaction.mode) {
                return .failure(blocked)
            }
            let names = interaction.allTargets.map {
                InlineInteractionRegistry.macCapabilityDisplayName($0)
            }
            return .success(.init(
                selection: interaction.target,
                summary: "\(InlineInteractionRegistry.englishList(names)) allowed"
            ))

        case .modelChoice:
            let resolvedScope = scope ?? interaction.primaryScope ?? .persistent
            guard let picked = selection, !picked.isEmpty else {
                return .failure("No model was chosen.")
            }
            // A pick names the account and the model. A card written before
            // that — or a permanent change read back from Providers — carries
            // the model alone.
            let model = InlineInteractionRegistry.splitModelOptionID(picked)?.modelID ?? picked
            if resolvedScope == .thisRequestOnly {
                // Nothing to read back: the binding IS the resolution, and it
                // is applied to the resumed request rather than stored. It is
                // verified by construction — a model was named, and this turn
                // will run on it.
                return .success(.init(
                    // The QUALIFIED id is carried, so the binding around the
                    // resumed turn runs on the account the person picked.
                    selection: picked,
                    summary: "Using \(model) for this one",
                    scope: .thisRequestOnly
                ))
            }
            // A permanent change was written by Providers' own group save.
            // Read the routing snapshot back and confirm the group actually
            // moved before the card claims it did.
            let router = SwiftNativeProviderRouting(dataRoot: dataRoot)
            guard let snapshot = try? await router.checkedRoutingSnapshotReadOnly() else {
                return .failure("Couldn't read your provider settings back.")
            }
            let group = ProviderSurfaceGroups.all.first { $0.id == interaction.target }
            let surfaces = group?.surfaces ?? [interaction.target]
            let matched = surfaces.contains { surface in
                ProviderRoutingSurfaceLookup.value(snapshot.preferences, surface)?.model == model
            }
            guard matched else {
                return .failure("\(group?.title ?? interaction.target) isn't on \(model) yet.")
            }
            return .success(.init(
                selection: model,
                summary: "\(group?.title ?? interaction.target) now uses \(model)",
                scope: .persistent
            ))

        case .apiKey where interaction.secret != nil:
            // The keyring's own answer: removed; or a value kept since this
            // card was raised that may go everywhere asked.
            let name = String(interaction.target.dropFirst("secret:".count))
            let kept: Keyring.Entry?
            do { kept = try Keyring.entry(name) } catch {
                return .failure("The keyring could not be read, so whether \(name) is kept is unknown. Try again.")
            }
            if interaction.secret?.remove == true {
                return kept == nil ? .success(.init(selection: interaction.target, summary: "\(name) removed"))
                    : .failure("\(name) is still kept.")
            }
            guard let ask = interaction.secret, Keyring.granted(name, hosts: ask.hosts, programs: ask.programs),
                  let kept, kept.at >= interaction.createdAt else {
                return .failure("\(name) isn't kept yet.")
            }
            return .success(.init(selection: interaction.target,
                                  summary: "\(name) kept \u{00B7} for \(ask.line)" + (kept.account.map { " \u{00B7} account \($0)" } ?? "")))

        case .apiKey:
            // The provider's own readiness, as Providers reports it. A key
            // that was typed but rejected is not ready, and does not settle.
            // A provider you sign into counts as connected through either
            // door: the pasted key's own row, or the signed-in account's.
            let target = InlineInteractionRegistry.canonicalProviderID(interaction.target)
            let doors = [target] + [InlineInteractionRegistry.providerSignIn(for: target)?.oauthProviderID]
                .compactMap { $0 }
            let providers = (try? await platform.providers()) ?? []
            let rows = doors.compactMap { id in providers.first { $0.providerID == id } }
            guard let first = rows.first else {
                return .failure("No provider named \(interaction.target).")
            }
            guard let provider = rows.first(where: \.eligible) else {
                return .failure("\(first.displayName) still isn't ready.")
            }
            let model = provider.defaultModel ?? provider.firstModel
            return .success(.init(
                selection: provider.providerID,
                summary: model.map { "Connected \u{00B7} \($0) ready" } ?? "\(provider.displayName) ready"
            ))

        case .capability:
            // Trust re-read. The flag is the authority; the tap is not.
            guard let flag = InlineInteractionRegistry.capabilityFlags[interaction.target] else {
                return .failure("That isn't a switch this build has.")
            }
            let policy = await SwiftNativeTrustCenter(dataRoot: dataRoot).loadTrustPolicy()
            guard case .object(let block)? = policy[flag.policyBlock],
                  block[flag.policyKey] == .bool(true)
            else {
                return .failure("\(flag.displayName) is still off.")
            }
            if let blocked = await platform.cardBlockReason([flag.id], mode: nil) {
                return .failure(blocked)
            }
            return .success(.init(
                selection: flag.id,
                summary: "\(flag.displayName) on"
            ))

        case .choose:
            guard let picked = selection,
                  let option = interaction.options.first(where: { $0.id == picked })
            else {
                return .failure("That isn't one of the options.")
            }
            return .success(.init(selection: option.id, summary: option.label))

        case .unknown:
            return .failure("This build doesn't know that kind of request.")
        }
    }

    // MARK: - Continuation

    /// Resume the suspended request EXACTLY ONCE.
    ///
    /// The claim is taken durably, on the row, before the turn starts: two
    /// taps, or a tap on the Mac racing one on the phone, both find the claim
    /// and only one turn runs. A claim that is already `resumed`, or one that
    /// Stop/dismissal invalidated, starts nothing.
    private static func resumeOnce(
        _ interaction: InlineInteraction,
        sessionID: String,
        dataRoot: URL
    ) async {
        // A live host claims its own continuation in the originating task.
        guard !waitingHosts.contains(interaction.id),
              interaction.continuation?.state == .waiting,
              interaction.continuation?.resumedByTurnId == nil,
              resumesInFlight[interaction.id] == nil else { return }
        let sources = interaction.continuation?.peerSources ?? [PeerDataTaint.unrecorded]
        let elevated = interaction.continuation?.elevatedPeerSources ?? []
        let taint = PeerDataTaint.current
            ?? PeerDataTaint(restoring: sources, elevated: elevated)
        // A turn already carrying this card must keep its provenance too.
        // Historical steering cannot be cleared by a later trust change.
        for source in sources { taint.mark(peer: source) }
        for source in elevated { taint.elevate(peer: source) }
        await PeerDataTaint.$current.withValue(taint) {
            _ = await resumeUnderPeerProvenance(interaction, sessionID: sessionID, dataRoot: dataRoot)
        }
    }

    /// This owner holds the continuation until its effect ends, then writes
    /// its one terminal record and releases the slot, even after Stop.
    private static func resumeUnderPeerProvenance(
        _ interaction: InlineInteraction, sessionID: String, dataRoot: URL
    ) async -> JSONValue? {
        guard interaction.continuation?.state == .waiting,
              interaction.continuation?.resumedByTurnId == nil,
              resumesInFlight[interaction.id] == nil else { return nil }
        do {
            guard try DataRootLife.isCurrent(interaction.continuation?.lifeID, in: dataRoot) else { return nil }
        } catch { nativeLog("[interaction] life identity is unavailable: \(error)"); return nil }
        let owner = Task { await runContinuation(interaction, sessionID: sessionID, dataRoot: dataRoot) }
        resumesInFlight[interaction.id] = owner
        return await withTaskCancellationHandler {
            await owner.value
        } onCancel: {
            owner.cancel()
        }
    }

    private static func runContinuation(
        _ interaction: InlineInteraction, sessionID: String, dataRoot: URL
    ) async -> JSONValue? {
        var record = interaction
        record.continuation?.state = .claimed
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
            (result, handBack) = try await continueRequest(&record, sessionID: sessionID, dataRoot: dataRoot)
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
            record = record.failed(reason: error.localizedDescription)
            // A recoverable failure waits for an explicit retry; only Stop or
            // deliberate invalidation permanently retires the continuation.
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

    private static func continueRequest(
        _ record: inout InlineInteraction, sessionID: String, dataRoot: URL
    ) async throws -> (JSONValue?, String?) {
        func failure(_ reason: String) -> NSError {
            NSError(domain: "InteractionCard", code: 2, userInfo: [NSLocalizedDescriptionKey: reason])
        }
        var origin = await originEnvelope(of: record.id, sessionID: sessionID, dataRoot: dataRoot)
        // A persisted envelope is not authority: recheck the signed phone's
        // witness against the current pairing before either world effect.
        if let continuation = record.continuation, continuation.signatureReceipt?.isEmpty == false {
            let witness = InlineInteractionSignatureWitness.Witness(
                sessionID: sessionID, interactionID: record.id, continuation: continuation,
                originEnvelope: origin, interaction: record)
            guard InlineInteractionSignatureWitness.isStillSigned(witness) else {
                throw failure("This came from your iPhone and I can't verify that phone any more. "
                    + "Sign in from the phone again, then Try again.")
            }
            origin = origin.map {
                TurnEnvelope(surface: $0.surface, agent: $0.agent, verifiedChatId: $0.verifiedChatId,
                    verifiedUserId: $0.verifiedUserId, commandSignatureVerified: true,
                    deliveryRoute: $0.deliveryRoute, declaredRemote: $0.declaredRemote,
                    answerExperienceID: $0.answerExperienceID)
            }
        }

        var hostResult: JSONValue?
        if record.continuation?.replayedAt == nil, record.state.outcome != nil,
           record.continuation?.mode == .retryBlockedTool,
           let toolName = record.continuation?.toolName,
           let arguments = record.continuation?.toolArgumentsJSON, let replayBlockedTool {
            try Task.checkCancellation()
            // Keep the crash witness before dispatch; a lost process cannot
            // turn an uncertain send back into permission to send it twice.
            record.continuation?.state = .replaying
            try await persistTransition(record, from: .claimed, sessionID: sessionID, dataRoot: dataRoot)
            try Task.checkCancellation()
            let runID = record.continuation!.resumeRunId
            guard replayedResumeRunIds.insert(runID).inserted else {
                throw failure("The \(toolName) call already ran, but its saved result is unavailable.")
            }
            switch await replayBlockedTool(toolName, arguments, sessionID, origin) {
            case .dispatched(let result):
                hostResult = result.flatMap { try? JSONValue.parse(Data($0.utf8)) }
                record.continuation?.replayedAt = Date()
                record.continuation?.replayedResult = result.map {
                    SwiftNativeChatOrchestrationClient.redactedPersistedToolResult(
                        tool: ToolNameAliases.shown(toolName, inputJSON: arguments).name, json: $0)
                }
            case .failed(let reason):
                replayedResumeRunIds.remove(runID)
                try Task.checkCancellation()
                throw failure(reason)
            }
            // Saving a landed result is settlement, never a cancellable write.
            record.continuation?.state = .claimed
            try await persistTransition(record, from: .replaying, sessionID: sessionID, dataRoot: dataRoot)
        }

        try Task.checkCancellation()
        if waitingHosts.contains(record.id) {
            guard let hostResult else { throw failure("The blocked call could not resume.") }
            record.continuation?.resumedByTurnId = TurnTraceContext.turnId
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
        if let turnID = TurnTraceContext.turnId,
           await ChatTurnSteering.shared.isTurnOpen(sessionId: sessionID) {
            try Task.checkCancellation()
            record.continuation?.resumedByTurnId = turnID
            return (nil, prompt)
        }
        guard let startTurn else { throw failure("The request could not continue: no turn starter is available.") }
        let binding: InlineInteractionModelOverride.Binding? = {
            guard record.kind == .modelChoice, let outcome = record.state.outcome,
                  outcome.scope == .thisRequestOnly, let model = outcome.selection else { return nil }
            let qualified = InlineInteractionRegistry.splitModelOptionID(model)
            return .init(group: record.target, providerID: qualified?.providerID ?? "",
                         model: qualified?.modelID ?? model)
        }()
        record.continuation?.state = .replaying
        try await persistTransition(record, from: .claimed, sessionID: sessionID, dataRoot: dataRoot)
        try Task.checkCancellation()
        let synthetic = prompt != record.continuation?.resumeText
        let admitted = await InlineInteractionModelOverride.$current.withValue(binding) {
            await ChatToolSessionContext.$envelope.withValue(origin) {
                await ChatToolSessionContext.$commandSignatureVerified.withValue(origin?.commandSignatureVerified) {
                    await ChatToolSessionContext.$replyRoute.withValue(origin?.deliveryRoute) {
                        await startTurn(prompt, sessionID, synthetic)
                    }
                }
            }
        }
        guard admitted else {
            try Task.checkCancellation()
            throw failure("That couldn't be continued just now. Try again.")
        }
        return (nil, nil)
    }

    /// Reclaim only same-life work stranded by process exit. Cross-life reads
    /// are stopped, so conversation open cannot replay a restored card.
    public static func reclaimStrandedContinuations(
        sessionID: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async {
        guard !reclaimedSessions.contains(sessionID) else { return }
        let rows: [JSONValue]
        do {
            rows = try await checkedRows(sessionID, dataRoot)
        } catch {
            return
        }
        // Mark the session only after its checked read and mutations succeed.
        var reconciled = true
        for interaction in rows.compactMap({ interaction(in: $0) }) {
            // A same-life control held by the departed process needs a new tap.
            if case .running = interaction.state {
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
                let stranded = released.failed(
                    reason: pendingCall.map {
                        "The app closed while the \($0) call was running. "
                            + "I can't tell whether that ran. Check, then Try again."
                    } ?? "I can't tell whether that resumed. Try again."
                )
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
                    await resumeOnce(interaction, sessionID: sessionID, dataRoot: dataRoot)
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
            await resumeOnce(released, sessionID: sessionID, dataRoot: dataRoot)
        }
        if reconciled { reclaimedSessions.insert(sessionID) }
    }

    /// What the resumed turn is told. Same discipline as the Telegram approval
    /// continuation: an internal marker, the settled fact, an explicit "do not
    /// ask again", and the outcome quoted strictly as data.
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
                // The runtime already made the call, with the arguments the
                // model originally wrote, through the ordinary gate. The model
                // is told what came back — as data — and carries on. It is not
                // asked to rebuild the call, because a rebuilt call is a
                // different call.
                lines.append("The blocked \(toolName) call has ALREADY been replayed for you, with your original arguments, through the ordinary gate. Do not make it again.")
                if let replayedResult, !replayedResult.isEmpty {
                    lines.append("Its result, quoted strictly as data:")
                    lines.append(replayedResult)
                } else {
                    lines.append("It returned nothing usable; say so plainly rather than retrying it.")
                }
                lines.append("Carry on with the original request from there.")
            } else if let toolName, interaction.continuation?.mode == .retryBlockedTool {
                // No faithful arguments survived (they were redacted or
                // truncated), so the call cannot be replayed verbatim. Naming
                // it is the honest fallback; it goes through the ordinary
                // dispatcher, with its ordinary approval, as a first call would.
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

    // MARK: - Row persistence
    //
    // Same-row replacement, keyed by the interaction id, under the
    // transcript's own lock — the locked receipt replacement the approval
    // executor uses. The row keeps its id, createdAt, source and envelope, and
    // keeps `kind: inline_interaction` FOREVER: a settled card stays a compact
    // card in scrollback ("GitHub connected"), it does not decay into a
    // generic tool receipt.

    private nonisolated static func path(_ sessionID: String, _ dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent(
                "\(NativeAgentChatSessionID.normalizedPathComponent(sessionID) ?? sessionID).jsonl"
            )
    }

    /// The envelope of the turn that raised this card.
    ///
    /// Read from the SAME row the interaction lives on — `metadata.envelope` is
    /// written there by the one writer that stamps the card
    /// (`ChatOrchestrationClient+MessagePersistence`), at the same moment, and
    /// the resolver's own locked rewrite preserves it. So it is the originating
    /// envelope by construction, with no second copy to drift.
    ///
    /// Provenance only: it says WHO and WHERE, and the gate still re-decides.
    public static func originEnvelope(
        of id: String, sessionID: String, dataRoot: URL
    ) async -> TurnEnvelope? {
        guard let rows = try? await checkedRows(sessionID, dataRoot) else { return nil }
        for row in rows.reversed() {
            guard interaction(in: row)?.id == id,
                  case .object(let object) = row,
                  case .object(let metadata)? = object["metadata"]
            else { continue }
            return TurnEnvelope.fromPersistedMetadata(metadata["envelope"])
        }
        return nil
    }

    private nonisolated static func interaction(in row: JSONValue) -> InlineInteraction? {
        SwiftNativeChatOrchestrationClient.inlineInteraction(in: row)
    }

    private static func require(
        id: String, sessionID: String, dataRoot: URL
    ) async throws -> InlineInteraction {
        guard let found = await interaction(id: id, sessionID: sessionID, dataRoot: dataRoot)
        else { throw ResolveError.notFound }
        return found
    }

    private static func checkRevision(
        _ interaction: InlineInteraction, _ expected: Int?
    ) throws {
        guard let expected else { return }
        guard expected == interaction.revision else {
            throw ResolveError.staleRevision(expected: expected, actual: interaction.revision)
        }
    }

    /// A POST-CLAIM continuation transition, written only over the exact
    /// predecessor this caller is carrying on from.
    ///
    /// Everything after the claim used to write unconditionally, so a row that
    /// had moved on disk — reclaimed by a relaunch, invalidated by Stop,
    /// superseded by a newer identical ask — was overwritten by whatever this
    /// process still held in memory, and a card could read `resumed` for a turn
    /// nobody started. The claim itself is CAS'd; so is every step after it.
    private static func persistTransition(
        _ interaction: InlineInteraction,
        from predecessor: InlineInteraction.Continuation.ResumeState,
        sessionID: String,
        dataRoot: URL
    ) async throws {
        let expectedRevision = interaction.revision
        try await persist(
            interaction, sessionID: sessionID, dataRoot: dataRoot,
            expecting: { current in
                current.revision == expectedRevision
                    && current.continuation?.state == predecessor
            }
        )
    }


    /// `ifRevision` is the revision the caller READ before deciding on this
    /// transition; `expecting` is a predicate evaluated on the row as it exists
    /// INSIDE the lock. Both make the write a compare-and-swap: the compare
    /// happens against what is actually persisted, and a loser is told the
    /// card moved instead of resurrecting what another writer settled.
    private static func persist(
        _ interaction: InlineInteraction,
        sessionID: String,
        ifRevision expected: Int? = nil,
        dataRoot: URL,
        expecting: (@Sendable (InlineInteraction) -> Bool)? = nil
    ) async throws {
        try await settle { @MainActor in
            do {
                try await write(interaction, sessionID: sessionID, ifRevision: expected,
                                dataRoot: dataRoot, expecting: expecting)
                return Result<Void, Error>.success(())
            } catch { return .failure(error) }
        }.get()
    }

    private static func write(
        _ interaction: InlineInteraction,
        sessionID: String,
        ifRevision expected: Int? = nil,
        dataRoot: URL,
        expecting: (@Sendable (InlineInteraction) -> Bool)? = nil
    ) async throws {
        try await SwiftNativeChatOrchestrationClient.persistInlineInteraction(
            interaction, at: path(sessionID, dataRoot), ifRevision: expected,
            persistence: SwiftNativePersistenceCore(), expecting: expecting)
        await ApprovalChatCards.publishInteractionChange(id: interaction.id, sessionID: sessionID, dataRoot: dataRoot)
        // Nothing re-reads the transcript on its own; the open conversation
        // still shows the pending card until told. Same signal a remote turn
        // posts.
        NotificationCenter.default.post(name: InlineInteractionWire.changedNotification, object: sessionID)
        NotificationCenter.default.post(name: .chatTurnCompleted, object: sessionID)
    }

    public nonisolated static func receiptEnvelope(_ interaction: InlineInteraction) -> JSONValue {
        SwiftNativeChatOrchestrationClient.inlineInteractionReceiptEnvelope(interaction)
    }
}
