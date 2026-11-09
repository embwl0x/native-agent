import ChatToolRuntime
import Foundation
import MacIntegration
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import ApprovalTransactions
// Blueprint: | `InlineDecisions.swift` | Owner-backed controls and honest receipts. |

/// Kind selects content and symbol without creating a separate visual style.
public enum InlineCardKind: String, Sendable, Equatable, CaseIterable {
    case needsConnector
    case needsPermission
    case needsModelChoice
    case needsAPIKey
    case needsCapability
    case choose
    case confirm
    case work

}

/// Derive presentation from the lifecycle owner; never store a second lifecycle here.
public enum InlineCardState: String, Sendable, Equatable, CaseIterable {
    case pending
    case running
    case settled
    case declined
    case failed
    case stopped
    /// Terminal and honest about not knowing: neither done nor declined.
    case unknown
    /// Superseded asks retain a quiet receipt so only one identical ask stays live.
    case superseded

    public var isTerminal: Bool {
        switch self {
        case .pending, .running: return false
        case .settled, .declined, .failed, .stopped, .unknown, .superseded: return true
        }
    }
}

public struct InlineCardChoice: Identifiable, Sendable, Equatable {
    public let id: String
    public var title: String
    /// Consequences belong beside their option so the decision is informed.
    public var note: String?
    /// The primary names the selected outcome; nil keeps the card's own label.
    public var actionLabel: String?

    public init(id: String, title: String, note: String? = nil, actionLabel: String? = nil) {
        self.id = id
        self.title = title
        self.note = note
        self.actionLabel = actionLabel
    }
}

/// Presentation carries no resolution policy.
public struct InlineCardModel: Identifiable, Sendable, Equatable {
    /// Bound to the originating request, not to the last message: a second observation of the same blocked request updates this card.
    public let id: String
    public var sessionID = ""
    public var kind: InlineCardKind
    public var target: String
    public var title: String
    /// One sentence. A writing constraint, not a line limit — it wraps.
    public var why: String
    public var primaryLabel: String
    public var secondaryLabel: String
    /// Required on every card: what taking the quiet option costs.
    public var consequence: String
    public var state: InlineCardState
    /// Permission cards must state how long the grant lasts.
    public var persistenceNote: String?
    /// What the card collects, in order. Values never become transcript content.
    public var fields: [InlineCardField]
    public var field: InlineCardField? { fields.first }
    /// An empty form may sign in; entering a value switches the primary to saving it.
    public var signInLabel: String?
    public var fullSetupLabel: String?
    public var choices: [InlineCardChoice]
    /// Keep consequential scope on the card face rather than behind disclosure.
    public var scopeLines: [String]
    public var identifier: String?
    public var detailsLabel: String?
    public var detailsBody: String?
    public var busyLabel: String?
    public var busyNote: String?
    /// The card's one restart for its launch-applied grants, said in full; nil when the card does not offer it.
    public var restartNote: String?
    public var outcome: String?
    public var outcomeMeta: String?
    public var canStop: Bool
    public var canRetry: Bool

    /// The one answer to "does this card still need the person": delivery, the Inbox, Today and the phone all read it from the live card.
    public var needsAttention: Bool {
        !state.isTerminal || (state == .failed && canRetry)
    }

    public init(
        id: String,
        kind: InlineCardKind,
        target: String = "",
        title: String,
        why: String,
        primaryLabel: String,
        secondaryLabel: String = "Not now",
        consequence: String,
        state: InlineCardState = .pending,
        persistenceNote: String? = nil,
        field: InlineCardField? = nil,
        fields: [InlineCardField] = [],
        signInLabel: String? = nil,
        fullSetupLabel: String? = nil,
        choices: [InlineCardChoice] = [],
        scopeLines: [String] = [],
        identifier: String? = nil,
        detailsLabel: String? = nil,
        detailsBody: String? = nil,
        busyLabel: String? = nil,
        busyNote: String? = nil,
        restartNote: String? = nil,
        outcome: String? = nil,
        outcomeMeta: String? = nil,
        canStop: Bool = false,
        canRetry: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.target = target
        self.title = title
        self.why = why
        self.primaryLabel = primaryLabel
        self.secondaryLabel = secondaryLabel
        self.consequence = consequence
        self.state = state
        self.persistenceNote = persistenceNote
        self.fields = fields.isEmpty ? (field.map { [$0] } ?? []) : fields
        self.signInLabel = signInLabel
        self.fullSetupLabel = fullSetupLabel
        self.choices = choices
        self.scopeLines = scopeLines
        self.identifier = identifier
        self.detailsLabel = detailsLabel
        self.detailsBody = detailsBody
        self.busyLabel = busyLabel
        self.busyNote = busyNote
        self.restartNote = restartNote
        self.outcome = outcome
        self.outcomeMeta = outcomeMeta
        self.canStop = canStop
        self.canRetry = canRetry
    }

}

