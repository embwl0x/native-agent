import Foundation
import Observation
// Blueprint: | `FacePageSession.swift` | Door-held edits, document demands and subject-owned operations above disposable rows |

public struct FaceItemID: Hashable, Sendable {
    public let section: String
    public let row: String
    public init(section: String, row: String) { self.section = section; self.row = row }
}

enum FaceFocus: Hashable {
    case row(FaceItemID), control(FaceItemID), action(FaceItemID, String), actionMenu(FaceItemID), filter
    var item: FaceItemID? {
        switch self {
        case .row(let item), .control(let item), .action(let item, _), .actionMenu(let item): item
        case .filter: nil
        }
    }
}

@MainActor @Observable public final class FacePageSession {
    public let drafts = FaceEditDrafts()
    public let documents = FaceDocumentReads()
    public let collections = FaceCollectionReads()
    public let children = FacePageSessions()
    public var scrollAnchor: FaceItemID?
    var unfolded: Set<String> = []
    var expanded: Set<FaceItemID> = []
    public var selection: FaceItemID?
    var filter = ""
    var showsFilter = false
    public struct Operation {
        public let submission: FaceActSubmission
        public let item: FaceItemID
        public var outcome: FaceActOutcome?
        public var cancelling = false
        public var checking = false
        fileprivate var editRevision: UUID?
        fileprivate var formEdits: [String: (key: String, revision: UUID?)] = [:]
        fileprivate var task: Task<Void, Never>?
    }
    /// A page owner's row is the act's subject wherever that row is drawn.
    public private(set) var operations: [String: Operation] = [:]
    private(set) var refusals: [String: WireFailure] = [:]
    public internal(set) var formErrors: [String: [String: String]] = [:]
    private var viewers: Set<UUID> = []
    var released: (() -> Void)?

    public init() {}

    /// Native leaves use the same held query and row vocabulary as the surrounding collection.
    public func matchesFilter(_ row: PartFace.Row) -> Bool {
        filter.isEmpty || row.descendants.contains { child in
            [child.title, child.detail ?? "", child.value ?? ""].joined(separator: " ")
                .localizedCaseInsensitiveContains(filter)
        }
    }

    func visibleRows(_ section: PartFace.Section) -> [(row: PartFace.Row, depth: Int)] {
        func flatten(_ rows: [PartFace.Row], depth: Int) -> [(row: PartFace.Row, depth: Int)] {
            rows.flatMap { row in
                [(row, depth)] + (expanded.contains(.init(section: section.id, row: row.id)) ? flatten(row.rows ?? [], depth: depth + 1) : [])
            }
        }
        guard section.folded != true || unfolded.contains(section.id) else { return [] }
        return flatten(section.rows, depth: 0)
    }

    public func attach(_ viewer: UUID) { viewers.insert(viewer) }
    public func detach(_ viewer: UUID) { viewers.remove(viewer); releaseIfIdle() }
    var retained: Bool {
        !viewers.isEmpty || drafts.hasEdits || operations.values.contains {
            $0.checking || $0.outcome == nil || $0.outcome?.unresolved == true
        }
    }
    private func releaseIfIdle() { if !retained { released?() } }

    func held(_ item: FaceItemID) -> Bool {
        guard let operation = operations[item.row] else { return false }
        return operation.checking || operation.outcome == nil || operation.outcome?.unresolved == true
    }

    public func submit(_ item: FaceItemID, row: String, action: String, value: String?, call: PartFace.Call?, door: any FaceDoor,
                undoOf: UUID? = nil, values: [String: PartFace.Value]? = nil, formRevision: String? = nil,
                formEdits: [String: String] = [:]) {
        guard !held(item) else { return }
        let subject = item.row
        guard let call else {
            let failure = WireFailure(code: "drawn_call_missing", message: "Read the page again; this action has no drawn call.",
                                      cause: nil, effects: .none)
            refusals[subject] = failure
            return
        }
        refusals.removeValue(forKey: subject)
        let submission = FaceActSubmission(id: UUID(), row: row, action: action, value: value, expectedCall: call, undoOf: undoOf,
                                           values: values, formRevision: formRevision)
        if !door.answersOnRow, action != "set", values == nil { Task { _ = await door.act(submission) }; return }
        let key = draftKey(item)
        let revision = drafts.revision(key)
        let audience = viewers
        operations[subject] = Operation(submission: submission, item: item, editRevision: revision)
        operations[subject]?.formEdits = formEdits.mapValues { (key: $0, revision: drafts.revision($0)) }
        let task = Task {
            let outcome = await door.act(submission)
            settle(operation: submission.id, outcome: outcome)
            if operations[subject]?.submission.id == submission.id, outcome.accepted, outcome.failure == nil, !outcome.unresolved,
               let words = outcome.words, !words.isEmpty, !audience.isDisjoint(with: viewers) { notice?(words) }
        }
        operations[subject]?.task = task
    }

    func check(_ item: FaceItemID, door: any FaceDoor) {
        let subject = item.row
        guard let operation = operations[subject], operation.outcome?.unresolved == true, !operation.checking else { return }
        let original = operation.submission
        let read = FaceActSubmission(id: original.id, row: original.row, action: original.action, value: original.value,
                                     expectedCall: original.expectedCall, checking: true, values: original.values,
                                     formRevision: original.formRevision)
        operations[subject]?.checking = true
        operations[subject]?.cancelling = false
        let task = Task {
            let outcome = await door.act(read)
            complete(original.id, outcome: outcome, checking: true)
        }
        operations[subject]?.task = task
    }

    public var notice: ((String) -> Void)?

    /// Replies and later owner evidence settle the same held operation, including when its view has departed.
    public func settle(operation id: UUID, outcome: FaceActOutcome) {
        complete(id, outcome: outcome, checking: false)
    }

