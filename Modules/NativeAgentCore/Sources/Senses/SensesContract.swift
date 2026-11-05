import AuthoredCapabilities
import Foundation
import AppKit
import CryptoKit
import Darwin
import NativeAgentCore
import PersistenceCore
// Blueprint: | `SensesContract.swift` | Sense wire records, bounds, origins, provenance and crossing contracts |


// MARK: - Corners

/// Shape and byte bounds checked independently on both sides of the sense plug.
public enum SenseWire {
    public static let newsBytes = 4_000, htmlBytes = 256 * 1_024, stateKeyBytes = 256, stateValueBytes = AbilityStore.notebookValueBytes

    public static func decodePage(_ input: [String: JSONValue], corner: SenseCorner) throws -> NativePage {
        var fields = input
        fields["corner"] = try JSONValue.fromEncodable(corner)
        for key in ["things", "folded"] where fields[key] == nil || fields[key] == .null { fields[key] = .array([]) }
        if case .array(let things)? = fields["things"] {
            fields["things"] = .array(things.map { thing in
                guard case .object(var row) = thing else { return thing }
                if row["verbs"] == nil || row["verbs"] == .null { row["verbs"] = .array([]) }
                return .object(row)
            })
        }
        return try JSONDecoder().decode(NativePage.self, from: JSONValue.object(fields).serializedData(pretty: false))
    }

    public static func validatePage(_ page: NativePage,
                                    textError: String = "Sense page exceeds the text ceiling; fold it and offer more.") throws {
        guard !page.address.isEmpty else { throw SenseFailure(code: "bad_output", message: "Sense page requires an address and at most 40,000 text bytes.") }
        guard page.text.utf8.count <= NativePage.maximumTextBytes else { throw SenseFailure(code: "bad_output", message: textError) }
    }

    public static func news(_ value: JSONValue?, senseID: String, version: Int,
                            error: String = "Sense news requires an address and summary.") throws -> SenseNews {
        guard case .object(let fields)? = value, case .string(let address)? = fields["address"],
              case .string(let summary)? = fields["summary"], summary.utf8.count <= newsBytes else {
            throw SenseFailure(code: "bad_output", message: error)
        }
        return SenseNews(senseID: senseID, version: version, address: address, summary: summary, at: Date())
    }

    public static func view(_ value: JSONValue?, senseID: String, version: Int) throws -> SenseInteractiveView? {
        if value == .null { return nil }
        guard case .object(let fields)? = value, case .string(let title)? = fields["title"],
              case .string(let html)? = fields["html"], html.utf8.count <= htmlBytes else {
            throw SenseFailure(code: "bad_output", message: "Sense view requires title and at most 256 KiB of HTML.")
        }
        return SenseInteractiveView(senseID: senseID, version: version, title: title, html: html)
    }

    public static func validStateKey(_ key: String) -> Bool { !key.isEmpty && key.utf8.count <= stateKeyBytes }
}

public enum SenseCorner: Hashable, Codable, Sendable {
    case app(bundleID: String)
    /// File extensions are lowercased and omit the dot.
    case fileKind(String)
    /// Site identity uses the lowercased host.
    case site(host: String)
    case stream(id: String)
    case need(id: String)

    /// Use prefixed registry keys to distinguish apps from files and other corners.
    public var key: String {
        switch self {
        case .app(let id): "app:\(id)"
        case .fileKind(let ext): "file:\(ext)"
        case .site(let host): "site:\(host)"
        case .stream(let id): "stream:\(id)"
        case .need(let id): "need:\(id)"
        }
    }

    public init?(key: String) {
        guard let colon = key.firstIndex(of: ":") else { return nil }
        let kind = key[..<colon], value = String(key[key.index(after: colon)...])
        guard !value.isEmpty else { return nil }
        switch kind {
        case "app": self = .app(bundleID: value)
        case "file": self = .fileKind(value.lowercased())
        case "site": self = .site(host: value.lowercased())
        case "stream": self = .stream(id: value)
        case "need": self = .need(id: value)
        default: return nil
        }
    }
}

// MARK: - The native form

public struct NativeThing: Codable, Sendable, Hashable {
    public var name: String
    public var kind: String
    /// Addresses must remain stable so things can be revisited.
    public var address: String
    public var detail: String?
    public var verbs: [String]

