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
    @ObservationIgnored public var scrollAnchor: FaceItemID?
    /// A list longer than this shows its first rows and says how many more it holds.
    static let foldAfter = 8
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

    @MainActor @Observable final class RowState {
        var operation: Operation?
        var refusal: WireFailure?
        var formErrors: [String: String] = [:]
    }

    enum Fold: Hashable, Sendable {
        case section(String), more(String), row(FaceItemID)
    }
    @ObservationIgnored private var openFolds: Set<Fold> = []

    subscript(open fold: Fold) -> Bool {
        get {
            access(keyPath: \.[open: fold])
            return openFolds.contains(fold)
        }
        set {
            withMutation(keyPath: \.[open: fold]) {
                if newValue { _ = openFolds.insert(fold) } else { _ = openFolds.remove(fold) }
            }
        }
    }

    @ObservationIgnored private var rows: [String: RowState] = [:]

    subscript(row subject: String) -> RowState? {
        access(keyPath: \.[row: subject])
        return rows[subject]
    }

    func editRow(_ subject: String) -> RowState {
        if let state = rows[subject] { return state }
        let state = RowState()
        withMutation(keyPath: \.[row: subject]) { rows[subject] = state }
        return state
    }

    public func operation(for subject: String) -> Operation? { self[row: subject]?.operation }

    public var operations: [String: Operation] {
        access(keyPath: \.operations)
        return rows.compactMapValues(\.operation)
    }

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
            // A row's inline group is drawn on the row's own line, never as rows of its own beneath it; what lies beneath is `beneath`.
            rows.flatMap { row in
                let open = row.holdsBeneath && self[open: .row(.init(section: section.id, row: row.id))]
                return [(row, depth)] + (open ? flatten(row.beneath, depth: depth + 1) : [])
            }
        }
        guard section.folded != true || self[open: .section(section.id)] else { return [] }
        return flatten(Array(section.rows.prefix(section.rows.count - hiddenRows(section))), depth: 0)
    }

    /// How many of a long list's rows wait behind its "more" line. None while the person filters, once they opened it, or when the row
    /// they selected or were sent to is among them. A list is shortened once: a section that folds as a whole opens whole, so only a
    /// section that is always open keeps a "more" line.
    func hiddenRows(_ section: PartFace.Section) -> Int {
        guard filter.isEmpty, !self[open: .more(section.id)], section.folded != true, section.style != .flow, section.style != .waiting,
              section.rows.count > Self.foldAfter + 2 else { return 0 }
        if wouldHide(selection, in: section) || wouldHide(scrollAnchor, in: section) { return 0 }
        return section.rows.count - Self.foldAfter
    }

    func collapseRows(_ section: PartFace.Section) {
        if wouldHide(scrollAnchor, in: section) { scrollAnchor = nil }
        if wouldHide(selection, in: section) { selection = nil }
        self[open: .more(section.id)] = false
    }

    private func wouldHide(_ item: FaceItemID?, in section: PartFace.Section) -> Bool {
        guard let item, item.section == section.id else { return false }
        return section.rows.dropFirst(Self.foldAfter).contains { row in
            row.descendants.contains { $0.id == item.row }
        }
    }

    public func attach(_ viewer: UUID) { viewers.insert(viewer) }
    public func detach(_ viewer: UUID) { viewers.remove(viewer); releaseIfIdle() }
    var retained: Bool {
        !viewers.isEmpty || drafts.hasEdits || !openFolds.isEmpty || operations.values.contains {
            $0.checking || $0.outcome == nil || $0.outcome?.unresolved == true
        }
    }
    private func releaseIfIdle() { if !retained { released?() } }

    func held(_ item: FaceItemID) -> Bool {
        guard let operation = operation(for: item.row) else { return false }
        return operation.checking || operation.outcome == nil || operation.outcome?.unresolved == true
    }

    public func submit(_ item: FaceItemID, row: String, action: String, value: String?, call: PartFace.Call?, door: any FaceDoor,
                undoOf: UUID? = nil, values: [String: PartFace.Value]? = nil, formRevision: String? = nil,
                formEdits: [String: String] = [:]) {
        guard !held(item) else { return }
        let state = editRow(item.row)
        guard let call else {
            let failure = WireFailure(code: "drawn_call_missing", message: "Read the page again; this action has no drawn call.",
                                      cause: nil, effects: .none)
            state.refusal = failure
            return
        }
        state.refusal = nil
        let submission = FaceActSubmission(id: UUID(), row: row, action: action, value: value, expectedCall: call, undoOf: undoOf,
                                           values: values, formRevision: formRevision)
        let key = draftKey(item)
        let revision = drafts.revision(key)
        let audience = viewers
        var operation = Operation(submission: submission, item: item, editRevision: revision)
        operation.formEdits = formEdits.mapValues { (key: $0, revision: drafts.revision($0)) }
        withMutation(keyPath: \.operations) { state.operation = operation }
        let task = Task {
            let outcome = await door.act(submission)
            complete(state, id: submission.id, outcome: outcome, checking: false)
            if state.operation?.submission.id == submission.id, outcome.accepted, outcome.failure == nil, !outcome.unresolved,
               let words = outcome.words, !words.isEmpty, !audience.isDisjoint(with: viewers) { notice?(words) }
        }
        state.operation?.task = task
    }

    func check(_ item: FaceItemID, door: any FaceDoor) {
        guard let state = rows[item.row], let operation = state.operation, operation.outcome?.unresolved == true, !operation.checking else { return }
        let original = operation.submission
        let read = FaceActSubmission(id: original.id, row: original.row, action: original.action, value: original.value,
                                     expectedCall: original.expectedCall, checking: true, values: original.values,
                                     formRevision: original.formRevision)
        state.operation?.checking = true
        state.operation?.cancelling = false
        let task = Task {
            let outcome = await door.act(read)
            complete(state, id: original.id, outcome: outcome, checking: true)
        }
        state.operation?.task = task
    }

    public var notice: ((String) -> Void)?

    /// Replies and later owner evidence settle the same held operation, including when its view has departed.
    public func settle(operation id: UUID, outcome: FaceActOutcome) {
        guard let state = rows.values.first(where: { $0.operation?.submission.id == id }) else { return }
        complete(state, id: id, outcome: outcome, checking: false)
    }

    func discardCheckResult(_ row: String) {
        guard let state = rows[row], let operation = state.operation, operation.submission.action == "test", operation.outcome != nil,
              operation.outcome?.effects == .none, operation.outcome?.unresolved == false else { return }
        state.operation = nil
    }

    private func complete(_ state: RowState, id: UUID, outcome: FaceActOutcome, checking: Bool) {
        guard var operation = state.operation, operation.submission.id == id, !checking || operation.checking else { return }
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
        state.operation = operation
        if !outcome.unresolved, operation.submission.action == "set",
           let saved = outcome.committed?.first(where: { $0.id == "value" }), case .string(let text)? = saved.value {
            drafts.accept(draftKey(operation.item), revision: operation.editRevision, saved: text)
        }
        settleForm(state, outcome: outcome)
        releaseIfIdle()
    }

    private func settleForm(_ state: RowState, outcome: FaceActOutcome) {
        guard let operation = state.operation, operation.submission.values != nil else { return }
        var errors: [String: String] = [:]
        for (path, words) in outcome.failure?.fields ?? [:] {
            let field = [path, path.hasPrefix("args.") ? String(path.dropFirst(5)) : path,
                         path.hasPrefix("$.") ? String(path.dropFirst(2)) : path].first { operation.formEdits[$0] != nil }
            errors[field ?? path] = words
        }
        state.formErrors = errors
        guard !outcome.unresolved else { return }
        for field in outcome.committed ?? [] {
            guard let edit = operation.formEdits[field.id], let value = field.value else { continue }
            drafts.accept(edit.key, revision: edit.revision, saved: value)
        }
    }

    public func cancel(_ item: FaceItemID) {
        guard let state = rows[item.row], let operation = state.operation, operation.outcome == nil || operation.checking else { return }
        state.operation?.cancelling = true
        state.operation?.task?.cancel()
    }

    func draftKey(_ item: FaceItemID) -> String { String(item.section.utf8.count) + ":" + item.section + item.row }
}

