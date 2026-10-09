import AgentWorkspace
import GrokLink
#if canImport(AppKit)
import AppKit
#endif
import Foundation
import TrustCenter
import CryptoKit
import ApprovalInbox
import NativeAgentCore
import PersistenceCore
import StandingBots
import ProviderRouting

public protocol BuiltInAgentLaneProviding: Sendable {
    func builtInAgentLaneUsable(_ name: String) -> Bool
}

extension SwiftToolDispatcher: BuiltInAgentLaneProviding {
    public static func closeACPConnections() async { await AgentACPConnections.shared.closeAll() }

    public func builtInAgentLaneUsable(_ name: String) -> Bool {
        let helper: URL?
        let cli: String
        let directory: String
        switch name {
        case "codex":
            helper = AgentBridgeRuntime.codexHelperURL(override: codexMessageWakeupHelperOverride, dataRoot: dataRoot)
            cli = "codex"
            directory = "codex-nativeagent-bridge"
        case "claude":
            // Nothing is launched: her live session reads the inbox.
            var isDirectory: ObjCBool = false
            let inbox = Self.bridgeConfigDirectory(named: "claude-bridge", configRootOverride: agentBridgeConfigRoot)
            return FileManager.default.fileExists(atPath: inbox.path, isDirectory: &isDirectory) && isDirectory.boolValue
        case "omp":
            helper = AgentBridgeRuntime.ompHelperURL(override: ompMessageWakeupHelperOverride, dataRoot: dataRoot)
            cli = "omp"
            directory = "omp-bridge"
        default: return false
        }
        return Self.builtInAgentLaneUsable(
            directory: Self.bridgeConfigDirectory(named: directory, configRootOverride: agentBridgeConfigRoot),
            readiness: AgentBridgeRuntime.readiness(helper: helper, cliName: cli, bridgeConfigRoot: agentBridgeConfigRoot)
        )
    }

