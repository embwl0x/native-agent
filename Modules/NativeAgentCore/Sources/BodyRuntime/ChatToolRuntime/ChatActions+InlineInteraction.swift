import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import MacNerves
// Blueprint: | `ChatActions+InlineInteraction.swift` | `SwiftToolDispatcher`: `impl_request_interaction`, `requestedInteraction` with its permission and secret card stages |

extension SwiftToolDispatcher {
    /// A predicted need may raise a card before a failing call. The registry alone supplies controls, locations and grant scope; unknown controls fail plainly.
    func impl_request_interaction(invocation: ChatToolInvocation, input: RequestInteractionArgs) async -> JSONValue {
        await Self.requestedInteraction(invocation: invocation, input: input, dataRoot: dataRoot)
    }

    /// Build and validate the request without filing a card, for dispatch and preview.
    public static func requestedInteraction(invocation: ChatToolInvocation, input: [String: JSONValue], dataRoot: URL) async -> JSONValue {
        do {
            let args = try DoorSchemaBuilder<RequestInteractionArgs>().decode(input)
            return await requestedInteraction(invocation: invocation, input: args, dataRoot: dataRoot)
        } catch {
            return ChatToolOutcome.failure(error: error, tool: "request_interaction")
        }
    }

    static func requestedInteraction(invocation: ChatToolInvocation, input: RequestInteractionArgs, dataRoot: URL) async -> JSONValue {
        func text(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }

        guard let rawKind = text(input.kind) else {
            return failed("missing_kind", "request_interaction requires a kind.")
        }
        let kind = InlineInteraction.Kind(rawValue: rawKind) ?? .unknown
        guard kind != .unknown else {
            return failed("unknown_kind", "There is no \(rawKind) request in this app.")
        }
        guard let why = text(input.why) else {
            return failed("missing_why", "Say in one sentence why this is needed.")
        }
        let target = text(input.target) ?? ""
        // Every decline states its consequence, using the caller's words or the registry's default.
        let declineConsequence = text(input.declineConsequence)

        let options = (input.options ?? []).map(\.option)

        let draft = InteractionDraft()
        let interaction: InlineInteraction?
        switch kind {
        case .connector:
            guard !target.isEmpty else {
                return failed("missing_target", "Name the connector to connect.")
            }
            interaction = InlineInteractionRegistry.connector(
                target, why: why, dataRoot: dataRoot,
                declineConsequence: declineConsequence
            )
        case .permission:
            if let answer = await permissionInteraction(draft, input: input, target: target, why: why, declineConsequence: declineConsequence,
                dataRoot: dataRoot) { return answer }
            interaction = draft.interaction
        case .modelChoice:
            guard !target.isEmpty else {
                return failed("missing_target", "Name the Providers group.")
            }
            // A pick settles only as a provider::model pair; any other id would leave the card unanswerable.
            let unsettleable = options.map(\.id).filter {
                $0 != InlineInteractionRegistry.persistentChoiceOptionID && InlineInteractionRegistry.splitModelOptionID($0) == nil
            }
            guard unsettleable.isEmpty else {
                return failed("invalid_model_option", "No card was raised: \(unsettleable.joined(separator: ", ")) "
                    + "\(unsettleable.count == 1 ? "is" : "are") not <provider>::<model> ids, so picking \(unsettleable.count == 1 ? "it" : "them") "
                    + "could never settle.")
            }
            interaction = InlineInteractionRegistry.modelChoice(
                group: target, why: why, options: options,
                scopedToThisRequest: text(input.scopeNoun),
                declineConsequence: declineConsequence
            )
        case .apiKey where target.hasPrefix("secret:"):
            if let answer = secretInteraction(draft, input: input, target: target, why: why, declineConsequence: declineConsequence) {
                return answer
            }
            interaction = draft.interaction
        case .apiKey:
            guard !target.isEmpty else {
                return failed("missing_target", "Name the provider.")
            }
            interaction = InlineInteractionRegistry.apiKey(
                provider: target, why: why, declineConsequence: declineConsequence
            )
        case .capability:
            interaction = InlineInteractionRegistry.capability(
                target, why: why, declineConsequence: declineConsequence
            )
        case .choose:
            guard let question = text(input.title) else {
                return failed("missing_question", "A choice needs a question.")
            }
            guard let consequence = declineConsequence else {
                return failed(
                    "missing_consequence",
                    "A choice needs decline_consequence: say what happens if they don't pick."
                )
            }
            // The card's own buttons answer with these words; an option named the same would be read as the button, not the pick.
            let reserved = options.map(\.id).filter { InlineInteractionRegistry.cardControlWords.contains($0) }
            guard reserved.isEmpty else {
                return failed("reserved_option_id", "No card was raised: option id \(reserved.joined(separator: ", ")) "
                    + "names one of the card's own buttons. Rename \(reserved.count == 1 ? "it" : "them").")
            }
            // Each button answers as itself: two options with one id would record the first one's label for the second.
            let ids = options.map { $0.id.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !ids.contains(where: \.isEmpty), Set(ids).count == ids.count else {
                return failed("duplicate_option_id", "No card was raised: every option needs its own nonblank id.")
            }
            interaction = InlineInteractionRegistry.choose(
                question: question, why: why, options: options,
                declineConsequence: consequence
            )
        case .unknown:
            interaction = nil
        }

        guard let interaction else {
            return failed(
                "unavailable",
                "There is no control in this app for \(target.isEmpty ? rawKind : target)."
            )
        }
        // Validate every target before raising the card: one tap grants the whole chain, so an unavailable control would make approval false.
        let descriptor = InlineInteractionRegistry.descriptor(
            kind: interaction.kind,
            target: interaction.target,
            additionalTargets: interaction.additionalTargets,
            dataRoot: dataRoot
        )
        guard descriptor.isActionable else {
            return failed(
                "unavailable",
                descriptor.unavailableReason ?? "No control for \(interaction.target)."
            )
        }
        let result = InlineInteractionNeed.envelope(invocation: invocation, interaction)
        if kind == .permission, case .object(var fields) = result {
            if !draft.automation.isEmpty { fields["automation"] = .array(draft.automation) }
            return .object(fields)
        }
        return result
    }

    /// A permission card asks for every capability at once. A switch the owner keeps off refuses plainly, Automation needs the app installed,
    /// and a grant already in place needs no card.
    private static func permissionInteraction(_ draft: InteractionDraft, input: RequestInteractionArgs, target: String, why: String,
        declineConsequence: String?, dataRoot: URL) async -> JSONValue? {
        let mode = input.mode?.trimmingCharacters(in: .whitespacesAndNewlines)
        let access = mode.flatMap(InlineInteraction.AccessMode.init(rawValue:))
        if let mode, !mode.isEmpty, access == nil {
            return failed("invalid_mode", "Unknown permission mode: \(mode). Use read, write or read_write.")
        }
        // Group predictable capabilities into one ask; unknown canonical ids stay unavailable.
        var capabilities = target.isEmpty ? [] : [target]
        capabilities += input.alsoNeeded ?? []
        if capabilities.contains("applescript") || capabilities.contains("automation") {
            return failed("missing_target", "Automation consent is per app. Request permission with target applescript:<bundle_id>.")
        }
        var integrationAllowed = true
        if capabilities.contains(where: MacIntegrationID.all.contains) {
            do {
                let permissions = try await MacIntegrationPermissionStore(dataRoot: dataRoot).snapshotChecked()
                for capability in capabilities where MacIntegrationID.all.contains(capability) {
                    for mode in [MacIntegrationPermissionMode.read, .write]
                    where (access == nil || access?.rawValue == mode.rawValue || access == .readWrite)
                        && (mode == .read ? MacIntegrationID.supportsRead(capability) : MacIntegrationID.supportsWrite(capability)) {
                        if let refusal = permissions.readiness.refusal(integration: capability, mode: mode) {
                            return ChatToolOutcome.failure(error: ToolFailureError(refusal, effects: .none,
                                owner: "security/mac_integration_permissions.json \(capability).\(mode.rawValue)",
                                tap: "Trust > Mac > Apps and features > \(MacIntegrationID.displayName(for: capability)) > \(mode.rawValue.capitalized)",
                                personDecides: true, code: "operator_permission_off", status: .refused,
                                instruction: "Only the owner can enable this switch."), tool: InlineInteractionWire.toolName)
                        }
                        if !permissions.allows(capability, mode: mode) { integrationAllowed = false }
                    }
                }
            } catch {
                let file = dataRoot.appendingPathComponent("security/mac_integration_permissions.json")
                return ChatToolOutcome.failure(error: ToolFailureError(
                    "Saved Mac Integration permissions could not be read: \(error.localizedDescription)",
                    effects: .none, owner: file.path,
                    code: "permission_settings_unavailable",
                    instruction: ToolFailureError.fileRepairInstruction(file,
                        shape: """
                            The store is a JSON object: known integration entries are objects and any saved read/write axis must be Boolean; \
                            _operatorOverrides holds explicit per-axis choices and _mutationReceipts is an array of provenance receipts. \
                            Preserve all entries, grants, revocations and receipts; never invent a value, fill an absent axis or grant a \
                            missing permission.
                            """) + """
                             Repair the saved permission store from its retained bytes before requesting access; preserve the owner's \
                            choices.
                            """),
                    tool: InlineInteractionWire.toolName)
            }
        }
        for capability in capabilities {
            guard let bundleID = AppleScriptExecution.automationTarget(capability) else { continue }
            let permission = await AppleScriptExecution.automationPermission(bundleID: bundleID)
            guard case .object(let fields) = permission, fields["app_path"] != nil else {
                return failed("app_not_installed", "No installed app resolves \(bundleID); install that app before requesting Automation consent.")
            }
            draft.automation.append(permission)
        }
        do {
        if integrationAllowed, !capabilities.isEmpty, try capabilities.allSatisfy({
            guard SystemPermissionPreflight.cardSettingsCapability($0) != nil else { return false }
            guard InlineInteractionRegistry.isMacControlCategory($0) else { return true }
            return try InlineInteractionRegistry.macControlCategoryAllowed($0, dataRoot: dataRoot)
        }), await SystemPermissionPreflight.cardBlockReason(capabilities, mode: access) == nil {
            return .object(["status": .string("ok"), "already_done": .bool(true), "effects": .string("none"),
                "summary": .string("Permission is already allowed; no card is needed."), "automation": .array(draft.automation)])
        }
        } catch { return ChatToolOutcome.failure(error: error, tool: InlineInteractionWire.toolName) }
        // Omission requests both axes; every supplied mode was checked above.
        draft.interaction = InlineInteractionRegistry.permission(
            capabilities,
            why: why,
            mode: access,
            declineConsequence: declineConsequence
        )
        return nil
    }

    /// A secret card names where the secret may go and shows the whole grant it keeps. Removing a secret that is not kept, or asking for a
    /// grant already in place, needs no card.
    private static func secretInteraction(_ draft: InteractionDraft, input: RequestInteractionArgs, target: String, why: String,
        declineConsequence: String?) -> JSONValue? {
        let name = String(target.dropFirst("secret:".count))
        // A program is granted as the file that runs, never a name another file could take.
        let hosts = (input.hosts ?? []).compactMap(Keyring.host)
        let programs = (input.programs ?? []).compactMap(AgentHostCommandLines.resolveCommand)
        if input.remove == true {
            let kept: Keyring.Entry?
            do { kept = try Keyring.entry(name) } catch {
                return failed("unavailable", "The keyring could not be read, so whether \(name) is kept is unknown. Try again.")
            }
            guard kept != nil else {
                return .object(["status": .string("ok"), "already_done": .bool(true), "effects": .string("none"),
                                "summary": .string("No secret named \(name) is kept; nothing to remove.")])
            }
            draft.interaction = InlineInteractionRegistry.secret(name, ask: .init(hosts: [], programs: [], remove: true),
                                                           why: why, declineConsequence: declineConsequence)
            return nil
        }
        guard Keyring.validName(name), !(hosts.isEmpty && programs.isEmpty),
              hosts.count == (input.hosts ?? []).count, programs.count == (input.programs ?? []).count else {
            return failed("missing_target", "A secret is target secret:<name> (lowercase letters, digits, . _ -) with where it may go: "
                + """
                    hosts [\"api.example.com\"] a request may carry it to and/or programs [\"npx\"] (a name on the login PATH or an \
                    executable's path) it may be handed to.
                    """)
        }
        var signIn: InlineInteraction.SecretAsk.SignIn?
        if let given = input.signIn {
            guard given.additional["client_secret"] == nil else {
                return failed("missing_target",
                    "A client secret never goes through you: leave it out, and the person types it on the card if the service issued one.")
            }
            // The card shows each address's host, and the flow goes to exactly those.
            guard (given.authorize == nil) != (given.device == nil),
                  [given.authorize, given.device, given.token].allSatisfy({
                      $0.map { URL(string: $0)?.scheme == "https" && URL(string: $0)?.host?.isEmpty == false } ?? true }) else {
                return failed("missing_target", """
                    sign_in takes authorize (or device, for a device sign-in), token and client_id (https addresses and the service's client \
                    id),\u{20}
                    """
                    + "and optionally scopes, redirect (a registered http://127.0.0.1:<port>/<path>) and client_auth.")
            }
            guard [nil, "body", "basic"].contains(given.clientAuth) else {
                return failed("missing_target", "client_auth is body (the default) or basic.")
            }
            signIn = .init(authorize: given.authorize, device: given.device, token: given.token, clientID: given.clientID, scopes: given.scopes,
                redirect: given.redirect,
                           clientAuth: given.clientAuth == "basic" ? "basic" : nil)
        }
        let kept: Keyring.Entry?
        do { kept = try Keyring.entry(name) } catch {
            return failed("unavailable", "The keyring could not be read, so whether \(name) is kept is unknown. Try again.")
        }
        // The card shows the whole grant, which is kept exactly: where it already goes stays on it, unless only:true narrows it to what the agent named,
        // and then the card says what stops.
        let keptHosts = kept?.hosts ?? [], keptPrograms = kept?.programs.map(\.path) ?? []
        let only = input.only == true
        let stops = only ? keptHosts.filter { !hosts.contains($0) } + keptPrograms.filter { !programs.contains($0) }.map { "program " + $0 } : []
        // Expired, revoked or unwanted: replace asks again; the kept value stays until the new one is.
        let granted: Bool
        do { granted = try kept.map { try Keyring.granted($0, hosts: hosts, programs: programs) } ?? false }
        catch { return failed("unavailable", error.localizedDescription) }
        if input.replace != true, stops.isEmpty, granted {
            return .object(["status": .string("ok"), "already_done": .bool(true), "effects": .string("none"),
                "summary": .string("Secret \(name) is already kept for \((hosts + programs.map { "program " + $0 }).joined(separator: ", "))"
                    + "\(kept?.account.map { " (account \($0))" } ?? ""); no card is needed. "
                    + "If it stopped working (expired, revoked) or the person wants a new one, ask again with replace:true.")])
        }
        draft.interaction = InlineInteractionRegistry.secret(name, ask: .init(hosts: only ? hosts : hosts + keptHosts.filter { !hosts.contains($0) },
                                                                        programs: only ? programs : programs + keptPrograms
                                                                            .filter { !programs.contains($0) },
                                                                        signIn: signIn, stops: stops),
                                                       why: why, declineConsequence: declineConsequence)
        return nil
    }

    /// A request refused before any card, with the argument to correct and what it accepts.
    private static func failed(_ reason: String, _ detail: String) -> JSONValue {
        let path: String
        let accepted: String
        switch reason {
        case "missing_kind", "unknown_kind":
            path = "$.kind"
            accepted = "connector, permission, model_choice, api_key, capability, choose"
        case "missing_why":
            path = "$.why"
            accepted = "A nonblank string explaining why this is needed; reason or message is also accepted."
        case "missing_question":
            path = "$.title"
            accepted = "A nonblank question string; question is also accepted."
        case "missing_consequence":
            path = "$.decline_consequence"
            accepted = "A nonblank string saying what happens if the person declines."
        case "missing_target":
            path = "$.target"
            accepted = """
                A canonical ID supported by the selected kind in request_interaction. Inspect its argument form; do not invent an ID or \
                widen permission.
                """
        case "invalid_mode":
            path = "$.mode"
            accepted = "read, write or read_write"
        case "reserved_option_id":
            path = "$.options"
            accepted = "Option ids other than answer, begin, full_setup, restart and signIn, which name the card's own buttons."
        case "invalid_model_option":
            path = "$.options"
            accepted = "Model options with id <provider>::<model>, as Providers lists them."
        default:
            path = "$"
            accepted = "A supported kind, target and additional targets with an available control in this app. Inspect request_interaction's argument form."
        }
        return .object([
            "status": .string("failed"),
            "tool": .string(InlineInteractionWire.toolName),
            "reason": .string(reason),
            "error": .string(detail),
            "argument_path": .string(path),
            "accepted": .string(accepted),
            "effects": .string("none"),
        ])
    }
}

/// What a permission or secret request decided when it raises a card: the card, and the Automation targets it checked.
private final class InteractionDraft {
    var automation: [JSONValue] = []
    var interaction: InlineInteraction?
}