    func discardCheckResult(_ row: String) {
        guard let operation = operations[row], operation.submission.action == "test", operation.outcome != nil,
              operation.outcome?.effects == .none, operation.outcome?.unresolved == false else { return }
        operations[row] = nil
    }

    private func complete(_ id: UUID, outcome: FaceActOutcome, checking: Bool) {
        guard let subject = operations.first(where: { $0.value.submission.id == id })?.key,
              var operation = operations[subject], !checking || operation.checking else { return }
        // A late uncertain reply cannot replace an owner's already-settled evidence.
        if operation.outcome?.unresolved == false, outcome.unresolved { return }
        var outcome = outcome
        // A failed read describes that read, never proof that the earlier write had no effect.
        if checking, !outcome.accepted || outcome.unresolved {
            outcome.effects = .unknown
            outcome.committed = nil
        }
        operation.outcome = outcome
        operation.checking = false
        operation.cancelling = false
        operation.task = nil
        operations[subject] = operation
        if !outcome.unresolved, operation.submission.action == "set",
           let saved = outcome.committed?.first(where: { $0.id == "value" }), case .string(let text)? = saved.value {
            drafts.accept(draftKey(operation.item), revision: operation.editRevision, saved: text)
        }
        settleForm(subject, outcome: outcome)
        releaseIfIdle()
    }

    private func settleForm(_ subject: String, outcome: FaceActOutcome) {
        guard let operation = operations[subject], operation.submission.values != nil else { return }
        var errors: [String: String] = [:]
        for (path, words) in outcome.failure?.fields ?? [:] {
            let field = [path, path.hasPrefix("args.") ? String(path.dropFirst(5)) : path,
                         path.hasPrefix("$.") ? String(path.dropFirst(2)) : path].first { operation.formEdits[$0] != nil }
            errors[field ?? path] = words
        }
        formErrors[subject] = errors
        guard !outcome.unresolved else { return }
        for field in outcome.committed ?? [] {
            guard let edit = operation.formEdits[field.id], let value = field.value else { continue }
            drafts.accept(edit.key, revision: edit.revision, saved: value)
        }
    }

    public func cancel(_ item: FaceItemID) {
        let subject = item.row
        guard let operation = operations[subject], operation.outcome == nil || operation.checking else { return }
        operations[subject]?.cancelling = true
        operations[subject]?.task?.cancel()
    }

    func draftKey(_ item: FaceItemID) -> String { String(item.section.utf8.count) + ":" + item.section + item.row }
}

/// The native door owns sessions; a departed page stays only while it holds edits or unresolved work.
@MainActor public final class FacePageSessions {
    private var sessions: [String: FacePageSession] = [:]
    public init() {}
    public func page(_ key: String) -> FacePageSession {
        if let session = sessions[key] { return session }
        let session = FacePageSession()
        sessions[key] = session
        session.released = { [weak self, weak session] in
            guard let self, let session, self.sessions[key] === session else { return }
            self.sessions.removeValue(forKey: key)
        }
        return session
    }
}

/// Non-secret edits belong to a subject, with the baseline needed to retain edits made during a save.
@MainActor @Observable public final class FaceEditDrafts {
    private var held: [String: (value: Any, baseline: Any, revision: UUID)] = [:]
    var hasEdits: Bool { !held.isEmpty }
    func revision(_ subject: String) -> UUID? { held[subject]?.revision }
    public init() {}

    public func value<Value>(_ subject: String, seed: @autoclosure () -> Value) -> Value {
        (held[subject]?.value as? Value) ?? seed()
    }

    public func baseline<Value>(_ subject: String, seed: Value) -> Value {
        (held[subject]?.baseline as? Value) ?? seed
    }

    public func set<Value>(_ value: Value, for subject: String, baseline: Value? = nil) {
        held[subject] = (value, held[subject]?.baseline ?? baseline ?? value, UUID())
    }

    public func accept<Value: Equatable>(_ subject: String, submitted: Value, saved: Value) {
        guard let draft = held[subject] else { return }
        if (draft.value as? Value) == submitted { clear(subject) }
        else { held[subject] = (draft.value, saved, draft.revision) }
    }

    func accept(_ subject: String, revision: UUID?, saved: String) {
        guard let draft = held[subject] else { return }
        if draft.revision == revision { clear(subject) }
        else { held[subject] = (draft.value, saved, draft.revision) }
    }

    func accept(_ subject: String, revision: UUID?, saved: PartFace.Value) {
        guard let draft = held[subject] else { return }
        if draft.revision == revision { clear(subject) }
        else { held[subject] = (draft.value, saved, draft.revision) }
    }

    public func accept<Value: Codable & Equatable>(_ subject: String, submitted: Value, rebasingOn saved: Value) throws {
        guard let pending = held[subject]?.value as? Value else { return }
        if pending == submitted { clear(subject) }
        else { held[subject] = (try merging(subject, edited: pending, into: saved, baseline: submitted), saved, UUID()) }
    }

    public func merging<Value: Codable>(
        _ subject: String, edited: Value, into current: Value, baseline originalBaseline: Value? = nil
    ) throws -> Value {
        guard let original = originalBaseline ?? (held[subject]?.baseline as? Value) else { return current }
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        func fields(_ value: Value) throws -> [String: PartFace.Value] {
            try decoder.decode([String: PartFace.Value].self, from: encoder.encode(value))
        }
        let baseline = try fields(original), changes = try fields(edited)
        var merged = try fields(current)
        for key in Set(baseline.keys).union(changes.keys) where baseline[key] != changes[key] { merged[key] = changes[key] }
        return try decoder.decode(Value.self, from: encoder.encode(merged))
    }

    public func clear(_ subject: String) { held.removeValue(forKey: subject) }
}
