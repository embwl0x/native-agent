import Foundation
import CryptoKit
import Darwin
import NativeAgentCore
import PersistenceCore

// The Native World (User, 2026-10-05; design: docs/SENSES.md). NativeAgent makes
// the whole world native to its agent: every app, file kind, site and stream
// reaches her in ONE form — a page, named things, an address for everything,
// news when it changes. This file is the shared contract every
// part builds against; behaviour lives in the owners named in docs/SENSES.md.

// MARK: - Corners

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

public enum SenseStatus: String, Codable, Sendable { case draft, on, archived, unavailable }

/// The language a sense is written in. `native` = a built-in Swift sense
/// (our existing corners, wrapped unchanged on day one).
public enum SenseLanguage: String, Codable, Sendable { case javascript, swift, native }

/// On call: runs when she reads or acts, then stops. Live: keeps running to
/// follow or maintain its corner, supervised and restarted from its state.
public enum SenseMode: String, Codable, Sendable { case onCall = "on_call", live }

public enum SenseOrigin: String, Codable, Sendable { case builtIn = "built_in", grown, shared }

/// What a sense may reach, enforced by its sandbox profile. Secrets,
/// credentials, Trust, approvals and persona are never
/// reachable, whatever is declared.
public struct SenseReach: Codable, Sendable, Hashable {
    /// Paths it may read (files of its kind are handed over by the source
    /// provider; this is for extra read-only reach, usually empty).
    public var readPaths: [String]
    /// Hosts it may reach over the network (empty = none).
    public var hosts: [String]

    public init(readPaths: [String] = [], hosts: [String] = []) { self.readPaths = readPaths; self.hosts = hosts }
}

/// One sense: identity, version and lifecycle. Stored by the registry.
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
    /// Entry file, relative to the sense's version folder (nil for `native`).
    public var entry: String?
    /// The verbs it offers on its things, for door discovery.
    public var verbs: [String]
    public var createdAt: Date
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
                createdAt: Date, enabledAt: Date? = nil, lastUsedAt: Date? = nil, uses: Int = 0, corrections: Int = 0,
                growthCostUSD: Double? = nil) {
        self.id = id; self.corner = corner; self.version = version; self.status = status
        self.language = language; self.mode = mode; self.origin = origin; self.reach = reach
        self.entry = entry; self.verbs = verbs; self.createdAt = createdAt; self.enabledAt = enabledAt
        self.lastUsedAt = lastUsedAt; self.uses = uses; self.corrections = corrections
        self.growthCostUSD = growthCostUSD
    }
}

/// The one line every served view carries, so she knows who made it.
public struct SenseProvenance: Codable, Sendable, Hashable {
    public var senseID: String
    public var version: Int
    public var grownAt: Date
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
        let age = Int(max(0, now.timeIntervalSince(grownAt)))
        let ago: String = age < 3600 ? "\(max(1, age / 60))m" : age < 86_400 ? "\(age / 3600)h" : "\(age / 86_400)d"
        let source = origin == .builtIn ? "built in" : "grown \(ago) ago"
        return "via sense \(senseID) v\(version) · \(source) · used \(uses)× · corrected \(corrections)×"
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

