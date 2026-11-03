import NativeAgentShared
import AppKit
import ApplicationServices
import AgentConversations
import MacControl
import NativeAgentCore
import PersistenceCore
import Experiences
import Privacy
// Blueprint: | `GrokDesktopReply.swift` | MacControl owns bounded native window/subtree reads and reply-text traversal; incomplete reads propagate to send and reply receipts; submission-owned shared desktop observation transfers once to its reply reader; a last non-answering reply must match across two idle AX reads at least 300ms apart, with one quiet-boundary read independent of notifications; the three-minute reply deadline ends every observation without claiming completion; reader settlement through `settle` saves the answer or partial with its actual read method/wake, owes failed storage with that terminal evidence under the operation ID, and releases observation and foreground once |

/// Grok's answer to a desktop send, read back from the same chat it was pasted
/// into, after the send has returned (the exchange waits; this settles it).
///
/// One reader: its accessibility tree provides exact text and completion.
/// An unavailable tree retains the partial answer and names its blocker.
/// Grok is never brought forward for this.
///
/// The transcript's AXDocumentArticle rows contain message groups; the AXHeading names the chat.
@MainActor public enum GrokDesktopReply {
    typealias AX = GrokRoutineAccessibility
    struct Turn: Sendable { let user: Bool; let text: String }
    /// Taken at send time with Grok in front.
    struct Layout { let baseline: Int; var watchID: String? }

    // MARK: - Accessibility (Grok in front)

    private struct Scan { let turns: [Turn]; let answering: Bool }
    private struct Read: Sendable { let turns: [Turn]; let answering: Bool }

    private static func passiveRead(chat: String) async throws -> Read? {
        if let pid = NSRunningApplication.runningApplications(withBundleIdentifier: GrokBotRoute.bundleID).first?.processIdentifier {
            try? await SystemMacAXElementSource.prepareRenderer(pid: pid)
        }
        return try await MacAccessibilityReader.read {
            try scan(chat: chat).map { Read(turns: $0.turns, answering: $0.answering) }
        }
    }

    /// The open chat's turns, oldest first; nil when `chat` is not the open
    /// chat or its transcript can't be read. Never descends into the sidebar.
    nonisolated private static func scan(chat: String) throws -> Scan? {
        try MacAccessibilityReader.withReadBudget {
            // An unreadable event is evidence, not a setup action or a repeated log.
            guard SystemMacAXElementSource().isTrusted(), let app = NSRunningApplication.runningApplications(withBundleIdentifier: GrokBotRoute.bundleID).first else { return nil }
            let windows = try SystemMacAXElementSource().nativeWindows(pid: app.processIdentifier)
            guard windows.count == 1, let window = windows.first else { return nil }
            var log: AXUIElement?, current = false, answering = false
            let tree = try MacAccessibilityReader.elements(in: window, searching: "Grok Bot's current chat and transcript") {
                !["AXApplicationLog", "AXLandmarkComplementary"].contains(MacAXAttributeRead.text($0, kAXSubroleAttribute))
            }
            for node in tree {
                let role = try MacAXAttributeRead.checkedText(node, kAXRoleAttribute), subrole = try MacAXAttributeRead.checkedText(node, kAXSubroleAttribute)
                if role == "AXHeading", try MacAXAttributeRead.checkedText(node, kAXDescriptionAttribute) == chat || MacAXAttributeRead.checkedText(node, kAXTitleAttribute) == chat { current = true }
                if role == kAXButtonRole, try [kAXTitleAttribute, kAXDescriptionAttribute].contains(where: { try MacAXAttributeRead.checkedText(node, $0).hasPrefix("Stop") }) { answering = true }
                if subrole == "AXApplicationLog" { log = node }
            }
            guard current, let log else { return nil }
            let turns = try MacAccessibilityReader.childElements(in: log, searching: "Grok Bot's transcript rows")
                .flatMap { [$0] + (try MacAccessibilityReader.childElements(in: $0, searching: "Grok Bot's transcript articles")) }
                .filter { try MacAXAttributeRead.checkedText($0, kAXSubroleAttribute) == "AXDocumentArticle" }
                .map { article in
                    guard let body = try MacAccessibilityReader.elements(in: article, searching: "Grok Bot's message body").first(where: { try MacAXAttributeRead.checkedText($0, kAXSubroleAttribute) == "AXApplicationGroup" }) else {
                        return Turn(user: false, text: "") // an approval or tool card: activity, no words
                    }
                    let label = try MacAXAttributeRead.checkedText(body, kAXDescriptionAttribute)
                    guard label == "Your message" || label.hasSuffix(" message") else { return Turn(user: false, text: "") }
                    return Turn(user: label == "Your message", text: try MacAccessibilityReader.nativeText(in: body))
                }
            return Scan(turns: turns, answering: answering)
        }
    }

