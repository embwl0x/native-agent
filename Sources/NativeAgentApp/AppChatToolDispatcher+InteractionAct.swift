import ChatOrchestration
import Dispatcher
import Foundation
import MacIntegration
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TrustCenter

/// Answering an inline card without a hand on the trackpad.
///
/// A card is a question the app asked in the middle of a conversation. On the
/// Mac it is answered by tapping it, and `InlineInteractionChatBinding` turns
/// that tap into three steps: mark the row running, OPEN THE CONTROL that
/// already owns the thing, then ask that control's owner whether it is now
/// done. This tool is the same three steps with the middle one taken through
/// the control's non-UI path — Connectors' own token write, the receipted
/// permission store, `saveMultimodalPolicy`, the model override binding —
/// instead of through a sheet.
///
/// What it deliberately does NOT do:
///
///  * **It never opens a window.** No `NativeAgentAppCoordinator.request`, no
///    sheet, no activate. A control that IS a page or a browser handoff
///    (Trust posture, OAuth, Providers' group picker) has no honest non-UI
///    path, so the answer is `needs_glass` with the reason — never a silent
///    half-grant.
///  * **It never becomes the authority.** `complete` re-reads the owner, the
///    same as a tap does, so a bad token FAILS the card in the connector's own
///    words and leaves the retry intact.
///  * **It never answers for someone else.** A card raised in a conversation
///    that came from the phone or Telegram belongs to that person; the tool
///    refuses it rather than settling a question it was not asked.
extension AppChatToolDispatcher {

    /// Which controls can be worked without a window, and how.
    private enum InteractionControlRoute {
        case connectorToken(connector: String)
        case permissionGrant
        case capabilityFlag
        case providerKey
        case inlineSelection
        /// The control is a page, a sheet or a browser handoff.
        case needsGlass(String)
    }

    /// Remote, decided the fail-CLOSED way.
    ///
    /// `ConversationSurfaceProfile.isRemote` is a denylist, so a surface it has
    /// never heard of reads as LOCAL — and a surface nobody has thought of yet
    /// is exactly the class that must not be trusted with someone else's card.
    /// So the question is inverted, the same way `ActivityQuery` inverted it:
    /// name the lanes that are this Mac, and refuse everything else, including
    /// what is added tomorrow.
    ///
    /// The app's own loopback bridges are on the list. They are this machine,
    /// token-authenticated, and they are how the agent reaches its own app at
    /// all — they raise these cards and they answer them.
    private static let localOriginSurfaceIDs: Set<String> = [
        "chat",             // the Mac chat window
        "mac", "app",       // in-process Mac surfaces (what the row records)
        "observatory",      // local inspector UI
        "claude-bridge", "claude_bridge",
        "codex-bridge", "codex_bridge",
        "",                 // unset/in-process default
    ]

    private static func isRemoteOrigin(_ envelope: TurnEnvelope) -> Bool {
        if envelope.declaredRemote == true { return true }
        if ConversationSurfaceProfile(envelope.surface).isRemote { return true }
        return !localOriginSurfaceIDs.contains(ConversationSurfaceProfile(envelope.surface).id)
    }

    /// The card and this caller are the same person.
    ///
    /// Surface NAMES are not compared: the row records the persistence-side
    /// surface ("app") while the caller carries the transport-side one
    /// ("claude-bridge"), so comparing the two strings would refuse every
    /// honest call. What is compared is the identity the TRANSPORT vouched
    /// for — where either side recorded one, both must, and they must match.
    private static func sameOriginLane(card: TurnEnvelope, caller: TurnEnvelope) -> Bool {
        card.verifiedChatId == caller.verifiedChatId
            && card.verifiedUserId == caller.verifiedUserId
    }

    /// The authority this route moves, named for the refusal — or nil when the
    /// route changes nothing about what the agent is allowed to do.
    /// The capability flags a card may turn on, spelled as the saved policy
    /// spells them. A key not on this list is not written at all.
    private static let selfAdminCapabilityPolicyKeys: Set<String> = [
        "image_generation_openai", "screen_capture", "vision_api_calls", "tts_openai",
    ]

