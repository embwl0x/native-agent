import AgentWorkspace
import ChatToolParsing
import Desk
import Foundation
import Experiences
import NativeAgentShared
import MacControl
import NativeAgentCore
import PersistenceCore
import ProviderRouting
// Blueprint: | `AgentContactHealth.swift` | `not_reached`, `repair`, `agent.verify`; Reply health requires exchange evidence. |

/// Saved exchanges alone prove reply health; refresh is single-flight per root and never resends.
public actor AgentContactHealth {
    public static let shared = AgentContactHealth()
    private var running: Set<String> = []
    private var pending: Set<String> = []
    private var appQueries: [Probe: UUID] = [:]
    private var appObservations: [Probe: (Bool, Date)] = [:]
    private var grokVerifiers: [String: @Sendable (String) async throws -> Void] = [:]
    private var cardsRead: Set<String> = []

    /// Presence is live evidence independent of saved reply health.
    public nonisolated static func read(dataRoot: URL) throws -> [String: AgentLocalHealth] {
        var health = try AgentLocalHealth.checkedRead(dataRoot).mapValues {
            var evidence = $0
            evidence.retainReplyEvidence()
            return evidence
        }
        let peers = try AgentPeerStore(dataRoot: dataRoot).list()
        for peer in peers {
            guard let presence = ChatGPTDotIPCTransport.owns(peer) ? dotPresence() : checkIn(peer) else { continue }
            let key = "peer:" + peer.id
            if health[key] == nil { health[key] = AgentLocalHealth(status: "unchecked", detail: "", checkedAt: .distantPast, authenticated: false) }
            health[key]?.present(presence)
        }
        return health
    }

    /// Pull hosts receive queued messages on their next call; only a call within 30 minutes proves live presence.
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
        return AgentLocalHealth(status: "live",
            detail: "Live: \(peer.name) called in at \(clock.string(from: at)); a message goes out in the result of its next call.",
                                checkedAt: at, authenticated: false)
    }

    /// The transport owns directionality: a local ChatGPT window permits two-way delivery; inbound-only is not broken.
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

    /// Only explicit verification runs the contact’s own send dry; background health never resends. Protocol checks may learn evidence; desktop labels cannot
    /// be guessed, and a pass closes only faults it exercised.
    package static func repair(turn: Turn, mac: MacOperationContext, conversation: AgentConversationContext, _ agent: String, dataRoot: URL,
        workspace: String? = nil, perform: AgentConversationSession.Dispatch) async throws -> JSONValue {
        let store = AgentPeerStore(dataRoot: dataRoot)
        let peer = try store.list().first { "peer:" + $0.id == agent }
        if let row = peer.flatMap({ AgentPeerStore.hostRowID($0.endpoint) }).flatMap(AgentHostDirectory.row(named:)) ?? AgentHostDirectory.row(named: agent),
           row.acp == nil, row.settingsSupported || row.format == .shellEnvironment {
            let setup = AgentHostConnection.verifySetup(name: row.id, store: store, dataRoot: dataRoot, workspace: workspace ?? peer?.hostWorkspace)
            if !passed(setup) || peer == nil || row.commandLine == nil { return setup }
        }
        var verification = conversation
        verification.dryRun = true
        let found = try await perform("agent_message", ["agent": .string(agent), "text": .string(AgentHostDirectory.probeToken), "dry_run": .bool(true)],
            turn, verification, mac)
        if passed(found), case .object(let fields) = found, let peer = text(fields["agent"]) {
            // A pass closes only faults it exercised; actual delivery closes the rest.
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

    /// Keep the first exact send outcome. Repair is a separate explicit operation; a failure never authorizes another outbound attempt.
    package static func heal(_ receipt: JSONValue, row: AgentConversationRecord, dataRoot: URL) async -> JSONValue {
        guard row.agent.hasPrefix("peer:"), case .object(var failed) = receipt else { return receipt }
        if failed["completed"] == .bool(true) {
            await resolve(row.agent, [""], note: "A message reached it.", dataRoot: dataRoot)
            return receipt
        }
        guard let reason = text(failed["reason"]),
              ["protocol_mismatch", "recipe_mismatch", "connection_startup_timeout", "not_confirmed"].contains(reason) else { return receipt }
        failed["automatic_resend"] = .bool(false)
        failed["remedy"] = Repair.reconcile(
            instruction: "Inspect and repair this contact's authored connection with agent.verify; the failed message is never resent automatically.",
            nextCall: .object(["tool": .string("app"), "input": .object([
                "action": .string("agent.verify"), "args": .object(["agent": .string(row.agent)])])]))
        failed["harness_item"] = await file(failed, reason: reason, row: row, dataRoot: dataRoot,
            then: """
                Inspect the retained send before any new send. Read agent.recipe, correct it with agent.recipe_write, then explicitly verify or send.
                """).map(JSONValue.string)
        return .object(failed)
    }

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

    package static func shortVersion(_ version: String) -> String {
        version.range(of: #"\d+(\.\d+)+"#, options: .regularExpression).map { String(version[$0]) } ?? String(version.prefix { $0 != "\n" })
    }

    /// The route's fields, never its prose, establish whether anything left. Preserve positive or uncertain effects even in a contradictory receipt.
    private nonisolated static func sentNothing(_ receipt: [String: JSONValue]) -> Bool {
        // The route’s `sent` field owns wire evidence; generic envelope effects speak only when it is absent.
        if case .bool(let sent)? = receipt["sent"] { return !sent }
        let reply = ToolResult(.object(receipt))
        switch reply.effects {
        case .occurred?, .partial?, .unknown?: return false
        default: break
        }
        return reply.effects == ToolFailureError.Effects.none || receipt["execution"] == .string("not_run")
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

    /// Refresh and presentation share the rule: only possible delivery can establish a broken reply path.
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
        // A relaunch-interrupted send does not prove a broken reply path.
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
        return """
            Reply path broken since \(NativeTimestampFormat.plainZulu(since)); last good \(good.map(NativeTimestampFormat.plainZulu) ?? "never"). \
            Run agent.verify for \(name); do not resend the message.
            """
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
            // Without a blocker code, report readable prerequisites without inferring causes from prose.
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
        let probes: [(String, Probe)] = peers.map { ("peer:" + $0.id, probe($0)) }
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
            // Inbound-only contacts have no outbound reply path to mark broken.
            let inboundOnly = peer.map { ChatGPTDotIPCTransport.owns($0) && ChatGPTDotIPCTransport.inboundOnly } == true
            // Unavailable alone says nothing about delivery; the send receipt owns reply health.
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
            // Changed app, program or recipe identity invalidates proof without establishing a repairable fault.
            let recipe = peer?.recipeID.flatMap(AgentRecipeStore.recipe)
            // One dry run per launch fills unread card evidence without sending.
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
            // Compare the approved program version against the proof, since Full Mac launches follow updates.
            let programVersion = peer?.acpExecutable?.version
            let programChanged = programVersion != nil && proof?.version.map { $0 != programVersion } == true
            let programShown = programVersion.map(Self.shortVersion)
            let unverified = recipeChanged || programChanged
                || (peer?.transport == .desktopChat && proof != nil && (proof?.appVersion == nil || appVersion == nil))
                || (peer?.appBundleIDs.isEmpty == false && proof?.appVersion.map { $0 != appVersion } == true)
            // Inbound-only contacts cannot have broken, expired, interrupted or unverified sends.
            if !inboundOnly, broken != nil || expired != nil || interrupted != nil || stalled != nil || unverified {
                var observed = previous[agent] ?? AgentLocalHealth(status: "broken", detail: "", checkedAt: Date(), authenticated: false)
                observed.status = broken != nil ? "broken" : expired != nil ? "no_reply_by_deadline" : interrupted != nil ? "interrupted"
                    : stalled != nil ? "stalled" : "unverified"
                observed.brokenSince = broken
                observed.lastGoodAt = good
                observed.failureOperation = operation
                // Transport evidence distinguishes an undeliverable send from a broken reply path.
                let dotWords: String? = if let peer, ChatGPTDotIPCTransport.owns(peer), !ChatGPTDotIPCTransport.available,
                    case .object(let state) = ChatGPTDotIPCTransport.readiness, let why = Self.text(state["detail"]), !why.isEmpty {
                    """
                        Sends to \(peer.name) cannot be delivered: \(why) \(peer.name) can still reach the agent by running the local message \
                        command on this Mac (nativeagent-link message, with its contact file); a reply typed in its own chat no longer arrives. Last good send \
                        \(good.map(NativeTimestampFormat.plainZulu) ?? "never").
                        """
                } else { nil }
                observed.detail = dotWords ?? broken.map {
                    Self.brokenDetail(since: $0, good: good, name: peer?.name ?? agent)
                } ?? expired.map {
                    """
                        No reply by the deadline \(NativeTimestampFormat.plainZulu($0)); last good \
                        \(good.map(NativeTimestampFormat.plainZulu) ?? "never"). Run agent.verify for \(peer?.name ?? agent); do not resend the \
                        message.
                        """
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
                    // Use the repair evidence from the send without running it again.
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
            // Exclude live transport overlays when comparing stored rows, or each refresh rewrites the watched file.
            if let old = previous[agent], !old.sticky, old.lastGoodAt == good, Date().timeIntervalSince(old.checkedAt) < AgentLocalHealth.refreshInterval,
               old.failureOperation == operation { continue }
            if Task.isCancelled { return }
            var observed: AgentLocalHealth
            if let kept = observations[probe] { observed = kept }
            else { observed = await inspect(probe); observations[probe] = observed }
            observed.failureOperation = operation
            observed.lastGoodAt = good
            // Ready requires a reply; an installed program alone proves no round trip.
            if observed.status == "ready", good == nil {
                observed.status = "installed"
                observed.detail = "Installed; no reply proven yet"
            }
            // Inbound-only contacts have no outbound fault to repair.
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
        let conversation = AgentConversationContext()
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
                let result = try await AgentPeerDiscovery.resolve(conversation: conversation, peer.endpoint.appendingPathComponent("agent/card"),
                    bearerToken: AgentPeerCredentials.read(peerID: peer.id))
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
                ? String(error.localizedDescription.split(separator: "\n").first ?? "Routine verification failed.")
                    + " Open Grok Bot's Routines and restore the NativeAgent reply routine, then run agent.verify for \(name)."
                : "Restore \(name)'s reply endpoint or sign-in, then run agent.verify."
        }
        guard var health = try? AgentLocalHealth.checkedRead(dataRoot) else { return }
        guard health[agent]?.repairFor == operation, health[agent]?.brokenSince != nil || health[agent]?.status == "no_reply_by_deadline" else { return }
        health[agent]?.repairDetail = detail
        for key in health.keys { health[key]?.retainReplyEvidence() }
        do { try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(health), to: AgentLocalHealth.url(dataRoot)) }
        catch { nativeLog("AgentContactHealth: could not save verification: %@", error.localizedDescription) }
    }

    /// Card checks may learn changes, but readiness cannot establish reply proof.
    private static func cardCheck(_ peer: AgentPeerContact) async throws -> [String: JSONValue] {
        let token = try AgentPeerCredentials.read(peerID: peer.id)
        var conversation = AgentConversationContext()
        conversation.dryRun = true
        return await AgentPeerDiscovery.a2aCheck(conversation: conversation, peer, bearerToken: token, sending: true).receipt
    }

    /// A status must persist for a minute before waking the agent, so flapping creates no arrivals.
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
        case dot
    }

    private func probe(_ peer: AgentPeerContact) -> Probe {
        // An IPC follower, rather than app installation, proves the ChatGPT reply path.
        if ChatGPTDotIPCTransport.owns(peer) { return .dot }
        let host = AgentPeerStore.hostRowID(peer.endpoint).flatMap { AgentHostDirectory.row(named: $0) }
        // Launches follow installed program updates, so an update alone is not a fault.
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
        case .dot:
            return Self.dotPresence()
        case .app(let bundles):
            // Retain a stuck Launch Services lookup and its waiter so later samples cannot multiply work.
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
            // Inspect files without launching; only exchanges establish whether the model answers.
            guard let path, FileManager.default.isExecutableFile(atPath: path) else {
                return result("unavailable", "Program not installed — \(name)")
            }
            guard name == "codex" else { return result("ready", "Program installed") }
            // Authentication presence comes from the same saved token or API-key file the CLI reads.
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