    public init(code: String, message: String, inputExcerpt: String? = nil, provenance: SenseProvenance? = nil) {
        self.code = code; self.message = message; self.inputExcerpt = inputExcerpt
        self.provenance = provenance
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
    /// A file: its path (read-only) and size.
    case file(path: String, bytes: Int)
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
    func didReadFile(path: String, bytes: Int, version: String) async
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

/// Runs a sense (the helper process for javascript/swift, in-process for native).
public protocol SenseRunner: Sendable {
    func run(_ record: SenseRecord, request: SenseRequest, source: SenseSourceProvider) async -> SenseOutcome
}

/// An offline interactive view. HTML is handed over as bytes, never a file
/// URL; its sole event channel is tied to this exact sense version.
public struct SenseInteractiveView: Codable, Sendable, Hashable {
    public var senseID: String
    public var version: Int
    public var title: String
    public var html: String

    public init(senseID: String, version: Int, title: String, html: String) {
        self.senseID = senseID; self.version = version; self.title = title; self.html = html
    }
}

/// Optional runner capability. View events may update the sense's view or
/// notebook; they are not SenseRequest.act and must never execute door actions.
public protocol SenseViewEventReceiver: Sendable {
    func receiveViewEvent(_ event: JSONValue, for record: SenseRecord,
                          source: SenseSourceProvider) async throws
}

/// The registry: one lookup the door consults first.
public protocol SenseRegistry: Sendable {
    func sense(for corner: SenseCorner) async throws -> SenseRecord?
    func all() async throws -> [SenseRecord]
    func upsert(_ record: SenseRecord) async throws
    func recordUse(senseID: String) async
}

/// Optional management surface for lifecycle, versioned code and portable sharing.
/// Consumers reach this through the registry installed in SensesHub.
public protocol SenseRegistryManaging: SenseRegistry {
    func allChecked() async throws -> [SenseRecord]
    func upsert(_ record: SenseRecord, codeFiles: [String: Data]) async throws -> SenseRecord
    func versions(id: String) async throws -> [SenseRecord]
    func recordUse(senseID: String, version: Int) async throws
    func rollback(id: String) async throws -> SenseRecord
    func setStatus(id: String, version: Int, status: SenseStatus) async throws -> SenseRecord
    func markUnavailable(id: String, version: Int, reason: String) async throws
    /// Publication and User's off-switch are serialized by the registry owner.
    func publishIfNotArchived(_ record: SenseRecord, codeFiles: [String: Data]) async throws -> SenseRecord?
    func archiveUnused(now: Date) async throws -> [SenseRecord]
    func exportBundle(id: String, to destination: URL, userApproved: Bool) async throws -> SenseExportResult
    func importBundle(from bundle: URL) async throws -> SenseRecord
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

// MARK: - The hub

/// Process-wide wiring, set once at launch by the app, so Core call sites
/// (the door and the readers) reach the senses without
/// depending on the app. Every member is optional: nil = senses not wired.
public final class SensesHub: @unchecked Sendable {
    public static let shared = SensesHub()
    private let lock = NSLock()
    private var _registry: SenseRegistry?
    private var _runner: SenseRunner?
    private var _source: SenseSourceProvider?
    private var _memoryProvenanceSink: (any SenseMemoryProvenanceSink)?

    public func installMemoryProvenanceSink(_ sink: any SenseMemoryProvenanceSink) {
        lock.lock(); defer { lock.unlock() }
        _memoryProvenanceSink = sink
    }

    /// Call after a page is actually served in her turn, before returning it.
    public func didServe(_ provenance: SenseProvenance) {
        SenseTurnReads.current?.record(provenance)
    }

    /// Call for viewWrong and for the version being withdrawn on rollback.
    public func markVersionWrong(senseID: String, version: Int) async throws {
        let sink = memoryProvenanceSink
        guard let sink else {
            throw SenseFailure(code: "memory_unavailable", message: "Cannot flag memories: sense memory provenance is not wired.")
        }
        try await sink.markVersionWrong(senseID: senseID, version: version)
    }

    private var memoryProvenanceSink: (any SenseMemoryProvenanceSink)? {
        lock.lock(); defer { lock.unlock() }; return _memoryProvenanceSink
    }

    public func install(registry: SenseRegistry?, runner: SenseRunner?, source: SenseSourceProvider?) {
        lock.lock(); defer { lock.unlock() }
        _registry = registry; _runner = runner; _source = source
    }

    public var registry: SenseRegistry? { lock.lock(); defer { lock.unlock() }; return _registry }
    public var runner: SenseRunner? { lock.lock(); defer { lock.unlock() }; return _runner }
    public var source: SenseSourceProvider? { lock.lock(); defer { lock.unlock() }; return _source }

    /// Watch entries, their source callbacks and restarts are observations,
    /// independently of which turn originally started the live sense.
    @TaskLocal public static var passiveObservation = false

}

// MARK: - Native senses and news

/// A built-in sense implemented in Swift, in-process (`SenseLanguage.native`):
/// our existing corners wrapped unchanged on day one. The runner calls it
/// instead of the helper.
public protocol NativeSense: Sendable {
    var id: String { get }
    var corner: SenseCorner { get }
    func run(_ request: SenseRequest, source: SenseSourceProvider) async -> SenseOutcome
}

/// Built-in senses by id, registered at launch.
public final class NativeSenseCatalog: @unchecked Sendable {
    public static let shared = NativeSenseCatalog()
    private let lock = NSLock()
    private var senses: [String: NativeSense] = [:]

    public func register(_ sense: NativeSense) {
        lock.lock(); defer { lock.unlock() }
        senses[sense.id] = sense
    }

    public func sense(id: String) -> NativeSense? {
        lock.lock(); defer { lock.unlock() }
        return senses[id]
    }

    public var all: [NativeSense] {
        lock.lock(); defer { lock.unlock() }
        return Array(senses.values)
    }
}

/// The latest news from live senses. The runner posts; her context and the
/// surfaces read. Bounded: older news falls off.
public actor SenseNewsBoard {
    public static let shared = SenseNewsBoard()
    public static let capacity = 200
    /// News retention, not a reader/execution deadline. No timer or polling.
    public static let maximumAge: TimeInterval = 60 * 60
    private var items: [SenseNews] = []
    private var recent: [SenseNews] = []
    private struct History: Codable {
        var count: Int
        var deltas: [String]
    }
    private struct Saved: Codable {
        var schema = 1
        var items: [SenseNews]
        // Includes acknowledged notices: delivery must not renew their unread
        // status when a restored watcher sends the same source change again.
        var recent: [SenseNews]
        var histories: [UUID: History]
    }
    private static let maximumStorageBytes = 8 * 1_024 * 1_024
    private static let maximumSummaryBytes = 2_048
    private static let maximumUpdateBytes = 240
    private var histories: [UUID: History] = [:]
    private var view: SenseInteractiveView?
    private var storageURL: URL?
    private var storageBlocked = false
    private var storageNotice: SenseNews?
    public private(set) var storageFailure: String?

    /// Bind before live readers start. Only a missing file means an empty
    /// board; damaged bytes are preserved and the failure remains visible.
    public func configure(dataRoot: URL) {
        guard storageURL == nil else { return }
        let directory = dataRoot.appendingPathComponent("senses/news", isDirectory: true)
        storageURL = directory.appendingPathComponent("unread.json")
        do {
            let fm = FileManager.default
            for folder in [directory.deletingLastPathComponent(), directory] {
                var info = stat()
                if lstat(folder.path, &info) == 0 {
                    guard info.st_mode & S_IFMT == S_IFDIR else {
                        throw storageError("Private news folder is not a directory.")
                    }
                } else {
                    guard errno == ENOENT else { throw storageError("Private news folder is unreadable.") }
                    try fm.createDirectory(at: folder, withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700])
                }
            }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            var excluded = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            let url = storageURL!
            var info = stat()
            if lstat(url.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFREG,
                      info.st_size >= 0, info.st_size <= Self.maximumStorageBytes else {
                    throw storageError("Private news store must be a bounded regular file.")
                }
                let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: url))
                guard saved.schema == 1, saved.items.count <= Self.capacity,
                      saved.recent.count <= Self.capacity, saved.histories.count <= Self.capacity,
                      Set(saved.items.map(\.id)).count == saved.items.count,
                      saved.histories.values.allSatisfy({ $0.count >= $0.deltas.count && $0.deltas.count <= 3 }) else {
                    throw storageError("Private news store has invalid bounds or schema.")
                }
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                // Installation owns the binding before watches start. Preserve
                // any startup notice already buffered by a source owner.
                let buffered = items
                items = saved.items
                recent = saved.recent
                histories = saved.histories
                for item in buffered where !items.contains(where: { $0.id == item.id }) {
                    items.append(item)
                    recent.append(item)
                }
                items = Array(items.suffix(Self.capacity))
                recent = Array(recent.suffix(Self.capacity))
            } else if errno != ENOENT {
                throw storageError("Private news store is unreadable.")
            }
            prune(save: false)
            try persist()
        } catch {
            storageBlocked = true
            fail(error)
        }
    }

