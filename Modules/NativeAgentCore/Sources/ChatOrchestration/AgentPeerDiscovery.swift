import Foundation
import PersistenceCore

/// Bounded read-only discovery. A website, an HTTP success, or an unsupported
/// protocol is not a connected agent. No contact or credential is written here.
enum AgentPeerDiscovery {
    struct Result: Sendable {
        let transport: AgentPeerTransport?
        let endpoint: URL?
        let evidence: JSONValue
    }

    static func candidates(for endpoint: URL) -> [URL] {
        var origin = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        origin.path = ""; origin.query = nil; origin.fragment = nil
        let root = origin.url!
        var urls = [endpoint]
        if !endpoint.path.hasSuffix(".json"), !endpoint.path.hasSuffix("/agent/card") {
            urls.append(endpoint.appendingPathComponent(".well-known/agent-card.json"))
        }
        urls += [root.appendingPathComponent(".well-known/agent-card.json"),
                 root.appendingPathComponent(".well-known/agent.json")]
        if !endpoint.path.hasSuffix(".json"), !endpoint.path.hasSuffix("/agent/card") {
            urls.append(endpoint.appendingPathComponent("agent/card"))
        } else {
            urls.append(root.appendingPathComponent("agent/card"))
        }
        var seen: Set<String> = []
        return urls.filter { seen.insert($0.absoluteString).inserted }
    }

    static func resolve(_ endpoint: URL, bearerToken: String?) async throws -> Result {
        try AgentPeerStore.validate(AgentPeerContact(name: "Discovery", endpoint: endpoint, transport: .a2a))
        var probes: [JSONValue] = []
        var authenticationBlocked = false
        func finish(_ status: String, _ detail: String, transport: AgentPeerTransport? = nil,
                    endpoint: URL? = nil) -> Result {
            Result(transport: transport, endpoint: endpoint, evidence: .object([
                "status": .string(status), "detail": .string(detail), "probes": .array(probes),
                "message_sent": .bool(false), "untrusted_remote_data": .bool(true),
                "supported_transports": .array([.string("a2a"), .string("nativeAgent")])]))
        }
        for url in candidates(for: endpoint) {
            try Task.checkCancellation()
            let response: AgentPeerHTTP.Response
            do { response = try await AgentPeerHTTP.get(url, bearerToken: bearerToken, timeout: 5) }
            catch {
                if Task.isCancelled { throw CancellationError() }
                probes.append(.object(["url": .string(url.absoluteString), "status": .string("unavailable")]))
                continue
            }
            probes.append(.object(["url": .string(url.absoluteString), "http_status": .int(Int64(response.statusCode))]))
            if response.statusCode == 401 || response.statusCode == 403 {
                authenticationBlocked = true
                continue
            }
            guard (200..<300).contains(response.statusCode), case .object(let card)? = response.json else { continue }
            if card["protocol"] == .string("nativeagent-bridge") {
                guard card["version"] == .string("1.0"), url.path.hasSuffix("/agent/card"),
                      case .object(let message)? = card["message"], case .object(let reply)? = card["reply"],
                      message["method"] == .string("POST"), message["path"] == .string("/agent/message"),
                      message["text_field"] == .string("text"), message["session_field"] == .string("sessionId"),
                      reply["method"] == .string("POST"), reply["path"] == .string("/agent/reply"),
                      reply["request_field"] == .string("request_id"), reply["session_field"] == .string("session_id"),
                      case .object(let auth)? = card["authentication"], auth["scheme"] == .string("bearer"),
                      case .bool(let required)? = auth["required"] else {
                    return finish("unsupported", "NativeAgent card does not advertise the supported version, message/reply contract, or authentication scheme.")
                }
                guard !required || bearerToken != nil else {
                    return finish("auth_required", "NativeAgent requires this peer's bearer credential. No contact was saved.")
                }
                let base = url.deletingLastPathComponent().deletingLastPathComponent()
                return finish("discovered", "Validated NativeAgent 1.0 message and exact-receipt interfaces. No message sent.", transport: .nativeAgent, endpoint: base)
            }
            guard card["protocolVersion"] != nil || card["supportedInterfaces"] != nil else { continue }
            guard case .string(let name)? = card["name"], !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  case .object? = card["capabilities"], case .array? = card["skills"] else {
                return finish("unsupported", "Advertised A2A card is missing its name, capabilities, or skills contract. Ask its owner for a complete supported agent card.")
            }
            let selected: AgentA2AWire.Interface
            do { selected = try AgentA2AWire.selectInterface(card: .object(card), cardURL: url) }
            catch { return finish("unsupported", "Agent card has no supported A2A version/binding or requires an unsupported extension. Ask its owner for A2A 0.3 JSONRPC or 1.0 JSONRPC/HTTP+JSON.") }
            do { try SwiftToolDispatcher.peerAuthorizeInterface(selected, cardURL: url, hasCredential: bearerToken != nil) }
            catch {
                // Only classify missing credentials when the exact interface
                // would be usable with our supported bearer authentication.
                if bearerToken == nil,
                   (try? SwiftToolDispatcher.peerAuthorizeInterface(selected, cardURL: url, hasCredential: true)) != nil {
                    return finish("auth_required", "The advertised A2A interface requires this peer's bearer credential. No contact was saved.")
                }
                return finish("unsupported", "Advertised interface requires unsupported authentication or a different origin. Ask its owner for a same-origin supported agent card; no credential was forwarded to that interface.")
            }
            return finish("discovered", "Validated advertised A2A \(selected.version) \(selected.binding) interface. Messaging and task reads are supported; no message sent.", transport: .a2a, endpoint: url)
        }
        if authenticationBlocked {
            return finish("auth_required", "Discovery encountered access requirements. Supply this peer's bearer credential or ask its owner for a supported authenticated agent endpoint; no contact was saved.")
        }
        return finish("needs_setup", "No supported agent card was found in bounded discovery. Supply an exact agent-card URL or ask this system's owner to expose A2A or NativeAgent bridge access. A website or model API alone is not an agent session endpoint.")
    }
}
