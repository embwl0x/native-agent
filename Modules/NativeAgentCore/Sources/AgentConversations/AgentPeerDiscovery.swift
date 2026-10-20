import CryptoKit
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

    static func localCandidates(ports: Set<Int>) -> [URL] {
        ports.filter { (1...65535).contains($0) }.sorted().flatMap { port in
            ["127.0.0.1", "[::1]"].flatMap { host in
                ["agent-card.json", "agent.json"].map { URL(string: "http://\(host):\(port)/.well-known/\($0)")! }
            }
        }
    }

    static func localCard(_ url: URL) async throws -> AgentDiscoveryCandidate? {
        // Validate before creating any request, including when a caller supplies a candidate.
        // Nothing serving there is absence; a card served there that cannot be used is said.
        // Any listening port is asked, so only what reads as a card is one.
        guard let response = try? await AgentPeerHTTP.getLoopbackCard(url), (200..<300).contains(response.statusCode),
              case .object(let card)? = response.json, card["name"] != nil,
              ["skills", "capabilities", "protocolVersion", "supportedInterfaces"].contains(where: { card[$0] != nil }) else { return nil }
        guard case .string(let name)? = card["name"], !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 480, case .object? = card["capabilities"], case .array? = card["skills"],
              let selected = try? AgentA2AWire.selectInterface(card: .object(card), cardURL: url) else {
            throw AgentCommunicationError.invalid("\(url.absoluteString) serves an agent card this app cannot use (name, capabilities, skills and a supported interface are required)")
        }
        try AgentPeerHTTP.validateLoopbackCandidate(selected.endpoint)
        guard selected.endpoint.host == url.host, selected.endpoint.port == url.port else {
            throw AgentCommunicationError.invalid("\(url.absoluteString) advertised a different origin; no credential was forwarded")
        }
        let description: String
        if case .string(let text)? = card["description"] { description = String(text.prefix(500)) }
        else { description = "An agent running on this Mac." }
        var candidate = AgentDiscoveryCandidate(name: name, detail: description, hostID: nil,
                                                settingsPath: nil, cardURL: url, endpoint: selected.endpoint)
        candidate.foundBy = ["a2a: " + url.absoluteString]
        if case .string(let version)? = card["version"] { candidate.version = String(version.prefix(64)) }
        return candidate
    }

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

    /// The app's own program among the running ones, not a helper or updater inside it.
    static func running(_ app: URL, _ info: NSDictionary?, in programs: [String]) -> [String] {
        guard let name = info?["CFBundleExecutable"] as? String else { return [] }
        let main = app.path + "/Contents/MacOS/" + name
        return programs.contains(main) ? ["process: " + main] : []
    }

    /// Recipes own installation evidence; settings and running programs only
    /// annotate it. An app name alone establishes no messaging route.
    static func scanLocal(_ bundles: [Bundle]) async -> [AgentDiscoveryCandidate] {
        let programs = runningPrograms()
        let fm = FileManager.default
        var results: [AgentDiscoveryCandidate] = []
        if case .failure(let failure) = AgentHostCommandLines.loginEnvironment {
            var candidate = AgentDiscoveryCandidate(name: "Login shell", detail: failure.message,
                hostID: "login-shell", settingsPath: nil, cardURL: nil, endpoint: nil)
            candidate.connectable = false
            candidate.decision = Repair.why(owner: failure.owner!, tap: failure.tap!)
            results.append(candidate)
        }
        for row in AgentHostDirectory.rows {
            let binding = row.installation
            let apps = binding.applicationURL.map { [($0, appInfo($0))] } ?? []
            let paths = binding.executables.values.sorted()
            let resolved = Set(paths)
            var running = apps.flatMap { running($0.0, $0.1, in: programs) }
            running += programs.filter { resolved.contains($0) }
                .prefix(1).map { "process: " + $0 }
            let evidence = binding.evidence
            guard !evidence.isEmpty else { continue }
            var candidate = AgentDiscoveryCandidate(name: row.displayName,
                detail: "Installed: " + evidence.joined(separator: "; "),
                hostID: row.id, settingsPath: row.settingsSupported ? row.expandedConfigPath : nil, cardURL: nil, endpoint: nil)
            candidate.connectable = !binding.transports.isEmpty
            if let failure = binding.failure, case .success = AgentHostCommandLines.loginEnvironment {
                candidate.setupFailure = failure.message
                candidate.decision = Repair.why(owner: failure.owner!, tap: failure.tap!)
            }
            candidate.foundBy = evidence
                + (row.configPaths ?? []).map(AgentHostDirectory.expand).filter { fm.fileExists(atPath: $0) }.map { "config: " + $0 }
                + running
            candidate.version = apps.lazy.compactMap { $0.1?["CFBundleShortVersionString"] as? String }.first ?? paths.first
                .flatMap { (try? fm.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }
                .map { "program changed " + ISO8601DateFormatter().string(from: $0) }
            results.append(candidate)
        }
        return results
    }

    /// THE PROBES: what on this Mac speaks a protocol, never a list of names.
    /// One per signature (an A2A card on a listening loopback port, a program
    /// that carries ACP's methods or advertises an ACP entry, a settings file
    /// holding an mcpServers table), each find with what was observed. The
    /// recipe book is read after: a recipe that knows the find takes it
    /// (`hostID`, merged into its row's own pass); one none knows carries the
    /// recipe it would have (`draft`). Reading is all a probe does: a found
    /// program runs (its --help, then initialize) only when `launch` says it
    /// may, on an explicit discover, under the rule for running another
    /// agent's program. Bounded (a card read 0.6s, --help 1s, initialize 3s,
    /// all at once). Not checked: Bonjour (A2A names no service type, and a
    /// browse asks for Local Network access), and a chat window no recipe labels.
    static func probe(_ bundles: [Bundle], launch: Launch?) async -> [AgentDiscoveryCandidate] {
        async let programs = acpPrograms(bundles, launch: launch)
        async let settings = mcpSettings(bundles)
        // One card per agent: the agent-card.json path wins when it serves both.
        var cards: [AgentDiscoveryCandidate] = []
        await withTaskGroup(of: AgentDiscoveryCandidate?.self) { group in
            for url in localCandidates(ports: listeningPorts().union(AgentRecipeStore.rows.flatMap(\.a2aPorts))) {
                group.addTask {
                    do { return try await localCard(url) }
                    catch {
                        var failed = AgentDiscoveryCandidate(name: url.absoluteString, detail: error.localizedDescription,
                            hostID: nil, settingsPath: nil, cardURL: url, endpoint: nil)
                        failed.connectable = false
                        failed.setupFailure = error.localizedDescription
                        return failed
                    }
                }
            }
            for await candidate in group { if let candidate { cards.append(candidate) } }
        }
        var endpoints: Set<URL> = []
        // An id a recipe already holds is that recipe's: its draft is never offered over it.
        return await (programs + settings).map { found in
            guard let id = found.draft?.id, AgentRecipeStore.recipe(id) != nil else { return found }
            var held = found
            held.connectable = false
            held.setupFailure = "agents/recipes/\(id).json already holds a recipe that does not find this one (\(found.foundBy.first ?? found.name)), so its draft is not offered. Read it with agent.recipe."
            return held
        } + cards.sorted { $0.id < $1.id }.filter { endpoints.insert($0.endpoint ?? $0.cardURL!).inserted }
    }

    /// May a found program run (its --help, then initialize), as the caller's
    /// rule for running another agent's program decides: the command that runs
    /// it (bare, or inside the sandbox), or why it may not.
    package enum Launch: Sendable {
        case run(@Sendable (_ executable: String, _ arguments: [String]) -> [String])
        case refused(String)
    }

    /// THE ONE WAY A PROBE READS A FILE: a nonblocking open, fstat of a
    /// regular file of at most `limit` bytes, then bounded reads from that
    /// descriptor into owned bytes, chunk by chunk, until `each` says stop. A
    /// FIFO or device never blocks a pass, and no mapping can be truncated
    /// under it. False when it is no such file.
    static func readRegular(_ path: String, limit: Int64, _ each: (Data) -> Bool) -> Bool {
        let fd = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit else { return false }
        var left = Int(info.st_size), chunk = [UInt8](repeating: 0, count: 1 << 20)
        while left > 0 {
            let count = Darwin.read(fd, &chunk, min(chunk.count, left))
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            left -= count
            guard each(Data(chunk.prefix(count))) else { break }
        }
        return true
    }

    /// Every TCP port a program other than this app listens on, from the process table.
    static func listeningPorts() -> Set<Int> {
        var pids = [pid_t](repeating: 0, count: Int(max(0, proc_listallpids(nil, 0))) + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride)))
        var ports: Set<Int> = []
        for pid in pids.prefix(max(0, count)) where pid != getpid() {
            let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard size > 0 else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride)
            let listed = Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)) / MemoryLayout<proc_fdinfo>.stride
            for fd in fds.prefix(max(0, listed)) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                var info = socket_fdinfo()
                let length = Int32(MemoryLayout<socket_fdinfo>.stride)
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, length) == length,
                      info.psi.soi_kind == Int32(SOCKINFO_TCP), info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { continue }
                ports.insert(Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport))))
            }
        }
        return ports
    }

    /// ACP: a program on the login PATH, or a helper inside an app, that
    /// carries ACP's own methods (in its bytes or, a script a link names, the
    /// files beside it) or advertises an ACP entry (its name or launcher says
    /// acp, as a console script importing its ACP module does). Started the
    /// way its recipe, its own name or its --help's ACP entry says, it is sent
    /// initialize as the transport sends it, when `launch` lets it run. A
    /// client carries the methods too; only an agent answers, and only an
    /// answer is connectable.
    static func acpPrograms(_ bundles: [Bundle], launch: Launch?) async -> [AgentDiscoveryCandidate] {
        // Without the login PATH, its own row says why.
        guard case .success(let environment) = AgentHostCommandLines.loginEnvironment else { return [] }
        let fm = FileManager.default
        @Sendable func program(_ path: String) -> Bool {
            var info = stat()
            return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && access(path, X_OK) == 0
        }
        // Each file once, by the name it is called; the one its own file carries wins ("grok" for grok-macos-aarch64).
        var programs: [String: URL] = [:]
        let folders = (environment["PATH"] ?? "").components(separatedBy: ":").filter { $0.hasPrefix("/") }
        for folder in folders {
            for name in ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).sorted() {
                let link = URL(fileURLWithPath: folder).appendingPathComponent(name), file = link.resolvingSymlinksInPath()
                guard program(file.path) else { continue }
                if programs[file.path] == nil || (file.lastPathComponent.hasPrefix(name)
                    && !file.lastPathComponent.hasPrefix(programs[file.path]!.lastPathComponent)) { programs[file.path] = link }
            }
        }
        for app in bundles where app.kind == "installed" && !app.url.path.hasPrefix("/System/") {
            let main = app.info?["CFBundleExecutable"] as? String
            for folder in ["Contents/MacOS", "Contents/Helpers", "Contents/Resources/bin"].map(app.url.appendingPathComponent) {
                for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where folder.lastPathComponent != "MacOS" || name != main {
                    let link = folder.appendingPathComponent(name)
                    if program(link.resolvingSymlinksInPath().path) { programs[link.resolvingSymlinksInPath().path] = link }
                }
            }
        }
        let methods = ["session/new", "session/prompt"].map { Data($0.utf8) }
        @Sendable func says(_ text: some StringProtocol) -> Bool {
            text.range(of: #"(?<![A-Za-z])acp(?![A-Za-z])|agent client protocol"#, options: [.regularExpression, .caseInsensitive]) != nil
        }
        /// One read of a file: whether it carries the methods, and its first bytes.
        @Sendable func scan(_ path: String) -> (carries: Bool, head: Data)? {
            var missing = methods, window = Data(), head: Data?
            guard readRegular(path, limit: AgentACPExecutable.maximumBytes, { chunk in
                if head == nil { head = chunk.prefix(65_536) }
                window = window.suffix(16) + chunk
                missing.removeAll { window.range(of: $0) != nil }
                return !missing.isEmpty
            }) else { return nil }
            return (missing.isEmpty, head ?? Data())
        }
        /// What makes it an ACP candidate, read without running it: its methods, or its launcher naming acp.
        @Sendable func signature(_ path: String, beside: Bool) -> String? {
            guard let read = scan(path) else { return nil }
            if read.carries { return "carries ACP's session/new and session/prompt" }
            guard read.head.starts(with: Data("#!".utf8)) else { return nil }
            if says(String(decoding: read.head, as: UTF8.self)) { return "its launcher names acp" }
            guard beside else { return nil }
            let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
            let carried = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).contains {
                let file = folder.appendingPathComponent($0).path
                return file != path && !program(file) && scan(file)?.carries == true
            }
            return carried ? "the files beside it carry ACP's session/new and session/prompt" : nil
        }
        let rows = AgentHostDirectory.rows
        return await withTaskGroup(of: AgentDiscoveryCandidate?.self) { group in
            for (file, link) in programs {
                group.addTask {
                    let name = link.lastPathComponent
                    guard let why = says(name) ? "its name says acp" : signature(file, beside: link.path != file) else { return nil }
                    var seen = ["acp: \(link.path): \(why)"]
                    // A recipe she wrote from this find's own draft is its recipe, wherever it resolves now.
                    let row = rows.first { $0.installation.executables.values.contains(file) }
                        ?? AgentRecipeStore.recipe(recipeID(name, "acp", file)).flatMap { $0.seededFrom == "discovery" ? $0.host : nil }
                    var arguments = row?.acp?.arguments, answer: [String: JSONValue] = [:]
                    switch launch {
                    case nil:
                        seen.append("not run: its --help and initialize run on an explicit discover (agent.contacts {discover: true})")
                    case .refused(let why)?:
                        seen.append("not run: " + why)
                    case .run(let command)?:
                        // Run exactly the file that was read, as a send would.
                        guard let executable = try? AgentACPExecutable.capture(path: file) else { seen.append("not run: \(file) could not be read whole"); break }
                        // A program whose own name says acp is its entry.
                        if arguments == nil, says(name) { arguments = [] }
                        if arguments == nil, let help = try? await executable.reported(environment: environment,
                            command: command(file, ["--help"]), errors: true, grace: .seconds(1), limit: 65_536) {
                            arguments = acpEntry(help)
                        }
                        guard let arguments else { seen.append("entry: its --help names no ACP entry"); break }
                        seen.append("entry: \(([name] + arguments).joined(separator: " "))" + (row?.acp != nil ? " (its recipe)" : ""))
                        // The transport's own start, and nothing after it.
                        let started = command(file, arguments)
                        do {
                            if case .object(let result) = try await AgentACPClient().initialize(executable: started[0], arguments: Array(started.dropFirst()),
                                directory: FileManager.default.temporaryDirectory, environment: environment,
                                approvedExecutable: executable, timeout: .seconds(3)) { answer = result }
                            seen.append("initialize: answered ACP 1")
                        } catch let refused as AgentACPClient.Mismatch { seen.append("initialize: " + refused.detail) }
                        catch { seen.append("initialize: no ACP answer within 3s (\(error.localizedDescription))") }
                    }
                    let agent: [String: JSONValue] = if case .object(let info)? = answer["agentInfo"] { info } else { [:] }
                    func said(_ key: String) -> String? {
                        if case .string(let text)? = agent[key], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { String(text.prefix(80)) } else { nil }
                    }
                    if let row {
                        var known = AgentDiscoveryCandidate(name: row.displayName, detail: "Installed: " + row.installation.evidence.joined(separator: "; "),
                            hostID: row.id, settingsPath: nil, cardURL: nil, endpoint: nil)
                        known.foundBy = seen
                        return known
                    }
                    let speaks = !answer.isEmpty ? "Speaks ACP over stdio (\(([name] + (arguments ?? [])).joined(separator: " ")))."
                        : launch.flatMap { if case .run = $0 { "Looks like an ACP agent, but it did not answer as one; write its recipe's acp.arguments from its own documentation." } else { nil } }
                        ?? "Looks like an ACP agent; it has not been run, so whether it answers is not checked."
                    let line = try? JSONValue.object(["executable": .string(name), "arguments": .array((arguments ?? []).map(JSONValue.string)),
                        "documentation": .string("https://agentclientprotocol.com/protocol/v1/transports"), "permissionMode": .string("ask"),
                        "referenceVersion": .string(said("version") ?? ""), "environment": .object([:]),
                        "protocolVersion": answer["protocolVersion"] ?? .null]).decodedExactly(as: AgentHostACP.self)
                    var found = AgentDiscoveryCandidate(name: said("title") ?? said("name") ?? name, detail: speaks + " No recipe knows it yet.",
                        hostID: nil, settingsPath: nil, cardURL: nil, endpoint: nil)
                    found.draft = AgentHostRow(id: recipeID(name, "acp", file), displayName: found.name,
                        description: "An agent found on this Mac that speaks ACP over stdio.",
                        aliases: found.name == name ? [] : [name], installMarkers: [], configPath: "", format: .sessionMCP,
                        restartRequired: false, restartNote: "No restart needed; connection starts an ACP session with reply tools.",
                        documentation: "https://agentclientprotocol.com/protocol/v1/transports", settingsSupported: false,
                        acp: line, searchPaths: [link.deletingLastPathComponent().path])
                    found.foundBy = seen
                    found.version = said("version")
                    found.connectable = !answer.isEmpty
                    return found
                }
            }
            var found: [AgentDiscoveryCandidate] = []
            for await candidate in group { if let candidate { found.append(candidate) } }
            return found
        }
    }

    /// The arguments a --help names for ACP: a command or flag on an entry
    /// line (indented, as help lists them) that says ACP ("  acp  Run as an
    /// ACP server", "  --acp"), or a flag whose choices include acp
    /// ("  --mode <text|json|acp>"). Prose about ACP is not an entry.
    static func acpEntry(_ help: String) -> [String]? {
        for line in help.split(separator: "\n") where line.first?.isWhitespace == true && line.range(of: #"\bacp\b|agent client protocol"#, options: [.regularExpression, .caseInsensitive]) != nil {
            let words = line.split(whereSeparator: \.isWhitespace).map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ",")) }
            guard let entry = words.first, entry.range(of: #"^-{0,2}[A-Za-z][A-Za-z0-9-]*$"#, options: .regularExpression) != nil else { continue }
            if entry.hasPrefix("-"), words.count > 1, words[1].range(of: #"[<|(\[]acp[>|)\]]"#, options: [.regularExpression, .caseInsensitive]) != nil {
                return [entry, "acp"]
            }
            return [entry]
        }
        return nil
    }

    /// MCP hosts: a settings file holding an mcpServers table, wherever an app
    /// keeps one (~/Library/Application Support/*/*.json, ~/.config/*/mcp*.json,
    /// ~/.*/mcp*.json). Its folder names the app; an installed app of that name
    /// or bundle id is the program a connection is written for.
    static func mcpSettings(_ bundles: [Bundle]) -> [AgentDiscoveryCandidate] {
        let fm = FileManager.default, home = fm.homeDirectoryForCurrentUser.path
        let apps = bundles.filter { $0.kind == "installed" && !$0.url.path.hasPrefix("/System/") && $0.bundleID?.hasPrefix("com.apple.") != true }
        // Application Support also holds what macOS guards (Contacts, Calendars):
        // only an installed app's own folder there is read.
        let owned = Set(apps.flatMap { [$0.bundleID, $0.name].compactMap { $0 } })
        var files: [(folder: String, path: String)] = []
        for (root, dotted, settings) in [(home + "/Library/Application Support", false, false), (home + "/.config", false, true), (home, true, true)] {
            for folder in (try? fm.contentsOfDirectory(atPath: root)) ?? []
            where dotted ? folder.hasPrefix(".") : settings || owned.contains(folder) {
                for name in (try? fm.contentsOfDirectory(atPath: root + "/" + folder)) ?? []
                where name.hasSuffix(".json") && (!settings || name.hasPrefix("mcp")) {
                    files.append((folder, root + "/" + folder + "/" + name))
                }
            }
        }
        // A file a recipe names is that recipe's own pass to speak for.
        let known = Set(AgentHostDirectory.rows.flatMap { ([$0.configPath] + ($0.configPaths ?? [])).map(AgentHostDirectory.expand) })
        return files.compactMap { folder, path in
            var bytes = Data()
            guard !known.contains(path), readRegular(path, limit: 16 << 20, { bytes += $0; return true }),
                  let servers = (try? JSONSerialization.jsonObject(with: bytes) as? [String: Any])?["mcpServers"] as? [String: Any] else { return nil }
            let shown = path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
            let seen = ["mcp: \(path) holds an mcpServers table (\(servers.count) servers)"]
            let owner = folder.hasPrefix(".") ? String(folder.dropFirst()) : folder
            let app = apps.first { [$0.bundleID, $0.name, $0.url.deletingPathExtension().lastPathComponent].contains(owner) }
            var found = AgentDiscoveryCandidate(name: app?.name ?? owner,
                detail: "Its settings take MCP servers" + (app.map { " (\($0.url.path))." } ?? ", but no installed app is named \(owner), so a connection has no program to be written for.") + " No recipe knows it yet.",
                hostID: nil, settingsPath: path, cardURL: nil, endpoint: nil)
            found.draft = AgentHostRow(id: recipeID(owner, "mcp", path), displayName: found.name, description: "An app found on this Mac whose settings take MCP servers.",
                aliases: [], installMarkers: app.map { [$0.url.path] } ?? [], configPath: shown, format: .jsonMCPServers,
                restartRequired: true, restartNote: "Restart it to load the new connection.",
                documentation: "https://modelcontextprotocol.io/docs/develop/connect-local-servers",
                bundleIDs: app?.bundleID.map { [$0] } ?? [], configPaths: [shown])
            found.foundBy = seen + (app.map { ["app: " + $0.url.path] } ?? [])
            found.version = app?.version
            found.connectable = app != nil
            return found
        }
    }

    /// A found agent's recipe id: its name as a file name, made its own by
    /// the whole digest of its protocol and canonical path.
    static func recipeID(_ name: String, _ route: String, _ path: String) -> String {
        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        return AgentHostDirectory.normalize(name).map { ("a"..."z").contains($0) || ("0"..."9").contains($0) ? String($0) : "-" }.joined()
            + "-" + SHA256.hash(data: Data((route + "\u{0}" + canonical).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// One row per agent: a probe's find that a recipe's own pass listed adds
    /// what it saw. Only an established host match merges; every other find is its own.
    static func merged(_ found: [AgentDiscoveryCandidate]) -> [AgentDiscoveryCandidate] {
        var rows: [AgentDiscoveryCandidate] = []
        for candidate in found {
            guard candidate.hostID != nil, let index = rows.firstIndex(where: { $0.hostID == candidate.hostID }) else { rows.append(candidate); continue }
            rows[index].foundBy += candidate.foundBy.filter { !rows[index].foundBy.contains($0) }
        }
        return rows.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
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
            let selected: AgentA2AWire.Interface
            do { selected = try AgentA2AWire.selectInterface(card: .object(card), cardURL: url) }
            catch {
                return finish("unsupported", "This A2A card offers nothing this app speaks (\(error.localizedDescription)); it speaks \(AgentA2AWire.spoken). No contact was saved.",
                              card: url, offer: AgentA2AWire.spoken + ", with no required extension")
            }
            do { try AgentPeerPolicy.peerAuthorizeInterface(selected, cardURL: url, hasCredential: bearerToken != nil) }
            catch {
                // Only classify missing credentials when the exact interface
                // would be usable with our supported bearer authentication.
                if bearerToken == nil,
                   (try? AgentPeerPolicy.peerAuthorizeInterface(selected, cardURL: url, hasCredential: true)) != nil {
                    return finish("auth_required", "The advertised A2A interface requires this peer's bearer credential. No contact was saved.")
                }
                return finish("unsupported", "The advertised interface needs authentication other than bearer, or sits on another origin than its card. No credential was forwarded to it.",
                              card: url, offer: "its interface on the card's own origin with bearer authentication")
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

/// Opening Agents, explicitly asking to discover, launch and an install refresh
/// this session cache. Ordinary contact reads never initiate discovery,
/// including before the first refresh. A refresh connects settings-file hosts
/// and offers other routes once through `AgentDiscoveryOffer`. The probes
/// run on Agents and an explicit discover only; launch and an install keep
/// their last finds.
public actor AgentDiscoverySession {
    public static let shared = AgentDiscoverySession()
    private var cached: [AgentDiscoveryCandidate]?
    private var probed: [AgentDiscoveryCandidate] = []
    private var pending: Task<[AgentDiscoveryCandidate], Never>?
    /// How far the pending pass goes: 0 recipes, 1 the probes read, 2 found programs may run.
    private var pendingDepth = 0
    private var installs: Task<Void, Never>?
    private var installationWatcher: FileChangeWatcher?
    /// Spotlight's own failure, said beside every scan until its index works again.
    private var indexFailure: AgentDiscoveryCandidate?
    private let scan: @Sendable ([AgentPeerDiscovery.Bundle]) async -> [AgentDiscoveryCandidate]

    init(scan: @escaping @Sendable ([AgentPeerDiscovery.Bundle]) async -> [AgentDiscoveryCandidate] = AgentPeerDiscovery.scanLocal) {
        self.scan = scan
    }

    public func candidates(refresh: Bool = false, probe: Bool = true, dataRoot: URL) async -> [AgentDiscoveryCandidate] {
        await candidates(refresh: refresh, probe: probe, launch: nil, dataRoot: dataRoot)
    }

    /// `launch`: an explicit discover's rule for running a found program
    /// (`AgentPeerDiscovery.Launch`); without it the probes only read.
    package func candidates(refresh: Bool, probe: Bool = true, launch: AgentPeerDiscovery.Launch?,
                            dataRoot: URL) async -> [AgentDiscoveryCandidate] {
        if !refresh { return cached ?? [] }
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
        while let pending {
            if pendingDepth >= depth { return await pending.value }
            _ = await pending.value
        }
        let scan = scan
        let task = Task {
            nativeLog("AgentDiscoverySession: discovery scan started")
            async let found = probe ? AgentPeerDiscovery.probe(bundles, launch: launch) : nil
            let recipes = await scan(bundles)
            if let found = await found {
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
            pending = nil
            watchLocations(dataRoot: dataRoot)
            offer(result, dataRoot: dataRoot)
            return cached ?? result
        }
        pending = task
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
        guard installs == nil else { return }
        watchLocations(dataRoot: dataRoot)
        installs = Task {
            do {
                for await _ in try await MacAppIndex.shared.changes() {
                    let bundles = try await AgentPeerDiscovery.bundles()
                    indexFailed(nil)
                    arrived(bundles, dataRoot: dataRoot)
                    await installationsChanged(bundles, dataRoot: dataRoot)
                }
            } catch {
                installs = nil
                indexFailed(error)
            }
        }
    }

    private func watchLocations(dataRoot: URL) {
        let paths = AgentHostDirectory.rows.flatMap { $0.installation.locations }
        installationWatcher = FileChangeWatcher(paths: paths) { [weak self] _ in
            Task { await self?.installationsChanged(MacAppIndex.shared.readyApps() ?? [], dataRoot: dataRoot) }
        }
    }

    private func installationsChanged(_ bundles: [AgentPeerDiscovery.Bundle], dataRoot: URL) async {
        if let pending { _ = await pending.value }
        AgentHostRow.installationsChanged()
        watchLocations(dataRoot: dataRoot)
        _ = await discover(bundles, dataRoot: dataRoot)
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
                        setupFailed("Automatic Connect checked agents/recipes/\(row.id).json host.configPath=\(row.expandedConfigPath), host.format=\(row.format.rawValue): \(error.localizedDescription) Read agent.recipe, repair the named field/file, then agent.verify and agent.connect.", for: [candidate], dataRoot: dataRoot)
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
                for id in offers.keys where offers[id]?.offeredAt == now || offers[id]?.connectedAt == now { offers[id] = before[id] }
            }
            guard offers != before else { return }
            try AgentDiscoveryOffer.write(offers, dataRoot)
        } } catch {
            setupFailed("Automatic Connect could not read or save contacts at \(AgentPeerStore(dataRoot: dataRoot).fileURL.path) or discovery decisions at \(AgentDiscoveryOffer.url(dataRoot).path): \(error.localizedDescription) Restore readable, valid files and directory write access, then refresh Agents. Saved declines and disconnects must be preserved.", for: found, dataRoot: dataRoot)
        }
    }

    /// agent.discovery_dismiss: the person's or her "no", including after an update.
    public func dismiss(name: String, dataRoot: URL) -> JSONValue {
        do { return try CredentialFileLock.withLock(AgentDiscoveryOffer.url(dataRoot)) {
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
                "detail": .string("Not offered or connected automatically again. Nothing on this Mac was changed.")])
        } } catch { return .object(["status": .string("failed"), "changed": .bool(false),
            "detail": .string("Could not save the decline: \(error.localizedDescription). Try again.")]) }
    }
}