    public func present(_ view: SenseInteractiveView?) {
        self.view = view
    }
    public func interactiveView() -> SenseInteractiveView? { view }

    public func post(_ news: SenseNews) async {
        guard !Task.isCancelled else { return }
        postCurrent(news)
        await DerivedStateInvalidationCenter.shared.publish(DerivedSourceChange(
            namespace: "sense-news", stableID: news.senseID, operation: .changed,
            reason: "sense_news_posted", occurredAt: news.at))
    }

    private func postCurrent(_ news: SenseNews) {
        // Sanitize every visible field before history prefixes or clipping.
        // Source-owned observation/change identities remain exact and private.
        var news = news
        // Exact source identities are private hashes, not clipped addresses or
        // summaries. This keeps both deduplication and storage bounded.
        news.observationID = Self.identity(news.observationID ?? news.address)
        news.changeID = Self.identity(news.changeID ?? news.summary)
        news.senseID = ContextSecretContentPolicy.redactedFragment(news.senseID)
        news.address = ContextSecretContentPolicy.redactedFragment(news.address)
        news.summary = Self.bounded(ContextSecretContentPolicy.redactedFragment(news.summary), bytes: Self.maximumSummaryBytes)
        prune()
        guard news.at >= Date().addingTimeInterval(-Self.maximumAge) else { return }
        let sameCorner: (SenseNews) -> Bool = {
            $0.senseID == news.senseID && $0.version == news.version
                && ($0.observationID ?? $0.address) == (news.observationID ?? news.address)
        }
        // Repeated notices do not renew an old notice's age or unread status.
        guard !recent.contains(where: { sameCorner($0) && ($0.changeID ?? $0.summary) == (news.changeID ?? news.summary) }) else { return }
        recent.removeAll(where: sameCorner)
        recent.append(news)
        if recent.count > Self.capacity { recent.removeFirst(recent.count - Self.capacity) }
        var combined = news
        if let previous = items.first(where: sameCorner) {
            let history = histories.removeValue(forKey: previous.id) ?? History(count: 1, deltas: [Self.updateLine(previous.summary)])
            let deltas = Array(([Self.updateLine(news.summary)] + history.deltas).prefix(3))
            let count = history.count + 1
            histories[news.id] = History(count: count, deltas: deltas)
            let omitted = count - deltas.count
            combined.summary = "\(count) updates (newest first):\n" + deltas.map { "• " + $0 }.joined(separator: "\n")
                + (omitted > 0 ? "\n\(omitted) older updates omitted." : "")
        }
        combined.summary = ContextSecretContentPolicy.redactedFragment(combined.summary)
        // Keep the latest notice per corner; individual DOM/file edges cannot
        // occupy the board or starve another corner.
        items.removeAll(where: sameCorner)
        items.append(combined)
        if items.count > Self.capacity { items.removeFirst(items.count - Self.capacity) }
        retainHistories()
        saveVisible()
    }