    static func builtInAgentLaneUsable(directory: URL, readiness: AgentBridgeRuntime.Readiness) -> Bool {
        var isDirectory: ObjCBool = false
        return readiness.readyForAsyncRoundTrip
            && FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    func impl_agentCommunication(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        let optional: Set<String> = ["endpoint", "app_bundle_id", "conversation_label", "transport", "bearer_token", "conversation_id", "message_id", "task_id", "options", "limit", "offset", "max_chars", "details", "disconnect"]
        let args = input.filter {
            if ["session_id", "__session_id"].contains($0.key) { return false }
            if optional.contains($0.key), $0.value == .string("") { return false }
            // False means the caller is not disconnecting.
            if $0.key == "disconnect", $0.value == .bool(false) { return false }
            if $0.key == "options", case .object(let options) = $0.value,
               options.values.allSatisfy({ $0 == .string("") }) { return false }
            return true
        }
        let store = AgentPeerStore(dataRoot: dataRoot)
        if tool == "agent_contacts" {
            try Self.peerKeys(args, allowed: ["discover"])
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
            let laneNames = ["codex", "claude", "omp"]
            func matches(_ handle: String, _ name: String) -> Bool {
                named.map { handle.caseInsensitiveCompare($0) == .orderedSame || handle.split(separator: ":").last.map(String.init) == $0
                    || name.caseInsensitiveCompare($0) == .orderedSame } ?? true
            }
            var peers = allPeers.filter { matches("peer:" + $0.id, $0.name) }
            var lanes = laneNames.filter { matches($0, $0) }
            let allBots = named?.lowercased().hasPrefix("peer:") == true && !peers.isEmpty ? [] : try BotDefinitionStore(dataRoot: dataRoot).list()
            var bots = allBots.filter { matches("bot:" + $0.id.uuidString.lowercased(), $0.name) }
            let savedMatch = named != nil && (!peers.isEmpty || !lanes.isEmpty || !bots.isEmpty)
            if !savedMatch {
                peers = allPeers
                lanes = laneNames
                bots = allBots
                refresh = refresh || named != nil
                Task.detached(priority: .utility) { [dataRoot] in await AgentContactHealth.shared.refresh(dataRoot: dataRoot) }
            }
            if peers.contains(where: ChatGPTDotIPCTransport.owns) { _ = await chatGPTDotReadiness() }
            let usable = Set(lanes.filter { builtInAgentLaneUsable($0) })
            var contacts = Self.agentLaneContacts(peers: allPeers, selectedPeers: peers, lanes: lanes, usable: usable)
            let health = AgentLocalHealth.read(dataRoot)
            contacts = contacts.map { value in
                guard case .object(var row) = value, case .string(let agent)? = row["agent"], let observed = health[agent] else { return value }
                row["reply_path"] = observed.projection
                if observed.brokenSince != nil || observed.status == "unverified" {
                    row["state"] = .string(observed.status)
                    row["state_detail"] = .string(observed.problem ?? observed.detail)
                    row["readiness"] = .string(observed.status)
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
                         "kind": .string("bot"), "paused": .bool($0.paused), "readiness": .string("not_checked"),
                         "capabilities": .array([.string("message"), .string("read")]), "read_inputs": .array([])])
            }
            let connected = Set(peers.compactMap { AgentPeerStore.hostRowID($0.endpoint) })
            let found = savedMatch ? [] : await AgentDiscoverySession.shared.candidates(refresh: refresh)
            contacts += found.filter { candidate in
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
            if named == nil || note != nil { contacts = contacts.map(Self.compactContact) }
            var listed: [String: JSONValue] = ["status": .string("ok"), "contacts": .array(contacts),
                            "states": .array([AgentPeerContactState.listed, .setUp, .connected, .sendOnly]
                                .map { .string($0.rawValue + " — " + $0.detail) }),
                            "detail": .string("Configuration is not evidence of availability or permission to send. Connected means a real message arrived through the connection, or a message and reply crossed it. Each route shows its own proof.")]
            if let note { listed["note"] = .string(note) }
            return .object(listed)
        }
        if tool == "agent_connect" {
            try Self.peerKeys(args, allowed: ["name", "endpoint", "transport", "bearer_token", "app_bundle_id", "conversation_label", "disconnect", "working_directory", "workspace", "executable_path"])
            _ = try store.list() // Never install a secret over unreadable configuration.
            let name = try Self.peerString(args, "name", max: 480)!
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
            ? ["agent", "text", "conversation_id", "message_id", "task_id", "expects_reply"]
            : ["agent", "conversation_id", "message_id", "task_id", "limit", "offset", "max_chars", "text_offset", "source_version", "details", "page_size", "page_token", "status", "context_id", "history_length", "include_artifacts", "status_timestamp_after"])
        if let details = args["details"] {
            guard case .bool = details else { throw AgentCommunicationError.invalid("details must be boolean") }
        }
        if let expects = args["expects_reply"], case .bool = expects {} else if args["expects_reply"] != nil {
            throw ToolFailureError("expects_reply must be true or false.", argumentPath: "expects_reply", effects: .none)
        }
        let agent = try Self.peerString(args, "agent", max: 64)!
        guard agent.hasPrefix("peer:"), let peer = try store.list().first(where: { "peer:" + $0.id == agent }) else {
            throw AgentCommunicationError.invalid("configured peer handle required")
        }
        if !ChatGPTDotIPCTransport.owns(peer), args["text_offset"] != nil || args["source_version"] != nil {
            throw AgentCommunicationError.invalid("text_offset and source_version are Dot-only. Omit them when reading this contact.")
        }
        // Claude Code and Claude Desktop are Claude's doors: a message to one
        // goes to her inbox like claude_message, never to a headless run.
        if sending, AgentContactIdentity(dataRoot: dataRoot).canonical(agent) == "claude" {
            guard !AgentSwarmInheritedToolScope.isWorker else {
                throw AutonomyGateError.toolDenied(
                    reason: "claude_message is reserved for the parent turn and is unavailable inside a swarm worker"
                )
            }
            var message: [String: JSONValue] = ["text": .string(try Self.peerString(args, "text", max: 64000)!)]
            if let thread = try Self.peerString(args, "conversation_id", max: 1024, required: false), thread.hasPrefix("claude:") {
                message["conversation_id"] = .string(thread)
            }
            if let id = try Self.peerString(args, "message_id", max: 160, required: false) { message["message_id"] = .string(id) }
            message["expects_reply"] = args["expects_reply"]
            let session = Self.extractSessionId(from: input)
            if !session.isEmpty { message["session_id"] = .string(session) }
            return try await runClaudeMessage(input: message, surface: surface, configRootOverride: agentBridgeConfigRoot)
        }
        let listingFields: Set<String> = ["page_size", "page_token", "status", "context_id", "history_length", "include_artifacts", "status_timestamp_after"]
        if peer.transport == .grokBot {
            guard args["task_id"] == nil else { throw AgentCommunicationError.invalid("Grok uses message_id") }
            if !sending {
                let id = try Self.peerString(args, "message_id", max: 36)!
                // 2026-09-22: her workspace window reads a Grok thread from any of
                // her chats (User's product rule); only replies stay scoped to the asker.
                return GrokBotRoute.projection(try GrokRequestStore(dataRoot: dataRoot).read(id, peer: peer.id))
            }
            let session = ChatToolSessionContext.verifiedSessionId ?? Self.extractSessionId(from: input)
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
            // running it; a host without one has no outbound route at all.
            guard let row, row.commandLine != nil else {
                return Self.hostNoCommandLine(row: row, contact: peer, peers: (try? store.list()) ?? [])
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
            return await hostCommandRun(row: row, contact: peer, message: text, session: session,
                                        resuming: requested != nil, store: store, surface: surface,
                                        probe: text == AgentHostDirectory.probeText(appName: Self.appDisplayName))
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
        var envelope: [String: JSONValue] = ["agent": .string(agent), "transport": .string(peer.transport.rawValue),
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
        if peer.transport == .a2a {
            let response = try await AgentPeerHTTP.get(peer.endpoint, bearerToken: token)
            if !(200..<300).contains(response.statusCode) {
                Self.peerFailure(.init(cause: .http(status: response.statusCode,
                    detail: (try? response.json?.serialize(pretty: false)) ?? ""), work: .nothingRan), into: &envelope)
                return finished(envelope)
            }
            guard (200..<300).contains(response.statusCode), let card = response.json else {
                throw AgentCommunicationError.invalid("agent card unavailable; no message sent")
            }
            let selected: AgentA2AWire.Interface
            do { selected = try await AgentPeerDiscovery.authenticatedInterface(card: card, cardURL: peer.endpoint, bearerToken: token) }
            catch {
                if let failure = ProviderFailure.report(error, work: .nothingRan) {
                    Self.peerFailure(failure, into: &envelope)
                    return finished(envelope)
                }
                throw AgentCommunicationError.invalid("unsupported or invalid A2A card; no message sent")
            }
            try Self.peerAuthorizeInterface(selected, cardURL: peer.endpoint, hasCredential: token != nil)
            a2aInterface = selected
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
                let listing = try AgentA2AWire.operationRequest("ListTasks", parameters: filters, interface: selected, requestID: localRequestID)
                let response = try await AgentPeerHTTP.send(listing, bearerToken: token)
                guard (200..<300).contains(response.statusCode), let payload = response.json else { throw AgentCommunicationError.invalid("task listing unavailable") }
                let result = try AgentA2AWire.normalizeTaskList(payload, interface: selected, requestID: listing.requestID)
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
                    let receipt = try AgentA2AStream.normalize(response.events, interface: interface,
                        requestID: request.requestID, expectedTaskID: task)
                    envelope["interrupted"] = .bool(response.interrupted || receipt.interrupted)
                    guard let value = receipt.result else { throw AgentCommunicationError.invalid("No answer arrived. The work may still be running; do not resend automatically.") }
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
                if let status = row["original_status"] { envelope["status"] = status }
                envelope["untrusted_remote_data"] = .bool(PeerDataTaintDispatcher.containsPeerText(payload))
            }
            // The same proof, on the same terms, for a network peer: the send
            // was accepted, and a reply counts only where one actually came
            // back with it. An acknowledgement is not a reply.
            if sending {
                if case .string(let reply)? = envelope["reply"], !reply.isEmpty {
                    store.recordProof(peerID: peer.id, inbound: true, outbound: true)
                    if envelope["needs_authentication"] != .bool(true),
                       envelope["needs_input"] != .bool(true),
                       envelope["terminal"] != .bool(true) || envelope["completed"] == .bool(true) {
                        store.recordRoundTrip(peerID: peer.id, workspace: "Remote workspace (not reported)")
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

    // MARK: - Connect by name

    static func peerFailure(_ failure: ProviderFailure.Report, into envelope: inout [String: JSONValue]) {
        AgentPeerPolicy.peerFailure(failure, into: &envelope)
    }

    /// Connect-by-name. By the time this runs the person has already pressed
    /// the button on the card `AgentHostConnection.cardText` wrote — a
    /// confirm-tier tool body only executes on the approved replay — so this is
    /// where the entry is actually written and not one step earlier.
    private func hostConnect(name: String, workspace: String?, executablePath: String?, store: AgentPeerStore, surface: String, workingDirectory: String? = nil, conversationLabel: String? = nil) async throws -> JSONValue {
        guard conversationLabel == nil || AgentHostDirectory.row(named: name)?.route == .grokBot else {
            throw AgentCommunicationError.invalid("conversation_label by name applies to Grok Bot only; for a desktop app's chat use transport desktop with app_bundle_id")
        }
        // A chat app driven through its own window: nothing is written to its
        // settings and no key is minted, so saving it needs no card.
        if let row = AgentHostDirectory.row(named: name), row.route == .desktopChat {
            guard row.isInstalled, let bundle = row.bundleIDs.first, let endpoint = URL(string: "app://" + bundle) else {
                return .object(["status": .string("not_supported"), "requested": .string(name), "changed": .bool(false),
                                "detail": .string("\(row.displayName) is not installed on this Mac.")])
            }
            let saved = try store.insertDiscovered(AgentPeerContact(name: row.displayName, endpoint: endpoint, transport: .desktopChat))
            return .object(["status": .string("configured"), "contact": Self.peerProjection(saved, peers: (try? store.list()) ?? []),
                "changed": .bool(true), "completed": .bool(false),
                "detail": .string("Saved. Your first message opens a chat of your own in \(row.displayName) and brings its answer back in the same call.")])
        }
        guard AgentHostDirectory.row(named: name)?.acp != nil || AgentHostConnection.personApproved else {
            throw AgentCommunicationError.invalid("Connecting a named agent requires the person's approval card.")
        }
        guard usesCanonicalBody else {
            throw AgentCommunicationError.invalid("setting another agent up on this Mac is unavailable outside the canonical app")
        }
        var proposal: AgentHostConnection.Proposal
        do { proposal = try AgentHostConnection.propose(name: name, store: store, dataRoot: dataRoot, workspace: workspace, workingDirectory: workingDirectory) }
        catch let refusal as AgentHostConnection.Refusal {
            // Unknown or uninstalled: an honest result, nothing changed.
            return .object(["status": .string("not_supported"),
                            "requested": .string(name),
                            "known_agents": .array(AgentHostDirectory.knownNames.map(JSONValue.string)),
                            "changed": .bool(false),
                            "detail": .string(refusal.localizedDescription)])
        }
        if proposal.row.route == .grokBot {
            let result = try AgentHostConnection.connect(proposal: proposal, store: store)
            // The Connect card's "Use this Bot": the exact sidebar name of the
            // Bot that receives the routine request, chosen before it is sent.
            if let conversationLabel {
                guard result.contact.grokConversation == nil else {
                    throw AgentCommunicationError.invalid("The routine request already went to a Bot, so the Bot cannot be changed here. Disconnect Grok Bot (disconnect true, name peer:\(result.contact.id)) and connect again with conversation_label.")
                }
                do {
                    try store.updateGrok(result.contact.id) { current in
                        guard current.grokConversation == nil else { throw GrokLinkCredential.Failure.invalid }
                        current.conversationLabel = conversationLabel
                    }
                } catch {
                    throw AgentCommunicationError.invalid("conversation_label was not saved: it must be the Bot's exact sidebar name on one line, and the routine request must not have gone out yet")
                }
            }
            return .object(["status": .string("grok_setup"), "peer_id": .string(result.contact.id)])
        }
        if var existing = proposal.existing, proposal.row.acp == nil {
            if proposal.row.format == .shellEnvironment {
                let result = try AgentHostConnection.ensureEnvironment(proposal: proposal, store: store)
                return Self.environmentSetupResult(proposal: proposal, contact: result.contact, peers: try store.list(),
                    changed: result.repaired, repaired: result.repaired)
            }
            let permissionsChanged = try AgentHostConnection.ensureMessagingPermissions(contact: existing, store: store)
            // Connecting again approves the program installed now (the path the
            // card showed) when the approved one is gone, changed, or no longer
            // the installed version — updates leave old version folders behind.
            var programApproved = false
            if proposal.row.commandLine != nil,
               let path = proposal.executablePath, path == executablePath, existing.verifiedExecutablePath != path {
                programApproved = (try? store.approveExecutable(peerID: existing.id, path: path)) == true
                if programApproved, let saved = try? store.list().first(where: { $0.id == existing.id }) { existing = saved }
            }
            var value: [String: JSONValue] = ["status": .string("already_configured"), "contact": Self.peerProjection(existing, peers: (try? store.list()) ?? []),
                            "changed": .bool(permissionsChanged || programApproved),
                            "detail": .string(programApproved
                                ? "Approved the \(proposal.row.displayName) program at \(existing.approvedExecutablePath ?? ""); a Full Mac launch runs exactly this file. Nothing else was changed."
                                : "\(proposal.row.displayName) already has this app's entry and its own key. Nothing was changed.")]
            if existing.state != .connected, proposal.row.commandLine?.automaticMCPProbe == false {
                value["detail"] = .string(Self.directCommandSetupDetail)
            }
            if permissionsChanged { value["detail"] = .string("Enabled only this connection's two messaging tools in Antigravity. Send a message to verify the return path; existing Ask/Deny rules and all other permissions are unchanged.") }
            if existing.state != .connected, proposal.row.commandLine?.automaticMCPProbe == true {
                let probe = await hostCommandRun(row: proposal.row, contact: existing,
                    message: AgentHostDirectory.probeText(appName: Self.appDisplayName),
                    session: nil, store: store, surface: surface, probe: true)
                let settled = (try? store.list().first { $0.id == existing.id }) ?? existing
                let peers = (try? store.list()) ?? []
                let state = Self.currentPeerState(settled, peers: peers)
                value["contact"] = Self.peerProjection(settled, peers: peers)
                value["state"] = .string(state.rawValue)
                value["status"] = .string(state == .connected ? "connected" : "configured")
                value["detail"] = .string(state == .connected ? state.detail : Self.probeReason(probe))
                Self.includeConnectionProbe(probe, in: &value)
            }
            return .object(value)
        }
        if proposal.row.acp != nil {
            let version = try await proposal.executable?.reportedVersion()
            proposal.executable?.version = version
            // The person already answered this named connect in chat (or Full Mac
            // allows it): a second card here is filed where the chat never shows
            // it, and the first live drive waited on it unseen for fifteen
            // minutes. Ask here only when no one has been asked yet.
            if !AgentHostConnection.personApproved {
                guard try await AgentACPApproval.connect(proposal, appName: Self.appDisplayName,
                    inbox: SwiftNativeApprovalInbox(root: dataRoot)) else {
                    return .object(["status": .string("denied"), "changed": .bool(false), "completed": .bool(false)])
                }
            }
        } else if proposal.executablePath != executablePath {
            throw AgentCommunicationError.invalid("The agent executable changed since the approval card. Ask to connect again; nothing ran or changed.")
        }
        let result = try AgentHostConnection.connect(proposal: proposal, store: store)
        let row = proposal.row
        if row.format == .shellEnvironment {
            return Self.environmentSetupResult(proposal: proposal, contact: result.contact, peers: try store.list(), changed: true)
        }
        if row.acp != nil {
            return .object(["status": .string("configured"), "contact": Self.peerProjection(result.contact, peers: (try? store.list()) ?? []),
                "changed": .bool(true), "completed": .bool(false),
                "detail": .string("Saved this connection with its own key. Its settings were not changed. Send a message to check that it can answer; setup alone does not prove that.")])
        }
        // PROVE THE ROUND TRIP WHERE THAT IS POSSIBLE. The entry is written and
        // approved; a host with a command line now gets one fixed probe asking
        // it to answer through that entry. The contact turns connected only
        // when the inbound request carrying this connection's key actually
        // arrives — not because the probe returned, and never on a handshake.
        var probe: JSONValue?
        if row.commandLine?.automaticMCPProbe == true {
            probe = await hostCommandRun(
                row: row, contact: result.contact,
                message: AgentHostDirectory.probeText(appName: Self.appDisplayName),
                session: nil, store: store, surface: surface, probe: true)
        }
        let settled = (try? store.list().first { $0.id == result.contact.id }) ?? result.contact
        // The probe's own reply is the CLI talking back on its command line.
        // Only an inbound request through the entry proves the entry works, so
        // the connect state is read back from the contact, never from the run.
        let state = Self.currentPeerState(settled, peers: (try? store.list()) ?? [])
        var value: [String: JSONValue] = [
            "status": .string(state == .connected ? "connected" : "configured"),
            "contact": Self.peerProjection(settled, peers: (try? store.list()) ?? []),
            "state": .string(state.rawValue), "state_detail": .string(state == .unavailable ? state.detail : row.commandLine == nil ? "tools connected; cannot initiate yet" : state.detail),
            "config_path": .string(result.outcome.path),
            "entry": .string(AgentHostDirectory.entryName),
            "restart_required": .bool(row.restartRequired),
            "detail": .string(
                "Wrote one entry into \(row.displayName)'s own settings and kept a timestamped backup beside the file. "
                + "This connection has its own key; it is not elevated and nothing was restarted. "
                + (row.restartRequired
                   ? "\(row.displayName) may need a restart before it picks the entry up — restart it yourself; nothing of its window is opened or read. "
                   : "")
                + (state == .connected
                   ? "The executable answered a request; the contact carries the scope and time of that proof."
                   : row.commandLine != nil
                     ? "The probe did not come back through the entry, so this stays set up: an entry that exists proves only that it was written. " + Self.probeReason(probe)
                     : "Set up is not connected: this one turns connected when its first message arrives through the entry.")),
        ]
        if let probe { Self.includeConnectionProbe(probe, in: &value) }
        if row.commandLine?.automaticMCPProbe == false, state != .connected {
            value["detail"] = .string(Self.directCommandSetupDetail)
        }
        if let backup = result.outcome.backupPath { value["backup_path"] = .string(backup) }
        return .object(value)
    }

    private static let directCommandSetupDetail = "Connection saved with permission for only its two MCP messaging tools. Send an ordinary message with agent_message; the command returns its answer directly, and its conversation_id continues that conversation. No automatic callback was attempted. The separate MCP return path remains unverified until a message arrives through it."

    private static func environmentSetupResult(proposal: AgentHostConnection.Proposal, contact: AgentPeerContact,
                                               peers: [AgentPeerContact], changed: Bool, repaired: Bool = false) -> JSONValue {
        let prefix = "set -a && . " + AgentHostDirectory.shellQuoted(proposal.row.expandedConfigPath)
            + " && set +a && " + AgentHostDirectory.shellQuoted(proposal.command)
        let message = prefix + " message \"hello\""
        let reply = prefix + " reply --session '<session_id>' --request '<request_id>'"
        let state = currentPeerState(contact, peers: peers)
        return .object(["status": .string(repaired ? "repaired" : changed ? "configured" : "already_configured"),
            "contact": peerProjection(contact, peers: peers), "changed": .bool(changed),
            "state": .string(state.rawValue), "state_detail": .string(proposal.row.description),
            "env_file": .string(proposal.row.expandedConfigPath), "outbound_route": .string("chatgpt-dot-ipc"),
            "message_command": .string(message), "reply_command": .string(reply), "restart_required": .bool(false),
            "detail": .string("\(repaired ? "Repaired" : changed ? "Created" : "Already configured") ChatGPT Dot with its own scoped key and private (0600) environment file. No ChatGPT settings were edited. NativeAgent can message Dot in-house after a read-only route check.\nGive Dot this exact command:\n\(message)\nIf the answer is enqueued, use the session_id and request_id returned by that command:\n\(reply)\nKeep the same --session to continue the conversation. Read enqueued answers with reply; do not resend the message.")])
    }

    private func hostDisconnect(name: String, store: AgentPeerStore) async throws -> JSONValue {
        guard usesCanonicalBody else {
            throw AgentCommunicationError.invalid("changing another agent's settings is unavailable outside the canonical app")
        }
        // 2026-09-22 WHY: a disconnect of "Grok" matched Grok Bot by name and
        // revoked its keys. Only the exact peer id from agent_contacts removes.
        guard let contact = try store.list().first(where: { "peer:" + $0.id == name }) else {
            return .object(["status": .string("not_configured"), "requested": .string(name),
                            "changed": .bool(false),
                            "detail": .string("Disconnect needs the exact peer:<id> from agent_contacts. Nothing was changed.")])
        }
        let outcome: AgentHostConfigWriter.Outcome?
        if contact.transport == .grokBot {
            try store.updateGrok(contact.id, allowDisconnected: true) { revoked in
                if revoked.grokBootstrapConfirmed == nil {
                    revoked.grokBootstrapConfirmed = ["secure-paste", "set up"].contains(revoked.grokSetup ?? "")
                }
                try GrokLinkCredential.delete(peer: contact.id)
                try AgentPeerCredentials.delete(peerID: contact.id)
                revoked.grokSetup = "disconnected"
            }
            return .object(["status": .string("grok_disconnect"), "peer_id": .string(contact.id)])
        }
        if contact.transport == .mcpHost {
            outcome = try AgentHostConnection.disconnect(contact: contact, store: store)
        } else {
            try AgentPeerCredentials.delete(peerID: contact.id)
            _ = try store.remove(contact.id)
            await AgentACPConnections.shared.revoke(peer: contact.id)
            outcome = nil
        }
        var value: [String: JSONValue] = ["status": .string("disconnected"), "changed": .bool(true),
            "detail": .string(contact.transport == .mcpHost
                ? "Removed exactly this app's entry, revoked that connection's key, and forgot the contact. Everything else in that file is unchanged."
                : "Removed the contact and its saved key. No other app's settings were changed.")]
        if AgentPeerStore.hostRowID(contact.endpoint).flatMap({ AgentHostDirectory.row(named: $0)?.format }) == .shellEnvironment {
            value["detail"] = .string("Deleted this contact's environment file, revoked its scoped key and removed ChatGPT Dot. No ChatGPT settings were changed.")
        }
        if let outcome {
            value["config_path"] = .string(outcome.path)
            if let backup = outcome.backupPath { value["backup_path"] = .string(backup) }
        }
        return .object(value)
    }

    // MARK: - One verb, one adapter: run the other agent's command line

    /// The installed program, approved in place of the one pinned at connect
    /// when it moved (Cursor's version folders) or changed (Hermes in place).
    private static func followACPUpdate(_ contact: AgentPeerContact, executable: String, store: AgentPeerStore) async -> AgentPeerContact {
        guard let installed = AgentHostCommandLines.resolveExecutable(executable) else { return contact }
        let path = URL(fileURLWithPath: installed).standardizedFileURL.resolvingSymlinksInPath().path
        if let approved = contact.approvedACPExecutable, approved.path == path, approved.isCurrent { return contact }
        // Its version, for the startup check (startupBlocker) and the contact's version note.
        let version = try? await AgentACPExecutable.capture(path: path).reportedVersion()
        guard (try? store.approveExecutable(peerID: contact.id, path: path, version: version)) == true else { return contact }
        return (try? store.list())?.first { $0.id == contact.id } ?? contact
    }

    private func hostACPRun(contact: AgentPeerContact, message: String, conversationID: String?, store: AgentPeerStore,
                            surface: String) async throws -> JSONValue {
        guard usesCanonicalBody, await fullMacToolAccess(surface: surface).fileOpsAllowed else {
            return builderFullMacRequired(tool: "agent_message")
        }
        guard let id = AgentPeerStore.hostRowID(contact.endpoint),
              let line = AgentHostDirectory.row(named: id)?.acp,
              let link = AgentHostDirectory.linkCommandPath(),
              let secret = try AgentPeerCredentials.read(peerID: contact.id) else {
            return .object(["status": .string("unavailable"), "sent": .bool(false), "completed": .bool(false),
                "detail": .string("This connection cannot start. Check the other agent's installation and reconnect it.")])
        }
        let origin = SecurityOriginContext.currentTurn(
            verifiedSessionId: ChatToolSessionContext.verifiedSessionId, surface: surface)
        let launchPermission = await SwiftNativeSecurityCenter(dataRoot: dataRoot)
            .drivenAgentLaunchPermission(tool: "agent_message", origin: origin)
        // Full Mac follows updates, as drivenAgentLaunch does for command
        // contacts: the version installed now is approved here, so an update
        // never needs a reconnect and never runs the old build.
        let current = launchPermission == .fullMac
            ? await Self.followACPUpdate(contact, executable: line.executable, store: store) : contact
        guard let approved = current.approvedACPExecutable, approved.isCurrent else {
            await AgentACPConnections.shared.revoke(peer: contact.id)
            // 2026-09-22 WHY: awaiting a renewal card here held the turn (756s
            // once) and never changed the reply; reconnecting raises the card.
            return .object(["status": .string("reconnect_required"), "sent": .bool(false), "completed": .bool(false),
                "detail": .string("The approved program is missing, changed, or was never bound to this contact. Reconnect this agent to approve it. Nothing ran; the message was not resent.")])
        }
        if let blocker = line.startupBlocker(installedVersion: approved.version) {
            await AgentACPConnections.shared.revoke(peer: contact.id)
            store.recordUnavailable(peerID: contact.id)
            return .object(["status": .string("unavailable"), "sent": .bool(false), "completed": .bool(false),
                "reason": .string("incompatible_sandboxed_acp"), "detail": .string(blocker)])
        }
        let executable = approved.path
        guard let folder = contact.acpWorkingDirectory else {
            return .object(["status": .string("reconnect_required"), "completed": .bool(false),
                "detail": .string("Reconnect this agent to approve its starting folder.")])
        }
        let directory = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let environment: [String: String] = [
            AgentHostDirectory.peerIDVariable: contact.id,
            AgentHostDirectory.peerSecretVariable: secret,
            AgentHostDirectory.bridgeDescriptorVariable: AgentHostDirectory.bridgeDescriptorPath(dataRoot: dataRoot)]
        let server: JSONValue = .object(["name": .string(AgentHostDirectory.entryName), "command": .string(link),
            "args": .array([.string("mcp")]),
            "env": .array(environment.sorted { $0.key < $1.key }.map {
                .object(["name": .string($0.key), "value": .string($0.value)])
            })])
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        if case .denied(let reason) = launchPermission {
            await AgentACPConnections.shared.revoke(peer: contact.id)
            return .object(["status": .string("failed"), "reason": .string("launch_blocked"),
                "sent": .bool(false), "completed": .bool(false), "detail": .string("Nothing was launched: \(reason).")])
        }
        let sandbox: BuilderShellSandboxMode = launchPermission == .fullMac
            ? .off : await Self.builderShellSandboxMode(dataRoot: dataRoot)
        guard sandbox != .lockedDown else {
            await AgentACPConnections.shared.revoke(peer: contact.id)
            return .object(["status": .string("unavailable"), "sent": .bool(false), "completed": .bool(false),
                "detail": .string("Running another agent is turned off in the current permission settings.")])
        }
        let unrestricted = launchPermission == .fullMac
        let program = unrestricted ? executable : "/usr/bin/sandbox-exec"
        // 2026-09-22: the peer never reads the main bridge bearer; its link
        // uses the url-only descriptor outside this directory.
        let bridgeDir = Self.sbplEscapeLiteral(AgentHostDirectory.bridgeDiscoveryDirectory(dataRoot: dataRoot)
            .standardizedFileURL.resolvingSymlinksInPath().path)
        let arguments = unrestricted ? line.arguments : ["-p",
            (sandbox == .developerFullMac ? Self.builderDeveloperSandboxProfile(dataRoot: dataRoot)
                : Self.builderSandboxProfile(dataRoot: dataRoot))
                + "\n(deny file-read* (subpath \"\(bridgeDir)\"))", executable] + line.arguments
        let approvalContext = AgentACPApproval.Context.current
        let decidedSessionID = ChatToolSessionContext.verifiedSessionId
        let childEnvironment = AgentHostCommandLines.scrubbedEnvironment().merging(line.environment) { _, fixed in fixed }
        // The program's identity, not just its path: an in-place update starts a new process.
        let configuration = try JSONValue.object([
            "program": .string(program), "executable": .string("\(approved.path)\n\(approved.inode)\n\(approved.digest)"),
            "arguments": .array(arguments.map(JSONValue.string)),
            "folder": .string(folder), "server": server,
            "environment": .object(childEnvironment.mapValues(JSONValue.string))
        ]).serialize(pretty: false)
        var lease: AgentACPConnections.Lease?
        do {
            let acquired = try await AgentACPConnections.shared.acquire(peer: contact.id, conversation: conversationID, configuration: configuration)
            lease = acquired
            let reply = try await acquired.client.turn(
                executable: program, arguments: arguments,
                directory: directory, environment: childEnvironment,
                message: message, peerCredential: secret, mcpServers: [server], permissionMode: line.permissionMode,
                conversationID: conversationID,
                approvedExecutable: approved, keepAlive: true, requireVerifiedRestore: id == "hermes", permission: { request in
                    // Revocation wins even if an already-open card was approved.
                    guard try store.list().contains(where: { $0.id == contact.id }) else { return false }
                    // User 10-01: under Full Mac what an agent she drives asks
                    // for is her call, as for Codex and Claude; no card. A
                    // delete stays the person's (irreversible loss).
                    var kind = "other"
                    if case .object(let params) = request, case .object(let call)? = params["toolCall"],
                       case .string(let value)? = call["kind"], !value.isEmpty { kind = value }
                    let allowed: Bool
                    let currentPermission = await SwiftNativeSecurityCenter(dataRoot: self.dataRoot)
                        .drivenAgentLaunchPermission(tool: "agent_message", origin: origin)
                    if case .denied = currentPermission { return false }
                    let automaticallyAllowed = kind != "delete" && launchPermission == .fullMac && currentPermission == .fullMac
                    if automaticallyAllowed {
                        HarnessDecidedRow.post(requester: contact.name, tool: kind,
                                                     sessionID: decidedSessionID, dataRoot: self.dataRoot)
                        allowed = true
                    } else {
                        allowed = try await AgentACPApproval.request(request, peer: contact, context: approvalContext,
                                                                     dataRoot: self.dataRoot, inbox: inbox)
                    }
                    let stillConnected = try store.list().contains(where: { $0.id == contact.id })
                    let permissionAfterResponse = await SwiftNativeSecurityCenter(dataRoot: self.dataRoot)
                        .drivenAgentLaunchPermission(tool: "agent_message", origin: origin)
                    if case .denied = permissionAfterResponse { return false }
                    return allowed && stillConnected && (!automaticallyAllowed || permissionAfterResponse == .fullMac)
                }, update: Self.acpLiveUpdate(AgentConversationLiveContext.target))
            // A cancelled turn (agent_cancel's session/cancel) keeps its session:
            // ACP ends the prompt and the conversation continues from there.
            guard await AgentACPConnections.shared.finish(acquired, peer: contact.id, conversation: reply.sessionID) else { throw AgentACPClient.Failure.interrupted }
            lease = nil
            store.recordProof(peerID: contact.id, inbound: reply.completed && !reply.text.isEmpty, outbound: true)
            if reply.completed && !reply.text.isEmpty {
                store.recordRoundTrip(peerID: contact.id, executable: approved.path,
                    version: approved.version, workspace: directory.path)
            } else if reply.stopReason != "cancelled" {
                store.recordUnavailable(peerID: contact.id)
            }
            var result: [String: JSONValue] = ["status": .string(reply.completed ? "replied" : reply.stopReason),
                "agent": .string("peer:" + contact.id), "transport": .string("acp"),
                "conversation_id": .string(reply.sessionID), "continued": .bool(reply.continued),
                "sent": .bool(true), "completed": .bool(reply.completed), "reply": .string(reply.text),
                "untrusted_remote_data": .bool(!reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)]
            if let detail = reply.detail { result["detail"] = .string(detail) }
            return Self.peerRedact(.object(result), token: secret)
        } catch AgentACPClient.Failure.executableChanged {
            if let lease { await AgentACPConnections.shared.finish(lease, peer: contact.id, conversation: nil) }
            store.recordUnavailable(peerID: contact.id)
            return .object(["status": .string("reconnect_required"), "sent": .bool(false), "completed": .bool(false),
                "detail": .string("The program changed before launch. Reconnect this agent to approve it. Nothing ran; the message was not resent.")])
        } catch {
            // The session it already has, so an uncertain turn can be resumed, not orphaned.
            let opened = await lease?.client.currentSessionID
            let session = conversationID ?? opened
            if let lease { await AgentACPConnections.shared.finish(lease, peer: contact.id, conversation: nil) }
            if let failure = error as? AgentACPClient.Failure, failure == .sessionUnavailable || failure == .busy {
                return .object(["status": .string(failure == .busy ? "busy" : "session_unavailable"), "sent": .bool(false), "completed": .bool(false), "detail": .string(failure.localizedDescription)])
            }
            // Cut off mid-reply (her app quitting, a cancel) says nothing about
            // whether the agent can start; marking it unavailable hid a working
            // Cursor after a restart (User 09-27).
            let cutOff = (error as? AgentACPClient.Failure) == .interrupted || error is CancellationError || Task.isCancelled
            if !cutOff { store.recordUnavailable(peerID: contact.id) }
            if var result = AgentACPClient.startupTimeoutReceipt(error) {
                result["agent"] = .string("peer:" + contact.id)
                result["transport"] = .string("acp")
                return .object(result)
            }
            if let failure = ProviderFailure.report(error, work: .outcomeUnknown) {
                var result: [String: JSONValue] = ["agent": .string("peer:" + contact.id), "transport": .string("acp")]
                Self.peerFailure(failure, into: &result)
                if let session { result["conversation_id"] = .string(session) }
                return Self.peerRedact(.object(result), token: secret)
            }
            var result: [String: JSONValue] = ["status": .string(Task.isCancelled ? "cancelled" : "outcome_unknown"),
                "agent": .string("peer:" + contact.id), "transport": .string("acp"), "completed": .bool(false),
                "detail": .string(Task.isCancelled ? "The conversation was stopped." :
                    (error as? AgentACPClient.Failure)?.localizedDescription ?? "The conversation did not finish. Do not resend automatically.")]
            if let session { result["conversation_id"] = .string(session) }
            return .object(result)
        }
    }

    /// ACP `session/update` carries scrubbed reply snapshots, tool calls and
    /// plans as progress notes, and the rest as activity.
    static func acpLiveUpdate(_ target: AgentConversationLiveTarget?) -> @Sendable (JSONValue) async -> Void {
        guard let target else { return { _ in } }
        return { event in
            let hub = AgentConversationLiveHub.shared
            guard case .object(let update) = event, case .string(let kind)? = update["sessionUpdate"] else { return }
            switch kind {
            case "agent_message_chunk":
                if case .object(let content)? = update["content"], content["type"] == .string("text"),
                   case .string(let text)? = content["text"] { await hub.text(target, replace: text) }
            case "tool_call":
                if case .string(let title)? = update["title"] { await hub.note(target, title) } else { await hub.activity(target) }
            case "plan":
                var steps: [[String: JSONValue]] = []
                if case .array(let entries)? = update["entries"] {
                    steps = entries.compactMap { if case .object(let step) = $0 { step } else { nil } }
                }
                let current = steps.first { $0["status"] == .string("in_progress") } ?? steps.first { $0["status"] == .string("pending") }
                if case .string(let step)? = current?["content"] { await hub.note(target, "Plan: " + step) } else { await hub.activity(target) }
            default: await hub.activity(target)
            }
        }
    }

    /// agent_cancel's lane owner: the other side's own stop for a reply in
    /// flight. "stopping"/"stopped" when asked; "cannot_stop" when the route has
    /// none; "not_here" when only this app's own in-flight send could be
    /// stopped, which the conversation layer does by cancelling that send.
    private func agentCancel(_ args: [String: JSONValue], store: AgentPeerStore) async throws -> JSONValue {
        try Self.peerKeys(args, allowed: ["agent", "conversation_id", "message_id", "task_id"])
        let agent = try Self.peerString(args, "agent", max: 64)!
        func answer(_ status: String, _ detail: String = "") -> JSONValue {
            .object(["status": .string(status), "agent": .string(agent), "detail": .string(detail)])
        }
        if ["codex", "omp"].contains(agent) {
            guard let message = try Self.peerString(args, "message_id", max: 160, required: false) else {
                return answer("cannot_stop", "No accepted message is recorded for this reply, so there is nothing exact to stop.")
            }
            return await builtInStop(agent: agent, messageID: message)
        }
        guard agent.hasPrefix("peer:"), let peer = try store.list().first(where: { "peer:" + $0.id == agent }) else {
            return answer("not_here")
        }
        switch peer.transport {
        case .acp:
            let conversation = try Self.peerString(args, "conversation_id", max: 1024, required: false)
            guard await AgentACPConnections.shared.cancelTurn(peer: peer.id, conversation: conversation) else { return answer("not_here") }
            return answer("stopping", "Asked \(peer.name) to stop (ACP session/cancel). Its turn ends as cancelled and the session stays open for your next message.")
        case .a2a:
            guard let task = try Self.peerString(args, "task_id", max: 512, required: false) else { return answer("not_here") }
            return await a2aCancel(peer: peer, task: task, agent: agent)
        case .desktop, .desktopChat, .grokBot:
            return answer("cannot_stop", "\(peer.name) has no stop from here; its answer still arrives.")
        default:
            // A command-line host or another NativeAgent: only the send this app is running.
            return answer("not_here")
        }
    }

    /// A2A CancelTask on the exact task the conversation is waiting on.
    private func a2aCancel(peer: AgentPeerContact, task: String, agent: String) async -> JSONValue {
        var token: String?
        func answer(_ status: String, _ detail: String, task result: JSONValue? = nil, peerAuthored: Bool = false) -> JSONValue {
            var fields: [String: JSONValue] = ["status": .string(status), "agent": .string(agent), "detail": .string(detail), "task_id": .string(task)]
            if let result { fields["task"] = result }
            if peerAuthored { fields["untrusted_remote_data"] = .bool(true) }
            return Self.peerRedact(.object(fields), token: token)
        }
        do {
            guard peer.credentialKey == nil || usesCanonicalBody else { return answer("cannot_stop", "This contact's credential is unavailable here, so no stop was sent.") }
            token = peer.credentialKey == nil ? nil : try AgentPeerCredentials.read(peerID: peer.id)
            let card = try await AgentPeerHTTP.get(peer.endpoint, bearerToken: token)
            guard (200..<300).contains(card.statusCode), let json = card.json else {
                return answer("cannot_stop", "\(peer.name)'s agent card did not load (HTTP \(card.statusCode)), so no stop was sent; its reply may still arrive.")
            }
            let selected = try await AgentPeerDiscovery.authenticatedInterface(card: json, cardURL: peer.endpoint, bearerToken: token)
            try Self.peerAuthorizeInterface(selected, cardURL: peer.endpoint, hasCredential: token != nil)
            let request = try AgentA2AWire.cancelRequest(taskID: task, interface: selected)
            let response = try await AgentPeerHTTP.send(request, bearerToken: token)
            guard (200..<300).contains(response.statusCode), let payload = response.json else {
                return answer("cannot_stop", "\(peer.name) did not accept the stop (HTTP \(response.statusCode)); its reply may still arrive.")
            }
            let result = try AgentA2AWire.normalizeResponse(payload, interface: selected,
                                                            expectedRequestID: request.requestID, expectedTaskID: task)
            let summary: JSONValue = .object(["state": .string(result.state), "terminal": .bool(result.terminal)])
            if result.state == "canceled" { return answer("stopped", "\(peer.name) cancelled the task.", task: summary) }
            if result.terminal { return answer("cannot_stop", "The task had already ended (\(result.state)) before the stop.", task: summary) }
            return answer("stopping", "\(peer.name) accepted the stop; the task is \(result.state) and settles when it ends.", task: summary)
        } catch AgentA2AWire.WireError.remote(let code, let message) {
            return answer("cannot_stop", "\(peer.name) refused the stop (\(code): \(message)); its reply may still arrive.", peerAuthored: true)
        } catch {
            return answer("cannot_stop", "The stop could not be sent: \(error.localizedDescription). The reply may still arrive.", peerAuthored: true)
        }
    }

    /// Codex: app-server `turn/interrupt` on the exact turn. OMP: its wake run
    /// is interrupted (SIGINT, then SIGTERM), so the runner itself records how
    /// it ended and the answer path settles as usual.
    private func builtInStop(agent: String, messageID: String) async -> JSONValue {
        func answer(_ status: String, _ detail: String) -> JSONValue {
            .object(["status": .string(status), "agent": .string(agent), "message_id": .string(messageID), "detail": .string(detail)])
        }
        let name = agent == "omp" ? "OMP" : "Codex"
        if agent == "codex" {
            let job = DelegationStatusProjector(configRoot: agentBridgeConfigRoot)
                .readSnapshot(now: Date(), limit: 1, offset: 0, agent: "codex", messageID: messageID).jobs.first
            if job?.stallBasis == .terminal { return answer("cannot_stop", "Codex already finished that turn; its answer is on the way.") }
            guard let thread = job?.recordedThreadID, let turn = job?.recordedTurnID,
                  let helper = AgentBridgeRuntime.codexHelperURL(override: codexMessageWakeupHelperOverride, dataRoot: dataRoot),
                  let input = try? JSONValue.object(["interrupt": .bool(true), "threadId": .string(thread), "turnId": .string(turn)]).serializedData(pretty: false) else {
                return answer("cannot_stop", "Codex has not started a turn for it yet (it is queued behind other Codex work), so there is no turn to interrupt.")
            }
            let cwd = Self.builderSourceRepoRoot(dataRoot: dataRoot) ?? NativeAgentWorkspaceRoot.resolve(dataRoot: dataRoot)
            let receipt = await runAgentWakeupHelper(helper: helper, inputData: input, cwd: cwd, cli: "codex", variable: "CODEX_BIN",
                                                     timeout: Self.codexWakeupHelperTimeoutSeconds())
            guard case .object(let fields) = receipt, fields["status"] == .string("interrupted") else {
                let why: String = if case .object(let fields) = receipt, case .string(let text)? = fields["error"] ?? fields["reason"] { text } else { "no receipt" }
                return answer("cannot_stop", "Codex did not take the interrupt (\(why)); its reply may still arrive.")
            }
            return answer("stopping", "Asked Codex to interrupt its turn (turn/interrupt); the conversation settles when the turn ends.")
        }
        let directory = Self.bridgeConfigDirectory(named: "omp-bridge", configRootOverride: agentBridgeConfigRoot)
        let safe = String(messageID.map { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII || "._-".contains($0) ? $0 : "_" }.prefix(160))
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("wake-jobs/" + safe + ".json")),
              case .object(let job)? = try? JSONValue.parse(data) else {
            return answer("cannot_stop", "No wake run is recorded for that message, so there is nothing to interrupt.")
        }
        let state: String = if case .string(let value)? = job["state"] { value } else { "" }
        guard state == "running" else {
            return answer("cannot_stop", ["settled", "delivering"].contains(state)
                ? "\(name) already finished that run; its answer is on the way."
                : "\(name) has not started that run yet (\(state.isEmpty ? "unknown" : state)), so there is nothing to interrupt.")
        }
        // The runner recorded its own start identity (wake_worker_common's
        // processStartIdentity: ps lstart+command, hashed). A reused pid, even
        // another run of the same helper, never matches it.
        guard case .int(let number)? = job["runnerPid"], let pid = Int32(exactly: number), pid > 1,
              case .string(let recorded)? = job["runnerIdentity"], !recorded.isEmpty else {
            return answer("cannot_stop", "\(name)'s run did not record its process identity, so it is not safe to interrupt from here.")
        }
        guard Self.processStartIdentity(pid) == recorded else {
            return answer("cannot_stop", "\(name)'s run is no longer live on this Mac, so there is nothing to interrupt.")
        }
        // Only the run's own children (the agent CLI), never the runner: it
        // records the interrupted exit and settles the job like any other end.
        let tree = ProcessTreeReaper.snapshot(rootPID: pid)
        let children = ProcessTreeSnapshot(rootPID: pid, rootIdentity: nil, descendants: tree.descendants)
        guard !children.descendants.isEmpty else {
            return answer("cannot_stop", "\(name)'s run has no agent process to interrupt right now.")
        }
        Self.interruptThenTerminate(children)
        return answer("stopping", "Interrupted \(name)'s run (SIGINT, then SIGTERM if it keeps going); the conversation settles when the run records its end.")
    }

    /// The same identity the wake runners record for themselves:
    /// sha256 hex of `ps -p <pid> -o lstart=,command=`, trimmed.
    static func processStartIdentity(_ pid: Int32) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "lstart=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !text.isEmpty else { return nil }
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A MESSAGE GOES OUT AND A MESSAGE COMES BACK, IN THE SAME CALL.
    ///
    /// The only command-line adapter there is. It reads the row — executable
    /// name, argument template, whether the CLI documents a resume flag — and
    /// nothing here branches on which agent that row describes. The run is an
    /// ordinary command on this Mac and takes the ordinary path for one: the
    /// same Full Mac file_ops gate as `shell`, the same sandbox-profiled
    /// runner, the same audit receipt. No new authority, and the person's
    /// trust posture decides exactly as it does for any shell command.
    ///
    /// Its working directory is a fresh empty directory of its own, stdin is
    /// closed so nothing can block waiting for a person, and the reply is the
    /// CLI's own output — untrusted remote data, marked so, like every other
    /// transport here.
    private func hostCommandRun(
        row: AgentHostRow, contact: AgentPeerContact, message: String, session: String?,
        resuming: Bool = false, store: AgentPeerStore, surface: String, probe: Bool = false
    ) async -> JSONValue {
        guard let line = row.commandLine else { return Self.hostNoCommandLine(row: row, contact: contact, peers: (try? store.list()) ?? []) }
        let access = await fullMacToolAccess(surface: surface)
        guard access.fileOpsAllowed else {
            let refusal = builderFullMacRequired(tool: "agent_message")
            var value: [String: JSONValue] = [:]
            if case .object(let fields) = refusal { value = fields }
            if value["status"] == .string("failed") {
                value["status"] = .string("blocked_by_trust")
            }
            let mode = access.permissionLevel == "balanced" ? "Work mode" : "the current trust mode"
            value["reason"] = .string("trust_center_full_mac_required")
            value["sent"] = .bool(false)
            value["ran"] = .bool(false)
            value["completed"] = .bool(false)
            value["detail"] = .string(probe
                ? "The entry is written, but I couldn't check the link in \(mode) because running that agent here needs Builder or Full Mac; switch in Trust or the composer and say connect again, or use the connection from the other agent's side."
                : "I didn't send the message in \(mode) because running that agent here needs Builder or Full Mac; switch in Trust or the composer and ask me to send it again, or use the connection from the other agent's side.")
            if probe {
                value["connection_check"] = .bool(true)
                value["connection_reply_received"] = .bool(false)
            }
            return .object(value)
        }
        let agent = "peer:" + contact.id
        func honest(_ status: String, _ detail: String) -> JSONValue {
            store.recordUnavailable(peerID: contact.id)
            let state = Self.currentPeerState(contact, peers: (try? store.list()) ?? [])
            return .object(["status": .string(status), "agent": .string(agent), "transport": .string("mcpHost"),
                     "host": .string(row.id), "state": .string(state.rawValue),
                     "state_detail": .string(state.detail),
                     "sent": .bool(false), "completed": .bool(false), "detail": .string(detail)])
        }
        // A CLI that takes permission flags gets this request's launch
        // decision explicitly; a Full Mac run uses the approved file itself
        // (and approves the version installed now, so updates need no reconnect).
        var launch: DrivenAgentLaunch?
        var launchArguments: [String] = []
        if let flags = line.permissionFlags {
            let decided = await Self.drivenAgentLaunch(tool: "agent_message", surface: surface, contact: contact,
                                                       name: row.displayName, dataRoot: dataRoot)
            if let denied = decided.deniedResult { return denied }
            launch = decided
            launchArguments = decided.permission.arguments(flags)
        }
        let approved = (try? store.list())?.first { $0.id == contact.id }?.approvedExecutablePath ?? contact.approvedExecutablePath
        guard let approvedPath = approved,
              approvedPath == AgentHostCommandLines.resolveExecutable(line.executable) else {
            return honest("unavailable",
                "\(row.displayName)'s executable is missing, changed, or was never approved. Reconnect with an approval card showing its exact path. Nothing ran.")
        }
        let executable = launch?.executable ?? approvedPath
        // ONE directory per agent, inside the workspace the command runner
        // already confines writes to. It was a fresh one per message until the
        // Codex drive: Codex records every directory it runs in as a trusted
        // project in its own settings, so each message left a line behind there.
        let workingDirectory = contact.hostWorkspace.map { URL(fileURLWithPath: $0) }
            ?? Self.builderWorkspaceRoot(dataRoot: dataRoot).appendingPathComponent("agent-bridge-runs/" + row.id)
        guard (try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])) != nil else {
            return honest("unavailable", "A working directory for the run could not be created. Nothing ran.")
        }
        // The reply file is this run's alone, so two messages at once never read each other's.
        let replyDirectory = workingDirectory.appendingPathComponent(UUID().uuidString.lowercased())
        try? FileManager.default.createDirectory(at: replyDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: replyDirectory) }
        let replyFile = line.replyFileName.map { replyDirectory.appendingPathComponent($0).path }
        let probeNonce: String?
        do {
            probeNonce = probe ? try store.beginConnectionProbe(peerID: contact.id, timeout: TimeInterval(line.timeoutSeconds)) : nil
        } catch {
            return honest("unavailable", "The connection check could not be recorded. Nothing ran.")
        }
        defer {
            if let probeNonce {
                _ = store.finishConnectionProbe(peerID: contact.id, nonce: probeNonce, ran: false,
                    workspace: workingDirectory.path)
            }
        }
        let outgoing = probeNonce.map { AgentHostDirectory.probeText(appName: Self.appDisplayName, nonce: $0) } ?? message
        let argv = launchArguments + line.argv(message: outgoing, session: session, resuming: resuming, replyFilePath: replyFile)
        // A streaming CLI's lines go to the live view in order as they come,
        // while only final reply/identity events are retained for exit (the
        // runner's ordinary stdout envelope is clipped for display).
        let (lines, linesIn) = AsyncStream<String>.makeStream()
        let streamed: Task<String, Never>? = line.stream.map { _ in
            let live = AgentConversationLiveContext.target
            return Task { [line] in
                let hub = AgentConversationLiveHub.shared
                var whole = "", active = false, overflow = false
                var retainedBytes = 0
                for await text in lines {
                    if line.isResultLine(text), !overflow {
                        retainedBytes += text.utf8.count + 1
                        if retainedBytes <= 16 * 1024 * 1024 { whole += text + "\n" }
                        else { overflow = true; whole = "" }
                    }
                    guard let live, let event = line.streamEvent(line: text) else { continue }
                    if !active { await hub.activity(live); active = true }
                    switch event {
                    case .text(let chunk, whole: true): await hub.text(live, replace: chunk)
                    case .text(let chunk, whole: false): await hub.text(live, delta: chunk)
                    case .note(let note): await hub.note(live, note)
                    case .activity: break
                    }
                }
                return whole
            }
        }
        // The runner closes stdin. Pass the approved executable and argv directly.
        // The stdout handler's parameter and @Sendable-ness come from this
        // annotation, not inference through the nil ternary branch; the yield
        // result is intentionally discarded.
        let onStdoutLine: (@Sendable (String) -> Void)? = streamed == nil ? nil : { @Sendable in _ = linesIn.yield($0) }
        let outcome = await Self.runShellLikeProcess(
            toolName: "agent_message", executable: executable,
            args: argv,
            cwd: workingDirectory.path, timeoutSeconds: line.timeoutSeconds,
            sourcePayloadForAudit: probe ? AgentHostDirectory.probeToken : nil, dataRoot: dataRoot,
            // This app's own environment holds provider keys and the bridge
            // token; another agent's command gets a scrubbed one instead. And
            // nothing it backgrounds may outlive the run or its directory.
            environmentOverride: AgentHostCommandLines.scrubbedEnvironment(),
            closeStandardInput: true,
            reapDescendantsOnExit: true,
            interruptOnCancel: true,
            onStdoutLine: onStdoutLine)
        linesIn.finish()
        let streamedStdout = await streamed?.value
        guard case .object(var envelope) = outcome else { return outcome }
        if let streamedStdout { envelope["stdout"] = .string(streamedStdout) }
        var reply = ""
        var truncated = false
        if line.jsonResultReply, case .string(let text)? = envelope["stdout"] {
            let response = line.resultReply(stdout: text) ?? ""
            truncated = response.utf8.count > 64 * 1024
            reply = String(decoding: response.utf8.prefix(64 * 1024), as: UTF8.self)
        } else if let replyFile, let handle = FileHandle(forReadingAtPath: replyFile) {
            defer { try? handle.close() }
            // Bounded at the READ, not after it: a reply file is written by
            // another program and its size is that program's choice. One byte
            // past the cap is how we know to say so.
            let data = (try? handle.read(upToCount: 64 * 1024 + 1)) ?? Data()
            truncated = data.count > 64 * 1024
            reply = String(decoding: data.prefix(64 * 1024), as: UTF8.self)
        } else if !line.capturesThreadID, case .string(let text)? = envelope["stdout"] {
            reply = text
            truncated = envelope["_truncated"] == .bool(true)
        }
        reply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let ran = envelope["status"] == .string("completed")
        // THE ROUND TRIP, recorded where it happened: a message left and a
        // reply came back. Nothing short of that promotes the contact — and
        // the CONNECT PROBE is deliberately not counted as a reply arriving.
        // What the probe asks to be proven is the ENTRY, so only the inbound
        // request carrying this connection's key may promote it; the probe's
        // own stdout is the command line talking, which proves nothing about
        // the entry that was just written.
        let replied = ran && !reply.isEmpty
        // A run she stopped says nothing about whether the contact works.
        let arrived = envelope["status"] == .string("cancelled") ? false : Self.recordHostConnectionOutcome(store: store, contact: contact, ran: ran,
            replied: replied, probe: probe, probeNonce: probeNonce,
            executable: executable, workspace: workingDirectory.path)
        let settled = (try? store.list().first { $0.id == contact.id }) ?? contact
        let state = Self.currentPeerState(settled, peers: (try? store.list()) ?? [])
        var result: [String: JSONValue] = [
            "status": .string(replied ? "replied" : "outcome_unknown"),
            "agent": .string(agent), "transport": .string("mcpHost"), "host": .string(row.id),
            "state": .string(state.rawValue), "state_detail": .string(state.detail),
            "sent": .bool(ran), "completed": .bool(replied),
            "reply": .string(reply), "reply_truncated": .bool(truncated),
            "untrusted_remote_data": .bool(!reply.isEmpty),
            "exit_code": envelope["exit_code"] ?? .null, "timed_out": envelope["timed_out"] ?? .bool(false),
        ]
        if line.capturesThreadID {
            let stdout: String
            if case .string(let text)? = envelope["stdout"] { stdout = text } else { stdout = "" }
            if let confirmed = line.capturedThreadID(stdout: stdout, expected: resuming ? session : nil) {
                result["conversation_id"] = .string(confirmed)
                result["continuation_available"] = .bool(true)
            } else {
                result["continuation_available"] = .bool(false)
                result["continuation_detail"] = .string("The command did not confirm the expected conversation identity. Its reply is retained, but continuity is unverified. Do not resend automatically or silently start a replacement conversation.")
            }
        } else if let session { result["conversation_id"] = .string(session) }
        if probe {
            // A handshake proves the path; its words are not for her. Without them the
            // turn is not carrying another agent's text, so the person's own next
            // request in the same turn is still theirs (09-19 drive: "Codex asked for
            // this, not you" on a message the person had asked for).
            result["reply"] = nil
            result["reply_truncated"] = nil
            result["untrusted_remote_data"] = nil
            result["connection_check"] = .bool(true)
            result["connection_reply_received"] = .bool(arrived)
            if !arrived {
                result["detail"] = .string("No new answer arrived through the connection. The other app may need to restart before it can reply here.")
            }
        }
        if envelope["status"] == .string("cancelled") {
            // agent_cancel: interrupted at her request, not a failure of the contact.
            result["status"] = .string("cancelled")
            result["sent"] = .bool(true)
            result["detail"] = .string("Stopped at your request: \(row.displayName)'s run was interrupted. Anything it said before stopping is kept above; nothing was resent.")
        } else if !replied {
            result["detail"] = .string(
                "\(row.displayName)'s command line did not come back with a reply, so nothing is proven. "
                + "Its own output is in stderr. Do not resend automatically.")
            if case .string(let text)? = envelope["stderr"] { result["stderr"] = .string(text) }
            if case .string(let text)? = envelope["stderr"] {
                let cause = ProviderFailure.wire(text, fallback: .malformedResponse)
                if cause != .malformedResponse {
                    Self.peerFailure(.init(cause: cause, work: ran ? .outcomeUnknown : .nothingRan), into: &result)
                }
            }
        }
        result["untrusted_remote_data"] = .bool(PeerDataTaintDispatcher.containsPeerText(.object([
            "reply": result["reply"] ?? .null, "stderr": result["stderr"] ?? .null,
        ])))
        return Self.peerRedact(.object(result), token: nil)
    }

    /// A CLI reply proves that route; the MCP return path has separate evidence.
    static func recordHostConnectionOutcome(store: AgentPeerStore, contact: AgentPeerContact,
                                             ran: Bool, replied: Bool, probe: Bool,
                                             probeNonce: String? = nil,
                                             executable: String, workspace: String) -> Bool {
        store.recordProof(peerID: contact.id, outbound: ran)
        let arrived = probe && probeNonce.map {
            store.finishConnectionProbe(peerID: contact.id, nonce: $0, ran: ran, workspace: workspace)
        } == true
        if ran && replied && !probe {
            store.recordRoundTrip(peerID: contact.id, executable: executable, workspace: workspace)
        } else if !probe {
            store.recordUnavailable(peerID: contact.id)
        }
        return arrived
    }

    /// The probe's own reason, so "stays set up" is never a shrug: the command
    /// was missing, the run timed out, or it simply did not answer back.
    static func probeReason(_ probe: JSONValue?) -> String {
        guard case .object(let value)? = probe else { return "" }
        if value["reason"] == .string("trust_center_full_mac_required"),
           case .string(let detail)? = value["detail"] { return detail }
        if value["timed_out"] == .bool(true) { return "The probe ran past its time limit." }
        if case .string(let detail)? = value["detail"] { return detail }
        return "The probe ran and nothing arrived through the entry."
    }

    static func includeConnectionProbe(_ probe: JSONValue, in value: inout [String: JSONValue]) {
        value["probe"] = probe
        guard case .object(let fields) = probe,
              fields["reason"] == .string("trust_center_full_mac_required") else { return }
        value["reason"] = fields["reason"]
        value["completed"] = .bool(false)
        value["detail"] = .string(probeReason(probe))
        // A trust refusal says nothing about whether the other app needs a restart.
        value["restart_required"] = nil
    }

    /// A HOST WITH NO COMMAND LINE. Honest, and it never reaches for a window.
    static func hostNoCommandLine(row: AgentHostRow?, contact: AgentPeerContact, peers: [AgentPeerContact] = []) -> JSONValue {
        let state = currentPeerState(contact, peers: peers)
        return .object(["status": .string("no_outbound_route"), "agent": .string("peer:" + contact.id),
                 "transport": .string("mcpHost"), "host": .string(row?.id ?? ""),
                 "state": .string(state.rawValue), "state_detail": .string(state == .unavailable ? state.detail : row?.format == .shellEnvironment ? row!.description : "tools connected; cannot initiate yet"),
                 "outbound_route": .string(row?.outboundRoute ?? "none"),
                 "sent": .bool(false), "read": .bool(false), "completed": .bool(false),
                 "detail": .string(row?.format == .shellEnvironment ? row!.description : hostInboundOnlyDetail)])
    }

    /// One sentence of truth about a closed desktop app: this app can type into
    /// it, and the answer comes back through this app's own inbound door.
    static let desktopSetupNote = "Send-only. For this contact to answer, add this app's MCP server to it (command: nativeagent-link mcp) and have it reply with its agent_message tool; the reply arrives as an ordinary inbound message."
    static let desktopSendOnlyDetail = "Desktop contacts are send-only. Nothing was opened, focused or read. " + desktopSetupNote

    static let hostInboundOnlyDetail =
        "Tools connected; cannot initiate yet. There is no way to push a message into that application from here: it has no command line this "
        + "build knows, and its window is not a transport — nothing of it is opened or read. It can "
        + "message this agent any time, because its own settings carry this app's entry and its "
        + "agent_message tool reaches straight in; its messages arrive as ordinary inbound turns."

    static func agentLaneContacts(peers: [AgentPeerContact], selectedPeers: [AgentPeerContact], lanes names: [String], usable: Set<String>,
                                  readCredential: (String) throws -> String? = { try AgentPeerCredentials.read(peerID: $0) }) -> [JSONValue] {
        let lanes: [JSONValue] = names.map {
            let connected = usable.contains($0)
            return .object(["agent": .string($0), "name": .string($0), "kind": .string("local_agent"),
                     "state": .string(connected ? "connected" : "unavailable"),
                     "readiness": .string(connected ? "connected" : "unavailable"),
                     "can_start_turn": .bool(connected),
                     "state_detail": .string($0 == "claude" && connected
                        ? "Messages go to Claude's inbox; she reads them in her live session and answers over the bridge."
                        : connected
                        ? "The local helper, command line and reply path are available. Sign-in is checked when a request runs."
                        : "The local helper, command line, runtime or reply path is unavailable. Check this agent's local CLI installation and NativeAgent bridge setup."),
                     "capabilities": .array([.string("message"), .string("read")]), "read_inputs": .array([.string("message_id")])])
        }
        return lanes + selectedPeers.map { peer in
            guard ["codex", "claude", "omp"].contains(peer.name.trimmingCharacters(in: .whitespaces).lowercased()),
                  case .object(var projection) = peerProjection(peer, peers: peers, readCredential: readCredential)
            else { return peerProjection(peer, peers: peers, readCredential: readCredential) }
            projection["name"] = .string(peer.name + " (agent contact)")
            return .object(projection)
        }
    }

    private static func currentPeerState(_ peer: AgentPeerContact, peers: [AgentPeerContact]) -> AgentPeerContactState {
        AgentPeerCredentials.isAvailable(peer, peers: peers) ? peer.state : .unavailable
    }

    private static func compactContact(_ value: JSONValue) -> JSONValue {
        guard case .object(let row) = value else { return value }
        let keys: Set<String> = ["agent", "name", "description", "kind", "state", "state_detail", "readiness", "paused",
            "endpoint", "card_url", "untrusted_remote_data",
            "can_start_turn", "can_answer_back", "capabilities", "read_inputs", "workspace",
            "last_reply_in", "last_message_out", "last_exchange", "retained_exchanges", "unavailable_now_checked_at", "reply_path"]
        var compact = row.filter { keys.contains($0.key) }
        if let contact = row["agent"] ?? row["name"] {
            compact["detail_read"] = .object(["action": .string("agent.contacts"), "args": .object(["discover": contact])])
        }
        return .object(compact)
    }

    private static func peerProjection(_ peer: AgentPeerContact, peers: [AgentPeerContact] = [],
                                       readCredential: (String) throws -> String? = { try AgentPeerCredentials.read(peerID: $0) }) -> JSONValue {
        guard case .object(var value) = peerHistoryProjection(peer) else { return .null }
        if !AgentPeerCredentials.isAvailable(peer, peers: peers, readCredential: readCredential) {
            value["state"] = .string("unavailable")
            value["state_detail"] = .string(AgentPeerCredentials.unavailableDetail)
            value["readiness"] = .string("unavailable")
        }
        return .object(value)
    }

    private static func peerHistoryProjection(_ peer: AgentPeerContact) -> JSONValue {
        if peer.transport == .grokBot {
            var value: [String: JSONValue] = ["agent": .string("peer:" + peer.id), "name": .string(peer.name),
                "kind": .string("agent_host"), "transport": .string("grokBot"),
                "state": .string(peer.grokSetup == "set up" && peer.provenInboundAt != nil ? "connected" : peer.grokSetup ?? "set up"),
                "last_reply_in": peer.provenInboundAt.map(JSONValue.string) ?? .null,
                "last_message_out": peer.provenOutboundAt.map(JSONValue.string) ?? .null,
                "readiness": .string("not_checked"),
                "can_start_turn": .bool(peer.grokSetup == "set up"), "can_answer_back": .bool(true),
                "capabilities": .array([.string("message"), .string("read")]),
                "read_inputs": .array([.string("message_id")]),
                "state_detail": .string("Webhook acceptance starts a run. Only a correlated local reply is an answer. Grok Bot may ask for local execution approval each time.")]
            if let proof = peer.roundTripProof {
                value["round_trip_proof"] = .object([
                    "route": .string("grokBot"), "at": .string(proof.at),
                    "endpoint": .string(proof.endpoint.absoluteString),
                    "executable": .null, "version": .null, "workspace": .string(proof.workspace)])
            }
            return .object(value)
        }
        // The state, in the same four words everywhere, on every contact.
        var value: [String: JSONValue] = ["agent": .string("peer:" + peer.id), "name": .string(peer.name),
            "can_start_turn": .bool(peer.canStartTurn), "can_answer_back": .bool(peer.canAnswerBack),
            "state": .string(peer.state.rawValue), "state_detail": .string(peer.state.detail)]
        if let workspace = peer.hostWorkspace { value["workspace"] = .string(workspace) }
        // A host's CLI answer and its inbound MCP message are separate proofs.
        // Show the newest reply without promoting one proof into the other.
        var lastReply = peer.provenInboundAt
        if peer.transport == .mcpHost, let proof = peer.roundTripProof,
           proof.executable != nil, proof.endpoint == peer.endpoint, proof.credentialKey == peer.credentialKey {
            lastReply = [lastReply, proof.at].compactMap { $0 }.max()
        }
        if let stamp = lastReply { value["last_reply_in"] = .string(stamp) }
        if let stamp = peer.provenOutboundAt { value["last_message_out"] = .string(stamp) }
        if let proof = peer.roundTripProof {
            value["round_trip_proof"] = .object([
                "route": .string(peer.transport == .acp ? "acp" : peer.transport == .desktop ? "desktop" : proof.executable == nil ? "remote" : "commandLine"),
                "at": .string(proof.at), "endpoint": .string(proof.endpoint.absoluteString),
                "executable": proof.executable.map(JSONValue.string) ?? .null,
                "version": proof.version.map(JSONValue.string) ?? .null,
                "workspace": .string(proof.workspace)])
        }
        if let proof = peer.mcpReturnProof {
            value["mcp_return_proof"] = .object([
                "route": .string(proof.endpoint.absoluteString), "at": .string(proof.at)])
        }
        if let stamp = peer.unavailableAt { value["unavailable_now_checked_at"] = .string(stamp) }
        if peer.transport == .acp {
            value["kind"] = .string("agent_host")
            if peer.state == .setUp {
                value["state_detail"] = .string(!peer.canStartTurn
                    ? "The saved executable cannot currently be verified. Reconnect to review the changed or missing program; earlier replies remain recorded."
                    : peer.unavailableAt != nil
                        ? "The last connection attempt was unavailable. Earlier replies remain recorded; opening a new turn rechecks the route."
                        : "The connection is saved, but it has not answered a message yet.")
            }
            value["transport"] = .string("acp")
            value["route"] = .string("acp")
            value["outbound_route"] = .string("acp")
            value["capabilities"] = .array([.string("message")])
            value["readiness"] = .string("not_checked")
            value["setup"] = .string("Can start a conversation and receive its answer in the same call. The app remembers the conversation within your current chat and continues it when supported; use conversation to select a named discussion. It runs on this Mac as you; this app asks you only when the agent asks it for permission.")
            value["executable"] = peer.approvedExecutablePath.map(JSONValue.string) ?? .null
            value["working_directory"] = peer.acpWorkingDirectory.map(JSONValue.string) ?? .null
            if let id = AgentPeerStore.hostRowID(peer.endpoint), let line = AgentHostDirectory.row(named: id)?.acp {
                value["version_note"] = .string(line.versionNote(peer.acpExecutable?.version))
            }
            return .object(value)
        }
        if peer.transport == .mcpHost {
            let row = AgentPeerStore.hostRowID(peer.endpoint).flatMap { id in
                AgentHostDirectory.rows.first { $0.id == id }
            }
            let line = row?.commandLine
            value["kind"] = .string("agent_host")
            value["transport"] = .string("mcpHost")
            value["host"] = .string(row?.id ?? "")
            value["route"] = .string(row?.route.rawValue ?? "mcp-settings-only")
            value["outbound_route"] = .string(row?.outboundRoute ?? "none")
            if line == nil { value["state_detail"] = .string("tools connected; cannot initiate yet") }
            value["credential_configured"] = .bool(peer.credentialKey != nil)
            value["readiness"] = .string("not_checked")
            value["capabilities"] = .array(line == nil ? [] : [.string("message")])
            value["read_inputs"] = .array(line?.continuesConversations == true ? [.string("conversation_id")] : [])
            value["setup"] = .string(line == nil
                ? hostInboundOnlyDetail
                : "A message to this contact runs its command line once and brings its reply back in the same call."
                    + (line?.continuesConversations == true
                       ? " The app remembers the conversation within your current chat; use conversation to select a named discussion."
                       : " This connection starts a separate conversation for each message.")
                    + " It also reaches this app any time through its own entry.")
            if row?.format == .shellEnvironment {
                value["state_detail"] = .string(ChatGPTDotIPCTransport.detail)
                value["outbound_route"] = .string("chatgpt-dot-ipc")
                value["route"] = .string("chatgpt-dot-ipc")
                value["readiness"] = ChatGPTDotIPCTransport.readiness
                value["can_start_turn"] = .bool(ChatGPTDotIPCTransport.available)
                value["capabilities"] = .array([.string("message"), .string("read")])
                value["read_inputs"] = .array([.string("conversation_id"), .string("limit"), .string("offset"), .string("max_chars"), .string("text_offset"), .string("source_version")])
                value["setup"] = .string("NativeAgent messages Dot in-house after a read-only route check. Unknown delivery is read by its original receipt, never resent. Dot's nativeagent-link inbound commands and per-agent Trust remain unchanged.")
            }
            return .object(value)
        }
        if peer.transport == .desktopChat {
            value["kind"] = .string("desktop_chat_agent")
            value["transport"] = .string("desktopChat")
            value["app_bundle_id"] = .string(AgentPeerStore.desktopBundleID(peer.endpoint) ?? "")
            value["capabilities"] = .array([.string("message")])
            value["read_inputs"] = .array([.string("conversation_id")])
            value["setup"] = .string("A message is typed into your own chat in its app and its answer comes back in the same call. The app remembers that chat within your conversation; start a new conversation for a fresh chat there.")
            return .object(value)
        }
        if peer.transport == .desktop {
            value["kind"] = .string("desktop_agent")
            value["transport"] = .string("desktop")
            value["app_bundle_id"] = .string(AgentPeerStore.desktopBundleID(peer.endpoint) ?? "")
            value["readiness"] = .string("not_checked")
            value["execution"] = .string("app_managed_desktop_route")
            value["capabilities"] = .array([.string("message")])
            value["setup"] = .string(peer.readsReplyInWindow
                ? "A message is pasted into its chat \u{201C}\(peer.conversationLabel ?? "grok")\u{201D} in the Grok Bot app and its answer is read back from that same chat in the same call (up to three minutes)."
                : desktopSetupNote)
            if let label = peer.conversationLabel { value["conversation_label"] = .string(label) }
            return .object(value)
        }
        value["kind"] = .string("external_peer")
        value["transport"] = .string(peer.transport.rawValue)
        value["endpoint"] = .string(peer.endpoint.absoluteString)
        value["credential_configured"] = .bool(peer.credentialKey != nil)
        value["readiness"] = .string("not_checked")
        value["capabilities"] = .array([.string("message"), .string("read")])
        value["read_inputs"] = .array(peer.transport == .a2a
            ? [.string("task_id")] : [.string("message_id"), .string("conversation_id")])
        return .object(value)
    }

    static func peerAuthorizeInterface(_ interface: AgentA2AWire.Interface, cardURL: URL, hasCredential: Bool) throws {
        try AgentPeerPolicy.peerAuthorizeInterface(interface, cardURL: cardURL, hasCredential: hasCredential)
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

    private static func peerKeys(_ args: [String: JSONValue], allowed: Set<String>) throws {
        let unknown = Set(args.keys).subtracting(allowed).sorted()
        guard unknown.isEmpty else {
            throw ToolFailureError("Agent communication: unsupported fields: " + unknown.joined(separator: ", ") + ".",
                                   argumentPath: unknown.first, effects: .none)
        }
    }
    private static func peerString(_ args: [String: JSONValue], _ key: String, max: Int, required: Bool = true) throws -> String? {
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
