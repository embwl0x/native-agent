import SenseCore
import MindCore
import MacNerves
import Foundation
import PersistenceCore
import NativeAgentCore
import NativeAgentShared
import DeskCore
// Blueprint: | `AppToolExecutor+AppDoor.swift` | Home items, page dispatch, complete route corrections, version recovery and undo |
/// The app door adds no gate: registry admission and folded re-entry retain the complete chain.
/// It refuses user-only actions below Full Mac, stale versions and undeclared arguments.
extension AppToolExecutor {
    public static let doorToolNames = ["app"]
    /// The rail's inbox means Notifications, while door inbox reads notes from the Today sheet.
    static let doorInbox = QuietToolPage.inbox
    @MainActor var doorPages: [QuietToolPage] { get async throws { [Self.doorInbox] + (try await presentation.pages) } }
    @MainActor var doorPageIndex: [String: QuietToolPage] { get async throws { try await Dictionary(doorPages.map { ($0.id, $0) }, uniquingKeysWith: { first,
        _ in first }) } }
    /// Resolve mounted presentation for "visible" before ordinary page lookup; "current" means the Advanced sidebar page.
    @MainActor func doorPage(_ raw: String) async -> QuietToolPage? {
        let key = AppDoorNames.resolve(raw)
        if key == "inbox" { return Self.doorInbox }
        if key == "current" { return presentation.currentPage }
        // Context receipts and agent_view read outside the index; the latter must not resolve as the agents contact page.
        if let page = QuietToolPage.unindexed.first(where: { $0.id == key }) { return page }
        return await presentation.page(named: key)
    }
    public static let doorDoctor = "Doctor (app {page:\"diagnostics\", item:\"doctor\"})"
    /// Home and unpaged items may name effects, so they share resolution with scripts.
    static func opensHomeItem(_ input: [String: JSONValue]) -> Bool {
        guard !JSONValue.trimmedScalarTextOrEmpty(input["item"]).isEmpty else { return false }
        let page = JSONValue.trimmedScalarTextOrEmpty(input["page"]).lowercased()
        return page.isEmpty || page == "home"
    }
    static let doorScriptKey = "__script"
    /// Repair only an unambiguous batch shape. Conflicting or unreadable values stay beside the door's declared schema.
    static func doorBatchAdvice(_ entries: JSONValue, input: [String: JSONValue]) throws -> JSONValue {
        func shape() throws -> JSONValue {
            guard let schema = appToolSchemas().first(where: { $0.name == "app" }) else {
                throw ToolFailureError("The app input schema is unavailable; repair the door declaration.", effects: .none)
            }
            return .array([.object(["input_schema": try JSONValue.parse(schema.parametersJSON),
                "supplied_input": .object(input.filter { !$0.key.hasPrefix("__") })])])
        }
        let list: [JSONValue]
        switch entries {
        case .array(let calls): list = calls
        case .object: list = [entries]
        default: return try shape()
        }
        guard (1...AppScriptRunner.actionLimit).contains(list.count) else { return try shape() }
        let shared = input.filter {
            !$0.key.hasPrefix("__") && !["actions", "preview", "expected_version"].contains($0.key) && !ToolNameAliases.appDeedKeys.contains($0.key)
                && $0.value != .null
        }
        var calls: [JSONValue] = []
        for entry in list {
            guard case .object(let given) = entry else { return try shape() }
            var call = ToolNameAliases.doorCall("app", given)
            guard call.keys.allSatisfy({ ToolNameAliases.appDoorKeys.contains($0) || ToolNameAliases.appStepKeys.contains($0) || $0.hasPrefix("__") }),
                  shared.allSatisfy({ call[$0.key] == nil || call[$0.key] == .null || call[$0.key] == $0.value }) else {
                return try shape()
            }
            call.merge(shared) { current, supplied in current == .null ? supplied : current }
            if call["args"] != nil, call["args"] != .null,
               !["action", "page", "item", "find", "script"].contains(where: { !JSONValue.trimmedScalarTextOrEmpty(call[$0]).isEmpty }) {
                return try shape()
            }
            calls.append(.object(call))
        }
        var call: [String: JSONValue] = ["actions": .array(calls)]
        for key in ["preview", "expected_version", "then_say", "with"] { call[key] = input[key] }
        return .object(call)
    }
    /// Door refusals precede execution and name the correcting call.
    static func doorRefusal(_ reason: String, _ detail: String, remedy kind: String, _ instruction: String,
                            next: [String: JSONValue]? = nil, extra: [String: JSONValue] = [:]) -> JSONValue {
        var extra = extra
        if extra["try_instead"] == nil, ["correct_arguments", "correct_route"].contains(kind), let next {
            extra["try_instead"] = .object(next)
        }
        extra["remedy"] = .object([
            "kind": .string(kind), "instruction": .string(instruction),
            "next_call": next.map { .object(["tool": .string("app"), "input": .object($0)]) } ?? .null,
        ])
        return ChatToolOutcome.refusedBeforeRunning(code: reason, detail: detail, extra: extra)
    }
    /// The producer supplies the resource, cause and recovery; typed owner evidence survives intact.
    static func ownedFailure(_ error: Error, code: String, owner: String, instruction: String,
                             next: [String: JSONValue], effects: ToolFailureError.Effects) -> JSONValue {
        if error is CancellationError { return ChatToolOutcome.failure(error: error, tool: "app", effects: effects) }
        let producer = ChatToolOutcome.failure(error: ToolFailureError(error.localizedDescription, effects: effects,
            owner: owner, nextCall: ToolFailureError.call("app", next), code: code, instruction: instruction,
            recovery: effects == .unknown ? .reconcile : .inspect), tool: "app")
        if error is ToolFailureError || error is SenseFailure {
            var failure = ChatToolOutcome.failure(error: error, tool: "app", effects: effects).objectValue ?? [:]
            if failure["status"] != .string("cancelled"), failure["remedy"] == nil || failure["remedy"] == .null {
                failure["remedy"] = producer.objectValue?["remedy"]
            }
            return .object(failure)
        }
        return producer
    }
    /// Owned refusals retain the deciding owner and its exact recovery control.
    static func doorRefusal(_ reason: String, _ detail: String, owner: String, next: [String: JSONValue]? = nil,
                            tap: String? = nil, extra: [String: JSONValue] = [:]) -> JSONValue {
        var extra = extra
        extra["remedy"] = Repair.remedy(owner: owner,
            nextCall: next.map { .object(["tool": .string("app"), "input": .object($0)]) }, tap: tap)
        return failure(reason, detail, extra: extra)
    }
    @MainActor
    func runRecordRead(input: [String: JSONValue], turn: Turn) async -> JSONValue {
        let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        return await Self.readRecord(input, root: root, turn: turn)
    }

