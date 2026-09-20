#if canImport(AppKit)
import AppKit
#endif
import Foundation
import ApprovalInbox
import NativeAgentCore
import PersistenceCore
import StandingBots
import ProviderRouting

public protocol BuiltInAgentLaneProviding: Sendable {
    func builtInAgentLaneUsable(_ name: String) -> Bool
}

extension SwiftToolDispatcher: BuiltInAgentLaneProviding {
    public func builtInAgentLaneUsable(_ name: String) -> Bool {
        let helper: URL?
        let cli: String
        let directory: String
        switch name {
        case "codex":
            helper = AgentBridgeRuntime.codexHelperURL(override: codexMessageWakeupHelperOverride, repoRoot: rootForRead)
            cli = "codex"
            directory = "codex-nativeagent-bridge"
        case "claude":
            helper = AgentBridgeRuntime.claudeHelperURL(override: claudeMessageWakeupHelperOverride, repoRoot: rootForRead)
            cli = "claude"
            directory = "claude-bridge"
        case "omp":
            helper = AgentBridgeRuntime.ompHelperURL(override: ompMessageWakeupHelperOverride, repoRoot: rootForRead)
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
            if let discover = args["discover"], case .bool = discover {} else if args["discover"] != nil {
                throw AgentCommunicationError.invalid("discover must be a boolean")
            }
            let peers = try store.list()
            let usable = Set(["codex", "claude", "omp"].filter { builtInAgentLaneUsable($0) })
            var contacts = Self.agentLaneContacts(peers: peers, usable: usable)
            contacts += try BotDefinitionStore(dataRoot: dataRoot).list().map {
                .object(["agent": .string("bot:" + $0.id.uuidString.lowercased()), "name": .string($0.name),
                         "kind": .string("bot"), "paused": .bool($0.paused), "readiness": .string("not_checked"),
                         "capabilities": .array([.string("message"), .string("read")]), "read_inputs": .array([])])
            }
            // LISTED: a known agent on this Mac with nothing set up behind it
            // yet. Saying so is how `agent_connect` by name becomes findable
            // without the agent having to guess a name.
            let connected = Set(peers.compactMap { AgentPeerStore.hostRowID($0.endpoint) })
            let found = await AgentDiscoverySession.shared.candidates(refresh: args["discover"] == .bool(true))
            contacts += found.filter { candidate in
                if let host = candidate.hostID {
                    return AgentHostDirectory.rows.first { $0.id == host }?.requiresWorkspace == true || !connected.contains(host)
                }
                return !peers.contains { $0.endpoint == candidate.cardURL || $0.endpoint == candidate.endpoint }
            }.map(\.projection)
            return .object(["status": .string("ok"), "contacts": .array(contacts),
                            "states": .array([AgentPeerContactState.listed, .setUp, .connected, .sendOnly]
                                .map { .string($0.rawValue + " — " + $0.detail) }),
                            "detail": .string("Configuration is not evidence of availability or permission to send. Connected means a real message arrived through the connection, or a message and reply crossed it. Each route shows its own proof.")])
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
                return try hostDisconnect(name: name, workspace: workspace, store: store)
            }
            if args["endpoint"] == nil, args["app_bundle_id"] == nil, transportName == "auto" {
                return try await hostConnect(name: name, workspace: workspace, executablePath: try Self.peerString(args, "executable_path", max: 4096, required: false), store: store, surface: surface,
                    workingDirectory: Self.peerString(args, "working_directory", max: 4096, required: false))
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
        guard tool == "agent_message" || tool == "agent_read" else { throw AgentCommunicationError.invalid("tool") }
        let sending = tool == "agent_message"
        try Self.peerKeys(args, allowed: sending
            ? ["agent", "text", "conversation_id", "message_id", "task_id"]
            : ["agent", "conversation_id", "message_id", "task_id", "offset", "max_chars", "details", "page_size", "page_token", "status", "context_id", "history_length", "include_artifacts", "status_timestamp_after"])
        if let details = args["details"] {
            guard case .bool = details else { throw AgentCommunicationError.invalid("details must be boolean") }
        }
        let agent = try Self.peerString(args, "agent", max: 64)!
        guard agent.hasPrefix("peer:"), let peer = try store.list().first(where: { "peer:" + $0.id == agent }) else {
            throw AgentCommunicationError.invalid("configured peer handle required")
        }
        let listingFields: Set<String> = ["page_size", "page_token", "status", "context_id", "history_length", "include_artifacts", "status_timestamp_after"]
        if peer.transport == .grokBot {
            guard args["task_id"] == nil else { throw AgentCommunicationError.invalid("Grok uses message_id") }
            let session = ChatToolSessionContext.verifiedSessionId ?? Self.extractSessionId(from: input)
            guard !session.isEmpty else { throw AgentCommunicationError.invalid("A conversation is required") }
            if !sending {
                let id = try Self.peerString(args, "message_id", max: 36)!
                let pending = try GrokRequestStore(dataRoot: dataRoot).read(id, peer: peer.id)
                guard pending.conversationID == session else { throw AgentCommunicationError.invalid("This request belongs to another conversation") }
                return GrokBotRoute.projection(pending)
            }
            if let requested = try Self.peerString(args, "conversation_id", max: 128, required: false), requested != session {
                throw AgentCommunicationError.invalid("Grok replies return to the conversation asking")
            }
            let id = try Self.peerString(args, "message_id", max: 36, required: false) ?? UUID().uuidString.lowercased()
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
        if peer.transport == .acp {
            guard sending else {
                return .object(["status": .string("nothing_to_read"), "completed": .bool(false),
                    "detail": .string("The answer returns with the message. This contact starts a new conversation for each message; there is no saved answer to recover.")])
            }
            guard args["conversation_id"] == nil, args["message_id"] == nil, args["task_id"] == nil else {
                throw AgentCommunicationError.invalid("This contact starts a new conversation for each message. Send text only.")
            }
            return try await hostACPRun(contact: peer, message: Self.peerString(args, "text", max: 64000)!,
                                        store: store, surface: surface)
        }
        if peer.transport == .mcpHost {
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
            let session = requested ?? (row.commandLine?.continuesConversations == true
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
        envelope["status"] = .string("failed")
        envelope["completed"] = .bool(false)
        envelope["detail"] = .string(failure.errorDescription!)
        envelope["work"] = .string(failure.work.rawValue)
        if let data = try? JSONEncoder().encode(failure) {
            envelope["provider_failure"] = try? JSONDecoder().decode(JSONValue.self, from: data)
        }
    }

    /// Connect-by-name. By the time this runs the person has already pressed
    /// the button on the card `AgentHostConnection.cardText` wrote — a
    /// confirm-tier tool body only executes on the approved replay — so this is
    /// where the entry is actually written and not one step earlier.
    private func hostConnect(name: String, workspace: String?, executablePath: String?, store: AgentPeerStore, surface: String, workingDirectory: String? = nil) async throws -> JSONValue {
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
            return .object(["status": .string("grok_setup"), "peer_id": .string(result.contact.id)])
        }
        if let existing = proposal.existing, proposal.row.acp == nil {
            return .object(["status": .string("already_configured"), "contact": Self.peerProjection(existing, peers: (try? store.list()) ?? []),
                            "changed": .bool(false),
                            "detail": .string("\(proposal.row.displayName) already has this app's entry and its own key. Nothing was changed.")])
        }
        if proposal.row.acp != nil {
            let version = try await proposal.executable?.reportedVersion()
            proposal.executable?.version = version
            guard try await AgentACPApproval.connect(proposal, appName: Self.appDisplayName,
                inbox: SwiftNativeApprovalInbox(root: dataRoot)) else {
                return .object(["status": .string("denied"), "changed": .bool(false), "completed": .bool(false)])
            }
        } else if proposal.executablePath != executablePath {
            throw AgentCommunicationError.invalid("The agent executable changed since the approval card. Ask to connect again; nothing ran or changed.")
        }
        let result = try AgentHostConnection.connect(proposal: proposal, store: store)
        let row = proposal.row
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
        if row.commandLine != nil {
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
        if let probe { value["probe"] = probe }
        if let backup = result.outcome.backupPath { value["backup_path"] = .string(backup) }
        return .object(value)
    }

    private func hostDisconnect(name: String, workspace: String?, store: AgentPeerStore) throws -> JSONValue {
        guard usesCanonicalBody else {
            throw AgentCommunicationError.invalid("changing another agent's settings is unavailable outside the canonical app")
        }
        let row = AgentHostDirectory.row(named: name)
        let folder = try row.map { try AgentHostConnection.workspaceFolder(row: $0, workspace: workspace) } ?? nil
        let wanted = row?.id
        guard let contact = try store.list().first(where: { peer in
            "peer:" + peer.id == name || (wanted != nil && (peer.transport == .mcpHost || peer.transport == .acp || peer.transport == .grokBot)
                && AgentPeerStore.hostRowID(peer.endpoint) == wanted && peer.hostWorkspace == folder)
        }) else {
            return .object(["status": .string("not_configured"), "requested": .string(name),
                            "changed": .bool(false),
                            "detail": .string("No connection of this app's making was found for that name. Nothing was changed.")])
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
            outcome = nil
        }
        var value: [String: JSONValue] = ["status": .string("disconnected"), "changed": .bool(true),
            "detail": .string(contact.transport == .mcpHost
                ? "Removed exactly this app's entry, revoked that connection's key, and forgot the contact. Everything else in that file is unchanged."
                : "Removed the contact and its saved key. No other app's settings were changed.")]
        if let outcome {
            value["config_path"] = .string(outcome.path)
            if let backup = outcome.backupPath { value["backup_path"] = .string(backup) }
        }
        return .object(value)
    }

    // MARK: - One verb, one adapter: run the other agent's command line

    private func hostACPRun(contact: AgentPeerContact, message: String, store: AgentPeerStore,
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
        guard let approved = contact.approvedACPExecutable, approved.isCurrent else {
            _ = try await AgentACPApproval.renewExecutable(contact, store: store,
                inbox: SwiftNativeApprovalInbox(root: dataRoot))
            return .object(["status": .string("reconnect_required"), "sent": .bool(false), "completed": .bool(false),
                "detail": .string("The approved program is missing, changed, or was never bound to this contact. Review the fresh connection approval or reconnect. Nothing ran; the message was not resent.")])
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
        let sandbox = await Self.builderShellSandboxMode(dataRoot: dataRoot)
        guard sandbox != .lockedDown else {
            return .object(["status": .string("unavailable"), "sent": .bool(false), "completed": .bool(false),
                "detail": .string("Running another agent is turned off in the current permission settings.")])
        }
        let program = sandbox == .off ? executable : "/usr/bin/sandbox-exec"
        let arguments = sandbox == .off ? line.arguments : ["-p",
            sandbox == .developerFullMac ? Self.builderDeveloperSandboxProfile(dataRoot: dataRoot)
                : Self.builderSandboxProfile(dataRoot: dataRoot), executable] + line.arguments
        do {
            let reply = try await AgentACPClient().turn(
                executable: program, arguments: arguments,
                directory: directory, environment: AgentHostCommandLines.scrubbedEnvironment().merging(line.environment) { _, fixed in fixed },
                message: message, mcpServers: [server], permissionMode: line.permissionMode,
                approvedExecutable: approved, permission: { request in
                    // Revocation wins even if an already-open card was approved.
                    guard try store.list().contains(where: { $0.id == contact.id }) else { return false }
                    let allowed = try await AgentACPApproval.request(request, peer: contact, inbox: inbox)
                    let stillConnected = try store.list().contains(where: { $0.id == contact.id })
                    return allowed && stillConnected
                })
            store.recordProof(peerID: contact.id, inbound: reply.completed && !reply.text.isEmpty, outbound: true)
            if reply.completed && !reply.text.isEmpty {
                store.recordRoundTrip(peerID: contact.id, executable: approved.path,
                    version: approved.version, workspace: directory.path)
            } else {
                store.recordUnavailable(peerID: contact.id)
            }
            return Self.peerRedact(.object(["status": .string(reply.completed ? "replied" : reply.stopReason),
                "agent": .string("peer:" + contact.id), "transport": .string("acp"),
                "sent": .bool(true), "completed": .bool(reply.completed), "reply": .string(reply.text),
                "untrusted_remote_data": .bool(!reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)]), token: secret)
        } catch AgentACPClient.Failure.executableChanged {
            store.recordUnavailable(peerID: contact.id)
            _ = try await AgentACPApproval.renewExecutable(contact, store: store, inbox: inbox)
            return .object(["status": .string("reconnect_required"), "sent": .bool(false), "completed": .bool(false),
                "detail": .string("The program changed before launch. A fresh approval was requested. Nothing ran; the message was not resent.")])
        } catch {
            store.recordUnavailable(peerID: contact.id)
            if let failure = ProviderFailure.report(error, work: .outcomeUnknown) {
                var result: [String: JSONValue] = ["agent": .string("peer:" + contact.id), "transport": .string("acp")]
                Self.peerFailure(failure, into: &result)
                return Self.peerRedact(.object(result), token: secret)
            }
            return .object(["status": .string(Task.isCancelled ? "cancelled" : "outcome_unknown"),
                "agent": .string("peer:" + contact.id), "transport": .string("acp"), "completed": .bool(false),
                "detail": .string(Task.isCancelled ? "The conversation was stopped." :
                    (error as? AgentACPClient.Failure)?.localizedDescription ?? "The conversation did not finish. Do not resend automatically.")])
        }
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
        guard await fullMacToolAccess(surface: surface).fileOpsAllowed else {
            return builderFullMacRequired(tool: "agent_message")
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
        guard let executable = contact.approvedExecutablePath,
              executable == AgentHostCommandLines.resolveExecutable(line.executable) else {
            return honest("unavailable",
                "\(row.displayName)'s executable is missing, changed, or was never approved. Reconnect with an approval card showing its exact path. Nothing ran.")
        }
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
        let argv = line.argv(message: outgoing, session: session, resuming: resuming, replyFilePath: replyFile)
        // The runner closes stdin. Pass the approved executable and argv directly.
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
            reapDescendantsOnExit: true)
        guard case .object(let envelope) = outcome else { return outcome }
        var reply = ""
        var truncated = false
        if let replyFile, let handle = FileHandle(forReadingAtPath: replyFile) {
            defer { try? handle.close() }
            // Bounded at the READ, not after it: a reply file is written by
            // another program and its size is that program's choice. One byte
            // past the cap is how we know to say so.
            let data = (try? handle.read(upToCount: 64 * 1024 + 1)) ?? Data()
            truncated = data.count > 64 * 1024
            reply = String(decoding: data.prefix(64 * 1024), as: UTF8.self)
        } else if case .string(let text)? = envelope["stdout"] {
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
        let arrived = Self.recordHostConnectionOutcome(store: store, contact: contact, ran: ran,
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
        if let session { result["conversation_id"] = .string(session) }
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
        if !replied {
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
    private static func probeReason(_ probe: JSONValue?) -> String {
        guard case .object(let value)? = probe else { return "" }
        if value["timed_out"] == .bool(true) { return "The probe ran past its time limit." }
        if case .string(let detail)? = value["detail"] { return detail }
        return "The probe ran and nothing arrived through the entry."
    }

    /// A HOST WITH NO COMMAND LINE. Honest, and it never reaches for a window.
    static func hostNoCommandLine(row: AgentHostRow?, contact: AgentPeerContact, peers: [AgentPeerContact] = []) -> JSONValue {
        let state = currentPeerState(contact, peers: peers)
        return .object(["status": .string("no_outbound_route"), "agent": .string("peer:" + contact.id),
                 "transport": .string("mcpHost"), "host": .string(row?.id ?? ""),
                 "state": .string(state.rawValue), "state_detail": .string(state == .unavailable ? state.detail : "tools connected; cannot initiate yet"),
                 "outbound_route": .string(row?.outboundRoute ?? "none"),
                 "sent": .bool(false), "read": .bool(false), "completed": .bool(false),
                 "detail": .string(hostInboundOnlyDetail)])
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

    static func agentLaneContacts(peers: [AgentPeerContact], usable: Set<String>,
                                  readCredential: (String) throws -> String? = { try AgentPeerCredentials.read(peerID: $0) }) -> [JSONValue] {
        let lanes: [JSONValue] = ["codex", "claude", "omp"].filter { usable.contains($0) }.map {
            .object(["agent": .string($0), "name": .string($0), "kind": .string("local_agent"), "readiness": .string("not_checked"),
                     "capabilities": .array([.string("message"), .string("read")]), "read_inputs": .array([.string("message_id")])])
        }
        return lanes + peers.map { peer in
            guard usable.contains(peer.name.trimmingCharacters(in: .whitespaces).lowercased()),
                  case .object(var projection) = peerProjection(peer, peers: peers, readCredential: readCredential)
            else { return peerProjection(peer, peers: peers, readCredential: readCredential) }
            projection["name"] = .string(peer.name + " (agent contact)")
            return .object(projection)
        }
    }

    private static func currentPeerState(_ peer: AgentPeerContact, peers: [AgentPeerContact]) -> AgentPeerContactState {
        AgentPeerCredentials.isAvailable(peer, peers: peers) ? peer.state : .unavailable
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
            return .object(["agent": .string("peer:" + peer.id), "name": .string(peer.name),
                "transport": .string("grokBot"), "state": .string(peer.grokSetup ?? "set up"),
                "can_start_turn": .bool(peer.grokSetup == "set up"), "can_answer_back": .bool(true),
                "capabilities": .array([.string("message"), .string("read")]),
                "read_inputs": .array([.string("message_id")]),
                "state_detail": .string("Webhook acceptance starts a run. Only a correlated local reply is an answer. Grok Bot may ask for local execution approval each time.")])
        }
        // The state, in the same four words everywhere, on every contact.
        var value: [String: JSONValue] = ["agent": .string("peer:" + peer.id), "name": .string(peer.name),
            "can_start_turn": .bool(peer.canStartTurn), "can_answer_back": .bool(peer.canAnswerBack),
            "state": .string(peer.state.rawValue), "state_detail": .string(peer.state.detail)]
        if let workspace = peer.hostWorkspace { value["workspace"] = .string(workspace) }
        if let stamp = peer.provenInboundAt { value["last_reply_in"] = .string(stamp) }
        if let stamp = peer.provenOutboundAt { value["last_message_out"] = .string(stamp) }
        if let proof = peer.roundTripProof {
            value["round_trip_proof"] = .object([
                "route": .string(peer.transport == .acp ? "acp" : proof.executable == nil ? "remote" : "commandLine"),
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
                value["state_detail"] = .string("The connection is saved, but it has not answered a message yet.")
            }
            value["transport"] = .string("acp")
            value["route"] = .string("acp")
            value["outbound_route"] = .string("acp")
            value["capabilities"] = .array([.string("message")])
            value["readiness"] = .string("not_checked")
            value["setup"] = .string("Can start a conversation and receive its answer in the same call. Each message starts a new conversation. It runs on this Mac as you; this app asks you only when the agent asks it for permission.")
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
                       ? " Carry conversation_id forward to stay in one conversation."
                       : " This connection starts a separate conversation for each message.")
                    + " It also reaches this app any time through its own entry.")
            return .object(value)
        }
        if peer.transport == .desktop {
            value["kind"] = .string("desktop_agent")
            value["transport"] = .string("desktop")
            value["app_bundle_id"] = .string(AgentPeerStore.desktopBundleID(peer.endpoint) ?? "")
            value["readiness"] = .string("not_checked")
            value["execution"] = .string("app_managed_desktop_route")
            value["capabilities"] = .array([.string("message")])
            value["setup"] = .string(desktopSetupNote)
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
        try AgentPeerHTTP.validateURL(cardURL)
        try AgentPeerHTTP.validateURL(interface.endpoint)
        var candidate = AgentPeerContact(name: "Peer endpoint", endpoint: interface.endpoint, transport: .a2a)
        candidate.credentialKey = nil
        try AgentPeerStore.validate(candidate)
        func origin(_ url: URL) -> String {
            "\(url.scheme?.lowercased() ?? "")://\(url.host?.lowercased() ?? ""):\(url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80))"
        }
        // HTTP/2 may listen beside the card's HTTP listener. The card may
        // authorize a gRPC port on the same host with the same TLS policy,
        // never a different host or a downgrade from HTTPS to plaintext.
        let sameGRPCHost = interface.binding == "GRPC"
            && interface.endpoint.host?.lowercased() == cardURL.host?.lowercased()
            && interface.endpoint.scheme?.lowercased() == cardURL.scheme?.lowercased()
        guard origin(interface.endpoint) == origin(cardURL) || sameGRPCHost else { throw AgentCommunicationError.invalid("cross-origin peer interface requires its own configured contact") }
        guard case .array(let alternatives) = interface.securityRequirements,
              case .object(let schemes) = interface.securitySchemes else { throw AgentCommunicationError.invalid("security requirements") }
        if alternatives.isEmpty { return }
        for requirement in alternatives {
            guard case .object(let rawEntries) = requirement else { continue }
            let entries: [String: JSONValue]
            if interface.version == "1.0" {
                guard case .object(let values)? = rawEntries["schemes"] else { continue }
                entries = values
            } else { entries = rawEntries }
            if entries.isEmpty { return }
            guard hasCredential else { continue }
            let supported = entries.allSatisfy { name, scopes in
                let scopeList: JSONValue
                if interface.version == "1.0", case .object(let value) = scopes { scopeList = value["list"] ?? .array([]) }
                else { scopeList = scopes }
                guard case .array(let values) = scopeList, values.isEmpty,
                      case .object(let raw)? = schemes[name] else { return false }
                let scheme: [String: JSONValue]
                if case .object(let http)? = raw["httpAuthSecurityScheme"] { scheme = http }
                else { guard raw["type"] == .string("http") else { return false }; scheme = raw }
                guard case .string(let kind)? = scheme["scheme"] else { return false }
                return kind.lowercased() == "bearer"
            }
            if supported { return }
        }
        throw AgentCommunicationError.invalid("peer requires unsupported authentication or a configured bearer credential")
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
        guard Set(args.keys).isSubset(of: allowed) else { throw AgentCommunicationError.invalid("unsupported fields") }
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

private enum AgentCommunicationError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let detail): return "Agent communication: \(detail)." }
    }
}
