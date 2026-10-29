import AgentLinkTransport
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import ChatTurnContracts
import ChatToolParsing
import AgentWorkspace
import ApprovalInbox
import StandingBots
import TurnTrace
import CryptoKit
import MacControl
import os
// Blueprint: | `AgentA2ACard.swift` | `AgentPeerDiscovery` card exchange: `authenticatedInterface`, `a2aCheck` hold every A2A call and dry run to the recipe's effective card, auth and offer; `listTasks` proves 1.0 auth; `resolve` validates A2A and NativeAgent endpoints without saving contacts or sending messages. |

extension AgentPeerDiscovery {
    /// Return the selected, authorized interface and effective card; authorize extended cards again.
    /// Never expose it through public discovery or forward credentials to a newly declared origin.
    package static func authenticatedInterface(card: JSONValue, cardURL: URL, bearerToken: String?) async throws -> (AgentA2AWire.Interface, JSONValue) {
        var selected = try AgentA2AWire.selectInterface(card: card, cardURL: cardURL)
        try AgentPeerPolicy.peerAuthorizeInterface(selected, cardURL: cardURL, hasCredential: bearerToken != nil)
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
            try AgentPeerPolicy.peerAuthorizeInterface(selected, cardURL: cardURL, hasCredential: true)
            return (selected, extended)
        }
        return (selected, card)
    }

    /// Before A2A calls and dry runs, read the recipe's card with its credential and select its effective interface.
    /// Unsupported cards stop with `protocol_mismatch`; interface, auth or offer drift stops sends with
    /// `recipe_mismatch` and its fields. First reads are recorded; dry runs learn changes except dropped skills.
    /// A 1.0 dry run also lists one task to prove auth. Return the interface and recipe, or the terminal receipt.
    package static func a2aCheck(_ peer: AgentPeerContact, bearerToken: String?, sending: Bool)
        async -> (interface: AgentA2AWire.Interface?, recipe: AgentRecipeStore.Recipe?, receipt: [String: JSONValue]) {
        let dryRun = AgentRecipeStore.dryRun
        var receipt: [String: JSONValue] = ["status": .string(dryRun ? "failed" : "unavailable"), "agent": .string("peer:" + peer.id),
            "transport": .string("a2a"), "sent": .bool(false), "completed": .bool(false)]
        if dryRun { receipt["dry_run"] = .bool(true) }
        func refused(_ detail: String) -> (AgentA2AWire.Interface?, AgentRecipeStore.Recipe?, [String: JSONValue]) {
            receipt["detail"] = .string("\(peer.name): \(detail). Nothing was sent.")
            return (nil, nil, receipt)
        }
        let recipe: AgentRecipeStore.Recipe
        do { recipe = try AgentRecipeStore.recipe(for: peer) } catch { return refused("\(error). Fix that file, or delete it to have it seeded again") }
        guard let part = recipe.host.a2a else { return refused("agents/recipes/\(peer.id).json has no a2a part, so its card is not known") }
        // The card's place may move within the contact's own origin; its credential goes nowhere else.
        guard let cardURL = URL(string: part.card), AgentPeerPolicy.origin(cardURL) == AgentPeerPolicy.origin(peer.endpoint) else {
            return refused("its recipe's a2a.card \(part.card) is not on its own origin \(AgentPeerPolicy.origin(peer.endpoint))")
        }
        guard part.credential == peer.credentialKey else {
            return refused("its recipe's a2a.credential \(part.credential ?? "none") names no key it has; its key is \(peer.credentialKey ?? "none")")
        }
        var card: JSONValue?
        func stopped(_ error: Error, at method: String) -> (AgentA2AWire.Interface?, AgentRecipeStore.Recipe?, [String: JSONValue]) {
            receipt["method"] = .string(method)
            receipt["untrusted_remote_data"] = .bool(true)
            if let failure = error as? ToolFailureError {
                receipt.merge(failure.failureEvidence(defaultCode: "agent_check_failed", defaultOwner: peer.name)) { _, owned in owned }
                receipt["detail"] = .string(failure.message)
                return (nil, nil, receipt)
            }
            switch error as? AgentA2AWire.WireError {
            case .invalid?, .unsupported?:
                // What the card advertises, against what this app speaks.
                let fields: [String: JSONValue] = if case .object(let fields)? = card { fields } else { [:] }
                let interfaces: [JSONValue] = if case .array(let list)? = fields["supportedInterfaces"] { list }
                    else { [.object(["protocolVersion": fields["protocolVersion"] ?? .null, "protocolBinding": fields["preferredTransport"] ?? .string("JSONRPC")])] }
                let advertised = interfaces.compactMap { item -> String? in
                    guard case .object(let entry) = item, case .string(let version)? = entry["protocolVersion"],
                          case .string(let binding)? = entry["protocolBinding"] else { return nil }
                    return version + " " + binding
                }.joined(separator: ", ")
                receipt["reason"] = .string("protocol_mismatch")
                if !advertised.isEmpty { receipt["protocol_version"] = .string(advertised) }
                if case .string(let version)? = fields["version"] { receipt["program_version"] = .string(version) }
                receipt["detail"] = .string("\(peer.name): \(method) — \(error.localizedDescription). It advertises \(advertised.isEmpty ? "no readable interface" : advertised); "
                    + "this app speaks \(AgentA2AWire.spoken). Nothing was sent.")
            default:
                if let failure = ProviderFailure.report(error, work: .nothingRan) { AgentPeerPolicy.peerFailure(failure, into: &receipt) }
                else { receipt["detail"] = .string("\(peer.name): \(method) — \(error.localizedDescription) Nothing was sent.") }
                if dryRun { receipt["status"] = .string("failed") }
            }
            return (nil, nil, receipt)
        }
        let selected: AgentA2AWire.Interface, read: AgentHostRow.A2A.Card
        do {
            let response = try await AgentPeerHTTP.get(cardURL, bearerToken: bearerToken)
            guard (200..<300).contains(response.statusCode) else {
                throw ProviderFailure.Report(cause: .http(status: response.statusCode,
                    detail: (try? response.json?.serialize(pretty: false)) ?? ""), work: .nothingRan)
            }
            guard let json = response.json else { throw AgentA2AWire.WireError.invalid("agent card is not JSON") }
            card = json
            let (interface, effective) = try await authenticatedInterface(card: json, cardURL: cardURL, bearerToken: bearerToken)
            selected = interface
            read = a2aRead(effective, interface)
        } catch { return stopped(error, at: "agent card") }
        let recorded = part.read
        let drift = recorded.map { AgentHostRow.A2A.Card.drift($0, read) } ?? []
        // Values the card wrote: labelled as the peer's wherever they appear.
        if !drift.isEmpty { receipt["untrusted_remote_data"] = .bool(true) }
        // A send stops for what it relies on; a card whose text alone changed
        // (its digest) still sends, and its next dry run records it.
        let relied = drift.filter { !$0.hasPrefix("digest:") }
        if sending, !dryRun, !relied.isEmpty {
            receipt["reason"] = .string("recipe_mismatch")
            receipt["method"] = .string("agent card")
            receipt["fields"] = .array(relied.map { .string(String($0.prefix { $0 != ":" })) })
            receipt["detail"] = .string("\(peer.name)'s card no longer matches its recipe — \(relied.joined(separator: "; ")). Nothing was sent.")
            return (nil, nil, receipt)
        }
        guard sending || dryRun else { return (selected, recipe, [:]) }
        // On 0.3 there is no safe call: the card answered, auth is unproven.
        let proven = selected.version == "1.0"
        if dryRun, proven {
            do { _ = try await listTasks(["pageSize": .int(1)], interface: selected, bearerToken: bearerToken) }
            catch { return stopped(error, at: "ListTasks") }
        }
        let dropped = (recorded?.skills ?? []).filter { !read.skills.contains($0) }
        if dryRun, !dropped.isEmpty {
            receipt["reason"] = .string("recipe_mismatch")
            receipt["method"] = .string("agent card")
            receipt["detail"] = .string("\(peer.name)'s card dropped \(dropped.joined(separator: ", ")), which its recipe names, so nothing was learned — "
                + "\(drift.joined(separator: "; ")). Nothing was sent.")
            return (nil, nil, receipt)
        }
        let answered = proven ? "\(peer.name) answered with its card, its auth and a task listing; nothing was sent."
            : "\(peer.name) answered with its card; auth unchecked — 0.3 has no safe call. Nothing was sent."
        var checked = recipe
        // A first read is recorded by a send too; a change only by a dry run.
        if read != recorded, dryRun || recorded == nil {
            var host = recipe.host
            host.a2a?.read = read
            do { checked = try AgentRecipeStore.learn(recipe, host: host) }
            catch {
                receipt["detail"] = .string("\(peer.name)'s recipe could not take what its card says (\(drift.isEmpty ? "its first read" : drift.joined(separator: "; "))): \(error). Nothing was sent.")
                return (nil, nil, receipt)
            }
        }
        guard dryRun else { return (selected, checked, [:]) }
        receipt["status"] = .string(!proven ? "unchecked" : recorded == nil || recorded == read ? "passed" : "repaired")
        receipt["recipe_version"] = .int(Int64(checked.recipeVersion))
        receipt["detail"] = .string(answered + (recorded == nil ? " Its card is recorded in recipe v\(checked.recipeVersion)." : ""))
        if recorded != nil, recorded != read {
            receipt["healed"] = .string("\(peer.name): \(drift.joined(separator: "; ")) — recipe updated to v\(checked.recipeVersion)")
        }
        return (nil, checked, receipt)
    }

    /// Selected effective-card evidence, including its digest, for the recipe (`AgentHostRow.A2A.Card`).
    private static func a2aRead(_ card: JSONValue, _ interface: AgentA2AWire.Interface) -> AgentHostRow.A2A.Card {
        let fields: [String: JSONValue] = if case .object(let fields) = card { fields } else { [:] }
        func strings(_ list: JSONValue?, _ key: String) -> [String] {
            guard case .array(let items)? = list else { return [] }
            return items.compactMap { item -> String? in
                guard case .object(let item) = item, case .string(let value)? = item[key] else { return nil }
                return value
            }.sorted()
        }
        var auth: Set<String> = []
        if case .array(let alternatives) = interface.securityRequirements, case .object(let schemes) = interface.securitySchemes {
            for case .object(let entry) in alternatives {
                var names = entry
                if interface.version == "1.0" { names = if case .object(let named)? = entry["schemes"] { named } else { [:] } }
                for name in names.keys { auth.insert(name + ": " + ((try? schemes[name]?.serialize(pretty: false)) ?? "undeclared")) }
            }
        }
        let capabilities: [String: JSONValue] = if case .object(let capabilities)? = fields["capabilities"] { capabilities } else { [:] }
        return .init(endpoint: interface.endpoint.absoluteString, version: interface.version, binding: interface.binding, tenant: interface.tenant,
                     auth: auth.sorted(), streaming: interface.streaming, pushNotifications: interface.pushNotifications,
                     extendedCard: interface.extendedAgentCard, skills: strings(fields["skills"], "id"),
                     extensions: strings(capabilities["extensions"], "uri"), digest: card.digest)
    }

    /// One ListTasks call: agent_read's listing, a dry run's check.
    package static func listTasks(_ filters: [String: JSONValue], interface: AgentA2AWire.Interface, bearerToken: String?,
                                  requestID: String = UUID().uuidString.lowercased()) async throws -> JSONValue {
        let listing = try AgentA2AWire.operationRequest("ListTasks", parameters: filters, interface: interface, requestID: requestID)
        let response = try await AgentPeerHTTP.send(listing, bearerToken: bearerToken)
        guard (200..<300).contains(response.statusCode), let payload = response.json else { throw AgentCommunicationError.invalid("task listing unavailable") }
        return try AgentA2AWire.normalizeTaskList(payload, interface: interface, requestID: listing.requestID)
    }

    package struct Result: Sendable {
        package let transport: AgentPeerTransport?
        package let endpoint: URL?
        package let evidence: JSONValue
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

    package static func resolve(_ endpoint: URL, bearerToken: String?) async throws -> Result {
        try AgentPeerStore.validate(AgentPeerContact(name: "Discovery", endpoint: endpoint, transport: .a2a))
        var probes: [JSONValue] = []
        var authenticationBlocked = false
        var providerFailure: ProviderFailure.Report?
        func finish(_ status: String, _ detail: String, transport: AgentPeerTransport? = nil,
                    endpoint: URL? = nil, card: URL? = nil, offer: String? = nil) -> Result {
            var evidence: [String: JSONValue] = [
                "status": .string(status), "detail": .string(detail), "probes": .array(probes),
                "message_sent": .bool(false), "untrusted_remote_data": .bool(true),
                "supported_transports": .array([.string("a2a"), .string("nativeAgent")])]
            // An unsupported contract is the peer's own card against what this app
            // speaks: nothing here is broken and nothing is owed. The card's owner
            // decides what it offers.
            if let card, let offer {
                evidence["remedy"] = Repair.why(owner: "the agent card at " + card.absoluteString,
                                                tap: "that agent's own setup, whose card must offer " + offer)
            }
            return Result(transport: transport, endpoint: endpoint, evidence: .object(evidence))
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
                    return finish("unsupported", "This NativeAgent card does not advertise bridge 1.0 with its message/reply contract and bearer authentication. No contact was saved.",
                                  card: url, offer: "NativeAgent bridge 1.0 (POST /agent/message and /agent/reply, bearer authentication)")
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
                return finish("unsupported", "This A2A card is missing its name, capabilities or skills. No contact was saved.",
                              card: url, offer: "a complete A2A card (name, capabilities and skills)")
            }
            let authenticated: AgentA2AWire.Interface
            do { authenticated = try await authenticatedInterface(card: .object(card), cardURL: url, bearerToken: bearerToken).0 }
            catch {
                switch error as? AgentA2AWire.WireError {
                case .invalid?, .unsupported?:
                    return finish("unsupported", "This A2A card offers nothing this app speaks (\(error.localizedDescription)); it speaks \(AgentA2AWire.spoken). No contact was saved.",
                                  card: url, offer: AgentA2AWire.spoken + ", with no required extension")
                default: break
                }
                if let failure = ProviderFailure.report(error, work: .nothingRan) {
                    var fields: [String: JSONValue] = ["message_sent": .bool(false)]
                    AgentPeerPolicy.peerFailure(failure, into: &fields)
                    return Result(transport: nil, endpoint: nil, evidence: .object(fields))
                }
                throw error
            }
            return finish("discovered", "Validated advertised A2A \(authenticated.version) \(authenticated.binding) interface. Messaging and task reads are supported; no message sent.", transport: .a2a, endpoint: url)
        }
        if let providerFailure {
            var fields: [String: JSONValue] = ["probes": .array(probes), "message_sent": .bool(false)]
            AgentPeerPolicy.peerFailure(providerFailure, into: &fields)
            return Result(transport: nil, endpoint: nil, evidence: .object(fields))
        }
        if authenticationBlocked {
            return finish("auth_required", "Discovery encountered access requirements. Supply this peer's bearer credential or ask its owner for a supported authenticated agent endpoint; no contact was saved.")
        }
        return finish("needs_setup", "No supported agent card was found in bounded discovery. Supply an exact agent-card URL or ask this system's owner to expose A2A or NativeAgent bridge access. A website or model API alone is not an agent session endpoint.")
    }
}