    static func submission(_ message: String, chat: String) throws -> (baseline: Int, layout: Layout?)? {
        guard let scan = try scan(chat: chat) else { return nil }
        func normalized(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let baseline = scan.turns.filter { $0.user && normalized($0.text) == normalized(message) }.count
        return (baseline, Layout(baseline: scan.turns.filter { $0.user && same($0.text, message) }.count, watchID: nil))
    }


    /// The answer by accessibility: Grok's turns after the user turn that is
    /// exactly this message and the first one past the baseline.
    private static func axReply(_ scan: Read, message: String, baseline: Int) -> (text: String, active: Bool, last: Bool)? {
        let mine = scan.turns.indices.filter { scan.turns[$0].user && same(scan.turns[$0].text, message) }
        guard mine.count > baseline else { return nil }
        // Only up to the next user turn: a later message is not ours to answer.
        let after = scan.turns[(mine[baseline] + 1)...].prefix { !$0.user }
        return (after.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n"), !after.isEmpty,
                scan.turns[(mine[baseline] + 1)...].allSatisfy { !$0.user })
    }


    // MARK: - The watch

    enum Outcome: Sendable { case answered(String, at: Date, by: String), unanswered(partial: String, blocker: String?) }
    private static let replyTimeout: TimeInterval = 180

    /// The reply deadline ends observation without treating a pause as an answer.
    @MainActor final class Observation {
        var outcome: Outcome = .unanswered(partial: "", blocker: nil)
        var firstActivity: Date?
        var timedOut = false
        var previous: NSRunningApplication?
        var driver: MacDriverBinding?
        let deadline = Date().addingTimeInterval(replyTimeout)
        var readReceipt: JSONValue?

        func releaseForeground() async {
            let held = previous
            previous = nil
            let binding = driver
            driver = nil
            await MacDriverContext.$binding.withValue(binding) { await AX.restoreForeground(held) }
        }
    }

    private struct PendingWatch {
        let observation: Observation
        let events: DesktopRouteObservation
        let message: String
        let layout: Layout
    }
    private static var pendingWatches: [String: PendingWatch] = [:]

    /// Subscribe at submission, while Grok still exposes its answering control.
    /// Keep that foreground until completion, retirement or the existing reporting deadline;
    /// cleanup never changes focus after the person has switched applications.
    static func start(message: String, chat: String, layout: Layout, previous: NSRunningApplication?) throws -> String {
        let events = try DesktopRouteObservation(bundleID: GrokBotRoute.bundleID)
        let observation = Observation()
        observation.previous = previous
        observation.driver = MacDriverContext.binding?.settlementBinding()
        let id = UUID().uuidString
        pendingWatches[id] = PendingWatch(observation: observation, events: events, message: message, layout: layout)
        return id
    }

    static func abandon(_ id: String?) async {
        guard let id, let pending = pendingWatches.removeValue(forKey: id) else { return }
        await settle { @MainActor in
            pending.events.stop()
            await pending.observation.releaseForeground()
        }
    }

    /// Read after registration and on shared desktop wakes, within the reply
    /// deadline. An idle AX answer arms
    /// one 300ms quiet read, so a second notification is never required to
    /// verify the same text with the answering control absent on both reads.
    static func watch(message: String, chat: String, layout: Layout, live: AgentConversationLiveTarget?,
                      observation: Observation, events: DesktopRouteObservation) async -> Outcome {
        let hub = AgentConversationLiveHub.shared
        var text = ""
        var idleText: String?
        var idleSince: Date?
        do {
            while true {
                guard !Task.isCancelled else { return observation.outcome }
                var reply: (text: String, active: Bool)?
                var readBy: String?
                var blocker: String?
                var completed = false
                let previousIdle = idleText
                let previousIdleSince = idleSince
                idleText = nil
                idleSince = nil
                do {
                    // A failed read is no evidence this tick (never completion); the deadline still ends the watch.
                    if let scan = try await passiveRead(chat: chat), let found = axReply(scan, message: message, baseline: layout.baseline) {
                        reply = (found.text, found.active)
                        readBy = "accessibility"
                        if !found.last {
                            observation.readReceipt = events.receipt(readBy: "accessibility")
                            observation.outcome = .unanswered(partial: found.text, blocker: "A later message followed this send before its reply completion was confirmed. Its visible text remains a partial reply; nothing was resent.")
                            return observation.outcome
                        }
                        if !scan.answering {
                            let since = previousIdle == found.text ? (previousIdleSince ?? Date()) : Date()
                            idleText = found.text; idleSince = since
                            completed = !found.text.isEmpty && previousIdle == found.text && Date().timeIntervalSince(since) >= 0.3
                        }
                        if !scan.answering && !completed && !found.text.isEmpty {
                            blocker = "Grok's reply is visible, but it is not yet stable across two consecutive idle scans. The visible text is a partial reply, not a confirmed finished answer."
                        }
                    } else {
                        blocker = "Grok's exact chat and submitted turn were not available through Accessibility. Open chat \u{201C}\(chat)\u{201D} in a single Grok window."
                    }
                } catch {
                    blocker = "Grok's Accessibility read failed: \(error.localizedDescription)."
                }
                let changed = reply.map { $0.text != text } ?? false
                let activity = reply?.active == true && observation.firstActivity == nil
                if activity { observation.firstActivity = Date() }
                if let reply {
                    text = reply.text
                    if let readBy { observation.readReceipt = events.receipt(readBy: readBy) }
                }
                observation.outcome = completed ? .answered(text, at: Date(), by: "accessibility") : .unanswered(partial: text, blocker: blocker)
                if !observation.timedOut {
                    if let live, activity { await hub.activity(live) }
                    guard !Task.isCancelled else { return observation.outcome }
                    if let live, changed, !text.isEmpty { await hub.text(live, replace: text) }
                }
                if completed { return observation.outcome }
                if Date() >= observation.deadline {
                    observation.outcome = .unanswered(partial: text, blocker: "Grok's reply was not confirmed within the three-minute observation deadline. Reply observation has ended. Any answer stays in that chat; nothing was resent.")
                    return observation.outcome
                }
                var boundary = observation.deadline
                if let idleSince, let idleText, !idleText.isEmpty {
                    let quiet = idleSince.addingTimeInterval(0.3)
                    boundary = min(boundary, quiet)
                }
                try await events.next(until: boundary)
            }
        } catch {
            observation.outcome = .unanswered(partial: text, blocker: "Grok's desktop reply observation stopped: \(error.localizedDescription) Any answer stays in that chat; nothing was resent.")
        }
        return observation.outcome
    }


    /// A verified desktop send to Grok returns at once as waiting; a tracked
    /// watch then settles that exact exchange with the answer and its timing.
    public static func follow(_ sent: JSONValue, dataRoot: URL) async -> JSONValue {
        guard case .object(var fields) = sent, case .object(let plan)? = fields.removeValue(forKey: "_grok_watch"),
              case .string(let chat)? = plan["chat"], case .string(let peerID)? = plan["peer"],
              case .string(let watchID)? = plan["watch_id"] else { return sent }
        let store = AgentPeerStore(dataRoot: dataRoot)
        let peers = (try? store.list()) ?? []
        let name = peers.first { $0.id == peerID }?.name ?? "Grok"
        // Two contacts can share this app (09-26: "Grok" here, "Grok Bot" by routine): name both.
        let other = peers.first { $0.transport == .grokBot }.map { " The \u{201C}\($0.name)\u{201D} contact is a separate route (its routine) into the same app." } ?? ""
        let place = "chat \u{201C}\(chat)\u{201D} in the Grok Bot app, as contact \u{201C}\(name)\u{201D}"
        fields["app"] = .string("Grok Bot"); fields["chat"] = .string(chat)
        fields.removeValue(forKey: "reply_with")
        guard let live = AgentConversationLiveContext.target, let row = live.recordID, let operation = live.operationID else {
            await abandon(watchID)
            fields["detail"] = .string("Pasted into \(place). Its answer is not watched on this path; it stays in that chat." + other)
            return .object(fields)
        }
        guard let pending = pendingWatches.removeValue(forKey: watchID) else {
            fields["status"] = .string("failed"); fields["terminal"] = .bool(true)
            fields["detail"] = .string("Grok's reply observation was not retained. The message was sent; any answer stays in that chat.")
            return .object(fields)
        }
        fields["reply_deadline"] = .string(NativeTimestampFormat.plainZulu(pending.observation.deadline))
        let base = fields
        fields["status"] = .string("running")
        fields["reply_observation"] = .string("running")
        fields["detail"] = .string("Pasted into \(place). Its reply is watched in that same chat without bringing Grok forward. A confirmed finished answer lands on this exchange by itself. Do not resend." + other)
        let ownership = UUID()
        let events = pending.events
        let follower = Task { @MainActor in
            let observation = pending.observation
            // The same reply deadline releases foreground ownership even if
            // the final read is still finishing. Settlement releases the watch.
            let deadline = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(max(0, observation.deadline.timeIntervalSinceNow))) } catch { return }
                observation.timedOut = true
                await settle { @MainActor in await observation.releaseForeground() }
            }
            let outcome = await withTaskCancellationHandler {
                await watch(message: pending.message, chat: chat, layout: pending.layout, live: live,
                            observation: observation, events: events)
            } onCancel: {
                deadline.cancel()
                Task { @MainActor in events.stop() }
            }
            deadline.cancel()
            var terminal = base
            var answer: String?, stop: String?
            switch outcome {
            case .answered(let reply, let at, let by):
                answer = reply
                terminal["status"] = .string("answered")
                terminal["reply"] = .string(reply); terminal["replied_at"] = .string(NativeTimestampFormat.fractionalZulu(at))
                terminal["read_by"] = .string(by); terminal["untrusted_remote_data"] = .bool(true)
                terminal["detail"] = .string("Pasted into \(place), and read \(name)'s answer back from that same chat after its last message stayed unchanged across two idle Accessibility reads at least 300 ms apart, with no answering control present." + other)
            case .unanswered(let partial, let blocker):
                terminal["status"] = .string("no_reply")
                if Task.isCancelled { stop = "Local reply observation stopped. The message was sent to \(place); any answer stays in that chat." }
                terminal["detail"] = .string((stop ?? "Pasted into \(place), but no finished answer was confirmed. "
                    + (blocker ?? "No reply completion signal has been observed.") + " Nothing was resent; any answer stays in that chat.") + other)
                if let blocker { terminal["blocker"] = .string(blocker) }
                if !partial.isEmpty { terminal["partial_reply"] = .string(partial); terminal["untrusted_remote_data"] = .bool(true) }
            }
            terminal["terminal"] = .bool(true); terminal["completed"] = .bool(answer != nil)
            terminal["reply_observation_receipt"] = observation.readReceipt ?? events.receipt(readBy: "unavailable")
            terminal["reply_observation"] = .string(answer != nil ? "done" : stop != nil ? "stopped" : Date() >= observation.deadline ? "timed_out" : "failed")
            let receipt = JSONValue.object(terminal), produced = answer, stopDetail = stop
            await settle { @MainActor in
                await deadline.value
                await observation.releaseForeground()
                do {
                    try AgentConversationStore(dataRoot: dataRoot).settleExchange(id: row, exchange: operation,
                        reply: produced, receipt: receipt, firstActivity: observation.firstActivity, stopDetail: stopDetail)
                    if produced != nil {
                        store.recordProof(peerID: peerID, outbound: true)
                        store.recordRoundTrip(peerID: peerID, workspace: "Grok Bot chat \u{201C}\(chat)\u{201D}")
                    }
                    await AgentConversationLiveHub.shared.settle(live, state: "finished")
                } catch {
                    let failure = "Grok's reply result could not be saved: \(error.localizedDescription) Nothing was resent; any answer stays in that chat."
                    let source = AgentConversationStore(dataRoot: dataRoot).fileURL.path
                    await RepairOwed.owe(dataRoot, id: operation + ":reply-settlement", kind: .message,
                        cause: [operation], evidence: [.init(source: source, id: row)],
                        operation: "agent.reply.settlement:" + operation, owner: source,
                        words: "Conversation \(row), operation \(operation), reply in \(place). " + failure
                            + " Original reply outcome and observation evidence: "
                            + NativeAgentSecretRedactor.redactText(String(describing: receipt)),
                        lever: "Repair conversation storage, then save this exact reply outcome and its evidence; never resend the message.").value
                    nativeLog("%@", failure)
                    await AgentConversationLiveHub.shared.settle(live, state: "failed", note: failure)
                }
                events.stop()
                AgentConversationWatches.finish(ownership)
            }
        }
        AgentConversationWatches.retain(ownership, row: row, operation: operation, task: follower)
        return .object(fields)
    }

    // MARK: - Text

    /// Composer and transcript differ in whitespace, never in meaningful
    /// punctuation, symbols or emoji. Submission and reply use this same key.
    nonisolated static func transcriptKey(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The whole turn is exactly this message.
    static func same(_ turn: String, _ message: String) -> Bool {
        let key = transcriptKey(message)
        return !key.isEmpty && transcriptKey(turn) == key
    }


}
