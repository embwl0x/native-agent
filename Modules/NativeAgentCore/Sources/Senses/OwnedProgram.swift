import AuthoredCapabilities
import CryptoKit
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `OwnedProgram.swift` | Source and candidate identities, run/face entries and shared monotonic progress-window policy |

/// Executable bytes grant no admission; the lifecycle owner checks selected version and authority before execution.
public struct OwnedProgram: Codable, Sendable, Equatable {
    /// Version digests seal their kind, so every part must retain its sealed kind.
    public enum Kind: String, Codable, Sendable { case sense, part = "ability", script, turn, tool, skill }
    public enum Entry: String, Codable, Sendable { case functionBody, run, face, sense }

    public let kind: Kind
    public let id: String
    /// Execution identity is caller-supplied; candidate identity seals all inputs.
    public let version: String
    public let source: String
    /// Hash only source bytes so this digest remains distinct from candidate identity.
    public let digest: String
    public let entry: Entry
    public let schema: JSONValue
    public let dependencies: [String]
    public let permissions: [String]
    public let reach: SenseReach
    /// Host waits must not spend the renewable no-progress window.
    public let seconds: Double
    private let resident: Bool?
    public var isResident: Bool { resident == true }

    public init(kind: Kind, id: String, version: String, source: String, entry: Entry,
                schema: JSONValue = .object([:]), dependencies: [String] = [],
                permissions: [String] = [], reach: SenseReach = SenseReach(), seconds: Double? = nil, resident: Bool = false) {
        self.kind = kind; self.id = id; self.version = version; self.source = source; self.entry = entry
        self.schema = schema; self.dependencies = dependencies; self.permissions = permissions; self.reach = reach
        self.seconds = seconds ?? (kind == .sense ? 30 : [.part, .tool, .skill].contains(kind) ? 10 : 60)
        self.resident = resident ? true : nil
        digest = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public var sourceLimit: Int { AbilityStore.sourceLimit }
    /// Admission bounds input and captured fixtures, never clips produced returns.
    public var materialLimit: Int { isPart || kind == .turn ? 4 * 1024 * 1024 : OwnedProgramRunner.inputLimit }
    public var inputLimit: Int { materialLimit }
    public var isPart: Bool { [.part, .tool, .skill].contains(kind) }
    public var storeKind: AbilityStore.Kind? { isPart ? .part : AbilityStore.Kind(rawValue: kind.rawValue) }
    /// Journal strict calls for resume replay and interpret their receipts exactly.
    public var isStrict: Bool {
        isPart && Self.calls(source).usesStrictVerbs
    }

    public func validate() throws {
        guard !id.isEmpty, !version.isEmpty, seconds.isFinite, seconds > 0,
              source.utf8.count <= sourceLimit,
              digest == SHA256.hash(data: Data(source.utf8)).map({ String(format: "%02x", $0) }).joined(),
              (kind == .sense) == (entry == .sense),
              kind == .sense || kind == .script || entry == .run || isPart && entry == .face else {
            throw SenseFailure(code: "bad_input", message: "Owned program identity, source, entry or execution limit is invalid.")
        }
    }
}

/// The supervisor and JSC enforce independently but must share one monotonic renewal, host-wait and deadline policy.
public struct ProgramProgressWindow: Sendable {
    public let seconds: Double
    private var last: ContinuousClock.Instant = .now
    public init(seconds: Double) { self.seconds = seconds }
    public var deadline: ContinuousClock.Instant { last.advanced(by: .seconds(seconds)) }
    public mutating func renew() { last = .now }
    public mutating func resume(after started: ContinuousClock.Instant) {
        last = last.advanced(by: max(last, started).duration(to: .now))
    }
}

extension OwnedProgram {
    /// Runner verbs on `app` are not registry actions.
    public static let verbs: Set<String> = ["read", "find", "log", "expect", "expect_fail", "decide", "step"]