    public init(name: String, kind: String, address: String, detail: String? = nil, verbs: [String] = []) {
        self.name = name; self.kind = kind; self.address = address; self.detail = detail; self.verbs = verbs
    }
}

/// Fold secondary detail behind another request to keep the native page compact.
public struct NativePage: Codable, Sendable, Hashable {
    public var corner: SenseCorner
    /// Thing addresses share the page's root.
    public var address: String
    public var title: String
    public var text: String
    public var things: [NativeThing]
    public var folded: [String]
    public var more: String?

    public init(corner: SenseCorner, address: String, title: String, text: String,
                things: [NativeThing] = [], folded: [String] = [], more: String? = nil) {
        self.corner = corner; self.address = address; self.title = title; self.text = text
        self.things = things; self.folded = folded; self.more = more
    }

    public static let maximumTextBytes = 40_000
}

public struct SenseNews: Codable, Sendable, Hashable {
    public var id: UUID = UUID()
    public var senseID: String
    public var version: Int
    public var address: String
    public var summary: String
    public var at: Date
    /// Navigation changes visible addresses without creating a second pending news stream; keep file/tab identity stable.
    public var observationID: String?
    /// Source change identity must not depend on clipped or redacted summaries.
    public var changeID: String?

    public init(senseID: String, version: Int, address: String, summary: String, at: Date, observationID: String? = nil, changeID: String? = nil) {
        self.senseID = senseID; self.version = version; self.address = address; self.summary = summary; self.at = at
        self.observationID = observationID
        self.changeID = changeID
    }
}

// MARK: - Senses

public enum SenseStatus: String, Codable, Sendable { case draft, on, off, unavailable }

public enum SenseLanguage: String, Codable, Sendable { case javascript, native }

/// On-call helpers end after a read/act; live helpers retain state while supervised across updates.
public enum SenseMode: String, Codable, Sendable { case onCall = "on_call", live }

public enum SenseOrigin: String, Codable, Sendable {
    case builtIn = "built in", grown, shared

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let origin = Self(rawValue: value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown sense origin: \(value)"))
        }
        self = origin
    }
}

/// Sandbox declarations must never expose secrets, credentials, Trust, approvals or persona.
public struct SenseReach: Codable, Sendable, Hashable {
    /// Ordinary source files arrive through the provider; declared paths grant only additional read-only reach.
    public var readPaths: [String]
    /// Empty hosts grants no network reach.
    public var hosts: [String]
    /// Bundle declarations grant reads only.
    public var apps: [String]?

    public init(readPaths: [String] = [], hosts: [String] = [], apps: [String]? = nil) {
        self.readPaths = readPaths; self.hosts = hosts; self.apps = apps
    }
}

/// Project lifecycle from the ability file instead of keeping another owner.
public struct SenseRecord: Codable, Sendable, Hashable {
    public var id: String
    public var corner: SenseCorner
    public var version: Int
    public var status: SenseStatus
    public var unavailableReason: String?
    public var language: SenseLanguage
    public var mode: SenseMode
    public var origin: SenseOrigin
    public var reach: SenseReach
    /// Retain entry names for bundle modules and portable exports; native senses have none.
    public var entry: String?
    /// Bundled JavaScript and native senses have no validated program identity.
    public var candidateDigest: String?
    public var disabledBy: String?
    public var verbs: [String]
    /// Built-in senses have no authored creation date.
    public var createdAt: Date?
    public var enabledAt: Date?
    public var lastUsedAt: Date?
    public var uses: Int
    public var corrections: Int
    /// Spend uses USD; nil means unrecorded rather than zero.
    public var growthCostUSD: Double?
    /// Retain the triggering complaint so growth can be delivered durably.
    public var grownBecause: String?

    /// Shared verbs require a successful local read of this exact version; an act cannot establish that proof.
    public var verbsEnabled: Bool { status == .on && (origin != .shared || uses > 0) }

