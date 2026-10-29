import AuthoredCapabilities
import CryptoKit
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `OwnedProgram.swift` | Program contract separating source digest from caller/candidate version, run/face entries over the same source, and ProgramProgressWindow: shared ContinuousClock renewal, host-wait exclusion and deadlines, with independent supervisor/JSC enforcement |

/// Exact executable bytes, not an admission. The lifecycle owner checks the
/// selected version and authority before handing a program to the runner.
public struct OwnedProgram: Codable, Sendable, Equatable {
    /// `tool` and `skill` survive only as the kind sealed into a part's
    /// earlier versions (their digests hash it): every one runs as a part.
    public enum Kind: String, Codable, Sendable { case sense, part = "ability", script, turn, tool, skill }
    public enum Entry: String, Codable, Sendable { case functionBody, run, face, sense }

    public let kind: Kind
    public let id: String
    /// Caller-supplied execution identity; candidates replace it with their full seal.
    public let version: String
    public let source: String
    /// SHA-256 of source alone; distinct from the candidate's version.
    public let digest: String
    public let entry: Entry
    public let schema: JSONValue
    public let dependencies: [String]
    public let permissions: [String]
    public let reach: SenseReach
    /// Renewable no-progress seconds, excluding host waits: sense 30, ability 10, other 60 by default.
    public let seconds: Double
    private let resident: Bool?
    public var isResident: Bool { resident == true }

