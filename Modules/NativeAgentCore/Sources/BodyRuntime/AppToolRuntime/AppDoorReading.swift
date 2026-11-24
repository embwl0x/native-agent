import SenseCore
import MindCore
import MacNerves
import CryptoKit
import Foundation
import PersistenceCore
import NativeAgentCore
import NativeAgentShared
import DeskCore
// Blueprint: | `AppDoorReading.swift` | Direct home engine entry, page/item/find reads and call-fit census |
extension AppToolExecutor {
    @concurrent static func doorStoreRead<Value: Sendable>(_ read: @Sendable () throws -> Value) async rethrows -> Value {
        try read()
    }
    @concurrent static func doorPageActions(_ page: String, hasSettings: Bool, dataRoot: URL, turn: Turn?) async throws -> [AppAction] {
        try AppActions.on(page: page, dataRoot: dataRoot, turn: turn)
            .filter { $0.page != "*" || ($0.id == "setting.set" && hasSettings) }
    }
    @MainActor
    func doorIndex(turn: Turn, execution: AppActionExecution) async throws -> JSONValue {
        let posture = await Self.freshQuietPosture()
        let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let everyPage = try AppActions.all.filter { $0.page == "*" }.map(\.id)
        let inventory = try await AppActions.inventory(dataRoot: root, turn: turn)
        var shape = inventory.actions.map { $0.page + "/" + $0.id + "/" + $0.scope }.sorted()
        var pages: [JSONValue] = []
        for page in try await doorPages {
            let title = page.title.lowercased() == page.id.lowercased() ? "" : "\(page.title). "
            let line = "\(page.id): \(title)\(page.summary)"
            shape.append(line)
            pages.append(.string(line))
        }
        let home = await doorHome([:], turn: turn, execution: execution)
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
    @MainActor
    func doorHome(_ call: [String: JSONValue], turn: Turn, execution: AppActionExecution) async -> JSONValue {
        guard let door = execution.invocation.appDoor else {
            return Self.failure("door_unavailable",
                "Home reads only from inside a chat turn. Nothing was read.",
                extra: ["remedy": .object(["kind": .string("correct_arguments"),
                    "instruction": .string("Call app from inside a chat turn; this caller cannot bind a chat by supplying a session id."), "next_call": .null])])
        }
        do { return Self.foldedResult(try await door.perform(nil, call, turn, execution.toolInvocation), guide: nil) }
        catch { return ChatToolOutcome.failure(error: error, tool: "app") }
    }
    @concurrent private static func doorAbilityCensus(root: URL, jobStore: AgentJobStore, surface: String, turn: Turn, execution: AppActionExecution) async throws -> JSONValue {
        let abilities = AbilityStore(dataRoot: root)
        let programs = OwnedProgramStore(root: abilities.root)
        let senses = FileSenseRegistry(dataRoot: root)
        let files = try abilities.files()
        let host = AppScriptRunner.Host(call: { _, _, _ in .null }, dataRoot: root, jobStore: jobStore, execution: execution, catalogTurn: turn)
        let key = try SwiftNativeManifestSigner(dataRoot: root).existingSigningKey()
        var rows: [[String: JSONValue]] = []
        for identity in files {
            for slot in AbilityStore.Slot.allCases {
                guard let file = try abilities.read(id: identity.id, slot: slot) else { continue }
                let descriptor = file.metadata["candidate"]?.objectValue ?? [:]
                let record = file.record
                let native = record["language"] == .string("native")
                let guidance = file.pathExtension == "md"
                let digest = JSONValue.trimmedScalarTextOrEmpty(descriptor["program"]?.objectValue?["version"])
                let status = JSONValue.trimmedScalarTextOrEmpty(record["status"])
                var blocks: [JSONValue] = []
                var callFit: JSONValue = .null
                var validated = native || guidance, admitted = native || guidance
                if !native && !guidance && file.kind != .turn {
                    do {
                        let candidate = try programs.load(id: file.id, digest: digest)
                        var callsFit = true
                        do {
                            let shapes = try await Parts(root: root).checkDependencies(candidate,
                                invocation: .init(host: host, execution: execution.programExecution(turn: turn, surface: surface)))
                            let unavailable = candidate.program.dependencies.filter { shapes.objectValue?[$0] == .null }
                            callFit = .object(["status": .string(unavailable.isEmpty ? "static_calls_fit" : "contracts_unavailable"),
                                "runtime": .string("computed arguments and unavailable contracts are checked when called"),
                                "unavailable": .array(unavailable.map(JSONValue.string))])
                        } catch {
                            callsFit = false
                            let failure = ownedFailure(error, code: "census_evidence_unreadable", owner: file.id,
                                instruction: "Correct the named call with ability.save and keep the reviewed version.",
                                next: ["action": .string("ability.read"), "args": .object(["id": .string(file.id)])], effects: .none)
                            callFit = failure; blocks.append(failure)
                        }
                        guard !digest.isEmpty, let key else {
                            throw ToolFailureError("The exact JS version has no sealed validation proof.", effects: .none, owner: file.id,
                                nextCall: ToolFailureError.call("app", ["action": .string("ability.read"), "args": .object(["id": .string(file.id)])]),
                                code: "validation_proof_missing", instruction: "Read the exact source, then save and validate that version before conversion.",
                                    recovery: .inspect)
                        }
                        _ = try programs.proof(candidate, key: key)
                        validated = callsFit
                        if slot != .next {
                            if file.kind == .part {
                                if status == "active" {
                                    // Admission is judged against the selected registry row, as a run judges it; a file's own record has no active path.
                                    let parts = Parts(root: root)
                                    try await parts.checkAdmission(candidate)
                                    admitted = true
                                }
                            } else {
                                let sense = try FileSenseRegistry.record(candidate)
                                admitted = record["candidateDigest"] == .string(candidate.digest) && record["version"] == .int(Int64(sense.version))
                            }
                            if ["active", "on"].contains(status), !admitted {
                                blocks.append(failure("version_not_admitted", "The selected JS version is not admitted.",
                                    extra: ["remedy": .object(["kind": .string("inspect"),
                                        "instruction": .string("Read this exact version before enabling it; do not admit different code."),
                                        "next_call": .object(["tool": .string("app"), "input": .object([
                                            "action": .string(file.kind == .sense ? "sense.versions" : "ability.read"),
                                            "args": .object([file.kind == .sense ? "sense_id" : "id": .string(file.id)])])])])]))
                            }
                        }
                    } catch {
                        let failure = ownedFailure(error, code: "census_evidence_unreadable", owner: file.id,
                            instruction: "Read this ability's retained source and resolve the reported evidence failure before conversion.",
                            next: ["action": .string("ability.read"), "args": .object(["id": .string(file.id)])], effects: .none)
                        if callFit == .null { callFit = failure }
                        blocks.append(failure)
                    }
                }
                let version = record["codeFingerprint"] ?? record["candidateDigest"] ?? record["version"] ?? .null
                rows.append(["kind": .string(file.kind.rawValue), "id": .string(file.id),
                    "call_fit": callFit,
                    "name": record["name"] ?? .string(file.id),
                    "role": .string(slot == .current ? "registered" : slot == .previous ? "previous" : "proposed"),
                    "language": .string(native ? "native" : guidance ? "guidance" : record["language"] == .string("swift") ? "Swift" : "JS"), "status": .string(
                        status),
                    "source": .string(try abilities.path(id: file.id, slot: slot, pathExtension: file.pathExtension).path),
                    "source_digest": .string(file.bodyDigest), "selected_version": version,
                    "pending_version": slot == .next ? .string(digest) : .null,
                    "validation": .string(file.kind == .turn ? "run_by_stem"
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
            let header = try AbilityStore.File(id: skill.id, kind: .part, metadata: try AbilityStore.partHeader([:]), body: "", pathExtension: "md")
            rows.append(["kind": .string("skill"), "id": .string(skill.id), "name": .string(skill.name),
                "role": .string("built_in"), "language": .string("guidance"), "status": skill.status.map(JSONValue.string) ?? .null,
                "source": .string(path), "source_digest": skill.bodyRevision.map(JSONValue.string) ?? .null,
                "description": .string(skill.description),
                "validation": .string(skill.status == "unavailable" ? "unavailable" : "bundled"),
                "counterpart": .null, "blocks_cutover": .array([]), "part": .string(header.partLine)]
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
                "source_digest": body.map { .string(SHA256Hex.of($0)) } ?? .null,
                "counterpart": .null, "blocks_cutover": .array([]), "part": .string(header.partLine)]
                .merging(["reach": try .fromEncodable(sense.reach), "mode": .string(sense.mode.rawValue)]) { _, value in value })
        }
        let blocked = rows.count { !($0["blocks_cutover"]?.arrayValue ?? []).isEmpty }
        var census: [String: JSONValue] = ["status": .string("ok"), "page": .string("tools"), "item": .string("census"),
            "complete": .bool(blocked == 0), "blocked": .int(Int64(blocked)), "entries": .array(rows.map(JSONValue.object)),
            "note": .string("""
                Read-only ability files and bundled defaults. Candidate JS requires sealed proof, current dependencies and admission. Unavailable previous \
                versions do not block working current versions.
                """)]
        census["version"] = .string(try doorVersion(page: "tools", item: "census", ["content": .object(census)]))
        return .object(census)
    }
    @concurrent private static func doorStoredParts(page: QuietToolPage, item: String, offset: Int, root: URL) async throws -> JSONValue {
        if page.id == "tools", item.isEmpty {
            var list = JSONValue.objectOrEmpty(try Parts(root: root).list(offset: offset))
            list["page"] = .string(page.id)
            list["title"] = .string(page.title)
            if list["has_more"] == .bool(true) {
                list["next_call"] = .object(["page": .string("tools"), "args": .object(["offset": list["next_offset"] ?? .int(0)])])
            }
            return .object(list)
        }
        if !item.isEmpty {
            let read = try await Parts(root: root).read(item, offset: offset)
            guard case .object(let fields) = read, fields["status"] == .string("ok") else { return ChatToolOutcome.refusedBeforeRunning(read) }
            return .object(["status": .string("ok"), "page": .string(page.id), "item": read])
        }
        let items = try InstalledSkillInventory.entries(dataRoot: root, includingSource: false).map { entry in
            JSONValue.object(["id": .string(entry.id), "name": .string(entry.name), "description": .string(entry.description),
                "status": entry.status.map(JSONValue.string) ?? .null,
                "next_call": .object(["action": .string("ability.read"), "args": .object(["id": .string(entry.id)])])])
        }
        return .object(["status": .string("ok"), "page": .string(page.id), "title": .string(page.title), "items": .array(items),
            "note": .string("Built-in guidance from the persona: read it with ability.read. What you write is an ability, on the tools page.")])
    }
    static func previewPage(_ page: String, item: String) -> JSONValue {
        .object(["status": .string("preview"), "execution": .string("preview"), "effects": .string("none"),
            "page": .string(page), "item": .string(item), "detail": .string("Opening this page can refresh or retain state.")])
    }
    @MainActor
    func doorRead(page: QuietToolPage, item: String, offset: Int = 0, surface: String, turn: Turn, execution: AppActionExecution,
                  following: Bool = false) async throws -> JSONValue {
        let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        var item = item
        // An Inbox card's id reads that card from Today and Desk too; a Desk item of its own keeps its own read.
        var deskOwnsItem = false
        if page.id == "desk", !item.isEmpty { deskOwnsItem = await quietHost()?.pageItem(page: "desk", named: item) != nil }
        if ["today", "inbox", "desk"].contains(page.id), !item.isEmpty, !deskOwnsItem {
            let cards = (try? await ForPerson.at(root).inbox()) ?? []
            if let card = cards.first(where: { $0.id == item }) ?? cards.first(where: {
                $0.interaction_id == item || $0.interaction_id.map { "card:" + $0 } == item
                    || $0.related_approval_id == item || $0.related_approval_id.map { "approval:" + $0 } == item
            }) {
                item = card.id
                if page.id != "inbox", let inbox = await doorPage("inbox") {
                    return Self.doorOpened(try await doorRead(page: inbox, item: item, offset: offset, surface: surface, turn: turn,
                        execution: execution, following: true), at: (page: "inbox", item: item))
                }
            }
        }
        if !following, !item.isEmpty, let shown = await quietHost()?.pageItem(page: page.id, named: item) { item = shown.id }
        let named = page.id + "/" + item.lowercased()
        if !following, !item.isEmpty, AppDoorNames.aliases[named] != nil {
            let place = AppDoorNames.place(page: named, item: "")
            if place.page != page.id, let next = await doorPage(place.page) {
                return Self.doorOpened(try await doorRead(page: next, item: place.item, offset: offset, surface: surface, turn: turn,
                                                          execution: execution, following: true), at: place)
            }
        }
        if !item.isEmpty, offset == 0, let host = quietHost(), let words = await host.pageItemText(page: page.id, item: item, rows: false) {
            return .object(["status": .string("ok"), "page": .string(page.id), "item": .string(item), "content": .string(words)])
        }
        if turn.doorPreview != nil, Self.doorItemReads[page.id]?[item.lowercased()] == nil,
           !item.hasPrefix("guide:"), !(page.id == "inbox" && !item.isEmpty && item != "earlier"),
           !["tools", "skills", "make"].contains(page.id) {
            return Self.previewPage(page.id, item: item)
        }
        do {
            if page.id == "pairing", item == "phone-senses" {
                return try await Self.doorStoreRead { try PhoneSensesGuide.read(dataRoot: root) }
            }
            if item.hasPrefix("guide:"),
               let action = try await Self.doorPageActions(page.id, hasSettings: false, dataRoot: root, turn: turn).first(where: { "guide:" + $0.id == item }),
               let guide = try AppActions.about(action) {
                return .object(["status": .string("ok"), "page": .string(page.id), "item": .string(item),
                                "guide": .object([action.id: .string(guide)])])
            }
            if page.id == "make" {
                let read = await readMake(ref: item.isEmpty ? nil : item, offset: offset)
                guard !item.isEmpty, read.objectValue?["status"] == .string("ok") else { return read }
                return .object(["status": .string("ok"), "page": .string(page.id), "item": read])
            }
            if !item.isEmpty, let host = quietHost(), let body = try await host.pageBody(page: page.id, item: item, offset: offset, turn: turn) {
                return .object(["status": .string("ok"), "page": .string(page.id), "item": .string(item), "content": .string(body)])
            }
            if ["tools", "skills"].contains(page.id), item.lowercased() == "census" {
                return try await Self.doorAbilityCensus(root: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot(), jobStore: agentJobs.store,
                                                      surface: surface, turn: turn, execution: execution)
            }
            if ["tools", "skills"].contains(page.id) {
                return try await Self.doorStoredParts(page: page, item: item, offset: offset, root: root)
            }
            if page.id == "inbox", item == "earlier" {
                return await runAppPageRead(input: ["page": .string("inbox")], turn: turn)
            }
            if page.id == "inbox", item.lowercased() == "all" {
                guard let host = quietHost() else { return Self.unattachedFailure() }
                let result = await host.inbox(verb: "list", input: ["filter": .string("all"), "limit": .int(200)], turn: turn)
                guard case .object(let list) = result, list["status"] == .string("ok") else { return result }
                let notes: [JSONValue] = if case .array(let notes)? = list["notes"] { notes } else { [] }
                return .object(["status": .string("ok"), "page": .string("inbox"), "title": .string(page.title),
                                "about": .string(page.summary), "count": list["count"] ?? .null, "shown": list["shown"] ?? .null,
                                "items": .array(notes.map { note in
                                    guard case .object(let row) = note else { return note }
                                    let title = String(JSONValue.trimmedScalarTextOrEmpty(row["title"])
                                        .split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(120))
                                    let id = JSONValue.trimmedScalarTextOrEmpty(row["id"])
                                    let source = JSONValue.trimmedScalarTextOrEmpty(row["source"])
                                    return .string("\(id) | kind=\(source) | \(title) | "
                                        + "unread=\(row["status"] == .string("unread"))")
                                })])
            }
            if page.id == "inbox", !item.isEmpty {
                guard let host = quietHost() else { return Self.unattachedFailure() }
                let result = await host.inbox(verb: "read", input: ["id": .string(item)], turn: turn)
                guard ChatToolOutcome.outputLooksSuccessful(result) else { return result }
                guard case .object(let read) = result, case .array(let notes)? = read["notes"],
                      let note = notes.first else { return result }
                return .object(["status": .string("ok"), "page": .string("inbox"), "item": Self.doorButtons(note)])
            }
            if let tool = ["diagnostics": "doctor_status", "telegram": "telegram_status"][page.id],
               Self.doorItemReads[page.id]?[item.lowercased()] != nil {
                let result = try await healthRead(item.lowercased(), turn: turn)
                guard ChatToolOutcome.outputLooksSuccessful(result) else { return result }
                return .object(["status": .string("ok"), "page": .string(page.id), "item": result])
            }
            if page.id == "bots", !item.isEmpty {
                guard let perform = execution.perform else {
                    return Self.doorRefusal("door_unavailable", "A helper reads only from inside a chat turn. Nothing was read.",
                        remedy: "correct_arguments", "Call app from inside a chat turn; this caller cannot bind a chat by supplying a session id.")
                }
                let result = Self.foldedResult(try await perform("bot_list", ["id": .string(item)], turn, execution), guide: nil, tool: "bot_list")
                guard case .object(let list) = result, list["status"] == .string("ok"),
                      case .array(let rows)? = list["bots"], let row = rows.first else { return result }
                return .object(["status": .string("ok"), "page": .string("bots"), "item": row])
            }
            if ["context", "agent_view"].contains(page.id) {
                return await runAppPageRead(input: ["page": .string(page.id), (page.id == "agent_view" ? "room" : "session_id"): .string(item)], turn: turn)
            }
            switch (page.id, item.isEmpty) {
            case ("chat", false):
                let owner = try await Self.doorStoreRead { [item] in
                    try AgentConversationStore(dataRoot: root).resolveConversation(item, scope: turn.verifiedSessionID, matchingTitle: true)
                }
                guard let owner else {
                    return ChatToolOutcome.refusedBeforeRunning(.object(["status": .string("not_found")]))
                }
                switch owner {
                case .session(let row):
                    guard let id = row["id"]?.stringValue else { throw CocoaError(.fileReadCorruptFile) }
                    if row["archived"] == .bool(true) {
                        return .object(["status": .string("ok"), "page": .string("chat"), "item": .object(["conversation": .string(id)])])
                    }
                    let result = await composerRead(sessionId: id, turn: turn)
                    guard case .object(var state) = result else { throw CocoaError(.fileReadCorruptFile) }
                    state["conversation"] = .string(id)
                    return .object(["status": .string("ok"), "page": .string("chat"), "item": .object(state)])
                case .agent(let row):
                    return .object(["status": .string("ok"), "page": .string("chat"), "item": .object(["conversation": .string(row.id)])])
                }
            case (_, false):
                guard let host = quietHost() else { return Self.unattachedFailure() }
                let rows = try await pageSettingRows(page: page, host: host, turn: turn, only: item)
                guard !rows.isEmpty else {
                    let notFound = ChatToolOutcome.refusedBeforeRunning(.object(["status": .string("not_found")]))
                    guard !following, let shown = await host.pageItem(page: page.id, named: item), let open = shown.open,
                          case .page(let to, item: let toItem)? = FaceLink(open) else {
                        guard let words = await host.pageItemText(page: page.id, item: item, rows: true) else { return notFound }
                        return .object(["status": .string("ok"), "page": .string(page.id), "item": .string(item), "content": .string(words)])
                    }
                    let place = AppDoorNames.place(page: to + (toItem.map { "/" + $0 } ?? ""), item: "")
                    guard place.page != page.id || place.item != shown.id, let next = await doorPage(place.page) else { return notFound }
                    return Self.doorOpened(try await doorRead(page: next, item: place.item, offset: offset, surface: surface, turn: turn,
                                                              execution: execution, following: true), at: place)
                }
                return .object(["status": .string("ok"), "page": .string(page.id), "item": .string(item), "settings": .array(rows)])
            default:
                let result = await runAppPageRead(input: ["page": .string(page.id)], turn: turn)
                guard case .object(var read) = result, read["status"] == .string("ok") || read["status"] == .string("partial"),
                      let host = quietHost() else { return result }
                if page.id == "chat",
                   case .object(let list) = await host.runChatSession(verb: "list", input: [:], reachesUser: false, turn: turn) {
                    guard ChatToolOutcome.outputLooksSuccessful(.object(list)) else { return .object(list) }
                    read["conversations"] = list["conversations"]
                    read["conversations_next_offset"] = list["next_offset"]
                }
                if page.id == "providers",
                   case .object(let list) = await host.provider(verb: "list", input: [:], turn: turn) {
                    guard ChatToolOutcome.outputLooksSuccessful(.object(list)) else { return .object(list) }
                    read["accounts"] = list["accounts"]
                }
                return .object(read)
            }
        } catch {
            return ChatToolOutcome.failure(error: error, tool: "app", effects: ToolFailureError.Effects.none)
        }
    }
    @MainActor
    func doorShownPlaces(_ name: String) async throws -> [(page: String, item: String)] {
        let words = name.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        guard !words.isEmpty, !words.contains("/") else { return [] }
        var places: [(page: String, item: String)] = AppDoorNames.aliases.keys.sorted().compactMap { key in
            let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
            return parts.count == 2 && parts[1] == words ? (page: parts[0], item: parts[1]) : nil
        }
        guard let host = quietHost() else { return places }
        for page in try await doorPages {
            guard let shown = await host.pageItem(page: page.id, named: words),
                  !places.contains(where: { $0.page == page.id && $0.item.lowercased() == shown.id.lowercased() }) else { continue }
            places.append((page: page.id, item: shown.id))
        }
        return places
    }
    @MainActor
    func doorShownName(_ name: String, input: [String: JSONValue], surface: String, inProcess: Bool, turn: Turn,
                       execution: AppActionExecution) async throws -> JSONValue? {
        let places = try await doorShownPlaces(name)
        guard let place = places.first else { return nil }
        guard places.count == 1 else {
            return Self.doorRefusal("ambiguous_item", "More than one page shows \(name). Nothing was read.",
                remedy: "choose_page", "Read one of the listed places: app {page:\"<page>\", item:\"<item>\"}.",
                extra: ["places": .array(places.map { .object(["page": .string($0.page), "item": .string($0.item)]) })])
        }
        var call = input
        call["page"] = .string(place.page)
        call["item"] = .string(place.item)
        return AgentWorkspace.resolvedRead(try await runAppDoor(input: call, surface: surface, inProcess: inProcess, turn: turn,
                                                                execution: execution), as: place.page + "." + place.item)
    }
    static func doorOpened(_ read: JSONValue, at place: (page: String, item: String)) -> JSONValue {
        guard case .object(var fields) = read else { return read }
        fields["resolved"] = .string(place.item.isEmpty ? place.page : place.page + "/" + place.item)
        return .object(fields)
    }
    static func doorVersion(asked page: String, item: String, _ read: [String: JSONValue]) throws -> String {
        let place = (read["resolved"]?.stringValue ?? "").split(separator: "/", maxSplits: 1).map(String.init)
        guard let opened = place.first else { return try doorVersion(page: page, item: item, read) }
        return try doorVersion(page: opened, item: place.count > 1 ? place[1] : "", read)
    }
    static func doorVersion(page: String, item: String, _ read: [String: JSONValue]) throws -> String {
        var fields = read.filter { ["content", "settings", "items", "item", "count", "entries", "complete", "blocked"].contains($0.key) }
        if page == "chat", !item.isEmpty, case .object(let composer)? = fields["item"] {
            fields["item"] = .object(composer.filter { ["conversation", "draft", "attachments", "provider", "model", "think", "fast", "persona"].contains(
                $0.key) })
        }
        let shown = JSONValue.object(fields)
        let digest = SHA256.hash(data: try shown.serializedData(pretty: false))
        return (item.isEmpty ? page : page + "/" + item) + "@"
            + digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }
    @MainActor
    func doorCurrentVersion(scope: String, surface: String, turn: Turn, execution: AppActionExecution) async throws -> String? {
        let parts = scope.split(separator: "/", maxSplits: 1).map(String.init)
        if parts.first == "senses", parts.count == 2 {
            guard let registry = SensesHub.shared.registry,
                  case .object(let read) = try await registry.lifecycleRead(id: parts[1]) else { return nil }
            return read["version"]?.scalarText
        }
        guard let name = parts.first, let page = await doorPage(name) else { return nil }
        let item = parts.count > 1 ? parts[1] : ""
        guard case .object(let read) = try await doorRead(page: page, item: item, surface: surface, turn: turn, execution: execution) else { return nil }
        if read["execution"] == .string("preview") {
            throw ToolFailureError("Opening \(scope) in this preview could retain state. Its current version was not checked.",
                effects: .none, owner: scope, code: "preview_version_unavailable")
        }
        guard read["status"] == .string("ok") || read["status"] == .string("partial") else { return nil }
        return try read["version"]?.scalarText ?? Self.doorVersion(asked: page.id, item: item, read)
    }
    @concurrent
    func doorFind(_ query: String, turn: Turn) async throws -> JSONValue {
        let asked = AppActions.intentWords(query)
        let root = await MainActor.run { quietHost()?.dataRootOverride } ?? PersistenceCore.defaultDataRoot()
        let permissions = try await MacIntegrationPermissionStore(dataRoot: root).readinessChecked()
        var schemaGaps: [JSONValue] = []
        func discover(_ action: AppAction) -> JSONValue? {
            let blocker = (action.schema?.macIntegration).flatMap {
                permissions.refusal(integration: $0.integration, mode: $0.mode)
            }
            do { return try AppActions.discovery(action, blocker: blocker) }
            catch {
                schemaGaps.append(.object(["action": .string(action.id),
                    "failure": ChatToolOutcome.failure(error: error, tool: "app", effects: ToolFailureError.Effects.none)]))
                return nil
            }
        }
        let lane = TurnTracePersistLane(dataRootOverride: root)
        func gaveBack(_ contract: JSONValue, _ id: String) async -> JSONValue {
            guard turn.peerSteering?.isTainted(dataRoot: turn.dataRoot) != true, case .object(var fields) = contract,
                  let shapes = try? await lane.gaveBack(action: id), !shapes.isEmpty else { return contract }
            fields["gave_back"] = .array(shapes)
            return .object(fields)
        }
        if let action = try AppActions.action(query, dataRoot: root, turn: turn),
           action.id.lowercased() == query.lowercased() {
            // A home item named exactly is read as page and item, as ranked search returns it: it has no action to call.
            if action.isItemRead {
                return .object(["status": .string("ok"), "find": .string(query), "matched_actions": .int(0), "shown_actions": .int(0),
                    "actions": .array([]), "schema_gaps": .array(schemaGaps), "pages": .array([]),
                    "read_next": .array([.object(action.input.merging(["description": .string(action.label)]) { _, value in value })]),
                    "effects": .string("none")])
            }
            var actions: [JSONValue] = []
            if let contract = discover(action) { actions.append(await gaveBack(contract, action.id)) }
            return .object(["status": .string("ok"), "find": .string(query),
                "matched_actions": .int(1), "shown_actions": .int(Int64(actions.count)),
                "actions": .array(actions), "schema_gaps": .array(schemaGaps),
                "pages": .array([]), "read_next": .array([]), "effects": .string("none")])
        }
        let (ranked, namedPages, gaps) = try await AppActions.ranked(query, pages: doorPageIndex, dataRoot: root, memory: await actionIndex, turn: turn)
        let matches = ranked.prefix(5)
        let actions = matches.filter { !$0.isItemRead }
        let named = AppActions.named(query)
        let items: [JSONValue] = matches.filter(\.isItemRead).map {
            .object($0.input.merging(["description": .string($0.label)]) { _, value in value })
        }
        let pages = try await doorPages.map { page in
            (page, AppActions.hits(AppActions.wordSet(page.id + " " + page.title + " " + page.summary), asked))
        }.filter { $0.1 > 0 }.sorted {
            let leftNamed = namedPages.contains($0.0.id), rightNamed = namedPages.contains($1.0.id)
            if leftNamed != rightNamed { return leftNamed }
            return $0.1 > $1.1
        }.prefix(3)
        let disabled = try AppActions.disabledTools(asked, dataRoot: root).prefix(2)
        var shown: [JSONValue] = []
        for (offset, action) in actions.enumerated() {
            guard let contract = discover(action) else { continue }
            if offset == 0 || named.contains(action.id) { shown.append(await gaveBack(contract, action.id)); continue }
            let blocker = contract.objectValue?["blocker"]?.stringValue
            shown.append(.string(action.line + (blocker.map { " Unavailable: " + $0 } ?? "")))
        }
        var found: [String: JSONValue] = [
            "status": .string("ok"),
            "find": .string(query),
            "matched_actions": .int(Int64(AppActions.matchedActions(ranked).count)), "shown_actions": .int(Int64(shown.count)),
            "actions": .array(shown), "schema_gaps": .array(schemaGaps),
            "pages": .array(pages.map { .string("\($0.0.id): \($0.0.title). \($0.0.summary)") }),
            "read_next": .array(items),
            "note": .string("""
                find discovers actions, pages and home items. Among shown actions, the best and explicitly named ids include args_schema and example; others \
                use id(args) label. Name an id for its full match. Search saved work with work.context {query}, conversations with chat.search {query}. \
                Reversible actions run directly; irreversible examples use preview:true (checks only). Replace <placeholders> with your values.
                """),
            "effects": .string("none"),
        ]
        if matches.isEmpty && pages.isEmpty && disabled.isEmpty && gaps.isEmpty {
            found["reason"] = .string("no_match")
            found["message"] = .string("Nothing matches \"\(query)\": no action, page or item.")
        }
        if !gaps.isEmpty {
            let detail = gaps.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "; ")
            found["message"] = .string("""
                Action search is incomplete: these actions could not be embedded and were excluded. \(detail). Usable actions were searched; this is not \
                evidence that an excluded action does not match. Read its page or name its exact id while repairing the model output.
                """)
        }
        if !disabled.isEmpty { found["disabled"] = .array(Array(disabled)) }
        found["ranking_basis"] = .string("""
            Exact action ids first, then a named page's own actions in page order (registered page ids, titles, door aliases and integration ids); the rest \
            use token overlap and semantic suggestions that clear the attention chance bar against this retrieval epoch's inventory. Assumes most actions are \
            irrelevant and a light-tailed background. Language coverage and natural-language constraints depend on the embedding model. Use -<exact action \
            id> for an explicit exclusion; no language-specific clauses are rewritten.
            """)
        return .object(found)
    }
}