    public init(id: String, corner: SenseCorner, version: Int = 1, status: SenseStatus = .on,
                language: SenseLanguage, mode: SenseMode = .onCall, origin: SenseOrigin,
                reach: SenseReach = SenseReach(), entry: String?, verbs: [String] = [],
                createdAt: Date? = nil, enabledAt: Date? = nil, lastUsedAt: Date? = nil, uses: Int = 0, corrections: Int = 0,
                growthCostUSD: Double? = nil) {
        self.id = id; self.corner = corner; self.version = version; self.status = status
        self.language = language; self.mode = mode; self.origin = origin; self.reach = reach
        self.entry = entry; self.verbs = verbs; self.createdAt = origin == .builtIn ? nil : createdAt; self.enabledAt = enabledAt
        self.lastUsedAt = lastUsedAt; self.uses = uses; self.corrections = corrections
        self.growthCostUSD = growthCostUSD
    }

    private enum CodingKeys: String, CodingKey {
        case id, corner, version, status, unavailableReason, language, mode, origin, reach, entry
        case candidateDigest, disabledBy, verbs, createdAt, enabledAt, lastUsedAt, uses, corrections, growthCostUSD, grownBecause
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(String.self, forKey: .id)
        corner = try fields.decode(SenseCorner.self, forKey: .corner)
        version = try fields.decode(Int.self, forKey: .version)
        status = try fields.decode(SenseStatus.self, forKey: .status)
        unavailableReason = try fields.decodeIfPresent(String.self, forKey: .unavailableReason)
        language = try fields.decode(SenseLanguage.self, forKey: .language)
        mode = try fields.decode(SenseMode.self, forKey: .mode)
        origin = try fields.decode(SenseOrigin.self, forKey: .origin)
        reach = try fields.decode(SenseReach.self, forKey: .reach)
        entry = try fields.decodeIfPresent(String.self, forKey: .entry)
        candidateDigest = try fields.decodeIfPresent(String.self, forKey: .candidateDigest)
        disabledBy = try fields.decodeIfPresent(String.self, forKey: .disabledBy)
        verbs = try fields.decode([String].self, forKey: .verbs)
        let created = try fields.decodeIfPresent(Date.self, forKey: .createdAt)
        createdAt = origin == .builtIn ? nil : created
        enabledAt = try fields.decodeIfPresent(Date.self, forKey: .enabledAt)
        lastUsedAt = try fields.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        uses = try fields.decode(Int.self, forKey: .uses)
        corrections = try fields.decode(Int.self, forKey: .corrections)
        growthCostUSD = try fields.decodeIfPresent(Double.self, forKey: .growthCostUSD)
        grownBecause = try fields.decodeIfPresent(String.self, forKey: .grownBecause)
    }

    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(id, forKey: .id)
        try fields.encode(corner, forKey: .corner)
        try fields.encode(version, forKey: .version)
        try fields.encode(status, forKey: .status)
        try fields.encodeIfPresent(unavailableReason, forKey: .unavailableReason)
        try fields.encode(language, forKey: .language)
        try fields.encode(mode, forKey: .mode)
        try fields.encode(origin, forKey: .origin)
        try fields.encode(reach, forKey: .reach)
        try fields.encodeIfPresent(entry, forKey: .entry)
        try fields.encodeIfPresent(candidateDigest, forKey: .candidateDigest)
        try fields.encodeIfPresent(disabledBy, forKey: .disabledBy)
        try fields.encode(verbs, forKey: .verbs)
        if origin != .builtIn { try fields.encodeIfPresent(createdAt, forKey: .createdAt) }
        try fields.encodeIfPresent(enabledAt, forKey: .enabledAt)
        try fields.encodeIfPresent(lastUsedAt, forKey: .lastUsedAt)
        try fields.encode(uses, forKey: .uses)
        try fields.encode(corrections, forKey: .corrections)
        try fields.encodeIfPresent(growthCostUSD, forKey: .growthCostUSD)
        try fields.encodeIfPresent(grownBecause, forKey: .grownBecause)
    }
}

/// Every served view must identify its producing sense.
public struct SenseProvenance: Codable, Sendable, Hashable {
    public var senseID: String
    public var version: Int
    public var grownAt: Date?
    public var uses: Int
    public var corrections: Int
    public var origin: SenseOrigin

    public init(record: SenseRecord) {
        senseID = record.id; version = record.version; grownAt = record.createdAt
        uses = record.uses; corrections = record.corrections
        origin = record.origin
    }

