import AuthoredCapabilities
import Foundation
import AppKit
import CryptoKit
import Darwin
import NativeAgentCore
import PersistenceCore
// Blueprint: | `SensesContract.swift` | Shared sense records, wire validators, notebook bounds, native catalog, memory provenance and crossing contracts; built-in origins retain legacy spelling and provenance age formatting rejects invalid times |

// Shared sense contract: pages, named things, addresses and change news; behavior owners are in docs/SENSES.md.

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

/// One corner of the world a sense serves.
public enum SenseCorner: Hashable, Codable, Sendable {
    /// A Mac app, by bundle id.
    case app(bundleID: String)
    /// A kind of file, by lowercased extension without the dot ("numbers", "docx").
    case fileKind(String)
    /// A website, by lowercased host ("bank.example.com").
    case site(host: String)
    /// A device or stream with a stable id.
    case stream(id: String)
    /// A need with no natural home, by its need id.
    case need(id: String)

    /// Stable registry key, e.g. "app:com.apple.iWork.Numbers", "file:numbers".
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

/// A named thing on a page she can point at and act on.
public struct NativeThing: Codable, Sendable, Hashable {
    /// What it is called, as she would say it ("Total", "Header layer", "Send").
    public var name: String
    /// A short kind word ("cell", "layer", "button", "row", "track").
    public var kind: String
    /// Its address: stable, so she can remember it and come back.
    public var address: String
    /// One short line of detail (its value, its state), or nil.
    public var detail: String?
    /// Verbs she may invoke on it in her turn ("set", "press", "open").
    public var verbs: [String]

    public init(name: String, kind: String, address: String, detail: String? = nil, verbs: [String] = []) {
        self.name = name; self.kind = kind; self.address = address; self.detail = detail; self.verbs = verbs
    }
}

/// A corner in the native form. Compact by design: what matters is shown,
/// the rest folded, with more one request away.
public struct NativePage: Codable, Sendable, Hashable {
    public var corner: SenseCorner
    /// The page's own address (the root of its things' addresses).
    public var address: String
    public var title: String
    /// Plain text with light structure (headings, lists, tables as text).
    public var text: String
    public var things: [NativeThing]
    /// Names of sections folded away to keep the page compact.
    public var folded: [String]
    /// The address that returns more (the next part, a folded section), or nil.
    public var more: String?

    public init(corner: SenseCorner, address: String, title: String, text: String,
                things: [NativeThing] = [], folded: [String] = [], more: String? = nil) {
        self.corner = corner; self.address = address; self.title = title; self.text = text
        self.things = things; self.folded = folded; self.more = more
    }

    /// The size ceiling for a page's text (same order as Chrome page text).
    public static let maximumTextBytes = 40_000
}

/// News from a live sense: something at an address changed.
public struct SenseNews: Codable, Sendable, Hashable {
    public var id: UUID = UUID()
    public var senseID: String
    public var version: Int
    public var address: String
    public var summary: String
    public var at: Date
    /// Stable observed file/tab identity; navigation changes the visible
    /// address without creating another pending stream of news.
    public var observationID: String?
    /// Source-owned change identity, independent of a clipped/redacted summary.
    public var changeID: String?

    public init(senseID: String, version: Int, address: String, summary: String, at: Date, observationID: String? = nil, changeID: String? = nil) {
        self.senseID = senseID; self.version = version; self.address = address; self.summary = summary; self.at = at
        self.observationID = observationID
        self.changeID = changeID
    }
}

// MARK: - Senses

public enum SenseStatus: String, Codable, Sendable { case draft, on, off, unavailable }

/// The language a sense is written in. `native` = a built-in Swift sense
/// (our existing corners, wrapped unchanged on day one).
// swift is retained only to decode historical authored records.
public enum SenseLanguage: String, Codable, Sendable { case javascript, swift, native }

/// On call: runs when she reads or acts, then stops. Live: keeps running to
/// follow or maintain its corner, supervised and restarted from its state.
public enum SenseMode: String, Codable, Sendable { case onCall = "on_call", live }

public enum SenseOrigin: String, Codable, Sendable {
    case builtIn = "built in", grown, shared

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        if value == "built_in" { self = .builtIn; return }
        guard let origin = Self(rawValue: value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown sense origin: \(value)"))
        }
        self = origin
    }
}