    /// Store lookup, reads and JSON parsing run away from the UI actor; the store alone owns the SQL and event fold.
    @concurrent private static func readRecord(_ input: [String: JSONValue], root: URL, turn: Turn) async -> JSONValue {
        guard case .string(let grain)? = input["of"], ["experiences", "details"].contains(grain) else {
            return failure("invalid_args", "record.read requires of:experiences or of:details.")
        }
        let filters: Set<String> = grain == "experiences" ? ["id", "id_prefix", "kind", "open_only"]
            : ["subject", "subject_prefix", "kind", "source", "since"]
        let accepted = filters.union(["of", "limit"])
        let misplaced = input.keys.filter { !$0.hasPrefix("__") && !accepted.contains($0) }.sorted()
        guard misplaced.isEmpty else {
            return failure("invalid_args", "These filters do not apply to \(grain): \(misplaced.joined(separator: ", ")).")
        }
        for key in filters.subtracting(["open_only"]) where input[key] != nil {
            guard case .string? = input[key] else { return failure("invalid_args", "\(key) must be a string; omit it to leave it unfiltered.") }
        }
        let limit: Int
        switch input["limit"] {
        case nil: limit = 20
        case .int(let value)? where value > 0:
            guard let count = Int(exactly: value) else { return failure("invalid_args", "limit is too large for this Mac.") }
            limit = count
        default: return failure("invalid_args", "limit must be a positive integer; omit it for 20.")
        }
        do {
            try Task.checkCancellation()
            let store = ExperienceStore.at(root)
            if grain == "experiences" {
                let kind: Experience.Kind?
                if let text = input["kind"]?.stringValue {
                    guard let value = Experience.Kind(rawValue: text) else {
                        return failure("invalid_args", "Experience kind must be heard, answer, act, decision, run, message, happening or thought.")
                    }
                    kind = value
                } else { kind = nil }
                let openOnly: Bool
                switch input["open_only"] {
                case nil: openOnly = false
                case .bool(let value)?: openOnly = value
                default: return failure("invalid_args", "open_only must be a boolean; omit it to read open and closed experiences.")
                }
                let id = input["id"]?.stringValue, idPrefix = input["id_prefix"]?.stringValue
                func readExperiences(ownSessionOnly: Bool) async throws -> (total: Int, items: [Experience], unreadable: [ExperienceStore.Unreadable])? {
                    let conversation: String?
                    if ownSessionOnly {
                        guard let session = ChatToolSessionInjection.currentSession(turn: turn) else { return nil }
                        conversation = session
                    } else {
                        conversation = nil
                    }
                    return try await store.recordedExperiences(id: id, idPrefix: idPrefix, kind: kind, openOnly: openOnly,
                        conversation: conversation, limit: limit)
                }
                var ownSessionOnly = turn.peerSteering?.isTainted(dataRoot: turn.dataRoot) == true
                var page = try await readExperiences(ownSessionOnly: ownSessionOnly)
                try Task.checkCancellation()
                if !ownSessionOnly, turn.peerSteering?.isTainted(dataRoot: turn.dataRoot) == true {
                    ownSessionOnly = true
                    page = try await readExperiences(ownSessionOnly: true)
                    try Task.checkCancellation()
                }
                guard let page else {
                    return .object(["status": .string("ok"), "of": .string(grain),
                        "matched_total": .int(0), "returned": .int(0),
                        "has_more": .bool(false), "items": .array([]), "unreadable": .array([]),
                        "effects": .string("none")])
                }
                let currentSession = ownSessionOnly ? ChatToolSessionInjection.currentSession(turn: turn) : nil
                let items = try page.items.compactMap { experience -> JSONValue? in
                    guard !ownSessionOnly || currentSession.map({ session in
                        experience.addressedTo.contains("conversation:" + session) || experience.owes.values.contains { $0.to == "conversation:" + session }
                            || experience.evidence.contains(.init(source: "conversation", id: session))
                    }) == true else { return nil }
                    guard case .object(var fields) = try JSONValue.fromEncodable(experience) else { throw CocoaError(.coderInvalidValue) }
                    fields["open"] = .bool(experience.isOpen)
                    fields["face"] = try JSONValue.fromEncodable(experience.face)
                    fields["outcome"] = try JSONValue.fromEncodable(experience.outcome)
                    fields["happening"] = try JSONValue.fromEncodable(experience.happening)
                    return .object(fields)
                }
                let unreadable: [JSONValue] = page.unreadable.map { record in
                    if ownSessionOnly { return .object(["error": .string("The unreadable experience's conversation could not be verified.")]) }
                    return .object(["id": .string(record.id), "event": .int(record.seq), "error": .string(record.words)])
                }
                return .object(["status": .string(unreadable.isEmpty ? "ok" : "partial"), "of": .string(grain),
                    "matched_total": .int(Int64(page.total)), "returned": .int(Int64(items.count)),
                    "has_more": .bool(page.total > items.count + unreadable.count), "items": .array(items), "unreadable": .array(unreadable),
                    "effects": .string("none")])
            }
            let since: Date?
            if let text = input["since"]?.stringValue {
                guard let date = NativeTimestampFormat.parseISO8601FractionalFirst(text) else {
                    return failure("invalid_args", "since must be an ISO 8601 timestamp with a timezone.")
                }
                since = date
            } else { since = nil }
            let source = input["source"]?.stringValue, subject = input["subject"]?.stringValue, kind = input["kind"]?.stringValue
            let subjectPrefix = input["subject_prefix"]?.stringValue
            func readDetails(ownSessionOnly: Bool) async throws -> (total: Int, items: [ExperienceStore.Detail])? {
                var query = ExperienceStore.DetailQuery(sources: source.map { [$0] },
                    subjects: subject.map { [$0] }, kinds: kind.map { [$0] }, from: since,
                    limit: limit, newestFirst: true, subjectPrefix: subjectPrefix)
                if ownSessionOnly {
                    guard let session = ChatToolSessionInjection.currentSession(turn: turn) else { return nil }
                    query.conversation = session
                }
                return try await store.recordedDetails(query)
            }
            var ownSessionOnly = turn.peerSteering?.isTainted(dataRoot: turn.dataRoot) == true
            var page = try await readDetails(ownSessionOnly: ownSessionOnly)
            try Task.checkCancellation()
            if !ownSessionOnly, turn.peerSteering?.isTainted(dataRoot: turn.dataRoot) == true {
                ownSessionOnly = true
                page = try await readDetails(ownSessionOnly: true)
                try Task.checkCancellation()
            }
            guard let page else {
                return .object(["status": .string("ok"), "of": .string(grain),
                    "matched_total": .int(0), "returned": .int(0), "selected": .int(0),
                    "has_more": .bool(false), "items": .array([]), "gaps": .array([]), "effects": .string("none")])
            }
            let currentSession = ownSessionOnly ? ChatToolSessionInjection.currentSession(turn: turn) : nil
            var items: [JSONValue] = [], gaps: [JSONValue] = []
            for detail in page.items {
                var fields: [String: JSONValue] = ["seq": .int(detail.seq), "at": .string(NativeTimestampFormat.fractionalZulu(detail.at)),
                    "source": .string(detail.source), "kind": .string(detail.kind), "subject": .string(detail.subject),
                    "once": try JSONValue.fromEncodable(detail.once)]
                do {
                    guard detail.row.count <= ExperienceStore.maxRowBytes else {
                        throw ExperienceStore.DetailError.tooLarge(detail.kind, detail.row.count)
                    }
                    let row = try JSONValue.parse(detail.row)
                    let session = detail.source == "trust" && detail.kind == "consent"
                        ? row.objectValue?["origin"]?.objectValue?["session_id"] : row.objectValue?["sessionId"]
                    guard !ownSessionOnly || currentSession.map({
                        session == .string($0)
                    }) == true else { continue }
                    fields["row"] = row
                    items.append(.object(fields))
                } catch {
                    if ownSessionOnly {
                        gaps.append(.object(["error": .string("The unreadable detail's conversation could not be verified.")]))
                        continue
                    }
                    fields["error"] = .string(error.localizedDescription)
                    fields["remedy"] = Repair.remedy(owner: "experiences/experiences.sqlite",
                        nextCall: .object(["tool": .string("app"), "input": .object(["action": .string("doctor.run")])]), tap: nil)
                    gaps.append(.object(fields))
                }
            }
            return .object(["status": .string(gaps.isEmpty ? "ok" : "partial"), "of": .string(grain),
                "matched_total": .int(Int64(page.total)), "returned": .int(Int64(items.count)), "selected": .int(Int64(page.items.count)),
                "has_more": .bool(page.total > page.items.count), "items": .array(items), "gaps": .array(gaps), "effects": .string("none")])
        } catch {
            return ownedFailure(error, code: "record_unreadable", owner: "experiences/experiences.sqlite",
                instruction: "Inspect the experience store's cause with Doctor; an unreadable record does not establish missing history.",
                next: ["action": .string("doctor.run")], effects: .none)
        }
    }