/// Purely join owner-backed controls to presentation; never store, dispatch or resolve here. Missing controls render terminal unknown, never a button that
/// cannot act. The secondary always declines; affirmative alternatives belong in scope or options.
public enum InlineCards {

    // MARK: - Kind and state, 1:1

    public static func kind(_ kind: InlineInteraction.Kind) -> InlineCardKind {
        switch kind {
        case .connector: return .needsConnector
        case .permission: return .needsPermission
        case .modelChoice: return .needsModelChoice
        case .apiKey: return .needsAPIKey
        case .capability: return .needsCapability
        // Unknown kinds stay neutral and terminal because this build cannot answer them.
        case .choose, .unknown: return .choose
        }
    }

    public static func state(_ state: InlineInteraction.State) -> InlineCardState {
        switch state {
        case .pending: return .pending
        case .running: return .running
        case .settled: return .settled
        case .declined: return .declined
        case .failed: return .failed
        case .stopped: return .stopped
        case .unknown: return .unknown
        case .superseded: return .superseded
        }
    }

    // MARK: - The projection

    public static func model(
        _ interaction: InlineInteraction,
        descriptor: InlineInteractionDescriptor,
        repeatCount: Int = 1
    ) -> InlineCardModel {
        // A missing control cannot honestly offer an action.
        let deadControl = !descriptor.isActionable && interaction.state.isOpen
        let continuationFailed = interaction.continuationFailure != nil
        let cardState: InlineCardState = continuationFailed ? .failed : deadControl ? .unknown : state(interaction.state)
        let receipt = outcome(interaction, deadControl: deadControl, repeatCount: repeatCount)

        return InlineCardModel(
            id: interaction.id,
            kind: kind(interaction.kind),
            target: descriptor.displayName,
            title: interaction.title,
            why: interaction.why,
            primaryLabel: primaryLabel(interaction, descriptor),
            // The quiet command declines; affirmative alternatives belong in scope.
            secondaryLabel: "Not now",
            consequence: [.connector, .apiKey].contains(interaction.kind) && interaction.secret?.remove != true
                ? "If you skip, \(descriptor.displayName) stays off."
                : interaction.declineConsequence,
            state: cardState,
            persistenceNote: interaction.persistenceNote,
            fields: continuationFailed ? [] : fields(interaction, descriptor),
            signInLabel: InlineInteractionRegistry.providerSignIn(for: descriptor.target)
                .flatMap { descriptor.control == .providerAPIKey ? "Sign in with \($0.displayShort)" : nil }
                ?? (interaction.secret?.signIn == nil ? nil : "Sign in"),
            // Detailed service policies belong on the full page, beyond the card's controls.
            fullSetupLabel: !continuationFailed && descriptor.control == .connectorManualToken ? "Open full setup" : nil,
            choices: interaction.options.map {
                InlineCardChoice(
                    id: $0.id, title: $0.label, note: $0.detail,
                    // Model options name their outcome; the group-wide save row keeps the card label.
                    actionLabel: $0.id == InlineInteractionRegistry.persistentChoiceOptionID
                        ? nil : "Use \($0.label)"
                )
            },
            scopeLines: scopeLines(interaction, descriptor),
            // Receipts cannot promise a future primary action or expand beyond their outcome line.
            detailsLabel: rendersAsReceipt(cardState)
                ? nil : details(interaction, descriptor)?.label,
            detailsBody: rendersAsReceipt(cardState)
                ? nil : details(interaction, descriptor)?.body,
            busyLabel: busyLabel(interaction.kind),
            busyNote: busyNote(interaction, descriptor.control),
            restartNote: restartNote(interaction),
            outcome: interaction.continuationFailure.map {
                let reason = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return "Failed to continue: " + (reason.isEmpty ? "no cause was recorded." : reason)
            } ?? receipt.text,
            outcomeMeta: continuationFailed
                ? [receipt.text, receipt.meta].compactMap { $0 }.joined(separator: "\n\n")
                : receipt.meta ?? (deadControl ? descriptor.unavailableReason : nil),
            // Only running work owns Stop; a need is waiting on the person.
            canStop: false,
            // Retry is the shared lifecycle's; a build with no control for it cannot offer one.
            canRetry: continuationFailed || (descriptor.isActionable && interaction.state.isRetryable)
        )
    }

