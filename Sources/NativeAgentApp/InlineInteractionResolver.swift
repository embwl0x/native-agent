import Foundation
import ChatOrchestration
import MacIntegration
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import TrustCenter

/// The one place an inline card settles and the one place a suspended request
/// resumes.
///
/// The shape is deliberately the same as the approval executor's: find the row
/// by a durable identifier, replace it in place so the card BECOMES the
/// receipt, and continue the conversation once. The differences are the two
/// that matter:
///
///  * **It verifies with the owner, never with the card.** A tap on "Connect
///    GitHub" does not settle anything. Connectors is asked whether GitHub is
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
enum InlineInteractionResolver {

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
    typealias TurnStarter = @MainActor (
        _ prompt: String, _ sessionID: String, _ hideUserBubble: Bool
    ) async -> Bool
    static var startTurn: TurnStarter?

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
    enum ReplayOutcome: Sendable {
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
    typealias ToolReplayer = @MainActor (
        _ toolName: String, _ argumentsJSON: String, _ sessionID: String,
        _ origin: TurnEnvelope?
    ) async -> ReplayOutcome
    static var replayBlockedTool: ToolReplayer?

    /// Interactions whose resume is in flight in THIS process. A relaunch has
    /// none, which is what makes a leftover `.claimed` on disk provably
    /// stranded rather than possibly live.
    private static var resumesInFlight: Set<String> = []
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
    static func takeContinuationHandBack(id: String) -> String? {
        handBacks.removeValue(forKey: id)
    }

    // MARK: - Errors

    enum ResolveError: LocalizedError {
        case notFound
        case staleRevision(expected: Int, actual: Int)
        case alreadySettled(String)
        case alreadyClaimed
        case notVerified(String)
        case noControl(String)

        var errorDescription: String? {
            switch self {
            case .notFound:
                return "That request is no longer in this conversation."
            case .staleRevision(let expected, let actual):
                return "This card moved on (expected \(expected), found \(actual)). Reopen it."
            case .alreadySettled(let state):
                return "That was already \(state)."
            case .alreadyClaimed:
                return "Already continuing — a second tap does nothing."
            case .notVerified(let detail):
                return detail
            case .noControl(let detail):
                return detail
            }
        }
    }

    // MARK: - Reading

    /// Every interaction row in a session, newest last. Reads the transcript
    /// and nothing else, so a relaunch rebuilds pending cards from disk.
    static func interactions(
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
            let rows = try await SwiftNativePersistenceCore().readJSONL(path(sessionID, dataRoot))
            loggedReadFailures.remove(sessionID)
            return rows
        } catch {
            if loggedReadFailures.insert(sessionID).inserted {
                NSLog("[interaction] transcript read failed for \(sessionID): \(error)")
            }
            throw error
        }
    }

