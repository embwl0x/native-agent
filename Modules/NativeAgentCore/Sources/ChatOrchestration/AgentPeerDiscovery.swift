import Foundation
import PersistenceCore
import ProviderRouting

/// Bounded read-only discovery. A website, an HTTP success, or an unsupported
/// protocol is not a connected agent. No contact or credential is written here.
enum AgentPeerDiscovery {
    /// Use the authenticated card for this call only. Never persist it into
    /// public discovery or forward the credential to a newly declared origin.
    static func authenticatedInterface(card: JSONValue, cardURL: URL, bearerToken: String?) async throws -> AgentA2AWire.Interface {
        var selected = try AgentA2AWire.selectInterface(card: card, cardURL: cardURL)
        try SwiftToolDispatcher.peerAuthorizeInterface(selected, cardURL: cardURL, hasCredential: bearerToken != nil)
        if selected.extendedAgentCard, bearerToken != nil {
            let request = try AgentA2AWire.operationRequest("GetExtendedAgentCard", interface: selected)
            let response = try await AgentPeerHTTP.send(request, bearerToken: bearerToken)
            if !(200..<300).contains(response.statusCode) {
                throw ProviderFailure.Report(cause: .http(status: response.statusCode,
                    detail: (try? response.json?.serialize(pretty: false)) ?? ""), work: .nothingRan)
            }
            guard (200..<300).contains(response.statusCode), let payload = response.json else { throw AgentA2AWire.WireError.invalid("authenticated extended agent card unavailable") }
            let extended = try AgentA2AWire.operationResult(payload, interface: selected, requestID: request.requestID)
            selected = try AgentA2AWire.selectInterface(card: extended, cardURL: cardURL)
            try SwiftToolDispatcher.peerAuthorizeInterface(selected, cardURL: cardURL, hasCredential: true)
        }
        return selected
    }
    static func localCandidates(installedHosts: [AgentHostRow]) -> [URL] {
        let ports = Set(installedHosts.flatMap(\.a2aPorts)).filter { (1...65535).contains($0) }.sorted()
        return ports.flatMap { port in
            ["127.0.0.1", "[::1]"].map { URL(string: "http://\($0):\(port)/.well-known/agent-card.json")! }
        }
    }

    static func localCard(_ url: URL) async throws -> AgentDiscoveryCandidate? {
        // Validate before creating any request, including when a caller supplies a candidate.
        let response = try await AgentPeerHTTP.getLoopbackCard(url)
        guard (200..<300).contains(response.statusCode), case .object(let card)? = response.json,
              case .string(let name)? = card["name"], !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 480, case .object? = card["capabilities"], case .array? = card["skills"],
              let selected = try? AgentA2AWire.selectInterface(card: .object(card), cardURL: url) else { return nil }
        try AgentPeerHTTP.validateLoopbackCandidate(selected.endpoint)
        guard selected.endpoint.host == url.host, selected.endpoint.port == url.port else { return nil }
        let description: String
        if case .string(let text)? = card["description"] { description = String(text.prefix(500)) }
        else { description = "An agent running on this Mac." }
        return AgentDiscoveryCandidate(name: name, detail: description, hostID: nil,
                                       settingsPath: nil, cardURL: url, endpoint: selected.endpoint)
    }

    static func scanLocal() async -> [AgentDiscoveryCandidate] {
        let hosts = AgentHostDirectory.rows.filter(\.isInstalled)
        var results = hosts.map(installedCandidate)
        await withTaskGroup(of: AgentDiscoveryCandidate?.self) { group in
            for url in localCandidates(installedHosts: hosts) {
                group.addTask { try? await localCard(url) }
            }
            for await candidate in group { if let candidate { results.append(candidate) } }
        }
        return results.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    static func installedCandidate(_ row: AgentHostRow) -> AgentDiscoveryCandidate {
        AgentDiscoveryCandidate(name: row.displayName, detail: "Installed on this Mac.", hostID: row.id,
                                settingsPath: row.settingsSupported ? row.expandedConfigPath : nil,
                                cardURL: nil, endpoint: nil)
    }

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
        var providerFailure: ProviderFailure.Report?
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
            if response.statusCode >= 400 {
                let cause = ProviderFailure.http(status: response.statusCode,
                    detail: (try? response.json?.serialize(pretty: false)) ?? "")
                if cause != .refused { providerFailure = .init(cause: cause, work: .nothingRan) }
            }
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
            let authenticated: AgentA2AWire.Interface
            do { authenticated = try await authenticatedInterface(card: .object(card), cardURL: url, bearerToken: bearerToken) }
            catch {
                if let failure = ProviderFailure.report(error, work: .nothingRan) {
                    var fields: [String: JSONValue] = ["message_sent": .bool(false)]
                    SwiftToolDispatcher.peerFailure(failure, into: &fields)
                    return Result(transport: nil, endpoint: nil, evidence: .object(fields))
                }
                return finish(bearerToken == nil ? "auth_required" : "unsupported", "Could not validate the authenticated extended agent card. No contact was saved.")
            }
            return finish("discovered", "Validated advertised A2A \(authenticated.version) \(authenticated.binding) interface. Messaging and task reads are supported; no message sent.", transport: .a2a, endpoint: url)
        }
        if let providerFailure {
            var fields: [String: JSONValue] = ["probes": .array(probes), "message_sent": .bool(false)]
            SwiftToolDispatcher.peerFailure(providerFailure, into: &fields)
            return Result(transport: nil, endpoint: nil, evidence: .object(fields))
        }
        if authenticationBlocked {
            return finish("auth_required", "Discovery encountered access requirements. Supply this peer's bearer credential or ask its owner for a supported authenticated agent endpoint; no contact was saved.")
        }
        return finish("needs_setup", "No supported agent card was found in bounded discovery. Supply an exact agent-card URL or ask this system's owner to expose A2A or NativeAgent bridge access. A website or model API alone is not an agent session endpoint.")
    }
}