    /// Failures retain explanation and retry controls rather than collapsing to a receipt.
    private static func rendersAsReceipt(_ state: InlineCardState) -> Bool {
        switch state {
        case .settled, .declined, .unknown, .superseded: return true
        case .pending, .running, .failed, .stopped: return false
        }
    }

    // MARK: - Parts

    /// A model choice without options must name the control that can actually offer them.
    private static func primaryLabel(
        _ interaction: InlineInteraction,
        _ descriptor: InlineInteractionDescriptor
    ) -> String {
        if interaction.kind == .modelChoice, interaction.options.isEmpty {
            return "Choose in Providers"
        }
        // A posture card grants nothing; the only true label is the page.
        if descriptor.control == .trustPostureRequired {
            return "Open Trust"
        }
        switch interaction.kind {
        case .apiKey where interaction.secret?.remove == true:
            return interaction.primaryActionLabel
        case .connector, .apiKey:
            return "Connect \(descriptor.displayName)"
        case .permission:
            let names = interaction.allTargets.map(
                InlineInteractionRegistry.macCapabilityDisplayName
            )
            let phrase = InlineInteractionRegistry.englishList(names)
            return phrase.isEmpty ? interaction.primaryActionLabel : "Allow \(phrase)"
        case .capability:
            return "Turn on \(descriptor.displayName.lowercased())"
        case .modelChoice, .choose, .unknown:
            return interaction.primaryActionLabel
        }
    }

    /// Fields save through their owner and verify there so they are controls rather than decoration.
    private static func fields(_ interaction: InlineInteraction, _ descriptor: InlineInteractionDescriptor) -> [InlineCardField] {
        switch descriptor.control {
        case .keyring:
            // Removal takes no value; sign-in fetches its own except for a service-issued client secret.
            if interaction.secret?.remove == true { return [] }
            guard interaction.secret?.signIn == nil else {
                let basic = interaction.secret?.signIn?.clientAuth == "basic"
                return [InlineCardField(label: "Client secret", placeholder: basic ? "The secret the service issued" : "Only if the service issued one",
                                        helper: "Kept in this Mac's Keychain with the sign-in. The chat and the agent never see it.",
                                        isSecret: true, isOptional: !basic)]
            }
            return [InlineCardField(label: "\(descriptor.displayName) key", placeholder: "Paste the key",
                                    helper: "Kept in this Mac's Keychain. The chat and the agent never see it.", isSecret: true)]
        case .connectorManualToken:
            return descriptor.connectorFields
        case .providerAPIKey:
            return [] // A provider row points to protected Mac entry; it never collects a value.
        default:
            return []
        }
    }

    /// Show grant scope and resolution reach on the card face.
    private static func scopeLines(
        _ interaction: InlineInteraction,
        _ descriptor: InlineInteractionDescriptor
    ) -> [String] {
        var lines: [String] = []

        if interaction.kind == .permission {
            for capability in interaction.allTargets {
                let name = InlineInteractionRegistry.macCapabilityDisplayName(capability)
                lines.append("\(name) — \(axes(capability, mode: interaction.mode))")
            }
            if descriptor.control == .trustPostureRequired {
                // The card cannot change posture; its face must not imply that it can.
                lines.append(
                    "Your Trust posture doesn't allow this at all — it can only be changed in Trust."
                )
            }
        }

        if [.permission, .capability].contains(interaction.kind) {
            lines += SystemPermissionPreflight.cardSettingsInstructions(interaction.allTargets)
        }

        // A secret's grant is where it may go, and nowhere else.
        if let ask = interaction.secret, ask.remove != true {
            lines.append("Goes only to \(ask.line)")
            if let stops = ask.stops { lines.append("Stops going to \(stops.joined(separator: ", "))") }
            if let signIn = ask.signIn {
                let host = { (address: String?) in address.flatMap(URL.init(string:))?.host ?? "" }
                lines.append("Signs in at \(host(signIn.authorize ?? signIn.device)); token from \(host(signIn.token))")
            }
        }

        // Request-only scope requires local model options; choices made in Providers are saved.
        if interaction.kind == .modelChoice {
            if interaction.options.isEmpty {
                lines.append("Saved for every \(descriptor.displayName) task.")
            } else if interaction.primaryScope == .thisRequestOnly {
                // Exclude the permanent-save row from the request-only scope promise.
                lines.append("Picking a model applies to this request only — nothing is saved.")
            } else {
                lines.append("Saved for every \(descriptor.displayName) task.")
            }
        }
        return lines
    }

