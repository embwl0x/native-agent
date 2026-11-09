import Foundation
import MacControl
import MacIntegration
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import TrustCenter
// Blueprint: | `InlineInteractionRegistry.swift` | Checked inline interaction descriptors for connector, provider, permission and capability owners |

/// Derive cards from checked connector, integration, provider and capability owners so labels and permissions do not drift. Unknown IDs render unavailable
/// text, never dead controls. Shared setup routes serve cards and the wizard.
public enum InlineInteractionRegistry {

    // MARK: - Descriptors

    public static func descriptor(
        kind: InlineInteraction.Kind,
        target: String,
        additionalTargets: [String] = [],
        dataRoot: URL
    ) -> InlineInteractionDescriptor {
        switch kind {
        case .connector:
            let id = ConnectorSetup.canonicalID(target)
            if id == "mail" {
                return InlineInteractionDescriptor(kind: .connector, target: id, displayName: "Mail",
                    icon: "envelope", control: .internetAccounts, location: .macRequired)
            }
            if id == "chrome" || id == "iphone" {
                return InlineInteractionDescriptor(kind: .connector, target: id,
                    displayName: connectorDisplayName(id, dataRoot: dataRoot),
                    icon: id == "chrome" ? "globe" : "iphone",
                    control: id == "chrome" ? .chromeSetup : .pairDevice, location: .macRequired)
            }
            let setup = ConnectorSetup.resolve(id)
            return InlineInteractionDescriptor(
                kind: .connector,
                target: id,
                displayName: connectorDisplayName(id, dataRoot: dataRoot),
                icon: "link",
                control: {
                    switch setup {
                    case .manualToken: return .connectorManualToken
                    case .unavailable: return .unavailable
                    }
                }(),
                location: .macRequired,
                unavailableReason: setup == .unavailable
                    ? "This build has no setup flow for \(target)."
                    : nil
            )

        case .permission:
            // Check the whole also_needed chain; granting only the primary's permitted category could leave a forbidden latent allow.
            let targets = ([target] + additionalTargets).filter { !$0.isEmpty }
            let known = !targets.isEmpty && targets.allSatisfy {
                MacIntegrationID.all.contains($0) || isMacControlCategory($0)
                    || SystemPermissionPreflight.cardSettingsCapability($0) != nil
            }
            // Cards cannot change the person's saved posture; a forbidden category offers only its owning settings page.
            let posturePermits: Bool
            do {
                if known && targets.contains(where: isMacControlCategory) {
                    let policy = try macControlPolicySnapshot(dataRoot: dataRoot)
                    posturePermits = policy.trustPolicy.map { PermissionLaw.posture($0) == .fullMac } ?? false
                } else {
                    posturePermits = true
                }
            } catch {
                return InlineInteractionDescriptor(kind: .permission, target: target,
                    displayName: macCapabilityDisplayName(target), icon: "lock.shield",
                    control: .unavailable, location: .macRequired,
                    unavailableReason: error.localizedDescription)
            }
            let control: InlineInteractionDescriptor.Control = {
                guard known else { return .unavailable }
                return posturePermits ? .macPermissionGrant : .trustPostureRequired
            }()
            return InlineInteractionDescriptor(
                kind: .permission,
                target: target,
                displayName: macCapabilityDisplayName(target),
                icon: "lock.shield",
                control: control,
                // A macOS permission prompt happens on the Mac, by the person.
                location: .macRequired,
                unavailableReason: known ? nil : "No such Mac capability on this build. A macOS grant is privacy:<grant>, grant one of "
                    + SystemPermissionCapability.requestable + "; Automation for one app is applescript:<bundle_id>."
            )

        case .modelChoice:
            let group = ProviderSurfaceGroups.all.first { $0.id == target }
            return InlineInteractionDescriptor(
                kind: .modelChoice,
                target: target,
                displayName: group?.title ?? target,
                icon: "cpu",
                control: group == nil ? .unavailable : .providerGroupModel,
                location: .anywhere,
                unavailableReason: group == nil ? "No such Providers group." : nil
            )

        case .apiKey where target.hasPrefix("secret:"):
            // A keyring secret one of the agent's abilities names: no registry knows it, and none needs to. The person grants it once.
            let name = String(target.dropFirst("secret:".count))
            return InlineInteractionDescriptor(
                kind: .apiKey, target: target, displayName: name, icon: "key",
                control: Keyring.validName(name) ? .keyring : .unavailable, location: .macRequired,
                unavailableReason: Keyring.validName(name) ? nil : "A secret's name is lowercase letters, digits, . _ -."
            )

        case .apiKey:
            let providerID = canonicalProviderID(target)
            return InlineInteractionDescriptor(
                kind: .apiKey,
                target: providerID,
                displayName: providerDisplayName(providerID),
                icon: "key",
                control: providerID.isEmpty ? .unavailable : .providerAPIKey,
                location: .macRequired,
                unavailableReason: target.isEmpty ? "No provider named." : nil
            )

        case .capability:
            let flag = capabilityFlags[target]
            return InlineInteractionDescriptor(
                kind: .capability,
                target: target,
                displayName: flag?.displayName ?? target,
                icon: "switch.2",
                // NOT a universal flag writer: only catalogued, user-configurable flags have a control.
                control: flag == nil ? .unavailable : .capabilityFlag,
                location: .anywhere,
                unavailableReason: flag == nil
                    ? "That is not a switch a person can turn on here."
                    : nil
            )

        case .choose:
            return InlineInteractionDescriptor(
                kind: .choose,
                target: target,
                displayName: target,
                icon: "questionmark.circle",
                control: .inlineChoice,
                location: .anywhere
            )

        case .unknown:
            return InlineInteractionDescriptor(
                kind: .unknown,
                target: target,
                displayName: target,
                control: .unavailable,
                unavailableReason: "This build does not know that kind of request."
            )
        }
    }