    public func line(now: Date, readContent: OwnedProgramRunner.ReadContent? = nil) -> String {
        // Keep invalid provenance dates visible instead of trapping or inventing a fresh age.
        let seconds = grownAt.map { now.timeIntervalSince($0) } ?? .nan
        let whole = seconds.isFinite ? Int(exactly: seconds.rounded(.towardZero)) : nil
        let ago = whole.map { value in
            let age = max(0, value)
            return age < 3600 ? "\(max(1, age / 60))m" : age < 86_400 ? "\(age / 3600)h" : "\(age / 86_400)d"
        }
        let validDate = grownAt.map { $0 >= .distantPast && $0 <= .distantFuture } ?? true
        let source = origin == .builtIn ? "built in" : validDate
            ? ago.map { "grown \($0) ago" } ?? "creation time unavailable" : "invalid creation time"
        let line = "via sense \(senseID) v\(version) · \(source) · used \(uses)× · corrected \(corrections)×"
        readContent?.record(.string(line),
            content: .string("via sense \(senseID) v\(version) · \(origin.rawValue)"))
        return line
    }
}

// MARK: - Running a sense

public enum SenseRequest: Sendable, Equatable {
    case read(address: String?)
    /// Only a verb invoked in the agent's turn may produce door requests; senses cannot act independently.
    case act(verb: String, address: String, args: JSONValue)
    case watch
    /// View and part-wake handling grants no door action authority.
    case event(JSONValue)
}

/// An act's explicitly supplied callback re-enters normal app gates.
public enum SenseActionContext {
    public typealias Perform = @Sendable (_ verb: String, _ address: String, _ args: JSONValue) async throws -> JSONValue
}

/// Re-entry and verification are properties of this read's call path.
public struct SenseReadOptions: Sendable {
    public var raw = false
    public var verifyingActCorner: SenseCorner?
    public init(raw: Bool = false, verifyingActCorner: SenseCorner? = nil) {
        self.raw = raw; self.verifyingActCorner = verifyingActCorner
    }
}

/// One read or watch operation, captured by its source and asynchronous callbacks.
/// A passive owner has no turn and no action callback; it never inherits either.
public struct SenseReadOperation: Sendable {
    public var turn: Turn?
    public var options: SenseReadOptions
    public var appCapture: SenseAppReadCapture?
    public var senseReads: SenseTurnReads?
    public var readContent: OwnedProgramRunner.ReadContent?
    public var perform: SenseActionContext.Perform?
    public var passive: Bool
    public var deadline: ContinuousClock.Instant?
    public init(turn: Turn?, options: SenseReadOptions = .init(), appCapture: SenseAppReadCapture? = nil,
                senseReads: SenseTurnReads? = nil, readContent: OwnedProgramRunner.ReadContent? = nil,
                perform: SenseActionContext.Perform? = nil, passive: Bool = false, deadline: ContinuousClock.Instant? = nil) {
        self.turn = turn; self.options = options; self.appCapture = appCapture; self.senseReads = senseReads
        self.readContent = readContent; self.perform = perform; self.passive = passive; self.deadline = deadline
    }
    public func observing() -> SenseReadOperation {
        var operation = self
        operation.turn = nil; operation.perform = nil; operation.passive = true
        operation.options.verifyingActCorner = nil
        operation.appCapture = nil; operation.senseReads = nil; operation.readContent = nil; operation.deadline = nil
        return operation
    }
}

public struct SenseFailure: Codable, Sendable, Hashable, Error {
    public var code: String
    public var message: String
    public var inputExcerpt: String?
    /// Failures need the same producing provenance as served views.
    public var provenance: SenseProvenance?
    public var remedy: JSONValue?

    public var status: String { code == "cancelled" ? "cancelled" : ["timeout", "fetch_timeout"].contains(code) ? "timeout" : "failed" }

    public func failureEvidence(render: (String) -> String = { $0 }) -> [String: JSONValue] {
        var fields: [String: JSONValue] = ["status": .string(status), "failure_code": .string(code),
            "reason": .string(code), "detail": .string(render(message))]
        fields["remedy"] = remedy
        if let inputExcerpt { fields["input_excerpt"] = .string(render(inputExcerpt)) }
        if let provenance {
            var value: [String: JSONValue] = ["senseID": .string(provenance.senseID), "version": .int(Int64(provenance.version)),
                "uses": .int(Int64(provenance.uses)), "corrections": .int(Int64(provenance.corrections))]
            if provenance.origin != .builtIn, let grownAt = provenance.grownAt {
                value["grownAt"] = .double(grownAt.timeIntervalSinceReferenceDate)
            }
            value["origin"] = .string(provenance.origin.rawValue)
            fields["provenance"] = .object(value)
        }
        return fields
    }