    /// Inspect literal app calls outside strings and comments; runtime-built ids still require the run's allowlist.
    public static func calledActions(_ source: String) -> [String] {
        var seen: Set<String> = []
        return calls(source).literal.filter { $0.inferred && !$0.primitive }.map(\.id).filter { seen.insert($0).inserted }
    }

    /// Keep offsets and lines while hiding literal text because template expressions remain code.
    public static func code(_ source: String) -> String {
        lexed(source).code
    }

    /// Share literal boundaries with call inspection so comments and regular expressions cannot become action names. The one reader is
    /// `AbilityStore.lexed`, below Senses so a part's own entry is read by it too.
    static func lexed(_ source: String) -> (code: String, literals: [Range<Int>]) {
        AbilityStore.lexed(source)
    }

}

/// Registry facts flow down into Senses; dependencies and permissions never grant action authority.
public struct OwnedProgramAction: Sendable {
    public let id: String
    public let partID: String?
    public let page: String
    public let read: Bool
    public let advisory: Bool
    /// Recordings must not execute nested authored programs.
    public let program: Bool
    public let readOnly: @Sendable ([String: JSONValue]) -> Bool
    /// Watch frames share the watch's receipt rather than creating independent ledger rows.
    public let journaled: Bool
    public let versioned: Bool
    public init(id: String, page: String, read: Bool, advisory: Bool = false, partID: String? = nil, program: Bool = false,
                journaled: Bool = true, versioned: Bool = false, readOnly: @escaping @Sendable ([String: JSONValue]) -> Bool) {
        self.id = id; self.partID = partID; self.page = page; self.read = read; self.advisory = advisory; self.program = program
        self.journaled = journaled; self.versioned = versioned; self.readOnly = readOnly
    }
}

/// Use canonical domain evidence at every result depth instead of classifying results a second way.
public struct OwnedProgramReceiptEvidence: Sendable {
    public let successful: Bool
    public let waiting: Bool
    public let resultClass: String
    public let pending: Bool
    public let effectUnconfirmed: Bool
    public init(successful: Bool, waiting: Bool, resultClass: String, pending: Bool, effectUnconfirmed: Bool) {
        self.successful = successful; self.waiting = waiting; self.resultClass = resultClass
        self.pending = pending; self.effectUnconfirmed = effectUnconfirmed
    }
}

/// App calls hand their execution's turn to ordinary gates; primitives check declared reach and protected stores on every call. Live senses use
/// source-bound adapters without turn authority; hosts cannot publish versions or expand Trust.
public protocol OwnedProgramHostProfile: Sendable {
    var actionIDs: [String] { get throws }
    var floorReasons: Set<String> { get }
    var scriptKey: String { get }
    func action(_ id: String) throws -> OwnedProgramAction?
    func canonicalAction(_ id: String) throws -> String
    func doorInput(id: String, given: [JSONValue]) -> Result<[String: JSONValue], OwnedProgramRunner.ScriptError>
    func callArgumentsForEvidence(_ id: String, given: [JSONValue]) throws -> [JSONValue]
    func opensHomeItem(_ input: [String: JSONValue]) -> Bool
    func secretLine(_ text: String) -> Bool
    func evidence(_ receipt: JSONValue) -> OwnedProgramReceiptEvidence
    func receiptField(_ key: String, in receipt: JSONValue) -> JSONValue?
    func answer(_ receipt: JSONValue) -> JSONValue
    func perform(_ input: [String: JSONValue], execution: OwnedProgramExecution) async -> JSONValue
    func validationPerform(_ input: [String: JSONValue], fixture: OwnedProgramFixtures, execution: OwnedProgramExecution) async -> JSONValue
    func decide(_ question: String, data: JSONValue, execution: OwnedProgramExecution) async throws -> JSONValue?
    func checkPrimitive(_ operation: String, arguments: JSONValue, execution: OwnedProgramExecution) async -> JSONValue?
    func primitiveAction(_ operation: String) -> OwnedProgramAction?
    /// Keep partial and unknown effects in terminal receipts; suppress preview effects and propagate preview into nested programs.
    func primitive(_ operation: String, arguments: JSONValue, preview: Bool, execution: OwnedProgramExecution) async throws -> JSONValue
    func reach(_ name: String, execution: OwnedProgramExecution) async throws -> JSONValue
}

extension OwnedProgramHostProfile {
    public func answer(_ receipt: JSONValue) -> JSONValue { receipt }
    public func validationPerform(_ input: [String: JSONValue], fixture: OwnedProgramFixtures, execution: OwnedProgramExecution) async -> JSONValue {
        await fixture.reply(input, execution: execution)
    }
    public func decide(_ question: String, data: JSONValue, execution: OwnedProgramExecution) async throws -> JSONValue? { nil }
    public func checkPrimitive(_ operation: String, arguments: JSONValue, execution: OwnedProgramExecution) async -> JSONValue? { nil }
    public func primitiveAction(_ operation: String) -> OwnedProgramAction? { nil }
    public func primitive(_ operation: String, arguments: JSONValue, preview: Bool, execution: OwnedProgramExecution) async throws -> JSONValue {
        throw SenseFailure(code: "unsupported", message: "This host does not admit primitive \(operation).")
    }
    public func reach(_ name: String, execution: OwnedProgramExecution) async throws -> JSONValue {
        throw SenseFailure(code: "unsupported", message: "Only the agent's turn part reaches turn.\(name)().")
    }
}

public protocol OwnedProgramRunning: Sendable {
    func run(_ program: OwnedProgram, input: JSONValue?, preview: Bool,
             replay: OwnedProgramRunner.Replay?, host: any OwnedProgramHostProfile, execution: OwnedProgramExecution) async -> JSONValue
}

/// One invocation's input, pinned contracts and call accumulators. The turn is
/// held here and handed to the host; none of these values comes from a task.
public struct OwnedProgramExecution: Sendable {
    /// The model-dispatched tool operation, when this host call serves a part thought.
    public var toolInvocation: ChatToolInvocation?
    public var turn: Turn?
    public var surface: String
    public var input: JSONValue?
    public var preview: Bool
    public var wake: JSONValue?
    public var options: OwnedProgramRunOptions
    public var readContent: OwnedProgramRunner.ReadContent?
    public var dependencySnapshot: (id: String, version: String, shapes: JSONValue)?
    public var valueIdentity: (id: String, version: String)?
    public struct ValueReach: Sendable {
        public let id: String
        public let actions: Set<String>
        public let capabilities: Set<String>
        public init(id: String, actions: Set<String>, capabilities: Set<String>) {
            self.id = id; self.actions = actions; self.capabilities = capabilities
        }
    }
    public var valueReach: ValueReach?
    public var deadline: ContinuousClock.Instant?
    public var deadlines: OperationDeadlines
    public var onActivity: (@Sendable () -> Void)?
    public init(turn: Turn?, surface: String, deadlines: OperationDeadlines, input: JSONValue? = nil, preview: Bool = false, wake: JSONValue? = nil,
                options: OwnedProgramRunOptions = .init(), readContent: OwnedProgramRunner.ReadContent? = nil,
                dependencySnapshot: (id: String, version: String, shapes: JSONValue)? = nil,
                valueIdentity: (id: String, version: String)? = nil, valueReach: ValueReach? = nil, deadline: ContinuousClock.Instant? = nil,
                onActivity: (@Sendable () -> Void)? = nil) {
        self.turn = turn; self.surface = surface; self.input = input; self.preview = preview; self.wake = wake; self.options = options
        self.readContent = readContent; self.dependencySnapshot = dependencySnapshot; self.valueIdentity = valueIdentity;
        self.valueReach = valueReach
            self.deadline = deadline; self.onActivity = onActivity
        self.deadlines = deadlines
    }
}