    // MARK: - Display names

    /// Use the connector catalog's display name so new entries need no renderer branch.
    public static func connectorDisplayName(_ id: String, dataRoot: URL) -> String {
        let canonical = ConnectorSetup.canonicalID(id)
        do {
            let rows = try ConnectorOAuthRegistry.readRegistry(at: ConnectorOAuthRegistry.connectorRegistryPath(root: dataRoot))
            if let row = rows.first(where: { $0["id"]?.stringValue == canonical }),
               let name = row["name"]?.stringValue, !name.isEmpty { return name }
            // No registered display name is an optional fact, not a reason to manufacture a second name. The exact connector ID is usable.
            return canonical
        } catch {
            return "\(canonical) (registry name unavailable: \(error.localizedDescription); repair connectors/registry.json)"
        }
    }

    /// Mac Integration ids own their display names; the five Mac Control approval categories carry Trust's own titles.
    public static func macCapabilityDisplayName(_ id: String) -> String {
        if id.hasPrefix("privacy:"), let gate = SystemPermissionPreflight.cardSettingsCapability(id) { return gate.displayName }
        if MacIntegrationID.all.contains(id) {
            return MacIntegrationID.displayName(for: id)
        }
        if let bundleID = AppleScriptExecution.automationTarget(id) { return "Automation for \(bundleID)" }
        // Name the access being granted so a read permission never appears to authorize only changes.
        if let noun = macControlCategoryGrantNouns[id] {
            return noun.prefix(1).uppercased() + noun.dropFirst()
        }
        return macControlCategoryTitles[id] ?? titleCased(id)
    }

    static let macControlCategoryTitles: [String: String] = [
        "shell": "Terminal commands",
        "file_ops": "File changes",
        "applescript": "AppleScript",
        "jxa": "JavaScript automation",
        "accessibility": "Screen control",
        "system": "System control",
        "notifications": "Notifications",
        "spotlight": "Spotlight search",
    ]

    /// Use access nouns on grant cards; switch titles describe settings rather than the permission being requested.
    static let macControlCategoryGrantNouns: [String: String] = [
        "shell": "terminal commands",
        "file_ops": "file access",
        "applescript": "AppleScript",
        "jxa": "JavaScript automation",
        "accessibility": "screen control",
        "system": "system control",
        "notifications": "notifications",
        "spotlight": "Spotlight search",
    ]

    /// Mac Control and MacIntegration grants have different owners; resolve the category before writing.
    public static func isMacControlCategory(_ id: String) -> Bool {
        macControlCategoryTitles[id] != nil
    }

