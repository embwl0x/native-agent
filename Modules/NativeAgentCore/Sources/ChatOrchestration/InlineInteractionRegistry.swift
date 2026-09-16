import Foundation
import MacControl
import MacIntegration
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting

/// Turns a canonical ID into a card, without any per-service code.
///
/// Everything here is DERIVED from a registry that already exists for its own
/// reasons — the connector registry on disk, `MacIntegrationID`, the Providers
/// group table, the trust-policy capability catalog. Adding a connector adds a
/// row to `connectors/registry.json` and nothing else: no card branch, no
/// button, no new copy. An id no registry knows produces an `unavailable`
/// descriptor, which the card renders as a statement rather than a dead
/// control.
///
/// The one thing a registry cannot derive is HOW an account is set up
/// (a pasted token vs. a native OAuth flow). That table lives here, once, and
/// `ConnectorWizardSetupRoute` reads it instead of holding its own copy.
public enum InlineInteractionRegistry {

    // MARK: - Connector setup routes
    //
    // Moved out of ConnectorWizardView so the wizard and the card cannot
    // disagree about how a given account is connected. At review-0414f GitHub
    // and Slack are Personal Access Tokens, NOT OAuth — the card must say
    // "Paste a token", because offering "Sign in with GitHub" would be a lie.

    public enum ConnectorSetup: String, Sendable, Equatable {
        case manualToken
        case oauth
        case unavailable
    }

    /// Canonical connector id → how it is set up. Aliases resolve to the
    /// canonical id first, so `email`/`calendar` land on `gmail`/`gcal`.
    public static func connectorSetup(for rawID: String) -> ConnectorSetup {
        switch canonicalConnectorID(rawID) {
        case "github", "slack", "notion", "telegram":
            return .manualToken
        case "x", "gmail", "gcal":
            return .oauth
        default:
            return .unavailable
        }
    }