    public init(code: String, message: String, inputExcerpt: String? = nil, provenance: SenseProvenance? = nil, remedy: JSONValue? = nil) {
        self.code = code; self.message = message; self.inputExcerpt = inputExcerpt
        self.provenance = provenance
        self.remedy = remedy
    }

    public init(_ error: Error, code: String = "failed") {
        if let failure = error as? SenseFailure { self = failure; return }
        let failure = error as? ToolFailureError
        self.init(code: code, message: error.localizedDescription)
        guard let failure else { return }
        remedy = failure.remedy()
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(code); hasher.combine(message)
        hasher.combine(inputExcerpt); hasher.combine(provenance)
    }
}

public enum SenseOutcome: Sendable {
    case page(NativePage, SenseProvenance)
    case acted(JSONValue, SenseProvenance)
    case failed(SenseFailure)
}

/// Supply raw material through source.read; senses must never touch the operating system directly.
public enum SenseMaterial: Sendable {
    case accessibility(JSONValue)
    /// File bytes must already have passed read admission.
    case file(path: String, bytes: Int, data: Data? = nil)
    case pageSnapshot(JSONValue)
    case text(String)

    /// Treat macOS document packages as a single file despite their directory shape.
    public static let packageExtensions: Set<String> = ["pages", "numbers", "key", "rtfd"]
}

public protocol SenseSourceProvider: Sendable {
    func material(for corner: SenseCorner, address: String?, operation: SenseReadOperation) async throws -> SenseMaterial
}

/// Whole-file receipts count package member bytes and hash both names and content for version identity.
public protocol SenseFileReadReporting: SenseSourceProvider {
    func didReadFile(path: String, bytes: Int, version: String, data: Data) async
}

/// Every observed material must pass current read gates; unsupported corners must fail rather than pretend to watch.
public protocol SenseSourceWatchingProvider: SenseSourceProvider {
    func changes(for corner: SenseCorner, address: String?, operation: SenseReadOperation) async throws -> AsyncStream<SenseSourceChange>
}

/// A failed reading is not an empty snapshot; admitted file material and checked membership share one owner.
public enum SenseSourceChange: Sendable {
    case changed(SenseMaterial, files: [String: [Int64]]? = nil)
    /// Only gated ENOENT proves root absence and empty membership, distinct from a material failure.
    case absent
    case unavailable(SenseFailure)
}

/// Share progress admission between supervisor and watchdog; only successful reads and valid publish/notify may advance it.
public struct SenseEntryProgress: Sendable {
    private var readAddresses: Set<String?> = []
    private var highWater: Double?

    public init() {}

    public mutating func read(address: String?) -> Bool {
        readAddresses.insert(address).inserted
    }

    /// Nil reports a completed unit; repeated marks cannot renew progress.
    public mutating func advance(to value: Double?) throws -> Double? {
        let n = value ?? (highWater ?? 0) + 1
        guard n.isFinite else {
            throw SenseFailure(code: "bad_output", message: "Sense progress requires a finite number.")
        }
        guard highWater == nil || n > highWater! else { return nil }
        highWater = n
        return n
    }
}

/// Live subscription evidence must follow the actual owner lifetime rather than the sense's declared mode.
public struct SenseLiveWatch: Sendable, Hashable {
    public let address: String
    public let senseID: String
    public let version: Int
    public let corner: SenseCorner

    public init(address: String, senseID: String, version: Int, corner: SenseCorner) {
        self.address = ContextSecretContentPolicy.redactedFragment(address)
        self.senseID = senseID; self.version = version; self.corner = corner
    }
}

public protocol SenseWatchReporting: Sendable {
    func liveWatches() async -> [SenseLiveWatch]
}

/// Deliver view HTML as bytes, never a file URL; bind its sole event channel to the exact sense version.
public struct SenseInteractiveView: Codable, Sendable, Hashable {
    public var senseID: String
    public var version: Int
    public var title: String
    public var html: String

    public func isCurrent(in records: [SenseRecord]) -> Bool {
        records.contains { $0.id == senseID && $0.version == version && $0.status == .on }
    }

