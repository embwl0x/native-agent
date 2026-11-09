import Foundation
import PersistenceCore
import PersonaEngine
import TrustCenter
import ChatSessionWork
import NativeAgentCore
import NativeAgentShared
// Blueprint: | `FirstRunWelcomeTransaction.swift` | Claimed public welcome; checked receipt settlement |
// Keep welcome receipts local and in off-disk backup; exclude them from local backup, public export and phone sync.

/// Only chat-owner acceptance proves greeting delivery; deferred and rejected handoffs must not present success.
public enum FirstRunGreetingOutcome: Equatable, Sendable {
    case notArmed
    /// An existing persona needs no greeting, deferral or failure notice.
    case existingPersona
    case priorOutcomeUnknown
    case noActiveSession
    case providerUnavailable
    case claimFailed
    case delivered(sessionId: String)
    case rejected(message: String)

    public var routeFailureMessage: String? {
        switch self {
        case .notArmed, .existingPersona, .delivered:
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
            return "NativeAgent could not finish the first greeting: \(message)"
        }
    }
}

// MARK: - First-run welcome greeting
// Only public-release onboarding may mark a fresh persona for welcome; upgrades and development installs never greet.
// Persist only the agent's reply. The opener uses the supplied user name, writes one requested-role line through persona writers,
// and leaves later preferences to conversation. Both marker and first-conversation evidence gate delivery.

/// Project transcript evidence through a protocol to avoid an EngineRuntime dependency.
public protocol FirstRunWelcomeMessage {
    var id: String { get }
    var role: String { get }
    var content: String { get }
    var firstRunMechanicalKind: String? { get }
    var firstRunTurnCompleted: Bool { get }
}

/// Keep reads and pre/post-await checks on MainActor so greeting claims retain transactional ordering.
@MainActor
public protocol FirstRunWelcomePort: AnyObject {
    associatedtype FirstRunMessage: FirstRunWelcomeMessage
    var firstRunDataRoot: URL { get }
    var firstRunIsPublicRelease: Bool { get }
    var activeChatSessionId: String { get }
    var chatMessages: [FirstRunMessage] { get }
    var firstRunSessionIsBusy: Bool { get }
    var firstConversationPersonName: String { get throws }
    var firstRunSyntheticErrorIDPrefix: String { get }
    func firstRunGreetingHasReadyProvider() async -> Bool
    func sendFirstRunGreeting(_ kickoff: String, sessionID: String) async -> MacChatTurnAcceptance
    func firstRunMessages(for sessionID: String) -> [FirstRunMessage]
    func firstRunLoadMessages(for sessionID: String) async throws
}

@MainActor
public final class FirstRunWelcomeTransaction {
    private var firstRunGreetingInFlight = false

    public init() {}

    private func firstRunWelcomeMarkerURL(port: some FirstRunWelcomePort) -> URL {
        port.firstRunDataRoot
            .appendingPathComponent(".needs_welcome", isDirectory: false)
    }

    /// Rename a sibling claim file for recoverable handoff; a crash during send leaves unknown delivery and blocks duplicate greeting.
    private func firstRunWelcomeInFlightMarkerURL(port: some FirstRunWelcomePort) -> URL {
        port.firstRunDataRoot
            .appendingPathComponent(".needs_welcome.inflight", isDirectory: false)
    }

    // MARK: - The first conversation: fresh personas only

    /// Markers, write tokens, unreadable persona, role headings and conversation rows all defeat freshness.
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

    /// Only real conversational rows defeat emptiness; transient error notices must not block retrying a rejected greeting.
    public static func hasConversationRows<Message: FirstRunWelcomeMessage>(_ messages: [Message], syntheticErrorIDPrefix: String) -> Bool {
        messages.contains {
            ($0.role == "user" || $0.role == "assistant")
                && !$0.id.hasPrefix(syntheticErrorIDPrefix)
                && !isPersistedFailureRow($0)
        }
    }

