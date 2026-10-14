import CryptoKit
import Foundation
import NativeAgentCore
import PersistenceCore

/// App events stay in the app process; the isolated executor only supplies JSON.
public protocol OwnedAppCalling: Sendable {
    func callApp(_ arguments: JSONValue, targets: [String: String]) async throws -> JSONValue
}

/// Exact executable bytes, not an admission. The lifecycle owner checks the
/// selected version and authority before handing a program to the runner.
public struct OwnedProgram: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case sense, tool, skill, script }
    public enum Entry: String, Codable, Sendable { case functionBody, run, sense }

    public let kind: Kind
    public let id: String
    public let version: String
    public let source: String
    public let digest: String
    public let entry: Entry
    public let schema: JSONValue
    public let dependencies: [String]
    public let permissions: [String]
    public let reach: SenseReach
    public let seconds: Double

    public init(kind: Kind, id: String, version: String, source: String, entry: Entry,
                schema: JSONValue = .object([:]), dependencies: [String] = [],
                permissions: [String] = [], reach: SenseReach = SenseReach(), seconds: Double? = nil) {
        self.kind = kind; self.id = id; self.version = version; self.source = source; self.entry = entry
        self.schema = schema; self.dependencies = dependencies; self.permissions = permissions; self.reach = reach
        self.seconds = seconds ?? (kind == .sense ? 30 : kind == .tool ? 10 : 60)
        digest = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public var sourceLimit: Int { kind == .script || kind == .skill ? 8 * 1024 : 512 * 1024 }
    public var returnLimit: Int { kind == .tool ? 4 * 1024 * 1024 : OwnedProgramRunner.returnLimit }

    public func validate() throws {
        guard !id.isEmpty, !version.isEmpty, seconds.isFinite, seconds > 0,
              source.utf8.count <= sourceLimit,
              digest == SHA256.hash(data: Data(source.utf8)).map({ String(format: "%02x", $0) }).joined(),
              (kind == .sense) == (entry == .sense),
              kind == .sense || kind == .script || entry == .run else {
            throw SenseFailure(code: "bad_input", message: "Owned program identity, source, entry or execution limit is invalid.")
        }
    }
}

/// The app registry stays above Senses. These are its current facts, used by
/// the shared journal; dependencies and permissions never grant an action.
public struct OwnedProgramAction: Sendable {
    public let id: String
    public let page: String
    public let read: Bool
    public let advisory: Bool
    public let readOnly: @Sendable ([String: JSONValue]) -> Bool
    public init(id: String, page: String, read: Bool, advisory: Bool = false,
                readOnly: @escaping @Sendable ([String: JSONValue]) -> Bool) {
        self.id = id; self.page = page; self.read = read; self.advisory = advisory; self.readOnly = readOnly
    }
}

/// Canonical domain evidence, not a second result classifier. The shared
/// journal applies strict-run rules to these projections at every result depth.
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

/// Lanes B/C supply Swift-owned hosts here: app calls re-enter the ordinary
/// gates in the requesting task's context; tool primitives check the declared
/// permissions and protected stores on every call. Live senses use their
/// source-bound adapter on the same OwnedProgramProcess, without turn authority.
/// Host profiles do not publish versions, expand Trust, or execute fallback code.
public protocol OwnedProgramHostProfile: Sendable {
    var actionIDs: [String] { get }
    var floorReasons: Set<String> { get }
    var scriptKey: String { get }
    func action(_ id: String) -> OwnedProgramAction?
    func canonicalAction(_ id: String) -> String
    func doorInput(id: String, given: [JSONValue]) -> Result<[String: JSONValue], OwnedProgramRunner.ScriptError>
    func opensHomeItem(_ input: [String: JSONValue]) -> Bool
    func secretLine(_ text: String) -> Bool
    func evidence(_ receipt: JSONValue) -> OwnedProgramReceiptEvidence
    func receiptField(_ key: String, in receipt: JSONValue) -> JSONValue?
    func perform(_ input: [String: JSONValue]) async -> JSONValue
    func validationPerform(_ input: [String: JSONValue], fixture: OwnedProgramFixtures) async -> JSONValue
    func decide(_ question: String, data: JSONValue) async throws -> JSONValue?
    func checkPrimitive(_ operation: String, arguments: JSONValue) async -> JSONValue?
    func primitiveAction(_ operation: String) -> OwnedProgramAction?
    /// Return a terminal receipt with status, effects and result, including
    /// partial/unknown effects on failure. Preview writes never reach this owner.
    func primitive(_ operation: String, arguments: JSONValue, preview: Bool) async throws -> JSONValue
}

extension OwnedProgramHostProfile {
    public func validationPerform(_ input: [String: JSONValue], fixture: OwnedProgramFixtures) async -> JSONValue {
        await fixture.reply(input)
    }
    public func decide(_ question: String, data: JSONValue) async throws -> JSONValue? { nil }
    public func checkPrimitive(_ operation: String, arguments: JSONValue) async -> JSONValue? { nil }
    public func primitiveAction(_ operation: String) -> OwnedProgramAction? { nil }
    public func primitive(_ operation: String, arguments: JSONValue, preview: Bool) async throws -> JSONValue {
        throw SenseFailure(code: "unsupported", message: "This host does not admit primitive \(operation).")
    }
}

public protocol OwnedProgramRunning: Sendable {
    func run(_ program: OwnedProgram, input: JSONValue?, preview: Bool,
             replay: OwnedProgramRunner.Replay?, host: any OwnedProgramHostProfile) async -> JSONValue
}