    /// Alias folding. The registry, the OAuth store, and the wizard each grew
    /// their own spellings (`email` → `gmail`, `calendar`/`google_calendar` →
    /// `gcal`, `twitter` → `x`); a need raised with any of them must reach the
    /// same descriptor.
    public static func canonicalConnectorID(_ rawID: String) -> String {
        switch rawID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "email": return "gmail"
        case "calendar", "google_calendar": return "gcal"
        case "twitter": return "x"
        case let other: return other
        }
    }

    // MARK: - Descriptors

    /// The descriptor for one need. `dataRoot` is read only for the connector
    /// registry's display names; every other lookup is in-process.
    public static func descriptor(
        kind: InlineInteraction.Kind,
        target: String,
        additionalTargets: [String] = [],
        dataRoot: URL
    ) -> InlineInteractionDescriptor {
        switch kind {
        case .connector:
            let id = canonicalConnectorID(target)
            let setup = connectorSetup(for: id)
            return InlineInteractionDescriptor(
                kind: .connector,
                target: id,
                displayName: connectorDisplayName(id, dataRoot: dataRoot),
                icon: "link",
                control: {
                    switch setup {
                    case .manualToken: return .connectorManualToken
                    case .oauth: return .connectorOAuth
                    case .unavailable: return .unavailable
                    }
                }(),
                // Both routes end at a browser or a pasted secret. Neither can
                // be completed from the phone.
                location: .macRequired,
                unavailableReason: setup == .unavailable
                    ? "This build has no setup flow for \(target)."
                    : nil
            )

        case .permission:
            // EVERY capability this card would grant, not just the one it is
            // named after. A need can carry a chain (`also_needed`), and the
            // grant writes all of them — so a descriptor derived from the
            // primary alone offers a live grant button for a chain whose OTHER
            // half the posture forbids, and the write lands as a latent allow
            // that switches on the day the person moves to Full Mac.
            let targets = ([target] + additionalTargets).filter { !$0.isEmpty }
            let known = !targets.isEmpty && targets.allSatisfy {
                MacIntegrationID.all.contains($0) || isMacControlCategory($0)
            }
            // User's fence, in code: Safe and Workspace are the person's own
            // standing posture and no card may move it. When the posture
            // forbids the whole category, the card says so and the only thing
            // it offers is the page where that decision actually lives.
            let posturePermits = !targets.contains(where: isMacControlCategory)
                || macControlPostureAllowsCategories(dataRoot: dataRoot)
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
                unavailableReason: known ? nil : "No such Mac capability on this build."
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

        case .apiKey:
            return InlineInteractionDescriptor(
                kind: .apiKey,
                target: target,
                displayName: providerDisplayName(target),
                icon: "key",
                control: target.isEmpty ? .unavailable : .providerAPIKey,
                // A key is typed by the person, on the Mac. The phone API
                // refuses keys through iCloud on purpose.
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
                // NOT a universal flag writer: only catalogued,
                // user-configurable flags have a control.
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

    /// From `connectors/registry.json` — the same catalog Connectors renders.
    /// A connector added there is named correctly here with no code change.
    public static func connectorDisplayName(_ id: String, dataRoot: URL) -> String {
        let canonical = canonicalConnectorID(id)
        if let name = connectorRegistryNames(dataRoot: dataRoot)[canonical],
           !name.isEmpty {
            return name
        }
        // The registry on disk is written lazily and its rows often carry no
        // `name` at all, so title-casing the id was the common path, not the
        // rare one — and it renders "Connect Github", with a lowercase h, on a
        // fresh install. These are proper nouns; they have one spelling. Same
        // species as `macControlCategoryTitles` below: a display-name table,
        // not a per-service branch.
        if let known = connectorDisplayNames[canonical] { return known }
        return titleCased(canonical)
    }

    /// How each connector spells its own name. Consulted only when the
    /// registry on disk does not answer.
    static let connectorDisplayNames: [String: String] = [
        "github": "GitHub",
        "gmail": "Gmail",
        "gcal": "Google Calendar",
        "slack": "Slack",
        "notion": "Notion",
        "telegram": "Telegram",
        "x": "X",
    ]

    private static func connectorRegistryNames(dataRoot: URL) -> [String: String] {
        let path = dataRoot
            .appendingPathComponent("connectors", isDirectory: true)
            .appendingPathComponent("registry.json")
        guard let data = try? Data(contentsOf: path),
              let value = try? JSONValue.parse(data)
        else { return [:] }
        // The registry is either a bare array of rows or an object wrapping
        // one; accept both rather than pinning a shape this type does not own.
        let rows: [JSONValue]
        switch value {
        case .array(let array):
            rows = array
        case .object(let object):
            if case .array(let array)? = object["connectors"] ?? object["items"] {
                rows = array
            } else {
                rows = []
            }
        default:
            rows = []
        }
        var names: [String: String] = [:]
        for row in rows {
            guard case .object(let object) = row,
                  case .string(let id)? = object["id"],
                  case .string(let name)? = object["name"]
            else { continue }
            names[canonicalConnectorID(id)] = name
        }
        return names
    }

    /// Mac Integration ids own their display names; the five Mac Control
    /// approval categories carry Trust's own titles.
    public static func macCapabilityDisplayName(_ id: String) -> String {
        if MacIntegrationID.all.contains(id) {
            return MacIntegrationID.displayName(for: id)
        }
        // The card names the thing being allowed ("File access"), not the
        // switch's own row title in Trust ("File changes") — a read that says
        // "File changes" reads as a lie to the person granting it.
        if let noun = macControlCategoryGrantNouns[id] {
            return noun.prefix(1).uppercased() + noun.dropFirst()
        }
        return macControlCategoryTitles[id] ?? titleCased(id)
    }

    /// Trust's own wording for the Mac Control categories (MacControlPermissions).
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

    /// The noun a grant is phrased with: "Allow file access", not "Allow File
    /// changes". Trust's own titles name the SWITCH; a card names the thing the
    /// person is allowing.
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

    /// True when `id` is one of Trust's Mac Control approval categories rather
    /// than a MacIntegration capability. The two are granted by DIFFERENT
    /// owners, which is the whole reason this question is asked.
    public static func isMacControlCategory(_ id: String) -> Bool {
        macControlCategoryTitles[id] != nil
    }

    /// Whether the SAVED Trust posture permits Mac Control categories at all.
    ///
    /// Read straight off `trust/policy.json` through MacControl's own gate, so
    /// the card cannot disagree with the thing that will refuse the call. Under
    /// Safe or Workspace this is false, and no per-category switch would take
    /// effect even if one were written — so the card must not offer to write one.
    public static func macControlPostureAllowsCategories(dataRoot: URL) -> Bool {
        guard let trust = macControlPolicySnapshot(dataRoot: dataRoot).trustPolicy
        else { return false }
        return MacControlGate.fullMacActive(trust)
    }

    /// Whether the saved policy already allows a category — the same question
    /// the dispatch gate asks, so a settled card and a working call agree.
    public static func macControlCategoryAllowed(_ category: String, dataRoot: URL) -> Bool {
        let policy = macControlPolicySnapshot(dataRoot: dataRoot)
        guard let trust = policy.trustPolicy, MacControlGate.fullMacActive(trust) else {
            return false
        }
        return MacControlGate.gate(policy, category: category).allowed
    }

    static func macControlPolicySnapshot(dataRoot: URL) -> MacControlPolicy {
        let path = dataRoot
            .appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("policy.json")
        guard let data = try? Data(contentsOf: path),
              let value = try? JSONValue.parse(data),
              case .object(let root) = value
        else { return MacControlPolicy.default }
        return MacControlPolicy.fromTrustPolicyObject(root)
    }

    public static func providerDisplayName(_ id: String) -> String {
        titleCased(id)
    }

    // MARK: - Capability catalog

    /// The user-configurable capability flags, with the trust-policy path each
    /// one writes. This IS the catalog: a flag absent from here has no control
    /// and cannot be switched on by raising a card, which is what keeps
    /// `needs_capability` from becoming a universal flag writer.
    public struct CapabilityFlag: Sendable, Equatable {
        public var id: String
        public var displayName: String
        /// Trust policy block, then key inside it.
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
        "vision_api_calls": CapabilityFlag(
            id: "vision_api_calls",
            displayName: "Image understanding",
            policyBlock: "multimodalPolicy",
            policyKey: "vision_api_calls",
            why: "Looking at images " + InlineInteraction.ConsequenceCopy.trustSwitchedOff
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
    //
    // One place that writes the prose, so every card in the app says the same
    // KIND of thing: one title, one sentence of why, a real primary label, and
    // — Agent's rule — what happens if you say no. A need with no decline
    // consequence cannot be constructed.

    public static func connector(
        _ rawID: String,
        why: String,
        dataRoot: URL,
        declineConsequence: String? = nil
    ) -> InlineInteraction {
        let id = canonicalConnectorID(rawID)
        let descriptor = descriptor(kind: .connector, target: id, dataRoot: dataRoot)
        let name = descriptor.displayName
        return InlineInteraction(
            kind: .connector,
            target: id,
            title: "Connect \(name)",
            why: why,
            // Agent, 2026-09-13: the primary says the OUTCOME. "Paste a token"
            // described the mechanics of one of the two setup routes; what the
            // person is buying is \(name), connected.
            primaryActionLabel: "Connect \(name)",
            declineConsequence: declineConsequence
                ?? "Without \(name) I can't do this part, and " + InlineInteraction.ConsequenceCopy.connectorCarryOn,
            persistenceNote: "Stays connected until you disconnect it in Connectors.",
            cardProse: "I need \(name) for this \u{2014} connect it below, "
                + InlineInteraction.ConsequenceCopy.keepGoingSuffix
        )
    }

    /// One need, every capability it covers. Agent's rule: when the checker
    /// can know a request needs Mac Control AND Desktop access, it asks ONCE
    /// and the person grants once — step-by-step escalation is for the cases
    /// where the second need genuinely cannot be known in advance.
    public static func permission(
        _ capabilities: [String],
        why: String,
        mode: InlineInteraction.AccessMode? = nil,
        declineConsequence: String? = nil
    ) -> InlineInteraction? {
        guard let primary = capabilities.first else { return nil }
        // A Mac Control category is named by what it lets the agent DO
        // ("Allow file access"); a MacIntegration capability is named by its
        // own display name, as it always was.
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
            // The outcome, named: "Allow Calendar", never a bare "Allow".
            primaryActionLabel: "Allow \(grantPhrase)",
            declineConsequence: declineConsequence
                ?? "I'll leave \(grantPhrase) " + InlineInteraction.ConsequenceCopy.permissionLeaveAlone,
            // User's fence, said out loud on the card: a grant is not for one
            // turn, and the person should know that before they tap.
            persistenceNote: "Stays on until you turn it off in Trust.",
            cardProse: "I need your go-ahead for \(grantPhrase) \u{2014} allow it below, "
                + InlineInteraction.ConsequenceCopy.keepGoingSuffix
        )
    }

    /// The one option id that is not a model: "save this for the whole group",
    /// resolved through Providers' own page like every other permanent change.
    public static let persistentChoiceOptionID = "__save_for_group__"

    /// The models on this Mac that can make a picture, as options.
    ///
    /// Provider-blind by construction: the only per-provider thing consulted is
    /// DATA — `FirstPartyModelCatalog`'s own image-route table and its model
    /// tables, the same catalog the Providers page renders. `providerIDs` is
    /// whatever the routing snapshot says this person actually uses, so a
    /// catalog row for an account they do not have never appears. No branch
    /// anywhere names a provider.
    public static func imageCapableModelOptions(
        providerIDs: [String]
    ) -> [InlineInteraction.Option] {
        var seen: Set<String> = []
        var rows: [(providerID: String, model: FirstPartyModelDescriptor, routeModel: String)] = []
        for providerID in providerIDs {
            guard let route = FirstPartyModelCatalog.imageRoute(forProviderID: providerID)
            else { continue }
            for model in FirstPartyModelCatalog.models(forProviderID: providerID) {
                // An option names the ACCOUNT and the model. Before this it
                // named the model alone and the resolver inferred the account
                // back from the id — which sends every bare `gpt-*` to the
                // OAuth route, so an API-key-only install resumed through an
                // account it has never connected. Dedupe is on the pair for
                // the same reason: two accounts serving one model id are two
                // different answers, not a duplicate.
                guard seen.insert("\(providerID.lowercased())::\(model.id.lowercased())").inserted
                else { continue }
                rows.append((providerID, model, route.model))
            }
        }
        // The account name appears ONLY where it is needed to tell two rows
        // apart; otherwise the person reads a model name, as before.
        var countsByModel: [String: Int] = [:]
        for row in rows { countsByModel[row.model.id.lowercased(), default: 0] += 1 }
        return rows.map { row in
            let name = row.model.name.isEmpty ? row.model.id : row.model.name
            let ambiguous = (countsByModel[row.model.id.lowercased()] ?? 0) > 1
            return InlineInteraction.Option(
                id: modelOptionID(providerID: row.providerID, modelID: row.model.id),
                label: ambiguous ? "\(name) (\(providerDisplayName(row.providerID)))" : name,
                detail: "Makes pictures through \(row.routeModel)."
            )
        }
    }

    /// A model option's identity: which account, then which model. The
    /// resolver reads the account straight off this instead of guessing it
    /// from the model id.
    public static func modelOptionID(providerID: String, modelID: String) -> String {
        providerID.isEmpty ? modelID : "\(providerID)::\(modelID)"
    }

    /// Split a provider-qualified option id. `nil` for a bare model id — every
    /// card written before this existed — which the caller resolves the old way.
    public static func splitModelOptionID(_ id: String) -> (providerID: String, modelID: String)? {
        guard let separator = id.range(of: "::") else { return nil }
        let providerID = String(id[id.startIndex..<separator.lowerBound])
        let modelID = String(id[separator.upperBound...])
        guard !providerID.isEmpty, !modelID.isEmpty else { return nil }
        return (providerID, modelID)
    }

    /// A model choice for a Providers group.
    ///
    /// `scopedToThisRequest` is Agent's one-image seam: for a single piece of
    /// work, the PRIMARY action binds the choice to this request only and the
    /// SECONDARY is the permanent group change. Choosing a model to finish one
    /// picture must never silently rewrite what every Work task runs on.
    public static func modelChoice(
        group: String,
        why: String,
        options: [InlineInteraction.Option],
        scopedToThisRequest: String? = nil,
        declineConsequence: String? = nil
    ) -> InlineInteraction {
        let title = ProviderSurfaceGroups.all.first { $0.id == group }?.title ?? group
        if let scopeNoun = scopedToThisRequest {
            // The permanent alternative is a CHOICE in the list, not a second
            // affirmative button: the card grammar has one primary and one
            // quiet decline, and a scope this consequential must be picked
            // deliberately rather than tapped past.
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
        provider: String,
        why: String,
        declineConsequence: String? = nil
    ) -> InlineInteraction {
        let name = providerDisplayName(provider)
        return InlineInteraction(
            kind: .apiKey,
            target: provider,
            title: "Add your \(name) key",
            why: why,
            // The outcome of pasting a key is \(name), reachable.
            primaryActionLabel: "Connect \(name)",
            declineConsequence: declineConsequence
                ?? "Without a key I can't reach \(name)" + InlineInteraction.ConsequenceCopy.apiKeyNothingChanges,
            persistenceNote: "Stored in your Mac's Keychain until you remove it.",
            cardProse: "I need a key for \(name) \u{2014} add it below, "
                + InlineInteraction.ConsequenceCopy.keepGoingSuffix
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
