import NativeAgentShared
import AppKit
import ApplicationServices
import AgentConversations
import MacControl
import NativeAgentCore
import PersistenceCore
import ScreenCaptureKit
import Vision
// Blueprint: | `GrokDesktopReply.swift` | MacControl owns bounded native window/subtree reads and reply-text traversal; incomplete reads propagate to send and reply receipts; submission-owned shared desktop observation transfers once to its reply reader; a last non-answering reply must match across two idle AX reads at least 300ms apart, with one quiet-boundary read independent of notifications; the three-minute reporting deadline releases foreground ownership without claiming completion; no-notification interval observation ends at that deadline while supported events retain late-answer reach; reader settlement through `settle` saves the answer or partial with its actual read method/wake and releases observation and foreground once |

/// Grok's answer to a desktop send, read back from the same chat it was pasted
/// into, after the send has returned (the exchange waits; this settles it).
///
/// Two reads, never an action: first its accessibility tree for exact text;
/// when unavailable, a capture of Grok's window alone, cropped to the
/// transcript, read with Vision. Pixels retain partial text, not completion.
/// Grok is never brought forward for this.
///
/// The transcript's AXDocumentArticle rows contain message groups; the AXHeading names the chat.
@MainActor public enum GrokDesktopReply {
    typealias AX = GrokRoutineAccessibility
    struct Turn: Sendable { let user: Bool; let text: String }
    /// Taken at send time with Grok in front.
    struct Layout { let baseline: Int; let transcript: CGRect; let window: CGSize; let windowID: CGWindowID; var watchID: String? }

    // MARK: - Accessibility (Grok in front)

    private struct Scan { let window: AXUIElement; let log: AXUIElement; let composer: AXUIElement?; let turns: [Turn]; let answering: Bool }
    private struct Read: Sendable { let turns: [Turn]; let answering: Bool }