/// Session-only observations. These never write contacts, settings or credentials.
public struct AgentDiscoveryCandidate: Sendable, Equatable, Identifiable {
    public let name: String
    public let detail: String
    public let hostID: String?
    public let settingsPath: String?
    public let cardURL: URL?
    public let endpoint: URL?
    public init(name: String, detail: String, hostID: String?, settingsPath: String?, cardURL: URL?, endpoint: URL?) {
        self.name = name
        self.detail = detail
        self.hostID = hostID
        self.settingsPath = settingsPath
        self.cardURL = cardURL
        self.endpoint = endpoint
    }
    public var id: String { hostID ?? cardURL!.absoluteString }

    var projection: JSONValue {
        var fields: [String: JSONValue] = [
            "name": .string(name), "description": .string(detail),
            "kind": .string(hostID == nil ? "a2a_agent" : "agent_host"),
            "state": .string(AgentPeerContactState.listed.rawValue),
            "state_detail": .string(AgentPeerContactState.listed.detail),
            "capabilities": .array([]), "read_inputs": .array([])]
        let row = AgentHostDirectory.rows.first { $0.id == hostID }
        if row?.settingsSupported != false, let settingsPath, !settingsPath.isEmpty {
            fields["settings_file"] = .string(settingsPath)
            let workspace = row?.requiresWorkspace == true
            fields["setup"] = .string("agent_connect with name \"\(name)\""
                + (workspace ? " and workspace set to the folder the person chose." : " sets this one up."))
        }
        if let hostID, let row = AgentHostDirectory.row(named: hostID) {
            fields["route"] = .string(row.route.rawValue)
            // Seeing an installed host does not prove a usable connection.
            fields["can_start_turn"] = .bool(false)
            fields["can_answer_back"] = .bool(false)
            if let acp = row.acp {
                fields["setup"] = .string("Connect \(row.displayName) by name to review its executable and starting folder. It runs as you; this app asks only when the agent asks it.")
                fields["reference_version"] = .string(acp.referenceVersion)
            }
        }
        if let cardURL, let endpoint {
            fields["endpoint"] = .string(endpoint.absoluteString)
            fields["card_url"] = .string(cardURL.absoluteString)
            fields["transport"] = .string("a2a")
            fields["untrusted_remote_data"] = .bool(true)
            fields["setup"] = .string("Use agent_connect with this name and the card_url as endpoint. A connection may need its own key.")
        }
        return .object(fields)
    }
}

/// Opening Agents or explicitly asking to discover refreshes this session cache.
/// Ordinary contact reads never initiate discovery, including before the first refresh.
public actor AgentDiscoverySession {
    public static let shared = AgentDiscoverySession()
    private var cached: [AgentDiscoveryCandidate]?
    private var pending: Task<[AgentDiscoveryCandidate], Never>?
    private let scan: @Sendable () async -> [AgentDiscoveryCandidate]

    init(scan: @escaping @Sendable () async -> [AgentDiscoveryCandidate] = AgentPeerDiscovery.scanLocal) {
        self.scan = scan
    }

    public func candidates(refresh: Bool = false) async -> [AgentDiscoveryCandidate] {
        if let pending { return await pending.value }
        if !refresh { return cached ?? [] }
        let task = Task { await scan() }
        pending = task
        let result = await task.value
        cached = result
        pending = nil
        return result
    }
}
