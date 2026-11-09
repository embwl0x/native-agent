import AuthoredCapabilities
import AgentWorkspace
import Experiences
import Foundation
import NativeAgentShared
import MacControl
import NativeAgentCore
import PersistenceCore
import ChatTurnContracts
import ChatToolParsing
import ApprovalInbox
import StandingBots
import TurnTrace
import CryptoKit
import AgentLinkTransport
import os
// Blueprint: | `AgentDiscoverySession.swift` | `AgentDiscoveryCandidate`, `AgentDiscoverySession`, `app.installed` |

/// Discovery observations must not write contacts, settings or credentials.
public struct AgentDiscoveryCandidate: Sendable, Equatable, Identifiable {
    public let name: String
    public let detail: String
    public var setupFailure: String?
    public let hostID: String?
    public let settingsPath: String?
    public let cardURL: URL?
    public let endpoint: URL?
    public var foundBy: [String] = []
    public var version: String?
    public var connectable = true
    /// A policy refusal belongs to the person’s control, not repair debt.
    public var decision: JSONValue?
    public var draft: AgentHostRow?
    public init(name: String, detail: String, hostID: String?, settingsPath: String?, cardURL: URL?, endpoint: URL?) {
        self.name = name
        self.detail = detail
        self.hostID = hostID
        self.settingsPath = settingsPath
        self.cardURL = cardURL
        self.endpoint = endpoint
    }
    public var id: String { hostID ?? draft?.id ?? cardURL!.absoluteString }

    package var projection: JSONValue {
        var fields: [String: JSONValue] = [
            "name": .string(name), "description": .string(detail),
            "kind": .string(hostID != nil ? "agent_host" : draft?.acp != nil ? "acp_agent" : draft != nil ? "mcp_host" : "a2a_agent"),
            "state": .string(AgentPeerContactState.listed.rawValue),
            "state_detail": .string(AgentPeerContactState.listed.detail),
            "capabilities": .array([]), "read_inputs": .array([]), "found_by": .array(foundBy.map(JSONValue.string))]
        let row = AgentHostDirectory.rows.first { $0.id == hostID }
        if row?.settingsSupported != false, let settingsPath, !settingsPath.isEmpty {
            fields["settings_file"] = .string(settingsPath)
            let workspace = row?.requiresWorkspace == true
            fields["setup"] = .string("agent_connect for \"\(name)\""
                + (workspace ? " with workspace set to the folder the person chose." : " sets this one up."))
        }
        if let hostID, let row = AgentHostDirectory.row(named: hostID) {
            fields["route"] = .string(row.route.rawValue)
            // Seeing an installed host does not prove a usable connection.
            fields["can_start_turn"] = .bool(false)
            fields["can_answer_back"] = .bool(false)
            if row.format == .shellEnvironment {
                fields["description"] = .string(row.description)
                fields["outbound_route"] = .string("none")
                fields["setup"] = .string("""
                    agent_connect for \"\(row.displayName)\" creates a private environment file and returns the local commands to give Dot. Dot can \
                    message NativeAgent, and NativeAgent can message Dot in its current ChatGPT conversation after checking the running app and \
                    conversation.
                    """)
            }
            if row.route == .desktopChat {
                fields["setup"] = .string("""
                    agent_connect for \"\(row.displayName)\" sets this one up. Messages go to a chat of its own in the app, and the answer comes \
                    back in the same call.
                    """)
            }
            if let acp = row.acp {
                fields["setup"] = .string("""
                    Connect \(row.displayName) by name to review its executable and starting folder. It runs as you; this app asks only when the \
                    agent asks it.
                    """)
                fields["reference_version"] = .string(acp.referenceVersion)
            }
        }
        // Report the peer’s own name and version as evidence, independent of whether its route is offered.
        if draft?.acp != nil { fields["untrusted_remote_data"] = .bool(true) }
        if let draft, setupFailure == nil {
            fields["setup"] = .string(
                "No recipe knows it yet: agent.recipe_write {host: \"\(draft.id)\", recipe: recipe_draft}, then agent_connect for \"\(draft.id)\".")
            fields["recipe_draft"] = try? JSONValue.fromEncodable(AgentRecipeStore.Recipe(recipeVersion: 1, seededFrom: "discovery",
                updatedAt: "", source: "written", digest: "", host: draft))
        }
        if !connectable { fields["setup"] = nil; fields["description"] = .string(detail) }
        // Separate correctable discovery evidence from the person’s policy decisions.
        if let decision { fields["remedy"] = decision }
        else if let setupFailure {
            let verify = hostID != nil && hostID != "app-index"
            fields["remedy"] = .object(["kind": .string("inspect"),
                "instruction": .string("Discovery could not use \(settingsPath ?? cardURL?.absoluteString ?? name): \(setupFailure)"),
                "next_call": .object(["tool": .string("app"), "input": .object(verify
                    ? ["action": .string("agent.verify"), "args": .object(["agent": .string(hostID!)])]
                    : ["action": .string("agent.contacts"), "args": .object(["discover": .bool(true)])])])])
        }
        if let cardURL, let endpoint {
            fields["endpoint"] = .string(endpoint.absoluteString)
            fields["card_url"] = .string(cardURL.absoluteString)
            fields["transport"] = .string("a2a")
            fields["untrusted_remote_data"] = .bool(true)
            fields["setup"] = .string("Use agent_connect with this name and the card_url as endpoint. A connection may need its own key.")
        }
        if let setupFailure { fields["description"] = .string(setupFailure) }
        return .object(fields)
    }
}