    public func latest(limit: Int = 20) -> [SenseNews] {
        prune()
        let ordered = items.sorted { $0.at > $1.at }
        return Array(((storageNotice.map { [$0] } ?? []) + ordered).prefix(max(0, limit)))
    }

    /// Acknowledge immutable notices only after provider output proves the
    /// packet was served. A newer event at the same address survives this ack.
    public func acknowledge(_ ids: Set<UUID>) async {
        let previousItems = items
        let previousHistories = histories
        items.removeAll { ids.contains($0.id) }
        retainHistories()
        // Publish removal only after its durable receipt. Failed delivery
        // bookkeeping is shown explicitly instead of promising restart safety.
        do { try persist() } catch {
            items = previousItems
            histories = previousHistories
            fail(error)
        }
        await DerivedStateInvalidationCenter.shared.publish(DerivedSourceChange(
            namespace: "sense-news", stableID: "served", operation: .changed,
            reason: "sense_news_seen", occurredAt: Date()))
    }

    private func prune(save: Bool = true) {
        let previousCount = items.count + recent.count
        let cutoff = Date().addingTimeInterval(-Self.maximumAge)
        items.removeAll { $0.at < cutoff }
        recent.removeAll { $0.at < cutoff }
        retainHistories()
        if save, previousCount != items.count + recent.count { saveVisible() }
    }

    private func retainHistories() {
        let ids = Set(items.map(\.id))
        histories = histories.filter { ids.contains($0.key) }
    }

    private static func identity(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func bounded(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var result = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            guard used + size <= bytes - "…".utf8.count else { break }
            result.append(character)
            used += size
        }
        return result + "…"
    }

    private static func updateLine(_ text: String) -> String {
        bounded(text.split(whereSeparator: \.isNewline).joined(separator: " · "), bytes: maximumUpdateBytes)
    }

    private func persist() throws {
        guard let storageURL else { return }
        guard !storageBlocked else { throw storageError(storageFailure ?? "Private news storage is unavailable.") }
        let bytes = try JSONEncoder().encode(Saved(items: items, recent: recent, histories: histories))
        guard bytes.count <= Self.maximumStorageBytes else { throw storageError("Private news storage exceeded its byte bound.") }
        guard NativePrivateFile.write(bytes, to: storageURL) else { throw storageError("Cannot durably write private unread news.") }
        storageFailure = nil
        storageNotice = nil
    }

    private func saveVisible() {
        do { try persist() } catch { fail(error) }
    }

    private func storageError(_ message: String) -> NSError {
        NSError(domain: "SenseNewsBoard", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func fail(_ error: Error) {
        let message = ContextSecretContentPolicy.redactedFragment(error.localizedDescription)
        if storageFailure != message {
            FileHandle.standardError.write(Data("SenseNewsBoard: \(message)\n".utf8))
        }
        storageFailure = message
        storageNotice = SenseNews(senseID: "sense-news", version: 1, address: "senses:news",
            summary: "Unread news persistence unavailable: \(message) Pending news may be lost after restart. raw view · private news storage is unavailable.", at: Date())
    }
}


/// Errors surface their own words wherever they are shown, never
/// "SenseFailure error 1".
extension SenseFailure: LocalizedError {
    public var errorDescription: String? { message.isEmpty ? code : message }
}
