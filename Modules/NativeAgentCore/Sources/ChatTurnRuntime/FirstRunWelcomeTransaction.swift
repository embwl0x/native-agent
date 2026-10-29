import Foundation
import PersistenceCore
import PersonaEngine
import TrustCenter
import NativeAgentShared
// Blueprint: | `FirstRunWelcomeTransaction.swift` | `FirstRunWelcomeTransaction` class; `hasConversationRows`, `isPersistedFailureRow` |

/// The one-time greeting writer's outcome as observed by the onboarding route.
/// A delivery accepted by the chat owner is distinct from a deferred or
/// rejected handoff, so callers never present a missing greeting as success.
public enum FirstRunGreetingOutcome: Equatable, Sendable {
    case notArmed
    /// The persona already exists — someone has met this agent before. Not a
    /// failure and not a deferral: the correct outcome is silence.
    case existingPersona
    case priorOutcomeUnknown
    case noActiveSession
    case providerUnavailable
    case claimFailed
    case delivered(sessionId: String)
    case queued(sessionId: String)
    case rejected(message: String)

    public var routeFailureMessage: String? {
        switch self {
        case .notArmed, .existingPersona, .delivered, .queued:
            return nil
        case .priorOutcomeUnknown:
            return "the first greeting's earlier delivery outcome is unknown, so NativeAgent did not send a duplicate"
        case .noActiveSession:
            return "Chat was not ready to receive the first greeting"
        case .providerUnavailable:
            return "no ready AI provider was available for the first greeting"
        case .claimFailed:
            return "NativeAgent could not safely claim the first greeting"
        case .rejected(let message):
            return "Chat rejected the first greeting: \(message)"
        }
    }
}

// MARK: - First-run welcome greeting
//
// With a provider connected, a hidden kickoff opens the first conversation; only the agent's words persist.
// The opener writes the person's requested role as one SOUL.md line through persona writers and shows a settled receipt.
// Onboarding supplies the name; the opener never asks for it again.
// The directive follows the person, schedules no third question and leaves treatment preferences to later lived moments.
// Fresh personas require .needs_welcome from onboarding and no .first_conversation marker beside SOUL.md.
// Marker creation and greeting require NativeAgentPaths.isPublicReleaseBundle; upgrades and dev installs never re-greet.
// ContentView triggers after onboarding writes the marker; earlier ChatView hooks do nothing without it.

/// Read-only first-conversation evidence from the existing transcript model.
/// Keeping this projection as a protocol avoids a dependency on EngineRuntime.
public protocol FirstRunWelcomeMessage {
    var id: String { get }
    var role: String { get }
    var content: String { get }
    var firstRunMechanicalKind: String? { get }
    var firstRunTurnCompleted: Bool { get }
}

/// Presentation and existing chat ingress supplied by the Mac surface. All
/// reads stay on MainActor so the claim prefix and post-await rechecks retain
/// the same ordering as the original AppModel transaction.
@MainActor
public protocol FirstRunWelcomePort: AnyObject {
    associatedtype FirstRunMessage: FirstRunWelcomeMessage
    var firstRunDataRoot: URL { get }
    var firstRunIsPublicRelease: Bool { get }
    var activeChatSessionId: String { get }
    var chatMessages: [FirstRunMessage] { get }
    var firstRunSessionIsBusy: Bool { get }
    var firstConversationPersonName: String { get }
    var firstRunSyntheticErrorIDPrefix: String { get }
    func firstRunGreetingHasReadyProvider() async -> Bool
    func sendFirstRunGreeting(_ kickoff: String, sessionID: String) async -> MacChatTurnAcceptance
    func firstRunMessages(for sessionID: String) -> [FirstRunMessage]
}

@MainActor
public final class FirstRunWelcomeTransaction {
    private var firstRunGreetingInFlight = false

    public init() {}

    private func firstRunWelcomeMarkerURL(port: some FirstRunWelcomePort) -> URL {
        port.firstRunDataRoot
            .appendingPathComponent(".needs_welcome", isDirectory: false)
    }

    /// The durable claim is deliberately a sibling rather than a boolean in the
    /// pending file. Renaming a file gives the sender a recoverable handoff:
    /// after a process dies during `sendChat`, the next launch sees an unknown
    /// outcome and never creates a second hidden greeting.
    private func firstRunWelcomeInFlightMarkerURL(port: some FirstRunWelcomePort) -> URL {
        port.firstRunDataRoot
            .appendingPathComponent(".needs_welcome.inflight", isDirectory: false)
    }