    private static func passiveRead(chat: String) async throws -> Read? {
        try await MacAccessibilityReader.read {
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
            var log: AXUIElement?, composer: AXUIElement?, current = false, answering = false
            let tree = try MacAccessibilityReader.elements(in: window, searching: "Grok Bot's current chat and transcript") {
                !["AXApplicationLog", "AXLandmarkComplementary"].contains(MacAXAttributeRead.text($0, kAXSubroleAttribute))
            }
            for node in tree {
                let role = try MacAXAttributeRead.checkedText(node, kAXRoleAttribute), subrole = try MacAXAttributeRead.checkedText(node, kAXSubroleAttribute)
                if role == "AXHeading", try MacAXAttributeRead.checkedText(node, kAXDescriptionAttribute) == chat || MacAXAttributeRead.checkedText(node, kAXTitleAttribute) == chat { current = true }
                if role == kAXButtonRole, try [kAXTitleAttribute, kAXDescriptionAttribute].contains(where: { try MacAXAttributeRead.checkedText(node, $0).hasPrefix("Stop") }) { answering = true }
                if role == kAXTextAreaRole, try MacAXAttributeRead.checkedText(node, kAXDescriptionAttribute).lowercased() == "prompt" { composer = node }
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
            return Scan(window: window, log: log, composer: composer, turns: turns, answering: answering)
        }
    }

    static func submission(_ message: String, chat: String) throws -> (baseline: Int, layout: Layout?)? {
        guard let scan = try scan(chat: chat) else { return nil }
        func normalized(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let baseline = scan.turns.filter { $0.user && normalized($0.text) == normalized(message) }.count
        guard let window = MacAXAttributeRead.frame(scan.window), var transcript = MacAXAttributeRead.frame(scan.log),
              let pid = NSRunningApplication.runningApplications(withBundleIdentifier: GrokBotRoute.bundleID).first?.processIdentifier else { return (baseline, nil) }
        // The window the message went into, by its id: the passive read looks at that one only.
        let ids = ((CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []).compactMap { info -> CGWindowID? in
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid, info[kCGWindowLayer as String] as? Int == 0,
                  let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
                  abs(bounds.minX - window.minX) < 1, abs(bounds.minY - window.minY) < 1,
                  abs(bounds.width - window.width) < 1, abs(bounds.height - window.height) < 1 else { return nil }
            return info[kCGWindowNumber as String] as? CGWindowID
        }
        guard ids.count == 1 else { return (baseline, nil) }
        if let composer = scan.composer.flatMap(MacAXAttributeRead.frame), composer.minY > transcript.minY {
            transcript.size.height = min(transcript.height, composer.minY - transcript.minY)
        }
        transcript = transcript.intersection(window)
        guard !transcript.isNull, !transcript.isEmpty else { return (baseline, nil) }
        return (baseline, Layout(baseline: scan.turns.filter { $0.user && same($0.text, message) }.count,
                      transcript: transcript.offsetBy(dx: -window.minX, dy: -window.minY), window: window.size, windowID: ids[0]))
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

    // MARK: - Screen text (Grok behind other windows)

    private struct Line { var text: String; var rect: CGRect }
    private enum ScreenRead { case lines([Line]), noPermission, windowGone, unreadable }

    /// Grok's window alone (occluded is fine; minimized or on another Space is
    /// not), cropped to the transcript and the header above it, as text lines
    /// in transcript points; only the send's own window, and only while its
    /// header names this chat.
    private static func screenLines(_ layout: Layout, chat: String) async -> ScreenRead {
        guard CGPreflightScreenCaptureAccess() else { return .noPermission }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return .unreadable }
        guard let window = content.windows.first(where: { $0.windowID == layout.windowID }),
              window.owningApplication?.bundleIdentifier == GrokBotRoute.bundleID else { return .windowGone }
        guard abs(window.frame.width - layout.window.width) < 2, abs(window.frame.height - layout.window.height) < 2 else { return .unreadable }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = max(1, min(Double(filter.pointPixelScale), 4))
        let area = CGRect(x: layout.transcript.minX, y: 0, width: layout.transcript.width, height: layout.transcript.maxY)
            .intersection(CGRect(origin: .zero, size: window.frame.size))
        guard !area.isNull, !area.isEmpty,
              let width = Int(exactly: (Double(area.width) * scale).rounded()), width > 0,
              let height = Int(exactly: (Double(area.height) * scale).rounded()), height > 0 else { return .unreadable }
        configuration.sourceRect = area
        configuration.width = width
        configuration.height = height
        configuration.ignoreShadowsSingleWindow = true
        configuration.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else { return .unreadable }
        let size = area.size, top = layout.transcript.minY
        let lines = await Task.detached(priority: .utility) { () -> [Line]? in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil else { return nil }
            return (request.results ?? []).compactMap { observation in
                guard let text = observation.topCandidates(1).first?.string, !bare(text).isEmpty else { return nil }
                let box = observation.boundingBox
                return Line(text: text, rect: CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
                                                     width: box.width * size.width, height: box.height * size.height))
            }
        }.value
        guard let lines, lines.contains(where: { $0.rect.maxY <= top && bare($0.text).lowercased() == bare(chat).lowercased() }) else { return .unreadable }
        return .lines(lines.filter { $0.rect.minY >= top }.map { Line(text: $0.text, rect: $0.rect.offsetBy(dx: 0, dy: -top)) })
    }

    /// The answer on screen: Grok's lines below the person's bubble that reads
    /// as this message, up to the next bubble of theirs. Which bubble: the one
    /// followed by the answer already seen, else the newest; `last` when no
    /// bubble of theirs follows it on screen.
    private static func screenReply(_ lines: [Line], width: CGFloat, message: String, seen: String) -> (text: String, last: Bool)? {
        struct Segment { let user: Bool; var text: String; var bottom: CGFloat }
        var segments: [Segment] = []
        var boundary = false
        for line in lines.sorted(by: { $0.rect.minY < $1.rect.minY }) {
            // A day/time separator is not text, but it does end the bubble above it.
            if stamp(line.text) { boundary = true; continue }
            let user = line.rect.minX > width * 0.15
            defer { boundary = false }
            if !boundary, var last = segments.last, last.user == user {
                // A wrapped line joins its paragraph; a wider gap starts a new one.
                last.text += (line.rect.minY - last.bottom > line.rect.height * 0.8 ? "\n" : " ") + line.text
                last.bottom = line.rect.maxY
                segments[segments.count - 1] = last
            } else { segments.append(Segment(user: user, text: line.text, bottom: line.rect.maxY)) }
        }
        let answers = segments.indices.filter { segments[$0].user && resembles(segments[$0].text, message) }.map { index in
            (index, segments[(index + 1)...].prefix { !$0.user }.map(\.text).joined(separator: "\n\n"))
        }
        let start = String(bare(seen).prefix(24))
        let chosen = start.isEmpty ? answers.last : answers.last { bare($0.1).hasPrefix(start) } ?? answers.last
        guard let chosen else { return nil }
        return (chosen.1, !segments[(chosen.0 + 1)...].contains { $0.user })
    }

    // MARK: - The watch

    enum Outcome: Sendable { case answered(String, at: Date, by: String), unanswered(partial: String, blocker: String?) }
    private static let replyTimeout: TimeInterval = 180

    /// The reporting deadline shares evidence with the event reader; it never
    /// cancels the subscription or turns a pause in text into an answer.
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

    /// Read after registration and on shared desktop wakes. No-notification
    /// apps are read only within the reply deadline. An idle AX answer arms
    /// one 300ms quiet read, so a second notification is never required to
    /// verify the same text with the answering control absent on both reads.
    static func watch(message: String, chat: String, layout: Layout, live: AgentConversationLiveTarget?,
                      observation: Observation, events: DesktopRouteObservation) async -> Outcome {
        let hub = AgentConversationLiveHub.shared
        var text = ""
        var idleText: String?
        var idleSince: Date?
        var awaited = layout.baseline == 0
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
                        if found.last { awaited = true }
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
                if reply == nil {
                    let axBlocker = blocker.map { $0 + " " } ?? ""
                    switch await screenLines(layout, chat: chat) {
                    case .lines(let lines):
                        if let seen = screenReply(lines, width: layout.transcript.width, message: message, seen: text), seen.last {
                            if seen.text.isEmpty { awaited = true }
                            if awaited { reply = (seen.text, !seen.text.isEmpty); readBy = "screen_text" }
                        }
                        blocker = axBlocker + "Its visible text can be read on desktop wakes, but the window's pixels do not prove that the answer is finished. Open this chat in Grok to observe its completion signal."
                    case .noPermission:
                        blocker = axBlocker + "Screen Recording is off for NativeAgent, so Grok's window could not be read. Grant NativeAgent Screen Recording in System Settings (Privacy & Security), or bring Grok to the front so its text can be read."
                    case .windowGone:
                        observation.outcome = .unanswered(partial: text, blocker: windowGone)
                        return observation.outcome
                    case .unreadable:
                        blocker = axBlocker + "Grok's window text could not be read on this desktop wake. Open this chat in a single Grok window to observe its reply."
                    }
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
                if events.pollingReason != nil, Date() >= observation.deadline {
                    observation.outcome = .unanswered(partial: text, blocker: "Grok's reply was not confirmed within the three-minute observation deadline. The app supports no Accessibility change notifications; bounded interval reads have ended. Any answer stays in that chat; nothing was resent.")
                    return observation.outcome
                }
                var boundary: Date? = Date() < observation.deadline ? observation.deadline : nil
                if let idleSince, let idleText, !idleText.isEmpty {
                    let quiet = idleSince.addingTimeInterval(0.3)
                    boundary = min(boundary ?? quiet, quiet)
                }
                try await events.next(until: boundary)
            }
        } catch {
            observation.outcome = .unanswered(partial: text, blocker: "Grok's desktop reply observation stopped: \(error.localizedDescription) Any answer stays in that chat; nothing was resent.")
        }
        return observation.outcome
    }

    static let windowGone = "The Grok window this message went into was closed, minimized or moved to another Space, so its answer could not be read. Open that chat's window on this Space; any answer stays in that chat."

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
            // One reporting deadline, never a read trigger. The same event
            // subscription remains alive for an answer arriving after it.
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
            terminal["reply_observation"] = .string(answer != nil ? "done" : stop != nil ? "stopped" : "failed")
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

    /// Letters and digits only: the composer, the transcript and the screen
    /// differ in spacing, line breaks and markdown punctuation.
    nonisolated static func bare(_ text: String) -> String { String(text.filter { $0.isLetter || $0.isNumber }) }

    /// The whole turn is exactly this message.
    static func same(_ turn: String, _ message: String) -> Bool {
        let key = bare(message)
        return !key.isEmpty && bare(turn) == key
    }

    /// A run of the person's lines read off the screen ends with this message,
    /// within a few misread characters.
    static func resembles(_ bubble: String, _ message: String) -> Bool {
        // Its ending: the reply follows the end of our message, and a bubble
        // whose top scrolled away still shows it; one followed by another
        // message of theirs in the same run of lines does not end with ours.
        let seen = Array(bare(bubble).lowercased()), sent = Array(bare(message).lowercased())
        let n = min(60, seen.count, sent.count)
        guard n >= min(8, sent.count), n > 0 else { return false }
        return characterEditDistance(Array(seen.suffix(n)), Array(sent.suffix(n))) <= max(2, n / 10)
    }

    /// Day and time separators ("Today 11:09 PM", "10:56 AM", "Tue, Sep 22 5:17 PM").
    static func stamp(_ text: String) -> Bool {
        text.count <= 32 && text.range(of: #"\d{1,2}:\d{2}\s?(AM|PM|am|pm)?$"#, options: .regularExpression) != nil
    }

}