/// What a sense may reach, enforced by its sandbox profile. Secrets,
/// credentials, Trust, approvals and persona are never
/// reachable, whatever is declared.
public struct SenseReach: Codable, Sendable, Hashable {
    /// Paths it may read (files of its kind are handed over by the source
    /// provider; this is for extra read-only reach, usually empty).
    public var readPaths: [String]
    /// Hosts it may reach over the network (empty = none).
    public var hosts: [String]
    /// Bundle identifiers; senses may only read these apps.
    public var apps: [String]?

    public init(readPaths: [String] = [], hosts: [String] = [], apps: [String]? = nil) {
        self.readPaths = readPaths; self.hosts = hosts; self.apps = apps
    }
}

/// One sense: identity, version and lifecycle, projected from its ability file.
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
    /// Source entry name, retained for bundled modules and portable exports (nil for `native`).
    public var entry: String?
    /// Validated program identity; absent for bundled and migrated source-only abilities.
    public var candidateDigest: String?
    public var disabledBy: String?
    /// The verbs it offers on its things, for door discovery.
    public var verbs: [String]
    /// Built-in senses ship with the app; they have no invented birth date.
    public var createdAt: Date?
    public var enabledAt: Date?
    public var lastUsedAt: Date?
    public var uses: Int
    public var corrections: Int
    /// Provider spend to grow this version, in USD; nil means not recorded.
    public var growthCostUSD: Double?
    /// The complaint that caused this version, retained for durable delivery.
    public var grownBecause: String?

    /// Shared code may offer verbs only after this version has run here once.
    /// The runner records a use after a successful local read, never an act.
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
        // Older bundles used Unix zero as both dates. It was never an event.
        if origin == .builtIn, enabledAt == Date(timeIntervalSince1970: 0) { enabledAt = nil }
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
        if origin != .builtIn || enabledAt != Date(timeIntervalSince1970: 0) {
            try fields.encodeIfPresent(enabledAt, forKey: .enabledAt)
        }
        try fields.encodeIfPresent(lastUsedAt, forKey: .lastUsedAt)
        try fields.encode(uses, forKey: .uses)
        try fields.encode(corrections, forKey: .corrections)
        try fields.encodeIfPresent(growthCostUSD, forKey: .growthCostUSD)
        try fields.encodeIfPresent(grownBecause, forKey: .grownBecause)
    }
}

/// The one line every served view carries, so she knows who made it.
public struct SenseProvenance: Codable, Sendable, Hashable {
    public var senseID: String
    public var version: Int
    public var grownAt: Date?
    public var uses: Int
    public var corrections: Int
    /// Optional for previously persisted provenance; current reads always stamp it.
    public var origin: SenseOrigin?

    public init(record: SenseRecord) {
        senseID = record.id; version = record.version; grownAt = record.createdAt
        uses = record.uses; corrections = record.corrections
        origin = record.origin
    }

    /// e.g. "via sense numbers-file v3 · grown 2h ago · used 41× · corrected 1×"
    public func line(now: Date) -> String {
        // Imported provenance may predate registry validation. Invalid dates
        // remain visible evidence rather than trapping or becoming a fresh age.
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
        OwnedProgramRunner.ReadContent.current?.record(.string(line),
            content: .string("via sense \(senseID) v\(version) · \(origin?.rawValue ?? "")"))
        return line
    }
}

// MARK: - Running a sense

public enum SenseRequest: Sendable, Equatable {
    /// Read the corner (or an address inside it) in the native form.
    case read(address: String?)
    /// A verb SHE invoked in her turn on a named thing. The sense turns it
    /// into door requests; it never acts on its own.
    case act(verb: String, address: String, args: JSONValue)
    /// Start following the corner (live senses only).
    case watch
    /// Handle an interactive view or part wake without authorizing door actions.
    case event(JSONValue)
}

/// Bound only while the door answers her act, never for reads or background work.
/// `verb` names an existing app action; the callback re-enters its normal gates.
public enum SenseActionContext {
    public typealias Perform = @Sendable (_ verb: String, _ address: String, _ args: JSONValue) async throws -> JSONValue
    @TaskLocal public static var perform: Perform?
}