    static func interaction(
        id: String,
        sessionID: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> InlineInteraction? {
        await interactions(sessionID: sessionID, dataRoot: dataRoot).first { $0.id == id }
    }

    /// Every interaction in a session PAIRED WITH THE TRANSCRIPT ROW it was
    /// raised on. The card belongs under that row and nowhere else, so the
    /// renderer needs the row identity the reader is scrolling past — not just
    /// the interaction. Same single read as `interactions`.
    /// The checked form: a read failure is returned, not flattened to "no
    /// cards", so the renderer can keep the last good projection on screen.
    static func checkedInteractionsByRow(
        sessionID: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> Result<[(rowID: String, interaction: InlineInteraction)], any Error> {
        do {
            return .success(project(try await checkedRows(sessionID, dataRoot)))
        } catch {
            return .failure(error)
        }
    }

    static func interactionsByRow(
        sessionID: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> [(rowID: String, interaction: InlineInteraction)] {
        (try? await checkedRows(sessionID, dataRoot)).map(project) ?? []
    }

    private nonisolated static func project(
        _ rows: [JSONValue]
    ) -> [(rowID: String, interaction: InlineInteraction)] {
        rows.compactMap { row in
            guard case .object(let object) = row,
                  case .string(let rowID)? = object["id"],
                  let interaction = interaction(in: row)
            else { return nil }
            return (rowID, interaction)
        }
    }

    /// The descriptor the card renders from: display name, which control
    /// opens, and whether it can be completed on this device at all.
    static func descriptor(
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
    static func raise(
        _ interaction: InlineInteraction,
        sessionID: String,
        resumeText: String? = nil,
        resumable: Bool = true,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> InlineInteraction? {
        var stamped = interaction
        let resumeRunId = "interaction-\(stamped.id)"
        var continuation = InlineInteraction.Continuation(
            toolName: nil,
            mode: .continueTurn,
            state: resumable ? .waiting : .invalidated,
            resumeRunId: resumeRunId,
            resumeText: resumeText
        )
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
                originEnvelope: nil,
                interaction: stamped
            )
        )
        stamped.continuation = continuation
        guard let encoded = InlineInteractionNeed.encode(stamped) else { return nil }
        let envelope = receiptEnvelope(stamped)
        let metadata: [String: JSONValue] = [
            "kind": .string(InlineInteractionWire.transcriptKind),
            "toolName": .string(InlineInteractionWire.toolName),
            "inputJSON": .string("{}"),
            "resultSummary": .string((try? envelope.serialize(pretty: false)) ?? ""),
            "resultStatus": .string(InlineInteractionWire.waitingStatus),
            "ok": .bool(false),
            InlineInteractionWire.metadataKey: encoded,
            "interactionId": .string(stamped.id),
        ]
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
            // One live card per ask, on THIS path too. The tool-receipt writer
            // supersedes the older identical asks under the transcript's own
            // lock before it appends; a direct raise that only appended left a
            // durable stack of "Add an API key" cards, one per message sent
            // with no provider connected. Same key, same lock, same rule — and
            // the same exception: a card already RUNNING keeps its tap, and the
            // duplicate is the one that goes quiet.
            // Immutable binding: a @Sendable closure cannot capture `stamped`.
            let raised = stamped
            let key = SwiftNativeChatOrchestrationClient.SupersedeKey(
                kind: raised.kind, target: raised.target, mode: raised.mode, id: raised.id
            )
            try await persistence.withFileLock(file) {
                // Same rule as the tool-receipt writer: supersession has to
                // SUCCEED before a new pending row is appended, or a swallowed
                // read failure stacks a second live card on the same ask.
                let running = try await SwiftNativeChatOrchestrationClient
                    .supersedeOlderPending(
                        matching: key, in: file, persistence: persistence
                    )
                let rowToAppend = running
                    ? SwiftNativeChatOrchestrationClient.supersededRow(row, as: raised)
                    : row
                try await persistence.appendJSONLDurable(rowToAppend, to: file)
            }
        } catch {
            NSLog("[interaction] raise failed for \(stamped.id): \(error)")
            return nil
        }
        NotificationCenter.default.post(name: .chatTurnCompleted, object: sessionID)
        return stamped
    }

    // MARK: - Transitions

    /// The card's primary action was tapped and the existing control is being
    /// opened. Marks the row `running` so a second tap — or the phone — sees
    /// that this is already in flight.
    @discardableResult
    static func begin(
        id: String,
        sessionID: String,
        expectedRevision: Int? = nil,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws -> InlineInteraction {
        let current = try await require(id: id, sessionID: sessionID, dataRoot: dataRoot)
        try checkRevision(current, expectedRevision)
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
        case .pending, .failed:
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
    @discardableResult
    static func complete(
        id: String,
        sessionID: String,
        selection: String? = nil,
        scope: InlineInteraction.Scope? = nil,
        expectedRevision: Int? = nil,
        attribution: String? = nil,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws -> InlineInteraction {
        let current = try await require(id: id, sessionID: sessionID, dataRoot: dataRoot)
        try checkRevision(current, expectedRevision)
        guard current.state.isOpen else {
            throw ResolveError.alreadySettled(current.state.name)
        }

        let verification = await verify(
            current, selection: selection, scope: scope, dataRoot: dataRoot
        )
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
            await resumeOnce(settled, sessionID: sessionID, dataRoot: dataRoot)
            return settled
        }
    }

    /// "No." Settles as declined and resumes the request with the consequence
    /// the card promised, so Agent acts on the refusal rather than waiting
    /// forever or silently retrying the same wall.
    @discardableResult
    static func decline(
        id: String,
        sessionID: String,
        expectedRevision: Int? = nil,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws -> InlineInteraction {
        let current = try await require(id: id, sessionID: sessionID, dataRoot: dataRoot)
        try checkRevision(current, expectedRevision)
        guard current.state.isOpen else {
            throw ResolveError.alreadySettled(current.state.name)
        }
        let declined = current.declined()
        try await persist(
            declined, sessionID: sessionID, ifRevision: current.revision, dataRoot: dataRoot
        )
        await resumeOnce(declined, sessionID: sessionID, dataRoot: dataRoot)
        return declined
    }

    /// Undo a `begin` that must not carry through: the card goes back to
    /// answerable, exactly as it was before the agent touched it.
    ///
    /// The agent marks a card running BEFORE it acts, and that mark costs
    /// transcript I/O — long enough for the Trust posture behind an authority
    /// change to drop in another window. A refusal at that point must leave the
    /// card pending for the person, not `running` with nobody running it.
    @discardableResult
    static func returnToPending(
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
    static func invalidateContinuation(
        id: String,
        sessionID: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async {
        guard var current = await interaction(id: id, sessionID: sessionID, dataRoot: dataRoot)
        else { return }
        let readRevision = current.revision
        current.continuation?.state = .invalidated
        current.revision += 1
        try? await persist(
            current, sessionID: sessionID, ifRevision: readRevision, dataRoot: dataRoot
        )
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

    private static func verify(
        _ interaction: InlineInteraction,
        selection: String?,
        scope: InlineInteraction.Scope?,
        dataRoot: URL
    ) async -> Verification {
        switch interaction.kind {
        case .connector:
            // Connectors' own derived auth state — the same field the
            // Connectors page shows. A pasted-but-invalid token does not read
            // as connected here, which is the point.
            let target = InlineInteractionRegistry.canonicalConnectorID(interaction.target)
            let records = (try? await NativeClient.readConnectorRecords(root: dataRoot)) ?? []
            guard let record = records.first(where: {
                InlineInteractionRegistry.canonicalConnectorID($0.id) == target
            }) else {
                return .failure("\(interaction.title) isn't in Connectors on this Mac.")
            }
            guard record.authState == "connected" else {
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
                if InlineInteractionRegistry.isMacControlCategory(capability) {
                    if !InlineInteractionRegistry.macControlCategoryAllowed(
                        capability, dataRoot: dataRoot
                    ) {
                        missing.append(capability)
                    }
                    continue
                }
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
                return .failure(
                    "Still not allowed: \(InlineInteractionRegistry.englishList(names))."
                )
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

        case .apiKey:
            // The provider's own readiness, as Providers reports it. A key
            // that was typed but rejected is not ready, and does not settle.
            let providers = (try? await NativeClient(baseURL: "").listProviders()) ?? []
            guard let provider = providers.first(where: { $0.provider_id == interaction.target })
            else {
                return .failure("No provider named \(interaction.target).")
            }
            guard provider.auth_status.state.lowercased() == "ready" else {
                return .failure("\(provider.display_name) still isn't ready.")
            }
            return .success(.init(
                selection: provider.provider_id,
                summary: "\(provider.display_name) ready"
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
        guard var continuation = interaction.continuation else { return }
        // One continuation, one resume — whichever half of the fork took it.
        // `.waiting` is the durable claim; `resumedByTurnId` is the hand-back's
        // own mark (a turn already carries this card, so nothing may start a
        // second one); `resumesInFlight` covers the in-process race two callers
        // holding the same stale row would otherwise win together.
        guard continuation.state == .waiting,
              continuation.resumedByTurnId == nil,
              !resumesInFlight.contains(interaction.id)
        else { return }

        // Reserved BEFORE the first await. The check above and this insert ran
        // in one main-actor step, so a second caller holding the same stale row
        // cannot slip in while the claim below is being written — which is
        // exactly what reserving after the persist allowed.
        resumesInFlight.insert(interaction.id)
        defer { resumesInFlight.remove(interaction.id) }

        continuation.state = .claimed
        var claimed = interaction
        claimed.continuation = continuation
        do {
            // Compare-and-swap under the transcript lock: the row on disk must
            // still be the unclaimed revision this caller read. Another
            // process that claimed it in between loses here instead of both
            // sides resuming the same card.
            try await persist(
                claimed, sessionID: sessionID, dataRoot: dataRoot,
                expecting: { current in
                    current.revision == interaction.revision
                        && current.continuation?.state == .waiting
                        && current.continuation?.resumedByTurnId == nil
                }
            )
        } catch {
            NSLog("[interaction] resume claim failed for \(interaction.id): \(error)")
            return
        }

        // The envelope of the turn that raised the card. Both halves of the
        // resume — the blocked call's replay and the continuation turn — run
        // under it, so neither is laundered into a trusted local Mac call.
        var origin = await originEnvelope(
            of: interaction.id, sessionID: sessionID, dataRoot: dataRoot
        )

        // A card raised by a SIGNED turn — an iPhone turn whose HMAC the
        // inbound path checked — has to replay as one, or the iOS trust gate
        // refuses its own request back. The persisted envelope deliberately
        // does not carry that verdict, so the continuation carries a RECEIPT
        // instead and it is re-checked HERE, against the live pairing
        // material. The transcript never becomes the authority: it holds a
        // token the pairing secret has to still agree with.
        if let record = claimed.continuation, record.signatureReceipt?.isEmpty == false {
            // Rebuilt from THIS row: a receipt minted for another card, another
            // session, or the same card before its tool or arguments were
            // edited produces a different witness and does not verify.
            let witness = InlineInteractionSignatureWitness.Witness(
                sessionID: sessionID,
                interactionID: claimed.id,
                continuation: record,
                originEnvelope: origin,
                interaction: claimed
            )
            guard InlineInteractionSignatureWitness.isStillSigned(witness) else {
                // The pairing changed (or this Mac lost the secret). Replaying
                // unsigned would either be refused by the gate or, worse, run
                // as something it is not. Say the repair instead.
                await failAfterLostTransition(
                    id: interaction.id, sessionID: sessionID,
                    reason: "This came from your iPhone and I can't verify that phone any more. "
                        + "Sign in from the phone again, then Try again.",
                    dataRoot: dataRoot
                )
                return
            }
            origin = origin.map {
                TurnEnvelope(
                    surface: $0.surface,
                    agent: $0.agent,
                    verifiedChatId: $0.verifiedChatId,
                    verifiedUserId: $0.verifiedUserId,
                    commandSignatureVerified: true,
                    deliveryRoute: $0.deliveryRoute,
                    declaredRemote: $0.declaredRemote
                )
            }
        }

        // The blocked call, replayed verbatim, behind the ordinary gate.
        //
        // This runs BEFORE the continuation turn and its result is handed to
        // that turn as data, so the model carries on from what actually
        // happened instead of being told to make a call it would have to
        // rebuild from memory. Only a settled card replays; a decline or a
        // failure has nothing to run.
        //
        // A replay that ran is CHECKPOINTED on the row before admission. Turn
        // admission can still be refused, and a refusal releases the claim back
        // to `waiting` so the person can tap again — without the checkpoint,
        // that second tap would make the same call to the world a second time.
        var replayedResult: String? = claimed.continuation?.replayedResult
        var replayed = claimed.continuation?.replayedAt != nil
        if !replayed,
           claimed.state.outcome != nil,
           claimed.continuation?.mode == .retryBlockedTool,
           let toolName = claimed.continuation?.toolName,
           let arguments = claimed.continuation?.toolArgumentsJSON,
           let replayBlockedTool {
            // The checkpoint is MANDATORY, not best-effort. It is the only
            // thing standing between a refused admission and the same effect
            // being replayed on the world a second time, so a replay whose
            // checkpoint cannot be written must stop the continuation here
            // rather than carry on with the claim unrecorded.
            //
            // In-process idempotency is keyed on `resumeRunId` — the stable id
            // of THIS continuation — so even a checkpoint that never reached
            // disk cannot be replayed twice by this process.
            let resumeRunId = claimed.continuation?.resumeRunId
            if let resumeRunId, replayedResumeRunIds.contains(resumeRunId) {
                replayed = true
            } else {
            // The pre-dispatch marker, written DURABLY before the call is
            // made. The in-process guard above dies with the process, and the
            // checkpoint below is written after the effect — so a crash, or a
            // failed checkpoint write, between those two left disk holding an
            // ordinary `.claimed` row that relaunch happily released back to
            // `waiting` and replayed, making the same real call twice.
            //
            // `.replaying` is the honest third answer: this call MAY have run.
            // Reclaim never auto-replays a row in it (see
            // `reclaimStrandedContinuations`). If the marker itself cannot be
            // written, nothing is dispatched at all — an unrecorded call is
            // exactly what this state exists to prevent.
            claimed.continuation?.state = .replaying
            do {
                try await persistTransition(
                    claimed, from: .claimed, sessionID: sessionID, dataRoot: dataRoot
                )
            } catch {
                NSLog("[interaction] pre-dispatch marker failed for \(interaction.id): \(error)")
                await failAfterLostTransition(
                    id: interaction.id, sessionID: sessionID,
                    reason: "Couldn't record that the \(toolName) call was about to run, so it wasn't made. Try again.",
                    dataRoot: dataRoot
                )
                return
            }
            if let resumeRunId { replayedResumeRunIds.insert(resumeRunId) }
            switch await replayBlockedTool(toolName, arguments, sessionID, origin) {
            case .dispatched(let result):
                // The SAME redaction and bound the transcript's own tool
                // receipt gets. This result is persisted on the card's
                // continuation and fed to the resumed turn's prompt, and a
                // replayed `read_file` returns the file — credentials
                // included. Redacted before either, never after.
                let safeResult = result.map {
                    SwiftNativeChatOrchestrationClient
                        .redactedPersistedToolResult(tool: toolName, json: $0)
                }
                replayed = true
                replayedResult = safeResult
                claimed.continuation?.state = .claimed
                claimed.continuation?.replayedAt = Date()
                claimed.continuation?.replayedResult = safeResult
                do {
                    try await persistTransition(
                        claimed, from: .replaying, sessionID: sessionID, dataRoot: dataRoot
                    )
                } catch {
                    // The call already happened. Without a durable record of
                    // it, admitting the turn would leave a card that can be
                    // tapped again into a second real effect — so the card is
                    // failed RETRYABLY and the turn is not started. The person
                    // sees what happened instead of a silent double-send.
                    NSLog("[interaction] replay checkpoint failed for \(interaction.id): \(error)")
                    await failAfterLostTransition(
                        id: interaction.id, sessionID: sessionID,
                        reason: "The \(toolName) call ran, but recording it failed. Try again.",
                        dataRoot: dataRoot
                    )
                    return
                }
            case .failed(let reason):
                // Nothing ran, so the in-process guard is released too, and
                // the pre-dispatch marker is cleared: this is the one case
                // that KNOWS the world was not touched, so the row goes back
                // to an ordinary claim and a retry is free to run the call for
                // real. A clear that does not land leaves `.replaying` on
                // disk, which errs toward asking the person rather than
                // replaying behind their back.
                if let resumeRunId { replayedResumeRunIds.remove(resumeRunId) }
                claimed.continuation?.state = .claimed
                do {
                    try await persistTransition(
                        claimed, from: .replaying, sessionID: sessionID, dataRoot: dataRoot
                    )
                } catch {
                    NSLog("[interaction] clearing the pre-dispatch marker failed for \(interaction.id): \(error)")
                }
                // Nothing happened, so nothing is recorded. The prompt falls
                // back to telling the model the call may now run, and a retry
                // is free to replay it for real.
                NSLog("[interaction] replay of \(toolName) did not run for \(interaction.id): \(reason)")
            }
            }
        }

        // A card raised before any turn existed resumes by re-asking the
        // person's own question: there is no interrupted turn to continue,
        // because there was never one to interrupt.
        let prompt: String = {
            if claimed.continuation?.mode == .continueTurn,
               claimed.state.outcome != nil,
               let text = claimed.continuation?.resumeText,
               !text.isEmpty {
                return text
            }
            return continuationPrompt(
                for: claimed, replayed: replayed, replayedResult: replayedResult
            )
        }()
        // The model choice scoped to THIS request is bound around the resumed
        // turn and dies with it. A permanent choice was already written by
        // Providers, so nothing is bound here.
        let binding: InlineInteractionModelOverride.Binding? = {
            guard claimed.kind == .modelChoice,
                  let outcome = claimed.state.outcome,
                  outcome.scope == .thisRequestOnly,
                  let model = outcome.selection
            else { return nil }
            // The account the person picked, read off the option id. Inference
            // is the fallback for a card written before options carried one.
            let qualified = InlineInteractionRegistry.splitModelOptionID(model)
            let router = SwiftNativeProviderRouting(dataRoot: dataRoot)
            let providerID = qualified?.providerID
                ?? router.inferProviderForModel(model)
                ?? ""
            return .init(
                group: claimed.target,
                providerID: providerID,
                model: qualified?.modelID ?? model
            )
        }()

        // A turn is ALREADY narrating this session, and this card was settled
        // from inside it. Starting a continuation turn here is exactly what put
        // two turns on one transcript: the declined card's resume wrote its own
        // reply while the turn that raised the card was still writing, and that
        // ghost turn's fold read as "1 of 2 failed".
        //
        // The running turn IS the continuation. The settled card, the
        // consequence, and anything the replay above returned are handed back
        // to it as the answer to the call it just made, so it carries on in the
        // same reply. A tap on the glass while a turn runs is NOT this case —
        // there is no tool call waiting to be answered — so it falls through to
        // ordinary admission below, which queues it behind the running turn
        // rather than racing it.
        if let carryingTurnId = TurnTraceContext.turnId,
           await ChatTurnSteering.shared.isTurnOpen(sessionId: sessionID) {
            var handed = claimed
            handed.continuation?.state = .resumed
            handed.continuation?.resumedByTurnId = carryingTurnId
            do {
                try await persistTransition(
                    handed, from: .claimed, sessionID: sessionID, dataRoot: dataRoot
                )
            } catch {
                // The hand-back is only safe once disk agrees a turn took this
                // card. Publishing it first left a consumable answer while the
                // row still read `.claimed` — the turn swallowed the card and
                // nothing on disk said so. A write that did not land publishes
                // nothing and fails the card retryably instead.
                NSLog("[interaction] hand-back record failed for \(interaction.id): \(error)")
                await failAfterLostTransition(
                    id: interaction.id, sessionID: sessionID,
                    reason: "Couldn't record that this was handed back to the turn already "
                        + "running, so it wasn't. Try again.",
                    dataRoot: dataRoot
                )
                return
            }
            handBacks[interaction.id] = prompt
            return
        }

        guard let startTurn else {
            NSLog("[interaction] no turn starter installed; \(interaction.id) settled without resuming")
            return
        }
        // The pre-admission marker, written DURABLY before the turn starts —
        // the SAME `.replaying` marker used before a dispatch, and for the
        // same reason. Admission used to start the turn first and record it
        // after, so a lost CAS on the `resumed` write left disk reading
        // `.claimed`: reclaim released it back to `waiting` and the card
        // resumed a SECOND time. A row in `.replaying` is never auto-replayed;
        // if the marker itself cannot be written, no turn is started at all.
        // It shares the dispatch marker's wire value on purpose — a new one
        // would read as `.waiting` to an older build, which is the duplicate
        // resume this marker exists to prevent.
        var admittingClaim = claimed
        admittingClaim.continuation?.state = .replaying
        do {
            try await persistTransition(
                admittingClaim, from: .claimed, sessionID: sessionID, dataRoot: dataRoot
            )
        } catch {
            NSLog("[interaction] pre-admission marker failed for \(interaction.id): \(error)")
            await failAfterLostTransition(
                id: interaction.id, sessionID: sessionID,
                reason: "Couldn't record that this was about to continue, so it wasn't started. "
                    + "Try again.",
                dataRoot: dataRoot
            )
            return
        }
        let admitted = await InlineInteractionModelOverride.$current.withValue(binding) {
            // Ordinary turn admission, ordinary gate. Nothing about having
            // resolved a card grants the resumed turn any autonomy it did not
            // already have — and the turn runs under the ORIGIN's envelope, so
            // its reply goes back where the request came from and its tools are
            // judged on the identities the first attempt was judged on.
            await ChatToolSessionContext.$envelope.withValue(origin) {
                // The gate reads this task-local directly in places that never
                // see the envelope (Full Mac admission, turn planning), so the
                // re-verified signature is bound on BOTH, exactly as the tool
                // replay binds it.
                await ChatToolSessionContext.$commandSignatureVerified
                    .withValue(origin?.commandSignatureVerified) {
                    await ChatToolSessionContext.$replyRoute
                        .withValue(origin?.deliveryRoute) {
                            await startTurn(
                                prompt, sessionID,
                                prompt != claimed.continuation?.resumeText
                            )
                        }
                }
            }
        }

        // A REFUSED admission is a dead end unless it is said out loud. Putting
        // the continuation back to `waiting` under a card still reading
        // `settled` left nothing that could restart it: the card has no retry
        // control in a settled state, `begin` refuses a settled card, and
        // reclaim only releases `claimed` rows. The card is failed RETRYABLY
        // instead — which is exactly what keeps its control and its "Try
        // again" — against the row as it stands on disk, so the replay
        // checkpoint written above (`replayedAt` / `replayedResult`) survives
        // and a retry tells the model what the call already returned rather
        // than making it a second time.
        guard admitted else {
            NSLog("[interaction] resume was not admitted for \(interaction.id); claim released")
            await failAfterLostTransition(
                id: interaction.id, sessionID: sessionID,
                reason: "That couldn't be continued just now. Try again.",
                dataRoot: dataRoot
            )
            return
        }
        // `resumed` is a claim about the world, so it is written only when the
        // world agrees.
        var settledClaim = admittingClaim
        settledClaim.continuation?.state = .resumed
        do {
            try await persistTransition(
                settledClaim, from: .replaying, sessionID: sessionID, dataRoot: dataRoot
            )
        } catch {
            // The turn may already be running, so the row must not be left in
            // `.replaying` for reclaim to guess about later in this same
            // launch. It is failed retryably against the state we know, and
            // the person is told the resume is unverifiable.
            NSLog("[interaction] recording the resume of \(interaction.id) failed: \(error)")
            await failAfterLostTransition(
                id: interaction.id, sessionID: sessionID,
                reason: "I can't tell whether that resumed. Try again.",
                dataRoot: dataRoot
            )
        }
    }

    /// A `.claimed` continuation that never reached `.resumed` is stranded: the
    /// claim is durable, the turn that was supposed to follow it is not, and a
    /// process that died between the two leaves a card nothing can restart.
    ///
    /// A relaunch has no resumes in flight, so any claim still on disk when
    /// this session first reads the conversation belongs to a process that is
    /// gone. Put it back to `waiting` and it becomes retryable again.
    static func reclaimStrandedContinuations(
        sessionID: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async {
        guard !reclaimedSessions.contains(sessionID) else { return }
        // The CHECKED read first, and the once-per-session mark only after the
        // pass actually reconciled. Marking up front meant a transcript read
        // that FAILED — a locked file, a transient I/O error — burned the one
        // attempt this launch gets, and every stranded claim in the
        // conversation stayed stranded until relaunch with nothing on screen
        // saying so.
        let rows: [JSONValue]
        do {
            rows = try await checkedRows(sessionID, dataRoot)
        } catch {
            return
        }
        // Any mutation below that fails leaves the session UNMARKED, so the
        // next read of this conversation retries it.
        var reconciled = true
        for interaction in rows.compactMap({ interaction(in: $0) }) {
            // A `running` card means "a control is open on this Mac right
            // now". This is the FIRST read of the conversation this launch, so
            // no control in this process can have opened yet: anything still
            // running belongs to a process that is gone, and left the card with
            // no action at all — not open enough to act on, not failed enough
            // to retry. Demote it to the retryable failure it actually is.
            if case .running = interaction.state {
                let orphaned = interaction.failed(
                    reason: "The app closed before this finished."
                )
                do {
                    try await persist(orphaned, sessionID: sessionID, dataRoot: dataRoot)
                } catch {
                    reconciled = false
                }
                continue
            }
            // A row caught mid-dispatch or mid-admission. The call may have reached the world
            // and may not have; nothing readable from here can tell, so this
            // is the one continuation that is NEVER restarted automatically.
            // The person is told exactly that, and the retry is theirs to tap.
            if interaction.continuation?.state == .replaying,
               !resumesInFlight.contains(interaction.id) {
                var released = interaction
                released.continuation?.state = .waiting
                released.revision += 1
                // Which of the two markers this was is readable from the row
                // itself: a call is only still in doubt when one was dispatched
                // and never checkpointed. A checkpointed replay (or a card with
                // no call to replay at all) was caught on the way into the
                // turn, so the doubt is about the resume, not about the world.
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
                    try await persist(stranded, sessionID: sessionID, dataRoot: dataRoot)
                } catch {
                    reconciled = false
                }
                continue
            }
            guard interaction.continuation?.state == .claimed,
                  !resumesInFlight.contains(interaction.id)
            else { continue }
            var released = interaction
            released.continuation?.state = .waiting
            released.revision += 1
            do {
                try await persist(released, sessionID: sessionID, dataRoot: dataRoot)
            } catch {
                // The claim is still on disk, so this card is still stranded.
                // Leave the session retryable and do NOT resume from a release
                // that did not land.
                reconciled = false
                continue
            }
            // The card settled; only the continuation was lost. Run it now,
            // which is what the person asked for when they resolved the card.
            await resumeOnce(released, sessionID: sessionID, dataRoot: dataRoot)
        }
        if reconciled { reclaimedSessions.insert(sessionID) }
    }

    /// What the resumed turn is told. Same discipline as the Telegram approval
    /// continuation: an internal marker, the settled fact, an explicit "do not
    /// ask again", and the outcome quoted strictly as data.
    static func continuationPrompt(
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
    static func originEnvelope(
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
        guard case .object(let object) = row,
              case .object(let metadata)? = object["metadata"],
              case .string(InlineInteractionWire.transcriptKind)? = metadata["kind"],
              let raw = metadata[InlineInteractionWire.metadataKey]
        else { return nil }
        return InlineInteractionNeed.decode(raw)
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

    /// The recovery write after a post-claim transition did not land.
    ///
    /// The in-memory row this caller holds is exactly the thing that just
    /// lost, so writing it back stamps a stale continuation over whatever
    /// actually won. The authoritative row is re-read instead and THAT is
    /// failed retryably — and a row that already moved on to `resumed` or was
    /// invalidated is left alone, because a retry means nothing on it.
    private static func failAfterLostTransition(
        id: String,
        sessionID: String,
        reason: String,
        dataRoot: URL
    ) async {
        guard var onDisk = await interaction(id: id, sessionID: sessionID, dataRoot: dataRoot)
        else { return }
        let found = onDisk.revision
        let foundState = onDisk.continuation?.state
        guard foundState != .resumed, foundState != .invalidated else {
            NSLog("[interaction] \(id) already moved on; not failing it")
            return
        }
        onDisk.continuation?.state = .waiting
        let failed = onDisk.failed(reason: reason)
        // Revision ALONE is not identity here: a continuation-only transition
        // (`.claimed` -> `.resumed`) does not bump it, so a row that moved
        // between the read above and this write still matched the compare and
        // was stamped back to a failed `waiting`. The exact continuation state
        // this decision was made on is part of the compare.
        try? await persist(
            failed, sessionID: sessionID, dataRoot: dataRoot,
            expecting: { $0.revision == found && $0.continuation?.state == foundState }
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
        let persistence = SwiftNativePersistenceCore()
        let file = path(sessionID, dataRoot)
        try await persistence.withFileLock(file) {
            var rows = (try? await persistence.readJSONL(file)) ?? []
            guard let index = rows.firstIndex(where: {
                Self.interaction(in: $0)?.id == interaction.id
            }) else { throw ResolveError.notFound }
            if let expected, let persisted = Self.interaction(in: rows[index]) {
                guard persisted.revision == expected else {
                    throw ResolveError.staleRevision(
                        expected: expected, actual: persisted.revision
                    )
                }
            }
            if let expecting {
                guard let onDisk = Self.interaction(in: rows[index]) else {
                    throw ResolveError.notFound
                }
                guard expecting(onDisk) else {
                    throw ResolveError.staleRevision(
                        expected: interaction.revision, actual: onDisk.revision
                    )
                }
            }
            guard case .object(var object) = rows[index],
                  case .object(var metadata)? = object["metadata"]
            else { throw ResolveError.notFound }
            if let encoded = InlineInteractionNeed.encode(interaction) {
                metadata[InlineInteractionWire.metadataKey] = encoded
            }
            // The receipt the rest of the app reads. The pill and the history
            // renderer both parse `resultSummary` as a dispatch envelope, so a
            // settled card must write an ENVELOPE here, not prose — prose
            // parses to nothing and renders as "completion not confirmed".
            let envelope = receiptEnvelope(interaction)
            metadata["resultSummary"] = .string(
                (try? envelope.serialize(pretty: false)) ?? ""
            )
            metadata["resultStatus"] = .string(interaction.state.name)
            metadata["resultClass"] = .string(
                ChatToolOutcome.exactResultClass(envelope).rawValue
            )
            // Read by SessionHistoryPromptRenderer exactly like an ordinary
            // tool result, so the settled outcome reaches Agent's next turn
            // instead of being clipped out of the head projection.
            if let summary = interaction.state.outcome?.summary, !summary.isEmpty {
                metadata["resultBody"] = .string(summary)
            }
            metadata["ok"] = .bool(interaction.state.outcome != nil)
            object["metadata"] = .object(metadata)
            rows[index] = .object(object)
            try await persistence.replaceJSONL(rows, to: file)
        }
        // Nothing re-reads the transcript on its own; the open conversation
        // still shows the pending card until told. Same signal a remote turn
        // posts.
        NotificationCenter.default.post(name: .chatTurnCompleted, object: sessionID)
    }

    nonisolated static func receiptEnvelope(_ interaction: InlineInteraction) -> JSONValue {
        switch interaction.state {
        case .settled(let outcome):
            return .object([
                "status": .string("succeeded"),
                "ok": .bool(true),
                "detail": .string(outcome.summary),
            ])
        case .declined:
            return .object([
                "status": .string("cancelled"),
                "detail": .string(interaction.declineConsequence),
            ])
        // Replaced by a newer identical ask. Terminal and nobody's fault — and
        // NOT still waiting, which is what the `default` below used to call it.
        case .superseded:
            return .object([
                "status": .string("cancelled"),
                "detail": .string("A newer identical request replaced this one."),
            ])
        case .failed(let reason):
            return .object([
                "status": .string("failed"),
                "ok": .bool(false),
                "error": .string(reason),
            ])
        default:
            return .object([
                "status": .string(InlineInteractionWire.waitingStatus),
                "detail": .string(interaction.why),
            ])
        }
    }
}
