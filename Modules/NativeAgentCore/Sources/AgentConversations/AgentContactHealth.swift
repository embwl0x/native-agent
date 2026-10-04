import AgentWorkspace
import CoreServices
import Foundation
import MacControl
import NativeAgentCore
import PersistenceCore

/// Single flight per root; no prompts, handshakes or agent launches. The delegation
/// runner owns the five-minute deadline; list/home reads and new failures also ask.
public actor AgentContactHealth {
    public static let shared = AgentContactHealth()
    private var running: Set<String> = []
    private var pending: Set<String> = []
    private var appQueries: [Probe: UUID] = [:]
    private var appObservations: [Probe: (Bool, Date)] = [:]
    /// Programs whose probe is still running: a stuck one is never relaunched.
    private var commandsInFlight: Set<String> = []

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
        for (agent, probe) in probes {
            let failure = records.filter { $0.agent == agent && $0.phase == "attention" }.max { $0.updatedAt < $1.updatedAt }
            let operation = failure?.operationID
            // Dot's check is free and ChatGPT comes and goes (its launch, quit and
            // handshake each ask for a refresh): asked every time, the cached
            // word kept only while it still matches.
            let dot = probe == .dot ? await inspect(probe) : nil
            if let old = previous[agent], Date().timeIntervalSince(old.checkedAt) < 300, old.failureOperation == operation,
               dot.map({ $0.status == old.status && $0.detail == old.detail }) ?? true { continue }
            if Task.isCancelled { return }
            var observed: AgentLocalHealth
            if let kept = observations[probe] { observed = kept }
            else if let dot { observed = dot; observations[probe] = dot }
            else { observed = await inspect(probe); observations[probe] = observed }
            observed.failureOperation = operation
            if let old = previous[agent] { arrive(agent, from: old, to: observed, peers: peers, dataRoot: dataRoot) }
            previous[agent] = observed
            changed = true
        }
        guard changed else { return }
        let active = Set(probes.map(\.0))
        previous = previous.filter { active.contains($0.key) }
        do { try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(previous), to: AgentLocalHealth.url(dataRoot)) }
        catch { NSLog("AgentContactHealth: could not save local observations: %@", error.localizedDescription) }
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
        if peer.transport == .acp {
            guard let executable = peer.verifiedExecutablePath else { return .unavailable("Program missing or changed — reconnect") }
            return .command(host?.acp?.executable ?? URL(fileURLWithPath: executable).lastPathComponent, executable)
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
                    guard let urls = LSCopyApplicationURLsForBundleIdentifier(bundle as CFString, nil)?.takeRetainedValue() as? [URL] else { return false }
                    return urls.contains { FileManager.default.fileExists(atPath: $0.path) }
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
            guard let path else { return result("unavailable", "Program not installed — \(name)") }
            let args = name == "codex" ? ["login", "status"] : ["--version"]
            var environment = AgentHostCommandLines.scrubbedEnvironment().filter { ["PATH", "HOME"].contains($0.key) }
            environment["HOME"] = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
            environment["PATH"] = AgentBridgeRuntime.processEnvironment(base: environment)["PATH"]
            // Login directory, never provider keys or bridge credentials.
            if name == "codex" { environment["CODEX_HOME"] = ProcessInfo.processInfo.environment["CODEX_HOME"] }
            // Bound only this waiter. The detached adapter call keeps its own
            // lifecycle and can finish after a stuck probe's sweep moves on;
            // until it does, later sweeps report it rather than launch another.
            guard commandsInFlight.insert(path).inserted else { return result("unknown", "Health check timed out") }
            let query = Task.detached(priority: .utility) { [environment] in
                defer { Task { await self.commandFinished(path) } }
                return try await SystemProcessAdapter().run(executable: path, arguments: args,
                    currentDirectory: FileManager.default.homeDirectoryForCurrentUser, environment: environment,
                    standardInput: nil, timeoutSeconds: 4, outputByteLimit: 8192)
            }
            switch await raceAgainstTimeout(seconds: 5, { try await query.value }) {
            case .value(let output):
                if output.timedOut { return result("unknown", "Health check timed out") }
                if output.stdoutTruncated || output.stderrTruncated { return result("unknown", "Health check unavailable") }
                if name == "codex" {
                    let text = (output.stdout + "\n" + output.stderr).lowercased()
                    if text.contains("not logged in") { return result("signed_out", "Signed out — run codex login") }
                    if output.exitCode == 0, text.contains("logged in") { return result("ready", "Ready", authenticated: true) }
                } else if output.exitCode == 0 {
                    return result("ready", "Program available")
                }
                return result("unknown", "Health check unavailable")
            case .timedOut: return result("unknown", "Health check timed out")
            case .failure, .cancelled: return result("unknown", "Health check unavailable")
            }
        }
    }

    private func commandFinished(_ path: String) { commandsInFlight.remove(path) }

    private func keepAppObservation(_ observation: (Bool, Date), for probe: Probe, queryID: UUID) {
        guard appQueries[probe] == queryID else { return }
        appObservations[probe] = observation
    }

    private func appObservation(_ observation: (Bool, Date)) -> AgentLocalHealth {
        AgentLocalHealth(status: observation.0 ? "ready" : "unavailable",
            detail: observation.0 ? "App installed" : "App not installed", checkedAt: observation.1, authenticated: false)
    }
}
