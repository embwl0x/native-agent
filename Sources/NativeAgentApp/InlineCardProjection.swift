import ChatOrchestration
import Foundation
import MacIntegration
import NativeAgentShared

/// The join between the two halves.
///
/// The mechanism owns a durable `InlineInteraction` and the registry that says
/// WHICH existing control resolves it (`InlineInteractionDescriptor`). The view
/// half owns `InlineCardModel` and knows nothing about connectors, Trust or
/// Providers. This is the only place the two meet, and it is a pure function:
/// no store, no dispatch, no resolution.
///
/// Two rules it enforces, both of which exist so a card never lies:
///
///  * **A descriptor with no control never renders a button.** The card becomes
///    a terminal "unknown" wearing the yellow mark and saying why, rather than
///    a primary action that does nothing when tapped.
///  * **The secondary is always the decline.** `secondaryActionLabel` on a
///    scoped model choice is a second AFFIRMATIVE ("For future Work tasks
///    too"), and the view grammar has exactly one quiet command, which the
///    action handler wires to `decline`. Binding that label to a decline would
///    make the card do the opposite of what it says, so the alternative is
///    stated as a scope line and the quiet command stays "Not now".
enum InlineCardProjection {

    // MARK: - Kind and state, 1:1

    static func kind(_ kind: InlineInteraction.Kind) -> InlineCardKind {
        switch kind {
        case .connector: return .needsConnector
        case .permission: return .needsPermission
        case .modelChoice: return .needsModelChoice
        case .apiKey: return .needsAPIKey
        case .capability: return .needsCapability
        // An unknown kind is a question this build cannot answer; it renders
        // in the neutral "choose" shell and is forced terminal below.
        case .choose, .unknown: return .choose
        }
    }

    static func state(_ state: InlineInteraction.State) -> InlineCardState {
        switch state {
        case .pending: return .pending
        case .running: return .running
        case .settled: return .settled
        case .declined: return .declined
        case .failed: return .failed
        case .unknown: return .unknown
        case .superseded: return .superseded
        }
    }

    // MARK: - The projection

    static func model(
        _ interaction: InlineInteraction,
        descriptor: InlineInteractionDescriptor,
        repeatCount: Int = 1
    ) -> InlineCardModel {
        // A live need whose control does not exist on this build is terminal
        // and honest about it: the yellow question mark, the reason, no button.
        let deadControl = !descriptor.isActionable && interaction.state.isOpen
        let cardState = deadControl ? .unknown : state(interaction.state)

        return InlineCardModel(
            id: interaction.id,
            kind: kind(interaction.kind),
            target: descriptor.displayName,
            title: interaction.title,
            why: interaction.why,
            primaryLabel: primaryLabel(interaction, descriptor),
            // The quiet command is the decline, on every card. See the type
            // comment: the scoped model choice's own second label is an
            // affirmative and is surfaced in `scopeLines` instead.
            secondaryLabel: "Not now",
            // Something to connect says what skipping costs in one plain line,
            // whatever words the ask arrived with.
            consequence: [.connector, .apiKey].contains(interaction.kind)
                ? "If you skip, \(descriptor.displayName) stays off."
                : interaction.declineConsequence,
            state: cardState,
            persistenceNote: interaction.persistenceNote,
            fields: fields(descriptor),
            signInLabel: InlineInteractionRegistry.providerSignIn(for: descriptor.target)
                .flatMap { descriptor.control == .providerAPIKey ? "Sign in with \($0.displayShort)" : nil }
                // GitHub signs in by device flow in Connectors' sheet; the
                // token field stays as the alternative.
                ?? (isGitHubSignIn(descriptor) ? "Connect with GitHub" : nil),
            // Slack's mention rule, Telegram's users list and the like live on
            // the full page; the card never pretends to hold them.
            fullSetupLabel: descriptor.control == .connectorManualToken ? "Open full setup" : nil,
            choices: interaction.options.map {
                InlineCardChoice(
                    id: $0.id, title: $0.label, note: $0.detail,
                    // The primary names the outcome, so with a list on the
                    // card it names the row. The one row that is not a model -
                    // "save this for the whole group" - keeps the card's own
                    // label, because "Use Save for every Work task" is not a
                    // sentence.
                    actionLabel: $0.id == InlineInteractionRegistry.persistentChoiceOptionID
                        ? nil : "Use \($0.label)"
                )
            },
            scopeLines: scopeLines(interaction, descriptor),
            // "What happens" describes what tapping the primary WILL do, so it
            // belongs only to a card that still has one. On a receipt it would
            // promise a future that already happened, and it would put a
            // disclosure on the one line Agent's grammar reserves for the mark
            // and the outcome.
            detailsLabel: rendersAsReceipt(cardState)
                ? nil : details(interaction, descriptor)?.label,
            detailsBody: rendersAsReceipt(cardState)
                ? nil : details(interaction, descriptor)?.body,
            busyLabel: busyLabel(interaction.kind),
            busyNote: busyNote(descriptor.control),
            outcome: outcome(interaction, deadControl: deadControl, repeatCount: repeatCount, name: descriptor.displayName).text,
            outcomeMeta: outcome(interaction, deadControl: deadControl, repeatCount: repeatCount, name: descriptor.displayName).meta
                ?? (deadControl ? descriptor.unavailableReason : nil),
            // The working card owns Stop; a need is waiting on a person, and
            // there is nothing running to stop.
            canStop: false,
            canRetry: descriptor.isActionable
        )
    }

