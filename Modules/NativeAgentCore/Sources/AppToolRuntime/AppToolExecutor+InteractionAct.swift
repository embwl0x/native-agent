import ApprovalTransactions
import ChatTurnContracts
import ChatToolRuntime
import ChatToolParsing
import Dispatcher
import Foundation
import MacIntegration
import MacControl
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Privacy
import TrustCenter
// Blueprint: | `AppToolExecutor+InteractionAct.swift` | `AppToolExecutor`: `cardRefusal`, `runCardAction`, `applyMacControlCategoryGrant` |

/// Card actions use the control owner's non-UI path and reread that owner before completion.
/// Controls requiring a window return needs_glass; rejected writes fail with the owner's reason and preserve retry.
/// Remote cards belong to their verified person and cannot be answered by another caller.
extension AppToolExecutor {

    private enum InteractionControlRoute {
        case permissionGrant
        case capabilityFlag
        case providerKey
        case inlineSelection
        case needsGlass(String)
    }

    /// Transport-verified identities must match wherever either side recorded one; persistence and transport surface names differ.
    private static func sameOriginLane(card: TurnEnvelope, caller: TurnEnvelope) -> Bool {
        card.verifiedChatId == caller.verifiedChatId
            && card.verifiedUserId == caller.verifiedUserId
    }

    /// Only declared saved-policy capability keys may be written.
    private static let selfAdminCapabilityPolicyKeys: Set<String> = [
        "image_generation_openai", "screen_capture", "tts_openai",
    ]

    /// Name moved authority in refusals; routes moving none return nil.
    private static func authorityMutation(_ route: InteractionControlRoute) -> String? {
        switch route {
        case .permissionGrant: return "Granting Mac access"
        case .capabilityFlag: return "Turning on a Trust capability"
        case .providerKey: return "Writing a provider key"
        case .inlineSelection, .needsGlass: return nil
        }
    }