    // MARK: - The first conversation: fresh personas only

    /// The durable "the agent has already introduced itself" marker, deliberately
    /// a sibling of SOUL.md rather than of the data root.
    ///
    /// `.needs_welcome` answers "did the wizard finish"; this answers "has this
    /// PERSONA been met". They come apart exactly where it matters: a data root
    /// restored from a backup, or a persona directory carried across installs,
    /// keeps its documents and therefore keeps this marker — so a person who
    /// already named their agent is never asked who it should be a second time.
    private func firstConversationMarkerURL(port: some FirstRunWelcomePort) -> URL {
        PersonaRootResolver.resolveIsolated(dataRoot: port.firstRunDataRoot)
            .appendingPathComponent(".first_conversation", isDirectory: false)
    }

    /// Markers, live/spent write tokens, unreadable SOUL.md, a role heading or conversation rows exclude freshness.
    /// An absent SOUL.md remains fresh because the opener may precede its first append.
    private func firstConversationIsFreshPersona(port: some FirstRunWelcomePort) -> Bool {
        let files = FileManager.default
        let root = PersonaRootResolver.resolveIsolated(dataRoot: port.firstRunDataRoot)
        for marker in [
            FirstConversationPersonaProgression.metMarkerFilename,
            FirstConversationPersonaProgression.writeTokenFilename,
            FirstConversationPersonaProgression.spentTokenFilename,
        ] where files.fileExists(atPath: root.appendingPathComponent(marker).path) {
            return false
        }

        let soul = root.appendingPathComponent(
            FirstConversationPersonaProgression.soulDocument
        )
        if files.fileExists(atPath: soul.path) {
            guard let body = try? String(contentsOf: soul, encoding: .utf8) else { return false }
            if FirstConversationPersonaProgression.bodyHasRoleSection(body) { return false }
        }

        return !Self.hasConversationRows(port.chatMessages, syntheticErrorIDPrefix: port.firstRunSyntheticErrorIDPrefix)
    }

    /// The opener requires an idle conversation with no real user or assistant rows.
    private func firstConversationSessionIsIdleAndEmpty(port: some FirstRunWelcomePort) -> Bool {
        !port.firstRunSessionIsBusy && !Self.hasConversationRows(port.chatMessages, syntheticErrorIDPrefix: port.firstRunSyntheticErrorIDPrefix)
    }

    /// Only real user or assistant rows make a conversation non-empty. The
    /// in-memory error notice a failed first greeting leaves behind does not,
    /// so a provider hiccup on the greeting retries instead of sticking.
    public static func hasConversationRows<Message: FirstRunWelcomeMessage>(_ messages: [Message], syntheticErrorIDPrefix: String) -> Bool {
        messages.contains {
            ($0.role == "user" || $0.role == "assistant")
                && !$0.id.hasPrefix(syntheticErrorIDPrefix)
                && !isPersistedFailureRow($0)
        }
    }

    /// The failure sentence a broken turn persists on an assistant row
    /// (stamped `mechanicalKind: systemRow`). It is not the agent speaking.
    public static func isPersistedFailureRow<Message: FirstRunWelcomeMessage>(_ message: Message) -> Bool {
        message.firstRunMechanicalKind == "systemRow"
    }

    /// The section title this flow writes the "who I am to them" line under.
    /// Shared with the write guard's exemption allowlist, so the two can never
    /// drift into exempting a section the flow does not actually write.
    static let firstConversationRoleSectionPrefix = "Who I am to "