    private static func authorityMutation(_ route: InteractionControlRoute) -> String? {
        switch route {
        case .connectorToken: return "Writing a connector's token"
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

    @MainActor
    func runInteractionAct(input: [String: JSONValue], surface: String) async -> JSONValue {
        // The app's OWN window, worked in process.
        //
        // Reaching our own UI over accessibility deadlocks the turn that is
        // asking (in-process AppKit re-entry on the main thread), so that
        // refusal stands for everything not named here. What is named here
        // never goes near AX: each verb calls the same entry point the visible
        // control calls when a person clicks it.
        let target = Self.interactionText(input["target"]).lowercased()
        if !target.isEmpty {
            guard target == "composer" else {
                return Self.interactionFailure(
                    "self_inspection_unsupported",
                    "This app's own window can only be worked through the in-process composer "
                    + "verbs — reading or clicking our own UI over accessibility deadlocks the "
                    + "turn asking for it. target=composer covers: "
                    + QuietComposerVerbs.names.joined(separator: ", ")
                    + ". Everything else on our own window stays refused; use app_page_read, "
                    + "app_settings_list and app_setting_set for the rest.",
                    extra: [
                        "requested_target": .string(target),
                        "targets": .array([.string("composer")]),
                        "verbs": .array(QuietComposerVerbs.names.map { .string($0) }),
                    ]
                )
            }
            return await runComposerVerb(input: input, surface: surface)
        }

        let id = Self.interactionText(input["interaction_id"])
        guard !id.isEmpty else {
            return Self.interactionFailure(
                "missing_interaction_id",
                "Name the card. app_page_read page=chat lists each one's interaction id."
            )
        }
        let rawAction = Self.interactionText(input["action"]).lowercased()
        let action = rawAction.isEmpty ? "primary" : rawAction
        guard ["primary", "decline", "retry"].contains(action) else {
            return Self.interactionFailure(
                "unknown_action", "action is primary, decline or retry.",
                extra: ["requested": .string(rawAction)]
            )
        }
        guard let appModel = QuietSelfAdmin.shared.appModel else {
            return Self.interactionFailure(
                "app_window_unavailable",
                "The app's own controls are not available in this process."
            )
        }
        let dataRoot = appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let sessionID = appModel.activeChatSessionId
        guard !sessionID.isEmpty else {
            return Self.interactionFailure("no_conversation", "No conversation is open.")
        }
        guard let current = await InlineInteractionResolver.interaction(
            id: id, sessionID: sessionID, dataRoot: dataRoot
        ) else {
            return Self.interactionFailure(
                "not_found",
                "No card with that id is in the open conversation.",
                extra: ["interaction_id": .string(id)]
            )
        }

        // Whose question this is, and whether THIS caller is the one it was
        // asked of. Two origins, and both have to answer.
        //
        // The card's origin is the envelope on the row that raised it. A
        // missing one used to default to "chat", which is the permissive
        // answer to "I can't tell" — exactly the wrong way for unverifiable
        // provenance to fail. It now refuses.
        //
        // The caller's origin was never asked at all: only the CARD was
        // checked for remoteness, so a Telegram or iPhone turn could settle a
        // question asked of the person at the Mac window. Both sides must be
        // local, decided by allowlist, and the transport-verified chat and
        // person must agree where either side recorded one.
        guard let cardOrigin = await InlineInteractionResolver.originEnvelope(
            of: id, sessionID: sessionID, dataRoot: dataRoot
        ), !cardOrigin.surface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Self.interactionFailure(
                "origin_unverifiable",
                "I can't tell whose card this is — the row that raised it records no origin, so "
                + "I won't settle it. The person can answer it in the app.",
                extra: ["interaction_id": .string(id)]
            )
        }
        let caller = TurnEnvelope.current(surface: surface)
        if Self.isRemoteOrigin(cardOrigin) {
            return Self.interactionFailure(
                "not_yours_to_answer",
                "That card was raised from \(cardOrigin.surface) — it's the person "
                + "on that surface who was asked, so it isn't mine to answer.",
                extra: [
                    "interaction_id": .string(id),
                    "origin_surface": .string(cardOrigin.surface),
                ]
            )
        }
        if Self.isRemoteOrigin(caller) {
            return Self.interactionFailure(
                "not_yours_to_answer",
                "This turn came in from \(caller.surface), and the card was raised in the app "
                + "here — answering it from there would settle a question I wasn't asked.",
                extra: [
                    "interaction_id": .string(id),
                    "origin_surface": .string(cardOrigin.surface),
                    "caller_surface": .string(caller.surface),
                ]
            )
        }
        guard Self.sameOriginLane(card: cardOrigin, caller: caller) else {
            return Self.interactionFailure(
                "not_yours_to_answer",
                "That card belongs to a different conversation lane than this turn, so it isn't "
                + "mine to answer from here.",
                extra: [
                    "interaction_id": .string(id),
                    "origin_surface": .string(cardOrigin.surface),
                    "caller_surface": .string(caller.surface),
                ]
            )
        }
        // The session this turn was VERIFIED to be in, where the transport
        // named one. The card was found in the window's active session, which
        // is a different question from the one this caller is speaking in.
        if let verifiedSession = ChatToolSessionContext.verifiedSessionId?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !verifiedSession.isEmpty, verifiedSession != sessionID {
            return Self.interactionFailure(
                "not_yours_to_answer",
                "This turn is verified in another conversation, and the card is in the one open "
                + "here. I won't answer across the two.",
                extra: ["interaction_id": .string(id)]
            )
        }

        // The same posture gate app_setting_set stands behind, read the same
        // fresh way: answering a card writes to Connectors, Trust or Providers.
        guard let posture = await Self.freshQuietPosture(dataRoot: dataRoot) else {
            return Self.interactionFailure(
                "trust_mode_unreadable",
                "The saved Trust policy does not say which mode this Mac is in, so nothing is "
                + "changed. The person can set the mode in Trust."
            )
        }
        guard posture.changesAllowed else {
            return Self.interactionFailure(
                "trust_mode_read_only",
                "Answering a card is a write, and \(posture.name) is the posture that changes "
                + "nothing at all — the person's standing choice, and only they lift it.",
                extra: ["trust_mode": .string(posture.name)]
            )
        }

        if action == "decline" {
            do {
                let declined = try await InlineInteractionResolver.decline(
                    id: id, sessionID: sessionID,
                    expectedRevision: current.revision, dataRoot: dataRoot
                )
                return Self.interactionReceipt(
                    declined, action: action, status: "ok",
                    posture: posture, surface: surface, dataRoot: dataRoot,
                    extra: Self.continuationExtra(id)
                )
            } catch {
                return Self.interactionFailure(
                    "not_settled", error.localizedDescription,
                    extra: ["interaction_id": .string(id)]
                )
            }
        }

        let descriptor = InlineInteractionResolver.descriptor(for: current, dataRoot: dataRoot)
        let value = Self.interactionText(input["value"])
        let choice = Self.interactionText(input["choice"])
        let route = Self.route(
            control: descriptor.control, interaction: current,
            descriptor: descriptor, value: value, choice: choice
        )
        if case .needsGlass(let reason) = route {
            return Self.interactionReceipt(
                current, action: action, status: "needs_glass",
                posture: posture, surface: surface, dataRoot: dataRoot,
                extra: ["reason": .string(reason)]
            )
        }

        // A card that moves AUTHORITY — what the agent may reach, which keys it
        // holds — is Full Mac's alone, and Full Mac has to be true right now.
        //
        // The posture above was read before the route was known and before the
        // card was touched; this is a second CHECKED read of the saved policy,
        // taken immediately before the mutation, so a posture dropped to
        // Builder in another window in between is seen. Builder answers cards,
        // but it never grants the agent more reach than it already has.
        // Decided BEFORE `begin`, so a refusal leaves the card pending rather
        // than stranded mid-flight.
        var effective = posture
        if let authority = Self.authorityMutation(route) {
            guard let fresh = await Self.freshQuietPosture(dataRoot: dataRoot) else {
                return Self.interactionFailure(
                    "trust_mode_unreadable",
                    "The saved Trust policy does not say which mode this Mac is in, so nothing is "
                    + "changed. The person can set the mode in Trust."
                )
            }
            effective = fresh
            guard fresh.name == Self.fullMacModeName else {
                return Self.interactionReceipt(
                    current, action: action, status: "needs_glass",
                    posture: fresh, surface: surface, dataRoot: dataRoot,
                    extra: ["reason": .string(
                        "\(authority) changes what the agent itself is allowed to do, and only "
                        + "Full Mac lets the agent make that call. This Mac is in \(fresh.name), "
                        + "so the person answers this card on the glass."
                    )]
                )
            }
        }

        // Mark it running, exactly as a tap does. This refuses a stale revision
        // and a dead control, which is what makes a second call safe.
        let began: InlineInteraction
        do {
            began = try await InlineInteractionResolver.begin(
                id: id, sessionID: sessionID,
                expectedRevision: current.revision, dataRoot: dataRoot
            )
        } catch {
            return Self.interactionFailure(
                "not_begun", error.localizedDescription,
                extra: ["interaction_id": .string(id)]
            )
        }

        // `begin` is transcript I/O, and the Full Mac check above ran before
        // it. A posture dropped to Builder during that write would otherwise
        // still get the authority change through, because the decision was
        // already made. So the policy is read once more HERE, with nothing
        // awaited between it and the mutation, and a card that no longer
        // qualifies is put back to pending — answerable by the person — rather
        // than left running with nobody running it.
        if let authority = Self.authorityMutation(route) {
            let atMutation = await Self.freshQuietPosture(dataRoot: dataRoot)
            if atMutation?.name != Self.fullMacModeName {
                // `began` is this call's own local `.running` copy. When the
                // revert loses, that copy is a fiction — the row on disk is
                // something else — so the receipt reports the row that won,
                // never the state this process wished for.
                let pending: InlineInteraction
                do {
                    pending = try await InlineInteractionResolver.returnToPending(
                        began, sessionID: sessionID, dataRoot: dataRoot
                    )
                } catch {
                    guard let onDisk = await InlineInteractionResolver.interaction(
                        id: id, sessionID: sessionID, dataRoot: dataRoot
                    ) else {
                        return Self.interactionFailure(
                            "not_reverted", error.localizedDescription,
                            extra: ["interaction_id": .string(id)]
                        )
                    }
                    pending = onDisk
                }
                let reason = atMutation.map {
                    "\(authority) changes what the agent itself is allowed to do, and only Full "
                    + "Mac lets the agent make that call. This Mac is in \($0.name), so the "
                    + "person answers this card on the glass."
                } ?? (
                    "The saved Trust policy stopped saying which mode this Mac is in, so "
                    + "\(authority) was not changed. The person answers this card on the glass."
                )
                return Self.interactionReceipt(
                    pending, action: action, status: "needs_glass",
                    posture: atMutation ?? effective, surface: surface, dataRoot: dataRoot,
                    extra: ["reason": .string(reason)]
                )
            }
            effective = atMutation ?? effective
        }

        var selection: String? = current.target
        var scope: InlineInteraction.Scope?
        switch route {
        case .connectorToken(let connector):
            // The connector's own writer, which validates with the service
            // before it saves. A rejected token writes nothing, so the
            // resolver's re-read fails the card in the connector's own words.
            let result: OAuthFlowResult
            switch connector {
            case "notion": result = await NativeOAuthFlow.saveNotionToken(value, dataRoot: dataRoot)
            case "github": result = await NativeOAuthFlow.saveGitHubToken(value, dataRoot: dataRoot)
            default: result = OAuthFlowResult(ok: false, error: "No token route for \(connector).")
            }
            if !result.ok {
                NSLog("[interaction_act] \(connector) token rejected: \(result.error ?? "")")
            }
            selection = connector

        case .permissionGrant:
            await grantInteractionPermissions(current, appModel: appModel, dataRoot: dataRoot)

        case .capabilityFlag:
            // The Full Mac check above ran before `begin`'s transcript I/O,
            // and the old write then sent back the WHOLE cached multimodal
            // block — so a posture the person lowered in the meantime still
            // got the flag through, and any other switch they flipped since
            // the cache was read was overwritten with the stale value. The
            // patch is the one field, and the Full Mac check is re-run inside
            // the same locked generation the patch merges into.
            guard let flag = InlineInteractionRegistry.capabilityFlags[current.target],
                  Self.selfAdminCapabilityPolicyKeys.contains(flag.policyKey)
            else { break }
            await Self.applyCapabilityFlagGrant(
                policyKey: flag.policyKey, appModel: appModel,
                dataRoot: dataRoot, logTag: "interaction_act"
            )

        case .providerKey:
            _ = try? await appModel.configureProvider(
                current.target, apiKey: value, authMode: "api_key", defaultModel: nil
            )

        case .inlineSelection:
            selection = choice.isEmpty ? nil : choice
            if current.kind == .modelChoice { scope = current.primaryScope ?? .persistent }

        case .needsGlass:
            break
        }

        // The owner's answer, not ours — carrying, on the settled card's own
        // receipt line, the fact that nobody tapped it.
        do {
            let settled = try await InlineInteractionResolver.complete(
                id: id, sessionID: sessionID,
                selection: selection, scope: scope,
                // The revision THIS call acquired when it marked the card
                // running. A second caller that got in between settles
                // nothing: the compare refuses it instead of settling a card
                // this call no longer owns.
                expectedRevision: began.revision,
                attribution: Self.authorityMutation(route) == nil
                    ? "Answered by the agent"
                    : "Allowed by the agent",
                dataRoot: dataRoot
            )
            return Self.interactionReceipt(
                settled, action: action,
                status: settled.state.failureReason == nil ? "ok" : "failed",
                posture: effective, surface: surface, dataRoot: dataRoot,
                extra: Self.continuationExtra(id)
                    .merging(value.isEmpty ? [:] : ["value": .string("[redacted]")]) { a, _ in a }
            )
        } catch {
            return Self.interactionFailure(
                "not_settled", error.localizedDescription,
                extra: ["interaction_id": .string(id)]
            )
        }
    }

    /// Which of the card's controls has a non-UI path, and what to say when it
    /// does not. The one table; the switch above never re-decides it.
    private static func route(
        control: InlineInteractionDescriptor.Control,
        interaction: InlineInteraction,
        descriptor: InlineInteractionDescriptor,
        value: String,
        choice: String
    ) -> InteractionControlRoute {
        switch control {
        case .internetAccounts:
            return .needsGlass("Add and enable a Mail account in Internet Accounts on the Mac.")
        case .connectorManualToken:
            let connector = InlineInteractionRegistry.canonicalConnectorID(interaction.target)
            // Slack's setup is a token PLUS its channel/user allowlists; there
            // is no one-value write that means the same thing.
            guard ["notion", "github"].contains(connector) else {
                return .needsGlass(
                    "\(connector)'s setup takes more than one token — it has to be done in "
                    + "Connectors on the glass."
                )
            }
            // Decided BEFORE the card is marked running: a missing token has
            // to leave it pending, not stranded mid-flight.
            guard !value.isEmpty else {
                return .needsGlass(
                    "Pass the \(descriptor.displayName) token as `value`, or the person pastes "
                    + "it in Connectors."
                )
            }
            return .connectorToken(connector: connector)
        case .connectorOAuth:
            return .needsGlass(
                "Signing in to \(interaction.target) happens in a browser, with the person there."
            )
        case .macPermissionGrant:
            return .permissionGrant
        case .trustPostureRequired:
            return .needsGlass(
                "The Trust posture is the person's own standing choice; nothing but Trust changes it."
            )
        case .capabilityFlag:
            return .capabilityFlag
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

    /// The same receipted grant the card's own handler makes, capability by
    /// capability, on exactly the axis the need asked for.
    @MainActor
    private func grantInteractionPermissions(
        _ interaction: InlineInteraction, appModel: AppModel, dataRoot: URL
    ) async {
        let mode = interaction.mode
        var categories: [String] = []
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
                    // Never `.local()`: nobody tapped this. The receipt says
                    // the agent allowed it, and names the card it came from.
                    provenance: .agent(interactionID: interaction.id),
                    // One axis asked for, one axis granted; the other keeps
                    // whatever the person already decided about it.
                    onlyAddingAxes: true
                )
            } catch {
                NSLog("[interaction_act] grant failed for \(capability): \(error)")
            }
        }
        await Self.applyMacControlCategoryGrant(
            categories, appModel: appModel, dataRoot: dataRoot, logTag: "interaction_act"
        )
    }