    private static func interactionText(_ value: JSONValue?) -> String {
        guard case .string(let raw)? = value else { return "" }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct CardPlan {
        let appModel: any QuietToolHost
        let dataRoot: URL
        let sessionID: String
        let current: InlineInteraction
        /// Re-read Full Mac for authority-moving card receipts.
        let posture: QuietPosture
        /// Decline routes to no control.
        let route: InteractionControlRoute?
        let value: String
        let choice: String
    }

    /// Preview and execution share read-only origin, user-kind, route and posture checks before touching a card.
    @MainActor
    func cardRefusal(input: [String: JSONValue], surface: String, turn: Turn) async -> JSONValue? {
        if case .failure(let refusal) = await cardGate(input: input, surface: surface, turn: turn) { return refusal.answer }
        return nil
    }

    struct GateRefusal: Error {
        let answer: JSONValue
        init(answer: JSONValue) { self.answer = ChatToolOutcome.refusedBeforeRunning(answer) }
    }

    /// Card ids may arrive bare or prefixed as their interaction inbox note.
    private static func cardID(_ input: [String: JSONValue]) -> String {
        let id = interactionText(input["interaction_id"])
        return id.hasPrefix("interaction:") ? String(id.dropFirst("interaction:".count)) : id
    }

    @MainActor
    private func cardGate(input: [String: JSONValue], surface: String, turn: Turn) async -> Result<CardPlan, GateRefusal> {
        func refuse(_ answer: JSONValue) -> Result<CardPlan, GateRefusal> { .failure(GateRefusal(answer: answer)) }
        let id = Self.cardID(input)
        let rawAction = Self.interactionText(input["action"]).lowercased()
        let action = rawAction.isEmpty ? "primary" : rawAction
        guard let appModel = quietHost() else {
            return refuse(Self.interactionFailure(
                "app_window_unavailable",
                "The app's own controls are not available in this process."
            ))
        }
        let dataRoot = appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        // Resolve the card in its originating conversation, including the note's explicit target.
        let openSession = appModel.activeChatSessionId
        var sessionID = openSession
        var found: InlineInteraction?
        do {
            found = openSession.isEmpty ? nil
                : try await InlineInteractionResolver.interaction(id: id, sessionID: openSession, dataRoot: dataRoot)
            if found == nil {
                let raisedIn = try await InlineInteractionDelivery.pointer(id: "interaction:\(id)", dataRoot: dataRoot).sessionID
                sessionID = raisedIn
                found = try await InlineInteractionResolver.interaction(id: id, sessionID: raisedIn, dataRoot: dataRoot)
            }
        } catch {
            return refuse(Self.interactionFailure("card_unavailable",
                TurnSecretRedactor.redactText(error.localizedDescription), extra: ["interaction_id": .string(id)]))
        }
        guard let current = found else {
            return refuse(Self.interactionFailure(
                "not_found",
                "No card has that id in any conversation.",
                extra: ["interaction_id": .string(id)]
            ))
        }

        // Missing card provenance refuses. Transport-verified chat/person identities must agree, and the turn must own the card's conversation.
        let origin: TurnEnvelope?
        do { origin = try await InlineInteractionResolver.originEnvelope(of: id, sessionID: sessionID, dataRoot: dataRoot) }
        catch {
            return refuse(Self.interactionFailure("card_unavailable",
                TurnSecretRedactor.redactText(error.localizedDescription), extra: ["interaction_id": .string(id)]))
        }
        guard let cardOrigin = origin, !cardOrigin.surface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return refuse(Self.interactionFailure(
                "origin_unverifiable",
                "I can't tell whose card this is — the row that raised it records no origin, so "
                + "I won't settle it. The person can answer it in the app.",
                extra: ["interaction_id": .string(id)]
            ))
        }
        let caller = TurnEnvelope.current(turn: turn, surface: surface)
        guard Self.sameOriginLane(card: cardOrigin, caller: caller) else {
            return refuse(Self.interactionFailure(
                "not_yours_to_answer",
                "That card belongs to a different conversation lane than this turn, so it isn't "
                + "mine to answer from here.",
                extra: [
                    "interaction_id": .string(id),
                    "origin_surface": .string(cardOrigin.surface),
                    "caller_surface": .string(caller.surface),
                ]
            ))
        }
        // The verified transport conversation takes precedence over the visible window; only the card's originating conversation may answer.
        let verified = turn.verifiedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let callerSession = verified.isEmpty ? openSession : verified
        if callerSession != sessionID {
            return refuse(Self.interactionFailure(
                "not_yours_to_answer",
                "That card was raised in another conversation (\(sessionID)) than the one this turn is in, "
                + "so I won't answer it from here. Nothing was changed and the card still waits there.",
                extra: ["interaction_id": .string(id), "card_session_id": .string(sessionID)]
            ))
        }

        // Card writes share setting.set's fresh posture gate because they change Connectors, Trust or Providers.
        guard let posture = await Self.freshQuietPosture(dataRoot: dataRoot) else {
            return refuse(Self.interactionFailure(
                "trust_mode_unreadable",
                "The saved Trust policy does not say which mode this Mac is in, so nothing is "
                + "changed. The person can set the mode in Trust."
            ))
        }
        guard posture.changesAllowed else {
            return refuse(Self.interactionFailure(
                "trust_mode_read_only",
                "Answering a card is a write, and \(posture.name) is the posture that changes "
                + "nothing at all — the person's standing choice, and only they lift it.",
                extra: ["trust_mode": .string(posture.name)]
            ))
        }

        // Below Full Mac, macOS grants and capability raises wait for the user; decline remains available. Full Mac admits both.
        if action != "decline", posture.name != Self.fullMacModeName,
           current.kind == .permission || current.kind == .capability {
            return refuse(Self.interactionFailure(
                "owners_call",
                "\(current.kind == .permission ? "Granting Mac access" : "Turning on a Trust capability") is the owner's "
                + "call below Full Mac, and this Mac is in \(posture.name). Nothing was changed and the card still "
                + "waits for them: leave it for them. Not now still declines it.",
                extra: ["interaction_id": .string(id)]
            ))
        }

        let value = Self.interactionText(input["value"])
        let choice = Self.interactionText(input["choice"])
        // Declining any card grants nothing, including user-only cards.
        if action == "decline" {
            return .success(CardPlan(appModel: appModel, dataRoot: dataRoot, sessionID: sessionID, current: current,
                                     posture: posture, route: nil, value: value, choice: choice))
        }
        let descriptor = InlineInteractionResolver.descriptor(for: current, dataRoot: dataRoot)
        let route = Self.route(
            control: descriptor.control, interaction: current,
            descriptor: descriptor, value: value, choice: choice
        )
        if case .needsGlass(let reason) = route {
            return refuse(interactionReceipt(
                current, action: action, status: "needs_glass",
                posture: posture, surface: surface, dataRoot: dataRoot,
                extra: ["reason": .string(reason)]
            ))
        }

        // Re-read Full Mac after route resolution and before begin so a concurrent downgrade leaves the card pending.
        var effective = posture
        if let authority = Self.authorityMutation(route) {
            guard let fresh = await Self.freshQuietPosture(dataRoot: dataRoot) else {
                return refuse(Self.interactionFailure(
                    "trust_mode_unreadable",
                    "The saved Trust policy does not say which mode this Mac is in, so nothing is "
                    + "changed. The person can set the mode in Trust."
                ))
            }
            effective = fresh
            guard fresh.name == Self.fullMacModeName else {
                return refuse(interactionReceipt(
                    current, action: action, status: "needs_glass",
                    posture: fresh, surface: surface, dataRoot: dataRoot,
                    extra: ["reason": .string(
                        "\(authority) changes what the agent itself is allowed to do, and only "
                        + "Full Mac lets the agent make that call. This Mac is in \(fresh.name), "
                        + "so the person answers this card on the glass."
                    )]
                ))
            }
        }
        return .success(CardPlan(appModel: appModel, dataRoot: dataRoot, sessionID: sessionID, current: current,
                                 posture: effective, route: route, value: value, choice: choice))
    }

