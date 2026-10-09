import AgentWorkspace
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

    public func installGrokVerifier(dataRoot: URL, verify: @escaping @Sendable (String) async throws -> Void) async {
        grokVerifiers[dataRoot.standardizedFileURL.path] = verify
        await refresh(dataRoot: dataRoot)
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
        var previous = AgentLocalHealth.read(dataRoot)
        // Claude lives in her own session (Claude Code, Claude Desktop), not a
        // program this app runs: she is live when she spoke over the bridge
        // (agent_message, agent_reply) or marked a message read in her inbox in
        // the last 30 minutes, or her session touched `claude-live` beside that
        // inbox in the last 10 (it does every few minutes while it watches).
        let identity = AgentContactIdentity(dataRoot: dataRoot)
        let claude = peers.filter { identity.canonical("peer:" + $0.id) == "claude" }
        let iso = ISO8601DateFormatter()
        let spoke = claude.compactMap { $0.provenInboundAt.flatMap(iso.date) }
            + ContactReplyReads.read(dataRoot).filter { read in
                claude.contains { read.session.hasPrefix(ContactThread.prefix(owner: $0.id)) }
            }.map(\.at)
        let inbox = AgentConversationDelivery.inbox(agent: "claude", bridgeConfigRoot: InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot))
        let beat = inbox.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.deletingLastPathComponent()
            .appendingPathComponent("claude-live").path)[.modificationDate] as? Date }
        let live = (spoke + (inbox.map(Self.reads) ?? [])).contains { Date().timeIntervalSince($0) < 1800 }
            || beat.map { Date().timeIntervalSince($0) < 600 } == true
        let bridge = Probe.bridge(live: live)
        var probes: [(String, Probe)] = peers.map { ("peer:" + $0.id, claude.contains($0) ? bridge : probe($0)) }
        if !claude.isEmpty || records.contains(where: { $0.agent == "claude" }) { probes.append(("claude", bridge)) }
        for (lane, binary) in [("codex", "codex"), ("omp", "omp")] {
            if AgentHostCommandLines.resolveExecutable(binary) != nil || records.contains(where: { $0.agent == lane }) {
                probes.append((lane, .command(binary, AgentHostCommandLines.resolveExecutable(binary))))
            }
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
                return receipt["error"] != nil || receipt["execution_error"] != nil
                    || ["failed", "unavailable", "outcome_unknown"].contains(
                        receipt["status"].flatMap { if case .string(let s) = $0 { s } else { nil } } ?? "") ? (row, row.updatedAt) : nil
            }.filter { (good ?? .distantPast) < $0.1 }.min { $0.1 < $1.1 }
            let operation = failure?.0.operationID ?? (expired == nil ? nil : newest?.operationID)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions.insert(.withFractionalSeconds)
            let unavailable = peer?.unavailableAt.flatMap(fractional.date)
            let broken = ([failure?.1, unavailable]
                .compactMap { $0 }.filter { (good ?? .distantPast) < $0 }).min()
            let proof = peer?.roundTripProof ?? peer?.mcpReturnProof
            let appVersion = peer?.appBundleIDs.compactMap(AgentHostRow.applicationURL).first
                .flatMap { AgentPeerContact.appVersion(at: $0.path) }
            let unverified = (peer?.transport == .desktopChat && (proof?.appVersion == nil || appVersion == nil))
                || (peer?.appBundleIDs.isEmpty == false && proof?.appVersion.map { $0 != appVersion } == true)
            if broken != nil || expired != nil || unverified {
                var observed = previous[agent] ?? AgentLocalHealth(status: "broken", detail: "", checkedAt: Date(), authenticated: false)
                observed.status = broken != nil ? "broken" : (expired != nil ? "no_reply_by_deadline" : "unverified")
                observed.brokenSince = broken
                observed.lastGoodAt = good
                observed.failureOperation = operation
                observed.detail = broken.map {
                    "Reply path broken since \(iso.string(from: $0)); last good \(good.map(iso.string) ?? "never"). Open Connect for \(peer?.name ?? agent) and verify its reply path; do not resend the message."
                } ?? expired.map {
                    "No reply by the deadline \(iso.string(from: $0)); last good \(good.map(iso.string) ?? "never"). Open Connect for \(peer?.name ?? agent) and verify its reply path; do not resend the message."
                } ?? "App version \(appVersion ?? "unknown") is unverified; last proven version \(proof?.appVersion ?? "unknown"). Verify \(peer?.name ?? agent) in Connect before trusting its reply path."
                let reason = operation ?? broken.map(iso.string) ?? "app:\(appVersion ?? "unknown")"
                if observed.repairFor != reason,
                   Date().timeIntervalSince(observed.repairAttemptedAt ?? .distantPast) >= 3600,
                   peer?.transport != .grokBot || grokVerifiers[key] != nil {
                    observed.repairFor = reason
                    observed.repairAttemptedAt = Date()
                    observed.repairDetail = "Checking the reply path; no message will be resent."
                    repairs.append((agent, probe, peer, reason))
                }
                guard observed != previous[agent] else { continue }
                observed.checkedAt = Date()
                previous[agent] = observed
                changed = true
                continue
            }
            // Dot's check is free (his listener's live state, which asks for a
            // refresh on every change): asked every time, the cached word kept
            // only while it still matches.
            let dot = probe == .dot ? await inspect(probe) : nil
            if let old = previous[agent], old.brokenSince == nil, old.status != "unverified", old.lastGoodAt == good, Date().timeIntervalSince(old.checkedAt) < 300, old.failureOperation == operation,
               dot.map({ $0.status == old.status && $0.detail == old.detail }) ?? true { continue }
            if Task.isCancelled { return }
            var observed: AgentLocalHealth
            if let kept = observations[probe] { observed = kept }
            else if let dot { observed = dot; observations[probe] = dot }
            else { observed = await inspect(probe); observations[probe] = observed }
            observed.failureOperation = operation
            observed.lastGoodAt = good
            observed.repairAttemptedAt = previous[agent]?.repairAttemptedAt
            observed.repairFor = previous[agent]?.repairFor
            if let old = previous[agent] { arrive(agent, from: old, to: observed, peers: peers, dataRoot: dataRoot) }
            previous[agent] = observed
            changed = true
        }
        guard changed else { return }
        let active = Set(probes.map(\.0))
        previous = previous.filter { active.contains($0.key) }
        for (agent, saved) in AgentLocalHealth.read(dataRoot) where saved.repairFor == previous[agent]?.repairFor {
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
            } else if let peer, [.a2a, .nativeAgent].contains(peer.transport) {
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
        var health = AgentLocalHealth.read(dataRoot)
        guard health[agent]?.repairFor == operation, health[agent]?.brokenSince != nil || ["unverified", "no_reply_by_deadline"].contains(health[agent]?.status ?? "") else { return }
        health[agent]?.repairDetail = detail
        do { try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(health), to: AgentLocalHealth.url(dataRoot)) }
        catch { nativeLog("AgentContactHealth: could not save verification: %@", error.localizedDescription) }
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
        } else if problems.contains(old.status), new.status == "ready",
                  !ResidentWake.shared.withdraw(dataRoot: dataRoot, key: key) {
            ResidentWake.shared.request(dataRoot: dataRoot, reason: "what resolved", items: [.init(
                id: key + ":ready:" + stamp, line: name + " is back: " + new.detail, key: key, thread: key, home: true, hold: 60)])
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

    /// When her inbox's newest messages were marked read (`readAt`), from its last 64 KB.
    private static func reads(_ inbox: URL) -> [Date] {
        guard let handle = try? FileHandle(forReadingFrom: inbox) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return text.components(separatedBy: "\"readAt\":\"").dropFirst()
            .compactMap { $0.split(separator: "\"", maxSplits: 1).first.flatMap { iso.date(from: String($0)) } }
    }

    private func probe(_ peer: AgentPeerContact) -> Probe {
        // Dot answers only through the ChatGPT app's IPC follower, not because the app is installed.
        if ChatGPTDotIPCTransport.owns(peer) { return .dot }
        let host = AgentPeerStore.hostRowID(peer.endpoint).flatMap { AgentHostDirectory.row(named: $0) }
        // The program installed now: a launch follows its updates (hostACPRun,
        // drivenAgentLaunch), so an update is not a problem.
        if let executable = host?.acp?.executable {
            return .command(executable, AgentHostCommandLines.resolveExecutable(executable))
        }
        if let line = host?.commandLine {
            return .command(line.executable, AgentHostCommandLines.resolveExecutable(line.executable))
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
            return live ? result("live", "Live") : result("waiting", "Messages wait for Claude's next session")
        case .dot:
            // Offline, not unavailable: the ChatGPT app closing is not news to wake her for.
            if ChatGPTDotIPCTransport.available { return result("ready", "Ready") }
            if case .object(let fields) = ChatGPTDotIPCTransport.readiness, fields["status"] == .string("not_checked") {
                return result("unchecked", ChatGPTDotIPCTransport.detail)
            }
            return result("offline", ChatGPTDotIPCTransport.detail)
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
