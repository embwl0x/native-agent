import Foundation
import PersistenceCore
import NativeAgentCore
import NativeAgentShared

private let nestedOpenLog = ModuleLog(category: "Receipts", trail: true)
// Blueprint: | `DeskContinuation.swift` | `DeskContinuation`; life-stamped resumable work, stopped/restored projection; receiptIsUnresolved and toJSON |

public struct DeskContinuation: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case running, ready, blocked, complete, canceled, stopped }
    /// One dispatched call. Only a redacted, bounded summary and the
    /// references a domain verifier needs are kept — never raw arguments or
    /// results, which can carry typed secrets.
    public struct Step: Codable, Sendable, Equatable {
        public var id: String
        public var tool: String
        public var input: String
        public var result: String?
        public var reference: [String: JSONValue]?
        public var owner: String?
        public var ownerID: String?
        public var requestID: String?
        public var readOnly = false
        public var runID: String?
        /// Digest of the exact call (tool and full arguments): the same effect
        /// proposed again has the same digest.
        public var effect: String?

        public init(id: String, tool: String, input: String, reference: [String: JSONValue]? = nil, effect: String? = nil) {
            self.id = id
            self.tool = tool
            self.input = input
            self.reference = reference
            self.effect = effect
        }
    }
    public var version = 1
    public var revision = UUID().uuidString
    public var lifeID: String?
    public var state: State = .running
    public var processID: String
    public var runID: String
    public var originRunID: String
    public var sessionID: String?
    public var surface: String
    public var fileAccess: String
    public var envelope: [String: JSONValue]
    public var replyRoute: [String: JSONValue]
    public var remainingWork: String
    public var settled: [Step] = []
    public var pending: [Step] = []
    public var nextRunAt: Date = Date()
    public var resumeCount = 0
    public var lastReply: String = ""
    public var reason: String?
    public var response: JSONValue?
    public var peerSources: [String]?
    public var capabilityProfile: String?
    public var commandSignatureVerified: Bool?
    public var declaredRemote: Bool?
    public var helperDefinition: JSONValue?

    public init(runID: String, sessionID: String?, surface: String,
                envelope: [String: JSONValue], replyRoute: [String: JSONValue], remainingWork: String,
                fileAccess: String, peerSources: [String]? = nil, capabilityProfile: String? = nil,
                commandSignatureVerified: Bool? = nil, declaredRemote: Bool? = nil,
                helperDefinition: JSONValue? = nil) {
        self.processID = DeskContinuationScope.processID
        self.runID = runID
        self.originRunID = runID
        self.sessionID = sessionID
        self.surface = surface
        self.fileAccess = fileAccess
        self.envelope = envelope
        self.replyRoute = replyRoute
        self.remainingWork = remainingWork
        self.peerSources = peerSources
        self.capabilityProfile = capabilityProfile
        self.commandSignatureVerified = commandSignatureVerified
        self.declaredRemote = declaredRemote
        self.helperDefinition = helperDefinition
    }

    /// True when a receipt says its effect has not reached a definite outcome:
    /// still queued or running, outcome or effects unknown, or verification
    /// unsatisfied — including inside MCP `content`/`structuredContent` and
    /// JSON text bodies. Such an effect is never settled by its own receipt.
    public static func receiptIsUnresolved(_ value: JSONValue, depth: Int = 0) -> Bool {
        guard let path = unresolvedPath(value, depth: depth, path: "") else { return false }
        // Measuring before cutting (10-29): an open child under a closed outer receipt is a producer
        // that does not own its child's evidence. Each one logged here is a producer to fix; when none
        // log, this dig becomes a read of the outer receipt alone.
        if depth == 0, path.contains("."), case .object(let outer) = value {
            let who = ["action", "tool", "verb", "kind", "source"].compactMap { outer[$0]?.scalarText }.first ?? "?"
            nestedOpenLog("receipt.nested_open who=%@ path=%@ keys=%@", who, path,
                          outer.keys.sorted().prefix(12).joined(separator: ","))
        }
        return true
    }

    /// Where a receipt says its effect is still open, as a dotted path; nil when it is settled.
    static func unresolvedPath(_ value: JSONValue, depth: Int, path: String) -> String? {
        guard depth < 8 else { return path + "(depth)" }
        switch value {
        case .array(let values):
            for (i, v) in values.enumerated() { if let p = unresolvedPath(v, depth: depth + 1, path: path + "[\(i)]") { return p } }
            return nil
        case .string(let text):
            guard text.first == "{" || text.first == "[",
                  let parsed = try? JSONValue.parse(Data(text.utf8)) else { return nil }
            return unresolvedPath(parsed, depth: depth + 1, path: path + "(json)")
        case .object(let object):
            if case .string(let status)? = object["status"],
               unresolvedStatuses.contains(status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
                return path + ".status=" + status
            }
            if object["effects"] == .string("unknown") { return path + ".effects=unknown" }
            if object["effects_unknown"] == .bool(true) { return path + ".effects_unknown" }
            if object["verified"] == .bool(false) { return path + ".verified=false" }
            if object["timed_out"] == .bool(true) { return path + ".timed_out" }
            if object["completed"] == .bool(false) { return path + ".completed=false" }
            if let verification = object["verification"], verification != .null {
                let status: JSONValue?
                if case .object(let fields) = verification { status = fields["status"] } else { status = verification }
                if ![.string("satisfied"), .string("verified"), .string("not_required")].contains(status) { return path + ".verification" }
            }
            for key in ["detail", "result", "receipt", "execution", "output", "structuredContent", "content", "text"] {
                if let child = object[key], let p = unresolvedPath(child, depth: depth + 1, path: path + "." + key) { return p }
            }
            return nil
        default:
            return nil
        }
    }

    static let unresolvedStatuses: Set<String> = [
        "queued", "running", "pending", "started", "submitted", "accepted", "scheduled", "waiting", "interrupted",
        "outcome_unknown", "delivery_unknown", "unknown", "timeout", "timed_out",
        "enqueued", "working", "input-required", "input_required", "auth-required", "auth_required",
    ]

    public func toJSON() -> JSONValue {
        do { return try JSONValue.fromEncodable(self) }
        catch { preconditionFailure("Invalid continuation encoding: \(error)") }
    }

    public static func fromJSON(_ value: JSONValue) -> Self? {
        guard let record = try? JSONDecoder().decode(Self.self, from: value.serializedData(pretty: false)),
              record.version == 1, !record.revision.isEmpty, !record.runID.isEmpty,
              !record.processID.isEmpty, !record.surface.isEmpty, !record.originRunID.isEmpty,
              !record.remainingWork.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              record.resumeCount >= 0, record.settled.count + record.pending.count <= 128,
              Set((record.settled + record.pending).map(\.id)).count == record.settled.count + record.pending.count,
              (record.settled + record.pending).allSatisfy({ !$0.id.isEmpty && !$0.tool.isEmpty }),
              record.nextRunAt.timeIntervalSince1970.isFinite,
              record.toJSON() == value else { return nil }
        return record
    }
}