    /// cardGate checks precede execution; authority mutations recheck Full Mac at the write boundary.
    @MainActor
    func runCardAction(input: [String: JSONValue], surface: String, turn: Turn) async -> JSONValue {
        let plan: CardPlan
        switch await cardGate(input: input, surface: surface, turn: turn) {
        case .failure(let refusal): return refusal.answer
        case .success(let ready): plan = ready
        }
        let (appModel, dataRoot, sessionID, current) = (plan.appModel, plan.dataRoot, plan.sessionID, plan.current)
        let (value, choice) = (plan.value, plan.choice)
        let id = Self.cardID(input)
        let rawAction = Self.interactionText(input["action"]).lowercased()
        let action = rawAction.isEmpty ? "primary" : rawAction
        var effective = plan.posture
        guard let route = plan.route else {
            do {
                let declined = try await InlineInteractionResolver.decline(
                    id: id, sessionID: sessionID,
                    expectedRevision: current.revision, turn: turn, dataRoot: dataRoot
                )
                return interactionReceipt(
                    declined, action: action, status: "ok",
                    posture: effective, surface: surface, dataRoot: dataRoot,
                    extra: continuationExtra(id)
                )
            } catch {
                return Self.cardTransitionFailure("not_settled", error, id: id)
            }
        }

        // begin rejects stale revisions and dead controls so a second answer cannot execute twice.
        let began: InlineInteraction
        do {
            began = try await InlineInteractionResolver.begin(
                id: id, sessionID: sessionID,
                expectedRevision: current.revision, byAgent: true, dataRoot: dataRoot
            )
        } catch {
            return Self.cardTransitionFailure("not_begun", error, id: id)
        }

        // begin suspends for transcript I/O; recheck Full Mac synchronously before mutation and restore pending on a concurrent downgrade.
        if let authority = Self.authorityMutation(route) {
            let atMutation = await Self.freshQuietPosture(dataRoot: dataRoot)
            if atMutation?.name != Self.fullMacModeName {
                // If restoring pending loses a revision race, report the row that won rather than this call's stale running copy.
                let pending: InlineInteraction
                do {
                    pending = try await InlineInteractionResolver.returnToPending(
                        began, sessionID: sessionID, dataRoot: dataRoot
                    )
                } catch {
                    do {
                    guard let onDisk = try await InlineInteractionResolver.interaction(
                        id: id, sessionID: sessionID, dataRoot: dataRoot
                    ) else {
                        return Self.interactionFailure(
                            "not_reverted", error.localizedDescription,
                            extra: ["interaction_id": .string(id)]
                        )
                    }
                    pending = onDisk
                    } catch {
                        return Self.interactionFailure("card_unavailable", error.localizedDescription,
                            extra: ["interaction_id": .string(id)])
                    }
                }
                let reason = atMutation.map {
                    "\(authority) changes what the agent itself is allowed to do, and only Full "
                    + "Mac lets the agent make that call. This Mac is in \($0.name), so the "
                    + "person answers this card on the glass."
                } ?? (
                    "The saved Trust policy stopped saying which mode this Mac is in, so "
                    + "\(authority) was not changed. The person answers this card on the glass."
                )
                return interactionReceipt(
                    pending, action: action, status: "needs_glass",
                    posture: atMutation ?? effective, surface: surface, dataRoot: dataRoot,
                    extra: ["reason": .string(reason)]
                )
            }
            effective = atMutation ?? effective
        }

        var selection: String? = current.target
        var scope: InlineInteraction.Scope?
        // Provider setup supplies its safe reason class; grant failures are scrubbed by the shared credential redactor before settlement.
        var setupError: String?
        var note: String?
        var grant: InteractionGrantOutcome?
        switch route {
        case .permissionGrant:
            // cardGate already refused user-only kinds below Full Mac.
            grant = await grantInteractionPermissions(current, appModel: appModel, dataRoot: dataRoot)
            HarnessDecidedRow.post(turn: turn, requester: "Full Mac", tool: "card.answer \(current.kind.rawValue)",
                                   sessionID: sessionID, dataRoot: dataRoot)

        case .capabilityFlag:
            // The patch is the one field, and the Full Mac check is re-run inside the same locked generation the patch merges into.
            guard let flag = InlineInteractionRegistry.capabilityFlags[current.target],
                  Self.selfAdminCapabilityPolicyKeys.contains(flag.policyKey)
            else { break }
            grant = await Self.applyCapabilityFlagGrant(
                policyKey: flag.policyKey, appModel: appModel,
                dataRoot: dataRoot, logTag: "interaction_act"
            )
            HarnessDecidedRow.post(turn: turn, requester: "Full Mac", tool: "card.answer \(current.kind.rawValue)",
                                   sessionID: sessionID, dataRoot: dataRoot)

        case .providerKey:
            // Checked with the provider before it is saved, as the card does.
            let outcome = await appModel.saveProviderKey(
                value, provider: InlineInteractionRegistry.canonicalProviderID(current.target)
            )
            setupError = outcome.error
            note = outcome.note

        case .inlineSelection:
            selection = choice.isEmpty ? nil : choice
            if current.kind == .modelChoice { scope = current.primaryScope ?? .persistent }

        case .needsGlass:
            break
        }
        if let grant {
            setupError = grant.setupError
            note = grant.note
        }

        // Settlement uses the owner's answer and records that the agent, not a person, acted.
        do {
            let settled = try await InlineInteractionResolver.complete(
                id: id, sessionID: sessionID,
                selection: selection, scope: scope,
                // Settle only the revision this call acquired; a competing caller's revision must remain untouched.
                expectedRevision: began.revision,
                attribution: Self.authorityMutation(route) == nil
                    ? "Answered by the agent"
                    : "Allowed by the agent",
                setupError: setupError,
                note: note,
                byAgent: true, turn: turn, dataRoot: dataRoot
            )
            return interactionReceipt(
                settled, action: action,
                status: settled.state.failureReason == nil ? "ok" : "failed",
                posture: effective, surface: surface, dataRoot: dataRoot,
                extra: continuationExtra(id)
                    .merging(value.isEmpty ? [:] : ["value": .string("[redacted]")]) { a, _ in a }
                    .merging(grant.map { ["grant_outcome": $0.receipt] } ?? [:]) { a, _ in a }
            )
        } catch {
            return Self.interactionFailure(
                "not_settled", error.localizedDescription,
                extra: ["interaction_id": .string(id)]
                    .merging(grant.map { ["grant_outcome": $0.receipt] } ?? [:]) { a, _ in a }
            )
        }
    }

