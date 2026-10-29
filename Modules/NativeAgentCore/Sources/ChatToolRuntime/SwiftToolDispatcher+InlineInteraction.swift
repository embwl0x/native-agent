import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import MacIntegration
import MacControl
// Blueprint: | `SwiftToolDispatcher+InlineInteraction.swift` | `SwiftToolDispatcher`: `impl_request_interaction` |

extension SwiftToolDispatcher {
    /// Agent raising a need HERSELF, before hitting a wall.
    ///
    /// The boundaries raise needs when a tool is already blocked. This is the
    /// other direction: she can see from the request that she is about to be
    /// blocked ("can you see my GitHub?") and ask for the one thing that
    /// unblocks it, instead of making a failing call first so that the failure
    /// can produce a card.
    ///
    /// What she supplies is deliberately thin: a kind, a canonical ID, and the
    /// prose. Everything that could become an ACTION — the control that opens,
    /// where it can run, whether it is available at all — comes from the
    /// registry. She cannot invent a button, name a URL, point at a settings
    /// path, or widen what a grant covers. An unknown kind or an ID with no
    /// control returns a plain failure, so an unsupported ask reads as
    /// unsupported rather than as a card that does nothing.
    func impl_request_interaction(input: [String: JSONValue]) async -> JSONValue {
        await Self.requestedInteraction(input: input, dataRoot: dataRoot)
    }