    /// Classify failure rows by their mechanical writer stamp so they cannot count as the agent speaking.
    public static func isPersistedFailureRow<Message: FirstRunWelcomeMessage>(_ message: Message) -> Bool {
        message.firstRunMechanicalKind == "systemRow"
    }

    /// A completed greeting's durable receipt lets settlement resume without another send.
    private struct GreetingReceipt: Codable, Sendable {
        let sessionID: String
        let title: String
    }

    private static func receiptURL(dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent(".needs_welcome.receipt")
    }

    private static func loadGreetingReceipt(dataRoot: URL) throws -> GreetingReceipt? {
        let data: Data
        do { data = try Data(contentsOf: receiptURL(dataRoot: dataRoot)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        let receipt = try JSONDecoder().decode(GreetingReceipt.self, from: data)
        guard NativeAgentChatSessionID.normalizedPathComponent(receipt.sessionID) == receipt.sessionID,
              receipt.title.hasPrefix(FirstConversationPersonaProgression.roleSectionPrefix),
              !receipt.title.dropFirst(FirstConversationPersonaProgression.roleSectionPrefix.count)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !receipt.title.contains("\n"), !receipt.title.contains("\r") else {
            throw ToolFailureError("The greeting receipt has an invalid session or title. Repair it before settling progression.", effects: .unknown)
        }
        return receipt
    }

    /// Every required next-step record must read back before retiring the claim.
    /// Matching saved records make repair idempotent without resetting delivery.
    private static func completeFirstRunGreeting(dataRoot: URL, receipt: GreetingReceipt) throws -> FirstRunGreetingOutcome {
        try FirstConversationPersonaProgression.armWriteToken(
            dataRoot: dataRoot, sessionID: receipt.sessionID, title: receipt.title,
            token: FirstConversationPersonaProgression.writeTokenFilename,
            spent: FirstConversationPersonaProgression.spentTokenFilename)
        let directive = FirstConversationPersonaProgression.nextTurnDirective(title: receipt.title)
        if let saved = try ChatSessionDirective.load(dataRoot: dataRoot, sessionID: receipt.sessionID) {
            guard saved.directive == directive else {
                throw ToolFailureError("""
                    The greeting's next-turn directive belongs to other work. Preserve it and reconcile the receipt; nothing \
                    was overwritten.
                    """, effects: .unknown)
            }
        } else {
            let record = ChatSessionDirectiveRecord(
                createdAt: ISO8601DateFormatter().string(from: Date()), directive: directive)
            guard ChatSessionDirective.write(record, dataRoot: dataRoot, sessionID: receipt.sessionID),
                  try ChatSessionDirective.load(dataRoot: dataRoot, sessionID: receipt.sessionID) == record else {
                throw ToolFailureError("""
                    The greeting's next-turn directive could not be saved and verified. Its receipt and in-flight claim remain \
                    for repair.
                    """, effects: .unknown)
            }
        }
        let marker = PersonaRootResolver.resolveIsolated(dataRoot: dataRoot)
            .appendingPathComponent(FirstConversationPersonaProgression.metMarkerFilename)
        let payload = ["session_id": receipt.sessionID, "met_at": ISO8601DateFormatter().string(from: Date())]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: marker)
        guard try Data(contentsOf: marker) == data else {
            throw ToolFailureError("The greeting's met marker did not read back. Its in-flight claim remains for repair.", effects: .unknown)
        }
        try FileManager.default.removeItem(at: dataRoot.appendingPathComponent(".needs_welcome.inflight"))
        try SwiftNativePersistenceCore.syncDirectory(dataRoot)
        return .delivered(sessionId: receipt.sessionID)
    }

    private static func settleGreeting(dataRoot: URL, receipt: GreetingReceipt) -> FirstRunGreetingOutcome {
        do { return try completeFirstRunGreeting(dataRoot: dataRoot, receipt: receipt) }
        catch {
            return .rejected(message: """
                The greeting completed, but its saved next step needs repair: \(error.localizedDescription). Recheck setup after repair; the greeting \
                will not be sent again.
                """)
        }
    }

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

    /// Only public-release bundles arm welcome; calling this elsewhere does not imply a marker was written.
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

    /// The durable marker and in-flight flag let onboarding and view triggers share one greeting.
    private static func kickoff(title: String) -> String {
        """
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

        Then your reach: what you can touch on this Mac. Before you write it, read \
        app {page:"trust"}. Its "macOS grants" rows (row grant.<name>) are your live reach, in \
        the order a card asks for them. Raise exactly ONE card in this opening, for every such \
        row that reads Not granted: request_interaction kind=permission, target privacy:<name> \
        of the first such row, also_needed privacy:<name> of the rest of them in row order. The \
        Automation rows (row grant.automation.<app>) stay off this card; ask for one of those in \
        context, the first time you need that app. If every reach row is granted, raise no card.

        Say it in one or two sentences in your own voice: what the card turns on and what that \
        lets you do, close to "Allow these and I can read your calendar and see your screen; \
        Screen Recording takes one restart, and the card does it." Then offer one real first \
        thing you can do with what is on now (today's calendar, a reminder, a look at their \
        mail): one, concrete, offered, not asked.

        Full Mac, in one short clause: it is their own switch in Trust, for when they want you \
        on more of the Mac. Never say you can turn it on, or that the card does.

        The phone: read app {page:"connectors"}, its iPhone rows. If a phone is waiting to pair, say so in one \
        line: Match the code on Today opens it, and they choose Pair when the codes match. Otherwise \
        offer, in one sentence, to pair their iPhone. No phone card in this opening.

        After this opening, SETUP IS BY TALKING. When they ask to set something up, or it is \
        plainly useful for what they asked ("want me to connect your calendar?"), raise that \
        one thing's request_interaction card, one card at a time.

        The opening line takes no name and no list. Use their name later in the turn \
        ONLY if you genuinely know it; \
        never guess, invent, or use a placeholder like "User".

        \(FirstConversationPersonaProgression.roleAnswerInstruction(title: title))

        On their voice answer, a note supplies the exact VOICE.md title and app call.
        \(FirstConversationPersonaProgression.voiceAnswerInstruction)
        \(FirstConversationPersonaProgression.handBackInstruction)

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
    }

    @MainActor
    @discardableResult
    public func maybeSendFirstRunGreeting(port: some FirstRunWelcomePort) async -> FirstRunGreetingOutcome {
        // Claim synchronously on MainActor before awaiting so competing triggers cannot both start.
        // Recheck bundle eligibility so a restored marker cannot greet on a development install.
        guard port.firstRunIsPublicRelease else { return .notArmed }
        return await sendFirstRunGreetingIfEligible(port: port)
    }

    @MainActor
    private func sendFirstRunGreetingIfEligible(port: some FirstRunWelcomePort) async -> FirstRunGreetingOutcome {
        guard !firstRunGreetingInFlight else { return .notArmed }
        if firstRunWelcomeMarkerState(port: port) == .inFlight {
            do {
                // Missing evidence is unknown, never permission to repeat a send.
                guard let receipt = try Self.loadGreetingReceipt(dataRoot: port.firstRunDataRoot) else {
                    return .priorOutcomeUnknown
                }
                return Self.settleGreeting(dataRoot: port.firstRunDataRoot, receipt: receipt)
            } catch {
                return .rejected(message: """
                    The greeting's receipt is unavailable: \(error.localizedDescription). Preserve its in-flight claim and repair the receipt; no \
                    duplicate was sent.
                    """)
            }
        }
        guard firstRunWelcomeMarkerState(port: port) == .pending, !firstRunGreetingInFlight else { return .notArmed }
        guard !port.activeChatSessionId.isEmpty else { return .noActiveSession }
        let preparedSession = port.activeChatSessionId
        do { try await port.firstRunLoadMessages(for: preparedSession) }
        catch { return .rejected(message: "The greeting's conversation could not be read: " + error.localizedDescription) }
        guard port.activeChatSessionId == preparedSession, !firstRunGreetingInFlight else { return .noActiveSession }
        // Recheck persona freshness independently of the pending marker because their lifetimes differ; never repeat an answered introduction.
        guard firstConversationIsFreshPersona(port: port) else { return .existingPersona }
        guard !port.activeChatSessionId.isEmpty else { return .noActiveSession }
        guard firstConversationSessionIsIdleAndEmpty(port: port) else { return .noActiveSession }
        let sid = port.activeChatSessionId
        firstRunGreetingInFlight = true
        defer { firstRunGreetingInFlight = false }

        // Read providers fresh after connect; if none is ready, keep the marker for a later trigger.
        guard await port.firstRunGreetingHasReadyProvider() else { return .providerUnavailable }
        // The provider read suspends: a session switch or a human turn can
        // invalidate the empty first-conversation snapshot checked above.
        guard firstConversationIsFreshPersona(port: port) else { return .existingPersona }
        guard port.activeChatSessionId == sid, !sid.isEmpty, firstConversationSessionIsIdleAndEmpty(port: port) else {
            return .noActiveSession
        }
        let personName: String
        do { personName = try port.firstConversationPersonName }
        catch {
            return .rejected(
                message: """
                    The saved profile could not be read: \(error.localizedDescription). Repair memory/profile.json before the \
                    first greeting can be sent.
                    """)
        }
        guard !personName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .rejected(message: "The saved person's name is empty. Repair memory/profile.json.userName before sending the greeting.")
        }
        let title = FirstConversationPersonaProgression.roleSectionTitle(personName: personName)
        guard !title.contains("\n"), !title.contains("\r") else {
            return .rejected(message: "The saved person's name must fit on one line before sending the greeting.")
        }
        guard claimFirstRunWelcomeMarker(port: port) else { return .claimFailed }

        nativeLog("[first-run-welcome] firing greeting into session %@", sid)

        // The pending marker moved to the durable in-flight marker before this
        // handoff. A crash during delivery therefore leaves an honest unknown
        // state on disk and suppresses a duplicate greeting after restart.
        let acceptance = await port.sendFirstRunGreeting(Self.kickoff(title: title), sessionID: sid)
        switch acceptance {
        case .accepted(let acceptedSessionID):
            // sendChat awaits its task, so its completion notification has
            // already fired by the time an accepted handoff returns.
            if firstRunGreetingTurnSucceeded(port: port, sessionID: acceptedSessionID) {
                let dataRoot = port.firstRunDataRoot
                let receipt = GreetingReceipt(sessionID: acceptedSessionID, title: title)
                return await settle { @MainActor in
                    do {
                        try SwiftNativePersistenceCore.writeDataAtomicDurable(
                            JSONEncoder().encode(receipt), to: Self.receiptURL(dataRoot: dataRoot))
                        guard let saved = try Self.loadGreetingReceipt(dataRoot: dataRoot),
                              saved.sessionID == receipt.sessionID, saved.title == receipt.title else {
                            throw ToolFailureError("The completed greeting receipt did not read back.", effects: .unknown)
                        }
                        return Self.settleGreeting(dataRoot: dataRoot, receipt: receipt)
                    } catch {
                        return .rejected(message: """
                            The greeting completed, but its receipt could not be retained: \(error.localizedDescription). Its in-flight claim \
                            remains; inspect the transcript before repairing progression. Do not send the greeting again.
                            """)
                    }
                }
            }
            // Missing completion evidence leaves delivery unknown, never permission
            // to repeat an accepted handoff. Preserve the durable claim.
            return .priorOutcomeUnknown
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