    /// The ONE Mac-control write either grant path makes: exactly the
    /// categories the card named, plus the master gate they hang off, merged
    /// into the locked generation. A write that submits the whole CACHED policy
    /// block stomps every unrelated verb the person changed since that cache
    /// was read — and, being an authority mutation, lands even if the posture
    /// was lowered after the check — so the person's tap
    /// (`InlineInteractionChatBinding`) comes through here too, and the Full
    /// Mac check is re-run inside the lock the patch merges into.
    @MainActor
    static func applyMacControlCategoryGrant(
        _ categories: [String], appModel: AppModel, dataRoot: URL, logTag: String
    ) async {
        guard !categories.isEmpty else { return }
        guard InlineInteractionRegistry.macControlPostureAllowsCategories(dataRoot: dataRoot) else {
            NSLog("[\(logTag)] mac control grant refused: posture does not allow categories")
            return
        }
        var block: [String: Any] = ["enabled": true]
        for category in categories {
            switch category {
            case "shell": block["shell_allowed"] = true
            case "file_ops": block["file_ops_allowed"] = true
            case "applescript": block["applescript_allowed"] = true
            case "jxa": block["jxa_allowed"] = true
            case "accessibility": block["accessibility_allowed"] = true
            case "system": block["system_control_allowed"] = true
            case "notifications": block["notifications_allowed"] = true
            case "spotlight": block["spotlight_allowed"] = true
            default: continue
            }
        }
        guard block.count > 1 else { return }
        do {
            let saved = try await NativeClient.applyTrustPolicyPatch(
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
        } catch {
            NSLog("[\(logTag)] mac control grant failed: \(error)")
        }
    }

    /// The ONE multimodal-capability write either grant path makes: the single
    /// field the card named, merged into the locked generation with the Full
    /// Mac check re-run inside that lock. Same reason as the Mac-control
    /// helper — a whole cached block overwrites switches nobody touched.
    @MainActor
    static func applyCapabilityFlagGrant(
        policyKey: String, appModel: AppModel, dataRoot: URL, logTag: String
    ) async {
        do {
            let saved = try await NativeClient.applyTrustPolicyPatch(
                body: ["multimodalPolicy": [policyKey: true]],
                dataRoot: dataRoot,
                guardedByLockedPolicy: { locked in
                    guard Self.lockedPolicyIsFullMac(locked) else {
                        throw QuietSettingError.unavailable(
                            "This Mac is no longer in Full Mac, so the capability was "
                            + "not turned on.")
                    }
                }
            )
            appModel.applySavedTrustPolicy(saved, status: "Multimodal policy saved")
        } catch {
            // The resolver re-reads the owner, so a refused write fails the
            // card in the owner's own words rather than settling it.
            NSLog("[\(logTag)] capability flag write failed for \(policyKey): \(error)")
        }
    }

    /// The continuation the resolver handed back to THIS turn, when the card
    /// was settled from inside it.
    ///
    /// The card's continuation used to resume as a turn of its own whatever was
    /// running, so answering a card mid-turn put two turns on one transcript.
    /// It is now handed to the turn that answered — this tool call's own result
    /// — and the model carries on in the same reply. Absent means the card was
    /// settled with nothing running and a continuation turn was admitted the
    /// ordinary way.
    @MainActor
    private static func continuationExtra(_ id: String) -> [String: JSONValue] {
        guard let carried = InlineInteractionResolver.takeContinuationHandBack(id: id)
        else { return [:] }
        return [
            "continuation": .string(carried),
            "continuation_note": .string(
                "Carry on in THIS reply. No second turn was started for this card."),
        ]
    }

    // MARK: - The app's own composer

    /// One composer verb, receipted like every other quiet write.
    ///
    /// `read` is a read and stands behind no posture gate. Everything else
    /// changes what the person sees, so it stands behind the SAME fresh
    /// posture gate `app_setting_set` stands behind. There is no verb that
    /// sets Trust posture — the trust card opens and its word reads, and the
    /// posture itself stays the person's.
    @MainActor
    private func runComposerVerb(input: [String: JSONValue], surface: String) async -> JSONValue {
        let rawVerb = Self.interactionText(input["verb"]).lowercased()
        let verb = rawVerb.isEmpty ? "read" : rawVerb
        guard QuietComposerVerbs.names.contains(verb) else {
            return Self.interactionFailure(
                "unknown_verb",
                "No composer verb is called that.",
                extra: [
                    "requested": .string(rawVerb),
                    "verbs": .array(QuietComposerVerbs.names.map { .string($0) }),
                ]
            )
        }
        guard let appModel = QuietSelfAdmin.shared.appModel else {
            return Self.interactionFailure(
                "app_window_unavailable",
                "The app's own composer is not available in this process."
            )
        }

        if verb == "read" {
            var body = await QuietComposerVerbs.state(appModel: appModel)
            body["status"] = .string("ok")
            body["target"] = .string("composer")
            body["verb"] = .string("read")
            body["note"] = .string(
                "Read from the live composer's own state in process — no accessibility round "
                + "trip, and nothing was brought forward or clicked.")
            return .object(body)
        }

        guard let posture = await Self.freshQuietPosture(
            dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        ) else {
            return Self.interactionFailure(
                "trust_mode_unreadable",
                "The saved Trust policy does not say which mode this Mac is in, so nothing is "
                + "changed. The person can set the mode in Trust."
            )
        }
        guard posture.changesAllowed else {
            return Self.interactionFailure(
                "trust_mode_read_only",
                "Working the composer is a write, and \(posture.name) is the posture that changes "
                + "nothing at all — the person's standing choice, and only they lift it.",
                extra: ["trust_mode": .string(posture.name)]
            )
        }

        let outcome = await QuietComposerVerbs.run(
            verb: verb,
            value: Self.interactionText(input["value"]),
            choice: Self.interactionText(input["choice"]),
            appModel: appModel
        )
        if let refusal = outcome.refusal {
            return Self.interactionFailure(
                refusal.reason, refusal.detail,
                extra: [
                    "target": .string("composer"),
                    "verb": .string(verb),
                    "element": .string(outcome.element),
                ]
            )
        }
        // The receipt names the element acted on, and carries the composer's
        // state after the write — the same trail app_page_read page=chat now
        // shows, out of the same live objects.
        var body = await QuietComposerVerbs.state(appModel: appModel)
        body["status"] = .string("ok")
        body["target"] = .string("composer")
        body["verb"] = .string(verb)
        body["element"] = .string(outcome.element)
        body["changed"] = .bool(outcome.changed)
        body["detail"] = .string(outcome.detail)
        if verb == "set_page", let page = NativeAgentAppCoordinator.shared.currentPage {
            body["showing_page"] = .string(page.id)
        }
        body["trust_mode"] = .string(posture.name)
        body["surface"] = .string(surface)
        body["decided_by"] = .string("agent")
        body["note"] = .string(
            "Worked in process through the same action the composer's own control takes, so the "
            + "window shows it now. No accessibility round trip, nothing brought forward, and no "
            + "click was synthesized.")
        return .object(body)
    }

    // MARK: - Answers

    private static func interactionFailure(
        _ reason: String, _ detail: String, extra: [String: JSONValue] = [:]
    ) -> JSONValue {
        var body: [String: JSONValue] = [
            "status": .string("failed"),
            "reason": .string(reason),
            "detail": .string(detail),
        ]
        for (key, value) in extra { body[key] = value }
        return .object(body)
    }

    /// The settled card and the receipt the transcript now carries — the same
    /// envelope the row's `resultSummary` holds, so the tool's answer and
    /// scrollback cannot disagree.
    @MainActor
    private static func interactionReceipt(
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
        let card = InlineCardProjection.model(interaction, descriptor: descriptor)
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
