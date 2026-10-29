import AuthoredCapabilities
import AgentWorkspace
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
// Blueprint: | `AgentDiscoverySession.swift` | `AgentDiscoveryCandidate` presents observed routes; `AgentDiscoverySession` owns discovery lifetime and offers. Launch connects settings hosts from recipes without awaiting Spotlight; index arrivals wait for any in-flight scan, recipe-location watches reconcile after arming. Saved declines/disconnects win; running hosts get one restart note. Candidate/wake setup failures name files, fields and remedies, keep dismissible offers and clear on recovery. `app.installed` signals whole bundles at new id/version pairs after a silent installed-apps.json baseline. |

/// Session-only observations. These never write contacts, settings or credentials.
public struct AgentDiscoveryCandidate: Sendable, Equatable, Identifiable {
    public let name: String
    public let detail: String
    public var setupFailure: String?
    public let hostID: String?
    public let settingsPath: String?
    public let cardURL: URL?
    public let endpoint: URL?
    /// Each source that saw it, and where: "app: …", "path: …", "config: …",
    /// "process: …", "a2a: …", "acp: …", "entry: …", "initialize: …", "mcp: …".
    public var foundBy: [String] = []
    /// What it reports as its version (or when its program last changed).
    public var version: String?
    /// Connecting would find it too (`AgentHostRow.isInstalled`, or a card).
    public var connectable = true
    /// A lawful no that stopped its setup (`Repair.why`): the person's control, nothing owed.
    public var decision: JSONValue?
    /// The recipe a probe's find would have when no recipe knows it (`AgentPeerDiscovery.probe`).
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
                fields["setup"] = .string("agent_connect for \"\(row.displayName)\" creates a private environment file and returns the local commands to give Dot. Dot can message NativeAgent, and NativeAgent can message Dot in its current ChatGPT conversation after checking the running app and conversation.")
            }
            if row.route == .desktopChat {
                fields["setup"] = .string("agent_connect for \"\(row.displayName)\" sets this one up. Messages go to a chat of its own in the app, and the answer comes back in the same call.")
            }
            if let acp = row.acp {
                fields["setup"] = .string("Connect \(row.displayName) by name to review its executable and starting folder. It runs as you; this app asks only when the agent asks it.")
                fields["reference_version"] = .string(acp.referenceVersion)
            }
        }
        // The generic path for its protocol: its recipe written, then a connect by name.
        // Its name and version are what it said of itself, offered or not.
        if draft?.acp != nil { fields["untrusted_remote_data"] = .bool(true) }
        if let draft, setupFailure == nil {
            fields["setup"] = .string("No recipe knows it yet: agent.recipe_write {host: \"\(draft.id)\", recipe: recipe_draft}, then agent_connect for \"\(draft.id)\".")
            fields["recipe_draft"] = try? JSONValue.fromEncodable(AgentRecipeStore.Recipe(recipeVersion: 1, seededFrom: "discovery",
                updatedAt: "", source: "written", digest: "", host: draft))
        }
        if !connectable { fields["setup"] = nil; fields["description"] = .string(detail) }
        // Spotlight's miss, a card its own agent serves, or a settings file
        // Connect could not use: a correction to look at; his rule is his decision.
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

