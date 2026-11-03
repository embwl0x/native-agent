import AgentWorkspace
import Desk
import Foundation
import Experiences
import NativeAgentShared
import MacControl
import NativeAgentCore
import PersistenceCore
import ProviderRouting
// Blueprint: | `AgentContactHealth.swift` | Checked saved health and contact presence; refresh classifies receipt evidence at its owner, excluding definite unsent failures from broken reply paths and deadlines. Read failures remain unavailable with repair owed, and malformed Codex auth is never called signed out. `not_reached` preserves definite unsent evidence; round trips prove replies, while changed programs/recipes are unverified. `repair` runs the contact's own send dry only for explicit `agent.verify`; desktop uncertainty is filed, never retried. Durable claims bound background checks to once per episode/contact/hour. |

/// Single flight per root. Saved exchanges own reply health; readiness never proves
/// a reply. The existing continuation and contact reads refresh it without resends.
public actor AgentContactHealth {
    public static let shared = AgentContactHealth()
    private var running: Set<String> = []
    private var pending: Set<String> = []
    private var appQueries: [Probe: UUID] = [:]
    private var appObservations: [Probe: (Bool, Date)] = [:]
    private var grokVerifiers: [String: @Sendable (String) async throws -> Void] = [:]
    /// A2A contacts whose card this launch's health has dry-run because their recipe had not read it.
    private var cardsRead: Set<String> = []

    /// Presence is read at presentation, independently of saved reply-path evidence.
    public nonisolated static func read(dataRoot: URL) throws -> [String: AgentLocalHealth] {
        var health = try AgentLocalHealth.checkedRead(dataRoot).mapValues {
            var evidence = $0
            evidence.retainReplyEvidence()
            return evidence
        }
        let peers = try AgentPeerStore(dataRoot: dataRoot).list()
        for peer in peers {
            let key = "peer:" + peer.id
            guard let door = try AgentConversationDelivery.door(for: key, dataRoot: dataRoot, peers: peers), door.liveReader else { continue }
            let bridge = claudePresence(inbox: door.inbox)
            if health[key] == nil { health[key] = AgentLocalHealth(status: "unchecked", detail: "", checkedAt: .distantPast, authenticated: false) }
            health[key]?.present(bridge)
        }
        for peer in peers {
            guard let presence = ChatGPTDotIPCTransport.owns(peer) ? dotPresence() : checkIn(peer) else { continue }
            let key = "peer:" + peer.id
            if health[key] == nil { health[key] = AgentLocalHealth(status: "unchecked", detail: "", checkedAt: .distantPast, authenticated: false) }
            health[key]?.present(presence)
        }
        return health
    }

    /// A door its host pulls from (an MCP host with no command line): her
    /// messages wait in the conversation and go out in the result of the host's
    /// next call through its entry. Live while it called in within 30 minutes.
    /// Nil for every other contact.
    public nonisolated static func checkIn(_ peer: AgentPeerContact) -> AgentLocalHealth? {
        guard peer.transport == .mcpHost, !ChatGPTDotIPCTransport.owns(peer),
              AgentPeerStore.hostRowID(peer.endpoint).flatMap(AgentHostDirectory.row(named:))?.commandLine == nil else { return nil }
        let at = peer.provenInboundAt.flatMap(NativeTimestampFormat.parseISO8601)
        if peer.provenInboundAt != nil, at == nil {
            return AgentLocalHealth(status: "unknown",
                detail: "\(peer.name)'s saved check-in timestamp is unreadable. Repair its provenInboundAt in agents/peers.json before judging its presence.",
                checkedAt: .distantPast, authenticated: false)
        }
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        guard let at, Date().timeIntervalSince(at) < 1800 else {
            return AgentLocalHealth(status: "waiting", detail: "Messages wait for \(peer.name)'s next check-in"
                + (at.map { " (last call \(NativeTimestampFormat.plainZulu($0)))" } ?? " (it has not called in yet)")
                + "; they go out in the result of its next call.", checkedAt: at ?? .distantPast, authenticated: false)
        }
        return AgentLocalHealth(status: "live", detail: "Live: \(peer.name) called in at \(clock.string(from: at)); a message goes out in the result of its next call.",
                                checkedAt: at, authenticated: false)
    }

    private nonisolated static func claudePresence(inbox: URL) -> AgentLocalHealth {
        let path = inbox.deletingLastPathComponent().appendingPathComponent("claude-live")
        let at = (try? FileManager.default.attributesOfItem(atPath: path.path))?[.modificationDate] as? Date
        let recent = at.map(AgentLocalHealth.isRecent) == true
        var presence = bridgePresence(recent)
        presence.checkedAt = at ?? .distantPast
        return presence
    }

    private nonisolated static func bridgePresence(_ recent: Bool) -> AgentLocalHealth {
        AgentLocalHealth(status: recent ? "recent_activity" : "waiting",
            detail: recent ? "The inbox bridge was active within the last 10 minutes." : "No recent activity from the inbox bridge.",
            checkedAt: Date(), authenticated: false)
    }

    /// Dot's word is his transport's: two-way while ChatGPT lets a local
    /// window own his conversation, otherwise inbound only (never broken).
    private nonisolated static func dotPresence() -> AgentLocalHealth {
        let fields: [String: JSONValue] = if case .object(let fields) = ChatGPTDotIPCTransport.readiness { fields } else { [:] }
        let available = fields["status"] == .string("available")
        return AgentLocalHealth(status: available ? "ready" : fields["status"] == .string("not_checked") ? "unchecked"
                                    : ChatGPTDotIPCTransport.inboundOnly ? "inbound_only" : "waiting",
            detail: available ? "Ready" : ChatGPTDotIPCTransport.detail, checkedAt: Date(), authenticated: false)
    }

    public func installGrokVerifier(dataRoot: URL, verify: @escaping @Sendable (String) async throws -> Void) async {
        grokVerifiers[dataRoot.standardizedFileURL.path] = verify
        await refresh(dataRoot: dataRoot)
    }

    /// THE ONE REPAIR (a send that sent nothing, `agent.verify`; never the
    /// background health check, which runs an A2A contact's dry run itself,
    /// `AgentPeerDiscovery.a2aCheck`): the contact's own send, run dry through the
    /// chain it always takes (`AgentRecipeStore.dryRun`). Its program is
    /// re-resolved and its handshake run with no prompt (ACP), its window's
    /// controls found without typing or coming forward (desktop chat), its
    /// executable and args checked without launching (command line). Protocol
    /// checks may learn their own evidence; desktop labels are never guessed.
    /// A pass closes the bridge items it exercised.
    package static func repair(_ agent: String, dataRoot: URL, workspace: String? = nil, perform: AgentConversationSession.Dispatch) async throws -> JSONValue {
        let store = AgentPeerStore(dataRoot: dataRoot)
        let peer = try store.list().first { "peer:" + $0.id == agent }
        if let row = peer.flatMap({ AgentPeerStore.hostRowID($0.endpoint) }).flatMap(AgentHostDirectory.row(named:)) ?? AgentHostDirectory.row(named: agent),
           row.acp == nil, row.settingsSupported || row.format == .shellEnvironment {
            let setup = AgentHostConnection.verifySetup(name: row.id, store: store, dataRoot: dataRoot, workspace: workspace ?? peer?.hostWorkspace)
            if !passed(setup) || peer == nil || row.commandLine == nil { return setup }
        }
        let found = try await perform("agent_message", ["agent": .string(agent), "text": .string(AgentHostDirectory.probeToken), "dry_run": .bool(true)])
        if passed(found), case .object(let fields) = found, let peer = text(fields["agent"]) {
            // A pass closes only what it exercised: an ACP handshake's protocol
            // mismatches, an A2A card's mismatches, a window's checked controls.
            // A send that lands closes the rest.
            let checked: [String] = if case .array(let keys)? = fields["checked"] { keys.compactMap { text($0) } } else { [] }
            let closes: [String] = switch text(fields["transport"]) {
            case "acp": ["protocol_mismatch|"]
            case "a2a": ["protocol_mismatch|", "recipe_mismatch|"]
            default: checked.map { "recipe_mismatch|" + $0 }
            }
            await resolve(peer, closes, note: "A dry run passed.", dataRoot: dataRoot)
        }
        return found
    }

    /// Keep the first exact send outcome. Repair is a separate explicit
    /// operation; a failure never authorizes another outbound attempt.
    package static func heal(_ receipt: JSONValue, row: AgentConversationRecord, dataRoot: URL) async -> JSONValue {
        guard row.agent.hasPrefix("peer:"), case .object(var failed) = receipt else { return receipt }
        if failed["completed"] == .bool(true) {
            await resolve(row.agent, [""], note: "A message reached it.", dataRoot: dataRoot)
            return receipt
        }
        guard let reason = text(failed["reason"]),
              ["protocol_mismatch", "recipe_mismatch", "connection_startup_timeout", "not_confirmed"].contains(reason) else { return receipt }
        failed["automatic_resend"] = .bool(false)
        failed["remedy"] = Repair.reconcile(instruction: "Inspect and repair this contact's authored connection with agent.verify; the failed message is never resent automatically.",
            nextCall: .object(["tool": .string("app"), "input": .object([
                "action": .string("agent.verify"), "args": .object(["agent": .string(row.agent)])])]))
        failed["harness_item"] = await file(failed, reason: reason, row: row, dataRoot: dataRoot,
            then: "Inspect the retained send before any new send. Read agent.recipe, correct it with agent.recipe_write, then explicitly verify or send.").map(JSONValue.string)
        return .object(failed)
    }

    /// One harness item per contact, class and selector or method, ref the exchange; its handle.
    private static func file(_ failed: [String: JSONValue], reason: String, row: AgentConversationRecord, dataRoot: URL,
                             then: String) async -> String? {
        let at = text(failed["selector"]) ?? text(failed["method"]) ?? text(failed["phase"]) ?? ""
        var labels: [String] = []
        if reason == "not_confirmed", case .array(let seen)? = failed["labels"] { labels = seen.compactMap { text($0) } }
        return try? await HarnessQueue.file(HarnessFinding(
            key: "bridge|\(row.agent.dropFirst("peer:".count))|\(reason)|\(at)",
            title: "\(row.name): \(reason.replacingOccurrences(of: "_", with: " ")) at \(at)",
            summary: (text(failed["detail"]) ?? "") + (labels.isEmpty ? "" : "\nWindow labels nearest \(at): "
                + labels.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ")) + "\n" + then,
            owner: .agent, refs: [DeskRef(kind: .agent(name: row.name, handoffId: row.operationID, sessionId: row.scopeSessionID))],
            source: .bridge), dataRoot: dataRoot).handle
    }

    /// The contact's bridge items under these keys ("class|selector or method") close.
    private static func resolve(_ agent: String, _ keys: [String], note: String, dataRoot: URL) async {
        guard !keys.isEmpty else { return }
        let prefix = "bridge|" + agent.dropFirst("peer:".count) + "|"
        try? await HarnessQueue.resolve(keyPrefixes: Dictionary(keys.map { (prefix + $0, note) }) { first, _ in first }, dataRoot: dataRoot)
    }

    private static func passed(_ found: JSONValue) -> Bool {
        guard case .object(let fields) = found else { return false }
        return [.string("passed"), .string("repaired")].contains(fields["status"] ?? .null)
    }

    private static func text(_ value: JSONValue?) -> String? {
        if case .string(let text)? = value { text } else { nil }
    }

    /// "Hermes Agent v0.21.5+… (2026.9.24)" is shown as 0.21.5.
    package static func shortVersion(_ version: String) -> String {
        version.range(of: #"\d+(\.\d+)+"#, options: .regularExpression).map { String(version[$0]) } ?? String(version.prefix { $0 != "\n" })
    }

    /// The route's fields, never its prose, establish whether anything left.
    /// Preserve positive or uncertain effects even in a contradictory receipt.
    private nonisolated static func sentNothing(_ receipt: [String: JSONValue]) -> Bool {
        // The route's own `sent` is the wire's evidence; a generic envelope's
        // effects ("unknown" stamped on a failure, as Muse's 10-20 receipt was)
        // speaks only when the route said nothing.
        if case .bool(let sent)? = receipt["sent"] { return !sent }
        if ["occurred", "partial", "unknown"].contains(text(receipt["effects"]) ?? "") { return false }
        return receipt["effects"] == .string("none") || receipt["execution"] == .string("not_run")
    }

    private struct ReplyEvidence {
        var good: Date?
        var newest: AgentConversationRecord?
        var expired: Date?
        var failure: AgentConversationRecord?
        var unsent: AgentConversationRecord?
        var interrupted: Date?
        var stalled: Date?
    }

    /// Shared by refresh and presentation so old persisted health obeys the
    /// same law immediately: only a send with possible delivery can be broken.
    private nonisolated static func replyEvidence(_ history: [AgentConversationRecord], peer: AgentPeerContact?) -> ReplyEvidence {
        let pullReplyProof = peer.flatMap(Self.checkIn) == nil ? nil : peer?.provenOutboundAt
        let good = (history.flatMap { $0.exchanges ?? [] }.filter { $0.reply != nil }.map { $0.settledAt ?? $0.sentAt }
            + [peer?.roundTripProof?.at, peer?.mcpReturnProof?.at,
               pullReplyProof].compactMap { $0.flatMap(NativeTimestampFormat.parseISO8601) }).max()
        let newest = history.max { $0.updatedAt < $1.updatedAt }
        let expired = newest.flatMap { row -> Date? in
            guard row.stop == nil, !sentNothing(row.sendEvidence), case .object(let receipt)? = row.receipt,
                  receipt["reply_state"] == .string("no_reply_expired"),
                  case .string(let stamp)? = receipt["reply_deadline"], let deadline = NativeTimestampFormat.parseISO8601(stamp),
                  (good ?? .distantPast) < deadline else { return nil }
            return deadline
        }
        let failed = history.filter { row in
            row.stop == nil && row.phase == "attention" && !AgentConversationSession.awaitingApproval(row)
                && (row.sendFailed || sentNothing(row.sendEvidence)) && (good ?? .distantPast) < row.updatedAt
        }
        let failure = failed.filter { !sentNothing($0.sendEvidence)
            && $0.sendEvidence["status"] != .string("no_reply_expired") }.min { $0.updatedAt < $1.updatedAt }
        let unsent = failed.filter { sentNothing($0.sendEvidence) }.max { $0.updatedAt < $1.updatedAt }
        // Our relaunch cut the send off: not a broken reply path.
        let interrupted = newest.flatMap { row -> Date? in
            guard row.stop == nil, row.phase == "attention", !sentNothing(row.sendEvidence),
                  row.sendEvidence["status"] == .string("interrupted"), (good ?? .distantPast) < row.updatedAt else { return nil }
            return row.updatedAt
        }
        let stalled = newest.flatMap { row -> Date? in
            guard row.stop == nil, row.phase == "attention", !sentNothing(row.sendEvidence),
                  row.sendEvidence["status"] == .string("outcome_unknown") else { return nil }
            let at = row.exchanges?.last { $0.id == row.operationID }?.settledAt ?? row.updatedAt
            return (good ?? .distantPast) < at ? at : nil
        }
        return ReplyEvidence(good: good, newest: newest, expired: expired, failure: failure,
                             unsent: unsent, interrupted: interrupted, stalled: stalled)
    }

    private nonisolated static func brokenDetail(since: Date, good: Date?, name: String) -> String {
        return "Reply path broken since \(NativeTimestampFormat.plainZulu(since)); last good \(good.map(NativeTimestampFormat.plainZulu) ?? "never"). Run agent.verify for \(name); do not resend the message."
    }

    private nonisolated static func notReached(_ row: AgentConversationRecord, peer: AgentPeerContact?, good: Date?) -> AgentLocalHealth {
        let receipt = row.sendEvidence
        let reason = text(receipt["detail"]) ?? text(receipt["error"]) ?? text(receipt["execution_error"])
            ?? text(receipt["reason"]) ?? "The send did not run."
        var detail = "Not reached yet: \(reason) (\(NativeTimestampFormat.plainZulu(row.updatedAt)))."
        let code = text(receipt["reason"])
        if peer?.transport == .desktopChat {
            let trusted = SystemMacAXElementSource().isTrusted()
            let installed = peer?.appBundleIDs.contains { AgentHostRow.applicationURL($0) != nil } == true
            // Old desktop receipts have sent=false but no blocker code. State
            // today's readable prerequisites without inferring a cause from prose.
            if trusted && installed && (code == nil || code == "accessibility_permission_missing") {
                detail += code == nil
                    ? " Accessibility is granted and the app is installed now; the next send may try."
                    : " Accessibility is granted now; that cause is gone and the next send may try."
            } else if !trusted {
                detail += " Accessibility is off now."
            } else if !installed {
                detail += " The app is not installed now."
            }
        }
        var observed = AgentLocalHealth(status: "not_reached", detail: detail, checkedAt: Date(), authenticated: false)
        observed.failureOperation = row.operationID
        observed.lastGoodAt = good
        return observed
    }

    public func refresh(dataRoot: URL) async {
        let key = dataRoot.standardizedFileURL.path
        guard running.insert(key).inserted else { pending.insert(key); return }
        defer {
            running.remove(key)
            if pending.remove(key) != nil { Task { await refresh(dataRoot: dataRoot) } }
        }
        let peers: [AgentPeerContact], records: [AgentConversationRecord]
        var previous: [String: AgentLocalHealth]
        do {
            (peers, records, previous) = try RepairOwed.attempt(dataRoot, operation: "agent.health.read",
                owner: "Contact health source storage",
                lever: "Repair the named contact, conversation or health file; saved health is preserved.",
                words: { "Contact health cannot be refreshed: " + $0.localizedDescription }) {
                (try AgentPeerStore(dataRoot: dataRoot).list(),
                 try AgentConversationStore(dataRoot: dataRoot).recordsUnlocked(),
                 try AgentLocalHealth.checkedRead(dataRoot))
            }
        } catch { return }
        let probes: [(String, Probe)] = peers.map { peer in
            let key = "peer:" + peer.id
            if let door = AgentConversationDelivery.door(for: key, dataRoot: dataRoot, contacts: peers), door.liveReader {
                return (key, .bridge(live: Self.claudePresence(inbox: door.inbox).status == "recent_activity"))
            }
            return (key, probe(peer))
        }
        var observations: [Probe: AgentLocalHealth] = [:]
        var changed = false
        var repairs: [(String, Probe, AgentPeerContact?, String)] = []
        for (agent, probe) in probes {
            let history = records.filter { $0.agent == agent }
            let peer = peers.first { "peer:" + $0.id == agent }
            let evidence = Self.replyEvidence(history, peer: peer)
            let good = evidence.good, expired = evidence.expired, failure = evidence.failure
            let interrupted = evidence.interrupted, stalled = evidence.stalled
            let operation = failure?.operationID ?? (expired == nil ? nil : evidence.newest?.operationID)
            // An inbound-only contact has no send path to be unavailable: a send
            // it refused is not a broken reply path (the transport lifts an older mark).
            let inboundOnly = peer.map { ChatGPTDotIPCTransport.owns($0) && ChatGPTDotIPCTransport.inboundOnly } == true
            // A bare unavailable mark says nothing about delivery (it can be
            // recorded before launch). The send receipt alone owns reply health.
            let broken = inboundOnly ? nil : failure?.updatedAt
            if !inboundOnly, broken == nil, expired == nil, interrupted == nil, stalled == nil,
               let unsent = evidence.unsent {
                let observed = Self.notReached(unsent, peer: peer, good: good)
                if observed.replyStatus != previous[agent]?.replyStatus || observed.detail != previous[agent]?.detail
                    || observed.failureOperation != previous[agent]?.failureOperation || observed.lastGoodAt != previous[agent]?.lastGoodAt
                    || previous[agent]?.brokenSince != nil || previous[agent]?.repairFor != nil || previous[agent]?.repairDetail != nil
                    || previous[agent]?.repairAttemptedAt != nil {
                    previous[agent] = observed
                    changed = true
                }
                continue
            }
            let proof = peer?.roundTripProof ?? peer?.mcpReturnProof
            let appVersion = peer?.appBundleIDs.compactMap(AgentHostRow.applicationURL).first
                .flatMap { AgentPeerContact.appVersion(at: $0.path) }
            // Unverified: the app, its program, or the recipe it is reached by
            // changed since the proof. Said with what changed; nothing is repaired for it.
            let recipe = peer?.recipeID.flatMap(AgentRecipeStore.recipe)
            // A recipe that has not read its card (seeded at launch, or not yet):
            // its dry run, once a launch, fills it in; nothing is sent.
            if let peer, peer.transport == .a2a, recipe?.host.a2a?.read == nil, cardsRead.insert(peer.id).inserted {
                Task {
                    do { _ = try await Self.cardCheck(peer) }
                    catch { nativeLog("AgentContactHealth: %@'s card was not checked: %@", peer.name, error.localizedDescription) }
                }
            }
            let recipeDigest: String?
            do { recipeDigest = try recipe?.hostDigest }
            catch {
                var observed = previous[agent] ?? AgentLocalHealth(status: "unavailable", detail: "", checkedAt: Date(), authenticated: false)
                observed.status = "unavailable"
                observed.detail = "The recipe's identity cannot be read: \(error.localizedDescription). Repair its recipe file before verifying this contact."
                observed.checkedAt = Date()
                previous[agent] = observed
                changed = true
                continue
            }
            let recipeChanged = (proof?.recipeVersion != nil || proof?.recipeDigest != nil)
                && (proof?.recipeVersion != recipe?.recipeVersion || proof?.recipeDigest != recipeDigest)
            // A program's version as its approved receipt reported it (a Full Mac
            // launch follows an update and records the new one), against the proof's.
            let programVersion = peer?.acpExecutable?.version
            let programChanged = programVersion != nil && proof?.version.map { $0 != programVersion } == true
            let programShown = programVersion.map(Self.shortVersion)
            let unverified = recipeChanged || programChanged
                || (peer?.transport == .desktopChat && proof != nil && (proof?.appVersion == nil || appVersion == nil))
                || (peer?.appBundleIDs.isEmpty == false && proof?.appVersion.map { $0 != appVersion } == true)
            // An inbound-only contact has no outbound path: no broken, expired, interrupted or unverified send.
            if !inboundOnly, broken != nil || expired != nil || interrupted != nil || stalled != nil || unverified {
                var observed = previous[agent] ?? AgentLocalHealth(status: "broken", detail: "", checkedAt: Date(), authenticated: false)
                observed.status = broken != nil ? "broken" : expired != nil ? "no_reply_by_deadline" : interrupted != nil ? "interrupted"
                    : stalled != nil ? "stalled" : "unverified"
                observed.brokenSince = broken
                observed.lastGoodAt = good
                observed.failureOperation = operation
                // Dot's own transport knows what is wrong; its words lead, and they say
                // which way is broken: a send that cannot be delivered is not a reply path.
                let dotWords: String? = if let peer, ChatGPTDotIPCTransport.owns(peer), !ChatGPTDotIPCTransport.available,
                    case .object(let state) = ChatGPTDotIPCTransport.readiness, let why = Self.text(state["detail"]), !why.isEmpty {
                    "Sends to \(peer.name) cannot be delivered: \(why) He can still reach her by running the local message command on this Mac (nativeagent-link message, with his contact file); a reply typed in his own chat no longer arrives. Last good send \(good.map(NativeTimestampFormat.plainZulu) ?? "never")."
                } else { nil }
                observed.detail = dotWords ?? broken.map {
                    Self.brokenDetail(since: $0, good: good, name: peer?.name ?? agent)
                } ?? expired.map {
                    "No reply by the deadline \(NativeTimestampFormat.plainZulu($0)); last good \(good.map(NativeTimestampFormat.plainZulu) ?? "never"). Run agent.verify for \(peer?.name ?? agent); do not resend the message."
                } ?? (interrupted ?? stalled).map { at in
                    let clock = DateFormatter()
                    clock.dateFormat = "HH:mm"
                    return interrupted != nil
                        ? "Last send to \(peer?.name ?? agent) was interrupted by a relaunch at \(clock.string(from: at)); the next message proves the path."
                        : "A reply stalled at \(clock.string(from: at)) with its outcome unknown; the next message to \(peer?.name ?? agent) proves the path."
                } ?? "Unverified since " + (recipeChanged ? "the recipe changed"
                    : programChanged ? "\(peer?.name ?? agent) updated to \(programShown ?? "")"
                    : appVersion.map { "\(peer?.name ?? agent) updated to \($0)" } ?? "\(peer?.name ?? agent)'s app could not be found")
                if ["interrupted", "stalled", "unverified"].contains(observed.status) {
                    observed.repairFor = nil
                    observed.repairDetail = nil
                } else if let reason = operation ?? broken.map(NativeTimestampFormat.plainZulu), observed.repairFor != reason,
                   Date().timeIntervalSince(observed.repairAttemptedAt ?? .distantPast) >= 3600,
                   peer?.transport != .grokBot || grokVerifiers[key] != nil {
                    observed.repairFor = reason
                    observed.repairAttemptedAt = Date()
                    // The send already ran the repair: what it found, not a second run.
                    if case .object(let repair)? = failure?.sendEvidence["repair"],
                       let found = Self.text(repair["detail"]) {
                        observed.repairDetail = found
                    } else {
                        observed.repairDetail = "Checking the reply path; no message will be resent."
                        repairs.append((agent, probe, peer, reason))
                    }
                }
                guard observed != previous[agent] else { continue }
                observed.checkedAt = Date()
                previous[agent] = observed
                changed = true
                continue
            }
            // Dot's word is overlaid live at every read (`present`); the stored
            // row drops it, so comparing the two never matched and every
            // refresh rewrote this watched file (a CPU loop, 10-12).
            if let old = previous[agent], !old.sticky, old.lastGoodAt == good, Date().timeIntervalSince(old.checkedAt) < AgentLocalHealth.refreshInterval,
               old.failureOperation == operation { continue }
            if Task.isCancelled { return }
            var observed: AgentLocalHealth
            if let kept = observations[probe] { observed = kept }
            else { observed = await inspect(probe); observations[probe] = observed }
            observed.failureOperation = operation
            observed.lastGoodAt = good
            // Ready means a reply came back. A program or app on disk proves
            // only that it is installed.
            if observed.status == "ready", good == nil {
                observed.status = "installed"
                observed.detail = "Installed; no reply proven yet"
            }
            // Nothing to repair on an inbound-only contact: an earlier repair's words go with the fault.
            observed.repairAttemptedAt = observed.status == "inbound_only" ? nil : previous[agent]?.repairAttemptedAt
            observed.repairFor = observed.status == "inbound_only" ? nil : previous[agent]?.repairFor
            if let old = previous[agent] { arrive(agent, from: old, to: observed, peers: peers, dataRoot: dataRoot) }
            previous[agent] = observed
            changed = true
        }
        for (agent, _) in probes {
            let before = previous[agent]
            previous[agent]?.retainReplyEvidence()
            changed = changed || before != previous[agent]
        }
        guard changed else { return }
        let active = Set(probes.map(\.0))
        previous = previous.filter { active.contains($0.key) }
        guard let savedHealth = try? AgentLocalHealth.checkedRead(dataRoot) else { return }
        for (agent, saved) in savedHealth where previous[agent]?.replyStatus != "not_reached"
            && saved.repairFor == previous[agent]?.repairFor {
            previous[agent]?.repairDetail = saved.repairDetail
        }
        do { try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(previous), to: AgentLocalHealth.url(dataRoot)) }
        catch { nativeLog("AgentContactHealth: could not save local observations: %@", error.localizedDescription); return }
        for (agent, probe, peer, operation) in repairs {
            Task { await verify(agent, probe: probe, peer: peer, operation: operation, dataRoot: dataRoot) }
        }
    }

    private func verify(_ agent: String, probe: Probe, peer: AgentPeerContact?, operation: String, dataRoot: URL) async {
        let name = peer?.name ?? agent
        let detail: String
        do {
            if let peer, peer.transport == .grokBot, let verify = grokVerifiers[dataRoot.standardizedFileURL.path] {
                try await verify(peer.id)
                detail = "Reply routine re-imported; an actual reply is still unproven. Approve its reply command in Grok Bot if asked."
            } else if let peer, peer.transport == .a2a {
                let found = try await Self.cardCheck(peer)
                detail = (Self.text(found["detail"]) ?? "") + (Self.passed(.object(found))
                    ? " An actual reply is still unproven; run agent.verify for \(name)."
                    : " Fix its recipe with agent.recipe_write, or ask \(name)'s owner to restore its card, then run agent.verify.")
            } else if let peer, peer.transport == .nativeAgent {
                let result = try await AgentPeerDiscovery.resolve(peer.endpoint.appendingPathComponent("agent/card"), bearerToken: AgentPeerCredentials.read(peerID: peer.id))
                detail = result.transport == peer.transport
                    ? "Connection check passed; an actual reply is still unproven. Run agent.verify for \(name)."
                    : "Connection check failed. Ask \(name)'s owner to restore its advertised reply endpoint, then run agent.verify."
            } else {
                if probe == .dot { ChatGPTDotIPCTransport.reconnect() }
                let result = await inspect(probe)
                detail = "Readiness check: \(result.detail). " + (result.status == "ready" || result.status == "live"
                    ? "An actual reply is still unproven; run agent.verify for \(name)."
                    : "Restore \(name)'s installation or sign-in, then run agent.verify.")
            }
        } catch {
            detail = peer?.transport == .grokBot
                ? String(error.localizedDescription.split(separator: "\n").first ?? "Routine verification failed.") + " Open Grok Bot's Routines and restore the NativeAgent reply routine, then run agent.verify for \(name)."
                : "Restore \(name)'s reply endpoint or sign-in, then run agent.verify."
        }
        guard var health = try? AgentLocalHealth.checkedRead(dataRoot) else { return }
        guard health[agent]?.repairFor == operation, health[agent]?.brokenSince != nil || health[agent]?.status == "no_reply_by_deadline" else { return }
        health[agent]?.repairDetail = detail
        for key in health.keys { health[key]?.retainReplyEvidence() }
        do { try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(health), to: AgentLocalHealth.url(dataRoot)) }
        catch { nativeLog("AgentContactHealth: could not save verification: %@", error.localizedDescription) }
    }

    /// An A2A contact's dry run, as agent.verify runs it: what changed in its
    /// card is learned. No proof is recorded here: readiness never proves a reply.
    private static func cardCheck(_ peer: AgentPeerContact) async throws -> [String: JSONValue] {
        let token = try AgentPeerCredentials.read(peerID: peer.id)
        return await AgentRecipeStore.$dryRun.withValue(true) {
            await AgentPeerDiscovery.a2aCheck(peer, bearerToken: token, sending: true).receipt
        }
    }

    /// Signed out or program missing, and back again, arrive for her
    /// (ResidentWake). A status must hold a minute before it wakes her; one
    /// that flips back first is taken back, so a flapping agent wakes nothing.
    private func arrive(_ agent: String, from old: AgentLocalHealth, to new: AgentLocalHealth,
                        peers: [AgentPeerContact], dataRoot: URL) {
        let problems: Set<String> = ["signed_out", "unavailable"]
        let name = peers.first { "peer:" + $0.id == agent }?.name ?? agent.prefix(1).uppercased() + agent.dropFirst()
        let key = "health:" + agent, stamp = String(Int(new.checkedAt.timeIntervalSince1970))
        if problems.contains(new.status), new.status != old.status {
            ResidentWake.shared.request(dataRoot: dataRoot, reason: "what resolved", items: [.init(
                id: key + ":" + new.status + ":" + stamp, line: name + ": " + new.detail, key: key, thread: key, hold: 60)])
        } else if problems.contains(old.status), ["ready", "installed"].contains(new.status),
                  !ResidentWake.shared.withdraw(dataRoot: dataRoot, key: key) {
            var evidence = new
            evidence.retainReplyEvidence()
            ResidentWake.shared.request(dataRoot: dataRoot, reason: "what resolved", items: [.init(
                id: key + ":recovery:" + stamp, line: name, key: key, thread: key, home: true, hold: 60,
                at: new.checkedAt, recoveredFrom: old.status, recovery: evidence)])
        }
    }

    private enum Probe: Hashable {
        case command(String, String?)
        case app([String])
        case remote
        case bridge(live: Bool)
        case dot
    }

    private func probe(_ peer: AgentPeerContact) -> Probe {
        // Dot answers only through the ChatGPT app's IPC follower, not because the app is installed.
        if ChatGPTDotIPCTransport.owns(peer) { return .dot }
        let host = AgentPeerStore.hostRowID(peer.endpoint).flatMap { AgentHostDirectory.row(named: $0) }
        // The program installed now: a launch follows its updates (hostACPRun,
        // drivenAgentLaunch), so an update is not a problem.
        if let host, let executable = host.acp?.executable ?? host.commandLine?.executable {
            return .command(executable, host.resolveExecutable(executable))
        }
        if let bundle = AgentPeerStore.desktopBundleID(peer.endpoint) { return .app([bundle]) }
        if let bundles = host?.bundleIDs, !bundles.isEmpty { return .app(bundles) }
        return .remote
    }

    private func inspect(_ probe: Probe) async -> AgentLocalHealth {
        func result(_ status: String, _ detail: String, authenticated: Bool = false) -> AgentLocalHealth {
            AgentLocalHealth(status: status, detail: detail, checkedAt: Date(), authenticated: authenticated)
        }
        switch probe {
        case .remote: return result("unchecked", "No local health probe")
        case .bridge(let live):
            return Self.bridgePresence(live)
        case .dot:
            return Self.dotPresence()
        case .app(let bundles):
            // A stuck Launch Services lookup is retained, never multiplied by
            // subsequent samples, including the waiter on its task value.
            if appQueries[probe] != nil {
                guard let observation = appObservations.removeValue(forKey: probe) else {
                    return result("unknown", "Health check timed out")
                }
                appQueries.removeValue(forKey: probe)
                return appObservation(observation)
            }
            let queryID = UUID()
            appQueries[probe] = queryID
            let query = Task.detached(priority: .utility) {
                let installed = bundles.contains { bundle in
                    AgentHostRow.applicationURL(bundle) != nil
                }
                let observation = (installed, Date())
                await self.keepAppObservation(observation, for: probe, queryID: queryID)
                return observation
            }
            switch await raceAgainstTimeout(seconds: 4, { await query.value }) {
            case .value(let observation):
                if appQueries[probe] == queryID {
                    appQueries.removeValue(forKey: probe)
                    appObservations.removeValue(forKey: probe)
                }
                return appObservation(observation)
            case .timedOut: return result("unknown", "Health check timed out")
            case .failure, .cancelled: return result("unknown", "Health check unavailable")
            }
        case .command(let name, let path):
            // A file check, never a launch: whether a model answers is the last
            // exchange's to say (her people rows), not a `--version` run.
            guard let path, FileManager.default.isExecutableFile(atPath: path) else {
                return result("unavailable", "Program not installed — \(name)")
            }
            guard name == "codex" else { return result("ready", "Program installed") }
            // `codex login status` answers from this file: signed in is a saved
            // ChatGPT token or API key in it. Only its presence is looked at.
            let authPath = ChatGPTTransport.preferredAuthPath(source: .commandCLI)
            func present(_ value: JSONValue?) -> Bool {
                if case .string(let text)? = value { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                return false
            }
            let auth: [String: JSONValue]
            do {
                let data = try Data(contentsOf: authPath)
                guard case .object(let fields) = try JSONValue.parse(data) else {
                    return result("unknown", "Codex authentication file is malformed; repair " + authPath.path)
                }
                auth = fields
            } catch CocoaError.fileReadNoSuchFile { return result("signed_out", "Signed out — run codex login") }
            catch { return result("unknown", "Codex authentication could not be read: " + error.localizedDescription + ". Repair " + authPath.path) }
            var tokens: [String: JSONValue] = [:]
            if case .object(let saved)? = auth["tokens"] { tokens = saved }
            return present(tokens["access_token"]) || present(tokens["refresh_token"]) || present(auth["OPENAI_API_KEY"])
                ? result("ready", "Ready", authenticated: true) : result("signed_out", "Signed out — run codex login")
        }
    }

    private func keepAppObservation(_ observation: (Bool, Date), for probe: Probe, queryID: UUID) {
        guard appQueries[probe] == queryID else { return }
        appObservations[probe] = observation
    }

    private func appObservation(_ observation: (Bool, Date)) -> AgentLocalHealth {
        AgentLocalHealth(status: observation.0 ? "ready" : "unavailable",
            detail: observation.0 ? "App installed" : "App not installed", checkedAt: observation.1, authenticated: false)
    }
}
