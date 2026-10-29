import Experiences
import AgentWorkspace
import Agents
import TurnTrace
import AuthoredCapabilities
import AttentionRouting
import ChatTurnContracts
import ChatToolRuntime
import AgentConversations
import ChatToolParsing
import CryptoKit
import Foundation
import Privacy
import MacIntegration
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ToolRegistry
import ToolExecution
import TrustCenter
import Senses
import PersonaEngine
import Desk
// Blueprint: | `AppDoorReading.swift` | Home, page, item, version and find readings through the app door |
extension AppToolExecutor {
    /// The page's own actions; the ones on every page are named once, on `{}`, except setting.set where the page has settings to set.
    static func doorPageActions(_ page: String, hasSettings: Bool, dataRoot: URL) async -> [AppAction] {
        AppActions.on(page: page, dataRoot: dataRoot)
            .filter { $0.page != "*" || ($0.id == "setting.set" && hasSettings) }
    }
    /// Home first: open agent windows, what is in progress, what waits and what arrived (`home`, which sorts first), then a line per page. A page read lists its actions.
    @MainActor
    func doorIndex(_ input: [String: JSONValue]) async throws -> JSONValue {
        let posture = await Self.freshQuietPosture()
        let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let everyPage = AppActions.all.filter { $0.page == "*" }.map(\.id)
        // pages_version: the lines and every registered action (senses' corners included), so a changed index tells from a repeat.
        let inventory = try await AppActions.inventory(dataRoot: root)
        var shape = inventory.actions.map { $0.page + "/" + $0.id + "/" + $0.scope }.sorted()
        var pages: [JSONValue] = []
        for page in doorPages {
            // The title only when it says more than the id ("inbox: Inbox." is dead weight — Agent 10-10).
            let title = page.title.lowercased() == page.id.lowercased() ? "" : "\(page.title). "
            let line = "\(page.id): \(title)\(page.summary)"
            shape.append(line)
            pages.append(.string(line))
        }
        let home = await doorHome([:], input: input)
        guard ChatToolOutcome.outputLooksSuccessful(home) else { return home }
        return .object([
            "home": home,
            "status": .string("ok"),
            "pages": .array(pages),
            "pages_version": .string(SHA256.hash(data: Data(shape.joined(separator: "\n").utf8))
                .prefix(6).map { String(format: "%02x", $0) }.joined()),
            "on_every_page": .string(everyPage.joined(separator: ", ") + ": on any page; find gives their args."),
            "trust_mode": .string(posture?.name ?? "unreadable"),
            "note": .string("Read a page for action ids; item:\"actions\" gives signatures, find gives args_schema and examples. "
                + (posture?.name == Self.fullMacModeName
                    ? "Under Full Mac, owner actions are yours too; the owner sees each run. In-person controls still need them. "
                    : "Owner actions refuse with their cause and control. ")
                + "preview:true checks without running. "
                + "Batch: actions:[{action,args},{page},{item}], or args.handle:[…] "
                + "where a scalar is accepted; each runs and reports in order."),
        ])
    }
    /// Her home (the workspace): what she left off, and its names and refs as
    /// items. It runs as `workspace`, re-entered under its own name, so its
    /// gate, and every read or send a name runs under that tool's own name,
    /// judge it as they always did.
    @MainActor
    func doorHome(_ call: [String: JSONValue], input: [String: JSONValue]) async -> JSONValue {
        guard let perform = AppDoorReentry.perform else {
            return Self.doorRefusal("door_unavailable",
                "Home reads only through a chat's tool chain. Nothing was read.",
                remedy: "correct_arguments", "Call app from a chat turn's tool chain; this caller cannot bind a chat by supplying a session id.")
        }
        let call = ChatToolSessionInjection.apply(toolName: "workspace", input: call,
                                                  sessionId: input["__session_id"]?.scalarText)
        do { return Self.foldedResult(try await perform("workspace", call), guide: nil) }
        catch { return ChatToolOutcome.failure(error: error, tool: "app") }
    }
    private static func doorAbilityCensus(root: URL) async throws -> JSONValue {
        let abilities = AbilityStore(dataRoot: root)
        let programs = OwnedProgramStore(root: abilities.root)
        let senses = FileSenseRegistry(dataRoot: root)
        let files = try abilities.files()
        let host = AppScriptRunner.Host(call: { _ in .null }, dataRoot: root)
        let key = try SwiftNativeManifestSigner(dataRoot: root).existingSigningKey()
        var rows: [[String: JSONValue]] = []
        for identity in files {
            for slot in AbilityStore.Slot.allCases {
                guard let file = try abilities.read(id: identity.id, slot: slot) else { continue }
                let descriptor = file.metadata["candidate"]?.objectValue ?? [:]
                var record = file.record
                if var script = record["script"]?.objectValue { script["source"] = .string(file.body); record["script"] = .object(script) }
                let native = record["language"] == .string("native")
                let guidance = file.pathExtension == "md"
                let digest = doorText(descriptor["program"]?.objectValue?["version"])
                let status = doorText(record["status"])
                var blocks: [JSONValue] = []
                var validated = native || guidance, admitted = native || guidance, sourceChecked = false
                if file.kind == .sense, !native, descriptor.isEmpty {
                    do {
                        record["uses"] = record["uses"] ?? .int(0); record["corrections"] = record["corrections"] ?? .int(0)
                        let sense = try JSONDecoder().decode(SenseRecord.self, from: JSONValue.object(record).serializedData(pretty: false))
                        let sources = try senses.sourceFiles(sense)
                        guard let entry = sense.entry, sources[entry] == Data(file.body.utf8) else {
                            throw ToolFailureError("The migrated sense's selected source does not match its ability file.", effects: .none,
                                owner: file.id, nextCall: ToolFailureError.call("app", ["action": .string("sense.versions"),
                                    "args": .object(["sense_id": .string(file.id)])]), code: "sense_source_mismatch",
                                instruction: "Read this sense's versions and correct its selected source before conversion.", recovery: .inspect)
                        }
                        validated = true; admitted = true; sourceChecked = true
                    } catch { blocks.append(ownedFailure(error, code: "census_evidence_unreadable", owner: file.id,
                        instruction: "Read this ability's retained source and resolve the reported evidence failure before conversion.",
                        next: ["action": .string("ability.read"), "args": .object(["id": .string(file.id)])], effects: .none)) }
                } else if !native && !guidance && file.kind != .turn {
                    do {
                        guard !digest.isEmpty, let key else {
                            throw ToolFailureError("The exact JS version has no sealed validation proof.", effects: .none, owner: file.id,
                                nextCall: ToolFailureError.call("app", ["action": .string("ability.read"), "args": .object(["id": .string(file.id)])]),
                                code: "validation_proof_missing", instruction: "Read the exact source, then save and validate that version before conversion.", recovery: .inspect)
                        }
                        let candidate = try programs.load(id: file.id, digest: digest)
                        _ = try programs.proof(candidate, key: key)
                        guard candidate.program.dependencies.allSatisfy({ host.dependencyMatches($0, candidate.dependencyShapes.objectValue?[$0]) }) else {
                            throw ToolFailureError("An app-action dependency is unavailable or changed; save it against its current shape.", effects: .none,
                                owner: file.id, nextCall: ToolFailureError.call("app", ["action": .string("ability.read"), "args": .object(["id": .string(file.id)])]),
                                code: "dependency_changed", instruction: "Read the ability's dependencies; save its code against their current shapes.", recovery: .inspect)
                        }
                        validated = true
                        if slot != .next {
                            if file.kind == .part {
                                if status == "active" {
                                    try await OwnedProgramInvocation.$host.withValue(host) {
                                        try await Parts(root: root).checkAdmission(candidate, row: record)
                                    }
                                    admitted = true
                                }
                            } else {
                                let sense = try FileSenseRegistry.record(candidate)
                                admitted = record["candidateDigest"] == .string(candidate.digest) && record["version"] == .int(Int64(sense.version))
                            }
                            if ["active", "on"].contains(status), !admitted {
                                blocks.append(doorRefusal("version_not_admitted", "The selected JS version is not admitted.",
                                    remedy: "inspect", "Read this exact version before enabling it; do not admit different code.",
                                    next: ["action": .string(file.kind == .sense ? "sense.versions" : "ability.read"),
                                           "args": .object([file.kind == .sense ? "sense_id" : "id": .string(file.id)])]))
                            }
                        }
                    } catch { blocks.append(ownedFailure(error, code: "census_evidence_unreadable", owner: file.id,
                        instruction: "Read this ability's retained source and resolve the reported evidence failure before conversion.",
                        next: ["action": .string("ability.read"), "args": .object(["id": .string(file.id)])], effects: .none)) }
                }
                let version = record["codeFingerprint"] ?? record["candidateDigest"] ?? record["version"] ?? .null
                rows.append(["kind": .string(file.kind.rawValue), "id": .string(file.id),
                    "name": record["name"] ?? .string(file.id),
                    "role": .string(slot == .current ? "registered" : slot == .previous ? "rollback" : "proposed"),
                    "language": .string(native ? "native" : guidance ? "guidance" : record["language"] == .string("swift") ? "Swift" : "JS"), "status": .string(status),
                    "source": .string(try abilities.path(id: file.id, slot: slot, pathExtension: file.pathExtension).path),
                    "source_digest": .string(file.bodyDigest), "selected_version": version,
                    "pending_version": slot == .next ? .string(digest) : .null,
                    // Her turn is run by the stem every turn; it has no admission of its own.
                    "validation": .string(file.kind == .turn ? "run_by_stem" : sourceChecked ? "source_checked"
                        : admitted && validated ? "accepted" : validated ? "validated" : "unvalidated"),
                    "counterpart": validated && !digest.isEmpty ? .object(["id": .string(file.id), "version": .string(digest),
                        "status": .string(admitted ? "accepted" : "validated")]) : .null,
                    "unavailable": .array(slot == .previous ? blocks : []),
                    "blocks_cutover": .array(slot == .previous ? [] : blocks), "part": .string(file.partLine)]
                    .merging(file.kind == .sense ? record.filter { ["reach", "mode"].contains($0.key) } : file.part) { _, value in value })
            }
        }
        for skill in try InstalledSkillInventory.entries(dataRoot: root) {
            let path = skill.bodyPath ?? ""
            let body = try Data(contentsOf: URL(fileURLWithPath: path))
            let header = try AbilityStore.File(id: skill.id, kind: .part, metadata: try AbilityStore.partHeader([:]), body: "", pathExtension: "md")
            rows.append(["kind": .string("skill"), "id": .string(skill.id), "name": .string(skill.name),
                "role": .string("built_in"), "language": .string("guidance"), "status": skill.status.map(JSONValue.string) ?? .null,
                "source": .string(path), "source_digest": .string(SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()),
                "validation": .string("bundled"), "counterpart": .null, "blocks_cutover": .array([]), "part": .string(header.partLine)]
                .merging(header.part) { _, value in value })
        }
        for sense in try await senses.allChecked() where !files.contains(where: { $0.id == sense.id }) {
            let sources = sense.language == .native ? [:] : try senses.sourceFiles(sense)
            let body = sense.entry.flatMap { sources[$0] }
            let header = try AbilityStore.File(id: sense.id, kind: .sense,
                metadata: ["record": try .fromEncodable(sense)], body: "", pathExtension: "js")
            rows.append(["kind": .string("sense"), "id": .string(sense.id), "name": .string(sense.corner.key),
                "role": .string("built_in"), "language": .string(sense.language == .native ? "native" : "JS"),
                "status": .string(sense.status.rawValue), "source": .string("NativeAgent.app/Contents/Resources/Senses"),
                "selected_version": .int(Int64(sense.version)), "validation": .string("bundled"),
                "source_digest": body.map { .string(SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()) } ?? .null,
                "counterpart": .null, "blocks_cutover": .array([]), "part": .string(header.partLine)]
                .merging(["reach": try .fromEncodable(sense.reach), "mode": .string(sense.mode.rawValue)]) { _, value in value })
        }
        let blocked = rows.count { !($0["blocks_cutover"]?.arrayValue ?? []).isEmpty }
        var census: [String: JSONValue] = ["status": .string("ok"), "page": .string("tools"), "item": .string("census"),
            "complete": .bool(blocked == 0), "blocked": .int(Int64(blocked)), "entries": .array(rows.map(JSONValue.object)),
            "note": .string("Read-only ability files and bundled defaults. Candidate JS: sealed proof, current dependencies and admission; migrated senses: checked source. Unavailable previous versions do not block working current versions.")]
        census["version"] = .string(doorVersion(page: "tools", item: "census", ["content": .object(census)]))
        return .object(census)
    }
    /// What the page or item shows now, read in process; a name the page
    /// does not have is status not_found, which `doorItemRead` words.
    /// Its version hashes only what the person would see change (content,
    /// settings, items), not the accessibility tree.
    @MainActor
    func doorRead(page: QuietToolPage, item: String, offset: Int = 0) async throws -> JSONValue {
        let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        do {
            // An action's guide, before any page reads its items as its own names.
            if item.hasPrefix("guide:"),
               let action = await Self.doorPageActions(page.id, hasSettings: false, dataRoot: root).first(where: { "guide:" + $0.id == item }),
               let guide = AppActions.about(action) {
                return .object(["status": .string("ok"), "page": .string(page.id), "item": .string(item),
                                "guide": .object([action.id: .string(guide)])])
            }
            if ["tools", "skills"].contains(page.id), item.lowercased() == "census" {
                return try await Self.doorAbilityCensus(root: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot())
            }
            if page.id == "tools", item.isEmpty {
                var list = Self.partFields(try Parts(root: root).list(offset: offset))
                list["page"] = .string(page.id)
                list["title"] = .string(page.title)
                if list["has_more"] == .bool(true) {
                    list["next_call"] = .object(["page": .string("tools"), "args": .object(["offset": list["next_offset"] ?? .int(0)])])
                }
                return .object(list)
            }
            // A part reads by its id or name; a built-in skill's guidance reads too.
            if ["tools", "skills"].contains(page.id), !item.isEmpty {
                let read = try Parts(root: root).read(item, offset: offset)
                guard case .object(let fields) = read, fields["status"] == .string("ok") else { return ChatToolOutcome.refusedBeforeRunning(read) }
                return .object(["status": .string("ok"), "page": .string(page.id), "item": read])
            }
            if page.id == "skills" {
                let items = try InstalledSkillInventory.entries(dataRoot: root).map { entry in
                    JSONValue.object(["id": .string(entry.id), "name": .string(entry.name), "description": .string(entry.description),
                        "next_call": .object(["action": .string("ability.read"), "args": .object(["id": .string(entry.id)])])])
                }
                return .object(["status": .string("ok"), "page": .string(page.id), "title": .string(page.title), "items": .array(items),
                    "note": .string("Built-in guidance from the persona: read it with ability.read. What you write is an ability, on the tools page.")])
            }
            if page.id == "inbox" {
                guard let host = quietHost() else { return Self.unattachedFailure() }
                if item.isEmpty || item.lowercased() == "all" {
                    let result = await host.inbox(verb: "list", input: item.isEmpty ? [:]
                        : ["filter": .string("all"), "limit": .int(200)])
                    guard case .object(let list) = result, list["status"] == .string("ok") else { return result }
                    let notes: [JSONValue] = if case .array(let notes)? = list["notes"] { notes } else { [] }
                    return .object(["status": .string("ok"), "page": .string("inbox"), "title": .string(page.title),
                                    "about": .string(page.summary), "count": list["count"] ?? .null,
                                    "shown": list["shown"] ?? .null, "needs_you_count": list["needs_you_count"] ?? .null,
                                    "items": .array(notes.map { note in
                                        guard case .object(let row) = note else { return note }
                                        let title = String(Self.doorText(row["title"]).split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(120))
                                        return .string("\(Self.doorText(row["id"])) | kind=\(Self.doorText(row["source"])) | \(title) | unread=\(row["status"] == .string("unread")) | needs-you=\(row["needs_you"] == .bool(true))")
                                    })])
                }
                let result = await host.inbox(verb: "read", input: ["id": .string(item)])
                guard ChatToolOutcome.outputLooksSuccessful(result) else { return result }
                guard case .object(let read) = result, case .array(let notes)? = read["notes"],
                      let note = notes.first else { return result }
                return .object(["status": .string("ok"), "page": .string("inbox"), "item": Self.doorButtons(note)])
            }
            if let tool = ["diagnostics": "doctor_status", "telegram": "telegram_status"][page.id],
               Self.doorItemReads[page.id]?[item.lowercased()] != nil {
                let result = try await healthRead(item.lowercased())
                guard ChatToolOutcome.outputLooksSuccessful(result) else { return result }
                return .object(["status": .string("ok"), "page": .string(page.id), "item": result])
            }
            if ["context", "agent_view"].contains(page.id) {
                return await runAppPageRead(input: ["page": .string(page.id), (page.id == "agent_view" ? "room" : "session_id"): .string(item)])
            }
            switch (page.id, item.isEmpty) {
            case ("chat", false):
                // The composer's own read.
                let result = await composerRead(sessionId: item)
                guard case .object(let state) = result, state["status"] == .string("ok") else { return result }
                return .object(["status": .string("ok"), "page": .string("chat"), "item": result])
            case (_, false):
                return ChatToolOutcome.refusedBeforeRunning(.object(["status": .string("not_found")]))
            default:
                let result = await runAppPageRead(input: ["page": .string(page.id)])
                guard case .object(var read) = result, read["status"] == .string("ok"), let host = quietHost() else { return result }
                // Chat also lists the sidebar's conversations, the first page of
                // chat.list. Outside the version: her own turn moves them.
                if page.id == "chat",
                   case .object(let list) = await host.runChatSession(verb: "list", input: [:], reachesUser: false) {
                    guard ChatToolOutcome.outputLooksSuccessful(.object(list)) else { return .object(list) }
                    read["conversations"] = list["conversations"]
                    read["conversations_next_offset"] = list["next_offset"]
                }
                // Providers also lists each account's id, fallback model and
                // models, as provider.test and provider.set_fallback_model take them.
                if page.id == "providers",
                   case .object(let list) = await host.provider(verb: "list", input: [:]) {
                    guard ChatToolOutcome.outputLooksSuccessful(.object(list)) else { return .object(list) }
                    read["accounts"] = list["accounts"]
                }
                return .object(read)
            }
        } catch {
            return ChatToolOutcome.failure(error: error, tool: "app", effects: ToolFailureError.Effects.none)
        }
    }
    static func doorVersion(page: String, item: String, _ read: [String: JSONValue]) -> String {
        var fields = read.filter { ["content", "settings", "items", "item", "count", "entries", "complete", "blocked"].contains($0.key) }
        if page == "chat", !item.isEmpty, case .object(let composer)? = fields["item"] {
            // Turn progress and context usage do not edit the draft.
            fields["item"] = .object(composer.filter { ["conversation", "draft", "attachments", "provider", "model", "think", "fast", "persona"].contains($0.key) })
        }
        let shown = JSONValue.object(fields)
        let digest = SHA256.hash(data: (try? shown.serializedData(pretty: false)) ?? Data())
        return (item.isEmpty ? page : page + "/" + item) + "@"
            + digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }
    /// The version a read of `scope` ("page" or "page/item") would return now.
    @MainActor
    func doorCurrentVersion(scope: String) async throws -> String? {
        let parts = scope.split(separator: "/", maxSplits: 1).map(String.init)
        if parts.first == "senses", parts.count == 2 {
            guard let registry = SensesHub.shared.registry,
                  case .object(let read) = try await registry.lifecycleRead(id: parts[1]) else { return nil }
            return read["version"]?.scalarText
        }
        guard let page = parts.first.flatMap(doorPage) else { return nil }
        let item = parts.count > 1 ? parts[1] : ""
        guard case .object(let read) = try await doorRead(page: page, item: item),
              read["status"] == .string("ok") else { return nil }
        return read["version"]?.scalarText ?? Self.doorVersion(page: page.id, item: item, read)
    }
    @MainActor
    func doorFind(_ query: String) async throws -> JSONValue {
        let asked = AppActions.intentWords(query)
        let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let permissions = try? await MacIntegrationPermissionStore(dataRoot: root).readinessChecked()
        if let action = (await AppActions.resolvedAction(query, dataRoot: root))?.action,
           action.id.lowercased() == query.lowercased() {
            let blocker = MacIntegrationGates.byTool[action.tool].flatMap {
                permissions?.refusal(integration: $0.integration, mode: $0.mode)
            }
            return .object(["status": .string("ok"), "find": .string(query),
                "matched_actions": .int(1), "shown_actions": .int(1),
                "actions": .array([AppActions.discovery(action, blocker: blocker, dataRoot: root)]),
                "pages": .array([]), "read_next": .array([]), "effects": .string("none")])
        }
        let (ranked, degraded, namedPages) = try await AppActions.ranked(query, pages: doorPageIndex, dataRoot: root, memory: actionIndex)
        let matches = ranked.prefix(5)
        let actions = matches.filter { !$0.isItemRead }
        let named = AppActions.named(query)
        let items: [JSONValue] = matches.filter(\.isItemRead).map {
            .object($0.input.merging(["description": .string($0.label)]) { _, value in value })
        }
        let pages = doorPages.map { page in
            (page, AppActions.hits(Set(AppActions.intentWords(page.id + " " + page.title + " " + page.summary)), asked))
        }.filter { $0.1 > 0 }.sorted {
            let leftNamed = namedPages.contains($0.0.id), rightNamed = namedPages.contains($1.0.id)
            if leftNamed != rightNamed { return leftNamed }
            return $0.1 > $1.1
        }.prefix(3)
        let disabled = try AppActions.disabledTools(asked, dataRoot: root).prefix(2)
        var found: [String: JSONValue] = [
            "status": .string(matches.isEmpty && pages.isEmpty && disabled.isEmpty ? "not_found" : "ok"),
            "find": .string(query),
            "matched_actions": .int(Int64(AppActions.matchedActions(ranked).count)), "shown_actions": .int(Int64(actions.count)),
            // The best match and actions named by id carry their whole contract.
            "actions": .array(actions.enumerated().map { offset, action in
                let permissionBlocker = MacIntegrationGates.byTool[action.tool].flatMap {
                    permissions?.refusal(integration: $0.integration, mode: $0.mode)
                }
                let blocker = permissionBlocker
                guard offset == 0 || named.contains(action.id) else { return .string(action.line + (blocker.map { " Unavailable: " + $0 } ?? "")) }
                return AppActions.discovery(action, blocker: blocker, dataRoot: root)
            }),
            "pages": .array(pages.map { .string("\($0.0.id): \($0.0.title). \($0.0.summary)") }),
            "read_next": .array(items),
            "note": .string("find discovers actions, pages and home items. Among shown actions, the best and explicitly named ids include args_schema and example; others use id(args) label. Name an id for its full match. Search saved work with work.context {query}, conversations with chat.search {query}. Reversible actions run directly; irreversible examples use preview:true (checks only). Replace <placeholders> with your values."),
            // A find is a read; finding nothing is its answer.
            "effects": .string("none"),
        ]
        if found["status"] == .string("not_found") {
            found["reason"] = .string("no_match")
            found["message"] = .string("Nothing matches \"\(query)\": no action, page or item.")
        }
        if !disabled.isEmpty { found["disabled"] = .array(Array(disabled)) }
        if let degraded { found["ranking_degraded"] = .string("Ranked by words only: " + degraded) }
        found["ranking_basis"] = .string("Exact action ids first, then a named page's own actions in page order (registered page ids, titles, door aliases and integration ids); the rest use token overlap and semantic suggestions that clear the attention chance bar against this retrieval epoch's inventory. Assumes most actions are irrelevant and a light-tailed background. Language coverage and natural-language constraints depend on the embedding model. Use -<exact action id> for an explicit exclusion; no language-specific clauses are rewritten.")
        return .object(found)
    }
}
