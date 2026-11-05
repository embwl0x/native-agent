import CryptoKit
import AgentLinkTransport
import Foundation
import NativeAgentShared
import MacControl
import NativeAgentCore
import PersistenceCore
import os
// Blueprint: | `AgentPeerDiscovery.swift` | `AgentPeerDiscovery`, `probe`, `Launch`, `agentProgramLaunch` |

/// Bounded read-only discovery. A website, an HTTP success, or an unsupported protocol is not a connected agent. No contact or credential is written here.
package enum AgentPeerDiscovery {
    static func localCandidates(ports: Set<Int>) -> [URL] {
        ports.filter { (1...65535).contains($0) }.sorted().flatMap { port in
            ["127.0.0.1", "[::1]"].flatMap { host in
                ["agent-card.json", "agent.json"].map { URL(string: "http://\(host):\(port)/.well-known/\($0)")! }
            }
        }
    }

    static func localCard(_ url: URL) async throws -> AgentDiscoveryCandidate? {
        // Validate every candidate before requests; only a readable supported card establishes an agent.
        guard let response = try? await AgentPeerHTTP.getLoopbackCard(url), (200..<300).contains(response.statusCode),
              case .object(let card)? = response.json, card["name"] != nil,
              ["skills", "capabilities", "protocolVersion", "supportedInterfaces"].contains(where: { card[$0] != nil }) else { return nil }
        guard case .string(let name)? = card["name"], !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 480, case .object? = card["capabilities"], case .array? = card["skills"] else {
            throw AgentCommunicationError.invalid(
                "\(url.absoluteString) serves an agent card this app cannot use (name, capabilities, skills and a supported interface are required)")
        }
        let selected = try AgentA2AWire.selectInterface(card: .object(card), cardURL: url)
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

    /// Read process paths without running programs.
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

    /// Exclude helper and updater processes when identifying the application.
    static func running(_ app: URL, _ info: NSDictionary?, in programs: [String]) -> [String] {
        guard let name = info?["CFBundleExecutable"] as? String else { return [] }
        let main = app.path + "/Contents/MacOS/" + name
        return programs.contains(main) ? ["process: " + main] : []
    }

    /// Recipes own installation evidence; settings and running programs only annotate it. An app name alone establishes no messaging route.
    static func scanLocal() async -> [AgentDiscoveryCandidate] {
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

    /// Probe signatures read-only unless explicit launch admission permits bounded help and initialization. Bound cards to 0.6 s, help to 1 s and
    /// initialization to 3 s; unlabelled windows and undocumented Bonjour types prove no route.
    static func probe(_ bundles: [Bundle], launch: Launch?, dataRoot: URL) async -> [AgentDiscoveryCandidate] {
        async let programs = acpPrograms(bundles, launch: launch, dataRoot: dataRoot)
        async let settings = mcpSettings(bundles)
        // Prefer agent-card.json when both card paths identify the same agent.
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
            held.setupFailure = """
                agents/recipes/\(id).json already holds a recipe that does not find this one (\(found.foundBy.first ?? found.name)), so its draft \
                is not offered. Read it with agent.recipe.
                """
            return held
        } + cards.sorted { $0.id < $1.id }.filter { endpoints.insert($0.endpoint ?? $0.cardURL!).inserted }
    }

    /// The caller’s launch rule owns whether a found program may run, including any sandbox command.
    package enum Launch: Sendable {
        case run(@Sendable (_ executable: String, _ arguments: [String]) -> [String])
        case refused(String)
    }

    /// Nonblocking regular-file reads are bounded by size; FIFOs and devices must not stall discovery, and truncation cannot invalidate a mapping.
    static func readRegular(_ path: String, limit: Int64, _ each: (Data) -> Bool) -> Bool {
        let fd = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0,
              info.st_size <= limit, var left = Int(exactly: info.st_size) else { return false }
        var chunk = [UInt8](repeating: 0, count: 1 << 20)
        while left > 0 {
            guard !Task.isCancelled else { return false }
            let count = Darwin.read(fd, &chunk, min(chunk.count, left))
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            left -= count
            guard each(Data(chunk.prefix(count))) else { break }
        }
        return true
    }

    private struct ProgramSignature: Sendable {
        let stamp: SnapshotTailOpLog.FileStamp
        let carries: Bool
        let head: Data
    }
    private static let programSignatures = OSAllocatedUnfairLock<[String: ProgramSignature]>(initialState: [:])

    private static func signatureStamp(_ path: String) -> SnapshotTailOpLog.FileStamp? {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return SnapshotTailOpLog.FileStamp(info)
    }

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

    /// Only an initialization answer proves ACP connectability; clients can carry the same method signatures.
    static func acpPrograms(_ bundles: [Bundle], launch: Launch?, dataRoot: URL) async -> [AgentDiscoveryCandidate] {
        // Missing login PATH must retain its own failure reason.
        guard case .success(let environment) = AgentHostCommandLines.loginEnvironment else { return [] }
        let fm = FileManager.default
        @Sendable func program(_ path: String) -> Bool {
            var info = stat()
            return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && access(path, X_OK) == 0
        }
        // Use each file’s declared program name to avoid duplicate candidates.
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
        for app in MacAppIndex.installed(bundles) where !app.url.path.hasPrefix("/System/") {
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
        @Sendable func scan(_ path: String) -> (carries: Bool, head: Data)? {
            guard !Task.isCancelled, let stamp = signatureStamp(path) else { return nil }
            if let saved = programSignatures.withLock({ $0[path] }), saved.stamp == stamp {
                return (saved.carries, saved.head)
            }
            var missing = methods, window = Data(), head: Data?
            guard readRegular(path, limit: AgentACPExecutable.maximumBytes, { chunk in
                if head == nil { head = chunk.prefix(65_536) }
                window = window.suffix(16) + chunk
                missing.removeAll { window.range(of: $0) != nil }
                return !missing.isEmpty
            }) else { return nil }
            guard !Task.isCancelled, signatureStamp(path) == stamp else { return nil }
            // Retain launcher bytes only; binaries need just their signature bit.
            let retainedHead = head.flatMap { $0.starts(with: Data("#!".utf8)) ? $0 : nil } ?? Data()
            let carries = missing.isEmpty
            programSignatures.withLock { $0[path] = ProgramSignature(stamp: stamp, carries: carries, head: retainedHead) }
            return (carries, retainedHead)
        }
        /// ACP candidates require method bytes or an explicitly named launcher, without running them.
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
            var remaining = programs.makeIterator()
            var running = 0
            var found: [AgentDiscoveryCandidate] = []
            while !Task.isCancelled {
                // Limit signature reads and probes to two concurrent programs, refilling after completion to bound disk contention.
                while running < 2, let (file, link) = remaining.next() {
                    running += 1
                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        let name = link.lastPathComponent
                        guard let why = says(name) ? "its name says acp" : signature(file, beside: link.path != file) else { return nil }
                        var seen = ["acp: \(link.path): \(why)"]
                        // A recipe authored from this draft owns its find even if resolution moved.
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
                            guard let executable = try? AgentACPExecutable.capture(path: file) else { seen.append(
                                "not run: \(file) could not be read whole"); break }
                            if arguments == nil, says(name) { arguments = [] }
                            if arguments == nil, let help = try? await executable.reported(environment: environment,
                                command: command(file, ["--help"]), errors: true, grace: .seconds(1), limit: 65_536) {
                                arguments = acpEntry(help)
                            }
                            guard let arguments else { seen.append("entry: its --help names no ACP entry"); break }
                            seen.append("entry: \(([name] + arguments).joined(separator: " "))" + (row?.acp != nil ? " (its recipe)" : ""))
                            // Use only the transport’s declared start arguments.
                            let started = command(file, arguments)
                            do {
                                if case .object(let result) = try await AgentACPClient(dataRoot: dataRoot).initialize(executable: started[0],
                                    arguments: Array(started.dropFirst()),
                                    directory: FileManager.default.temporaryDirectory, environment: environment,
                                    approvedExecutable: executable, timeout: .seconds(3)) { answer = result }
                                seen.append("initialize: answered ACP 1")
                            } catch let refused as AgentACPClient.Mismatch { seen.append("initialize: " + refused.detail) }
                            catch { seen.append("initialize: no ACP answer within 3s (\(error.localizedDescription))") }
                        }
                        let agent: [String: JSONValue] = if case .object(let info)? = answer["agentInfo"] { info } else { [:] }
                        func said(_ key: String) -> String? {
                            if case .string(let text)? = agent[key], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { String(
                                text.prefix(80)) } else { nil }
                        }
                        if let row {
                            var known = AgentDiscoveryCandidate(name: row.displayName, detail: "Installed: " + row.installation.evidence.joined(
                                separator: "; "),
                                hostID: row.id, settingsPath: nil, cardURL: nil, endpoint: nil)
                            known.foundBy = seen
                            return known
                        }
                        let speaks = !answer.isEmpty ? "Speaks ACP over stdio (\(([name] + (arguments ?? [])).joined(separator: " ")))."
                            : launch.flatMap { if case .run = $0 { """
                                Looks like an ACP agent, but it did not answer as one; write its recipe's acp.arguments from its own documentation.
                                """ } else { nil } }
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
                guard running > 0, let candidate = await group.next() else { break }
                running -= 1
                if let candidate { found.append(candidate) }
            }
            group.cancelAll()
            return found
        }
    }

    /// Accept ACP entry commands or flags in help; prose mentioning ACP does not establish an entry.
    static func acpEntry(_ help: String) -> [String]? {
        for line in help.split(separator: "\n") where line.first?.isWhitespace == true && line.range(of: #"\bacp\b|agent client protocol"#,
            options: [.regularExpression, .caseInsensitive]) != nil {
            let words = line.split(whereSeparator: \.isWhitespace).map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ",")) }
            guard let entry = words.first, entry.range(of: #"^-{0,2}[A-Za-z][A-Za-z0-9-]*$"#, options: .regularExpression) != nil else { continue }
            if entry.hasPrefix("-"), words.count > 1, words[1].range(of: #"[<|(\[]acp[>|)\]]"#, options: [.regularExpression, .caseInsensitive]) != nil {
                return [entry, "acp"]
            }
            return [entry]
        }
        return nil
    }

    /// Use settings files as MCP host evidence, scoped to the installed application named by their folder.
    static func mcpSettings(_ bundles: [Bundle]) -> [AgentDiscoveryCandidate] {
        let fm = FileManager.default, home = fm.homeDirectoryForCurrentUser.path
        let apps = MacAppIndex.installed(bundles).filter { !$0.url.path.hasPrefix("/System/") && $0.bundleID?.hasPrefix("com.apple.") != true }
        // Read only installed apps’ own support folders to avoid protected macOS data.
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
        // A recipe-named file belongs to that recipe’s discovery pass.
        let known = Set(AgentHostDirectory.rows.flatMap { ([$0.configPath] + ($0.configPaths ?? [])).map(AgentHostDirectory.expand) })
        return files.compactMap { folder, path in
            var bytes = Data()
            guard !known.contains(path), readRegular(path, limit: 16 << 20, { bytes += $0; return true }),
                  let servers = (try? JSONSerialization.jsonObject(with: bytes) as? [String: Any])?["mcpServers"] as? [String: Any] else { return nil }
            let shown = UserDisplayFormatters.tildifyPath(path)
            let seen = ["mcp: \(path) holds an mcpServers table (\(servers.count) servers)"]
            let owner = folder.hasPrefix(".") ? String(folder.dropFirst()) : folder
            let app = apps.first { [$0.bundleID, $0.name, $0.url.deletingPathExtension().lastPathComponent].contains(owner) }
            var found = AgentDiscoveryCandidate(name: app?.name ?? owner,
                detail: "Its settings take MCP servers" + (app.map { " (\($0.url.path))." }
                    ?? ", but no installed app is named \(owner), so a connection has no program to be written for.") + " No recipe knows it yet.",
                hostID: nil, settingsPath: path, cardURL: nil, endpoint: nil)
            found.draft = AgentHostRow(id: recipeID(owner, "mcp", path), displayName: found.name,
                description: "An app found on this Mac whose settings take MCP servers.",
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

    /// Bind discovered IDs to protocol and canonical path so equal names do not merge identities.
    static func recipeID(_ name: String, _ route: String, _ path: String) -> String {
        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        return AgentHostDirectory.normalize(name).map { ("a"..."z").contains($0) || ("0"..."9").contains($0) ? String($0) : "-" }.joined()
            + "-" + SHA256.hash(data: Data((route + "\u{0}" + canonical).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Merge only established host matches; unrelated finds keep separate identities.
    static func merged(_ found: [AgentDiscoveryCandidate]) -> [AgentDiscoveryCandidate] {
        var rows: [AgentDiscoveryCandidate] = []
        for candidate in found {
            guard candidate.hostID != nil, let index = rows.firstIndex(where: { $0.hostID == candidate.hostID }) else { rows.append(candidate); continue }
            rows[index].foundBy += candidate.foundBy.filter { !rows[index].foundBy.contains($0) }
        }
        return rows.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }
}