    /// Which states the view draws as the one-line receipt rather than as a
    /// card with controls. A failure is deliberately NOT one of them: it keeps
    /// its card, its explanation and its retry.
    private static func rendersAsReceipt(_ state: InlineCardState) -> Bool {
        switch state {
        case .settled, .declined, .unknown, .superseded: return true
        case .pending, .running, .failed: return false
        }
    }

    // MARK: - Parts

    /// The interaction writes the label, with one exception the descriptor
    /// forces: a model choice that arrived with no options cannot honestly say
    /// "Just this image", because the card has nothing to pick from. It sends
    /// the person to the control that does have the list.
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
        // Agent, 2026-09-13: the primary says the OUTCOME, never the mechanics
        // of getting there. "Paste a token" is how one of the two connector
        // setups happens to work; what the person is buying is Notion,
        // connected. This is a RENDERING rule, so it governs the cards already
        // sitting in scrollback with the old wording on them, not just the
        // ones raised from here on. Derived from the descriptor, so it stays
        // free of per-service copy.
        switch interaction.kind {
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

    /// The values a card collects itself: a provider's key (or Claude's setup
    /// token), and a manual-token connector's own setup fields. Each is
    /// written through its owner's own save and then VERIFIED with that owner,
    /// so a field is a real control, not a decoration.
    private static func fields(_ descriptor: InlineInteractionDescriptor) -> [InlineCardField] {
        switch descriptor.control {
        case .connectorManualToken:
            return InlineConnectorSetup.fields(for: descriptor.target)
        case .providerAPIKey:
            let signIn = InlineInteractionRegistry.providerSignIn(for: descriptor.target)
            // Signing in is the only way into this one: no field at all.
            if signIn != nil, signIn?.pasteLabel == nil { return [] }
            return [InlineCardField(
                label: signIn?.pasteLabel ?? "\(descriptor.displayName) API key",
                placeholder: "Paste the key",
                helper: "Your key stays on this Mac. It never goes into the chat.",
                isSecret: true
            )]
        default:
            return []
        }
    }

    /// The consequential detail, on the face of the card: exactly what a grant
    /// covers, and how far a resolution reaches.
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
                // The posture is the person's, and a card never moves it. Say
                // that on the face of the card rather than letting a button
                // imply otherwise.
                lines.append(
                    "Your Trust posture doesn't allow this at all — it can only be changed in Trust."
                )
            }
        }

        // How far the resolution reaches — said only where it is TRUE. A
        // this-request-only scope is a promise the card can keep just when it
        // has the models to pick from; with no options the choice is made in
        // Providers, which saves it, and claiming otherwise would be a lie the
        // person discovers afterwards.
        if interaction.kind == .modelChoice {
            if interaction.options.isEmpty {
                lines.append("Saved for every \(descriptor.displayName) task.")
            } else if interaction.primaryScope == .thisRequestOnly {
                // The permanent alternative is the last row of the list, so the
                // scope line says which rows this promise covers rather than
                // claiming it of the whole card.
                lines.append("Picking a model applies to this request only — nothing is saved.")
            } else {
                lines.append("Saved for every \(descriptor.displayName) task.")
            }
        }
        return lines
    }

    /// What a Mac grant actually turns on.
    ///
    /// The need carries the axis the blocked call wanted, and where the owner
    /// has two axes to write, that is exactly what is granted and exactly what
    /// this line says. Trust's Mac Control categories are ONE switch each — no
    /// read/write split exists to narrow — so those say what the switch really
    /// covers rather than a narrower promise the store could not keep.
    private static func axes(_ capability: String, mode: InlineInteraction.AccessMode?) -> String {
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

    /// What tapping the primary will actually open. The control decides this,
    /// which is how the card stays free of per-service copy.
    private static func details(
        _ interaction: InlineInteraction,
        _ descriptor: InlineInteractionDescriptor
    ) -> (label: String, body: String)? {
        let name = descriptor.displayName
        // A choice the card itself holds is made HERE. Saying Providers opens
        // would describe the one row that does open it as if it were the card.
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
            return ("What happens", "Internet Accounts opens so you can add and enable a Mail account.")
        case .chromeSetup:
            return ("What happens",
                    "Chrome control is switched on in Trust, the extension folder shows in Finder "
                    + "and Chrome opens its extensions page. There, " + chromeSteps)
        case .pairDevice:
            return ("What happens",
                    "The pairing page opens. Open NativeAgent on your iPhone, then choose Pair "
                    + "here when the codes match.")
        case .connectorManualToken where isGitHubSignIn(descriptor):
            return ("What happens",
                    "GitHub opens in your browser with a code to approve; nothing is connected "
                    + "until GitHub says so. A pasted token works too. The chat never sees either.")
        case .connectorManualToken:
            return ("What happens",
                    "What you paste is checked with \(name) and saved by Connectors, the same "
                    + "as its setup page does. The chat never sees it.")
        case .connectorOAuth:
            return ("What happens",
                    "Your browser opens to sign in to \(name). "
                    + "Nothing is connected until \(name) says so.")
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
            if InlineInteractionRegistry.providerSignIn(for: descriptor.target) != nil {
                return ("What happens",
                        "Signing in opens your browser, the same sign-in as onboarding. "
                        + "Nothing counts as done until \(name) is ready in Providers.")
            }
            return ("What happens",
                    "The key is checked with \(name), then saved in Providers. "
                    + "A key \(name) rejects is not saved and does not count as done.")
        case .capabilityFlag:
            return ("What happens",
                    "\(name) is switched on in Trust, the same switch as the one on that page.")
        case .inlineChoice, .unavailable, .unknown:
            return nil
        }
    }

    private static func isGitHubSignIn(_ descriptor: InlineInteractionDescriptor) -> Bool {
        descriptor.control == .connectorManualToken
            && InlineInteractionRegistry.canonicalConnectorID(descriptor.target) == "github"
    }

    /// The one thing to click, for a card that waits on the person
    /// somewhere else and settles by itself when the owner says done.
    static let chromeSteps = "turn on Developer mode, click Load unpacked and choose the "
        + "\u{201C}\(ChromeExtensionFolder.visible.lastPathComponent)\u{201D} folder in your home folder."

    private static func busyNote(_ control: InlineInteractionDescriptor.Control) -> String? {
        switch control {
        case .internetAccounts: return "Add and turn on a Mail account in Internet Accounts."
        case .chromeSetup: return "In Chrome\u{2019}s extensions page, " + chromeSteps
        case .pairDevice: return "Open NativeAgent on your iPhone, then choose Pair when the codes match."
        case .macPermissionGrant, .capabilityFlag:
            return "If System Settings opened, turn NativeAgent on there."
        default: return nil
        }
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

    /// The one-line receipt and its metadata. A settled card says what the
    /// OWNER confirmed; a declined one keeps the promise the card made about
    /// declining; a failure carries its reason into the card that stays.
    private static func outcome(
        _ interaction: InlineInteraction,
        deadControl: Bool,
        repeatCount: Int = 1,
        name: String = ""
    ) -> (text: String?, meta: String?) {
        // The same ask, answered the same way, several times in a row is ONE
        // thing that happened — not five. The count rides on the receipt line
        // itself so the glass and the quiet page read say it identically
        // (Agent, 2026-09-14: ten Connect Notion cards in one conversation).
        func counted(_ text: String) -> String {
            repeatCount > 1 ? text + " (×\(repeatCount))" : text
        }
        if deadControl { return (counted(interaction.title), nil) }
        switch interaction.state {
        case .settled(let settled):
            return (counted(settled.summary.isEmpty ? interaction.title : settled.summary),
                    settled.scope == .thisRequestOnly ? "This request only" : nil)
        case .declined where [.connector, .apiKey].contains(interaction.kind) && !name.isEmpty:
            // Something to connect, skipped: the account's name, one word.
            return (counted("\(name) skipped"), nil)
        case .declined:
            // ONE gray line: the mark, "Not now", and what that cost. NEVER
            // the title - "Connect Notion" beside a cross reads as a thing
            // that happened (Agent, 2026-09-13). The consequence is the card's
            // own promise, kept where the person can still see it.
            let consequence = InlineInteraction.lowercasedLead(
                interaction.declineConsequence.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            return (counted(consequence.isEmpty ? "Not now" : "Not now \u{2014} " + consequence), nil)
        case .superseded:
            // The view draws one quiet line of its own; nothing to say here.
            return (nil, nil)
        case .failed(let reason):
            // THE FAILURE IS THE OUTCOME. `interaction.title` is the ask's own
            // headline — "Connect Notion" — so a failed card projected
            // "Outcome: Connect Notion", the primary button's words standing in
            // for what happened, with the actual reason demoted to metadata
            // (Agent, 2026-09-14).
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return (counted(trimmed.isEmpty ? "It didn't go through." : trimmed), nil)
        case .unknown:
            return (counted(interaction.title), "Outcome unknown.")
        case .pending, .running:
            return (nil, nil)
        }
    }
}