public struct SenseFailure: Codable, Sendable, Hashable, Error {
    /// e.g. "crashed", "timeout", "bad_output", "unsupported", "source_unavailable".
    public var code: String
    public var message: String
    /// A short excerpt of the input that broke it.
    public var inputExcerpt: String?
    /// The runner attaches the same provenance to failures as to served views.
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
            if let origin = provenance.origin { value["origin"] = .string(origin.rawValue) }
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

/// The raw material NativeAgent hands a sense (`source.read`). A sense never
/// touches the operating system directly.
public enum SenseMaterial: Sendable {
    /// An app's accessibility tree, as JSON.
    case accessibility(JSONValue)
    /// A file: its path (read-only), size and bytes already admitted by a read.
    case file(path: String, bytes: Int, data: Data? = nil)
    /// A web page snapshot, as JSON (the Chrome read model).
    case pageSnapshot(JSONValue)
    /// Plain text (a document extract, a stream chunk).
    case text(String)

    /// macOS document packages: folders a file sense reads as one file.
    public static let packageExtensions: Set<String> = ["pages", "numbers", "key", "rtfd"]
}

/// Fetches raw material for a corner. Implemented by the app over the
/// existing readers (four verbs, files, Chrome).
public protocol SenseSourceProvider: Sendable {
    func material(for corner: SenseCorner, address: String?) async throws -> SenseMaterial
}

/// Receipt for the exact whole-file bytes delivered by the helper runner.
/// Package bytes count member content; version hashes names and content.
public protocol SenseFileReadReporting: SenseSourceProvider {
    func didReadFile(path: String, bytes: Int, version: String, data: Data) async
}

/// Optional event-backed observation. Every delivered material passes the
/// current raw-read gates. Unsupported corners fail rather than fake a watch.
public protocol SenseSourceWatchingProvider: SenseSourceProvider {
    func changes(for corner: SenseCorner, address: String?) async throws -> AsyncStream<SenseMaterial>
}

/// Entry-local progress admission shared by the app supervisor and JS watchdog.
/// Call `read` only after a successful read; valid publish/notify always advance.
public struct SenseEntryProgress: Sendable {
    private var readAddresses: Set<String?> = []
    private var highWater: Double?

    public init() {}

    public mutating func read(address: String?) -> Bool {
        readAddresses.insert(address).inserted
    }

    /// Nil reports one completed unit. Returns the accepted mark, or nil for a repeat.
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

/// A subscription actually held by a source or helper, independent of the
/// sense's declared on-call/live mode. It ends with that owner's subscription.
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

/// An offline interactive view. HTML is handed over as bytes, never a file
/// URL; its sole event channel is tied to this exact sense version.
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
            var result = fields.filter { $0.key != "window_picture" && $0.key != "image" && $0.key != "png" }
                .mapValues(value)
            if fields["window_picture"] != nil {
                result["window_text_unavailable_reason"] = .string("This retained app read predates text-only retention; read the app and reject that view again.")
            }
            return .object(result)
        default: return source
        }
    }
}

/// The ordinary app read owns capture. The sense receives this frozen copy,
/// containing redacted AX and recognized text, never pixels or a new capture.
public final class SenseAppReadCapture: @unchecked Sendable {
    @TaskLocal public static var current: SenseAppReadCapture?
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
            tree["window_text_unavailable_reason"] = .string("The app window changed before its recognized text could be retained; read the app and reject that view again.")
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

/// MemoryV2 owns the durable flags; lifecycle and door owners report the exact version.
public protocol SenseMemoryProvenanceSink: Sendable {
    func markVersionWrong(senseID: String, version: Int) async throws
}

/// What crosses from a watch into her mind (docs/SUBCONSCIOUS.md, Cares): a
/// line weighed on CPU against her live cares. Her cognition installs it.
public protocol SenseCrossing: Sendable {
    /// When `line` touches a care, asks for one wake on the watch's thread
    /// whose arrival `id` says `says`, and whose reason names the care.
    func cross(_ line: String, watch: String, reason: String, id: String, says: String, agent: String?) async -> SenseCrossed
}

/// What a watch's line touched (a care, by its about) and what came of it.
public enum SenseCrossed: Sendable, Equatable {
    case woke(care: String)
    case untouched
    /// Nothing could judge it (no inner life, no cares, a cold embedder): the
    /// line crosses as it would with no crossing at all.
    case unweighed
    /// This watch already woke her about it and the care has not rested since.
    case resting(care: String)
    /// The wake could not be kept.
    case notKept(care: String)
}

/// Errors surface their own words wherever they are shown, never
/// "SenseFailure error 1".
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