    /// One route table decides non-UI availability; execution must not independently reclassify controls.
    private static func route(
        control: InlineInteractionDescriptor.Control,
        interaction: InlineInteraction,
        descriptor: InlineInteractionDescriptor,
        value: String,
        choice: String
    ) -> InteractionControlRoute {
        switch control {
        case .internetAccounts:
            return .needsGlass("Connecting Mail is the person's tap on the card on the Mac. " + InlineCards.mailRoute)
        case .chromeSetup:
            return .needsGlass("Loading the extension happens in Chrome, with the person there.")
        case .pairDevice:
            return .needsGlass("Pairing needs the person's iPhone and the Pair button on the Mac.")
        case .connectorManualToken:
            let connector = InlineInteractionRegistry.canonicalConnectorID(interaction.target)
            // Slack's and Telegram's setup is a token PLUS their allowlists; there is no one-value write that means the same thing.
            return .needsGlass(
                "\(connector)'s setup takes more than one token — it has to be done in "
                + "Connectors on the glass."
            )
        case .macPermissionGrant:
            if interaction.allTargets.contains(where: { InlineInteractionRegistry.isMacControlCategory($0) || SystemPermissionPreflight.cardSettingsCapability(
                $0) != nil }) {
                return .needsGlass("Allowing Mac control is the owner's choice. Use the permission card on the Mac.")
            }
            return .permissionGrant
        case .trustPostureRequired:
            return .needsGlass(
                "The Trust posture is the person's own standing choice; nothing but Trust changes it."
            )
        case .capabilityFlag:
            return .capabilityFlag
        case .keyring:
            return .needsGlass("A secret goes from the person's card into the keyring, never through you: they paste it or sign in on the Mac.")
        case .providerAPIKey:
            guard !value.isEmpty else {
                return .needsGlass(
                    "Pass the \(descriptor.displayName) API key as `value`, or the person types "
                    + "it in Providers."
                )
            }
            return .providerKey
        case .providerGroupModel:
            guard !choice.isEmpty,
                  choice != InlineInteractionRegistry.persistentChoiceOptionID,
                  interaction.options.contains(where: { $0.id == choice })
            else {
                return .needsGlass(
                    "Changing the group's model for good is done in Providers. Pass `choice` with "
                    + "one of the card's option ids to use a model for this request only."
                )
            }
            return .inlineSelection
        case .inlineChoice:
            return .inlineSelection
        case .unavailable, .unknown:
            return .needsGlass("This build has no control for that card.")
        }
    }