    /// Describe the real grant: integration axes can narrow access, but Trust categories are indivisible switches.
    private static func axes(_ capability: String, mode: InlineInteraction.AccessMode?) -> String {
        if capability.hasPrefix("applescript:") { return "macOS Automation consent for this app" }
        if InlineInteractionRegistry.isMacControlCategory(capability) {
            guard let mode else { return "one switch in Trust, covering reading and changing" }
            return "needed for \(mode == .write ? "changing" : "reading")"
                + "; the one Trust switch covers reading and changing"
        }
        let read = MacIntegrationID.supportsRead(capability) && (mode?.wantsRead ?? true)
        let write = MacIntegrationID.supportsWrite(capability) && (mode?.wantsWrite ?? true)
        switch (read, write) {
        case (true, true): return "read and write"
        case (true, false): return "read only"
        case (false, true): return "write only"
        case (false, false): return "no access on this build"
        }
    }

    /// Derive the destination from the control to avoid per-service copy here.
    private static func details(
        _ interaction: InlineInteraction,
        _ descriptor: InlineInteractionDescriptor
    ) -> (label: String, body: String)? {
        let name = descriptor.displayName
        // Local choices stay on this card; only their explicit Providers row opens that page.
        if interaction.kind == .modelChoice, !interaction.options.isEmpty {
            var body = "The model you pick makes this one picture and nothing is saved."
            if interaction.options.contains(where: { $0.id == InlineInteractionRegistry.persistentChoiceOptionID }) {
                body += " The last row is the other choice: it opens Providers, "
                    + "the only place the \(name) group's saved model changes."
            }
            return ("What happens", body)
        }
        switch descriptor.control {
        case .internetAccounts:
            return ("What happens", mailRoute)
        case .chromeSetup:
            return ("What happens",
                    "Chrome control is switched on in Trust. " + chromeSteps)
        case .pairDevice:
            return ("What happens",
                    "The pairing page opens. Open NativeAgent on your iPhone, then choose Pair "
                    + "here when the codes match.")
        case .connectorManualToken:
            return ("What happens",
                    "What you paste is checked with \(name) and saved by Connectors, the same "
                    + "as its setup page does. The chat never sees it.")
        case .macPermissionGrant where interaction.allTargets.contains(where: { $0.hasPrefix("applescript:") }):
            return ("What happens",
                    "macOS asks for Automation consent for each requested app; the card reports whether you allowed it.")
        case .macPermissionGrant where interaction.allTargets.contains(where: { SystemPermissionPreflight.cardSettingsCapability($0) != nil }):
            return ("What happens",
                    "macOS controls this permission. You can turn it off in System Settings.")
        case .macPermissionGrant:
            return ("What happens",
                    "The permission is turned on here and listed in Trust, "
                    + "where you can turn it off again at any time.")
        case .trustPostureRequired:
            return ("What happens",
                    "Trust opens. Your posture is yours to set — nothing here changes it, "
                    + "and \(name) stays off until you do.")
        case .providerGroupModel:
            return ("What happens",
                    "Providers opens on the \(name) group so you can pick the model there.")
        case .providerAPIKey:
            return ("What happens",
                    "Enter the key or sign in in the protected entry on the Mac. "
                    + "Nothing counts as done until the saved \(name) connection is verified in Providers.")
        case .capabilityFlag:
            return ("What happens",
                    "\(name) is switched on in Trust, the same switch as the one on that page.")
        case .keyring where interaction.secret?.remove == true:
            return ("What happens", "\(name) is deleted from this Mac's Keychain. Abilities that use it stop until you grant it again.")
        case .keyring:
            return ("What happens",
                    (interaction.secret?.signIn == nil ? "What you paste is kept in this Mac's Keychain. "
                        : "Your browser opens to sign in; what the service returns is kept in this Mac's Keychain. ")
                    + "It goes only to \(interaction.secret?.line ?? "where this card says"), and the agent uses it by name without ever seeing it.")
        case .inlineChoice, .unavailable, .unknown:
            return nil
        }
    }

    /// The Mail card's route in the order its tap runs it: reading on, then Check Mail, then Internet Accounts only when Mail has no account.
    public static let mailRoute = "Mail reading turns on and Mail is checked; if macOS asks to let NativeAgent control Mail, choose Allow. "
        + "Internet Accounts opens only if Mail has no account yet."

    /// Remote controls settle only when their owner confirms completion.
    public static let chromeSteps = "I'll load my extension in Chrome and check the connection. Allow Mac access if asked."