/// Agents, explicit discover, launch and installs refresh this cache; ordinary contact reads never discover.
/// Refresh connects settings hosts and offers other routes once through `AgentDiscoveryOffer`.
/// Only Agents and explicit discover probe; launch and installs keep their last finds.
public actor AgentDiscoverySession {
    public static let shared = AgentDiscoverySession()
    private var cached: [AgentDiscoveryCandidate]?
    private var probed: [AgentDiscoveryCandidate] = []
    private var pending: Task<[AgentDiscoveryCandidate], Never>?
    private var pendingID: UUID?
    private var pendingGeneration: UUID?
    /// How far the pending pass goes: 0 recipes, 1 the probes read, 2 found programs may run.
    private var pendingDepth = 0
    private var installs: Task<Void, Never>?
    private var locations: Task<Void, Never>?
    private var locationEvents: FileChangeEvents?
    private var locationPaths: [URL] = []
    private var installationReload: StoreReloadDebouncer?
    private var generation = UUID()
    private var observing = true

    /// The engine's resident owner closes observation before retiring its scan.
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
    /// Spotlight's own failure, said beside every scan until its index works again.
    private var indexFailure: AgentDiscoveryCandidate?

    public func candidates(refresh: Bool = false, probe: Bool = true, dataRoot: URL) async -> [AgentDiscoveryCandidate] {
        await candidates(refresh: refresh, probe: probe, launch: nil, dataRoot: dataRoot)
    }

    /// `launch`: an explicit discover's rule for running a found program
    /// (`AgentPeerDiscovery.Launch`); without it the probes only read.
    package func candidates(refresh: Bool, probe: Bool = true, launch: AgentPeerDiscovery.Launch?,
                            dataRoot: URL) async -> [AgentDiscoveryCandidate] {
        if !refresh { return cached ?? [] }
        guard observing, !Task.isCancelled else { return cached ?? [] }
        AgentHostRow.installationsChanged()
        // Recipes, programs and cards never wait on Spotlight.
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
        // A pass that goes as far as this one answers it; a shallower one is waited out, then this one runs.
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
            async let probing = probe ? AgentPeerDiscovery.probe(bundles, launch: launch) : nil
            let recipes = await AgentPeerDiscovery.scanLocal()
            let found = await probing
            guard self.generation == generation, !Task.isCancelled else { return cached ?? [] }
            if let found {
                // A read-only pass keeps what a find answered when it last ran.
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

    /// `app.installed`, delivery only: each bundle id at a version this Mac's
    /// scans have not seen, once the bundle is whole. The first scan records
    /// what is there silently. The name and path are plain data.
    private func arrived(_ bundles: [AgentPeerDiscovery.Bundle], dataRoot: URL) {
        let url = dataRoot.appendingPathComponent("agents/installed-apps.json")
        let baseline = FileManager.default.fileExists(atPath: url.path)
        guard var seen = baseline ? (try? JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: url))) : [] else {
            return nativeLog("AgentDiscoverySession: %@ does not read; no app arrivals until it is fixed or removed", url.path)
        }
        let before = seen
        for app in bundles {
            guard let id = app.bundleID, let info = app.info else { continue }
            if let sdef = info["OSAScriptingDefinition"] as? String,
               !FileManager.default.fileExists(atPath: app.url.appendingPathComponent("Contents/Resources/" + sdef).path) { continue }
            guard seen.insert(id + " " + app.version).inserted, baseline else { continue }
            guard case .object(let payload) = app.json else { continue }
            AbilityStore(dataRoot: dataRoot).signal("app.installed", payload)
        }
        guard seen != before || !baseline else { return }
        do { try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(seen), to: url) }
        catch { nativeLog("AgentDiscoverySession: could not keep installed apps: %@", error.localizedDescription) }
    }

    /// Register once; Spotlight's gathering and update edges own app arrivals.
    public func watchInstalls(dataRoot: URL) {
        guard installs == nil, !Task.isCancelled else { return }
        observing = true
        let generation = generation
        watchLocations(dataRoot: dataRoot)
        installs = Task {
            defer { if self.generation == generation { installs = nil } }
            do {
                for await _ in try await MacAppIndex.shared.changes() {
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
            // Registration is asynchronous; reconcile once after it to include
            // an installation that raced the scan which created this watcher.
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

    /// After agent_connect: a connection ends its offer in the same call.
    public func settle(dataRoot: URL) { offer(cached ?? [], dataRoot: dataRoot) }

    private static func key(_ id: String) -> String { "agent.found." + id }

    private func setupFailed(_ detail: String, for found: [AgentDiscoveryCandidate], dataRoot: URL) {
        let ids = Set(found.map(\.id))
        for index in (cached ?? []).indices where ids.contains(cached![index].id) {
            cached![index].setupFailure = detail
        }
        _ = ResidentWake.shared.request(dataRoot: dataRoot, reason: "agent connection setup failed", items: found.map {
            .init(id: "agent.setup." + $0.id, line: detail, key: "agent.setup." + $0.id, home: true)
        })
    }

    /// Settings hosts connect here; other routes are offered once. A person's
    /// decline or disconnect survives both discovery and program updates.
    private func offer(_ found: [AgentDiscoveryCandidate], dataRoot: URL) {
        do { try CredentialFileLock.withLock(AgentDiscoveryOffer.url(dataRoot)) {
            // Without the contacts nothing can be called unconnected.
            let peers = try AgentPeerStore(dataRoot: dataRoot).list()
            var hosts = Set(peers.compactMap { AgentPeerStore.hostRowID($0.endpoint) })
            // A saved settings-host contact whose key is definitely gone is
            // repaired on this same contact, like a new host is connected. An
            // unreadable Keychain is not a missing key: nothing is re-minted.
            let unkeyed = Set(peers.filter { peer in
                peer.transport == .mcpHost && peer.hostWorkspace == nil
                    && (peer.credentialKey == nil || (try? AgentPeerCredentials.read(peerID: peer.id)) == .some(nil))
            }.compactMap { AgentPeerStore.hostRowID($0.endpoint) })
            guard var offers = AgentDiscoveryOffer.read(dataRoot) else {
                throw AgentHostConfigWriter.Failure.unreadable("discovery decisions at \(AgentDiscoveryOffer.url(dataRoot).path)")
            }
            let before = offers, now = Date()
            var items: [ResidentWake.Item] = []
            for candidate in found {
                let row = AgentHostDirectory.rows.first { $0.id == candidate.hostID }
                // A workspace row needs a folder first; its app's own offer covers it.
                // A recipe connecting would not find is reported, never offered.
                guard row?.requiresWorkspace != true, candidate.connectable else { continue }
                var entry = offers[candidate.id] ?? AgentDiscoveryOffer(name: candidate.name)
                // A saved contact is not recovered while its own repair just failed.
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
                        // His own rule decided: said where, owed by no one.
                        if let index = cached?.firstIndex(where: { $0.id == candidate.id }) {
                            cached?[index].setupFailure = decided.message
                            cached?[index].decision = Repair.why(owner: decided.owner ?? row.expandedConfigPath, tap: decided.tap ?? decided.message)
                        }
                    } catch {
                        repairFailed = true
                        setupFailed("Connection failed: \(error.localizedDescription) Recipe agents/recipes/\(row.id).json: host.configPath=\(row.expandedConfigPath), host.format=\(row.format.rawValue). Read agent.recipe, fix the named field/file, then agent.verify and agent.connect.", for: [candidate], dataRoot: dataRoot)
                    }
                }
                if !repairFailed, candidate.hostID.map(hosts.contains)
                    ?? peers.contains(where: { $0.endpoint == candidate.cardURL || $0.endpoint == candidate.endpoint }) {
                    if let index = cached?.firstIndex(where: { $0.id == candidate.id }) {
                        cached?[index].setupFailure = nil
                        cached?[index].decision = nil
                    }
                    ResidentWake.shared.clear(dataRoot: dataRoot, key: "agent.setup." + candidate.id)
                    if entry.connectedAt == nil {
                        entry.connectedAt = now
                        ResidentWake.shared.withdraw(dataRoot: dataRoot, key: Self.key(candidate.id))
                        if let row, row.settingsSupported, row.restartRequired,
                           candidate.foundBy.contains(where: { $0.hasPrefix("process: ") }) {
                            items.append(.init(id: "agent.restart." + candidate.id,
                                line: "\(row.displayName): connector added. Restart: \(row.restartNote)",
                                key: "agent.restart." + candidate.id, home: true))
                        }
                    }
                } else if entry.connectedAt == nil, entry.declinedAt == nil, entry.offeredAt == nil {
                    entry.offeredAt = now; entry.version = candidate.version
                    let place = candidate.foundBy.joined(separator: "; ")
                    items.append(.init(id: Self.key(candidate.id) + ":" + (candidate.version ?? ""),
                        line: "Found \"\(candidate.name)\" on this Mac (\(place)), not connected. Connect: "
                            + (candidate.draft.map { _ in "agent.recipe_write with the recipe_draft agent.contacts {discover: \"\(candidate.name)\"} shows, then agent.connect" } ?? "agent.connect")
                            + "; not wanted: agent.discovery_dismiss.",
                        // A card names itself: that text carries an unidentified peer's
                        // provenance, so it waits for the wake and never lands in
                        // an untainted turn (ResidentWake.take).
                        key: Self.key(candidate.id), agent: candidate.hostID == nil ? "another agent" : nil))
                } else if entry.open {
                    entry.version = candidate.version
                } else { continue }
                offers[candidate.id] = entry
            }
            // An offer counts only once its wake is kept; otherwise the next pass offers it again.
            if !items.isEmpty, !ResidentWake.shared.request(dataRoot: dataRoot, reason: "an agent found on this Mac", items: items) {
                nativeLog("AgentDiscoverySession: the wake for %ld found agents was not kept; offering again next pass", items.count)
                for id in Array(offers.keys) where offers[id]?.offeredAt == now || offers[id]?.connectedAt == now { offers[id] = before[id] }
            }
            guard offers != before else { return }
            try AgentDiscoveryOffer.write(offers, dataRoot)
        } } catch {
            setupFailed("Agent discovery state failed: \(error.localizedDescription) Contacts: \(AgentPeerStore(dataRoot: dataRoot).fileURL.path); decisions: \(AgentDiscoveryOffer.url(dataRoot).path). Repair file validity and access, preserving saved declines and disconnects, then refresh Agents.", for: found, dataRoot: dataRoot)
        }
    }

    /// agent.discovery_dismiss: the person's or her "no", including after an update.
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
            ResidentWake.shared.withdraw(dataRoot: dataRoot, key: Self.key(id))
            return .object(["status": .string("declined"), "changed": .bool(true), "name": .string(offers[id]!.name),
                "detail": .string("Decline saved. This agent will not be offered or connected automatically again.")])
        } } catch { return failed("discovery_decision_save_failed", "Discovery decision save failed at \(file.path): \(error.localizedDescription). The decline may have been saved.", effects: "unknown") }
    }
}