    /// Read saved policy and the MacControl gate so cards cannot offer writes that the active posture would refuse.
    public static func macControlPostureAllowsCategories(dataRoot: URL) throws -> Bool {
        let policy = try macControlPolicySnapshot(dataRoot: dataRoot)
        guard let trust = policy.trustPolicy
        else { return false }
        return PermissionLaw.posture(trust) == .fullMac
    }

    /// Whether the saved policy already allows a category — the same question the dispatch gate asks, so a settled card and a working call agree.
    public static func macControlCategoryAllowed(_ category: String, dataRoot: URL) throws -> Bool {
        let policy = try macControlPolicySnapshot(dataRoot: dataRoot)
        guard let trust = policy.trustPolicy, PermissionLaw.posture(trust) == .fullMac else {
            return false
        }
        return MacControlGate.gate(policy, category: category).allowed
    }

    static func macControlPolicySnapshot(dataRoot: URL) throws -> MacControlPolicy {
        do {
            let root = try SwiftNativeTrustCenter(dataRoot: dataRoot).loadSavedPolicyChecked()
            return .fromTrustPolicyObject(root, dataRoot: dataRoot)
        } catch {
            let path = SwiftNativeTrustCenter.policyURL(dataRoot: dataRoot).path
            throw ToolFailureError("""
                Saved Trust policy at \(path) could not be read or validated. Preserve the damaged file and ask the owner to repair it in Trust > \
                Access and policy.
                """,
                effects: .none, owner: path,
                tap: "Trust > Access and policy > Preserve damaged policy and authorize Safe",
                code: "trust_policy_unavailable",
                instruction: "Ask the owner to preserve the damaged policy and authorize Safe.")
        }
    }

    public static func providerDisplayName(_ id: String) -> String {
        let canonical = canonicalProviderID(id)
        return providerDisplayNames[canonical] ?? titleCased(canonical)
    }

    static let providerDisplayNames: [String: String] = [
        "openai": "OpenAI",
        "openai_oauth_direct": "ChatGPT",
        "codex": "Codex",
        "anthropic": "Anthropic",
        "anthropic_oauth_direct": "Claude",
        "xai_oauth_direct": "xAI Grok",
        "openrouter": "OpenRouter",
        "moonshot": "Moonshot",
        "kimi-code": "Kimi Code",
        "meta": "Meta",
    ]

    // MARK: - Providers you sign into

