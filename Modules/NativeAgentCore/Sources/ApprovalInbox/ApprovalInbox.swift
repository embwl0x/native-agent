import AuthoredCapabilities
import Experiences
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TrustCenter
// Blueprint: | `ApprovalInbox.swift` | Checked approval authority; its decision experience is born as a matter with its doors, then only appended |


// MARK: - Errors

public enum ApprovalInboxError: Error, Equatable, LocalizedError {
    case notFound(String)
    case alreadyResolved(id: String, status: String)
    case malformedResponse(String)
    case unavailable(underlying: String)
    case resolutionNotAuthorized(id: String, reason: String)
    case queueFull(pending: Int, cap: Int)

    public var errorDescription: String? {
        switch self {
        case .notFound(let id): "Approval \(id) was not found. Refresh the request before continuing."
        case .alreadyResolved(let id, let status): "Approval \(id) is already \(status)."
        case .malformedResponse(let detail): "Approval storage is malformed: \(detail). Repair the retained approval store before continuing."
        case .unavailable(let detail): "Approval storage is unavailable: \(detail). Restore access to the approval store before continuing."
        case .resolutionNotAuthorized(_, let reason): reason
        case .queueFull(let pending,
            let cap): "Approval queue is full (\(pending) retained requests, limit \(cap)). Settle outstanding requests before filing another."
        }
    }
}

