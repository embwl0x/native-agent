import AppKit
import ApplicationServices
import ChatOrchestration
import MacControl
import NativeAgentCore
import PersistenceCore
import ScreenCaptureKit
import Vision

/// Grok's answer to a desktop send, read back from the same chat it was pasted
/// into, after the send has returned (the exchange waits; this settles it).
///
/// Two reads, never an action: with Grok in front, its accessibility tree
/// (exact text; Grok builds it only while in front); behind other windows, a
/// capture of Grok's window alone, cropped to the transcript, read with Vision.
/// Grok is never brought forward for this.
///
/// Seen on the installed app (0.57.1, 09-26): the chat is an AXApplicationLog
/// "Conversation transcript" holding one AXDocumentArticle per turn; each
/// message's body is an AXApplicationGroup described "Your message" or
/// "<chat> message"; the open chat's name is its AXHeading. On screen, Grok's
/// lines start at the transcript's left edge, the person's bubbles sit right of
/// a third of its width, and day/time separators are centred.
@MainActor public enum GrokDesktopReply {
    typealias AX = GrokRoutineAccessibility
    struct Turn: Sendable { let user: Bool; let text: String }
    /// Taken at send time with Grok in front.
    struct Layout { let baseline: Int; let transcript: CGRect; let window: CGSize; let windowID: CGWindowID; var watchID: String? }

    // MARK: - Accessibility (Grok in front)

    private struct Scan { let window: AXUIElement; let log: AXUIElement; let composer: AXUIElement?; let turns: [Turn]; let answering: Bool }
    private struct Read: Sendable { let turns: [Turn]; let answering: Bool }

    private static func passiveRead(chat: String) async -> Read? {
        try? await DesktopPeerReadLane.read {
            scan(chat: chat).map { Read(turns: $0.turns, answering: $0.answering) }
        }
    }

    /// The open chat's turns, oldest first; nil when `chat` is not the open
    /// chat or its transcript can't be read. Never descends into the sidebar.
    nonisolated private static func scan(chat: String) -> Scan? {
        // An unreadable event is evidence, not a setup action or a repeated log.
        guard AXIsProcessTrusted(), let app = NSRunningApplication.runningApplications(withBundleIdentifier: GrokBotRoute.bundleID).first,
              let windows = AX.attribute(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement],
              windows.count == 1, let window = windows.first else { return nil }
        var queue = [window], log: AXUIElement?, composer: AXUIElement?, current = false, answering = false, visited = 0
        while !queue.isEmpty, visited < 600 {
            let node = queue.removeFirst(); visited += 1
            let role = AX.string(node, kAXRoleAttribute), subrole = AX.string(node, kAXSubroleAttribute)
            if role == "AXHeading", AX.string(node, kAXDescriptionAttribute) == chat || AX.string(node, kAXTitleAttribute) == chat { current = true }
            if role == kAXButtonRole, [kAXTitleAttribute, kAXDescriptionAttribute].contains(where: { AX.string(node, $0).hasPrefix("Stop") }) { answering = true }
            if role == kAXTextAreaRole, AX.string(node, kAXDescriptionAttribute).lowercased() == "prompt" { composer = node }
            if subrole == "AXApplicationLog" { log = node; continue }
            if subrole == "AXLandmarkComplementary" { continue }
            queue.append(contentsOf: children(node))
        }
        guard current, let log else { return nil }
        let turns = children(log).flatMap { [$0] + children($0) }
            .filter { AX.string($0, kAXSubroleAttribute) == "AXDocumentArticle" }
            .compactMap { article in
                guard let body = AX.nodes(article).first(where: { AX.string($0, kAXSubroleAttribute) == "AXApplicationGroup" }) else {
                    return Turn(user: false, text: "") // an approval or tool card: activity, no words
                }
                let label = AX.string(body, kAXDescriptionAttribute)
                guard label == "Your message" || label.hasSuffix(" message") else { return Turn(user: false, text: "") }
                return Turn(user: label == "Your message", text: render(body))
            }
        return Scan(window: window, log: log, composer: composer, turns: turns, answering: answering)
    }