    public init(senseID: String, version: Int, title: String, html: String) {
        self.senseID = senseID; self.version = version; self.title = title; self.html = html
    }
}

public enum SenseExportResult: Sendable, Equatable {
    case approvalNeeded(senseID: String)
    case exported(URL)
}

enum SenseRetainedText {
    static func value(_ source: JSONValue) -> JSONValue {
        switch source {
        case .array(let values): return .array(values.map(value))
        case .object(let fields):
            let result = fields.filter { $0.key != "window_picture" && $0.key != "image" && $0.key != "png" }
                .mapValues(value)
            return .object(result)
        default: return source
        }
    }
}

/// Reuse the app read's frozen, redacted AX and recognized text; senses receive neither pixels nor a new capture.
public final class SenseAppReadCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var trees: [String: JSONValue] = [:]
    private let requestedBundle: String?
    public init(bundleID: String? = nil) {
        requestedBundle = bundleID
        if let bundleID {
            trees[bundleID] = .object(["app_bundle_id": .string(bundleID), "nodes": .array([])])
        }
    }
    public func record(bundleID: String, tree: JSONValue) {
        lock.lock(); defer { lock.unlock() }
        trees[bundleID] = SenseRetainedText.value(tree)
    }
    public func tree(bundleID: String) -> JSONValue? {
        lock.lock(); defer { lock.unlock() }
        return trees[bundleID]
    }
    public func augment(bundleID: String, fields: [String: JSONValue]) {
        lock.lock(); defer { lock.unlock() }
        guard case .object(var tree)? = trees[bundleID] else { return }
        tree.merge(fields) { _, new in new }
        trees[bundleID] = SenseRetainedText.value(.object(tree))
    }
    public func discardWindowText() {
        lock.lock(); defer { lock.unlock() }
        for (bundle, value) in trees {
            guard case .object(var tree) = value else { continue }
            tree.removeValue(forKey: "recognized_text")
            tree.removeValue(forKey: "recognized_text_body")
            tree["window_text_unavailable_reason"] = .string("""
                The app window changed before its recognized text could be retained; read the app and reject that view again.
                """)
            trees[bundle] = .object(tree)
        }
    }
    public func appendFrame(nodes: [JSONValue], truncated: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard let bundle = requestedBundle, case .object(var tree)? = trees[bundle] else { return }
        let previous: [JSONValue] = if case .array(let values)? = tree["nodes"] { values } else { [] }
        tree["nodes"] = .array(previous + nodes)
        tree["truncated"] = .bool(truncated || tree["truncated"] == .bool(true))
        tree["source"] = .string("retained document accessibility frames")
        trees[bundle] = .object(tree)
    }
}

/// MemoryV2 owns durable flags; lifecycle and door reporting must identify the exact version.
public protocol SenseMemoryProvenanceSink: Sendable {
    func markVersionWrong(senseID: String, version: Int) async throws
}

/// Cognition installs CPU weighing against live cares so watched lines cross through the same care owner.
public protocol SenseCrossing: Sendable {
    /// Wake the watch's own thread once, naming the touched care and retaining the arrival identity.
    func cross(_ line: String, watch: String, reason: String, id: String, says: String, agent: String?) async -> SenseCrossed
}

public enum SenseCrossed: Sendable, Equatable {
    case woke(care: String)
    case untouched
    /// Without inner life, cares or a ready embedder, pass the line through without a crossing verdict.
    case unweighed
    /// Suppress another wake while the touched care has not rested.
    case resting(care: String)
    case notKept(care: String)
}

/// Expose the failure's own words instead of an opaque NSError description.
extension SenseFailure: LocalizedError {
    public var errorDescription: String? { message.isEmpty ? code : message }
}

extension SenseCorner {
    public var surfaceName: String {
        switch self {
        case .app(let id):
            if id == "*" { return "Mac apps" }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return url.deletingPathExtension().lastPathComponent
            }
            return id
        case .fileKind(let kind): return kind == "*" ? "Files" : ".\(kind) files"
        case .site(let host): return host == "*" ? "Chrome sites" : host
        case .stream(let id):
            switch id {
            case "web": return "Web pages (read_page / web.read)"
            case "browser": return "Visible browser pages"
            case "mac.read": return "Mac documents"
            case "connectors": return "Connected services"
            default: return id
            }
        case .need(let id): return id
        }
    }
}