    /// Evidence from the existing grant owners, carried into card settlement.
    public struct InteractionGrantOutcome: Sendable {
        public struct Failure: Sendable {
            public let target: String
            public let message: String
        }
        public var completedTargets: [String] = []
        public var failures: [Failure] = []

        mutating func failed(_ target: String, _ message: String) {
            failures.append(Failure(target: target, message: NativeAppSecretRedactor.redactText(message)))
        }
        var note: String? {
            completedTargets.isEmpty ? nil : "Grant writes completed: " + completedTargets.joined(separator: ", ") + "."
        }
        var setupError: String? {
            failures.isEmpty ? nil : (failures.map { $0.target + ": " + $0.message } + [note].compactMap { $0 }).joined(separator: " ")
        }
        var receipt: JSONValue {
            .object(["completed_targets": .array(completedTargets.map(JSONValue.string)),
                "failures": .array(failures.map { .object(["target": .string($0.target), "message": .string($0.message)]) })])
        }
    }

    /// Grant exactly the capabilities and axis requested through the same receipted owner as the card handler.
    @MainActor
    private func grantInteractionPermissions(
        _ interaction: InlineInteraction, appModel: any QuietSettingsHost, dataRoot: URL
    ) async -> InteractionGrantOutcome {
        let mode = interaction.mode
        var categories: [String] = []
        var outcome = InteractionGrantOutcome()
        for capability in interaction.allTargets {
            if InlineInteractionRegistry.isMacControlCategory(capability) {
                categories.append(capability)
                continue
            }
            guard MacIntegrationID.all.contains(capability) else { continue }
            do {
                _ = try await MacIntegrationPermissionStore.shared.setWithReceipt(
                    integrationId: capability,
                    read: MacIntegrationID.supportsRead(capability) && (mode?.wantsRead ?? true),
                    write: MacIntegrationID.supportsWrite(capability) && (mode?.wantsWrite ?? true),
                    actionID: "\(interaction.id)-\(capability)",
                    surface: "interaction_act",
                    // Agent grants must never use local human-tap provenance; name their originating card.
                    provenance: .agent(interactionID: interaction.id),
                    // Grant only the requested axis so the user's other choice survives.
                    onlyAddingAxes: true
                )
                outcome.completedTargets.append(capability)
            } catch {
                nativeLog("[interaction_act] grant failed for \(capability): \(error)")
                outcome.failed(capability, error.localizedDescription)
            }
        }
        let mac = await Self.applyMacControlCategoryGrant(
            categories, appModel: appModel, dataRoot: dataRoot, logTag: "interaction_act"
        )
        outcome.completedTargets += mac.completedTargets
        outcome.failures += mac.failures
        return outcome
    }

