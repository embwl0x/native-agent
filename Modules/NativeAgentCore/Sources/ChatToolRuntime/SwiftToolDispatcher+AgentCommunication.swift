import AgentWorkspace
import AuthoredCapabilities
#if canImport(AppKit)
import AppKit
#endif
import Foundation
import NativeAgentShared
import TrustCenter
import ApprovalInbox
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import StandingBots
import ProviderRouting
// Blueprint: | `SwiftToolDispatcher+AgentCommunication.swift` | `SwiftToolDispatcher`: `closeACPConnections`, `builtInAgentLaneUsable`, `impl_agentCommunication`; command settlement joins its output consumer before reading replies and releasing its directory/probe; physical launch, exit success and proven delivery remain separate, launched unanswered commands retain unknown delivery |
extension SwiftToolDispatcher {
    public static func closeACPConnections() async { await AgentACPConnections.shared.closeAll() }
    static func builtInAgentLaneUsable(_ name: String, dataRoot: URL, configRoot: URL?) -> Bool {
        AgentConversationDelivery.lane(for: name, dataRoot: dataRoot, bridgeConfigRoot: configRoot) != nil
    }
    func impl_agentCommunication(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        let optional: Set<String> = ["endpoint", "app_bundle_id", "conversation_label", "transport", "bearer_token", "conversation_id", "message_id", "task_id", "options", "limit", "offset", "max_chars", "details", "disconnect", "ability"]
        let args = input.filter {
            if ["session_id", "__session_id"].contains($0.key) { return false }
            if tool == "agent_message", $0.key == "dry_run" { return false }
            if optional.contains($0.key), $0.value == .string("") { return false }
            // False means the caller is not disconnecting.
            if $0.key == "disconnect", $0.value == .bool(false) { return false }
            if $0.key == "options", case .object(let options) = $0.value,
               options.values.allSatisfy({ $0 == .string("") }) { return false }
            return true
        }
        let store = AgentPeerStore(dataRoot: dataRoot)
        if tool == "agent_message", let reply = try await HelperContact.message(input) { return reply }
        if tool == "agent_contacts" {
            try Self.peerKeys(args, allowed: ["discover", "details"])
            // A name in discover ("Grok Bot") means "find this one": filter to it.
            var named: String?
            var refresh = false
            switch args["discover"] {
            case nil, .bool(false)?: break
            case .bool(true)?: refresh = true
            case .string(let text)?:
                let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.lowercased() == "true" { refresh = true }
                else if !text.isEmpty, text.lowercased() != "false" { named = text }
            default: throw AgentCommunicationError.invalid("discover must be true, false, or a contact name")
            }
            let allPeers = try store.list()
            func matches(_ handle: String, _ name: String) -> Bool {
                named.map { handle.caseInsensitiveCompare($0) == .orderedSame || handle.split(separator: ":").last.map(String.init) == $0
                    || name.caseInsensitiveCompare($0) == .orderedSame } ?? true
            }
            var peers = allPeers.filter { peer in matches("peer:" + peer.id, peer.name)
                || named.map { name in (peer.handles ?? []).contains { $0.caseInsensitiveCompare(name) == .orderedSame } } == true }
            let allBots = named?.lowercased().hasPrefix("peer:") == true && !peers.isEmpty ? [] : try BotDefinitionStore(dataRoot: dataRoot).list()
            var bots = allBots.filter { matches("bot:" + $0.id.uuidString.lowercased(), $0.name) }
            let savedMatch = named != nil && (!peers.isEmpty || !bots.isEmpty)
            if !savedMatch {
                peers = allPeers
                bots = allBots
                refresh = refresh || named != nil
                Task.detached(priority: .utility) { [dataRoot] in await AgentContactHealth.shared.refresh(dataRoot: dataRoot) }
            }
            if peers.contains(where: ChatGPTDotIPCTransport.owns) { _ = await chatGPTDotReadiness() }
            var contacts = Self.agentLaneContacts(peers: allPeers, selectedPeers: peers)
            if let door = HelperContact.door, matches(door.name, door.name) {
                contacts.append(.object(["agent": .string(door.name), "name": .string(door.name),
                    "state": .string("available"), "conversation_id": .string(door.conversationID)]))
            }
            let health = AgentContactHealth.read(dataRoot: dataRoot)
            contacts = contacts.map { value in
                guard case .object(var row) = value, case .string(let agent)? = row["agent"], let observed = health[agent] else { return value }
                row["reply_path"] = observed.projection
                if let presence = observed.presenceStatus {
                    row["presence"] = .object(["status": .string(presence), "detail": .string(observed.presenceDetail ?? "")])
                }
                if observed.brokenSince != nil || observed.replyStatus == "unverified" {
                    row["state"] = .string(observed.replyStatus)
                    row["state_detail"] = .string(observed.problem ?? observed.replyDetail)
                    row["readiness"] = .string(observed.replyStatus)
                }
                return .object(row)
            }
            let lasts = AgentConversationStore.lastExchanges(peers: peers,
                records: peers.isEmpty ? [] : (try? AgentConversationStore(dataRoot: dataRoot).records()) ?? [], dataRoot: dataRoot)
            contacts = contacts.map { value in
                guard case .object(var row) = value, case .string(let agent)? = row["agent"],
                      let peer = peers.first(where: { "peer:" + $0.id == agent }),
                      let last = lasts[peer.id] else { return value }
                row["last_exchange"] = .string(last.summary)
                if let replyState = last.replyState { row["reply_state"] = replyState }
                row["retained_exchanges"] = .int(Int64(last.count))
                if row["state"] == .string(AgentPeerContactState.setUp.rawValue), peer.transport != .grokBot, !ChatGPTDotIPCTransport.owns(peer) {
                    row["state_detail"] = .string("Messages have crossed this connection: \(last.summary). No connection proof is recorded on the route itself, so its state word stays set up.")
                }
                return .object(row)
            }
            contacts += bots.map {
                .object(["agent": .string("bot:" + $0.id.uuidString.lowercased()), "name": .string($0.name),
                         "state": .string($0.paused ? "paused" : "not_checked"),
                         "kind": .string("bot"), "paused": .bool($0.paused), "readiness": .string("not_checked"),
                         "capabilities": .array([.string("message"), .string("read")]), "read_inputs": .array([])])
            }
            let connected = Set(peers.compactMap { AgentPeerStore.hostRowID($0.endpoint) })
            // An explicit discover may run what it finds (--help, initialize), under the rule a send runs it by.
            var launch: AgentPeerDiscovery.Launch?
            if refresh, !savedMatch {
                launch = .refused("running a found program needs this app's Full Mac file access on this surface")
                if usesCanonicalBody, await fullMacToolAccess(surface: surface).fileOpsAllowed {
                    let origin = SecurityOriginContext.currentTurn(verifiedSessionId: ChatToolSessionContext.verifiedSessionId, surface: surface)
                    launch = await agentProgramLaunch(SwiftNativeSecurityCenter(dataRoot: dataRoot)
                        .drivenAgentLaunchPermission(origin: origin)).launch
                }
            }
            let found = savedMatch ? [] : await AgentDiscoverySession.shared.candidates(refresh: refresh, launch: launch, dataRoot: dataRoot)
            // A program that answers as an agent already among her contacts is
            // another door to that contact, not a second contact (hermes-acp → Hermes).
            let twins = found.compactMap { candidate -> (AgentDiscoveryCandidate, AgentPeerContact)? in
                guard candidate.hostID == nil, candidate.detail.hasPrefix("Speaks ACP"),
                      let contact = peers.first(where: { Self.sameAgent($0.name, candidate.name) }) else { return nil }
                return (candidate, contact)
            }
            contacts += found.filter { candidate in
                if twins.contains(where: { $0.0 == candidate }) { return false }
                if let host = candidate.hostID {
                    return AgentHostDirectory.rows.first { $0.id == host }?.requiresWorkspace == true || !connected.contains(host)
                }
                return !peers.contains { $0.endpoint == candidate.cardURL || $0.endpoint == candidate.endpoint }
            }.map(\.projection)
            var note: String?
            if let named, !savedMatch {
                let hits = contacts.filter {
                    guard case .object(let row) = $0 else { return false }
                    if row["agent"] == .string(named) { return true }
                    if case .string(let name)? = row["name"] { return name.localizedCaseInsensitiveContains(named) }
                    return false
                }
                if hits.isEmpty { note = "No contact matches '\(named)'; all \(contacts.count) below." } else { contacts = hits }
            }
            let identity = AgentContactIdentity(dataRoot: dataRoot)
            let botHistory: Result<[UUID: [ShelfEntry]], Error> = Result {
                if bots.isEmpty { return [:] }
                return try ShelfStore(dataRoot: dataRoot).entriesByBot()
            }
            contacts = contacts.map { value in
                guard case .object(var row) = value else { return value }
                let agent = row["agent"]?.stringValue ?? ""
                row.removeValue(forKey: "last_reply_in")
                do {
                    let answered: Date?
                    if agent.hasPrefix("peer:") {
                        let lines = try ContactThread.mergedLines(dataRoot: dataRoot, owner: String(agent.dropFirst(5)), identity: identity)
                        answered = lines.last(where: { !$0.mine })?.at
                    } else if agent.hasPrefix("bot:"), let id = UUID(uuidString: String(agent.dropFirst(4))) {
                        answered = try botHistory.get()[id]?.last(where: {
                            !$0.actualReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        })?.runAt
                    } else { answered = nil }
                    row["last_answered"] = answered.map { .string(NativeTimestampFormat.plainZulu($0)) } ?? .null
                    if agent.hasPrefix("peer:") {
                        row["last_reply_in"] = row["last_answered"]
                        if row["state"] == .string("connected") {
                            row["state"] = .string(answered == nil ? "set up" : "answered")
                            row["state_detail"] = .string(answered.map { "Last answered " + NativeTimestampFormat.plainZulu($0) + ". Availability now is not proven." }
                                ?? "No answer in this contact's thread.")
                        }
                    }
                } catch {
                    row["last_answered"] = .null
                    row["state"] = .string("history_unavailable")
                    row["state_detail"] = .string(error.localizedDescription)
                }
                if case .object(let presence)? = row["presence"], presence["status"] == .string("waiting") {
                    row["state"] = .string("waiting")
                }
                return args["details"] == .bool(true) ? .object(row) : Self.compactContact(.object(row))
            }
            var listed: [String: JSONValue] = ["status": .string("ok"), "contacts": .array(contacts),
                            "detail": .string("Last answered is read from the contact's thread; it does not prove availability now. Use details:true for doors and connection evidence.")]
            if let note { listed["note"] = .string(note) }
            if !savedMatch {
                // What this listing read and what it ran, in words.
                let ran: String = switch launch {
                case nil: refresh
                    ? "Found programs were read (signature bytes, settings files, agent cards), not run; agent.contacts {discover: true} runs each one's --help and initialize."
                    : "Listed from the last discovery; nothing was read or run now."
                case .refused(let why)?: "Found programs were read, not run: \(why)."
                case .run?: "Each found program's --help and initialize ran under the rule a send to it uses: Full Mac as is, otherwise the builder sandbox (scrubbed environment, a temporary folder, stdin closed)."
                }
                let doors = twins.map { "\($0.0.name) is another door for \($0.1.name), already a contact" }
                listed["discovery"] = .string(ran + (doors.isEmpty ? "" : " " + doors.joined(separator: "; ") + "."))
            }
            return .object(listed)
        }
        if tool == "agent_connect" {
            try Self.peerKeys(args, allowed: ["name", "endpoint", "transport", "bearer_token", "app_bundle_id", "conversation_label", "disconnect", "working_directory", "workspace", "executable_path", "ability"])
            _ = try store.list() // Never install a secret over unreadable configuration.
            let name = try Self.peerString(args, "name", max: 480)!
            if let ability = args["ability"] {
                // A named connect's gate may bind an executable path to it; a move uses none.
                guard Set(args.keys).isSubset(of: ["name", "ability", "executable_path"]) else {
                    throw AgentCommunicationError.invalid("ability takes a saved contact's name only")
                }
                return try routeContact(name, ability: ability, store: store)
            }
            let workspace = try Self.peerString(args, "workspace", max: 4096, required: false)
            let transportName = try Self.peerString(args, "transport", max: 32, required: false) ?? "auto"
            // A NAME AND NOTHING ELSE. The URL path below is unchanged; this is
            // the other door — look the name up in the known-agent table and set
            // the connection up on this Mac. See `AgentHostConnection`.
            if let disconnect = args["disconnect"] {
                guard case .bool(true) = disconnect else {
                    throw AgentCommunicationError.invalid("disconnect must be true when supplied")
                }
                guard args["endpoint"] == nil, args["bearer_token"] == nil, args["app_bundle_id"] == nil else {
                    throw AgentCommunicationError.invalid("disconnect takes a name only")
                }
                return try await hostDisconnect(name: name, store: store)
            }
            if args["endpoint"] == nil, args["app_bundle_id"] == nil, transportName == "auto" {
                return try await hostConnect(name: name, workspace: workspace, executablePath: try Self.peerString(args, "executable_path", max: 4096, required: false), store: store, surface: surface,
                    workingDirectory: Self.peerString(args, "working_directory", max: 4096, required: false),
                    conversationLabel: Self.peerString(args, "conversation_label", max: 480, required: false)?.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if transportName == "desktop" {
                guard args["bearer_token"] == nil, args["endpoint"] == nil else {
                    throw AgentCommunicationError.invalid("desktop contacts use app_bundle_id, not endpoint or credentials")
                }
                let bundle = try Self.peerString(args, "app_bundle_id", max: 255)!
                let label = try Self.peerString(args, "conversation_label", max: 480, required: false)
                guard let endpoint = URL(string: "app://" + bundle), AgentPeerStore.desktopBundleID(endpoint) == bundle else {
                    throw AgentCommunicationError.invalid("exact application bundle identifier required")
                }
                #if canImport(AppKit)
                // A guessed identifier saves a contact that can never be reached.
                guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) != nil else {
                    throw AgentCommunicationError.invalid("no installed app has the bundle identifier \(bundle); read the real one from the app before saving")
                }
                #endif
                let proposed = AgentPeerContact(name: name, endpoint: endpoint, transport: .desktop, conversationLabel: label)
                let saved = try store.insertDiscovered(proposed)
                return .object(["status": .string(saved.id == proposed.id ? "configured" : "already_configured"),
                    "contact": Self.peerProjection(saved, peers: (try? store.list()) ?? []), "sent": .bool(false), "completed": .bool(false),
                    "detail": .string("Saved a desktop interaction target. App availability, recipient identity and delivery require ordinary screen/interact observation. No app interaction or message was performed. " + Self.desktopSetupNote)])
            }
            guard args["app_bundle_id"] == nil, args["conversation_label"] == nil else {
                throw AgentCommunicationError.invalid("app_bundle_id and conversation_label require desktop transport")
            }
            let address = try Self.peerString(args, "endpoint", max: 2048)!
            guard var endpoint = URL(string: address), transportName == "auto" || AgentPeerTransport(rawValue: transportName) != nil else {
                throw AgentCommunicationError.invalid("endpoint or transport")
            }
            let token = try Self.peerString(args, "bearer_token", max: 8192, required: false)
            guard transportName != "acp", transportName != "mcpHost" else {
                throw AgentCommunicationError.invalid("Connect this installed agent by name so it gets its own key.")
            }
            guard token == nil || usesCanonicalBody else {
                throw AgentCommunicationError.invalid("peer credentials are unavailable outside the canonical app")
            }
            var transport = AgentPeerTransport(rawValue: transportName) ?? .a2a
            var discovery: JSONValue?
            if transportName == "auto" {
                // Validate presentation input before any discovery request.
                try AgentPeerStore.validate(AgentPeerContact(name: name, endpoint: endpoint, transport: transport))
                let result = try await AgentPeerDiscovery.resolve(endpoint, bearerToken: token)
                guard let detected = result.transport, let resolved = result.endpoint else {
                    return Self.peerRedact(result.evidence, token: token)
                }
                endpoint = resolved; transport = detected; discovery = result.evidence
                let matches = try store.list().filter { $0.endpoint == endpoint && $0.transport == transport }
                guard matches.count <= 1 else {
                    return .object(["status": .string("needs_setup"), "detail": .string("Multiple existing contacts use this endpoint and transport. Resolve the ambiguous identity before connecting; nothing was changed.")])
                }
                if let existing = matches.first {
                    return Self.peerRedact(.object(["status": .string(token == nil ? "already_configured" : "needs_setup"),
                        "contact": Self.peerProjection(existing, peers: (try? store.list()) ?? []), "discovery": discovery!,
                        "detail": .string(token == nil ? "Reused the existing contact without changing its identity or credentials. No message sent." : "An existing contact already owns this endpoint. Its identity and credentials were preserved; credential replacement requires explicit setup.")]), token: token)
                }
            }
            var peer = AgentPeerContact(name: name, endpoint: endpoint, transport: transport)
            if token != nil { peer.credentialKey = AgentPeerContact.credentialKey(for: peer.id) }
            try AgentPeerStore.validate(peer)
            if let token { try AgentPeerCredentials.write(token, peerID: peer.id) }
            do {
                let saved: AgentPeerContact
                if transportName == "auto" { saved = try store.insertDiscovered(peer) }
                else { saved = try store.upsert(peer) }
                if saved.id != peer.id {
                    if token != nil { try AgentPeerCredentials.delete(peerID: peer.id) }
                    return Self.peerRedact(.object(["status": .string(token == nil ? "already_configured" : "needs_setup"),
                        "contact": Self.peerProjection(saved, peers: (try? store.list()) ?? []),
                        "detail": .string("A matching contact was installed concurrently. Its identity and credentials were preserved; no message sent.")]), token: token)
                }
            }
            catch {
                if token != nil {
                    do { try AgentPeerCredentials.delete(peerID: peer.id) }
                    catch { throw AgentCommunicationError.invalid("configuration failed and dedicated credential cleanup needs attention") }
                }
                throw error
            }
            var result: [String: JSONValue] = ["status": .string("configured"), "contact": Self.peerProjection(peer, peers: (try? store.list()) ?? []),
                "detail": .string(discovery == nil ? "Saved a contact. No network connection, presence check, or message was performed." : "Saved the discovered contact and supported transport. Discovery is not proof of message delivery or authority; no message sent.")]
            if let discovery { result["discovery"] = discovery }
            return Self.peerRedact(.object(result), token: token)
        }
        if tool == "agent_cancel" { return try await agentCancel(args, store: store) }
        guard tool == "agent_message" || tool == "agent_read" else { throw AgentCommunicationError.invalid("tool") }
        let sending = tool == "agent_message"
        try Self.peerKeys(args, allowed: sending
            ? ["agent", "text", "conversation_id", "message_id", "task_id", "expects_reply", "options"]
            : ["agent", "conversation_id", "message_id", "task_id", "limit", "offset", "max_chars", "text_offset", "source_version", "details", "page_size", "page_token", "status", "context_id", "history_length", "include_artifacts", "status_timestamp_after"])
        if let details = args["details"] {
            guard case .bool = details else { throw AgentCommunicationError.invalid("details must be boolean") }
        }
        if let expects = args["expects_reply"], case .bool = expects {} else if args["expects_reply"] != nil {
            throw ToolFailureError("expects_reply must be true or false.", argumentPath: "expects_reply", effects: .none)
        }
        let agent = try Self.peerString(args, "agent", max: 64)!
        guard agent.hasPrefix("peer:"), let peer = try store.list().first(where: { "peer:" + $0.id == agent }) else {
            throw AgentCommunicationError.invalid("No exact peer:<id> match for \(agent) in \(store.fileURL.path). Read agent.contacts for the saved handle; if absent, read agent.recipe, run agent.verify with its host name, then agent.connect to save the contact.")
        }
        let lane = AgentConversationDelivery.lane(for: agent, dataRoot: dataRoot, bridgeConfigRoot: agentBridgeConfigRoot)
        if lane == nil, let handle = peer.handles?.first(where: {
            AgentConversationDelivery.inbox(agent: $0, bridgeConfigRoot: agentBridgeConfigRoot ?? InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot)) != nil
        }) {
            throw ToolFailureError("The saved inbox door (\(handle)) is unavailable. Read agent.contacts to inspect its reader before sending.",
                accepted: "app {action:\"agent.contacts\"}", effects: .none)
        }
        if lane == nil, args["options"] != nil { throw AgentCommunicationError.invalid("This door does not accept inbox options; use its contact's declared inputs.") }
        // A repair dry-runs a recipe; an inbox is read by its resident session.
        if AgentRecipeStore.dryRun, ![.acp, .desktopChat, .mcpHost, .a2a].contains(peer.transport) || ChatGPTDotIPCTransport.owns(peer)
            || lane != nil || peer.ability != nil {
            return .object(["status": .string("unchecked"), "dry_run": .bool(true), "sent": .bool(false), "agent": .string(agent),
                "detail": .string("\(peer.name) is not reached by a recipe this app can dry-run; nothing was checked or sent.")])
        }
        // Reached through one of her abilities: her conversation with it runs
        // that (`AgentConversationSession.viaAbility`), never the built-in route.
        if let ability = peer.ability {
            guard !sending else {
                throw ToolFailureError("\(peer.name) is reached through your ability \(ability): message it with agent and text, without protocol ids.",
                                       argumentPath: "agent", effects: .none)
            }
            return .object(["status": .string("nothing_to_read"), "completed": .bool(false),
                "detail": .string("Its answers land in your conversation with it; there is nothing more to read here.")])
        }
        if !ChatGPTDotIPCTransport.owns(peer), args["text_offset"] != nil || args["source_version"] != nil {
            throw AgentCommunicationError.invalid("text_offset and source_version are Dot-only. Omit them when reading this contact.")
        }
        if let lane, !sending {
                // Exactly this exchange: its message, or the newest send in the conversation named.
                let conversation = try Self.peerString(args, "conversation_id", max: 1024, required: false)
                let message = try Self.peerString(args, "message_id", max: 160, required: false) ?? conversation.flatMap { thread in
                    try? AgentConversationStore(dataRoot: dataRoot).records()
                        .filter { $0.agent == agent && $0.conversationID == thread }.max { $0.updatedAt < $1.updatedAt }
                }.flatMap { if case .string(let id)? = $0.readInput?["message_id"] { id } else { nil } }
                guard let message else {
                    if conversation == nil {
                        var read = args
                        read["agent"] = .string(lane); read["detail"] = .string("full")
                        read.removeValue(forKey: "details")
                        return AgentConversationView.read(try await impl_delegation_status(input: read), agent: agent, input: args)
                    }
                    throw ToolFailureError(conversation.map { "No retained exchange with \(agent) is in conversation \($0); pass the message_id its send returned." }
                        ?? "Name the exchange to read: the message_id its send returned, or its conversation_id.",
                        argumentPath: conversation == nil ? "message_id" : "conversation_id",
                        accepted: "app {action:\"agent.read\",args:{agent:\"\(agent)\",message_id:\"<send receipt messageId>\"}}", effects: .none)
                }
                return AgentConversationView.read(try await impl_delegation_status(input: ["agent": .string(lane), "detail": .string("full"), "message_id": .string(message)]), agent: agent, input: args)
        }
        let listingFields: Set<String> = ["page_size", "page_token", "status", "context_id", "history_length", "include_artifacts", "status_timestamp_after"]
        if peer.transport == .grokBot {
            guard args["task_id"] == nil else { throw AgentCommunicationError.invalid("Grok uses message_id") }
            if !sending {
                let id = try Self.peerString(args, "message_id", max: 36)!
                // Grok threads are readable across chats; replies stay scoped to the asker.
                return GrokBotRoute.projection(try GrokRequestStore(dataRoot: dataRoot).read(id, peer: peer.id))
            }
            let session = ChatToolSessionContext.verifiedSessionId ?? ChatToolSessionInjection.explicitSessionId(in: input)
            guard !session.isEmpty else { throw AgentCommunicationError.invalid("Send from a chat so Grok's reply can return there") }
            if let requested = try Self.peerString(args, "conversation_id", max: 128, required: false), requested != session {
                throw AgentCommunicationError.invalid("Grok replies return to the conversation asking")
            }
            // The exchange's own id, so its answer pairs with exactly that exchange.
            let id = try Self.peerString(args, "message_id", max: 36, required: false)
                ?? AgentConversationLiveContext.target?.operationID ?? UUID().uuidString.lowercased()
            let text = try Self.peerString(args, "text", max: 64000)!
            // App checks running status; no secrets travel in this internal plan.
            return .object(["status": .string("grok_send"), "peer_id": .string(peer.id),
                "message_id": .string(id), "conversation_id": .string(session), "text": .string(text)])
        }
        if !Set(args.keys).isDisjoint(with: listingFields) {
            guard peer.transport == .a2a, !sending, args["task_id"] == nil else {
                throw AgentCommunicationError.invalid("A2A listing filters require agent_read without task_id")
            }
        }
        if peer.transport == .desktopChat {
            guard sending else {
                return .object(["status": .string("nothing_to_read"), "completed": .bool(false),
                    "detail": .string("The answer returns with the message; there is no saved answer to recover here.")])
            }
            guard args["message_id"] == nil, args["task_id"] == nil,
                  let bundle = AgentPeerStore.desktopBundleID(peer.endpoint) else {
                throw AgentCommunicationError.invalid("This contact takes text and conversation_id only.")
            }
            var plan: [String: JSONValue] = ["status": .string("desktop_chat_send"), "peer_id": .string(peer.id),
                "app_bundle_id": .string(bundle), "text": .string(try Self.peerString(args, "text", max: 64000)!)]
            // The thread's title in that app; absent starts a new thread there.
            if let thread = try Self.peerString(args, "conversation_id", max: 480, required: false) { plan["conversation_id"] = .string(thread) }
            if AgentRecipeStore.dryRun { plan["dry_run"] = .bool(true) }
            return .object(plan)
        }
        if peer.transport == .acp {
            guard sending else {
                return .object(["status": .string("nothing_to_read"), "completed": .bool(false),
                    "detail": .string("The answer returns with the message; there is no saved answer to recover here.")])
            }
            guard args["message_id"] == nil, args["task_id"] == nil else {
                throw AgentCommunicationError.invalid("This contact takes text and conversation_id only.")
            }
            return try await hostACPRun(contact: peer, message: Self.peerString(args, "text", max: 64000)!,
                                        conversationID: Self.peerString(args, "conversation_id", max: 1024, required: false),
                                        store: store, surface: surface)
        }
        if peer.transport == .mcpHost {
            if ChatGPTDotIPCTransport.owns(peer) { return try await chatGPTDotMessage(args, peer: peer, sending: sending) }
            let row = AgentPeerStore.hostRowID(peer.endpoint).flatMap { id in
                AgentHostDirectory.rows.first { $0.id == id }
            }
            // ONE VERB. A host whose row carries a command line is messaged by
            // running it; a host without one pulls: the message is held for its next call.
            guard let row, row.commandLine != nil else {
                return try Self.hostPull(row: row, contact: peer, text: sending ? Self.peerString(args, "text", max: 64000) : nil,
                                         peers: (try? store.list()) ?? [])
            }
            // Nothing to page through: the reply came back in the same call as
            // the message that asked for it, and there is no second copy here.
            guard sending else {
                let state = Self.currentPeerState(peer, peers: (try? store.list()) ?? [])
                return .object(["status": .string("nothing_to_read"), "agent": .string(agent),
                    "transport": .string("mcpHost"), "host": .string(row.id),
                    "state": .string(state.rawValue), "state_detail": .string(state.detail),
                    "read": .bool(false), "completed": .bool(false),
                    "detail": .string("This contact answers in the same call that messages it, so there is no receipt to recover. Send again with agent_message; anything it says on its own arrives as an ordinary inbound turn.")])
            }
            let text = try Self.peerString(args, "text", max: 64000)!
            let requested = try Self.peerString(args, "conversation_id", max: 128, required: false)
            // The model fills unused fields; an empty or null one is not a request for it.
            func given(_ key: String) -> Bool {
                switch args[key] { case nil, .null?, .string("")?: return false; default: return true }
            }
            guard !given("message_id"), !given("task_id") else {
                throw AgentCommunicationError.invalid("a command-line agent takes text and conversation_id only")
            }
            if requested != nil, row.commandLine?.continuesConversations != true {
                throw AgentCommunicationError.invalid("\(row.displayName)'s command line documents no way to continue a conversation, so every message to it is standalone; omit conversation_id")
            }
            if let requested, UUID(uuidString: requested) == nil {
                throw AgentCommunicationError.invalid("conversation_id must be the session UUID returned by this contact")
            }
            let session = requested ?? (row.commandLine?.continuesConversations == true && row.commandLine?.capturesThreadID != true
                ? UUID().uuidString.lowercased() : nil)
            return try await hostCommandRun(row: row, contact: peer, message: text, session: session,
                                        resuming: requested != nil, store: store, surface: surface,
                                        probe: !AgentRecipeStore.dryRun && text == AgentHostDirectory.probeText(appName: Self.appDisplayName))
        }
        if peer.transport == .desktop {
            guard args["conversation_id"] == nil, args["message_id"] == nil, args["task_id"] == nil,
                  args["offset"] == nil, args["max_chars"] == nil,
                  let bundle = AgentPeerStore.desktopBundleID(peer.endpoint) else {
                throw AgentCommunicationError.invalid("desktop routes use visible app/conversation verification, not protocol receipt IDs or paging")
            }
            var target: [String: JSONValue] = ["app_bundle_id": .string(bundle)]
            if let label = peer.conversationLabel { target["conversation_label"] = .string(label) }
            // Desktop contacts are SEND-ONLY. Reading another app's screen for a
            // reply was never a transport; the other agent answers through this
            // app's own inbound door instead.
            guard sending else {
                return .object(["status": .string("ok"), "agent": .string(agent), "transport": .string("desktop"),
                    "operation": .string("read"), "target": .object(target),
                    "opened": .bool(false), "read": .bool(false), "sent": .bool(false), "completed": .bool(false),
                    "detail": .string(Self.desktopSendOnlyDetail)])
            }
            let text = try Self.peerString(args, "text", max: 64000)!
            return .object(["status": .string("requires_interaction"),
                "agent": .string(agent), "transport": .string("desktop"),
                "operation": .string("message"), "target": .object(target),
                "target_is_untrusted_data": .bool(true), "sent": .bool(false), "completed": .bool(false),
                "automatic_action": .bool(false), "requested_text": .string(text),
                "detail": .string("Internal desktop route plan. The app-owned conversation handler executes it through normal Mac permissions. This Core projection has performed no interaction.")])
        }
        let text = try Self.peerString(args, "text", max: 64000, required: sending)
        let requestedConversation = try Self.peerString(args, "conversation_id", max: 512, required: false)
        // The receiving app owns the contact's session namespace. On first
        // send, let it select the conversation and retain its returned ID.
        let conversation = requestedConversation
        let message = try Self.peerString(args, "message_id", max: 512, required: false)
        let task = try Self.peerString(args, "task_id", max: 512, required: false)
        // Validate all transport-specific inputs before any network operation.
        if peer.transport == .nativeAgent {
            guard task == nil, sending || (message != nil && conversation != nil),
                  !sending || message == nil || UUID(uuidString: message!) != nil else {
                throw AgentCommunicationError.invalid("NativeAgent uses conversation_id and receipt message_id; send message_id must be a UUID; task_id is unsupported")
            }
            guard (conversation?.utf8.count ?? 0) <= 128, (message?.utf8.count ?? 0) <= 128 else {
                throw AgentCommunicationError.invalid("NativeAgent identity exceeds 128 bytes")
            }
            _ = try Self.peerPage(args, "offset", default: 0, range: 0...1_048_576)
            _ = try Self.peerPage(args, "max_chars", default: 8000, range: 1...16000)
        } else {
            guard args["offset"] == nil, args["max_chars"] == nil, sending || (message == nil && conversation == nil) else {
                throw AgentCommunicationError.invalid("A2A read takes task_id or listing filters; offset, max_chars, message_id and conversation_id are unsupported for read")
            }
        }
        var available = false
        defer { if !available { store.recordUnavailable(peerID: peer.id) } }
        guard peer.credentialKey == nil || usesCanonicalBody else {
            throw AgentCommunicationError.invalid("peer credentials are unavailable outside the canonical app")
        }
        let token = peer.credentialKey == nil ? nil : try AgentPeerCredentials.read(peerID: peer.id)
        if peer.credentialKey != nil && token == nil { throw AgentCommunicationError.invalid("configured peer credential is unavailable") }
        let localRequestID = UUID().uuidString.lowercased()
        // The attested door id rides beside the display name: the taint latch keys trust by it.
        var envelope: [String: JSONValue] = ["agent": .string(agent), "agent_id": .string("peer:" + peer.id),
            "transport": .string(peer.transport.rawValue),
            "local_request_id": .string(localRequestID), "automatic_polling": .bool(false)]
        func finished(_ fields: [String: JSONValue]) -> JSONValue {
            var result = fields
            // A2A direct messages have no GetMessage endpoint. Only a task
            // can provide an A2A recovery route; NativeAgent uses its receipt.
            if peer.transport == .nativeAgent || fields["task_id"] != nil,
               let locator = AgentConversationRouting.readLocator(agent: agent,
                    message: fields["message_id"], conversation: fields["conversation_id"], task: fields["task_id"]) {
                result["read_with"] = locator
            }
            let redacted = Self.peerRedact(.object(result), token: token)
            return sending ? redacted : AgentConversationView.read(redacted, agent: agent, input: args)
        }
        let request: AgentA2AWire.Request
        var a2aInterface: AgentA2AWire.Interface?
        // The recipe this send was held to, kept for its proof.
        var a2aRecipe: AgentRecipeStore.Recipe?
        if peer.transport == .a2a {
            // Its card, held to its recipe; a dry run ends here (`AgentPeerDiscovery.a2aCheck`).
            let checked = await AgentPeerDiscovery.a2aCheck(peer, bearerToken: token, sending: sending)
            guard let selected = checked.interface else {
                available = [.string("passed"), .string("repaired")].contains(checked.receipt["status"] ?? .null)
                return finished(envelope.merging(checked.receipt) { $1 })
            }
            a2aInterface = selected
            a2aRecipe = checked.recipe
            if sending {
                let outgoingID = message ?? UUID().uuidString.lowercased()
                envelope["outgoing_message_id"] = .string(outgoingID)
                let push: JSONValue?
                if selected.version == "1.0", selected.pushNotifications, AgentA2AWire.isLoopback(selected.endpoint), usesCanonicalBody {
                    push = await a2aPushConfiguration?(peer)
                } else { push = nil }
                envelope["push_notifications"] = .string(push == nil
                    ? "Unavailable: this app receives webhooks only on loopback. Using streaming or task reads."
                    : "A running loopback webhook is offered to this local peer; task reads remain available.")
                request = try AgentA2AWire.messageRequest(text: text!, messageID: outgoingID, contextID: conversation,
                    taskID: task, interface: selected, requestID: localRequestID, streaming: selected.streaming, pushConfiguration: push)
            } else if task == nil {
                var filters: [String: JSONValue] = [:]
                for (input, wire) in ["page_size": "pageSize", "page_token": "pageToken", "status": "status", "context_id": "contextId", "history_length": "historyLength", "include_artifacts": "includeArtifacts", "status_timestamp_after": "statusTimestampAfter"] {
                    filters[wire] = args[input]
                }
                let result = try await AgentPeerDiscovery.listTasks(filters, interface: selected, bearerToken: token, requestID: localRequestID)
                available = true
                envelope["status"] = .string("ok")
                if case .object(let fields) = result {
                    envelope["tasks"] = fields["tasks"] ?? .array([])
                    envelope["next_page_token"] = fields["nextPageToken"] ?? .string("")
                    envelope["page_size"] = fields["pageSize"] ?? .int(0)
                    envelope["total_size"] = fields["totalSize"] ?? .int(0)
                }
                envelope["completed"] = .bool(false)
                envelope["untrusted_remote_data"] = .bool(PeerDataTaintDispatcher.containsPeerText(envelope["tasks"] ?? .null))
                return Self.peerRedact(.object(envelope), token: token)
            } else {
                if await AgentA2APushReceiver.shared.consume(peerID: peer.id, taskID: task!) {
                    envelope["push_update_received"] = .bool(true)
                }
                request = try AgentA2AWire.taskRequest(taskID: task!, interface: selected, requestID: localRequestID)
            }
        } else {
            let cardURL = peer.endpoint.appendingPathComponent("agent/card")
            let response = try await AgentPeerHTTP.get(cardURL, bearerToken: token)
            if !(200..<300).contains(response.statusCode) {
                Self.peerFailure(.init(cause: .http(status: response.statusCode,
                    detail: (try? response.json?.serialize(pretty: false)) ?? ""), work: .nothingRan), into: &envelope)
                return finished(envelope)
            }
            guard (200..<300).contains(response.statusCode), case .object(let card)? = response.json,
                  card["protocol"] == .string("nativeagent-bridge"), card["version"] == .string("1.0") else {
                throw AgentCommunicationError.invalid("unsupported or unavailable NativeAgent card; no message sent")
            }
            var body: [String: JSONValue] = [:]
            if sending {
                body["text"] = .string(text!)
                let remoteRequestID = message ?? localRequestID
                body["request_id"] = .string(remoteRequestID)
                envelope["message_id"] = .string(remoteRequestID)
                if let conversation { body["sessionId"] = .string(conversation) }
            } else {
                body = ["request_id": .string(message!), "session_id": .string(conversation!),
                    "offset": .int(Int64(try Self.peerPage(args, "offset", default: 0, range: 0...1_048_576))),
                    "max_chars": .int(Int64(try Self.peerPage(args, "max_chars", default: 8000, range: 1...16000)))]
            }
            request = AgentA2AWire.Request(url: peer.endpoint.appendingPathComponent(sending ? "agent/message" : "agent/reply"),
                httpMethod: "POST", headers: ["Content-Type": "application/json"], body: .object(body), requestID: nil)
        }
        if let conversation { envelope["conversation_id"] = .string(conversation) }
        if let task { envelope["task_id"] = .string(task) }
        if !sending, let message { envelope["message_id"] = .string(message) }
        do {
            let response = try await AgentPeerHTTP.send(request, bearerToken: token)
            envelope["http_status"] = .int(Int64(response.statusCode))
            if response.interrupted { envelope["interrupted"] = .bool(true) }
            guard (200..<300).contains(response.statusCode) else {
                let detail = (try? response.json?.serialize(pretty: false)) ?? ""
                let cause = ProviderFailure.http(status: response.statusCode, detail: detail)
                Self.peerFailure(ProviderFailure.Report(cause: cause, work: .outcomeUnknown), into: &envelope)
                return finished(envelope)
            }
            if let interface = a2aInterface {
                let result: AgentA2AWire.Result
                if request.isStreaming {
                    let receipt = response.receipt
                    envelope["interrupted"] = .bool(response.interrupted || receipt?.interrupted != false)
                    guard let receipt, let value = receipt.result else { throw AgentCommunicationError.invalid("No answer arrived. The work may still be running; do not resend automatically.") }
                    result = value
                    if receipt.interrupted { envelope["detail"] = .string("The connection ended before an outcome arrived. Read this task again; do not resend the message.") }
                    else if response.interrupted { envelope["detail"] = .string("The connection was interrupted after the reported outcome arrived. Do not resend the message.") }
                } else {
                    guard let payload = response.json else { throw AgentCommunicationError.invalid("No answer arrived. Do not resend automatically.") }
                    result = try AgentA2AWire.normalizeResponse(payload, interface: interface,
                        expectedRequestID: request.requestID, expectedTaskID: sending ? nil : task)
                }
                if let conversation, let returned = result.contextID, conversation != returned {
                    throw AgentCommunicationError.invalid("conversation identity mismatch")
                }
                envelope["status"] = .string(result.state)
                envelope["reply"] = .string(result.text)
                envelope["completed"] = .bool(result.completed)
                envelope["terminal"] = .bool(result.terminal)
                envelope["needs_input"] = .bool(result.needsInput)
                envelope["needs_authentication"] = .bool(result.needsAuthentication)
                if result.needsInput { envelope["detail"] = .string("The other agent needs an answer before continuing.") }
                if result.needsAuthentication { envelope["detail"] = .string("The other agent needs access before continuing.") }
                if let value = result.taskID { envelope["task_id"] = .string(value) }
                if let value = result.contextID { envelope["conversation_id"] = .string(value) }
                if let value = result.messageID { envelope["message_id"] = .string(value) }
                envelope["parts"] = .array(result.parts)
                envelope["artifacts"] = .array(result.artifacts)
                if let failure = result.failure { Self.peerFailure(failure, into: &envelope) }
                envelope["untrusted_remote_data"] = .bool(PeerDataTaintDispatcher.containsPeerText(.object([
                    "reply": .string(result.text), "parts": .array(result.parts),
                    "artifacts": .array(result.artifacts)
                ])))
            } else {
                guard let payload = response.json, case .object(let row) = payload, case .string(let status)? = row["status"] else {
                    throw AgentCommunicationError.invalid("peer reply shape")
                }
                if !sending {
                    guard row["request_id"] == .string(message!), row["session_id"] == .string(conversation!) else {
                        throw AgentCommunicationError.invalid("receipt identity mismatch")
                    }
                } else {
                    guard row["requestId"] == envelope["message_id"] else {
                        throw AgentCommunicationError.invalid("message identity mismatch")
                    }
                    if let conversation, row["sessionId"] != .string(conversation) {
                        throw AgentCommunicationError.invalid("conversation identity mismatch")
                    }
                }
                envelope["status"] = row["ack"] == .string("enqueued") ? .string("enqueued") : .string(status)
                if let value = row["requestId"] { envelope["message_id"] = value }
                if let value = row["sessionId"] { envelope["conversation_id"] = value }
                if let value = row["runId"] ?? row["run_id"] { envelope["run_id"] = value }
                envelope["remote_evidence"] = payload
                for key in ["reply", "detail", "work", "provider_failure"] {
                    if let value = row[key] { envelope[key] = value }
                }
                // A failed peer's own why, read as normalization reads any failure's
                // shape, when it sent no detail; what is promoted is peer text.
                let gaveDetail = if case .string(let given)? = row["detail"] {
                    !given.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } else { false }
                let failed = ChatToolOutcome.ExactResultClass(rawValue: row["execution_result_class"]?.stringValue ?? "")?.isFailure == true
                var promoted = false
                if !gaveDetail, failed,
                   case .object(let failure) = ChatToolOutcome.normalizedFailure(.object(["status": .string("failed"), "result": payload])),
                   case .string(let why)? = failure["message"] {
                    envelope["detail"] = .string(why)
                    promoted = true
                }
                for key in ["retrieval_result_class", "execution_result_class"] { envelope[key] = row[key] }
                if !sending { envelope["terminal"] = row["execution_terminal"] }
                envelope["untrusted_remote_data"] = .bool(promoted || PeerDataTaintDispatcher.containsPeerText(payload))
            }
            // The same proof, on the same terms, for a network peer: the send
            // was accepted, and a reply counts only where one actually came
            // back with it. An acknowledgement is not a reply.
            if sending {
                // An A2A peer accepted it: what a bound retry reads (`AgentContactHealth.heal`).
                if a2aInterface != nil { envelope["sent"] = .bool(true) }
                if case .string(let reply)? = envelope["reply"], !reply.isEmpty {
                    store.recordProof(peerID: peer.id, inbound: true, outbound: true)
                    if envelope["needs_authentication"] != .bool(true),
                       envelope["needs_input"] != .bool(true),
                       envelope["terminal"] != .bool(true) || envelope["completed"] == .bool(true) {
                        store.recordRoundTrip(peerID: peer.id, workspace: "Remote workspace (not reported)", recipe: a2aRecipe)
                    }
                } else {
                    store.recordProof(peerID: peer.id, outbound: true)
                }
            }
            available = envelope["needs_authentication"] != .bool(true)
                && envelope["status"] != .string("failed")
            return finished(envelope)
        } catch {
            envelope["status"] = .string(sending ? "outcome_unknown" : "unavailable")
            envelope["detail"] = .string("Transport or response validation did not establish an outcome. IDs are correlation, not proof of acceptance or deduplication. NativeAgent recovery requires both message_id and a known conversation_id. Do not resend automatically.")
            if let failure = ProviderFailure.report(error, work: .outcomeUnknown) {
                Self.peerFailure(failure, into: &envelope)
            } else if case .remote(_, let message) = error as? AgentA2AWire.WireError {
                let cause = ProviderFailure.wire(message)
                Self.peerFailure(.init(cause: cause, work: .outcomeUnknown), into: &envelope)
            }
            return finished(envelope)
        }
    }
    /// Moves a saved contact to one of her abilities, or (false) back to its
    /// built-in route; its thread, identity, trust and keys stay as they are.
    private func routeContact(_ name: String, ability: JSONValue, store: AgentPeerStore) throws -> JSONValue {
        let matches = try store.list().filter { "peer:" + $0.id == name || $0.name.caseInsensitiveCompare(name) == .orderedSame }
        guard matches.count == 1, let peer = matches.first else {
            throw ToolFailureError("Name one saved contact from agent.contacts, by its name or peer:<id>, to move. Nothing changed.",
                                   argumentPath: "agent", effects: .none)
        }
        var id: String?
        if case .string(let wanted) = ability {
            guard let file = try AbilityStore(dataRoot: dataRoot).read(id: wanted), file.kind == .part else {
                throw ToolFailureError("No ability of yours is named \(wanted); ability.list shows them. Nothing changed.",
                                       argumentPath: "ability", effects: .none)
            }
            id = file.id
        } else if ability != .bool(false) {
            throw ToolFailureError("ability is one of your abilities' id, or false for the contact's built-in route.", argumentPath: "ability", effects: .none)
        }
        guard let moved = try store.route(peerID: peer.id, ability: id) else { throw AgentCommunicationError.invalid("This contact is no longer saved.") }
        return .object(["status": .string("configured"), "contact": Self.peerProjection(moved, peers: (try? store.list()) ?? []),
            "sent": .bool(false), "detail": .string(id.map { "\(moved.name) is reached through your ability \($0) from now on: agent.message runs it, and it answers with agent.reply. Its conversation, identity and trust are unchanged." }
                ?? "\(moved.name) is reached through its built-in route again.")])
    }
    static func peerRedact(_ value: JSONValue, token: String?) -> JSONValue {
        guard let token, !token.isEmpty else { return value }
        switch value {
        case .string(let text): return .string(text.replacingOccurrences(of: token, with: "[redacted]"))
        case .array(let values): return .array(values.map { peerRedact($0, token: token) })
        case .object(let values):
            var cleaned: [String: JSONValue] = [:]
            for (key, value) in values { cleaned[key.replacingOccurrences(of: token, with: "[redacted]")] = peerRedact(value, token: token) }
            return .object(cleaned)
        default: return value
        }
    }
    static func peerKeys(_ args: [String: JSONValue], allowed: Set<String>) throws {
        let unknown = Set(args.keys).subtracting(allowed).sorted()
        guard unknown.isEmpty else {
            throw ToolFailureError("Agent communication: unsupported fields: " + unknown.joined(separator: ", ") + ".",
                                   argumentPath: unknown.first, effects: .none)
        }
    }
    static func peerString(_ args: [String: JSONValue], _ key: String, max: Int, required: Bool = true) throws -> String? {
        guard let value = args[key] else {
            if required { throw AgentCommunicationError.invalid("missing \(key)") }
            return nil
        }
        guard case .string(let text) = value, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= max else { throw AgentCommunicationError.invalid("invalid \(key)") }
        return text
    }
    private static func peerPage(_ args: [String: JSONValue], _ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let value = args[key] else { return fallback }
        guard case .int(let number) = value, let integer = Int(exactly: number), range.contains(integer) else {
            throw AgentCommunicationError.invalid("invalid \(key)")
        }
        return integer
    }
}
