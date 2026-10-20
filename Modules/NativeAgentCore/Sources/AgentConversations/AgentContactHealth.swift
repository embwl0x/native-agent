import AgentWorkspace
import Desk
import Foundation
import MacControl
import NativeAgentCore
import PersistenceCore

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
    public nonisolated static func read(dataRoot: URL) -> [String: AgentLocalHealth] {
        var health = AgentLocalHealth.read(dataRoot).mapValues {
            var evidence = $0
            evidence.retainReplyEvidence()
            return evidence
        }
        let peers = (try? AgentPeerStore(dataRoot: dataRoot).list()) ?? []
        for peer in peers {
            let key = "peer:" + peer.id
            guard let door = AgentConversationDelivery.door(for: key, dataRoot: dataRoot), door.liveReader else { continue }
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
        let at = peer.provenInboundAt.flatMap { ISO8601DateFormatter().date(from: $0) }
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        guard let at, Date().timeIntervalSince(at) < 1800 else {
            return AgentLocalHealth(status: "waiting", detail: "Messages wait for \(peer.name)'s next check-in"
                + (at.map { " (last call \(ISO8601DateFormatter().string(from: $0)))" } ?? " (it has not called in yet)")
                + "; they go out in the result of its next call.", checkedAt: at ?? .distantPast, authenticated: false)
        }
        return AgentLocalHealth(status: "live", detail: "Live: \(peer.name) called in at \(clock.string(from: at)); a message goes out in the result of its next call.",
                                checkedAt: at, authenticated: false)
    }

    private nonisolated static func claudePresence(inbox: URL) -> AgentLocalHealth {
        let path = inbox.deletingLastPathComponent().appendingPathComponent("claude-live")
        let at = (try? FileManager.default.attributesOfItem(atPath: path.path))?[.modificationDate] as? Date
        let recent = at.map { Date().timeIntervalSince($0) < 600 } == true
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
    /// executable and args checked without launching (command line). Findings
    /// are written to its recipe; a pass closes the bridge items it exercised.
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

    /// ONE RETRY, BOUND TO THE SEND THAT FAILED: a receipt saying nothing was
    /// sent because the route and the agent disagree (`protocol_mismatch`,
    /// `recipe_mismatch`) or it timed out starting runs `repair`. When that
    /// passes, the same operation goes once more and stops there, saying what
    /// healed. When it fails, the receipt (still not sent) keeps the dry run's
    /// findings, and one harness item asks her to fix the recipe and send again.
    /// A desktop chat whose log changed shape after Return (the message may
    /// have gone out) is never retried, only filed. A send that lands closes
    /// the contact's items: her fix worked.
    package static func heal(_ receipt: JSONValue, row: AgentConversationRecord, dataRoot: URL,
                             again: () async throws -> JSONValue, dispatch: AgentConversationSession.Dispatch) async throws -> JSONValue {
        guard row.agent.hasPrefix("peer:"), case .object(var failed) = receipt else { return receipt }
        if failed["completed"] == .bool(true) {
            await resolve(row.agent, [""], note: "A message reached it.", dataRoot: dataRoot)
            return receipt
        }
        guard let reason = text(failed["reason"]) else { return receipt }
        if failed["sent"] != .bool(false) {
            guard ["recipe_mismatch", "not_confirmed"].contains(reason) else { return receipt }
            failed["harness_item"] = await file(failed, reason: reason, row: row, dataRoot: dataRoot,
                then: "The message may have gone out, so nothing was retried. Read its recipe with agent.recipe and fix it with agent.recipe_write; the next message that lands closes this.").map(JSONValue.string)
            return .object(failed)
        }
        guard ["protocol_mismatch", "recipe_mismatch", "connection_startup_timeout"].contains(reason) else { return receipt }
        // A dry run that cannot run leaves the send as it was: not sent.
        let checked: JSONValue
        do { checked = try await repair(row.agent, dataRoot: dataRoot, perform: dispatch) }
        catch { checked = .object(["status": .string("failed"), "detail": .string("The dry run could not run: \(error.localizedDescription)")]) }
        let found: [String: JSONValue] = if case .object(let fields) = checked { fields } else { [:] }
        guard passed(checked) else {
            failed["repair"] = checked
            failed["harness_item"] = await file(failed, reason: reason, row: row, dataRoot: dataRoot,
                then: "Dry run: " + (text(found["detail"]) ?? "did not pass.")
                    + "\nRead its recipe with agent.recipe, fix it with agent.recipe_write, then agent.verify or send again.").map(JSONValue.string)
            return .object(failed)
        }
        guard case .object(var resent) = try await again() else { return receipt }
        resent["repair"] = checked
        if resent["sent"] == .bool(true) {
            resent["healed"] = .string((text(found["healed"]) ?? "\(row.name): the dry run passed") + ", message sent")
        }
        if resent["completed"] == .bool(true) { await resolve(row.agent, [""], note: "A message reached it.", dataRoot: dataRoot) }
        if resent["sent"] != .bool(true) {
            // The one retry did not go through: the same item, with the repair that passed.
            let basis = text(resent["reason"]) == nil ? failed.merging(["detail": resent["detail"] ?? .null]) { $1 } : resent
            resent["harness_item"] = await file(basis, reason: text(basis["reason"]) ?? reason, row: row, dataRoot: dataRoot,
                then: "Dry run: " + (text(found["detail"]) ?? "passed.") + (resent["sent"] == .bool(false)
                    ? "\nThe one retry was not sent either. Read its recipe with agent.recipe, fix it with agent.recipe_write, then agent.verify or send again."
                    : "\nThe one retry may have gone out, so nothing more was retried. Read its recipe with agent.recipe and fix it with agent.recipe_write; the next message that lands closes this.")).map(JSONValue.string)
        }
        return .object(resent)
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

    public func refresh(dataRoot: URL) async {
        let key = dataRoot.standardizedFileURL.path
        guard running.insert(key).inserted else { pending.insert(key); return }
        defer {
            running.remove(key)
            if pending.remove(key) != nil { Task { await refresh(dataRoot: dataRoot) } }
        }
        guard let peers = try? AgentPeerStore(dataRoot: dataRoot).list(),
              let records = try? AgentConversationStore(dataRoot: dataRoot).recordsUnlocked() else { return }
        guard var previous = try? AgentLocalHealth.checkedRead(dataRoot) else { return }
        let iso = ISO8601DateFormatter()
        let probes: [(String, Probe)] = peers.map { peer in
            let key = "peer:" + peer.id
            if let door = AgentConversationDelivery.door(for: key, dataRoot: dataRoot), door.liveReader {
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
            let good = (history.flatMap { $0.exchanges ?? [] }.filter { $0.reply != nil }.map { $0.settledAt ?? $0.sentAt }
                + [peer?.roundTripProof?.at, peer?.mcpReturnProof?.at].compactMap { $0.flatMap(iso.date) }).max()
            let newest = history.max { $0.updatedAt < $1.updatedAt }
            let expired = newest.flatMap { row -> Date? in
                guard row.stop == nil, case .object(let receipt)? = row.receipt,
                      receipt["reply_state"] == .string("no_reply_expired"),
                      case .string(let stamp)? = receipt["reply_deadline"], let deadline = iso.date(from: stamp),
                      (good ?? .distantPast) < deadline else { return nil }
                return deadline
            }
            let failure = history.compactMap { row -> (AgentConversationRecord, Date)? in
                guard row.stop == nil, case .object(var receipt)? = row.receipt else { return nil }
                guard row.phase == "attention", !AgentConversationSession.awaitingApproval(row) else { return nil }
                if case .array(let jobs)? = receipt["jobs"], jobs.count == 1, case .object(let job) = jobs[0] { receipt = job }
                let status = receipt["status"].flatMap { if case .string(let s) = $0 { s } else { nil } } ?? ""
                return receipt["error"] != nil || receipt["execution_error"] != nil || ["failed", "unavailable"].contains(status)
                    || status == "outcome_unknown" && receipt["sent"] == .bool(false) ? (row, row.updatedAt) : nil
            }.filter { (good ?? .distantPast) < $0.1 }.min { $0.1 < $1.1 }
            // Our own relaunch cut the last send off: not broken, nothing to repair.
            let interrupted = newest.flatMap { row -> Date? in
                guard row.stop == nil, row.phase == "attention", case .object(let receipt)? = row.receipt,
                      receipt["status"] == .string("interrupted"), (good ?? .distantPast) < row.updatedAt else { return nil }
                return row.updatedAt
            }
            // A message that went and whose reply ended with its outcome unknown
            // stalled; the send path did not fail (Hermes 10-19: called broken,
            // its next message went fine).
            let stalled = newest.flatMap { row -> Date? in
                guard row.stop == nil, row.phase == "attention", case .object(let receipt)? = row.receipt,
                      receipt["status"] == .string("outcome_unknown"), receipt["sent"] != .bool(false) else { return nil }
                let at = row.exchanges?.last { $0.id == row.operationID }?.settledAt ?? row.updatedAt
                return (good ?? .distantPast) < at ? at : nil
            }
            let operation = failure?.0.operationID ?? (expired == nil ? nil : newest?.operationID)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions.insert(.withFractionalSeconds)
            // An inbound-only contact has no send path to be unavailable: a send
            // it refused is not a broken reply path (the transport lifts an older mark).
            let inboundOnly = peer.map { ChatGPTDotIPCTransport.owns($0) && ChatGPTDotIPCTransport.inboundOnly } == true
            let unavailable = inboundOnly ? nil : peer?.unavailableAt.flatMap(fractional.date)
            let broken = inboundOnly ? nil : ([failure?.1, unavailable]
                .compactMap { $0 }.filter { (good ?? .distantPast) < $0 }).min()
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
            let recipeChanged = (proof?.recipeVersion != nil || proof?.recipeDigest != nil)
                && (proof?.recipeVersion != recipe?.recipeVersion || proof?.recipeDigest != recipe?.hostDigest)
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
                    "Sends to \(peer.name) cannot be delivered: \(why) He can still reach her by running the local message command on this Mac (nativeagent-link message, with his contact file); a reply typed in his own chat no longer arrives. Last good send \(good.map(iso.string) ?? "never")."
                } else { nil }
                observed.detail = dotWords ?? broken.map {
                    "Reply path broken since \(iso.string(from: $0)); last good \(good.map(iso.string) ?? "never"). Open Connect for \(peer?.name ?? agent) and verify its reply path; do not resend the message."
                } ?? expired.map {
                    "No reply by the deadline \(iso.string(from: $0)); last good \(good.map(iso.string) ?? "never"). Open Connect for \(peer?.name ?? agent) and verify its reply path; do not resend the message."
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
                } else if let reason = operation ?? broken.map(iso.string), observed.repairFor != reason,
                   Date().timeIntervalSince(observed.repairAttemptedAt ?? .distantPast) >= 3600,
                   peer?.transport != .grokBot || grokVerifiers[key] != nil {
                    observed.repairFor = reason
                    observed.repairAttemptedAt = Date()
                    // The send already ran the repair: what it found, not a second run.
                    if case .object(let receipt)? = failure?.0.receipt, case .object(let repair)? = receipt["repair"],
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
            if let old = previous[agent], !old.sticky, old.lastGoodAt == good, Date().timeIntervalSince(old.checkedAt) < 300,
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
        for (agent, saved) in savedHealth where saved.repairFor == previous[agent]?.repairFor {
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
                    ? " An actual reply is still unproven; verify \(name) in Connect."
                    : " Fix its recipe with agent.recipe_write, or ask \(name)'s owner to restore its card, then verify in Connect.")
            } else if let peer, peer.transport == .nativeAgent {
                let result = try await AgentPeerDiscovery.resolve(peer.endpoint, bearerToken: AgentPeerCredentials.read(peerID: peer.id))
                detail = result.transport == peer.transport
                    ? "Connection check passed; an actual reply is still unproven. Verify \(name) in Connect."
                    : "Connection check failed. Ask \(name)'s owner to restore its advertised reply endpoint, then verify in Connect."
            } else {
                if probe == .dot { ChatGPTDotIPCTransport.reconnect() }
                let result = await inspect(probe)
                detail = "Readiness check: \(result.detail). " + (result.status == "ready" || result.status == "live"
                    ? "An actual reply is still unproven; verify \(name) in Connect."
                    : "Restore \(name)'s installation or sign-in, then verify in Connect.")
            }
        } catch {
            detail = peer?.transport == .grokBot
                ? String(error.localizedDescription.split(separator: "\n").first ?? "Routine verification failed.") + " Open Grok Bot's Routines and import the NativeAgent reply routine on Connect."
                : "Restore \(name)'s reply endpoint or sign-in, then verify in Connect."
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
        case unavailable(String)
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
        case .unavailable(let detail): return result("unavailable", detail)
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
            let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
            func present(_ value: JSONValue?) -> Bool {
                if case .string(let text)? = value { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                return false
            }
            guard let data = try? Data(contentsOf: home.appendingPathComponent("auth.json")),
                  case .object(let auth)? = try? JSONValue.parse(data) else { return result("signed_out", "Signed out — run codex login") }
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