    /// Merge only named categories and their master gate under the policy lock; whole cached policies overwrite unrelated user changes.
    /// Recheck Full Mac inside that same lock for agent answers; user taps share this writer.
    @MainActor
    @discardableResult
    public static func applyMacControlCategoryGrant(
        _ categories: [String], appModel: any QuietSettingsHost, dataRoot: URL, logTag: String
    ) async -> InteractionGrantOutcome {
        var outcome = InteractionGrantOutcome()
        guard !categories.isEmpty else { return outcome }
        let posturePermits: Bool
        do { posturePermits = try InlineInteractionRegistry.macControlPostureAllowsCategories(dataRoot: dataRoot) }
        catch {
            for category in categories { outcome.failed(category, error.localizedDescription) }
            return outcome
        }
        guard posturePermits else {
            nativeLog("[\(logTag)] mac control grant refused: posture does not allow categories")
            for category in categories { outcome.failed(category, "The current posture does not allow Mac control categories.") }
            return outcome
        }
        var block: [String: Any] = ["enabled": true]
        var granted: [String] = []
        for category in categories {
            guard InlineInteractionRegistry.isMacControlCategory(category) else { continue }
            block[categoryPolicyKey(category)] = true
            granted.append(category)
        }
        guard block.count > 1 else { return outcome }
        do {
            let saved = try await TrustPolicyToolWriter.applyTrustPolicyPatch(
                body: ["macControlPolicy": block],
                dataRoot: dataRoot,
                guardedByLockedPolicy: { locked in
                    guard Self.lockedPolicyIsFullMac(locked) else {
                        throw QuietSettingError.unavailable(
                            "This Mac is no longer in Full Mac, so Mac control was not changed.")
                    }
                }
            )
            appModel.applySavedTrustPolicy(saved, status: "Mac control policy saved")
            outcome.completedTargets = granted
        } catch {
            nativeLog("[\(logTag)] mac control grant failed: \(error)")
            for category in granted { outcome.failed(category, error.localizedDescription) }
        }
        return outcome
    }

    /// Merge only the named multimodal field and recheck Full Mac inside the policy lock; cached whole blocks overwrite unrelated choices.
    @MainActor
    /// Only agent answers require Full Mac; a person's tap retains the authority of the matching Trust switch.
    @discardableResult
    public static func applyCapabilityFlagGrant(
        policyKey: String, appModel: any QuietSettingsHost, dataRoot: URL, logTag: String,
        requireFullMac: Bool = true
    ) async -> InteractionGrantOutcome {
        var outcome = InteractionGrantOutcome()
        do {
            let saved = try await TrustPolicyToolWriter.applyTrustPolicyPatch(
                body: ["multimodalPolicy": [policyKey: true]],
                dataRoot: dataRoot,
                guardedByLockedPolicy: { locked in
                    guard !requireFullMac || Self.lockedPolicyIsFullMac(locked) else {
                        throw QuietSettingError.unavailable(
                            "This Mac is no longer in Full Mac, so the capability was "
                            + "not turned on.")
                    }
                }
            )
            appModel.applySavedTrustPolicy(saved, status: "Multimodal policy saved")
            outcome.completedTargets.append(policyKey)
        } catch {
            nativeLog("[\(logTag)] capability flag write failed for \(policyKey): \(error)")
            outcome.failed(policyKey, error.localizedDescription)
        }
        return outcome
    }

    /// Return the continuation to the answering turn so one transcript never runs two turns.
    /// Absence means ordinary continuation admission handled a card settled outside a turn.
    @MainActor
    private func continuationExtra(_ id: String) -> [String: JSONValue] {
        guard let carried = InlineInteractionResolver.takeContinuationHandBack(id: id)
        else { return [:] }
        return [
            "continuation": .string(carried),
            "continuation_note": .string(
                "Carry on in THIS reply. No second turn was started for this card."),
        ]
    }

    // MARK: - The app's own composer

    @MainActor
    func composerRead(sessionId: String, turn: Turn) async -> JSONValue {
        guard let appModel = quietHost() else {
            return ChatToolOutcome.refusedBeforeRunning(Self.interactionFailure(
                "app_window_unavailable",
                "The app's own composer is not available in this process."
            ))
        }
        var body = await appModel.composerState(sessionId: sessionId, turn: turn)
        if body["status"] == nil { body["status"] = .string("ok") }
        body["target"] = .string("composer")
        body["verb"] = .string("read")
        body["note"] = .string(
            "Read from the live composer's own state in process — no accessibility round "
            + "trip, and nothing was brought forward or clicked.")
        return .object(body)
    }