    private static func busyNote(_ interaction: InlineInteraction, _ control: InlineInteractionDescriptor.Control) -> String? {
        switch control {
        case .keyring: return Keyring.signInNote(String(interaction.target.dropFirst("secret:".count)))
        case .internetAccounts: return mailRoute
        case .chromeSetup: return chromeSteps
        case .pairDevice: return "Open NativeAgent on your iPhone, then choose Pair when the codes match."
        case .macPermissionGrant:
            return waitingLine(interaction) ?? "If System Settings opened, turn NativeAgent on there."
        case .capabilityFlag:
            return "If System Settings opened, turn NativeAgent on there."
        default: return nil
        }
    }

    /// The working line names exactly what the running card waits on and where the person turns it on.
    private static func waitingLine(_ interaction: InlineInteraction) -> String? {
        let pending = SystemPermissionPreflight.launchPending(interaction.allTargets).map(\.displayName)
        switch interaction.waitingOn {
        case nil:
            return nil
        case .some(.restart):
            return pending.isEmpty ? "Waiting on one restart."
                : "Waiting on one restart: \(InlineInteractionRegistry.englishList(pending)) \(pending.count == 1 ? "takes" : "take") effect when "
                    + "NativeAgent reopens."
        case .some(.target(let id)):
            guard let gate = SystemPermissionPreflight.cardSettingsCapability(id) else { return nil }
            let path = SystemPermissionPreflight.settingsPath(gate)
            let step = gate == .fullDiskAccess ? "add NativeAgent from Finder in \(path), then turn it on" : "turn on NativeAgent in \(path)"
            let line = "Waiting on \(InlineInteractionRegistry.macCapabilityDisplayName(id)): \(step)."
            guard SystemPermissionPreflight.appliesAtLaunch.contains(gate), !pending.isEmpty else { return line }
            return line + " One restart covers \(InlineInteractionRegistry.englishList(pending))."
        }
    }

    /// A running permission card offers its restart once its walk reaches what a restart covers; a failed or capability card offers it while a
    /// launch-applied grant on it has not taken effect in this process.
    private static func restartNote(_ interaction: InlineInteraction) -> String? {
        guard [.permission, .capability].contains(interaction.kind) else { return nil }
        let pending = SystemPermissionPreflight.launchPending(interaction.allTargets).map(\.displayName)
        guard !pending.isEmpty else { return nil }
        switch interaction.state {
        case .running where interaction.kind == .permission:
            guard SystemPermissionPreflight.waitsForRestart(interaction.waitingOn) else { return nil }
        case .running, .failed:
            break
        default:
            return nil
        }
        return "Once \(InlineInteractionRegistry.englishList(pending)) \(pending.count == 1 ? "is" : "are") on, restart NativeAgent once to finish. "
            + "Your chat stays put."
    }

    private static func busyLabel(_ kind: InlineInteraction.Kind) -> String {
        switch kind {
        case .connector: return "Connecting…"
        case .permission: return "Allowing…"
        case .modelChoice: return "Switching…"
        case .apiKey: return "Connecting…"
        case .capability: return "Turning on…"
        case .choose, .unknown: return "Working…"
        }
    }

    /// Receipts retain the owner's confirmed outcome or the card's promised decline consequence.
    private static func outcome(
        _ interaction: InlineInteraction,
        deadControl: Bool,
        repeatCount: Int = 1
    ) -> (text: String?, meta: String?) {
        // Repeat counts share one receipt line across rendered and page presentations.
        func counted(_ text: String) -> String {
            repeatCount > 1 ? text + " (×\(repeatCount))" : text
        }
        if deadControl { return (counted(interaction.title), nil) }
        switch interaction.state {
        case .stopped(let reason):
            let cause = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return (counted("Stopped: " + (cause.isEmpty ? "no reason was recorded." : cause)), nil)
        case .settled(let settled):
            let summary = settled.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return (counted("Done: " + (summary.isEmpty ? "no change summary was recorded." : summary)),
                    settled.scope == .thisRequestOnly ? "This request only" : nil)
        case .declined:
            // A declined receipt keeps the promised consequence, never the ask's title.
            let consequence = InlineInteraction.lowercasedLead(
                interaction.declineConsequence.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            return (counted(consequence.isEmpty ? "Not now" : "Not now \u{2014} " + consequence), nil)
        case .superseded:
            return (counted("Superseded: a newer request replaced this card."), nil)
        case .failed(let reason):
            // The failure reason is the outcome, never the ask's title.
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return (counted("Failed: " + (trimmed.isEmpty ? "no cause was recorded." : trimmed)), nil)
        case .unknown(let savedState):
            return (counted("Unknown: this build cannot interpret the saved state “\(savedState)”."),
                    interaction.kind == .unknown ? interaction.why : nil)
        case .pending, .running:
            return (nil, nil)
        }
    }

}