    /// Only explicit release with a reason or a successful operation settles owed repair.
    @MainActor
    func runRepairLetGo(input: [String: JSONValue]) async -> JSONValue {
        if Task.isCancelled { return ChatToolOutcome.failure(error: CancellationError(), tool: "app", effects: ToolFailureError.Effects.none) }
        var id = (input["id"]?.scalarText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = (input["reason"]?.scalarText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = (input["operation_prefix"]?.scalarText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        if !prefix.isEmpty { return await letGoRepairs(operationPrefix: prefix, reason: reason, alsoNamed: id, root: root) }
        guard !id.isEmpty, !reason.isEmpty else {
            return Self.doorRefusal("invalid_args", "Pass id (from an OWED line on your home) and reason. Nothing was let go.",
                remedy: "correct_arguments", "Call repair.let_go with id and reason.")
        }
        let store = ExperienceStore.at(root)
        do {
            // The delivery lifecycle owns the debt. Desk can see it before its advisory experience projection has landed.
            let released = try await CodexCompletionLifecycle.letGoReplies(deliveryIDs: [id], outcome: reason, dataRoot: root,
                configRoot: InstallPaths.current.bridgeConfigRoot(dataRoot: root))
            if released.contains(id) {
                return .object(["status": .string("ok"), "id": .string(id), "let_go": .string(reason), "effects": .string("occurred")])
            }
            try Task.checkCancellation()
            await store.drained()
            try Task.checkCancellation()
            var owed = try await store.experience(id)
            try Task.checkCancellation()
            // A named subject, or the short id Home and Doctor show, may settle only the unique open repair it names.
            if owed == nil {
                let short = id.count >= 6 && !id.contains(":")
                let named = try await store.open().filter { debt in
                    RepairOwed.isOwed(debt) && (RepairDebt(debt).operation.map { $0 == id || $0.hasSuffix(":" + id) } == true
                        || short && debt.id.split(separator: ":").contains { $0.hasPrefix(id) })
                }
                if named.count == 1 { owed = named[0]; id = named[0].id }
                else if named.count > 1 {
                    return Self.failure("ambiguous_id", "\(id) names \(named.count) open repairs; pass the full id of the one to let go. Nothing was let go.",
                        extra: ["choices": .array(named.prefix(8).map { .string($0.id) })])
                }
            }
            try Task.checkCancellation()
            if let owed, owed.owes["deliver"]?.phase.isSettled == false,
               owed.evidence.contains(where: { $0.source == "codex-completion-lifecycle" }) {
                return Self.failure("delivery_unavailable", "The reply's experience still shows delivery owed, "
                    + "but its delivery owner could not confirm an open reply for \(id). Nothing was let go.",
                    extra: ["remedy": .object(["kind": .string("inspect"),
                        "instruction": .string("Read the retained delivery before repairing its record; do not resend the reply."),
                        "next_call": .object(["tool": .string("app"), "input": .object(["action": .string("agent.jobs")])])])])
            }
            // Release obsolete reply debt through its redelivery checkpoint so recovery cannot deliver it again.
            if let owed, id.hasPrefix(Experience.answer(run: "")),
               owed.owes.contains(where: { $0.key.hasPrefix("deliver:") && !$0.value.phase.isSettled }),
               let conversation = owed.addressedTo.first(where: { $0.hasPrefix("conversation:") }) {
                try await store.append([.claim(.init(claim: "let go: " + reason, evidence: []))], to: id)
                try await SwiftNativeChatOrchestrationClient.settleReplyCheckpoint(dataRoot: root,
                    sessionId: String(conversation.dropFirst("conversation:".count)),
                    runId: String(id.dropFirst(Experience.answer(run: "").count)), verdict: "let_go")
                return .object(["status": .string("ok"), "id": .string(id), "let_go": .string(reason), "effects": .string("occurred")])
            }
            if let owed, owed.owes["decide"]?.phase.isSettled == false {
                return Self.failure("person_decides", """
                    \(id) waits on the person's decision; it is theirs to answer, not yours to let go. Nothing was let go.
                    """,
                    extra: ["remedy": .object(["kind": .string("none"),
                        "instruction": .string("Wait on it with desk.wait, or ask the person."), "next_call": .null])])
            }
            guard let owed, owed.owes["repair"]?.phase.isSettled == false else {
                return Self.failure("not_owed", "Nothing open that you owe has id \(id). Nothing was let go.",
                    extra: ["remedy": .object(["kind": .string("inspect"),
                        "instruction": .string("Read the OWED lines on your home for the ids still owed."),
                        "next_call": .object(["tool": .string("app"), "input": .object(["page": .string("home")])])])])
            }
            try await store.append([.claim(.init(claim: "let go: " + reason, evidence: [])),
                                    .letGo(key: "repair", reason: .abandoned)], to: id)
            return .object(["status": .string("ok"), "id": .string(id), "let_go": .string(reason), "effects": .string("occurred")])
        } catch is CancellationError {
            return ChatToolOutcome.failure(error: CancellationError(), tool: "app", effects: .unknown)
        } catch {
            return Self.failure("unreadable", "Reply or repair settlement could not complete: \(error.localizedDescription) "
                + "Read its current state before trying again.",
                extra: ["effects": .string("unknown"), "remedy": Repair.remedy(owner: "reply delivery lifecycle / experiences/experiences.sqlite",
                    nextCall: .object(["tool": .string("app"), "input": .object(["action": .string("doctor.run")])]), tap: nil)])
        }
    }
    /// Every open repair whose operation starts with the prefix goes through the one-id path, so each keeps that path's checks.
    private func letGoRepairs(operationPrefix prefix: String, reason: String, alsoNamed id: String, root: URL) async -> JSONValue {
        guard id.isEmpty, !reason.isEmpty else {
            return Self.doorRefusal("invalid_args", "Pass operation_prefix or id, not both, and a reason. Nothing was let go.",
                remedy: "correct_arguments", "Call repair.let_go with operation_prefix and reason.")
        }
        let store = ExperienceStore.at(root)
        let ids: [String]
        do {
            await store.drained()
            try Task.checkCancellation()
            ids = try await store.open().filter { debt in
                RepairOwed.isOwed(debt) && RepairDebt(debt).operation?.hasPrefix(prefix) == true
            }.map(\.id)
            try Task.checkCancellation()
        } catch is CancellationError {
            return ChatToolOutcome.failure(error: CancellationError(), tool: "app", effects: ToolFailureError.Effects.none)
        } catch {
            return Self.failure("unreadable", "Open repairs could not be read: \(error.localizedDescription) Nothing was let go.",
                extra: ["effects": .string("none"), "remedy": Repair.remedy(owner: "experiences/experiences.sqlite",
                    nextCall: .object(["tool": .string("app"), "input": .object(["action": .string("doctor.run")])]), tap: nil)])
        }
        guard !ids.isEmpty else {
            return Self.doorRefusal("not_owed", "No open repair's operation starts with \(prefix). Nothing was let go.",
                remedy: "inspect", "Read the OWED lines on your home for the operations still owed.", next: ["page": .string("home")])
        }
        var released = 0
        var refused: [JSONValue] = []
        var unverifiedEffects = false
        for each in ids {
            if Task.isCancelled { break }
            let result = await runRepairLetGo(input: ["id": .string(each), "reason": .string(reason)])
            if case .object(let fields) = result, fields["effects"] == .string("unknown") { unverifiedEffects = true }
            if case .object(let fields) = result, fields["status"] == .string("ok") { released += 1 } else {
                refused.append(.object(["id": .string(each), "result": result]))
            }
        }
        return .object(["status": .string(Task.isCancelled ? "cancelled" : refused.isEmpty ? "ok" : "partial"),
            "operation_prefix": .string(prefix), "unattempted": .int(Int64(ids.count - released - refused.count)),
            "let_go": .string(reason), "released": .int(Int64(released)), "refused_count": .int(Int64(refused.count)),
            "refused": .array(Array(refused.prefix(10))), "effects": .string(unverifiedEffects ? "unknown" : released > 0 ? "occurred" : "none")])
    }
    @MainActor func runTurnReconcile(input: [String: JSONValue]) async -> JSONValue {
        let root = quietHost()?.dataRootOverride ?? securityCenter.dataRoot
        do {
            let engine = try interactions.engine.resolve()
            guard engine.dataRoot.standardizedFileURL.path == root.standardizedFileURL.path else {
                throw ToolFailureError("The recovery request belongs to a different data root.", effects: .none)
            }
            try await engine.abandonedTurns.reconcile(
                sessionId: JSONValue.trimmedScalarTextOrEmpty(input["session_id"]), turnId: JSONValue.trimmedScalarTextOrEmpty(input["turn_id"]))
            return .object(["status": .string("ok"), "detail": .string("The saved turn was reconciled.")])
        } catch { return ChatToolOutcome.failure(error: error) }
    }
    @concurrent static func doorActionCorrection(_ name: String, input: [String: JSONValue], turn: Turn) async throws -> JSONValue? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let args = if case .object(let args)? = input["args"] { args } else { [String: JSONValue]() }
        guard let action = try AppActions.action(key, turn: turn) ?? AppActions.pagePrefixedAction(key, turn: turn) else { return nil }
        var call = ["action": JSONValue.string(action.id), "args": input["args"] ?? .object(args)]
        if action.argSpecs.flatMap(\.names).contains("query") {
            if call["args"] == .object([:]), case .string(let words)? = input["find"], !words.trimmingCharacters(in: .whitespaces).isEmpty {
                call["args"] = .object(["query": .string(words)])
            }
            if case .string(let words)? = call["args"] { call["args"] = .object(["query": .string(words)]) }
        }
        for key in ["preview", "expected_version"] { if let value = input[key] { call[key] = value } }
        TurnTraceBus.fireFromContext(kind: "shim.fired", payload: .object(["id": .string("T16"), "site": .string(
            "AppToolExecutor+AppDoor.swift:doorActionCorrection")]), turn: turn)
        let advice = try AppActions.callAdvice(action, input: call,
            discovery: AppActions.discovery(action).objectValue ?? [:])
        return doorRefusal("action_route", "Use try_instead's app call or declared argument shape. Nothing ran.",
            remedy: "correct_route", "Make next_call instead.", next: call,
            extra: ["resolved": call["action"] ?? .null, "try_instead": advice])
    }
    /// User/posture refusals run nothing; retrying without changing the cause cannot help.
    static let doorFloorReasons: Set<String> = [
        "owners_call", "owner_only", "trust_mode_read_only", "trust_mode_unreadable", "owners_screen", "owner_is_in_it",
        "opens_for_owner", "owners_ears", "owners_draft",
        // Remote or unknown-origin cards remain user-owned.
        "not_yours_to_answer", "origin_unverifiable",
        // Direct person-only actions remain so under Full Mac, including browser sign-in.
        "needs_person",
    ]
    static let doorItemReads = AppDoorNames.items
    /// Every page words not_found consistently with its page/name/recovery read; unrelated failures retain their own cause.
    static func doorItemRead(_ result: JSONValue, page: QuietToolPage, item: String) -> JSONValue {
        guard !item.isEmpty, case .object(let fields) = result, fields["status"] == .string("not_found") else { return result }
        return failure("unknown_item", "Nothing named \(item) is on the \(page.title) page now; app {page:\"\(page.id)\"} lists what is.",
            extra: ["remedy": .object(["kind": .string("read_page"), "instruction": .string("Read the page without item; nothing was done."),
                "next_call": .object(["tool": .string("app"), "input": .object(["page": .string(page.id)])])])])
    }
    /// Note buttons share door action ids; viewing is an item read, and unnamed buttons retain inbox.act.
    static func doorButtons(_ note: JSONValue) -> JSONValue {
        guard case .object(var row) = note, case .array(let buttons)? = row["actions"] else { return note }
        row["actions"] = .array(buttons.compactMap { button -> JSONValue? in
            let text = button.scalarText ?? ""
            let parts = text.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return noteButton(id: parts[0], label: parts.count > 1 ? parts[1] : parts[0]).map(JSONValue.string)
        })
        return .object(row)
    }
    /// View/read/reply remain reads; other buttons bind their action or inbox.act by id.
    public static func noteButton(id raw: String, label: String) -> String? {
        let id = InboxActionVocabulary.normalizedAction(raw.lowercased())
        guard !["view", "read", "reply"].contains(id) else { return nil }
        // Inbox buttons are fixed declarations, never a file-backed catalog lookup.
        let seeds: [AppAction]
        do { seeds = try AppActions.seedActions }
        catch { return label + " · action catalog unavailable: " + error.localizedDescription + "; repair the catalog before using this button" }
        let action = seeds.first { $0.page == "inbox" && $0.label.caseInsensitiveCompare(label) == .orderedSame }
            ?? (["archive", "dismiss", "repair"].contains(id) ? seeds.first { $0.id == "inbox." + id } : nil)
        guard let action else { return "inbox.act(action: \"\(id)\") \(label)" }
        return action.id + (action.isPersonOwned ? " · the owner's" : "")
    }
    /// Self-window handoffs execute in process inside the original gated act/go/screen call.
    @MainActor
    public func runSelfAppRoute(input: [String: JSONValue], surface: String, turn: Turn, execution: AppActionExecution) async -> JSONValue {
        do { return try await runAppDoor(input: input, surface: surface, inProcess: true, turn: turn, execution: execution) }
        catch { return ChatToolOutcome.failure(error: error, tool: "app") }
    }
    @MainActor
    func runAppDoor(input rawInput: [String: JSONValue], surface: String, inProcess: Bool = false, turn: Turn,
        execution: AppActionExecution) async throws -> JSONValue {
        var input = rawInput
        if turn.doorPreview != nil { input["preview"] = .bool(true) }
        if AppDoorNames.resolve(JSONValue.trimmedScalarTextOrEmpty(input["page"])) == "visible", input["action"] == nil {
            guard let visible = presentation.visiblePageInput else { return Self.unattachedFailure() }
            input.merge(visible) { _, visible in visible }
        }
        let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let resolved = try await AppActions.resolvedAction(JSONValue.trimmedScalarTextOrEmpty(input["action"]), dataRoot: root, turn: turn)
        if rawInput["preview"] == nil, let bound = execution.invocation[BoundDoorAction.self],
           let admitted = bound.previewRead, bound.requested == input["action"]?.stringValue,
           let action = resolved?.action, admitted.id == action.id, admitted.tool == action.tool,
           action.runsInPreview(args: input["args"]?.objectValue ?? [:]) {
            input.removeValue(forKey: "preview")
        }
        let form: String?
        if let resolved {
            form = try resolved.action.arguments.projection(resolved.action).form.get()
        } else { form = nil }
        let result: JSONValue
        do {
            if execution.argumentPreflightOnly {
                guard let resolved else {
                    return Self.doorRefusal("unknown_action", "No action is called \(JSONValue.trimmedScalarTextOrEmpty(input["action"])). Nothing ran.",
                        remedy: "find", "Find the action's current name and argument schema before calling it.",
                        next: ["find": input["action"] ?? .string("")])
                }
                // Admission never opens a corrected read or dispatches a scalar-list batch.
                result = try await doorDo(resolved.action.id, resolved: resolved, input: input, surface: surface,
                    inProcess: inProcess, turn: turn, execution: execution)
            } else {
                result = try await runAppDoorCall(input: input, resolvedAction: resolved, surface: surface, inProcess: inProcess,
                    turn: turn, execution: execution)
            }
        } catch is CancellationError { throw CancellationError() }
        catch { result = ChatToolOutcome.failure(error: error, tool: "app") }
        guard let resolved, let form else { return result }
        let reply = ToolResult(result)
        var receipt = result.objectValue ?? ["result": result,
            "status": .string(ChatToolOutcome.statusWord(result, verdict: reply.outcome)),
            "execution": .string(reply.outcome == .succeeded ? "executed" : "attempted")]
        receipt["action"] = receipt["action"] ?? .string(resolved.action.id)
        receipt["argument_form"] = .string(form)
        if let bound = execution.invocation[BoundDoorAction.self], bound.requested == input["action"]?.stringValue, !bound.understood.isEmpty {
            receipt["understood"] = .string(bound.understood.joined(separator: "; "))
        }
        return .object(receipt)
    }
    @MainActor
    private func runAppDoorCall(input rawInput: [String: JSONValue], resolvedAction: (action: AppAction, discovery: [String: JSONValue])?,
        surface: String, inProcess: Bool, turn: Turn, execution: AppActionExecution) async throws -> JSONValue {
        var input = rawInput
        let workspace = ChatWorkspaceBinding.operation(turn: turn, invocation: execution.invocation, jobs: agentJobs.store)
        // Approval replay carries the same receipt into this action's explicit execution.
        if let saved = input.removeValue(forKey: "__undo_receipt") {
            return try await doorUndoReplay(saved, input: input, surface: surface, inProcess: inProcess, turn: turn, execution: execution)
        }
        if case .string? = input["item"], JSONValue.trimmedScalarTextOrEmpty(input["item"]).isEmpty { input.removeValue(forKey: "item") }
        let action = JSONValue.trimmedScalarTextOrEmpty(input["action"])
        // With an action, the action is what runs. An item it did not take as its own names nothing beside it, so it is refused, never opened in
        // the action's place; a page or find beside an action stays the context it always was.
        if let named = resolvedAction?.action, !JSONValue.trimmedScalarTextOrEmpty(input["item"]).isEmpty {
            return Self.doorRefusal("beside_action",
                "\(named.id) is what runs, and a field beside it is not one of its arguments. Nothing was read or done.",
                remedy: "correct_arguments", "Put the action's own arguments inside args, as its args_schema names them.",
                next: ["find": .string(named.id)])
        }
        let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let scope = input["__session_id"]?.scalarText ?? turn.verifiedSessionID ?? ""
        let route = AppDoorRoute(input: input, action: action, resolvedAction: resolvedAction, workspace: workspace, root: root, scope: scope,
            surface: surface, inProcess: inProcess, turn: turn, execution: execution)
        if let routed = try await doorRouteByName(route) { return routed }
        if let routed = try await doorRouteDeed(route) { return routed }
        if let routed = try await doorRouteAction(route) { return routed }
        let result = try await doorRoutePage(route)
        guard case .program = turn.doorPreview, case .object(var read) = result,
              read["execution"] == nil, read["status"] == .string("ok") || read["status"] == .string("partial") else { return result }
        read["execution"] = .string("executed")
        read["effects"] = .string("none")
        return .object(read)
    }
    /// An approval's replay of an undo runs the action with the receipt it carries, only while it is still this conversation's last change.
    @MainActor
    private func doorUndoReplay(_ saved: JSONValue, input: [String: JSONValue], surface: String, inProcess: Bool, turn: Turn,
        execution: AppActionExecution) async throws -> JSONValue {
        let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let session = turn.verifiedSessionID ?? input["__session_id"]?.scalarText ?? ""
        guard !session.isEmpty, case .object(let receipt) = saved, receipt["action"] == input["action"],
              saved == (await AgentWorkspaceNavigation.shared.undoReceipt(dataRoot: root, scope: session)) else {
            return Self.failure("stale_undo", "That undo receipt is no longer this conversation's last change. Nothing was written.")
        }
        var undoExecution = execution
        undoExecution.undoReceipt = saved
        let result = try await runAppDoor(input: input, surface: surface, inProcess: inProcess, turn: turn, execution: undoExecution)
        if input["preview"] != .bool(true), ChatToolOutcome.outputLooksSuccessful(result), !ChatToolOutcome.isWaitingOnPerson(result) {
            await AgentWorkspaceNavigation.shared.clearUndo(saved, dataRoot: root, scope: session)
        }
        return result
    }
    /// A name with no action: the page the call last read, a home step, or the one owner a bare item names.
    @MainActor
    private func doorRouteByName(_ route: AppDoorRoute) async throws -> JSONValue? {
        var input = route.input
        let action = route.action, workspace = route.workspace, root = route.root, scope = route.scope
        let surface = route.surface, inProcess = route.inProcess, turn = route.turn, execution = route.execution
        if action.isEmpty, JSONValue.trimmedScalarTextOrEmpty(input["page"]).isEmpty, !JSONValue.trimmedScalarTextOrEmpty(input["item"]).isEmpty,
           input[Self.doorScriptKey] != .bool(true), !scope.isEmpty,
           let page = await AgentWorkspaceNavigation.shared.lastDoorPage(dataRoot: root, scope: scope),
           ["tools", "skills"].contains(page) {
            let item = JSONValue.trimmedScalarTextOrEmpty(input["item"])
            if try await Self.storedItem(item, page: page, root: root) != nil || item.lowercased() == "census" { input["page"] = .string(page) }
        }
        // Call prediction must share the exact page/item resolution used by execution.
        if let step = AppDoorNames.step(page: JSONValue.trimmedScalarTextOrEmpty(input["page"]), item: JSONValue.trimmedScalarTextOrEmpty(input["item"]),
                                        action: !JSONValue.trimmedScalarTextOrEmpty(input["action"]).isEmpty) {
            if step.page.isEmpty { input.removeValue(forKey: "page") } else { input["page"] = .string(step.page) }
            if let item = step.item { input["item"] = .string(item) }
            let result = try await runAppDoor(input: input, surface: surface, inProcess: inProcess, turn: turn, execution: execution)
            return AgentWorkspace.resolvedRead(result, as: step.label)
        }
        // A bare item names its unique owner; ambiguity is explicit, including a home room. With an action, the action runs instead.
        if action.isEmpty, JSONValue.trimmedScalarTextOrEmpty(input["page"]).isEmpty,
           case .string? = input["item"], !JSONValue.trimmedScalarTextOrEmpty(input["item"]).isEmpty {
            let named = JSONValue.trimmedScalarTextOrEmpty(input["item"])
            var owners = Dictionary(uniqueKeysWithValues: Self.doorItemReads.filter {
                $0.value[named.lowercased()] != nil
            }.map { ($0.key, named.lowercased()) })
            let skillName = named.hasPrefix("skill:") ? String(named.dropFirst(6)).trimmingCharacters(in: .whitespaces) : named
            if let skill = try await Self.storedItem(skillName, page: "skills", root: root) { owners["skills"] = skill }
            if let host = quietHost() {
                if let refusal = await host.inboxFence(verb: "read", input: ["id": .string(named)], turn: turn) {
                    guard case .object(let fields) = refusal, fields["reason"] == .string("unknown_id") else { return refusal }
                } else { owners["inbox"] = named }
            }
            if let desk = try await SwiftNativeDeskStore(dataRoot: root).liveState().matching(named).first {
                owners["desk"] = desk.handle
            }
            let conversations = try await Self.doorStoreRead { try HumanConversationIndex.rows(dataRoot: root) }
            let ids = conversations.filter { $0["id"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 })?.caseInsensitiveCompare(named) == .orderedSame }
            let conversationID = !ids.isEmpty
            let matches = conversationID ? ids : conversations.filter { $0["title"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 })?.caseInsensitiveCompare(
                named) == .orderedSame }
            guard matches.count <= 1 else {
                return Self.doorRefusal("ambiguous_item", "More than one conversation has that name.",
                    remedy: "choose_item", "Read chat.list, then use an exact conversation id.", next: ["action": .string("chat.list")])
            }
            if let row = matches.first { owners["chat"] = row["id"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }) }
            if !owners.isEmpty, !conversationID, !(owners["desk"] != nil && named.lowercased().hasPrefix("desk.")),
               await AgentScreen.classify(workspace: workspace, named, dataRoot: root, scope: scope) != .unknown {
                owners["home"] = named
            }
            if owners.count > 1 {
                return Self.doorRefusal("ambiguous_item", "More than one page owns that item.",
                    remedy: "choose_page", "Read it with one of the listed pages and the same item.",
                    extra: ["pages": .array(owners.keys.sorted().map(JSONValue.string))])
            }
            if owners.count == 1, let (page, item) = owners.first {
                input["page"] = .string(page)
                input["item"] = .string(item)
                return AgentWorkspace.resolvedRead(try await runAppDoor(input: input, surface: surface, inProcess: inProcess, turn: turn, execution: execution),
                                         as: page + "." + item)
            }
            if let page = await doorPage(named) {
                input["page"] = .string(page.id)
                input.removeValue(forKey: "item")
                return AgentWorkspace.resolvedRead(try await runAppDoor(input: input, surface: surface, inProcess: inProcess, turn: turn,
                    execution: execution), as: page.id)
            }
            // A reference Home issued is claimed by Home first; a name no owner, page or home name claims opens the one page item that shows it.
            if !(await AgentWorkspaceNavigation.shared.issued(named, dataRoot: root, scope: scope)),
               await AgentScreen.classify(workspace: workspace, named, dataRoot: root, scope: scope) == .unknown,
               let shown = try await doorShownName(named, input: input, surface: surface, inProcess: inProcess, turn: turn, execution: execution) {
                return shown
            }
        }
        route.input = input
        return nil
    }
    @concurrent private static func storedItem(_ name: String, page: String, root: URL) async throws -> String? {
        if page == "tools" { return try Parts(root: root).row(name, kind: nil)?["id"]?.stringValue }
        return try InstalledSkillInventory.match(name, in: InstalledSkillInventory.entries(dataRoot: root, includingSource: false))?.id
    }
    /// A deed: its keys checked, one action or a found folded into a batch, the batch run, or a script.
    @MainActor
    private func doorRouteDeed(_ route: AppDoorRoute) async throws -> JSONValue? {
        var input = route.input
        let action = route.action, surface = route.surface, turn = route.turn, execution = route.execution
        // Other keys app does not take still fail loudly; a deed key sent as null was omitted.
        for key in ToolNameAliases.appDeedKeys where input[key] == .null { input.removeValue(forKey: key) }
        if input["expect"] == .null { input.removeValue(forKey: "expect") }
        // A deed beside one action is a batch of one; a find beside actions is one more step of it.
        if input["actions"] == nil || input["actions"] == .null, !action.isEmpty,
           ToolNameAliases.appDeedKeys.contains(where: { input[$0] != nil }) {
            var step: [String: JSONValue] = [:]
            for key in ["action", "args", "page", "item", "expect"] {
                if let value = input.removeValue(forKey: key), value != .null { step[key] = value }
            }
            input["actions"] = .array([.object(step)])
        }
        if case .array(let steps)? = input["actions"], let found = input["find"], found != .null {
            input["actions"] = .array(steps + [.object(["find": found])])
            input.removeValue(forKey: "find")
        }
        let deed = input["actions"] != nil && input["actions"] != .null
        let valid = deed ? ToolNameAliases.appDoorKeys.union(ToolNameAliases.appDeedKeys) : ToolNameAliases.appDoorKeys
        let stray = input.keys.filter { !valid.contains($0) && !$0.hasPrefix("__") }.sorted()
        if !stray.isEmpty {
            if stray.count == 1, action.isEmpty, let key = stray.first, let value = input[key],
               let correction = try await Self.doorActionCorrection(key, input: input.merging(["args": value]) { _, value in value }, turn: turn) {
                return correction
            }
            return Self.doorRefusal("unknown_key",
                "app takes no \(stray.joined(separator: ", ")). Its keys are page, item, action, args, actions, preview, "
                + "expected_version, because, find and script. Use expect with action and then_say, or on each step of actions. An action's own arguments go inside args, "
                + "or beside action when the call has no args. Nothing was read or done.",
                remedy: "correct_arguments", "Call app again with only those keys; {} lists the pages.",
                next: [:], extra: ["unrecognised": .array(stray.map(JSONValue.string)), "valid": .array(valid.sorted().map(JSONValue.string))])
        }
        // Strict providers represent omitted optional fields with null.
        if let entries = input["actions"], entries != .null {
            let beside = input.filter { $0.key != "actions" && $0.value != .null }
            guard case .array(let list) = entries,
                  beside.keys.allSatisfy({ $0.hasPrefix("__") || ["preview", "expected_version", "because"].contains($0)
                      || ToolNameAliases.appDeedKeys.contains($0) }) else {
                let found = try Self.doorBatchAdvice(entries, input: input)
                let advice = found.objectValue.map { JSONValue.object(MacInjectionArgRedaction.redacted(tool: "app", input: $0, turn: turn)) } ?? found
                return Self.doorRefusal("invalid_actions",
                    "actions is a list of app calls ({action, args}, {page[, item]} or {item}, each may add expect, as and cleanup) "
                    + "and takes only preview, expected_version, because, then_say and with beside it. Nothing was run.",
                    remedy: "correct_arguments", "Use try_instead's actions call, or its declared shape with your supplied values.",
                    next: advice.objectValue, extra: ["try_instead": advice])
            }
            return try await doorMany(list, base: beside, turn: turn, execution: execution)
        }
        if let value = input["script"], value != .null, value != .string("") {
            // One call is one thing: the gates and the plan judge it by its action, so a script never rides under one.
            guard action.isEmpty else {
                return Self.doorRefusal("action_and_script",
                    "app takes an action or a script, not both. Nothing was run.", remedy: "correct_arguments",
                    "Call app again with only the action and its args, or only the script.")
            }
            guard case .string(let script) = value else {
                return Self.doorRefusal("invalid_script", "script must be a JavaScript function body. Nothing was run.",
                    remedy: "correct_arguments", "Use script:\"return [app.files.list({path:'docs'}), app.desk.read({})];\".")
            }
            return Self.previewApproval(await doorScript(script, input: input, surface: surface, turn: turn, execution: execution),
                preview: input["preview"] == .bool(true))
        }
        route.input = input
        return nil
    }
    /// An action: a screen name opened as its item, a scalar list fanned out, or the action itself run.
    @MainActor
    private func doorRouteAction(_ route: AppDoorRoute) async throws -> JSONValue? {
        let input = route.input, action = route.action, resolvedAction = route.resolvedAction, workspace = route.workspace
        let root = route.root, scope = route.scope, surface = route.surface, inProcess = route.inProcess, turn = route.turn
        let execution = route.execution
        // A screen name given as an action opens the same item its DO list names.
        if !action.isEmpty, resolvedAction == nil,
           input[Self.doorScriptKey] != .bool(true),
           await AgentScreen.classify(workspace: workspace, action, dataRoot: root, scope: scope) != .unknown {
            var item = input.filter { !["action", "page", "item"].contains($0.key) }
            item["item"] = .string(action)
            return try await runAppDoor(input: item, surface: surface, inProcess: inProcess, turn: turn, execution: execution)
        }
        // Scalar-list fan-out is allowed only for reads or folded tools whose gates judge each element; other changes require actions.
        // The list is found after the action's argument names bind, as preview finds it, so `item:[…]` fans out live as it does there.
        if let target = resolvedAction?.action, let bound = execution.invocation[BoundDoorAction.self],
           bound.requested == input["action"]?.stringValue, let (key, values) = bound.plural, case .object(let args)? = input["args"],
           target.isFold || target.readOnly(args: args),
           let current = Self.doorPlural(target, args, discovery: resolvedAction?.discovery ?? [:]), current.0 == key, current.1 == values {
            TurnTraceBus.fireFromContext(kind: "shim.fired", payload: .object(["id": .string("T17"), "site": .string(
                "AppToolExecutor+AppDoor.swift:runAppDoor")]), turn: turn)
            return try await doorMany(values.map { .object(["args": .object(args.merging([key: $0]) { $1 })]) },
                                      base: input.filter { $0.key != "args" }, turn: turn, execution: execution)
        }
        if !action.isEmpty {
            var value = try await doorDo(action, resolved: resolvedAction, input: input, surface: surface, inProcess: inProcess, turn: turn,
                execution: execution)
            if let action = resolvedAction?.action, case .object(var fields) = value {
                if fields["execution"] == nil { fields["execution"] = .string("not_run") }
                var metadata = action.effectFields(args: input["args"]?.objectValue ?? [:], result: fields)
                if fields["execution"] == .string("not_run") { metadata["effect"] = .string("none") }
                fields.merge(metadata) { current, _ in current }
                value = .object(fields)
            }
            return Self.previewApproval(value, preview: input["preview"] == .bool(true))
        }
        return nil
    }
    /// A read: find, a guide, a home item or the index, a sense, or a page and its item.
    @MainActor
    private func doorRoutePage(_ route: AppDoorRoute) async throws -> JSONValue {
        let input = route.input, workspace = route.workspace, root = route.root, scope = route.scope
        let surface = route.surface, inProcess = route.inProcess, turn = route.turn, execution = route.execution
        let find = JSONValue.trimmedScalarTextOrEmpty(input["find"])
        let page = JSONValue.trimmedScalarTextOrEmpty(input["page"])
        var item = JSONValue.trimmedScalarTextOrEmpty(input["item"])
        let pageOwner = await doorPage(page)
        if !page.isEmpty, item.isEmpty, pageOwner == nil, let correction = try await Self.doorActionCorrection(page, input: input, turn: turn) {
            return correction
        }
        // A guide names its action, and the action its page: guide:<id> reads with or without page, and from a page that is not the action's own (a room,
        // Senses) it reads from the action's.
        if item.hasPrefix("guide:"), page.isEmpty || pageOwner == nil,
           let named = (try await AppActions.resolvedAction(String(item.dropFirst("guide:".count)), dataRoot: root, turn: turn))?.action, named.page != "*" {
            var call = input
            call["page"] = .string(named.page)
            call["item"] = .string("guide:" + named.id)
            return try await runAppDoor(input: call, surface: surface, inProcess: inProcess, turn: turn, execution: execution)
        }
        if page.isEmpty, !item.isEmpty, let correction = try await Self.doorActionCorrection(item, input: input, turn: turn) {
            return correction
        }
        // An item with no page is a name or ref from home or one of its rooms.
        let homeItem = Self.opensHomeItem(input)
        // A script reads pages; it never opens an item anywhere but a real page.
        if input[Self.doorScriptKey] == .bool(true), input["item"].map({ $0 != .null }) == true,
           homeItem || pageOwner == nil {
            return Self.doorRefusal("action_required",
                "A script opens an item only on a real page; a home item can send or change something. Nothing was read or done.",
                remedy: "none", "Call the item's named action through app instead.")
        }
        // A home item does what its name says at once: there is nothing to preview, and no page version guards it.
        if homeItem, input["preview"] == .bool(true) || !JSONValue.trimmedScalarTextOrEmpty(input["expected_version"]).isEmpty {
            if item.lowercased().hasSuffix(".say") {
                var args: [String: JSONValue]
                switch input["args"] {
                case .object(let supplied)?: args = supplied
                case nil, .null?: args = [:]
                default:
                    return Self.doorRefusal("invalid_args", "Message arguments must be an object. Nothing was sent.",
                        remedy: "correct_arguments", "Use agent.message with its named arguments and preview:true.")
                }
                args["agent"] = .string(String(item.dropLast(4)))
                return Self.doorRefusal("item_not_previewable",
                    "Use agent.message to preview an agent message. Nothing was sent.",
                    remedy: "correct_route", "Make next_call with the message text and preview:true.",
                    next: ["action": .string("agent.message"), "args": .object(args), "preview": .bool(true)])
            }
            return Self.doorRefusal("item_not_previewable",
                "A home item opens or does what its name says at once; it takes no preview or expected_version. Nothing was read or done.",
                remedy: "correct_arguments",
                "Call app {item} again without preview or expected_version; open its room first to see what it does.")
        }
        if !find.isEmpty { return try await doorFind(find, turn: turn) }
        if turn.doorPreview != nil, page.isEmpty || page.lowercased() == "home" || SenseCorner(key: page) != nil {
            return Self.previewPage(page, item: item)
        }
        if homeItem || page.lowercased() == "home" {
            if input[Self.doorScriptKey] != .bool(true), !scope.isEmpty {
                try await AgentWorkspaceNavigation.shared.rememberDoorPage(nil, dataRoot: root, scope: scope)
            }
            var call: [String: JSONValue] = [:]
            if !item.isEmpty { call["action"] = .string(item) }
            if case .object(let args)? = input["args"] {
                if let stray = args.keys.sorted().first(where: { !["text", "fields", "conversation", "expects_reply"].contains($0) }) {
                    return Self.failure("unknown_arg",
                        "A home item takes text, or an agent conversation label and expects_reply in args, not \(stray). Nothing was read or done.",
                        extra: ["argument_path": .string("args.\(stray)"), "remedy": .object(["kind": .string("correct_arguments"), "instruction": .string("""
                            Call app again with args {text, conversation?, expects_reply?} for an agent message, or none. Use an app action for named fields.
                            """), "next_call": .null])])
                }
                for (key, value) in args where value != .null { call[key] = value }
            }
            return await doorHome(call, turn: turn, execution: execution)
        }
        if page.isEmpty {
            if input[Self.doorScriptKey] != .bool(true), !scope.isEmpty {
                try await AgentWorkspaceNavigation.shared.rememberDoorPage(nil, dataRoot: root, scope: scope)
            }
            return try await doorIndex(turn: turn, execution: execution)
        }
        if let corner = SenseCorner(key: page), let result = try await doorSenseRead(corner: corner, item: item, input: input, turn: turn,
            execution: execution) {
            return result
        }
        guard let resolved = pageOwner else {
            let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
            let scope = input["__session_id"]?.scalarText ?? turn.verifiedSessionID ?? ""
            let kind = await AgentScreen.classify(workspace: workspace, page, dataRoot: root, scope: scope)
            if kind != .unknown {
                // A page read may open a room or record, never invoke its effect verbs.
                let name = item.isEmpty ? page : item
                let itemKind = item.isEmpty ? kind : await AgentScreen.classify(workspace: workspace, item,
                    dataRoot: root, scope: scope)
                if kind == .read, itemKind == .read {
                    var call = input
                    call["page"] = .string("home")
                    call["item"] = .string(name)
                    return AgentWorkspace.resolvedRead(try await runAppDoor(input: call, surface: surface, inProcess: inProcess, turn: turn,
                        execution: execution),
                                             as: "home." + name)
                }
                return Self.doorRefusal("item_action", "That home name acts; a page only reads.", remedy: "open_item",
                    "Use item to invoke it explicitly.", next: ["item": .string(name)])
            }
            if item.isEmpty,
               let shown = try await doorShownName(page, input: input, surface: surface, inProcess: inProcess, turn: turn, execution: execution) {
                return shown
            }
            return Self.doorRefusal("unknown_page", "No page is called that, and no page shows a row by that name.", remedy: "read_index",
                "Read {} for the pages; a page's own row opens with app {page:\"<page>\", item:\"<row>\"}. Nothing was done.", next: [:],
                extra: ["requested": .string(page), "pages": .array(try await doorPages.map { .string($0.id) })])
        }
        if let refused = Self.doorPageArgsRefusal(input, resolved: resolved, item: item) { return refused }
        return try await doorRoutePageRead(route, page: page, item: item, resolved: resolved)
    }
    /// A page read takes args only where the page pages (offset) or bounds a conversation (limit).
    @MainActor
    private static func doorPageArgsRefusal(_ input: [String: JSONValue], resolved: QuietToolPage, item: String) -> JSONValue? {
        switch input["args"] {
        case .object(let args)?:
            let acceptsLimit = resolved.id == "chat" && !item.isEmpty && item != "actions" && !item.hasPrefix("guide:")
            let acceptsOffset = (resolved.id == "tools" || resolved.id == "make" && item.isEmpty)
                && item != "census" && item != "actions" && !item.hasPrefix("guide:")
            let allowed = Set((acceptsLimit ? ["limit"] : []) + (acceptsOffset ? ["offset"] : []))
            if let stray = args.keys.sorted().first(where: { !allowed.contains($0) }) {
                // Single-subject pages use item so the scope remains explicit.
                let subject = ["context": "conversation id", "agent_view": "room"][resolved.id]
                let named: String = { if case .string(let v)? = args[stray] { return v }; return item }()
                return Self.doorRefusal("unknown_arg", "A \(resolved.id) page read does not accept args.\(stray). Nothing was read.",
                    remedy: "correct_arguments", acceptsOffset ? "Pass args.offset (a nonnegative integer) to continue this \(resolved.title) read."
                        : acceptsLimit ? "Remove that argument; this conversation read accepts only args.limit (integer)."
                        : subject.map { "Name the \($0) as item: {page: \"\(resolved.id)\", item: \"<\($0)>\"}; without item it reads the one on screen." }
                        ?? "Read the page without args. Use find for action arguments.",
                    next: ["page": .string(resolved.id), "item": .string(subject == nil ? item : named),
                           "args": .object(args.filter { allowed.contains($0.key) })],
                    extra: ["argument_path": .string("args.\(stray)")])
            }
            if let offset = args["offset"] {
                guard case .int(let n) = offset, n >= 0 else {
                    return Self.doorRefusal("bad_input", "args.offset must be a nonnegative integer. Nothing was read.",
                        remedy: "correct_arguments", "Pass the next_offset from this \(resolved.title) read.", extra: ["argument_path": .string("args.offset")])
                }
            }
            if let limit = args["limit"], limit != .null,
               let problem = limit.schemaProblem(schema: .object(["type": .string("integer")]), path: "args.limit") {
                return Self.doorRefusal("bad_input", "\(problem.words). Nothing was read.",
                    remedy: "correct_arguments", "Pass an integer limit for this conversation read.",
                    extra: ["argument_path": .string(problem.path)])
            }
        case nil, .null?: break
        default:
            return Self.doorRefusal("invalid_args", "Page args must be an object. Nothing was read.",
                remedy: "correct_arguments", "Omit args, or pass only arguments this page read accepts.",
                extra: ["argument_path": .string("args")])
        }
        return nil
    }
    /// The page's read, with what the agent needs beside it: its version, item reads, this conversation and its actions.
    @MainActor
    private func doorRoutePageRead(_ route: AppDoorRoute, page: String, item: String, resolved: QuietToolPage) async throws -> JSONValue {
        let input = route.input, root = route.root, scope = route.scope
        let surface = route.surface, turn = route.turn, execution = route.execution
        if item == "actions" { return try await doorReadActionCatalog(resolved, asked: page, root: root, turn: turn) }
        let offset: Int64 = if case .int(let value)? = input["args"]?.objectValue?["offset"] { value } else { 0 }
        let result = Self.doorItemRead(try await doorRead(page: resolved, item: item, offset: Int(offset), surface: surface,
            turn: turn, execution: execution), page: resolved, item: item)
        guard case .object(var read) = result, read["status"] == .string("ok") || read["status"] == .string("partial") else { return result }
        if resolved.id == "tools", item != "census" {
            read["stopped_run_ids"] = .array(try await Self.doorStoreRead { try PartRunStore.waitingIDs(root: root).map(JSONValue.string) })
            read["resume_note"] = .string("""
                stopped_run_ids are saved targets for ability.resume; an empty list means none. Resume rechecks the seal, the ability and replayed reads.
                """)
        }
        if turn.doorPreview == nil, input[Self.doorScriptKey] != .bool(true), !scope.isEmpty {
            try await AgentWorkspaceNavigation.shared.rememberDoorPage(resolved.id, dataRoot: root, scope: scope)
        }
        // A row that opens another place read that place (`doorOpened`): its version and `resolved` already name it.
        read["version"] = try read["version"] ?? .string(Self.doorVersion(asked: resolved.id, item: item, read))
        if page != resolved.id, read["resolved"] == nil { read["resolved"] = .string(resolved.id) }
        if item.isEmpty, let items = Self.doorItemReads[resolved.id] {
            read["item_reads"] = .array(items.sorted { $0.key < $1.key }.map { .string("\($0.key): \($0.value)") })
        }
        // Conversation messages and reply eligibility stay outside the version because the agent's own turn moves them.
        if resolved.id == "chat", case .object(let composer)? = read["item"],
           let id = composer["conversation"]?.scalarText {
            let args: [String: JSONValue] = if case .object(let given)? = input["args"] { given } else { [:] }
            read["conversation"] = await ConversationReader.open(turn: turn, id: id,
                limit: args["limit"]?.scalarText.flatMap { Int($0) },
                dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot())
        }
        // This chat means the request's origin, which may differ from the visible conversation.
        if resolved.id == "chat", item.isEmpty, let asking = turn.verifiedSessionID, !asking.isEmpty {
            let onScreen: String? = if case .object(let composer)? = read["item"] { composer["conversation"]?.scalarText } else { nil }
            if onScreen != asking {
                read["this_conversation"] = .object(["session_id": .string(asking),
                    "note": .string("""
                        The conversation this request came from. \"This chat\" means this one; omit session_id or pass this id. Other conversations here are \
                        what the owner has on screen.
                        """)])
            }
        }
        let hasSettings = if case .array(let rows)? = read["settings"] { !rows.isEmpty } else { false }
        let actions = try await Self.doorPageActions(resolved.id, hasSettings: hasSettings, dataRoot: root, turn: turn)
        if !actions.isEmpty {
            read["page_actions"] = .object([
                "ids": .array(actions.map { .string($0.id) }),
                "read": .object(["page": .string(resolved.id), "item": .string("actions")]),
            ])
        }
        Self.addDoorPageGuides(actions, page: resolved.id, to: &read)
        return Self.pageReadResult(page: resolved.id, fields: read)
    }

    @MainActor
    private func doorReadActionCatalog(_ page: QuietToolPage, asked: String, root: URL, turn: Turn) async throws -> JSONValue {
        var read: [String: JSONValue] = ["status": .string("ok"), "title": .string(page.title), "item": .string("actions")]
        if asked != page.id { read["resolved"] = .string(page.id) }
        let hasSettings: Bool
        do {
            hasSettings = try !QuietSettings.settings(forPage: page.id, host: quietHost()).isEmpty
        } catch {
            hasSettings = false
            read["status"] = .string("partial")
            read["settings_catalog"] = ChatToolOutcome.failure(error: error, tool: "app", effects: ToolFailureError.Effects.none)
        }
        let actions = try await Self.doorPageActions(page.id, hasSettings: hasSettings, dataRoot: root, turn: turn)
        read["actions"] = .array(actions.map { .string($0.line) })
        read["preview_examples"] = .array(try actions.filter { $0.irreversible && $0.page != "*" }.prefix(1).compactMap {
            if case .object(let discovery) = try AppActions.discovery($0) { discovery["example"] } else { nil }
        })
        Self.addDoorPageGuides(actions, page: page.id, to: &read)
        return Self.pageReadResult(page: page.id, fields: read)
    }

    private static func addDoorPageGuides(_ actions: [AppAction], page: String, to read: inout [String: JSONValue]) {
        // The full Mac act guide is an explicit item read; other argument rules ride schemas and refusals.
        let guides = actions.filter { $0.id == "mac.act" }
        if !guides.isEmpty {
            read["guide_reads"] = .object(Dictionary(uniqueKeysWithValues: guides.map {
                ($0.id, .object(["page": .string(page), "item": .string("guide:" + $0.id)]))
            }))
            read["guide_note"] = .string(guides.map {
                """
                    Only before \($0.id) actions, read app {page:\"\(page)\", item:\"guide:\($0.id)\"}. Plain reads (mac.look, mac.system_info, \
                    mac.volume with no args) need no guide.
                    """
            }.joined(separator: " "))
        }
    }
}
/// One app call on its way to its route: what it asks, as each route before it left it, and where it was asked from.
private final class AppDoorRoute {
    var input: [String: JSONValue]
    let action: String
    let resolvedAction: (action: AppAction, discovery: [String: JSONValue])?
    let workspace: WorkspaceOperation
    let root: URL
    let scope: String
    let surface: String
    let inProcess: Bool
    let turn: Turn
    let execution: AppActionExecution
    init(input: [String: JSONValue], action: String, resolvedAction: (action: AppAction, discovery: [String: JSONValue])?,
         workspace: WorkspaceOperation, root: URL, scope: String, surface: String, inProcess: Bool, turn: Turn, execution: AppActionExecution) {
        self.input = input
        self.action = action
        self.resolvedAction = resolvedAction
        self.workspace = workspace
        self.root = root
        self.scope = scope
        self.surface = surface
        self.inProcess = inProcess
        self.turn = turn
        self.execution = execution
    }
}
/// Preview shares execution checks and refuses invalid/user-only calls before any card can be filed.
extension AppToolExecutor {
    // Argument validation uses preflight, never an owner's model call.
    func argumentRefusal(tool: String, input: [String: JSONValue], turn: Turn, execution: AppActionExecution) async -> JSONValue? {
        guard tool == "app", input["preview"] != .bool(true), input["action"] != nil else { return nil }
        var preview = input
        preview["preview"] = .bool(true)
        let result: JSONValue
        do {
            var preflight = execution
            preflight.argumentPreflightOnly = true
            result = try await runAppDoor(input: preview, surface: "chat", inProcess: true, turn: turn, execution: preflight)
        } catch { return ChatToolOutcome.failure(error: error, tool: "app", effects: ToolFailureError.Effects.none) }
        let reply = ToolResult(result)
        guard case .object(var fields) = reply.payload else {
            return ChatToolOutcome.failure(error: ToolFailureError("""
                Argument preflight returned no structured result. Repair the action contract before running it.
                """, effects: .none, code: "argument_preflight_failed"), tool: "app")
        }
        if case .string(let code)? = fields["would_refuse"] {
            fields["reason"] = .string(code)
            // The detail is the owner's own words, without the preview's "Would refuse: <code>." and "Nothing was done." around them.
            var words = JSONValue.trimmedScalarTextOrEmpty(fields["detail"])
            for prefix in ["Would refuse: \(code). ", "Would refuse: "] where words.hasPrefix(prefix) {
                words.removeFirst(prefix.count)
                break
            }
            if words.hasSuffix(" Nothing was done.") { words.removeLast(" Nothing was done.".count) }
            if !words.isEmpty { fields["detail"] = .string(words) }
            return Self.liveRefusal(fields)
        }
        // Keep the exact failed spelling; reply.status also accepts state and normalized spellings.
        return reply.outcome == .refused || fields["status"] == .string("failed")
            ? Self.liveRefusal(fields) : nil
    }

    /// A live call refused here was refused before any card: its receipt reads as that refusal (nothing ran, nothing raised), never as the
    /// preview its checks ran in.
    private static func liveRefusal(_ preview: [String: JSONValue]) -> JSONValue {
        ChatToolOutcome.refusedBeforeRunning(owner: .object(preview.filter {
            !$0.key.hasPrefix("would_") && !["preview_scope", "checks_not_run", "approver"].contains($0.key)
        }))
    }
}
