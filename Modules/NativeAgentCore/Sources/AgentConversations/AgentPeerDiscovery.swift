import AuthoredCapabilities
import AgentLinkTransport
import AgentWorkspace
import Foundation
import MacControl
import NativeAgentCore
import PersistenceCore
import ProviderRouting

/// Bounded read-only discovery. A website, an HTTP success, or an unsupported
/// protocol is not a connected agent. No contact or credential is written here.
package enum AgentPeerDiscovery {
    /// Use the authenticated card for this call only. Never persist it into
    /// public discovery or forward the credential to a newly declared origin.
    /// Returns the interface and the card it was chosen from.
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

    /// THE A2A CHECK, before every A2A call and as the whole of its dry run
    /// (`AgentRecipeStore.dryRun`, background health): the card read where
    /// the recipe says, with the credential it names, and the interface the
    /// card (its extended card, when there is one) offers. A send is held to
    /// what the recipe recorded: a card this app cannot speak is
    /// `protocol_mismatch`, one whose interface, auth or offer changed is
    /// `recipe_mismatch` naming each field, and neither sends anything; a
    /// recipe that never read its card records it. A dry run adds one task
    /// listing (1.0, the one safe call that proves auth) and learns a change
    /// into the recipe, except a skill the recipe names that the card dropped:
    /// that one is hers to decide. Returns the interface to go on with and the
    /// recipe it was held to, or the receipt that ends the call.
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
        func origin(_ url: URL) -> String { "\(url.scheme?.lowercased() ?? "")://\(url.host?.lowercased() ?? ""):\(url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80))" }
        guard let cardURL = URL(string: part.card), origin(cardURL) == origin(peer.endpoint) else {
            return refused("its recipe's a2a.card \(part.card) is not on its own origin \(origin(peer.endpoint))")
        }
        guard part.credential == peer.credentialKey else {
            return refused("its recipe's a2a.credential \(part.credential ?? "none") names no key it has; its key is \(peer.credentialKey ?? "none")")
        }
        var card: JSONValue?
        func stopped(_ error: Error, at method: String) -> (AgentA2AWire.Interface?, AgentRecipeStore.Recipe?, [String: JSONValue]) {
            receipt["method"] = .string(method)
            receipt["untrusted_remote_data"] = .bool(true)
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
                    + "this app speaks A2A 0.3 JSONRPC and 1.0 JSONRPC, HTTP+JSON or GRPC. Nothing was sent.")
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

    /// What a card offers, as its recipe records it (`AgentHostRow.A2A.Card`).
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

    static func localCandidates(installedHosts: [AgentHostRow]) -> [URL] {
        let ports = Set(installedHosts.flatMap(\.a2aPorts)).filter { (1...65535).contains($0) }.sorted()
        return ports.flatMap { port in
            ["127.0.0.1", "[::1]"].flatMap { host in
                ["agent-card.json", "agent.json"].map { URL(string: "http://\(host):\(port)/.well-known/\($0)")! }
            }
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
        var candidate = AgentDiscoveryCandidate(name: name, detail: description, hostID: nil,
                                                settingsPath: nil, cardURL: url, endpoint: selected.endpoint)
        candidate.foundBy = ["a2a: " + url.absoluteString]
        if case .string(let version)? = card["version"] { candidate.version = String(version.prefix(64)) }
        return candidate
    }

    /// Whole words of an app's name that mark an agent app. Such an app with
    /// no recipe is reported, never connected: no transport is guessed.
    static let agentAppWords: Set<String> = ["claude", "codex", "cursor", "zed", "lmstudio", "ollama", "muse", "endo",
                                             "grok", "gemini", "antigravity", "goose", "hermes", "dot"]

    /// Every running program's path, from the process table. Nothing is run.
    static func runningPrograms() -> [String] {
        var pids = [pid_t](repeating: 0, count: Int(max(0, proc_listallpids(nil, 0))) + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride)))
        return pids.prefix(max(0, count)).compactMap { pid in
            var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            return length > 0 ? String(decoding: buffer.prefix(Int(length)), as: UTF8.self) : nil
        }
    }

    static func appInfo(_ app: URL) -> NSDictionary? { NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) }

    package typealias Bundle = MacAppIndex.App

    static func bundles() async throws -> [Bundle] {
        try await MacAppIndex.shared.apps()
    }

    static func apps(_ bundles: [Bundle]) -> [(url: URL, info: NSDictionary, id: String)] {
        bundles.compactMap { app in
            guard let id = app.bundleID, let info = app.info else { return nil }
            return (app.url, info, id)
        }
    }

    /// The app's own program among the running ones, not a helper or updater inside it.
    static func running(_ app: URL, _ info: NSDictionary?, in programs: [String]) -> [String] {
        guard let name = info?["CFBundleExecutable"] as? String else { return [] }
        let main = app.path + "/Contents/MacOS/" + name
        return programs.contains(main) ? ["process: " + main] : []
    }

    /// Five read-only sources, each tagged on what it saw (`foundBy`): Launch
    /// Services and the Mac's app index, program folders, MCP settings
    /// files, running programs, and A2A cards on declared loopback ports. A
    /// recipe is a candidate on any program evidence (an app, a program file, a
    /// running program); a settings file alone only adds to what was seen. It
    /// is `connectable` when connecting would find it too. An agent-named app
    /// no recipe knows is one with no connect path. A program file is only
    /// looked at, never run, whatever its name.
    static func scanLocal(_ bundles: [Bundle]) async -> [AgentDiscoveryCandidate] {
        let programs = runningPrograms()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default
        let named = apps(bundles).filter { app in
            let words = app.url.deletingPathExtension().lastPathComponent.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            // A background-only helper (a URL handler) is not an agent to talk to.
            return !agentAppWords.isDisjoint(with: words + [words.joined()]) && app.info["LSBackgroundOnly"] as? Bool != true
        }
        var results: [AgentDiscoveryCandidate] = []
        for row in AgentHostDirectory.rows {
            var apps = row.bundleIDs.compactMap(AgentHostRow.applicationURL).map { ($0, appInfo($0)) }
            for app in named where row.bundleIDs.contains(app.id) && !apps.contains(where: { $0.0.path == app.url.path }) {
                apps.append((app.url, app.info))
            }
            let names = Set([row.id] + [row.acp?.executable, row.commandLine?.executable].compactMap { $0 })
            // Its own program folders, exactly as connecting resolves through them.
            var paths: [(folder: String, path: String)] = []
            for name in names.sorted() {
                for folder in row.programFolders.map(AgentHostDirectory.expand) {
                    guard let path = AgentHostCommandLines.resolveExecutable(name, directories: [folder], home: home) else { continue }
                    paths.append((folder, path))
                    break
                }
            }
            let running = apps.flatMap { running($0.0, $0.1, in: programs) }
                + programs.filter { names.contains(($0 as NSString).lastPathComponent) }.prefix(1).map { "process: " + $0 }
            guard !apps.isEmpty || !paths.isEmpty || !running.isEmpty else { continue }
            let own = Set(row.searchPaths.map(AgentHostDirectory.expand))
            let outside = paths.map(\.folder).first { !own.contains($0) }, installed = row.isInstalled
            var candidate = AgentDiscoveryCandidate(name: row.displayName,
                detail: !installed ? "Found on this Mac, but not where connecting looks for it, so it cannot be connected yet."
                    : outside.map { "Installed on this Mac, in \($0)." } ?? "Installed on this Mac.",
                hostID: row.id, settingsPath: row.settingsSupported ? row.expandedConfigPath : nil, cardURL: nil, endpoint: nil)
            candidate.connectable = installed
            candidate.foundBy = apps.map { "app: " + $0.0.path } + paths.map { "path: " + $0.path }
                + (row.configPaths ?? []).map(AgentHostDirectory.expand).filter { fm.fileExists(atPath: $0) }.map { "config: " + $0 }
                + running
            candidate.version = apps.lazy.compactMap { $0.1?["CFBundleShortVersionString"] as? String }.first ?? paths.first
                .flatMap { (try? fm.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date }
                .map { "program changed " + ISO8601DateFormatter().string(from: $0) }
            results.append(candidate)
        }
        let known = Set(AgentHostDirectory.rows.flatMap(\.bundleIDs))
        for app in named where !known.contains(app.id) && !results.contains(where: { $0.appBundleID == app.id }) {
            var candidate = AgentDiscoveryCandidate(name: String(app.url.lastPathComponent.dropLast(4)),
                detail: "An agent app with no recipe yet: there is no way to connect it from here.",
                hostID: nil, settingsPath: nil, cardURL: nil, endpoint: nil)
            candidate.appBundleID = app.id
            candidate.connectable = false
            candidate.version = app.info["CFBundleShortVersionString"] as? String
            candidate.foundBy = ["app: " + app.url.path] + running(app.url, app.info, in: programs)
            results.append(candidate)
        }
        // One card per agent: the agent-card.json path wins when it serves both.
        var cards: [AgentDiscoveryCandidate] = []
        await withTaskGroup(of: AgentDiscoveryCandidate?.self) { group in
            for url in localCandidates(installedHosts: AgentRecipeStore.rows) {
                group.addTask { try? await localCard(url) }
            }
            for await candidate in group { if let candidate { cards.append(candidate) } }
        }
        var endpoints: Set<URL> = []
        results += cards.sorted { $0.id < $1.id }.filter { endpoints.insert($0.endpoint!).inserted }
        return results.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
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
            do { try AgentPeerPolicy.peerAuthorizeInterface(selected, cardURL: url, hasCredential: bearerToken != nil) }
            catch {
                // Only classify missing credentials when the exact interface
                // would be usable with our supported bearer authentication.
                if bearerToken == nil,
                   (try? AgentPeerPolicy.peerAuthorizeInterface(selected, cardURL: url, hasCredential: true)) != nil {
                    return finish("auth_required", "The advertised A2A interface requires this peer's bearer credential. No contact was saved.")
                }
                return finish("unsupported", "Advertised interface requires unsupported authentication or a different origin. Ask its owner for a same-origin supported agent card; no credential was forwarded to that interface.")
            }
            let authenticated: AgentA2AWire.Interface
            do { authenticated = try await authenticatedInterface(card: .object(card), cardURL: url, bearerToken: bearerToken).0 }
            catch {
                if let failure = ProviderFailure.report(error, work: .nothingRan) {
                    var fields: [String: JSONValue] = ["message_sent": .bool(false)]
                    AgentPeerPolicy.peerFailure(failure, into: &fields)
                    return Result(transport: nil, endpoint: nil, evidence: .object(fields))
                }
                return finish(bearerToken == nil ? "auth_required" : "unsupported", "Could not validate the authenticated extended agent card. No contact was saved.")
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

/// Session-only observations. These never write contacts, settings or credentials.
public struct AgentDiscoveryCandidate: Sendable, Equatable, Identifiable {
    public let name: String
    public let detail: String
    public let hostID: String?
    public let settingsPath: String?
    public let cardURL: URL?
    public let endpoint: URL?
    /// Each source that saw it, and where: "app: …", "path: …", "config: …",
    /// "process: …", "a2a: …".
    public var foundBy: [String] = []
    /// What it reports as its version (or when its program last changed); a
    /// decline holds until this changes.
    public var version: String?
    /// An agent-named app no recipe knows: reported, with no connect path.
    public var appBundleID: String?
    /// Connecting would find it too (`AgentHostRow.isInstalled`, or a card).
    public var connectable = true
    public init(name: String, detail: String, hostID: String?, settingsPath: String?, cardURL: URL?, endpoint: URL?) {
        self.name = name
        self.detail = detail
        self.hostID = hostID
        self.settingsPath = settingsPath
        self.cardURL = cardURL
        self.endpoint = endpoint
    }
    public var id: String { hostID ?? cardURL?.absoluteString ?? "app:" + appBundleID! }

    package var projection: JSONValue {
        var fields: [String: JSONValue] = [
            "name": .string(name), "description": .string(detail),
            "kind": .string(hostID != nil ? "agent_host" : cardURL != nil ? "a2a_agent" : "agent_app"),
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
        if !connectable { fields["setup"] = nil; fields["description"] = .string(detail) }
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

/// Opening Agents, explicitly asking to discover, launch and an install refresh
/// this session cache. Ordinary contact reads never initiate discovery,
/// including before the first refresh. Each refresh offers what is new
/// (`AgentDiscoveryOffer`): one wake item for her and one home line.
public actor AgentDiscoverySession {
    public static let shared = AgentDiscoverySession()
    private var cached: [AgentDiscoveryCandidate]?
    private var pending: Task<[AgentDiscoveryCandidate], Never>?
    private var installs: Task<Void, Never>?
    private var indexErrorLogged = false
    private let scan: @Sendable ([AgentPeerDiscovery.Bundle]) async -> [AgentDiscoveryCandidate]

    init(scan: @escaping @Sendable ([AgentPeerDiscovery.Bundle]) async -> [AgentDiscoveryCandidate] = AgentPeerDiscovery.scanLocal) {
        self.scan = scan
    }

    public func candidates(refresh: Bool = false, dataRoot: URL) async -> [AgentDiscoveryCandidate] {
        if let pending { return await pending.value }
        if !refresh { return cached ?? [] }
        let scan = scan
        let task = Task {
            let bundles: [AgentPeerDiscovery.Bundle]
            do { bundles = try await AgentPeerDiscovery.bundles() }
            catch { logIndexError(error); bundles = [] }
            nativeLog("AgentDiscoverySession: discovery scan started")
            return await scan(bundles)
        }
        pending = task
        let result = await task.value
        nativeLog("AgentDiscoverySession: discovery scan finished")
        cached = result
        pending = nil
        offer(result, dataRoot: dataRoot)
        return result
    }

    private func logIndexError(_ error: Error) {
        guard !indexErrorLogged else { return }
        indexErrorLogged = true
        nativeLog("AgentDiscoverySession: app index unavailable: %@", error.localizedDescription)
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
        guard installs == nil else { return }
        installs = Task {
            do {
                for await _ in try await MacAppIndex.shared.changes() {
                    arrived(try await AgentPeerDiscovery.bundles(), dataRoot: dataRoot)
                    if pending == nil { Task { _ = await candidates(refresh: true, dataRoot: dataRoot) } }
                }
            } catch {
                installs = nil
                logIndexError(error)
            }
        }
    }

    /// After agent_connect: a connection ends its offer in the same call.
    public func settle(dataRoot: URL) { offer(cached ?? [], dataRoot: dataRoot) }

    private static func key(_ id: String) -> String { "agent.found." + id }

    /// A candidate new to discovery.json (or declined at another version) is
    /// offered once; a connected one is marked and its offer withdrawn.
    private func offer(_ found: [AgentDiscoveryCandidate], dataRoot: URL) {
        // Without the contacts nothing can be called unconnected.
        let peers: [AgentPeerContact]
        do { peers = try AgentPeerStore(dataRoot: dataRoot).list() }
        catch { return nativeLog("AgentDiscoverySession: contacts do not read (%@); no offers this pass", error.localizedDescription) }
        let hosts = Set(peers.compactMap { AgentPeerStore.hostRowID($0.endpoint) })
        guard var offers = AgentDiscoveryOffer.read(dataRoot) else {
            return nativeLog("AgentDiscoverySession: %@ does not read; no offers until it is fixed or removed", AgentDiscoveryOffer.url(dataRoot).path)
        }
        let before = offers, now = Date()
        var items: [ResidentWake.Item] = []
        for candidate in found {
            let row = AgentHostDirectory.rows.first { $0.id == candidate.hostID }
            // A workspace row needs a folder first; its app's own offer covers it.
            // A recipe connecting would not find is reported, never offered.
            guard row?.requiresWorkspace != true, candidate.connectable || candidate.appBundleID != nil else { continue }
            var entry = offers[candidate.id] ?? AgentDiscoveryOffer(name: candidate.name)
            if candidate.hostID.map(hosts.contains)
                ?? peers.contains(where: { $0.endpoint == candidate.cardURL || $0.endpoint == candidate.endpoint }) {
                if entry.connectedAt == nil {
                    entry.connectedAt = now
                    ResidentWake.shared.withdraw(dataRoot: dataRoot, key: Self.key(candidate.id))
                }
            } else if entry.connectedAt == nil, entry.offeredAt == nil || entry.declinedAt != nil && entry.version != candidate.version {
                entry.offeredAt = now; entry.declinedAt = nil; entry.version = candidate.version
                let place = candidate.foundBy.joined(separator: "; ")
                items.append(.init(id: Self.key(candidate.id) + ":" + (candidate.version ?? ""), line: candidate.appBundleID != nil
                    ? "Found \"\(candidate.name)\" on this Mac (no recipe yet): \(place)"
                    : "Found \"\(candidate.name)\" on this Mac (\(place)), not connected. Connect: agent.connect; not wanted: agent.discovery_dismiss.",
                    // A card names itself, and an app no recipe knows names
                    // itself on disk: that text carries an unidentified peer's
                    // provenance, so it waits for the wake and never lands in
                    // an untainted turn (ResidentWake.take).
                    key: Self.key(candidate.id), agent: candidate.hostID == nil ? "another agent" : nil))
            } else if entry.open {
                // An open offer keeps the version scanned now, so a decline holds that one.
                entry.version = candidate.version
            } else { continue }
            offers[candidate.id] = entry
        }
        // An offer counts only once its wake is kept; otherwise the next pass offers it again.
        if !items.isEmpty, !ResidentWake.shared.request(dataRoot: dataRoot, reason: "an agent found on this Mac", items: items) {
            nativeLog("AgentDiscoverySession: the wake for %ld found agents was not kept; offering again next pass", items.count)
            for id in offers.keys where offers[id]?.offeredAt == now { offers[id] = before[id] }
        }
        guard offers != before else { return }
        do { try AgentDiscoveryOffer.write(offers, dataRoot) }
        catch { nativeLog("AgentDiscoverySession: could not keep offers: %@", error.localizedDescription) }
    }

    /// agent.discovery_dismiss: the person's or her "no". Quiet until its version changes.
    public func dismiss(name: String, dataRoot: URL) -> JSONValue {
        guard var offers = AgentDiscoveryOffer.read(dataRoot) else {
            return .object(["status": .string("failed"), "changed": .bool(false),
                "detail": .string("\(AgentDiscoveryOffer.url(dataRoot).path) does not read, so nothing was declined. Fix or remove that file, then decline again.")])
        }
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        func named(_ id: String, _ offer: AgentDiscoveryOffer) -> Bool {
            offer.open && [id, offer.name].contains { $0.caseInsensitiveCompare(wanted) == .orderedSame }
        }
        guard let id = offers.keys.sorted().first(where: { named($0, offers[$0]!) }) else {
            return .object(["status": .string("not_found"), "changed": .bool(false),
                "detail": .string("No open offer of an agent found on this Mac is named \"\(wanted)\". Home's PEOPLE lines name each one.")])
        }
        offers[id]?.declinedAt = Date()
        do { try AgentDiscoveryOffer.write(offers, dataRoot) }
        catch { return .object(["status": .string("failed"), "changed": .bool(false), "detail": .string("Could not save the decline: \(error.localizedDescription). Try again.")]) }
        ResidentWake.shared.withdraw(dataRoot: dataRoot, key: Self.key(id))
        return .object(["status": .string("declined"), "changed": .bool(true), "name": .string(offers[id]!.name),
            "detail": .string("Not offered again until its version changes. Nothing on this Mac was changed.")])
    }
}