    /// Composer actions re-read posture for receipts and attachment fences; app-owned screen, sound and user-draft fences still apply.
    @MainActor
    func runComposerAction(
        verb: String, input: [String: JSONValue], surface: String, host appModel: any QuietToolHost, turn: Turn
    ) async -> JSONValue {
        let sessionId = Self.interactionText(input["session_id"])
        let posture: QuietPosture?
        let attachments: [URL]
        switch await composerGate(verb: verb, input: input, host: appModel, turn: turn) {
        case .failure(let refusal): return refusal.answer
        case .success(let ready): (posture, attachments) = ready
        }
        let reachesUser: Bool
        do { reachesUser = try await Self.reachesUser(surface: surface, fullMac: posture?.name == Self.fullMacModeName,
                                               dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot(), turn: turn) }
        catch { return ChatToolOutcome.failure(error: error, tool: "interaction_act", effects: ToolFailureError.Effects.none) }
        let outcome = await appModel.runComposer(
            verb: verb,
            value: Self.interactionText(input["value"]),
            choice: Self.interactionText(input["choice"]),
            sessionId: sessionId,
            attachments: attachments,
            reachesUser: reachesUser,
            turnSessionId: Self.interactionText(input["__session_id"]), turn: turn
        )
        if let refusal = Self.composerFailure(outcome, verb: verb) { return refusal }
        // Receipt state comes from the live composer owner so tool results agree with chat page reads.
        var body = await appModel.composerState(sessionId: sessionId, turn: turn)
        body["status"] = .string(outcome.status)
        body["target"] = .string("composer")
        body["verb"] = .string(verb)
        body["element"] = .string(outcome.element)
        body["changed"] = .bool(outcome.changed)
        body["detail"] = .string(outcome.detail)
        if verb == "set_page", let page = presentation.currentPage {
            body["showing_page"] = .string(page.id)
        }
        if let posture { body["trust_mode"] = .string(posture.name) }
        body["surface"] = .string(surface)
        body["decided_by"] = .string("agent")
        body["note"] = .string(
            "Worked in process through the same action the composer's own control takes, so the "
            + "window shows it now. No accessibility round trip, nothing brought forward, and no "
            + "click was synthesized.")
        return .object(body)
    }

    /// Preview shares read-only posture, file, screen, sound and draft checks with execution's app-owned fences.
    @MainActor
    func composerRefusal(verb: String, input: [String: JSONValue], surface: String, host: any QuietToolHost, turn: Turn) async -> JSONValue? {
        let posture: QuietPosture?
        switch await composerGate(verb: verb, input: input, host: host, turn: turn) {
        case .failure(let refusal): return refusal.answer
        case .success(let ready): posture = ready.0
        }
        let reachesUser: Bool
        do { reachesUser = try await Self.reachesUser(surface: surface, fullMac: posture?.name == Self.fullMacModeName,
                                               dataRoot: host.dataRootOverride ?? PersistenceCore.defaultDataRoot(), turn: turn) }
        catch { return ChatToolOutcome.failure(error: error, tool: "interaction_act", effects: ToolFailureError.Effects.none) }
        return host.composerFence(
            verb: verb, value: Self.interactionText(input["value"]), sessionId: Self.interactionText(input["session_id"]),
            reachesUser: reachesUser,
            turnSessionId: Self.interactionText(input["__session_id"]), turn: turn
        ).flatMap { Self.composerFailure($0, verb: verb) }
    }