public enum DeskContinuationScope {
    public static let processID = UUID().uuidString
    @TaskLocal public static var current: DeskContinuationTurn?
}

public enum DeskContinuationError: Error, LocalizedError {
    case conflict, unsafe, full, unavailable, parked
    public var errorDescription: String? {
        switch self {
        case .conflict: return "The task continuation changed owner; no work was repeated."
        case .unsafe: return "An earlier effect is unresolved. Verify it through its domain before continuing; do not repeat it."
        case .full: return "The task checkpoint is full. Automatic work is paused; inspect the retained receipts before continuing."
        case .unavailable: return "A durable task continuation requires an accepted turn and an exact reply route."
        case .parked: return "This task, or a task above it, is deferred, blocked or waiting on its owner. Nothing ran."
        }
    }
}

public actor DeskContinuationTurn {
    private let store: SwiftNativeDeskStore
    private var record: DeskContinuation
    private var handle: String?
    private var writing = false
    private var writers: [CheckedContinuation<Void, Never>] = []
    private var fenced = false
    /// Steps this process began; any other pending step lost its receipt.
    private var begun: Set<String> = []

    public init(store: SwiftNativeDeskStore, record: DeskContinuation, handle: String? = nil) {
        self.store = store
        self.record = record
        self.handle = handle
    }

    /// Steps recorded before attachment (settled and unresolved alike) move
    /// onto the task with it, so an earlier async or unknown effect stays
    /// pending for its domain verifier instead of being lost.
    public func attach(handle: String, remainingWork: String) async throws {
        await acquireWriter()
        defer { releaseWriter() }
        guard !fenced else { throw DeskContinuationError.unsafe }
        if let current = self.handle {
            guard current == handle else { throw DeskContinuationError.conflict }
            record.remainingWork = remainingWork
            try await save()
            return
        }
        guard record.settled.count + record.pending.count <= 128 else { throw DeskContinuationError.full }
        let item = try await store.liveState().items.first { $0.handle == handle }
        guard let item, !item.status.isTerminal else { throw DeskContinuationError.conflict }
        // A new life starts fresh. Within one life an unresolved effect still
        // belongs to its continuation, even after Stop.
        if let previous = item.continuation {
            guard [.complete, .canceled, .blocked, .stopped].contains(previous.state) else { throw DeskContinuationError.conflict }
            guard previous.state == .stopped || previous.pending.isEmpty else { throw DeskContinuationError.unsafe }
        }
        record.remainingWork = remainingWork
        record.revision = UUID().uuidString
        try await store.setContinuation(handle, expectedRevision: item.continuation?.revision, record: record)
        self.handle = handle
    }

    public func resume() async throws {
        await acquireWriter()
        defer { releaseWriter() }
        guard !fenced, try DataRootLife.isCurrent(record.lifeID, in: store.dataRoot) else { throw DeskContinuationError.unsafe }
        record.state = .running
        record.processID = DeskContinuationScope.processID
        try await save()
    }

    /// Returns the step as admitted: a call whose earlier run lost its receipt
    /// is admitted as that same step, so its settlement resolves it.
    @discardableResult
    public func begin(_ step: DeskContinuation.Step, peerSources: [String]) async throws -> DeskContinuation.Step {
        await acquireWriter()
        defer { releaseWriter() }
        retainPeerSources(peerSources)
        guard handle != nil else { return step }
        guard !fenced, record.state == .running else {
            throw DeskContinuationError.unsafe
        }
        guard record.settled.count + record.pending.count < 128 else {
            record.state = .blocked
            record.reason = "checkpoint_full"
            try await save()
            throw DeskContinuationError.full
        }
        var inFlight = step
        if let effect = step.effect,
           let earlier = record.pending.first(where: { !begun.contains($0.id) && $0.tool == step.tool && $0.effect == effect }) {
            inFlight.id = earlier.id
            record.pending.removeAll { $0.id == earlier.id }
        }
        begun.insert(inFlight.id)
        inFlight.owner = "turn"
        inFlight.runID = record.runID
        record.pending.append(inFlight)
        try await save(requiresActive: true)
        return inFlight
    }

    /// `settled` is true only for a definite outcome. An owner-run effect
    /// (Workshop, helper) stays pending under its reference until that
    /// domain's receipt settles it; any other unresolved step stops the
    /// continuation at the end of the turn and asks.
    public func settle(_ step: DeskContinuation.Step, result: String, settled: Bool,
                       owner: String? = nil, ownerID: String? = nil, requestID: String? = nil,
                       peerSources: [String]) async throws {
        await acquireWriter()
        defer { releaseWriter() }
        retainPeerSources(peerSources)
        guard !fenced else { throw DeskContinuationError.unsafe }
        var step = record.pending.first { $0.id == step.id } ?? step
        step.runID = record.runID
        step.result = result
        step.owner = owner
        step.ownerID = ownerID
        step.requestID = requestID
        record.pending.removeAll { $0.id == step.id }
        if settled {
            guard handle != nil || record.settled.count + record.pending.count < 128 else { return }
            record.settled.append(step)
        } else { record.pending.append(step) }
        try await save()
    }

    public func finish(state: DeskContinuation.State, reply: String, reason: String?, peerSources: [String]? = nil) async throws {
        await acquireWriter()
        defer { releaseWriter() }
        if let peerSources { retainPeerSources(peerSources) }
        guard handle != nil else { return }
        record.lastReply = reply
        if state == .canceled || record.state != .blocked {
            if state != .canceled, record.pending.contains(where: { $0.owner == nil || $0.owner == "turn" }) {
                record.state = .blocked
                record.reason = "effect_outcome_unknown"
            } else {
                record.state = state == .complete && (!record.pending.isEmpty || record.resumeCount > 0) ? .ready : state
                record.reason = reason
            }
        }
        record.nextRunAt = Date().addingTimeInterval(30)
        try await save()
    }

    public func completeResponse(_ response: JSONValue, reply: String, peerSources: [String]) async throws {
        await acquireWriter()
        defer { releaseWriter() }
        guard !fenced, handle != nil, record.resumeCount > 0, record.state == .running,
              record.pending.isEmpty else { return }
        record.response = response
        record.lastReply = reply
        retainPeerSources(peerSources)
        record.state = .ready
        record.reason = "reply_ready"
        record.nextRunAt = Date()
        try await save()
    }

    public func snapshot() async -> DeskContinuation {
        await acquireWriter()
        defer { releaseWriter() }
        return record
    }

    public func delivered() async throws {
        await acquireWriter()
        defer { releaseWriter() }
        guard record.pending.isEmpty else { throw DeskContinuationError.unsafe }
        record.state = .complete
        record.reason = "reply_delivered"
        try await save()
    }

    public func block(reason: String) async throws {
        await acquireWriter()
        defer { releaseWriter() }
        record.state = .blocked
        record.reason = reason
        try await save()
    }

    private func acquireWriter() async {
        if writing {
            await withCheckedContinuation { writers.append($0) }
        } else { writing = true }
    }

    private func retainPeerSources(_ sources: [String]) {
        var retained = record.peerSources ?? []
        for source in sources where !retained.contains(source) {
            retained.append(source)
        }
        record.peerSources = retained
    }

    private func releaseWriter() {
        if writers.isEmpty { writing = false }
        else { writers.removeFirst().resume() }
    }

    private func save(requiresActive: Bool = false) async throws {
        guard let handle else { return }
        let expected = record.revision
        record.revision = UUID().uuidString
        do {
            try await store.setContinuation(handle, expectedRevision: expected, record: record, requiresActive: requiresActive)
        } catch {
            fenced = true
            if let actual = try await store.continuation(handle), actual.revision == record.revision {
                record = actual
            } else { record.revision = expected }
            record.state = .blocked
            record.reason = "checkpoint_persistence_failed"
            throw error
        }
    }
}