public extension SwiftNativeApprovalInbox {
    /// Local decision convenience. Remote adapters must use the typed provenance overload and cannot enter through this label.
    @discardableResult
    func resolve(
        _ id: String,
        decision: ApprovalDecision,
        decidedBy: String
    ) async throws -> ApprovalRecord {
        try await resolve(
            id,
            decision: decision,
            provenance: .local(decidedBy: decidedBy)
        )
    }
}
/// PersistenceCore supplies atomic private storage; every inbox instance shares its file lock.
public actor SwiftNativeApprovalInbox {
    // Module visibility lets injection spends use the same root and persistence owner.
    let root: URL
    /// These actions retain local-only flags regardless of caller input. Paired iPhone and bound owner-DM decisions follow `validateResolutionAuthority`;
    /// executable review still requires Mac/phone.
    nonisolated static let hardLocalOnlyActions: Set<String> = [
        "agent.acp.permission",
        "backup_restore",
        "memory.update",
        "memory.delete",
        "memory.proposal.approve",
        "memory.proposal.reject",
        "improvement.promote",
        "improvement.revert",
        "autonomy.promote",
    ]
    /// Owner reviews allow paired-phone and bound owner-DM decisions, except executable reviews. `validateResolutionAuthority` owns that rule.
    public nonisolated static let ownerReviewActions: Set<String> = [
        "rem.proposal",
        "care.life",
        "memory.kind_backfill",
        SwiftNativeApprovalInbox.skillScriptInstallAction,
    ]
    public init(root: URL) {
        self.root = root
    }
    public nonisolated var approvalsPath: URL { Self.approvalsPath(root: root) }
    /// Pending requests, read-only and without the lock, for a glance that must not wait; a file caught mid-write fails its check and throws.
    public nonisolated func pendingUnlocked() throws -> [ApprovalRecord] {
        try recordsUnlocked().filter { $0.status == "pending" }
    }
    public nonisolated func resolvedUnlocked() throws -> [ApprovalRecord] {
        try recordsUnlocked().filter { $0.status == "resolved" }
    }
    public nonisolated func recordsUnlocked() throws -> [ApprovalRecord] {
        try readContinuations(Self.loadApprovalRowsChecked(at: approvalsPath).compactMap(ApprovalRecord.init(json:)))
    }
    /// A conversation releases its wait only after a checked decision, and an approved action's execution receipt. Missing identity is repair work.
    public nonisolated func decisionSettledUnlocked(_ id: String) throws -> Bool {
        guard let record = try recordsUnlocked().first(where: { $0.id == id }) else {
            throw ApprovalInboxError.notFound(id)
        }
        guard record.status != "pending" else { return false }
        return record.decision != "approved" || record.executedAction != nil
    }
    public func list(filter: ApprovalFilter) async throws -> [ApprovalRecord] {
        let items = try await SwiftNativePersistenceCore.withFileLock(approvalsPath) { [approvalsPath] in
            try Self.loadApprovalRowsChecked(at: approvalsPath)
        }
        // Checked loading validates every row before compactMap can discard malformed evidence.
        let records = try readContinuations(items.compactMap(ApprovalRecord.init(json:)))
        let sorted = records.sorted { lhs, rhs in
            lhs.createdAt > rhs.createdAt
        }
        return sorted.filter { record in
            if let s = filter.status, record.status != s { return false }
            if let a = filter.action, !ExecutionEventVocabulary.matches(record.action, a) {
                return false
            }
            return true
        }
    }
    public func get(_ id: String) async throws -> ApprovalRecord {
        let records = try await list(filter: .all)
        guard let match = records.first(where: { $0.id == id }) else {
            throw ApprovalInboxError.notFound(id)
        }
        return match
    }
    @discardableResult
    public func create(_ body: JSONValue, turn: Turn?, handsBack: Bool = false) async throws -> ApprovalRecord {
        try await createOrTouchPending(body, turn: turn, handsBack: handsBack, matchesPending: { _ in false }).record
    }
    /// Matches pending payloads or creates under one lock; matches stamp `lastRequestedAt`.
    @discardableResult
    public func createOrTouchPending(
        _ body: JSONValue,
        turn: Turn?,
        handsBack: Bool = false,
        matchesPending: @escaping @Sendable (JSONValue) -> Bool
    ) async throws -> (record: ApprovalRecord, created: Bool) {
        let outcome = try await Self._createOrTouchPendingImpl(
            body: body,
            turn: turn, handsBack: handsBack,
            lifeID: try DataRootLife.current(in: root),
            matchesPending: matchesPending,
            approvalsPath: approvalsPath,
            now: Date()
        )
        if outcome.created {
            ApprovalLifecycleBus.fire(.init(phase: .requested, record: outcome.record))
        }
        // Idempotent births repair missing experience even when an existing card is touched.
        await recordFiled(outcome.record, expired: outcome.expired)
        return (outcome.record, outcome.created)
    }
    /// Recorded after the approvals lock is released. Cards this write aged out let theirs go.
    private func recordFiled(_ record: ApprovalRecord, expired: [ApprovalRecord]) async {
        await recordProjection(record).value
        for expired in expired {
            await recordProjection(expired).value
            ApprovalLifecycleBus.fire(.init(phase: .resolved, record: expired))
        }
    }
    @discardableResult
    private func recordProjection(_ record: ApprovalRecord) -> Task<Void, Never> {
        let projection = ExperienceStore.record(root, record.id) { [root] store in
            try await Self.project(record, into: store, dataRoot: root)
        }
        let settlement = Task.detached { [root] in
            await projection.value
            if record.status != "pending", record.decision == nil {
                let operation = "approval.expiry:" + record.id
                do {
                    try await ForPerson.at(root).answered(record.id, evidence: nil, letGo: .expired)
                    await RepairOwed.settle(root, operation: operation, evidence: .init(source: Matter.approvals, id: record.id)).value
                } catch {
                    await RepairOwed.owe(root, id: record.id, kind: .decision, operation: operation, owner: Matter.approvals,
                        words: "Approval expiry could not settle: " + error.localizedDescription,
                        lever: "Repair the approval's matter and refresh the approval projection.").value
                }
            }
        }
        // Later answers settle with the decision; the first rides its continuation. Without a decision, the inbox lets go of every answer it held.
        guard record.status != "pending", case .object(let payload) = record.payload else { return settlement }
        var heards: [JSONValue] = if case .array(let waiting)? = payload["waitingHeards"] { waiting } else { [] }
        if record.decision == nil, case .object(let origin)? = payload["origin"],
           case .string(let heard)? = origin["answerExperienceID"], !heards.contains(.string(heard)) {
            heards.append(.string(heard))
        }
        let settle: ExperienceStore.Change = record.decision != nil
            ? .obligation(key: "answer", phase: .accepted, evidence: .init(source: "workflows/approvals/requests.json", id: record.id))
            : .letGo(key: "answer", reason: .expired)
        for case .string(let heard) in heards {
            ExperienceStore.record(root, heard) { store in
                guard try await store.experience(heard)?.owes["answer"]?.phase.isSettled == false else { return }
                try await store.append([settle], to: heard)
            }
        }
        return settlement
    }
    /// The durable domain row is the decision's source, not its advisory copy. Reads are projections only; a failed experience write cannot hold a turn.
    public func decisionsForREM() async throws -> [String: Experience] {
        let records = try await list(filter: ApprovalFilter(action: "rem.proposal"))
        var decisions: [String: Experience] = [:]
        for record in records {
            guard case .object(let payload) = record.payload,
                  case .object(let proposal)? = payload["proposal"],
                  case .string(let id)? = proposal["id"], decisions[id] == nil else { continue }
            decisions[id] = record.decisionExperience
        }
        return decisions
    }
    private static func project(_ record: ApprovalRecord, into store: ExperienceStore, dataRoot: URL) async throws {
        let projection = record.decisionExperience
        if try await store.experience(record.id) == nil {
            var born = record.matter.born(doors: record.isAgentsOwnDecision ? [] : try record.personDoors(dataRoot: dataRoot))
            if record.isAgentsOwnDecision { born.addressedTo = [] }
            try await store.begin(born)
        }
        var changes = projection.cause.map(ExperienceStore.Change.cause)
        if let face = projection.face { changes.append(.face(face)) }
        changes += projection.claims.map(ExperienceStore.Change.claim)
        if let outcome = projection.outcome {
            changes += [.outcome(outcome), .obligation(key: "decide", phase: .accepted,
                evidence: projection.owes["decide"]?.evidence)]
        } else if projection.owes["decide"]?.phase == .letGo {
            changes.append(.letGo(key: "decide", reason: .expired))
        }
        try await store.append(changes, to: record.id)
    }
    /// Aging is the only way a capped write may drop pending work.
    static func expired(from before: [JSONValue], to after: [JSONValue]) -> [ApprovalRecord] {
        let pending = Set(after.compactMap { ApprovalRecord(json: $0) }.filter { $0.status == "pending" }.map(\.id))
        return before.compactMap { row in
            guard var record = ApprovalRecord(json: row), record.status == "pending",
                  !pending.contains(record.id) else { return nil }
            record.status = "orphaned"
            return record
        }
    }
    private static func _createOrTouchPendingImpl(
        body: JSONValue,
        turn: Turn?,
        handsBack: Bool,
        lifeID: String,
        matchesPending: @Sendable (JSONValue) -> Bool,
        approvalsPath: URL,
        now: Date
    ) async throws -> (record: ApprovalRecord, created: Bool, expired: [ApprovalRecord]) {
      return try await SwiftNativePersistenceCore.withFileLock(approvalsPath) {
        var items = try Self.loadApprovalRowsChecked(at: approvalsPath)
        let stamp = Self.isoTimestamp(now)
        for (idx, item) in items.enumerated() {
            guard case .object(var obj) = item else { continue }
            guard case .string("pending") = obj["status"] ?? .null else { continue }
            guard matchesPending(obj["payload"] ?? .object([:])) else { continue }
            obj["lastRequestedAt"] = .string(stamp)
            // Every answer waiting on this card: the first rides its origin, each later one is kept here.
            if case .object(let asked) = body, case .object(let request)? = asked["payload"],
               case .object(let origin)? = request["origin"], case .string(let heard)? = origin["answerExperienceID"],
               case .object(var payload)? = obj["payload"] {
                let first: JSONValue? = if case .object(let kept)? = payload["origin"] { kept["answerExperienceID"] } else { nil }
                var waiting: [JSONValue] = if case .array(let ids)? = payload["waitingHeards"] { ids } else { [] }
                if first != .string(heard), !waiting.contains(.string(heard)) {
                    waiting.append(.string(heard))
                    payload["waitingHeards"] = .array(waiting)
                    obj["payload"] = .object(payload)
                }
            }
            guard let touched = ApprovalRecord(json: .object(obj)) else { continue }
            items[idx] = .object(obj)
            try await SwiftNativePersistenceCore.writeJSON(.array(items), to: approvalsPath)
            return (touched, false, [])
        }
        let approval = try Self.makeApprovalRecord(body: body, now: now, turn: turn, handsBack: handsBack)
        items.insert(approval.toJSON(forStorage: true), at: 0)
        let capped = try Self.cappedEvictingTerminalRows(items, cap: Self.storedApprovalCap, now: now, lifeID: lifeID)
        try await SwiftNativePersistenceCore.writeJSON(.array(capped), to: approvalsPath)
        return (approval, true, Self.expired(from: items, to: capped))
      }
    }
    /// Resolve with a typed authority origin. Remote authorization is checked against the same row generation inside the same file lock as the write.
    @discardableResult
    public func resolve(
        _ id: String,
        decision: ApprovalDecision,
        provenance: ApprovalResolutionProvenance
    ) async throws -> ApprovalRecord {
        let lifeID = try DataRootLife.current(in: root)
        let record = try await Self._resolveImpl(
            id: id, decision: decision,
            provenance: provenance,
            lifeID: lifeID,
            approvalsPath: approvalsPath,
            now: Date()
        )
        ApprovalLifecycleBus.fire(.init(phase: .resolved, record: record))
        // The inbox holding the decision is the person's durable acceptance; the birth goes first in case this resolver got there before the filer.
        await recordProjection(record).value
        return record
    }
    /// Construct without file I/O so validation cannot file an approval.
    private static func makeApprovalRecord(body: JSONValue, now: Date, turn: Turn?, handsBack: Bool) throws -> ApprovalRecord {
        if handsBack { throw SkillRunContext.HandBack("an approval") }
        let bodyObj: [String: JSONValue]
        if case .object(let obj) = body {
            bodyObj = obj
        } else {
            bodyObj = [:]
        }
        var payload: JSONValue
        if case .object = bodyObj["payload"] ?? .null {
            payload = bodyObj["payload"] ?? .object([:])
        } else {
            payload = .object([:])
        }
        let action = codepointPrefix(pyStr(bodyObj["action"], fallback: "unknown"), 120)
        // A filer that words nothing gets its call said in words, never its serialized payload.
        let rawPayloadPreview: String
        if case .string(let s)? = bodyObj["payloadPreview"],
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rawPayloadPreview = s
        } else {
            rawPayloadPreview = ApprovalWords.call(tool: action, input: payload.objectValue?["input"] ?? payload).says
        }
        if let id = turn?.hostCallID, case .object(var fields) = payload {
            fields["hostCallID"] = .string(id.uuidString)
            payload = .object(fields)
        }
        // Every executable-code approval shows the whole staged review.
        let executableReview = Self.requiresExecutableReview(action: action)
        let previewLimit = executableReview ? Self.skillScriptPreviewLimit : 4000
        guard !executableReview || rawPayloadPreview.count <= previewLimit else {
            throw ApprovalInboxError.malformedResponse("the script is too long to show whole on the card")
        }
        let payloadPreview = String(rawPayloadPreview.prefix(previewLimit))
        // Remote resolution is authority: hard-local actions ignore caller overrides. Otherwise honor only a literal JSON Boolean; missing or malformed flags
        // default to false unless the action is remote-safe.
        let isHardLocalOnly = Self.hardLocalOnlyActions.contains(action)
        let isOwnerReview = Self.ownerReviewActions.contains(action)
        let declaredRemoteResolvable = Self.strictBool(bodyObj["remoteResolvable"])
        let remoteResolvable: Bool
        if isHardLocalOnly {
            remoteResolvable = false
        } else if isOwnerReview {
            remoteResolvable = true
        } else if let declaredRemoteResolvable {
            remoteResolvable = declaredRemoteResolvable
        } else {
            remoteResolvable = Self.remoteSafeActions.contains(action)
        }
        let localOnly: Bool
        if isHardLocalOnly {
            localOnly = true
        } else if isOwnerReview {
            localOnly = false
        } else if let declared = Self.strictBool(bodyObj["localOnly"]) {
            localOnly = declared
        } else {
            localOnly = !remoteResolvable
        }
        guard localOnly == !remoteResolvable else {
            throw ApprovalInboxError.malformedResponse(
                "approval authority fields contradict each other"
            )
        }
        let stamp = isoTimestamp(now)
        var approval = ApprovalRecord(
            id: UUID().uuidString.lowercased(),
            // A part or script that asked is named first, in the one asker form the card keeps.
            title: codepointPrefix((turn?.requester.map { $0 + ApprovalRecord.askerSeparator } ?? "")
                + strip(pyStr(bodyObj["title"], fallback: "Approval required")), 160),
            action: action,
            risk: pyStr(bodyObj["risk"], fallback: "medium"),
            reason: codepointPrefix(strip(pyStr(bodyObj["reason"], fallback: "")), 1000),
            status: "pending",
            payload: payload,
            payloadPreview: payloadPreview,
            createdAt: stamp,
            resolvedAt: nil,
            decision: nil,
            remoteResolvable: remoteResolvable,
            localOnly: localOnly
        )
        approval.cause = turn?.id
        guard !Self.strip(approval.action).isEmpty, !Self.strip(approval.title).isEmpty else {
            throw ApprovalInboxError.malformedResponse("approval title and action must be nonblank")
        }
        try Self.validateApprovalRows([approval.toJSON(forStorage: true)])
        return approval
    }
    private static func _resolveImpl(
        id: String,
        decision: ApprovalDecision,
        provenance: ApprovalResolutionProvenance,
        lifeID: String,
        approvalsPath: URL,
        now: Date
    ) async throws -> ApprovalRecord {
      return try await SwiftNativePersistenceCore.withFileLock(approvalsPath) {
        let items = try Self.loadApprovalRowsChecked(at: approvalsPath)
        var mutated: [JSONValue] = items
        var resolvedRecord: ApprovalRecord?
        for (idx, item) in items.enumerated() {
            guard case .object(var obj) = item else { continue }
            guard case .string(let recordId) = obj["id"] ?? .null, recordId == id else { continue }
            try Self.validateResolutionAuthority(provenance, row: obj, id: id)
            let currentStatus: String = {
                if case .string(let s) = obj["status"] ?? .null { return s }
                return ""
            }()
            if Self.terminalApprovalStatuses.contains(currentStatus) {
                throw ApprovalInboxError.alreadyResolved(id: id, status: currentStatus)
            }
            // All decisions share the resolved status; retain the outcome separately.
            obj["status"] = .string("resolved")
            obj["decision"] = .string(decision.rawValue)
            obj["resolvedAt"] = .string(Self.isoTimestamp(now))
            obj["decidedBy"] = .string(provenance.decidedBy)
            obj["resolutionProvenance"] = provenance.toJSON()
            obj["chatContinuation"] = .object(["lifeID": .string(lifeID)])
            if let record = ApprovalRecord(json: .object(obj)), !Self.hasChatReportingObligation(record) {
                obj["chatContinuation"] = .object([
                    "lifeID": .string(lifeID), "done": .bool(true), "settlement": .string("no_reporting")
                ])
            }
            mutated[idx] = .object(obj)
            guard let rec = ApprovalRecord(json: .object(obj)) else {
                throw ApprovalInboxError.malformedResponse("could not re-parse mutated record")
            }
            resolvedRecord = rec
            break
        }
        guard let final = resolvedRecord else {
            throw ApprovalInboxError.notFound(id)
        }
        try await SwiftNativePersistenceCore.writeJSON(.array(mutated), to: approvalsPath)
        return final
      }
    }
    @discardableResult
    public func annotateExecution(
        _ id: String,
        executedAction: JSONValue,
        detail: String,
        result: JSONValue? = nil
    ) async throws -> ApprovalRecord {
        let record = try await SwiftNativePersistenceCore.withFileLock(approvalsPath) { [approvalsPath] in
            let items = try Self.loadApprovalRowsChecked(at: approvalsPath)
            var mutated = items
            var annotated: ApprovalRecord?
            for (index, item) in items.enumerated() {
                guard case .object(var object) = item,
                      object["id"] == .string(id) else { continue }
                object["executedAction"] = executedAction
                object["detail"] = .string(detail)
                guard let record = ApprovalRecord(json: .object(object)) else {
                    throw ApprovalInboxError.malformedResponse(
                        "could not re-parse annotated approval record"
                    )
                }
                if await ApprovalLifecycleBus.shared.awaitsHostReply(record) {
                    var state: [String: JSONValue] = if case .object(let saved)? = object["chatContinuation"] { saved } else { [:] }
                    state["done"] = .bool(true)
                    state["settlement"] = .string("host_reply")
                    object["chatContinuation"] = .object(state)
                }
                mutated[index] = .object(object)
                annotated = ApprovalRecord(json: .object(object))
                break
            }
            guard let annotated else { throw ApprovalInboxError.notFound(id) }
            try await SwiftNativePersistenceCore.writeJSON(.array(mutated), to: approvalsPath)
            return annotated
        }
        guard let settled = try readContinuations([record]).first else {
            throw ApprovalInboxError.malformedResponse("approval \(record.id) has no execution continuation")
        }
        await ApprovalLifecycleBus.shared.publish(.init(phase: .executed, record: settled,
            result: result ?? executedAction))
        await recordProjection(settled).value
        return settled
    }
    /// Reporting claims survive deletable chat history and outcome healing.
    public nonisolated static func defaultDataRoot() -> URL {
        PersistenceCore.defaultDataRoot()
    }
}