    /// Build and validate the request without filing a card, for dispatch and preview.
    public static func requestedInteraction(input: [String: JSONValue], dataRoot: URL) async -> JSONValue {
        func text(_ keys: String...) -> String? {
            for key in keys {
                if case .string(let value)? = input[key] {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
            return nil
        }
        func failed(_ reason: String, _ detail: String) -> JSONValue {
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
                accepted = "A canonical ID supported by the selected kind in request_interaction. Inspect its tool contract; do not invent an ID or widen permission."
            default:
                path = "$"
                accepted = "A supported kind, target and additional targets with an available control in this app. Inspect request_interaction's tool contract."
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

        guard let rawKind = text("kind") else {
            return failed("missing_kind", "request_interaction requires a kind.")
        }
        let kind = InlineInteraction.Kind(rawValue: rawKind) ?? .unknown
        guard kind != .unknown else {
            return failed("unknown_kind", "There is no \(rawKind) request in this app.")
        }
        guard let why = text("why", "reason", "message") else {
            return failed("missing_why", "Say in one sentence why this is needed.")
        }
        let target = text("target", rawKind) ?? (kind == .permission ? text("capability").map { AppleScriptExecution.automationTarget($0) == nil ? "privacy:" + $0 : $0 } : nil) ?? ""
        // Every decline states its consequence, using the caller's words or the registry's default.
        let declineConsequence = text("decline_consequence", "consequence")

        let options: [InlineInteraction.Option] = {
            guard case .array(let rows)? = input["options"] else { return [] }
            return rows.compactMap { row in
                guard case .object(let object) = row,
                      case .string(let id)? = object["id"]
                else { return nil }
                let label: String = {
                    if case .string(let value)? = object["label"] { return value }
                    return id
                }()
                var detail: String?
                if case .string(let value)? = object["detail"] ?? object["description"] {
                    detail = value
                }
                return InlineInteraction.Option(id: id, label: label, detail: detail)
            }
        }()

        var automation: [JSONValue] = []
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
            let access = text("mode", "access").flatMap { InlineInteraction.AccessMode(rawValue: $0) }
            // A chain she can predict is ONE ask. Extra capabilities are
            // canonical ids from the Mac list; anything the registry does not
            // know renders unavailable rather than granting something vague.
            var capabilities = target.isEmpty ? [] : [target]
            if case .array(let extra)? = input["also_needed"] ?? input["additional_targets"] {
                capabilities += extra.compactMap {
                    if case .string(let value) = $0 { return value }
                    return nil
                }
            }
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
                            shape: "The store is a JSON object: known integration entries are objects and any saved read/write axis must be Boolean; _operatorOverrides holds explicit per-axis choices and _mutationReceipts is an array of provenance receipts. Preserve all entries, grants, revocations and receipts; never invent a value, fill an absent axis or grant a missing permission.") + " Repair the saved permission store from its retained bytes before requesting access; preserve the owner's choices."),
                        tool: InlineInteractionWire.toolName)
                }
            }
            for capability in capabilities {
                guard let bundleID = AppleScriptExecution.automationTarget(capability) else { continue }
                let permission = await AppleScriptExecution.automationPermission(bundleID: bundleID)
                guard case .object(let fields) = permission, fields["app_path"] != nil else {
                    return failed("app_not_installed", "No installed app resolves \(bundleID); install that app before requesting Automation consent.")
                }
                automation.append(permission)
            }
            if integrationAllowed, !capabilities.isEmpty, capabilities.allSatisfy({
                SystemPermissionPreflight.cardSettingsCapability($0) != nil
                    && (!InlineInteractionRegistry.isMacControlCategory($0)
                        || InlineInteractionRegistry.macControlCategoryAllowed($0, dataRoot: dataRoot))
            }), await SystemPermissionPreflight.cardBlockReason(capabilities, mode: access) == nil {
                return .object(["status": .string("ok"), "already_done": .bool(true), "effects": .string("none"),
                    "summary": .string("Permission is already allowed; no card is needed."), "automation": .array(automation)])
            }
            // She may say which axis she needs; she cannot widen one. An
            // unknown value reads as "both", which is what the card would have
            // said before this field existed.
            interaction = InlineInteractionRegistry.permission(
                capabilities,
                why: why,
                mode: access,
                declineConsequence: declineConsequence
            )
        case .modelChoice:
            guard !target.isEmpty else {
                return failed("missing_target", "Name the Providers group.")
            }
            interaction = InlineInteractionRegistry.modelChoice(
                group: target, why: why, options: options,
                scopedToThisRequest: text("scope_noun"),
                declineConsequence: declineConsequence
            )
        case .apiKey where target.hasPrefix("secret:"):
            let name = String(target.dropFirst("secret:".count))
            func list(_ key: String) -> [String] {
                if case .array(let rows)? = input[key] { return rows.compactMap { if case .string(let text) = $0 { text } else { nil } } }
                return []
            }
            // A program is granted as the file that runs, never a name another file could take.
            let hosts = list("hosts").compactMap(Keyring.host), programs = list("programs").compactMap(AgentHostCommandLines.resolveCommand)
            if input["remove"] == .bool(true) {
                let kept: Keyring.Entry?
                do { kept = try Keyring.entry(name) } catch {
                    return failed("unavailable", "The keyring could not be read, so whether \(name) is kept is unknown. Try again.")
                }
                guard kept != nil else {
                    return .object(["status": .string("ok"), "already_done": .bool(true), "effects": .string("none"),
                                    "summary": .string("No secret named \(name) is kept; nothing to remove.")])
                }
                interaction = InlineInteractionRegistry.secret(name, ask: .init(hosts: [], programs: [], remove: true),
                                                               why: why, declineConsequence: declineConsequence)
                break
            }
            guard Keyring.validName(name), !(hosts.isEmpty && programs.isEmpty),
                  hosts.count == list("hosts").count, programs.count == list("programs").count else {
                return failed("missing_target", "A secret is target secret:<name> (lowercase letters, digits, . _ -) with where it may go: "
                    + "hosts [\"api.example.com\"] a request may carry it to and/or programs [\"npx\"] (a name on the login PATH or an executable's path) it may be handed to.")
            }
            var signIn: InlineInteraction.SecretAsk.SignIn?
            if case .object(let fields)? = input["sign_in"] {
                let given = JSONValue.object(fields).stringFields
                guard fields["client_secret"] == nil else {
                    return failed("missing_target", "A client secret never goes through you: leave it out, and the person types it on the card if the service issued one.")
                }
                // The card shows each address's host, and the flow goes to exactly those.
                guard (given["authorize"] == nil) != (given["device"] == nil), let token = given["token"], let client = given["client_id"],
                      [given["authorize"], given["device"], token].allSatisfy({ $0.map { URL(string: $0)?.scheme == "https" && URL(string: $0)?.host?.isEmpty == false } ?? true }) else {
                    return failed("missing_target", "sign_in takes authorize (or device, for a device sign-in), token and client_id (https addresses and the service's client id), "
                        + "and optionally scopes, redirect (a registered http://127.0.0.1:<port>/<path>) and client_auth.")
                }
                guard [nil, "body", "basic"].contains(given["client_auth"]) else {
                    return failed("missing_target", "client_auth is body (the default) or basic.")
                }
                signIn = .init(authorize: given["authorize"], device: given["device"], token: token, clientID: client, scopes: given["scopes"], redirect: given["redirect"],
                               clientAuth: given["client_auth"] == "basic" ? "basic" : nil)
            }
            let kept: Keyring.Entry?
            do { kept = try Keyring.entry(name) } catch {
                return failed("unavailable", "The keyring could not be read, so whether \(name) is kept is unknown. Try again.")
            }
            // The card shows the whole grant, which is kept exactly: where it already goes stays on it, unless
            // only:true narrows it to what she named, and then the card says what stops.
            let keptHosts = kept?.hosts ?? [], keptPrograms = kept?.programs.map(\.path) ?? []
            let only = input["only"] == .bool(true)
            let stops = only ? keptHosts.filter { !hosts.contains($0) } + keptPrograms.filter { !programs.contains($0) }.map { "program " + $0 } : []
            // Expired, revoked or unwanted: replace asks again; the kept value stays until the new one is.
            if input["replace"] != .bool(true), stops.isEmpty, Keyring.granted(name, hosts: hosts, programs: programs) {
                return .object(["status": .string("ok"), "already_done": .bool(true), "effects": .string("none"),
                    "summary": .string("Secret \(name) is already kept for \((hosts + programs.map { "program " + $0 }).joined(separator: ", "))"
                        + "\(kept?.account.map { " (account \($0))" } ?? ""); no card is needed. "
                        + "If it stopped working (expired, revoked) or the person wants a new one, ask again with replace:true.")])
            }
            interaction = InlineInteractionRegistry.secret(name, ask: .init(hosts: only ? hosts : hosts + keptHosts.filter { !hosts.contains($0) },
                                                                            programs: only ? programs : programs + keptPrograms.filter { !programs.contains($0) },
                                                                            signIn: signIn, stops: stops),
                                                           why: why, declineConsequence: declineConsequence)
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
            guard let question = text("title", "question") else {
                return failed("missing_question", "A choice needs a question.")
            }
            guard let consequence = declineConsequence else {
                return failed(
                    "missing_consequence",
                    "A choice needs decline_consequence: say what happens if they don't pick."
                )
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
        // Last gate: a descriptor with no executable control must not become a
        // card with a dead button.
        // The WHOLE chain, because the whole chain is what one tap grants: an
        // additional target this build does not know — or one the current
        // posture forbids — has to be refused HERE, at the raise, not
        // discovered after the person has already tapped.
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
        let result = InlineInteractionNeed.envelope(interaction)
        if kind == .permission, case .object(var fields) = result {
            if !automation.isEmpty { fields["automation"] = .array(automation) }
            return .object(fields)
        }
        return result
    }
}