    /// Use ProviderRouting's sign-in IDs; xai denotes the sign-in provider, not an API-key route.
    public static func canonicalProviderID(_ rawID: String) -> String {
        switch rawID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "chatgpt", "openai_codex_oauth", "openai_oauth", "codex_oauth": return "openai_oauth_direct"
        case "claude", "anthropic_oauth", "claude_oauth": return "anthropic_oauth_direct"
        case "xai", "grok", "xai_oauth": return "xai_oauth_direct"
        case let other: return other
        }
    }

    /// Sign-in cards must use onboarding's OAuth owner; offer paste fields only when that provider supports them.
    public struct ProviderSignIn: Sendable, Equatable {
        public var oauthProviderID: String
        public var displayShort: String
        public var pasteLabel: String?
    }

    public static func providerSignIn(for rawID: String) -> ProviderSignIn? {
        switch canonicalProviderID(rawID) {
        case "openai":
            return ProviderSignIn(oauthProviderID: "openai_oauth_direct", displayShort: "ChatGPT",
                                  pasteLabel: "or paste an API key")
        case "openai_oauth_direct", "codex":
            return ProviderSignIn(oauthProviderID: "openai_oauth_direct", displayShort: "ChatGPT",
                                  pasteLabel: nil)
        case "anthropic":
            return ProviderSignIn(oauthProviderID: "anthropic_oauth_direct", displayShort: "Claude",
                                  pasteLabel: "or paste an API key")
        case "anthropic_oauth_direct":
            return ProviderSignIn(oauthProviderID: "anthropic_oauth_direct", displayShort: "Claude",
                                  pasteLabel: "or paste a setup token (claude setup-token)")
        case "xai_oauth_direct":
            return ProviderSignIn(oauthProviderID: "xai_oauth_direct", displayShort: "xAI Grok",
                                  pasteLabel: nil)
        default:
            return nil
        }
    }

    // MARK: - Capability catalog

    /// Only catalogued user-configurable capability flags may have controls; needs_capability must not become a universal policy writer.
    public struct CapabilityFlag: Sendable, Equatable {
        public var id: String
        public var displayName: String
        public var policyBlock: String
        public var policyKey: String
        public var why: String
    }

    public static let capabilityFlags: [String: CapabilityFlag] = [
        "image_generation": CapabilityFlag(
            id: "image_generation",
            displayName: "Image generation",
            policyBlock: "multimodalPolicy",
            policyKey: "image_generation_openai",
            why: "Making pictures " + InlineInteraction.ConsequenceCopy.trustSwitchedOff
        ),
        "screen_capture": CapabilityFlag(
            id: "screen_capture",
            displayName: "Screen capture",
            policyBlock: "multimodalPolicy",
            policyKey: "screen_capture",
            why: "Reading your screen " + InlineInteraction.ConsequenceCopy.trustSwitchedOff
        ),
        "tts": CapabilityFlag(
            id: "tts",
            displayName: "Speech",
            policyBlock: "multimodalPolicy",
            policyKey: "tts_openai",
            why: "Speaking out loud " + InlineInteraction.ConsequenceCopy.trustSwitchedOff
        ),
    ]

    // MARK: - Builders
    // All cards need an outcome, a reason, a primary action and a decline consequence; construction requires the consequence.

    public static func connector(
        _ rawID: String,
        why: String,
        dataRoot: URL,
        declineConsequence: String? = nil
    ) -> InlineInteraction {
        let id = ConnectorSetup.canonicalID(rawID)
        let descriptor = descriptor(kind: .connector, target: id, dataRoot: dataRoot)
        let name = descriptor.displayName
        return InlineInteraction(
            kind: .connector,
            target: id,
            title: "Connect \(name)",
            why: why,
            primaryActionLabel: "Connect \(name)",
            declineConsequence: declineConsequence
                ?? "Without \(name) I can't do this part, and " + InlineInteraction.ConsequenceCopy.connectorCarryOn,
            persistenceNote: id == "chrome"
                ? "Stays on until you turn Chrome control off in Trust."
                : "Stays connected until you disconnect it in Connectors.",
            cardProse: "I need \(name) for this \u{2014} connect it below, "
                + InlineInteraction.ConsequenceCopy.keepGoingSuffix
        )
    }

    /// Combine capabilities known in advance into one grant; ask again only when a later need could not have been known.
    public static func permission(
        _ capabilities: [String],
        why: String,
        mode: InlineInteraction.AccessMode? = nil,
        declineConsequence: String? = nil
    ) -> InlineInteraction? {
        guard let primary = capabilities.first else { return nil }
        // Name the access being granted, using Mac Control capability nouns or MacIntegration's own display name.
        let grantPhrase = englishList(capabilities.map {
            macControlCategoryGrantNouns[$0] ?? macCapabilityDisplayName($0)
        })
        return InlineInteraction(
            kind: .permission,
            target: primary,
            additionalTargets: Array(capabilities.dropFirst()),
            mode: mode,
            title: "Allow \(grantPhrase)",
            why: why,
            primaryActionLabel: "Allow \(grantPhrase)",
            declineConsequence: declineConsequence
                ?? "I'll leave \(grantPhrase) " + InlineInteraction.ConsequenceCopy.permissionLeaveAlone,
            // Explain that a grant persists beyond the current turn before the person chooses it.
            persistenceNote: capabilities.allSatisfy { !MacIntegrationID.all.contains($0) && !isMacControlCategory($0)
                && SystemPermissionPreflight.cardSettingsCapability($0) != nil }
                ? "macOS keeps your decision until you change it in System Settings."
                : "Stays on until you turn it off in Trust.",
            cardProse: "I need your go-ahead for \(grantPhrase) \u{2014} allow it below, "
                + InlineInteraction.ConsequenceCopy.keepGoingSuffix
        )
    }

    /// Permanent group changes go through Providers' page; the option must not be decoded as a model.
    public static let persistentChoiceOptionID = "__save_for_group__"

    /// Read image-capable options from the same checked provider catalog and image-route table as Providers; hide accounts absent from the routing snapshot.
    public static func imageCapableModelOptions(
        providerIDs: [String], dataRoot: URL
    ) throws -> [InlineInteraction.Option] {
        var seen: Set<String> = []
        var rows: [(providerID: String, model: ProviderModelInfo, routeModel: String)] = []
        for providerID in providerIDs {
            guard let route = FirstPartyModelCatalog.imageRoute(forProviderID: providerID)
            else { continue }
            let catalog = try SwiftNativeProviderRouting(dataRoot: dataRoot).checkedCatalogModels(for: providerID)
            for model in catalog {
                // Qualify and deduplicate by account/model pair; a bare model ID cannot identify the correct connected account.
                guard seen.insert("\(providerID.lowercased())::\(model.id.lowercased())").inserted
                else { continue }
                rows.append((providerID, model, route.model))
            }
        }
        // Show the account name only when needed to distinguish model options, as the Providers page names it.
        var countsByModel: [String: Int] = [:]
        for row in rows { countsByModel[row.model.id.lowercased(), default: 0] += 1 }
        let routing = SwiftNativeProviderRouting(dataRoot: dataRoot)
        return try rows.map { row in
            let name = row.model.name.isEmpty ? row.model.id : row.model.name
            var label = name
            if (countsByModel[row.model.id.lowercased()] ?? 0) > 1 { label += " (\(try routing.providerDisplayName(row.providerID)))" }
            return InlineInteraction.Option(
                id: modelOptionID(providerID: row.providerID, modelID: row.model.id),
                label: label,
                detail: "Makes pictures through \(row.routeModel)."
            )
        }
    }

    /// Read the account from the option identity; guessing from a model ID can select the wrong connected account.
    public static func modelOptionID(providerID: String, modelID: String) -> String {
        "\(providerID)::\(modelID)"
    }

    public static func splitModelOptionID(_ id: String) -> (providerID: String, modelID: String)? {
        guard let separator = id.range(of: "::") else { return nil }
        let providerID = String(id[id.startIndex..<separator.lowerBound])
        let modelID = String(id[separator.upperBound...])
        guard !providerID.isEmpty, !modelID.isEmpty else { return nil }
        return (providerID, modelID)
    }

    /// A request-scoped choice changes only the resumed work; a permanent group change requires explicit selection.
    public static func modelChoice(
        group: String,
        why: String,
        options: [InlineInteraction.Option],
        scopedToThisRequest: String? = nil,
        declineConsequence: String? = nil
    ) -> InlineInteraction {
        let title = ProviderSurfaceGroups.all.first { $0.id == group }?.title ?? group
        if let scopeNoun = scopedToThisRequest {
            // The permanent alternative is a CHOICE in the list, not a second affirmative button: the card grammar has one primary and one quiet decline, and a
            // scope this consequential must be picked deliberately rather than tapped past.
            var scopedOptions = options
            if !options.isEmpty {
                scopedOptions.append(
                    InlineInteraction.Option(
                        id: persistentChoiceOptionID,
                        label: "Save for every \(title) task",
                        detail: "Opens Providers, where the \(title) group's model is saved."
                    )
                )
            }
            return InlineInteraction(
                kind: .modelChoice,
                target: group,
                title: "Choose a model",
                why: why,
                primaryActionLabel: "Just \(scopeNoun)",
                declineConsequence: declineConsequence
                    ?? InlineInteraction.ConsequenceCopy.modelScopedSkip + "\(title) models as they are.",
                cardProse: "I need to know which model to use \u{2014} pick one below, "
                    + InlineInteraction.ConsequenceCopy.keepGoingSuffix,
                options: scopedOptions,
                primaryScope: .thisRequestOnly
            )
        }
        return InlineInteraction(
            kind: .modelChoice,
            target: group,
            title: "Choose a model for \(title)",
            why: why,
            primaryActionLabel: "Use this model",
            declineConsequence: declineConsequence
                ?? InlineInteraction.ConsequenceCopy.modelStopHere,
            cardProse: "I need to know which model \(title) should use \u{2014} pick one below, "
                + InlineInteraction.ConsequenceCopy.keepGoingSuffix,
            options: options,
            primaryScope: .persistent,
            state: .pending
        )
    }

    public static func apiKey(
        provider rawProvider: String,
        why: String,
        declineConsequence: String? = nil
    ) -> InlineInteraction {
        let provider = canonicalProviderID(rawProvider)
        let name = providerDisplayName(provider)
        return InlineInteraction(
            kind: .apiKey,
            target: provider,
            title: providerSignIn(for: provider) == nil ? "Add your \(name) key" : "Connect \(name)",
            why: why,
            primaryActionLabel: "Connect \(name)",
            declineConsequence: declineConsequence
                ?? "Without a key I can't reach \(name)" + InlineInteraction.ConsequenceCopy.apiKeyNothingChanges,
            persistenceNote: "Saved on this Mac until you remove it.",
            cardProse: (providerSignIn(for: provider) == nil
                ? "I need a key for \(name)" : "I need \(name) connected")
                + " \u{2014} enter it in the protected entry on the Mac, "
                + InlineInteraction.ConsequenceCopy.keepGoingSuffix
        )
    }

    /// Name the secret's allowed destination so granting it does not imply unrestricted disclosure.
    public static func secret(
        _ name: String, ask: InlineInteraction.SecretAsk, why: String, declineConsequence: String? = nil
    ) -> InlineInteraction {
        if ask.remove == true {
            return InlineInteraction(
                kind: .apiKey, target: "secret:" + name, title: "Remove the \(name) key", why: why,
                primaryActionLabel: "Remove \(name)",
                declineConsequence: declineConsequence ?? "\(name) stays kept; nothing changes.",
                cardProse: "Shall I have \(name) removed? Confirm below, " + InlineInteraction.ConsequenceCopy.keepGoingSuffix,
                secret: ask
            )
        }
        return InlineInteraction(
            kind: .apiKey,
            target: "secret:" + name,
            title: ask.signIn == nil ? "Add the \(name) key" : "Sign in for \(name)",
            why: why,
            primaryActionLabel: "Connect \(name)",
            declineConsequence: declineConsequence
                ?? "Without it I can't use \(name)" + InlineInteraction.ConsequenceCopy.apiKeyNothingChanges,
            persistenceNote: "Kept in this Mac's Keychain.",
            cardProse: "I need \(name) \u{2014} add it below, " + InlineInteraction.ConsequenceCopy.keepGoingSuffix,
            secret: ask
        )
    }

    public static func capability(
        _ flagID: String,
        why: String? = nil,
        declineConsequence: String? = nil
    ) -> InlineInteraction? {
        guard let flag = capabilityFlags[flagID] else { return nil }
        return InlineInteraction(
            kind: .capability,
            target: flag.id,
            title: "Turn on \(flag.displayName.lowercased())",
            why: why ?? flag.why,
            primaryActionLabel: "Turn on \(flag.displayName.lowercased())",
            declineConsequence: declineConsequence
                ?? InlineInteraction.ConsequenceCopy.capabilityStaysOff,
            persistenceNote: "Stays on until you turn it off in Trust.",
            cardProse: "I need \(flag.displayName.lowercased()) switched on \u{2014} "
                + "turn it on below, " + InlineInteraction.ConsequenceCopy.keepGoingSuffix
        )
    }

    public static func choose(
        question: String,
        why: String,
        options: [InlineInteraction.Option],
        declineConsequence: String
    ) -> InlineInteraction? {
        guard !options.isEmpty else { return nil }
        return InlineInteraction(
            kind: .choose,
            target: "",
            title: question,
            why: why,
            primaryActionLabel: "Choose",
            declineConsequence: declineConsequence,
            cardProse: "I need an answer before I carry on \u{2014} choose below, "
                + InlineInteraction.ConsequenceCopy.keepGoingSuffix,
            options: options
        )
    }

    // MARK: - Prose helpers

    public static func englishList(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default:
            return items.dropLast().joined(separator: ", ") + ", and " + (items.last ?? "")
        }
    }

    static func titleCased(_ id: String) -> String {
        id.split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