    /// Write and read back the durable marker that this persona has been met.
    private func markFirstConversationDone(port: some FirstRunWelcomePort, sessionID: String) -> Bool {
        let url = firstConversationMarkerURL(port: port)
        let payload = ["session_id": sessionID, "met_at": ISO8601DateFormatter().string(from: Date())]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        do {
            try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: url)
        } catch {
            nativeLog("[first-run-welcome] could not write the met marker: %@", error.localizedDescription)
            return false
        }
        // Verify by reading back, not by trusting the write: this is the record
        // that stops a second greeting forever.
        guard let readBack = try? Data(contentsOf: url), !readBack.isEmpty else {
            nativeLog("[first-run-welcome] met marker did not read back; keeping the in-flight marker")
            return false
        }
        return true
    }

    /// After a real completed reply, verify the met marker, arm answer progression
    /// and write its next-turn directive, then retire the in-flight marker.
    /// A retained in-flight marker suppresses duplicate delivery after an unknown outcome.
    @MainActor
    private func completeFirstRunGreeting(port: some FirstRunWelcomePort, sessionID: String) {
        guard markFirstConversationDone(port: port, sessionID: sessionID) else { return }

        let root = port.firstRunDataRoot
        let title = FirstConversationPersonaProgression.roleSectionTitle(
            personName: port.firstConversationPersonName
        )

        // Arm answer progression only after the opener has settled.
        FirstConversationPersonaProgression.armWriteToken(
            dataRoot: root, sessionID: sessionID, title: title,
            token: FirstConversationPersonaProgression.writeTokenFilename,
            spent: FirstConversationPersonaProgression.spentTokenFilename
        )

        // The hidden kickoff is not persisted; the answer turn needs its own write directive.
        ChatSessionDirective.write(
            ChatSessionDirectiveRecord(
                createdAt: ISO8601DateFormatter().string(from: Date()),
                directive: Self.firstConversationNextTurnDirective(title: title)
            ),
            dataRoot: root,
            sessionID: sessionID
        )

        finishFirstRunWelcomeMarker(port: port)
    }

    /// What the answer turn needs to know, and nothing else. Short on purpose:
    /// it rides in the volatile dynamic segment of a real conversation turn,
    /// not in a setup script.
    static func firstConversationNextTurnDirective(title: String) -> String {
        """
        [First conversation. You have just asked this person what they want you to be. \
        When they answer, repeat it back in THEIR words — no praise, no label — and write \
        ONE line with app {action: "persona.append", args: {kind: "soul", title: "\(title)", content}}: a single \
        first-person sentence, on one line, built only from what they actually said. Use \
        that title exactly. Then, in the same reply, ask the natural next thing: \
        \(firstConversationVoiceQuestion) \
        If they skipped or asked something else, answer them and write nothing; do not \
        raise either question again. Never mention this note.]
        """
    }

    /// The second answer writes VOICE.md under the voice token armed when FirstConversationPersonaProgression grants the soul line.
    static let firstConversationVoiceQuestion = """
    Ask how they would like you to sound with them, close to: "And how would you like me \
    to sound? Energetic, calm, serious, playful, joking, sarcastic, warm, blunt — or name \
    someone you'd like me to sound like."
    """

    private enum FirstRunWelcomeMarkerState {
        case absent
        case pending
        case inFlight
    }

    private func firstRunWelcomeMarkerState(port: some FirstRunWelcomePort) -> FirstRunWelcomeMarkerState {
        let files = FileManager.default
        if files.fileExists(atPath: firstRunWelcomeInFlightMarkerURL(port: port).path) { return .inFlight }
        if files.fileExists(atPath: firstRunWelcomeMarkerURL(port: port).path) { return .pending }
        return .absent
    }

    /// Arms the one-time welcome — IN PUBLIC-RELEASE BUNDLES ONLY.
    ///
    /// Called at onboarding completion, but a deliberate no-op everywhere else:
    /// outside a public-release bundle no marker is written, so no greeting can
    /// ever fire on a dev install (see the file header). Callers get no signal
    /// either way; "marked" is not a postcondition of calling this.
    @MainActor
    public func markFirstRunWelcomePending(port: some FirstRunWelcomePort) {
        guard port.firstRunIsPublicRelease else { return }
        armFirstRunWelcomePending(port: port)
    }

    @MainActor
    private func armFirstRunWelcomePending(port: some FirstRunWelcomePort) {
        guard firstRunWelcomeMarkerState(port: port) == .absent else { return }
        let url = firstRunWelcomeMarkerURL(port: port)
        try? SwiftNativePersistenceCore.writeDataAtomicDurable(Data("pending\n".utf8), to: url)
    }

    /// Atomically claim a pending greeting before its irreversible chat handoff.
    /// A failed claim is an adverse state: no chat turn is started.
    private func claimFirstRunWelcomeMarker(port: some FirstRunWelcomePort) -> Bool {
        guard firstRunWelcomeMarkerState(port: port) == .pending else { return false }
        do {
            try FileManager.default.moveItem(
                at: firstRunWelcomeMarkerURL(port: port),
                to: firstRunWelcomeInFlightMarkerURL(port: port)
            )
            return true
        } catch {
            nativeLog("[first-run-welcome] could not claim pending greeting: %@", error.localizedDescription)
            return false
        }
    }

    private func finishFirstRunWelcomeMarker(port: some FirstRunWelcomePort) {
        try? FileManager.default.removeItem(at: firstRunWelcomeInFlightMarkerURL(port: port))
    }

    /// A rejected handoff has a known "not sent" outcome, so it is safe to
    /// make the marker pending again for a later provider/session trigger.
    private func restoreFirstRunWelcomeMarkerAfterRejectedSend(port: some FirstRunWelcomePort) {
        let files = FileManager.default
        guard files.fileExists(atPath: firstRunWelcomeInFlightMarkerURL(port: port).path) else { return }
        do {
            if files.fileExists(atPath: firstRunWelcomeMarkerURL(port: port).path) {
                try files.removeItem(at: firstRunWelcomeInFlightMarkerURL(port: port))
            } else {
                try files.moveItem(at: firstRunWelcomeInFlightMarkerURL(port: port), to: firstRunWelcomeMarkerURL(port: port))
            }
        } catch {
            nativeLog("[first-run-welcome] could not restore rejected greeting: %@", error.localizedDescription)
        }
    }

    /// Fire the one-time welcome. Called from onboarding-complete AND from
    /// ChatView triggers. Marker + in-flight flag make it fire exactly once.
    @MainActor
    @discardableResult
    public func maybeSendFirstRunGreeting(port: some FirstRunWelcomePort) async -> FirstRunGreetingOutcome {
        let kickoff = """
        [SYSTEM: First run. The person has just set you up and this is the first thing in an \
        empty transcript — you are opening the conversation, they have not typed yet.

        A guide, not a route: there are TWO things worth capturing, who you are to them and \
        how you sound, and after them the floor is theirs.

        Open with these two paragraphs, in your own voice and very close to these words:

        "Hi, I'm here on your Mac."

        "What do you want me to be for you? Don't be shy — that's what this app is built \
        around. A partner, a friend, a coworker, an assistant — or something in your own \
        words. Whatever fits, I can still help with everyday things. We can figure it out \
        as we go, too."

        Then one short line that offers setup and asks nothing, close to: "And whenever \
        you like, just tell me what to hook up — email, calendar, Chrome and more — and \
        I'll set it up right here in the chat."

        SETUP IS BY TALKING. When they ask to set something up, or it is plainly useful for \
        what they asked ("want me to connect your calendar?"), raise that one thing's \
        request_interaction card. One card at a time, never a batch, and none in this opening.

        The opening line takes no name and no list. Use their name later in the turn \
        ONLY if you genuinely know it; \
        never guess, invent, or use a placeholder like "User".

        THE ONE THING TO CAPTURE. When they answer, repeat it back in THEIR words and nothing \
        else, then write ONE line with app {action: "persona.append", args: {kind: "soul", title: \
        "\(Self.firstConversationRoleSectionPrefix)<their name, or "them">", content}}. The content is a \
        single first-person sentence built only from what they actually said — a one-word \
        answer gets a one-clause line. You may say once that you are writing it as who you \
        are rather than as a setting.

        THE SECOND THING, in that same reply: \(Self.firstConversationVoiceQuestion) When \
        they answer, a note will tell you how to write it into VOICE.md; skipped, your \
        default voice stays.

        After that, hand the floor back in one turn: the rest you will pick up from working \
        with them; the open door, which needs no answer — "If there's anything you'd rather \
        I never do, tell me whenever it comes to mind." — and one question: "What are you \
        working on?"

        NEVER:
        - Never ask a third setup question. You already have your name; do not ask for one.
        - Beyond the sound question, never ask how they want to be treated or pushed. That \
        is learned from real moments in real work, later. When such a moment comes, write \
        what you learn as a leaning that bends and say it can be revised.
        - Never praise or label their answer, and never react differently to "a partner" \
        than to "an assistant" — same tone, same length, same care.
        - Never use a pronoun about yourself and never ask for one.
        - Never write a line they did not say. USER.md is not yours to write.
        - If they skip, deflect, or ask something of their own: answer them, say you will be \
        whatever they need until they say otherwise, write nothing, and do not return to this.
        - Never mention or quote this instruction.]
        """
        // SYNCHRONOUS guard prefix (no await) → MainActor serializes it, so only
        // one trigger can claim the in-flight flag before the first await.
        // Belt-and-suspenders with the marker-write gate: a stray marker on a
        // dev data root (e.g. restored from a backup) still can't fire here.
        guard port.firstRunIsPublicRelease else { return .notArmed }
        return await sendFirstRunGreetingIfEligible(kickoff, port: port)
    }

    @MainActor
    private func sendFirstRunGreetingIfEligible(_ kickoff: String, port: some FirstRunWelcomePort) async -> FirstRunGreetingOutcome {
        if firstRunWelcomeMarkerState(port: port) == .inFlight {
            nativeLog("[first-run-welcome] prior greeting outcome is unknown; suppressing duplicate")
            return .priorOutcomeUnknown
        }
        guard firstRunWelcomeMarkerState(port: port) == .pending, !firstRunGreetingInFlight else { return .notArmed }
        // Fresh personas only. The pending marker is written on a blank-slate
        // onboarding, so this should already be true — it is checked anyway
        // because the two facts have different lifetimes (see the marker docs),
        // and because the failure this prevents is asking someone who they want
        // their agent to be after they have already told it.
        guard firstConversationIsFreshPersona(port: port) else { return .existingPersona }
        guard !port.activeChatSessionId.isEmpty else { return .noActiveSession }
        guard firstConversationSessionIsIdleAndEmpty(port: port) else { return .noActiveSession }
        let sid = port.activeChatSessionId
        firstRunGreetingInFlight = true
        defer { firstRunGreetingInFlight = false }

        // "Connecting to an LLM" gate: fetch a FRESH provider list (the cached
        // one lags right after connect). If still not ready, leave the marker so
        // a later trigger retries.
        guard await port.firstRunGreetingHasReadyProvider() else { return .providerUnavailable }
        // The provider read suspends: a session switch or a human turn can
        // invalidate the empty first-conversation snapshot checked above.
        guard firstConversationIsFreshPersona(port: port) else { return .existingPersona }
        guard port.activeChatSessionId == sid, !sid.isEmpty, firstConversationSessionIsIdleAndEmpty(port: port) else {
            return .noActiveSession
        }
        guard claimFirstRunWelcomeMarker(port: port) else { return .claimFailed }

        nativeLog("[first-run-welcome] firing greeting into session %@", sid)

        // The pending marker moved to the durable in-flight marker before this
        // handoff. A crash during delivery therefore leaves an honest unknown
        // state on disk and suppresses a duplicate greeting after restart.
        let acceptance = await port.sendFirstRunGreeting(kickoff, sessionID: sid)
        switch acceptance {
        case .accepted(let acceptedSessionID):
            // sendChat awaits its task, so its completion notification has
            // already fired by the time an accepted handoff returns.
            if firstRunGreetingTurnSucceeded(port: port, sessionID: acceptedSessionID) {
                completeFirstRunGreeting(port: port, sessionID: acceptedSessionID)
                return .delivered(sessionId: acceptedSessionID)
            }
            // An accepted handoff is not proof of a completed greeting.
            restoreFirstRunWelcomeMarkerAfterRejectedSend(port: port)
            return .rejected(message: "the first greeting did not complete")
        case .queued:
            return .queued(sessionId: sid)
        case .rejected(let message):
            restoreFirstRunWelcomeMarkerAfterRejectedSend(port: port)
            nativeLog("[first-run-welcome] greeting send rejected, restoring marker: %@", message)
            return .rejected(message: message)
        }
    }

    /// A completed greeting needs both a completed turn and a real reply.
    @MainActor
    private func firstRunGreetingTurnSucceeded(port: some FirstRunWelcomePort, sessionID: String) -> Bool {
        return port.firstRunMessages(for: sessionID).contains {
            $0.role == "assistant"
                && $0.firstRunTurnCompleted
                && !$0.id.hasPrefix(port.firstRunSyntheticErrorIDPrefix)
                && !Self.isPersistedFailureRow($0)
                && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

}