    public init(kind: Kind, id: String, version: String, source: String, entry: Entry,
                schema: JSONValue = .object([:]), dependencies: [String] = [],
                permissions: [String] = [], reach: SenseReach = SenseReach(), seconds: Double? = nil, resident: Bool = false) {
        self.kind = kind; self.id = id; self.version = version; self.source = source; self.entry = entry
        self.schema = schema; self.dependencies = dependencies; self.permissions = permissions; self.reach = reach
        // Her parts run under one rule.
        self.seconds = seconds ?? (kind == .sense ? 30 : [.part, .tool, .skill].contains(kind) ? 10 : 60)
        self.resident = resident ? true : nil
        digest = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public var sourceLimit: Int { AbilityStore.sourceLimit }
    public var returnLimit: Int { isPart || kind == .turn ? 4 * 1024 * 1024 : OwnedProgramRunner.returnLimit }
    public var inputLimit: Int { isPart || kind == .turn ? returnLimit : OwnedProgramRunner.inputLimit }
    /// One of her parts, whichever door made it.
    public var isPart: Bool { [.part, .tool, .skill].contains(kind) }
    /// The ability file kind its versions live in.
    public var storeKind: AbilityStore.Kind? { isPart ? .part : AbilityStore.Kind(rawValue: kind.rawValue) }
    /// A part whose code uses steps, decisions or expectations runs strict:
    /// each call journaled for a resume, and its receipt read exactly.
    public var isStrict: Bool {
        isPart && Self.code(source).range(of: #"\bapp\s*\.\s*(step|decide|expect|expect_fail)\s*\("#, options: .regularExpression) != nil
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

/// The supervisor and JSC watchdog keep independent progress evidence and
/// enforcement, with one monotonic renewal/host-wait/deadline policy.
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
    /// The runner's own verbs on `app`, which are never actions.
    public static let verbs: Set<String> = ["read", "find", "log", "expect", "expect_fail", "decide", "step"]

    /// The app actions a part's code calls by name, app.<page>.<action>(…),
    /// read outside its strings and comments. An id it builds at run time
    /// can't be seen here, and the run's allowlist still stops it.
    public static func calledActions(_ source: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\bapp\s*\.\s*(\w+)\s*\.\s*(\w+)\s*\("#) else { return [] }
        let code = OwnedProgram.code(source)
        var found: [String] = []
        for match in regex.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            let parts = (1...2).compactMap { Range(match.range(at: $0), in: code).map { String(code[$0]) } }
            guard parts.count == 2, !verbs.contains(parts[0]) else { continue }
            let id = parts.joined(separator: ".").lowercased()
            if !found.contains(id) { found.append(id) }
        }
        return found
    }

    /// Why a part's code can't run here, read outside its strings and comments:
    /// the executor is sync-only, so an async run hands back a Promise only
    /// after its effects already landed. Save, enable and run refuse it first.
    public static func asyncRefusal(_ source: String) -> String? {
        let code = OwnedProgram.code(source)
        guard let found = code.range(of: #"(?<![.$\w])(async|await)(?![\w$])|(?<![$\w])Promise(?![\w$])"#,
                                     options: .regularExpression) else { return nil }
        let line = code[..<found.lowerBound].utf8.filter { $0 == 10 }.count + 1
        return "Its code uses \(code[found]) at line \(line). Here async, await and Promise are refused anywhere in code (strings and comments aside; rename a key that uses one): an async run's effects land before its result can be read. "
            + "Define function run(input) synchronously, drop await and Promises (app and host calls already return their answer), and return plain JSON."
    }

    /// Keep offsets and lines while hiding literal text; template expressions are code.
    public static func code(_ source: String) -> String {
        let text = Array(source.utf16)
        var masked = text, i = 0
        func word(_ c: UInt16) -> Bool { c >= 128 || (48...57).contains(c) || (65...90).contains(c) || (97...122).contains(c) || c == 95 || c == 36 }
        func hide(_ start: Int) { for n in start..<i where text[n] != 10 && text[n] != 13 { masked[n] = 32 } }
        func literal(_ delimiter: UInt16) {
            let start = i
            i += 1
            var bracket = false
            while i < text.count {
                let c = text[i]; i += 1
                if c == 92 { i = min(i + 1, text.count); continue }
                if delimiter == 47, c == 91 { bracket = true }
                if delimiter == 47, c == 93 { bracket = false }
                if c == delimiter, !bracket { break }
            }
            if delimiter == 47 { while i < text.count, word(text[i]) { i += 1 } }
            hide(start)
        }
        func code(_ interpolation: Bool = false) {
            var regexAllowed = true, previous = "", parens: [Bool] = [], braces: [Bool] = []
            while i < text.count {
                let c = text[i], next = i + 1 < text.count ? text[i + 1] : 0
                if c == 32 || c == 9 || c == 10 || c == 13 { i += 1; continue }
                if c == 47, next == 47 || next == 42 {
                    let start = i; i += 2
                    while i < text.count {
                        if next == 47, text[i] == 10 || text[i] == 13 { break }
                        if next == 42, text[i] == 42, i + 1 < text.count, text[i + 1] == 47 { i += 2; break }
                        i += 1
                    }
                    hide(start); continue
                }
                if c == 34 || c == 39 || (c == 47 && regexAllowed) {
                    literal(c); regexAllowed = false; previous = "literal"; continue
                }
                if c == 96 {
                    var start = i; i += 1
                    while i < text.count {
                        if text[i] == 92 { i = min(i + 2, text.count); continue }
                        if text[i] == 96 { i += 1; hide(start); break }
                        if text[i] == 36, i + 1 < text.count, text[i + 1] == 123 {
                            i += 2; hide(start); code(true); start = i; continue
                        }
                        i += 1
                    }
                    hide(start); regexAllowed = false; previous = "literal"; continue
                }
                if word(c) {
                    let start = i
                    while i < text.count, word(text[i]) { i += 1 }
                    previous = String(decoding: text[start..<i], as: UTF16.self)
                    regexAllowed = ["return", "throw", "case", "delete", "void", "typeof", "new", "in", "of", "yield", "await", "else", "do"].contains(previous)
                    continue
                }
                if (c == 43 || c == 45), next == c {
                    i += 2; previous = "increment"; continue
                }
                i += 1
                if c == 123 { braces.append(["=", "(", "[", ",", ":", "?", "return", "yield", "await"].contains(previous) || (interpolation && previous.isEmpty)) }
                if c == 125 {
                    if interpolation, braces.isEmpty { masked[i - 1] = 32; return }
                    regexAllowed = !(braces.popLast() ?? false)
                    previous = "}"; continue
                }
                if c == 40 { parens.append(["if", "while", "for", "with", "switch", "catch"].contains(previous)) }
                regexAllowed = c == 41 ? (parens.popLast() ?? false) : ![93, 46].contains(c)
                previous = String(decoding: [c], as: UTF16.self)
            }
        }
        code()
        return String(decoding: masked, as: UTF16.self)
    }

}

/// The app registry stays above Senses. These are its current facts, used by
/// the shared journal; dependencies and permissions never grant an action.
public struct OwnedProgramAction: Sendable {
    public let id: String
    public let partID: String?
    public let page: String
    public let read: Bool
    public let advisory: Bool
    /// The action runs a program she wrote; a recording never runs one.
    public let program: Bool
    public let readOnly: @Sendable ([String: JSONValue]) -> Bool
    /// False for calls that answer the script without a ledger row of their
    /// own (a watch's frames: the watch leaves one receipt for them all).
    public let journaled: Bool
    /// Its writes are checked against a page version (not version-exempt).
    public let versioned: Bool
    public init(id: String, page: String, read: Bool, advisory: Bool = false, partID: String? = nil, program: Bool = false,
                journaled: Bool = true, versioned: Bool = false, readOnly: @escaping @Sendable ([String: JSONValue]) -> Bool) {
        self.id = id; self.partID = partID; self.page = page; self.read = read; self.advisory = advisory; self.program = program
        self.journaled = journaled; self.versioned = versioned; self.readOnly = readOnly
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
    /// What a program's call gets back from its receipt: the tool's own data.
    func answer(_ receipt: JSONValue) -> JSONValue
    func perform(_ input: [String: JSONValue]) async -> JSONValue
    func validationPerform(_ input: [String: JSONValue], fixture: OwnedProgramFixtures) async -> JSONValue
    func decide(_ question: String, data: JSONValue) async throws -> JSONValue?
    func checkPrimitive(_ operation: String, arguments: JSONValue) async -> JSONValue?
    func primitiveAction(_ operation: String) -> OwnedProgramAction?
    /// Return a terminal receipt with status, effects and result, including
    /// partial/unknown effects on failure. Preview effects are suppressed; nested programs retain preview.
    func primitive(_ operation: String, arguments: JSONValue, preview: Bool) async throws -> JSONValue
    /// Her turn part's synchronous reach (`turn.persona()` and the rest).
    func reach(_ name: String) async throws -> JSONValue
}

extension OwnedProgramHostProfile {
    public func answer(_ receipt: JSONValue) -> JSONValue { receipt }
    public func validationPerform(_ input: [String: JSONValue], fixture: OwnedProgramFixtures) async -> JSONValue {
        await fixture.reply(input)
    }
    public func decide(_ question: String, data: JSONValue) async throws -> JSONValue? { nil }
    public func checkPrimitive(_ operation: String, arguments: JSONValue) async -> JSONValue? { nil }
    public func primitiveAction(_ operation: String) -> OwnedProgramAction? { nil }
    public func primitive(_ operation: String, arguments: JSONValue, preview: Bool) async throws -> JSONValue {
        throw SenseFailure(code: "unsupported", message: "This host does not admit primitive \(operation).")
    }
    public func reach(_ name: String) async throws -> JSONValue {
        throw SenseFailure(code: "unsupported", message: "Only her turn part reaches turn.\(name)().")
    }
}

public protocol OwnedProgramRunning: Sendable {
    func run(_ program: OwnedProgram, input: JSONValue?, preview: Bool,
             replay: OwnedProgramRunner.Replay?, host: any OwnedProgramHostProfile) async -> JSONValue
}