/// Ordinary contact reads never discover; only explicit discovery and the Agents view probe programs. Launch and install refreshes retain probe findings while
/// connecting settings hosts and offering other routes once.
public actor AgentDiscoverySession {
    public static let shared = AgentDiscoverySession()
    private var cached: [AgentDiscoveryCandidate]?
    private var probed: [AgentDiscoveryCandidate] = []
    private var pending: Task<[AgentDiscoveryCandidate], Never>?
    private var pendingID: UUID?
    private var pendingGeneration: UUID?
    private var pendingDepth = 0
    private var installs: Task<Void, Never>?
    private var locations: Task<Void, Never>?
    private var locationEvents: FileChangeEvents?
    private var locationPaths: [URL] = []
    private var installationReload: StoreReloadDebouncer?
    private var generation = UUID()
    private var observing = true

    /// Close observation before retiring the resident scan.
    public func stop() {
        observing = false
        generation = UUID()
        installs?.cancel(); installs = nil
        locations?.cancel(); locations = nil
        locationEvents?.cancel(); locationEvents = nil
        locationPaths = []
        if let installationReload { Task { await installationReload.cancel() } }
        installationReload = nil
        pending?.cancel() // Keep exclusion until the scan actually exits.
    }
    /// Keep Spotlight failures visible until its index works again.
    private var indexFailure: AgentDiscoveryCandidate?

    public func candidates(refresh: Bool = false, probe: Bool = true, dataRoot: URL) async -> [AgentDiscoveryCandidate] {
        await candidates(refresh: refresh, probe: probe, launch: nil, dataRoot: dataRoot)
    }

    /// Without explicit launch admission, discovery probes may only read.
    package func candidates(refresh: Bool, probe: Bool = true, launch: AgentPeerDiscovery.Launch?,
                            dataRoot: URL) async -> [AgentDiscoveryCandidate] {
        if !refresh { return cached ?? [] }
        guard observing, !Task.isCancelled else { return cached ?? [] }
        AgentHostRow.installationsChanged()
        // Spotlight must not delay recipe, program or card discovery.
        return await discover(MacAppIndex.shared.readyApps() ?? [], probe: probe, launch: launch, dataRoot: dataRoot)
    }

    private func indexFailed(_ error: Error?) {
        indexFailure = error.map {
            var failed = AgentDiscoveryCandidate(name: "Installed apps (Spotlight)", detail: $0.localizedDescription,
                hostID: "app-index", settingsPath: nil, cardURL: nil, endpoint: nil)
            failed.connectable = false
            failed.setupFailure = $0.localizedDescription
            return failed
        }
        cached = (cached ?? []).filter { $0.id != "app-index" } + [indexFailure].compactMap { $0 }
    }

    private func discover(_ bundles: [AgentPeerDiscovery.Bundle], probe: Bool = false, launch: AgentPeerDiscovery.Launch? = nil,
                          dataRoot: URL) async -> [AgentDiscoveryCandidate] {
        // Join a pending pass only if its depth satisfies this request; otherwise run after it finishes.
        let depth: Int = if !probe { 0 } else if case .run? = launch { 2 } else { 1 }
        let generation = generation
        while let pending {
            if pendingDepth >= depth, pendingGeneration == generation { return await pending.value }
            _ = await pending.value
            guard self.generation == generation, !Task.isCancelled else { return cached ?? [] }
        }
        guard !Task.isCancelled else { return cached ?? [] }
        let id = UUID()
        let task = Task {
            defer {
                if pendingID == id { pending = nil; pendingID = nil; pendingGeneration = nil }
            }
            nativeLog("AgentDiscoverySession: discovery scan started")
            async let probing = probe ? AgentPeerDiscovery.probe(bundles, launch: launch, dataRoot: dataRoot) : nil
            let recipes = await AgentPeerDiscovery.scanLocal()
            let found = await probing
            guard self.generation == generation, !Task.isCancelled else { return cached ?? [] }
            if let found {
                // Read-only passes retain the evidence from the last executed probe.
                probed = found.map { new in
                    guard launch == nil, let ran = probed.first(where: { $0.id == new.id
                        && $0.foundBy.contains { $0.hasPrefix("initialize:") || $0.hasPrefix("entry:") } }) else { return new }
                    return ran
                }
            }
            let result = AgentPeerDiscovery.merged(recipes + probed)
            nativeLog("AgentDiscoverySession: discovery scan finished")
            cached = result + [indexFailure].compactMap { $0 }
            watchLocations(dataRoot: dataRoot)
            offer(result, dataRoot: dataRoot)
            return cached ?? result
        }
        pending = task
        pendingID = id
        pendingGeneration = generation
        pendingDepth = depth
        return await task.value
    }

    /// Each whole installed bundle version is one world happening and the parts' `app.installed` signal; the first scan establishes a silent baseline.
    private func arrived(_ bundles: [AgentPeerDiscovery.Bundle], dataRoot: URL) {
        let url = dataRoot.appendingPathComponent("agents/installed-apps.json")
        let baseline = FileManager.default.fileExists(atPath: url.path)
        guard var seen = baseline ? (try? JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: url))) : [] else {
            return nativeLog("AgentDiscoverySession: %@ does not read; no app arrivals until it is fixed or removed", url.path)
        }
        let before = seen
        for app in MacAppIndex.installed(bundles) {
            guard let id = app.bundleID, let info = app.info else { continue }
            if let sdef = info["OSAScriptingDefinition"] as? String,
               !FileManager.default.fileExists(atPath: app.url.appendingPathComponent("Contents/Resources/" + sdef).path) { continue }
            guard seen.insert(id + " " + app.version).inserted, baseline else { continue }
            if case .object(let payload) = app.json { AbilityStore(dataRoot: dataRoot).signal("app.installed", payload) }
            Attention.post(Happening(.world, subject: "app:" + id, door: "mac:installed",
                words: app.name + " " + app.version + " arrived on this Mac" + (app.scriptable == true ? "; it can be scripted." : "."),
                once: "app.installed:" + id + ":" + app.version, signal: "app.installed"), dataRoot: dataRoot)
        }
        guard seen != before || !baseline else { return }
        do { try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(seen), to: url) }
        catch { nativeLog("AgentDiscoverySession: could not keep installed apps: %@", error.localizedDescription) }
    }

    /// Spotlight gathering and update edges own arrivals; register once.
    public func watchInstalls(dataRoot: URL) {
        guard installs == nil, !Task.isCancelled else { return }
        observing = true
        let generation = generation
        watchLocations(dataRoot: dataRoot)
        installs = Task {
            defer { if self.generation == generation { installs = nil } }
            do {
                for await _ in try await MacAppIndex.shared.changes(context: MacOperationContext(dataRoot: dataRoot)) {
                    guard self.generation == generation, !Task.isCancelled else { return }
                    let bundles = try await AgentPeerDiscovery.bundles()
                    guard self.generation == generation, !Task.isCancelled else { return }
                    indexFailed(nil)
                    arrived(bundles, dataRoot: dataRoot)
                    await scheduleInstallationsChanged(dataRoot: dataRoot)
                }
            } catch {
                guard self.generation == generation, !Task.isCancelled else { return }
                indexFailed(error)
            }
        }
    }

    private func watchLocations(dataRoot: URL) {
        let paths = AgentHostDirectory.rows.flatMap { $0.installation.locations }
        guard locations == nil || locationPaths != paths else { return }
        locations?.cancel()
        locationEvents?.cancel()
        locationPaths = paths
        let generation = generation
        let events = FileChangeEvents(paths: paths, emitInitial: false)
        locationEvents = events
        locations = Task {
            defer { events.cancel() }
            // Registration is asynchronous; reconcile once after it to include an installation that raced the scan which created this watcher.
            await events.waitUntilArmed()
            if self.generation == generation, !Task.isCancelled {
                await scheduleInstallationsChanged(dataRoot: dataRoot)
            }
            for await _ in events.stream {
                guard self.generation == generation, !Task.isCancelled else { return }
                await scheduleInstallationsChanged(dataRoot: dataRoot)
            }
        }
    }

    private func scheduleInstallationsChanged(dataRoot: URL) async {
        guard observing, !Task.isCancelled else { return }
        if installationReload == nil {
            installationReload = StoreReloadDebouncer(delay: .milliseconds(250)) { [weak self] in
                await self?.installationsChanged(dataRoot: dataRoot)
            }
        }
        await installationReload?.setVisible(true)
        await installationReload?.signal()
    }

    private func installationsChanged(dataRoot: URL) async {
        let generation = generation
        if let pending { _ = await pending.value }
        guard observing, self.generation == generation, !Task.isCancelled, AgentHostRow.refreshInstallations() else { return }
        watchLocations(dataRoot: dataRoot)
        _ = await discover(MacAppIndex.shared.readyApps() ?? [], dataRoot: dataRoot)
    }

    /// Successful connection ends its offer in the same call.
    public func settle(dataRoot: URL) { offer(cached ?? [], dataRoot: dataRoot) }

    private func setupFailed(_ detail: String, for found: [AgentDiscoveryCandidate], dataRoot: URL) {
        let ids = Set(found.map(\.id))
        for index in (cached ?? []).indices where ids.contains(cached![index].id) {
            cached![index].setupFailure = detail
        }
        // The same failure of the same agent is one happening; a different failure is a new one.
        let failure = SHA256.hash(data: Data(detail.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        for candidate in found {
            Attention.post(Happening(.body, subject: "agent:" + candidate.id, door: "agents:discovery", who: "self", words: detail,
                once: "agent.setup:" + candidate.id + ":" + failure), dataRoot: dataRoot)
        }
    }

    /// Decline and disconnect survive discovery and program updates.
    private func offer(_ found: [AgentDiscoveryCandidate], dataRoot: URL) {
        do { try CredentialFileLock.withLock(AgentDiscoveryOffer.url(dataRoot)) {
            // Without a checked contact list, absence cannot establish an unconnected host.
            let peers = try AgentPeerStore(dataRoot: dataRoot).list()
            var hosts = Set(peers.compactMap { AgentPeerStore.hostRowID($0.endpoint) })
            // Remint only definitely missing settings-host keys; unreadable Keychain evidence cannot prove absence.
            let unkeyed = Set(peers.filter { peer in
                peer.transport == .mcpHost && peer.hostWorkspace == nil
                    && (peer.credentialKey == nil || (try? AgentPeerCredentials.read(peerID: peer.id)) == .some(nil))
            }.compactMap { AgentPeerStore.hostRowID($0.endpoint) })
            guard var offers = AgentDiscoveryOffer.read(dataRoot) else {
                throw AgentHostConfigWriter.Failure.unreadable("discovery decisions at \(AgentDiscoveryOffer.url(dataRoot).path)")
            }
            let before = offers, now = Date()
            var told: [Happening] = []
            for candidate in found {
                let row = AgentHostDirectory.rows.first { $0.id == candidate.hostID }
                // Workspace rows need an explicitly selected folder; offer only recipes that connecting can actually find.
                guard row?.requiresWorkspace != true, candidate.connectable else { continue }
                var entry = offers[candidate.id] ?? AgentDiscoveryOffer(name: candidate.name)
                // Do not recover a saved contact while its owning repair has just failed.
                var repairFailed = false
                if let row, row.settingsSupported, row.acp == nil, row.format != .sessionMCP, entry.declinedAt == nil,
                   unkeyed.contains(row.id) || (!hosts.contains(row.id) && entry.connectedAt == nil) {
                    do {
                        let store = AgentPeerStore(dataRoot: dataRoot)
                        let proposal = try AgentHostConnection.propose(name: row.id, store: store, dataRoot: dataRoot)
                        _ = try AgentHostConnection.connect(proposal: proposal, store: store)
                        hosts.insert(row.id)
                    } catch let decided as ToolFailureError where decided.personDecides {
                        repairFailed = true
                        // A policy refusal establishes no repair debt.
                        if let index = cached?.firstIndex(where: { $0.id == candidate.id }) {
                            cached?[index].setupFailure = decided.message
                            cached?[index].decision = Repair.why(owner: decided.owner ?? row.expandedConfigPath, tap: decided.tap ?? decided.message)
                        }
                    } catch {
                        repairFailed = true
                        setupFailed("""
                            Connection failed: \(error.localizedDescription) Recipe agents/recipes/\(row.id).json: \
                            host.configPath=\(row.expandedConfigPath), host.format=\(row.format.rawValue). Read agent.recipe, fix the named \
                            field/file, then agent.verify and agent.connect.
                            """, for: [candidate], dataRoot: dataRoot)
                    }
                }
                if !repairFailed, candidate.hostID.map(hosts.contains)
                    ?? peers.contains(where: { $0.endpoint == candidate.cardURL || $0.endpoint == candidate.endpoint }) {
                    if let index = cached?.firstIndex(where: { $0.id == candidate.id }) {
                        cached?[index].setupFailure = nil
                        cached?[index].decision = nil
                    }
                    if entry.connectedAt == nil {
                        entry.connectedAt = now
                        if let row, row.settingsSupported, row.restartRequired,
                           candidate.foundBy.contains(where: { $0.hasPrefix("process: ") }) {
                            told.append(Happening(.body, subject: "agent:" + candidate.id, door: "agents:discovery", who: "self",
                                words: "\(row.displayName): connector added. Restart: \(row.restartNote)",
                                once: "agent.restart:" + candidate.id + ":" + (candidate.version ?? "")))
                        }
                    }
                } else if entry.connectedAt == nil, entry.declinedAt == nil, entry.offeredAt == nil {
                    entry.offeredAt = now; entry.version = candidate.version
                    let place = candidate.foundBy.joined(separator: "; ")
                    told.append(Happening(.body, subject: "agent:" + candidate.id, door: "agents:discovery", who: "self",
                        words: "Found \"\(candidate.name)\" on this Mac (\(place)), not connected. Connect: "
                            + (candidate.draft.map { _ in """
                                agent.recipe_write with the recipe_draft agent.contacts {discover: \"\(candidate.name)\"} shows, then agent.connect
                                """ } ?? "agent.connect")
                            + "; not wanted: agent.discovery_dismiss.",
                        once: "agent.found:" + candidate.id + ":" + (candidate.version ?? ""),
                        // Peer-authored card text keeps unidentified-peer provenance: the thought that reads it is steered by that peer.
                        peers: candidate.hostID == nil ? ["another agent"] : nil))
                } else if entry.open {
                    entry.version = candidate.version
                } else { continue }
                offers[candidate.id] = entry
            }
            // Told only once the decisions are saved: a failed save tells its failure, and the next pass offers again under the same keys.
            if offers != before { try AgentDiscoveryOffer.write(offers, dataRoot) }
            for happening in told { Attention.post(happening, dataRoot: dataRoot) }
        } } catch {
            setupFailed("""
                Agent discovery state failed: \(error.localizedDescription) Contacts: \(AgentPeerStore(dataRoot: dataRoot).fileURL.path); \
                decisions: \(AgentDiscoveryOffer.url(dataRoot).path). Repair file validity and access, preserving saved declines and disconnects, \
                then refresh Agents.
                """, for: found, dataRoot: dataRoot)
        }
    }

    /// A dismissal survives program updates.
    public func dismiss(name: String, dataRoot: URL) -> JSONValue {
        let file = AgentDiscoveryOffer.url(dataRoot)
        func failed(_ reason: String, _ detail: String, effects: String) -> JSONValue {
            .object(["status": .string("failed"), "reason": .string(reason),
                "changed": effects == "none" ? .bool(false) : .null, "effects": .string(effects), "detail": .string(detail),
                "remedy": Repair.remedy(owner: file.path,
                    nextCall: nil, tap: nil,
                    instruction: ToolFailureError.fileRepairInstruction(file,
                        shape: "Preserve every saved discovery decline and disconnect in the discovery-decision object.")
                        + " Repair the file without discarding saved declines or disconnects; inspect the saved decision before declining again.")])
        }
        do { return try CredentialFileLock.withLock(AgentDiscoveryOffer.url(dataRoot)) {
            guard var offers = AgentDiscoveryOffer.read(dataRoot) else {
                return failed("discovery_decisions_unreadable", "\(file.path) is unreadable; no decline was saved.", effects: "none")
            }
            let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
            func named(_ id: String, _ offer: AgentDiscoveryOffer) -> Bool {
                offer.open && [id, offer.name].contains { $0.caseInsensitiveCompare(wanted) == .orderedSame }
            }
            guard let id = offers.keys.sorted().first(where: { named($0, offers[$0]!) }) else {
                return .object(["status": .string("not_found"), "reason": .string("discovery_offer_not_found"),
                    "changed": .bool(false), "effects": .string("none"),
                    "detail": .string("No open discovery offer is named \"\(wanted)\"."),
                    "remedy": .object(["kind": .string("correct_arguments"),
                        "instruction": .string("Read Home's PEOPLE lines and use an open offer's exact name."),
                        "next_call": .object(["tool": .string("app"), "input": .object([:])])])])
            }
            offers[id]?.declinedAt = Date()
            try AgentDiscoveryOffer.write(offers, dataRoot)
            return .object(["status": .string("declined"), "changed": .bool(true), "name": .string(offers[id]!.name),
                "detail": .string("Decline saved. This agent will not be offered or connected automatically again.")])
        } } catch { return failed("discovery_decision_save_failed",
            "Discovery decision save failed at \(file.path): \(error.localizedDescription). The decline may have been saved.", effects: "unknown") }
    }
}
