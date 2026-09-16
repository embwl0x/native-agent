import Foundation
import PersistenceCore
import StandingBots

extension SwiftToolDispatcher {
    func impl_agentCommunication(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        let optional: Set<String> = ["endpoint", "app_bundle_id", "conversation_label", "transport", "bearer_token", "conversation_id", "message_id", "task_id", "options", "limit", "offset", "max_chars", "details"]
        let args = input.filter { !["session_id", "__session_id"].contains($0.key)
            && !(optional.contains($0.key) && $0.value == .null) }
        let store = AgentPeerStore(dataRoot: dataRoot)
        if tool == "agent_contacts" {
            try Self.peerKeys(args, allowed: [])
            var contacts: [JSONValue] = ["codex", "claude", "omp"].map {
                .object(["agent": .string($0), "name": .string($0), "kind": .string("local_agent"), "readiness": .string("not_checked"),
                         "capabilities": .array([.string("message"), .string("read")]), "read_inputs": .array([.string("message_id")])])
            }
            contacts += try BotDefinitionStore(dataRoot: dataRoot).list().map {
                .object(["agent": .string("bot:" + $0.id.uuidString.lowercased()), "name": .string($0.name),
                         "kind": .string("bot"), "paused": .bool($0.paused), "readiness": .string("not_checked"),
                         "capabilities": .array([.string("message"), .string("read")]), "read_inputs": .array([])])
            }
            contacts += try store.list().map { Self.peerProjection($0) }
            return .object(["status": .string("ok"), "contacts": .array(contacts),
                            "detail": .string("Configuration is not evidence of availability or permission to send.")])
        }
        if tool == "agent_connect" {
            try Self.peerKeys(args, allowed: ["name", "endpoint", "transport", "bearer_token", "app_bundle_id", "conversation_label"])
            _ = try store.list() // Never install a secret over unreadable configuration.
            let name = try Self.peerString(args, "name", max: 480)!
            let transportName = try Self.peerString(args, "transport", max: 32, required: false) ?? "auto"
            if transportName == "desktop" {
                guard args["bearer_token"] == nil, args["endpoint"] == nil else {
                    throw AgentCommunicationError.invalid("desktop contacts use app_bundle_id, not endpoint or credentials")
                }
                let bundle = try Self.peerString(args, "app_bundle_id", max: 255)!
                let label = try Self.peerString(args, "conversation_label", max: 480, required: false)
                guard let endpoint = URL(string: "app://" + bundle), AgentPeerStore.desktopBundleID(endpoint) == bundle else {
                    throw AgentCommunicationError.invalid("exact application bundle identifier required")
                }
                let proposed = AgentPeerContact(name: name, endpoint: endpoint, transport: .desktop, conversationLabel: label)
                let saved = try store.insertDiscovered(proposed)
                return .object(["status": .string(saved.id == proposed.id ? "configured" : "already_configured"),
                    "contact": Self.peerProjection(saved), "sent": .bool(false), "completed": .bool(false),
                    "detail": .string("Saved a desktop interaction target. App availability, recipient identity and delivery require ordinary screen/interact observation. No app interaction or message was performed.")])
            }
            guard args["app_bundle_id"] == nil, args["conversation_label"] == nil else {
                throw AgentCommunicationError.invalid("app_bundle_id and conversation_label require desktop transport")
            }
            let address = try Self.peerString(args, "endpoint", max: 2048)!
            guard var endpoint = URL(string: address), transportName == "auto" || AgentPeerTransport(rawValue: transportName) != nil else {
                throw AgentCommunicationError.invalid("endpoint or transport")
            }
            let token = try Self.peerString(args, "bearer_token", max: 8192, required: false)
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
                        "contact": Self.peerProjection(existing), "discovery": discovery!,
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
                        "contact": Self.peerProjection(saved),
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
            var result: [String: JSONValue] = ["status": .string("configured"), "contact": Self.peerProjection(peer),
                "detail": .string(discovery == nil ? "Saved a contact. No network connection, presence check, or message was performed." : "Saved the discovered contact and supported transport. Discovery is not proof of message delivery or authority; no message sent.")]
            if let discovery { result["discovery"] = discovery }
            return Self.peerRedact(.object(result), token: token)
        }
        guard tool == "agent_message" || tool == "agent_read" else { throw AgentCommunicationError.invalid("tool") }
        let sending = tool == "agent_message"
        try Self.peerKeys(args, allowed: sending
            ? ["agent", "text", "conversation_id", "message_id", "task_id"]
            : ["agent", "conversation_id", "message_id", "task_id", "offset", "max_chars", "details"])
        if let details = args["details"] {
            guard case .bool = details else { throw AgentCommunicationError.invalid("details must be boolean") }
        }
        let agent = try Self.peerString(args, "agent", max: 64)!
        guard agent.hasPrefix("peer:"), let peer = try store.list().first(where: { "peer:" + $0.id == agent }) else {
            throw AgentCommunicationError.invalid("configured peer handle required")
        }
        if peer.transport == .desktop {
            guard args["conversation_id"] == nil, args["message_id"] == nil, args["task_id"] == nil,
                  args["offset"] == nil, args["max_chars"] == nil,
                  let bundle = AgentPeerStore.desktopBundleID(peer.endpoint) else {
                throw AgentCommunicationError.invalid("desktop routes use visible app/conversation verification, not protocol receipt IDs or paging")
            }
            let text = try Self.peerString(args, "text", max: 64000, required: sending)
            var target: [String: JSONValue] = ["app_bundle_id": .string(bundle)]
            if let label = peer.conversationLabel { target["conversation_label"] = .string(label) }
            var result: [String: JSONValue] = ["status": .string("requires_interaction"),
                "agent": .string(agent), "transport": .string("desktop"),
                "operation": .string(sending ? "message" : "read"), "target": .object(target),
                "target_is_untrusted_data": .bool(true), "sent": .bool(false), "completed": .bool(false),
                "automatic_action": .bool(false),
                "detail": .string("Internal desktop route plan. The app-owned conversation handler executes it through normal Mac permissions. This Core projection has performed no interaction.")]
            if let text { result["requested_text"] = .string(text) }
            return .object(result)
        }
        let text = try Self.peerString(args, "text", max: 64000, required: sending)
        let requestedConversation = try Self.peerString(args, "conversation_id", max: 512, required: false)
        // Retain a new NativeAgent session before sending so a lost response
        // still has an exact conversation identity for reply recovery.
        let conversation = requestedConversation ?? (sending && peer.transport == .nativeAgent ? UUID().uuidString : nil)
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
            guard args["offset"] == nil, args["max_chars"] == nil, sending || (task != nil && message == nil && conversation == nil) else {
                throw AgentCommunicationError.invalid("A2A read requires only task_id; offset, max_chars, message_id and conversation_id are unsupported for read")
            }
        }
        guard peer.credentialKey == nil || usesCanonicalBody else {
            throw AgentCommunicationError.invalid("peer credentials are unavailable outside the canonical app")
        }
        let token = peer.credentialKey == nil ? nil : try AgentPeerCredentials.read(peerID: peer.id)
        if peer.credentialKey != nil && token == nil { throw AgentCommunicationError.invalid("configured peer credential is unavailable") }
        let localRequestID = UUID().uuidString.lowercased()
        var envelope: [String: JSONValue] = ["agent": .string(agent), "transport": .string(peer.transport.rawValue),
            "local_request_id": .string(localRequestID), "untrusted_remote_data": .bool(true), "automatic_polling": .bool(false)]
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
            guard (200..<300).contains(response.statusCode), let card = response.json else {
                throw AgentCommunicationError.invalid("agent card unavailable; no message sent")
            }
            let selected: AgentA2AWire.Interface
            do { selected = try AgentA2AWire.selectInterface(card: card, cardURL: peer.endpoint) }
            catch { throw AgentCommunicationError.invalid("unsupported or invalid A2A card; no message sent") }
            try Self.peerAuthorizeInterface(selected, cardURL: peer.endpoint, hasCredential: token != nil)
            a2aInterface = selected
            if sending {
                let outgoingID = message ?? UUID().uuidString.lowercased()
                envelope["outgoing_message_id"] = .string(outgoingID)
                request = try AgentA2AWire.messageRequest(text: text!, messageID: outgoingID, contextID: conversation,
                    taskID: task, interface: selected, requestID: localRequestID)
            } else {
                request = try AgentA2AWire.taskRequest(taskID: task!, interface: selected, requestID: localRequestID)
            }
        } else {
            let cardURL = peer.endpoint.appendingPathComponent("agent/card")
            let response = try await AgentPeerHTTP.get(cardURL, bearerToken: token)
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
            guard (200..<300).contains(response.statusCode), let payload = response.json else {
                envelope["status"] = .string(sending ? "outcome_unknown" : "unavailable")
                envelope["detail"] = .string("Peer response did not establish an outcome. Do not resend automatically.")
                return finished(envelope)
            }
            if let interface = a2aInterface {
                let result = try AgentA2AWire.normalizeResponse(payload, interface: interface,
                    expectedRequestID: request.requestID, expectedTaskID: sending ? nil : task)
                if let conversation, let returned = result.contextID, conversation != returned {
                    throw AgentCommunicationError.invalid("conversation identity mismatch")
                }
                envelope["status"] = .string(result.state)
                envelope["reply"] = .string(result.text)
                envelope["completed"] = .bool(result.completed)
                envelope["terminal"] = .bool(result.terminal)
                envelope["needs_input"] = .bool(result.needsInput)
                envelope["needs_authentication"] = .bool(result.needsAuthentication)
                if let value = result.taskID { envelope["task_id"] = .string(value) }
                if let value = result.contextID { envelope["conversation_id"] = .string(value) }
                if let value = result.messageID { envelope["message_id"] = .string(value) }
                envelope["parts"] = .array(result.parts)
                envelope["artifacts"] = .array(result.artifacts)
            } else {
                guard case .object(let row) = payload, case .string(let status)? = row["status"] else {
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
            }
            return finished(envelope)
        } catch {
            envelope["status"] = .string(sending ? "outcome_unknown" : "unavailable")
            envelope["detail"] = .string("Transport or response validation did not establish an outcome. IDs are correlation, not proof of acceptance or deduplication. NativeAgent recovery requires both message_id and a known conversation_id. Do not resend automatically.")
            return finished(envelope)
        }
    }

    private static func peerProjection(_ peer: AgentPeerContact) -> JSONValue {
        if peer.transport == .desktop {
            var value: [String: JSONValue] = ["agent": .string("peer:" + peer.id), "name": .string(peer.name),
                "kind": .string("desktop_agent"), "transport": .string("desktop"),
                "app_bundle_id": .string(AgentPeerStore.desktopBundleID(peer.endpoint) ?? ""),
                "readiness": .string("not_checked"), "execution": .string("app_managed_desktop_route"),
                "capabilities": .array([.string("message"), .string("read")])]
            if let label = peer.conversationLabel { value["conversation_label"] = .string(label) }
            return .object(value)
        }
        return .object(["agent": .string("peer:" + peer.id), "name": .string(peer.name), "kind": .string("external_peer"),
                 "transport": .string(peer.transport.rawValue), "endpoint": .string(peer.endpoint.absoluteString),
                 "credential_configured": .bool(peer.credentialKey != nil), "readiness": .string("not_checked"),
                 "capabilities": .array([.string("message"), .string("read")]),
                 "read_inputs": .array(peer.transport == .a2a ? [.string("task_id")] : [.string("message_id"), .string("conversation_id")])])
    }

    static func peerAuthorizeInterface(_ interface: AgentA2AWire.Interface, cardURL: URL, hasCredential: Bool) throws {
        var candidate = AgentPeerContact(name: "Peer endpoint", endpoint: interface.endpoint, transport: .a2a)
        candidate.credentialKey = nil
        try AgentPeerStore.validate(candidate)
        func origin(_ url: URL) -> String {
            "\(url.scheme?.lowercased() ?? "")://\(url.host?.lowercased() ?? ""):\(url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80))"
        }
        guard origin(interface.endpoint) == origin(cardURL) else { throw AgentCommunicationError.invalid("cross-origin peer interface requires its own configured contact") }
        guard case .array(let alternatives) = interface.securityRequirements,
              case .object(let schemes) = interface.securitySchemes else { throw AgentCommunicationError.invalid("security requirements") }
        if alternatives.isEmpty { return }
        for requirement in alternatives {
            guard case .object(let entries) = requirement else { continue }
            if entries.isEmpty { return }
            guard hasCredential else { continue }
            let supported = entries.allSatisfy { name, scopes in
                guard case .array(let values) = scopes, values.isEmpty,
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