    /// At send time: user turns already carrying exactly this text, and the
    /// transcript's place in the window (above the message box).
    static func outgoingOccurrences(_ message: String, chat: String) -> Int? {
        func normalized(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        return scan(chat: chat).map { $0.turns.filter { $0.user && normalized($0.text) == normalized(message) }.count }
    }

    static func layout(_ message: String, chat: String) -> Layout? {
        guard let scan = scan(chat: chat), let window = frame(scan.window), var transcript = frame(scan.log),
              let pid = NSRunningApplication.runningApplications(withBundleIdentifier: GrokBotRoute.bundleID).first?.processIdentifier else { return nil }
        // The window the message went into, by its id: the passive read looks at that one only.
        let ids = ((CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []).compactMap { info -> CGWindowID? in
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid, info[kCGWindowLayer as String] as? Int == 0,
                  let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
                  abs(bounds.minX - window.minX) < 1, abs(bounds.minY - window.minY) < 1,
                  abs(bounds.width - window.width) < 1, abs(bounds.height - window.height) < 1 else { return nil }
            return info[kCGWindowNumber as String] as? CGWindowID
        }
        guard ids.count == 1 else { return nil }
        if let composer = scan.composer.flatMap(frame), composer.minY > transcript.minY {
            transcript.size.height = min(transcript.height, composer.minY - transcript.minY)
        }
        return Layout(baseline: scan.turns.filter { $0.user && same($0.text, message) }.count,
                      transcript: transcript.offsetBy(dx: -window.minX, dy: -window.minY), window: window.size, windowID: ids[0])
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
        configuration.sourceRect = area
        configuration.width = max(1, Int((area.width * scale).rounded()))
        configuration.height = max(1, Int((area.height * scale).rounded()))
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
    }

    private struct PendingWatch {
        let observation: Observation
        let events: MacAppSourceEvents
        let task: Task<Outcome, Never>
        let previous: NSRunningApplication?
    }
    private static var pendingWatches: [String: PendingWatch] = [:]

    /// Subscribe at submission, while Grok still exposes its answering control.
    /// Keep that foreground until completion or the existing reporting deadline;
    /// cleanup never changes focus after the person has switched applications.
    static func start(message: String, chat: String, layout: Layout, previous: NSRunningApplication?) throws -> String {
        let events = try MacAppSourceEvents(bundleID: GrokBotRoute.bundleID)
        let observation = Observation()
        let live = AgentConversationLiveContext.target
        let task = Task { @MainActor in
            if let live { await AgentConversationLiveHub.shared.begin(live, lane: "desktop") }
            return await watch(message: message, chat: chat, layout: layout, live: live,
                               observation: observation, events: events)
        }
        let id = UUID().uuidString
        pendingWatches[id] = PendingWatch(observation: observation, events: events, task: task, previous: previous)
        return id
    }

    static func abandon(_ id: String?) async {
        guard let id, let pending = pendingWatches.removeValue(forKey: id) else { return }
        pending.task.cancel()
        pending.events.cancel()
        await AX.restoreForeground(pending.previous)
    }

    /// Only Grok's accessibility notifications trigger reads. Screen text can
    /// report partial activity while Grok is behind other windows, but only an
    /// last reply stable across two idle scans proves a finished answer.
    static func watch(message: String, chat: String, layout: Layout, live: AgentConversationLiveTarget?,
                      observation: Observation, events: MacAppSourceEvents) async -> Outcome {
        defer { events.cancel() }
        let hub = AgentConversationLiveHub.shared
        var text = ""
        var idleText: String?
        var awaited = layout.baseline == 0
        do {
            for try await _ in events.stream {
                guard !Task.isCancelled else { return observation.outcome }
                var reply: (text: String, active: Bool)?
                var blocker: String?
                var completed = false
                let previousIdle = idleText
                idleText = nil
                if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == GrokBotRoute.bundleID {
                    if let scan = await passiveRead(chat: chat), let found = axReply(scan, message: message, baseline: layout.baseline) {
                        if found.last { awaited = true }
                        reply = (found.text, found.active)
                        if !found.last {
                            observation.outcome = .unanswered(partial: found.text, blocker: "A later message followed this send before its reply completion was confirmed. Its visible text remains a partial reply; nothing was resent.")
                            return observation.outcome
                        }
                        completed = !scan.answering && !found.text.isEmpty && previousIdle == found.text
                        if !scan.answering { idleText = found.text }
                        if !scan.answering && !completed && !found.text.isEmpty {
                            blocker = "Grok's reply is visible, but it is not yet stable across two consecutive idle scans. The visible text is a partial reply, not a confirmed finished answer."
                        }
                    } else {
                        blocker = "Grok is in front, but its accessibility tree could not be read (Accessibility is off for NativeAgent, Grok has more than one window, or chat \u{201C}\(chat)\u{201D} is not the open chat), so its answer could not be read. Open that chat in a single Grok window; any answer stays in that chat."
                    }
                } else {
                    switch await screenLines(layout, chat: chat) {
                    case .lines(let lines):
                        if let seen = screenReply(lines, width: layout.transcript.width, message: message, seen: text), seen.last {
                            if seen.text.isEmpty { awaited = true }
                            if awaited { reply = (seen.text, !seen.text.isEmpty) }
                        }
                        blocker = "Grok is behind other windows. Its visible text can be read on accessibility events, but the window's pixels do not prove that the answer is finished. Open this chat in Grok to observe its completion signal."
                    case .noPermission:
                        blocker = "Screen Recording is off for NativeAgent, so Grok's window could not be read while it was behind other windows. Grant NativeAgent Screen Recording in System Settings (Privacy & Security), or bring Grok to the front so its text can be read."
                    case .windowGone:
                        observation.outcome = .unanswered(partial: text, blocker: windowGone)
                        return observation.outcome
                    case .unreadable:
                        blocker = "Grok's window text could not be read on this accessibility event. Open this chat in a single Grok window to observe its reply."
                    }
                }
                guard !Task.isCancelled else { return observation.outcome }
                let changed = reply.map { $0.text != text } ?? false
                let activity = reply?.active == true && observation.firstActivity == nil
                if activity { observation.firstActivity = Date() }
                if let reply { text = reply.text }
                observation.outcome = completed ? .answered(text, at: Date(), by: "accessibility") : .unanswered(partial: text, blocker: blocker)
                if !observation.timedOut {
                    if let live, activity { await hub.activity(live) }
                    if let live, changed, !text.isEmpty { await hub.text(live, replace: text) }
                }
                if completed { return observation.outcome }
            }
            observation.outcome = .unanswered(partial: text, blocker: "Grok's accessibility reply observation ended before a finished answer was confirmed. Any answer stays in that chat; nothing was resent.")
        } catch {
            observation.outcome = .unanswered(partial: text, blocker: "Grok's accessibility reply observation stopped: \(error.localizedDescription) Any answer stays in that chat; nothing was resent.")
        }
        return observation.outcome
    }

    static let windowGone = "The Grok window this message went into was closed, minimized or moved to another Space, so its answer could not be read. Open that chat's window on this Space; any answer stays in that chat."

    /// A desktop chat's answer, read after its send returned, lands on that
    /// send's exchange: still the thread's current one, it is the result;
    /// one the thread has moved past keeps it as its own reply. Either way it
    /// reaches her as a reply (AgentConversationStore.noteReplies).
    public static func land(_ receipt: [String: JSONValue], answer: String?, row: String, operation: String,
                            firstActivity: Date? = nil, dataRoot: URL) throws {
        try AgentConversationStore(dataRoot: dataRoot).settleExchange(id: row, exchange: operation,
            reply: answer, receipt: .object(receipt), firstActivity: firstActivity)
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
        fields["reply_deadline"] = .string(ISO8601DateFormatter().string(from: Date().addingTimeInterval(replyTimeout)))
        let base = fields
        fields["status"] = .string("running")
        fields["detail"] = .string("Pasted into \(place). Accessibility events watch its reply without bringing Grok forward. A confirmed finished answer lands on this exchange by itself; after three minutes, an unconfirmed reply is reported honestly and observation continues. Do not resend." + other)
        AgentConversationWatches.begin(row: row, operation: operation)
        func settle(_ outcome: Outcome, firstActivity: Date?, late: Bool) async -> JSONValue {
            var settled = base
            var answer: String?
            switch outcome {
            case .answered(let reply, let at, let by):
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                answer = reply
                settled["status"] = .string("answered"); settled["completed"] = .bool(true)
                settled["reply"] = .string(reply); settled["replied_at"] = .string(iso.string(from: at))
                settled["read_by"] = .string(by); settled["untrusted_remote_data"] = .bool(true)
                settled["detail"] = .string("Pasted into \(place), and read \(name)'s answer back from that same chat after its last message stayed unchanged across two consecutive idle scans." + other)
            case .unanswered(let partial, let blocker):
                settled["status"] = .string("no_reply")
                settled["detail"] = .string("Pasted into \(place), but no finished answer was confirmed. "
                    + (blocker ?? "No reply completion signal has been observed.") + " Nothing was resent; "
                    + "any answer stays in that chat" + (late ? "; accessibility observation continues, and a confirmed answer lands on this exchange whenever it comes." : ".") + other)
                if let blocker { settled["blocker"] = .string(blocker) }
                if !partial.isEmpty { settled["partial_reply"] = .string(String(partial.prefix(2000))); settled["untrusted_remote_data"] = .bool(true) }
            }
            if late, case .object(let expired) = AgentConversationView.expiringReply(.object(settled)) { settled = expired }
            do {
                try land(settled, answer: answer, row: row, operation: operation, firstActivity: firstActivity, dataRoot: dataRoot)
                if answer != nil {
                    store.recordProof(peerID: peerID, outbound: true)
                    store.recordRoundTrip(peerID: peerID, workspace: "Grok Bot chat \u{201C}\(chat)\u{201D}")
                }
                await AgentConversationLiveHub.shared.settle(live, state: "finished")
            } catch {
                let failure = "Grok's reply result could not be saved: \(error.localizedDescription) Nothing was resent; any answer stays in that chat."
                nativeLog("%@", failure)
                settled["status"] = .string("failed"); settled["completed"] = .bool(false)
                settled["error"] = .string(failure); settled["detail"] = .string(failure)
                await AgentConversationLiveHub.shared.settle(live, state: "failed", note: failure)
            }
            return .object(settled)
        }
        let pending: PendingWatch
        do {
            guard let saved = pendingWatches.removeValue(forKey: watchID) else { throw CancellationError() }
            pending = saved
        }
        catch {
            let blocker = "Grok's accessibility reply observation could not start: \(error.localizedDescription) Open this chat in Grok and restore Accessibility permission if needed; nothing was resent."
            let receipt = await settle(.unanswered(partial: "", blocker: blocker), firstActivity: nil, late: false)
            AgentConversationWatches.end(row: row, operation: operation)
            return receipt
        }
        Task { @MainActor in
            let observation = pending.observation
            // One reporting deadline, never a read trigger. The same event
            // subscription remains alive for an answer arriving after it.
            let deadline = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(replyTimeout)) } catch { return }
                if case .answered = observation.outcome { return }
                observation.timedOut = true
                await AX.restoreForeground(pending.previous)
                _ = await settle(observation.outcome, firstActivity: observation.firstActivity, late: true)
                AgentConversationWatches.end(row: row, operation: operation)
            }
            let outcome = await pending.task.value
            deadline.cancel()
            if !observation.timedOut { await AX.restoreForeground(pending.previous) }
            _ = await settle(outcome, firstActivity: observation.firstActivity, late: false)
            if !observation.timedOut {
                AgentConversationWatches.end(row: row, operation: operation)
            }
        }
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
        return distance(Array(seen.suffix(n)), Array(sent.suffix(n))) <= max(2, n / 10)
    }

    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        var row = Array(0...b.count)
        for i in 1...max(1, a.count) where !a.isEmpty {
            var previous = row[0]; row[0] = i
            for j in stride(from: 1, through: b.count, by: 1) {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return a.isEmpty ? b.count : row[b.count]
    }

    /// Day and time separators ("Today 11:09 PM", "10:56 AM", "Tue, Sep 22 5:17 PM").
    static func stamp(_ text: String) -> Bool {
        text.count <= 32 && text.range(of: #"\d{1,2}:\d{2}\s?(AM|PM|am|pm)?$"#, options: .regularExpression) != nil
    }

    nonisolated static func children(_ node: AXUIElement) -> [AXUIElement] {
        AX.attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    static func frame(_ node: AXUIElement) -> CGRect? {
        guard let position = AX.attribute(node, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = AX.attribute(node, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &extent),
              extent.width > 0, extent.height > 0 else { return nil }
        return CGRect(origin: point, size: extent)
    }

    /// Reading order: inline pieces (code spans, links, text split around them)
    /// join directly; separate blocks go on their own lines.
    nonisolated static func render(_ node: AXUIElement) -> String {
        if AX.string(node, kAXRoleAttribute) == kAXStaticTextRole { return AX.string(node, kAXValueAttribute) }
        var result = "", previousInline = false
        for child in children(node) {
            let text = render(child)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let inline = AX.string(child, kAXSubroleAttribute) == "AXCodeStyleGroup" || AX.string(child, kAXRoleAttribute) == "AXLink"
            if result.isEmpty || inline || previousInline || result.last?.isWhitespace == true
                || text.first.map({ $0.isWhitespace || $0.isPunctuation }) == true {
                result += text
            } else { result += "\n" + text }
            previousInline = inline
        }
        return result
    }
}