    /// check_updates needs no posture; other composer calls carry checked posture and fenced attachments.
    @MainActor
    private func composerGate(
        verb: String, input: [String: JSONValue], host: any QuietToolHost, turn: Turn
    ) async -> Result<(QuietPosture?, [URL]), GateRefusal> {
        let dataRoot = host.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        var posture: QuietPosture?
        if verb != "check_updates" {
            guard let fresh = await Self.freshQuietPosture(dataRoot: dataRoot) else {
                return .failure(GateRefusal(answer: Self.interactionFailure(
                    "trust_mode_unreadable",
                    "The saved Trust policy does not say which mode this Mac is in, so nothing is "
                    + "changed. The person can set the mode in Trust."
                )))
            }
            guard fresh.changesAllowed else {
                return .failure(GateRefusal(answer: Self.interactionFailure(
                    "trust_mode_read_only",
                    "Working the composer is a write, and \(fresh.name) is the posture that changes "
                    + "nothing at all — the person's standing choice, and only they lift it.",
                    extra: ["trust_mode": .string(fresh.name)]
                )))
            }
            posture = fresh
        }
        var attachments: [URL] = []
        for raw in Self.attachmentPaths(input["attachments"]) {
            switch await SwiftNativeSecurityCenter.fencedAttachment(raw, dataRoot: dataRoot, turn: turn) {
            case .success(let file): attachments.append(file)
            case .failure(let refusal):
                return .failure(GateRefusal(answer: Self.interactionFailure(
                    refusal.reason, refusal.detail,
                    extra: ["target": .string("composer"), "verb": .string(verb), "attachment": .string(raw)]
                )))
            }
        }
        return .success((posture, attachments))
    }

    private static func composerFailure(_ outcome: QuietComposerOutcome, verb: String) -> JSONValue? {
        outcome.refusal.map { refusal in
            interactionFailure(
                refusal.reason, refusal.detail,
                extra: [
                    "target": .string("composer"),
                    "verb": .string(verb),
                    "element": .string(outcome.element),
                    "effects": .string(refusal.effects.rawValue),
                    "remedy": outcome.remedy ?? .null,
                ]
            )
        }
    }

    private static func attachmentPaths(_ value: JSONValue?) -> [String] {
        switch value {
        case .string(let one)?: return [one].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        case .array(let many)?: return many.map(interactionText).filter { !$0.isEmpty }
        default: return []
        }
    }

    // MARK: - Answers

    /// Only begin/decline's typed rejections precede their transcript write.
    private static func cardTransitionFailure(_ reason: String, _ error: Error, id: String) -> JSONValue {
        let result = interactionFailure(reason, error.localizedDescription, extra: ["interaction_id": .string(id)])
        return error is InlineInteractionResolver.ResolveError ? ChatToolOutcome.refusedBeforeRunning(result) : result
    }

    private static func interactionFailure(
        _ reason: String, _ detail: String, extra: [String: JSONValue] = [:]
    ) -> JSONValue {
        var body: [String: JSONValue] = [
            "status": .string("failed"),
            "reason": .string(reason),
            "detail": .string(detail),
        ]
        // The code, status and detail stand: extra never overwrites them.
        body.merge(extra) { own, _ in own }
        return .object(body)
    }

    /// The tool answer and scrollback share the settled row's resultSummary so they cannot disagree.
    @MainActor
    private func interactionReceipt(
        _ interaction: InlineInteraction,
        action: String,
        status: String,
        posture: QuietPosture,
        surface: String,
        dataRoot: URL,
        extra: [String: JSONValue] = [:]
    ) -> JSONValue {
        let descriptor = InlineInteractionResolver.descriptor(
            for: interaction, dataRoot: dataRoot
        )
        let card = InlineCards.model(interaction, descriptor: descriptor)
        var body: [String: JSONValue] = [
            "status": .string(status),
            "interaction_id": .string(interaction.id),
            "action": .string(action),
            "card": .object([
                "title": .string(card.title),
                "state": .string(card.state.rawValue),
                "why": .string(card.why),
                "primary": .string(card.primaryLabel),
                "secondary": .string(card.secondaryLabel),
                "scope_lines": .array(card.scopeLines.map { .string($0) }),
                "outcome": card.outcome.map { JSONValue.string($0) } ?? .null,
                "outcome_meta": card.outcomeMeta.map { JSONValue.string($0) } ?? .null,
                "can_retry": .bool(card.canRetry),
                "revision": .int(Int64(interaction.revision)),
            ]),
            "receipt": InlineInteractionResolver.receiptEnvelope(interaction),
            "trust_mode": .string(posture.name),
            "surface": .string(surface),
            // Not a human tap, and it never reads as one.
            "decided_by": .string("agent"),
            "note": .string(
                "Resolved through the same InlineInteractionResolver path a tap takes — the "
                + "control's owner was re-asked, and nothing was brought forward or clicked."),
        ]
        for (key, value) in extra { body[key] = value }
        return .object(body)
    }
}