/// The native door owns sessions; a departed page stays only while it holds edits or unresolved work.
@MainActor public final class FacePageSessions {
    private var sessions: [String: FacePageSession] = [:]
    public var defaultNotice: ((String) -> Void)? {
        didSet {
            for session in sessions.values {
                session.notice = defaultNotice
                session.children.defaultNotice = defaultNotice
            }
        }
    }
    public init() {}
    public func page(_ key: String) -> FacePageSession {
        if let session = sessions[key] { return session }
        let session = FacePageSession()
        session.notice = defaultNotice
        session.children.defaultNotice = defaultNotice
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
    @MainActor @Observable fileprivate final class DraftCell {
        var edit: (value: Any, baseline: Any, revision: UUID)

        init(value: Any, baseline: Any) { edit = (value, baseline, UUID()) }
    }

    @ObservationIgnored private var cells: [String: DraftCell] = [:]

    private subscript(_ subject: String) -> DraftCell? {
        get {
            access(keyPath: \.[subject])
            return cells[subject]
        }
        set { withMutation(keyPath: \.[subject]) { cells[subject] = newValue } }
    }

    var hasEdits: Bool { !cells.isEmpty }
    func revision(_ subject: String) -> UUID? { self[subject]?.edit.revision }
    public init() {}

    public func value<Value>(_ subject: String, seed: @autoclosure () -> Value) -> Value {
        (self[subject]?.edit.value as? Value) ?? seed()
    }

    public func baseline<Value>(_ subject: String, seed: Value) -> Value {
        (self[subject]?.edit.baseline as? Value) ?? seed
    }

    public func set<Value>(_ value: Value, for subject: String, baseline: Value? = nil) {
        if let cell = cells[subject] {
            cell.edit = (value, cell.edit.baseline, UUID())
        } else {
            self[subject] = DraftCell(value: value, baseline: baseline ?? value)
        }
    }

    public func accept<Value: Equatable>(_ subject: String, submitted: Value, saved: Value) {
        guard let cell = cells[subject] else { return }
        let draft = cell.edit
        if (draft.value as? Value) == submitted { clear(subject) }
        else { cell.edit = (draft.value, saved, draft.revision) }
    }

    func accept<Value>(_ subject: String, revision: UUID?, saved: Value) {
        guard let cell = cells[subject] else { return }
        let draft = cell.edit
        if draft.revision == revision { clear(subject) }
        else { cell.edit = (draft.value, saved, draft.revision) }
    }

    public func accept<Value: Codable & Equatable>(_ subject: String, submitted: Value, rebasingOn saved: Value) throws {
        guard let cell = cells[subject], let pending = cell.edit.value as? Value else { return }
        if pending == submitted { clear(subject) }
        else { cell.edit = (try merging(subject, edited: pending, into: saved, baseline: submitted), saved, UUID()) }
    }

    public func merging<Value: Codable>(
        _ subject: String, edited: Value, into current: Value, baseline originalBaseline: Value? = nil
    ) throws -> Value {
        guard let original = originalBaseline ?? (self[subject]?.edit.baseline as? Value) else { return current }
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        func fields(_ value: Value) throws -> [String: PartFace.Value] {
            try decoder.decode([String: PartFace.Value].self, from: encoder.encode(value))
        }
        let baseline = try fields(original), changes = try fields(edited)
        var merged = try fields(current)
        for key in Set(baseline.keys).union(changes.keys) where baseline[key] != changes[key] { merged[key] = changes[key] }
        return try decoder.decode(Value.self, from: encoder.encode(merged))
    }

    public func clear(_ subject: String) { if cells[subject] != nil { self[subject] = nil } }
}
