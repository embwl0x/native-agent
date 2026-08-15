// Narrow launch-time composition over canonical Swift runtime owners.

import Foundation
import NativeAgentCore
import BackgroundLoops
import MemoryV2
import PersistenceCore

// MARK: - BackgroundLoopsManager
//
// App-side composition facade. Core's BackgroundLoopsManager is the sole
// lifecycle, execution, and status owner; this type only assembles app-bound
// dependencies and adapts the existing NativeAgentApp call surface.

public actor BackgroundLoopsManager {
    public static let shared = BackgroundLoopsManager()

    private let coreManager: BackgroundLoops.BackgroundLoopsManager
    private let assembleLoops: @Sendable () -> [any LoopRunner]
    private let replacementLoop: @Sendable (String) -> (any LoopRunner)?
    private let runAutoDoctorAtLaunch: @Sendable () -> Bool
    private let runHeartbeatAtLaunch: @Sendable () -> Bool

    public struct LoopStatus: Sendable, Equatable {
        public let loopId: String
        public let running: Bool
    }

    init(
        coreManager: BackgroundLoops.BackgroundLoopsManager = .shared,
        assembleLoops: @escaping @Sendable () -> [any LoopRunner] = {
            BackgroundLoopsAssembly.assembleAllLoops()
        },
        replacementLoop: @escaping @Sendable (String) -> (any LoopRunner)? = { id in
            switch id {
            case "telegram_poll":
                return BackgroundLoopsAssembly.makeTelegramPollLoopIfConfigured()
            case "slack_socket_mode":
                return BackgroundLoopsAssembly.makeSlackSocketModeLoopIfConfigured()
            case "doctor_auto_run":
                return BackgroundLoopsAssembly.makeAutoDoctorLoop()
            default:
                return nil
            }
        },
        runAutoDoctorAtLaunch: @escaping @Sendable () -> Bool = {
            let config = NativeClient.readAutoDoctorConfig(dataRoot: PersistenceCore.defaultDataRoot())
            return (config.enabled ?? true) && (config.runOnStartup ?? false)
        },
        // A4.8a: injectable so tests can suppress the fire-and-forget launch
        // heartbeat tick below — its unstructured Task raced the ownership
        // tests' status() reads (gate runCount moved between two reads →
        // ~1-in-3 failures on an identical tree). Prod default stays true.
        runHeartbeatAtLaunch: @escaping @Sendable () -> Bool = { true }
    ) {
        self.coreManager = coreManager
        self.assembleLoops = assembleLoops
        self.replacementLoop = replacementLoop
        self.runAutoDoctorAtLaunch = runAutoDoctorAtLaunch
        self.runHeartbeatAtLaunch = runHeartbeatAtLaunch
    }

    public func start() async {
        guard !(await coreManager.isRunning()) else { return }
        await start(loops: assembleLoops())
    }

    public func start(loops: [any LoopRunner]) async {
        // A4.2/A4.8: install the failure push before starting so an early
        // failure streak knocks. Idempotent — the scheduler just re-stores the
        // closure. The scheduler owns the gating (2 consecutive failures +
        // 6h cooldown); this closure only files the card and (for
        // attention-worthy severity) the push.
        await coreManager.setFailureTransitionPush { loopId, error in
            await BackgroundLoopsManager.fileLoopFailureNotice(
                dataRoot: PersistenceCore.defaultDataRoot(), loopId: loopId, error: error)
        }
        let didStart = await coreManager.start(loops: loops)
        guard didStart else { return }
        // Heartbeat's periodic cadence is intentionally low-noise (twice
        // daily), but the status receipt should refresh after app restart.
        // Run a best-effort one-shot off the actor path so an anomalous
        // heartbeat's wording LLM cannot block startup.
        if runHeartbeatAtLaunch() {
            Task { await coreManager.runTickOnce(loopId: "heartbeat") }
        }
        // Auto-Doctor remains weekly and disabled-at-launch by default. When
        // the user explicitly enables the saved launch affordance, route the
        // one-shot through Core's existing single-flight owner instead of
        // changing every scheduler loop to tick immediately.
        if runAutoDoctorAtLaunch() {
            Task { await coreManager.runTickOnce(loopId: "doctor_auto_run") }
        }
    }

    /// A4.2: upsert ONE stable inbox card per loop (id `loop-failure:<loopId>`,
    /// so repeated failures update the same card, never pile up) and fire the
    /// paired-device push for it. Called only on the scheduler's cooldown-gated
    /// ok→fail transition. Mirrors `fileDiskHygieneNotice`'s upsert shape. The
    /// durable failure receipt is written separately by the scheduler — this is
    /// purely the surfacing lane the receipt-only path was missing.
    nonisolated static func fileLoopFailureNotice(
        dataRoot: URL, loopId: String, error: String
    ) async {
        let inboxPath = dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
        let cardId = "loop-failure:\(loopId)"
        let now = ISO8601DateFormatter().string(from: Date())
        let summary = "Background loop \"\(loopId)\" started failing."
        // W1(c) upgrade campaign (L4-01): the card is sticky. A dismissed
        // card for the SAME failing condition stays dismissed and never
        // re-pushes; a genuinely NEW error class resurrects it. The signature
        // is the error head, not the full text (timestamps/addresses churn).
        let errorSignature = String(error.prefix(200))
        let detail = "The \"\(loopId)\" background loop transitioned from healthy to "
            + "failing. Latest error:\n\n\(String(error.prefix(1_500)))\n\n"
            + "It will keep retrying on its normal cadence; this card updates in place."
        let card: JSONValue = .object([
            "id": .string(cardId),
            "created_at": .string(now),
            "source": .string("background_loop"),
            "severity": .string("actionable"),
            "title": .string("A background loop is failing"),
            "summary": .string(String(summary.prefix(500))),
            "detail": .string(detail),
            "related_mission_id": .null,
            "related_approval_id": .null,
            "related_paths": .array([]),
            "related_groups": .array([]),
            "actions": .array([
                .object(["id": .string("view"), "label": .string("View"),
                         "description": .string("See the loop failure detail")]),
                .object(["id": .string("dismiss"), "label": .string("Dismiss"),
                         "description": .string("Dismiss this card")]),
            ]),
            "error_signature": .string(errorSignature),
            "status": .string("unread"),
            "read_at": .null,
        ])
        let persistence = SwiftNativePersistenceCore()
        do {
            let shouldPush = try await persistence.withFileLock(inboxPath) { () async throws -> Bool in
                let lines = try InboxRewriteGuard.readLines(inboxPath)
                guard InboxRewriteGuard.rewriteIsSafe(lines: lines, path: inboxPath) else {
                    InboxRewriteGuard.refuse("BackgroundLoopsManager[\(loopId)]", path: inboxPath)
                    return false
                }
                var mutated: [Data] = []
                mutated.reserveCapacity(lines.count + 1)
                var found = false
                var pushWorthy = true
                for line in lines {
                    guard case .object(let obj)? = line.row,
                          case .string(let id)? = obj["id"],
                          id == cardId else {
                        // Other rows AND undecodable lines: verbatim.
                        mutated.append(line.raw)
                        continue
                    }
                    var replacement = card
                    // Legacy rows (pre-signature) match when their stored
                    // detail already contains this error head — otherwise
                    // every dismissed pre-patch card would resurrect once
                    // (gpt-5.5 review SHOULD-FIX).
                    let signatureMatches: Bool = {
                        if case .string(let oldSig)? = obj["error_signature"] {
                            return oldSig == errorSignature
                        }
                        if case .string(let oldDetail)? = obj["detail"] {
                            return oldDetail.contains(errorSignature)
                        }
                        return false
                    }()
                    if signatureMatches,
                       case .string(let oldStatus)? = obj["status"],
                       oldStatus != "unread",
                       case .object(var newObj) = card {
                        // Same condition, already seen/dismissed: keep User's
                        // status, refresh only the detail/timestamp, no knock.
                        newObj["status"] = obj["status"] ?? .string("unread")
                        newObj["read_at"] = obj["read_at"] ?? .null
                        replacement = .object(newObj)
                        pushWorthy = false
                    }
                    mutated.append(Data(try replacement.serialize(pretty: false).utf8))
                    found = true
                }
                if !found { mutated.append(Data(try card.serialize(pretty: false).utf8)) }
                try InboxRewriteGuard.writeLines(mutated, to: inboxPath)
                return pushWorthy
            }
            // The scheduler already gated this to one push per transition/6h.
            // W1(c): additionally, a dismissed card whose error signature is
            // unchanged suppresses the knock entirely — User said "seen".
            guard shouldPush else { return }
            await InboxPushNotifier.notifyIfAttentionWorthy(
                dataRoot: dataRoot,
                itemId: cardId,
                title: "A background loop is failing",
                summary: String(summary.prefix(500)),
                source: "background_loop",
                severity: "actionable"
            )
        } catch {
            FileHandle.standardError.write(Data(
                "BackgroundLoopsManager: loop-failure notice upsert failed for \(loopId): \(error)\n".utf8))
        }
    }

    public func stop() async {
        await coreManager.stop()
    }

    public func status() async -> [LoopStatus] {
        await coreManager.status().map {
            LoopStatus(loopId: $0.name, running: $0.running)
        }
    }

    public func isRunning() async -> Bool {
        await coreManager.isRunning()
    }

    public func uptimeSeconds(now: Date = Date()) async -> Double {
        await coreManager.uptimeSeconds(now: now)
    }

    /// One-tick trigger for NSBackgroundActivityScheduler hand-offs. Core
    /// coalesces this request with an in-flight periodic tick of the same id.
    @discardableResult
    public func runTickOnce(loopId: String) async -> LoopTickOutcome {
        if !(await coreManager.isRunning(loopId: loopId)) {
            await start(loops: assembleLoops())
        }
        return await coreManager.runTickOnce(loopId: loopId)
    }

    /// Loop ids this facade can rebuild in place. Everything else is bound to
    /// state captured at assembly time and only re-reads its config on launch.
    static let hotReloadableLoopIDs: Set<String> = [
        "telegram_poll", "slack_socket_mode", "doctor_auto_run",
    ]

    /// Rebuilds one config-bound chat-surface registration. Core cancels and
    /// drains only the requested target before replacement, leaving every
    /// other loop task and status counter intact.
    ///
    /// L4-06 (2026-08-11): this used to return `Bool`, and for any id outside
    /// `hotReloadableLoopIDs` it returned `registered().contains(id)` — i.e.
    /// `true`, "restarted", having done nothing. Callers (and any UI reading
    /// them) reported success while the config change silently waited on an
    /// app relaunch. The tri-state below cannot claim that: a loop that was
    /// not rebuilt reports `.requiresRelaunch`, and an id this manager does
    /// not own at all reports `.unknown`.
    @discardableResult
    public func restartLoop(id: String) async -> LoopRestartOutcome {
        let registered = await coreManager.registered().contains(id)
        guard Self.hotReloadableLoopIDs.contains(id) else {
            return registered ? .requiresRelaunch(loopId: id) : .unknown(loopId: id)
        }
        await coreManager.restartLoop(id: id, newLoop: replacementLoop(id))
        // A hot-reload that leaves the id unregistered did not restart it;
        // saying so is the whole point of this enum.
        return await coreManager.registered().contains(id)
            ? .restarted(loopId: id)
            : .unknown(loopId: id)
    }
}

/// Honest result of `BackgroundLoopsManager.restartLoop(id:)`.
///
/// `.restarted` is the only outcome that means the running loop now reflects
/// the config on disk. `.requiresRelaunch` means the loop is alive but still
/// running its launch-time configuration. `.unknown` means this manager has no
/// such loop registered (or the rebuild left it unregistered) — nothing can be
/// promised about it either way.
public enum LoopRestartOutcome: Sendable, Equatable {
    case restarted(loopId: String)
    case requiresRelaunch(loopId: String)
    case unknown(loopId: String)

    public var didRestart: Bool {
        if case .restarted = self { return true }
        return false
    }

    public var loopId: String {
        switch self {
        case .restarted(let id), .requiresRelaunch(let id), .unknown(let id):
            return id
        }
    }

    /// User-facing sentence for a surface that just asked for a restart.
    /// `nil` when the restart actually happened and there is nothing to say.
    public var surfaceMessage: String? {
        switch self {
        case .restarted:
            return nil
        case .requiresRelaunch(let id):
            return "The \(id) loop keeps its launch-time settings until you relaunch NativeAgent."
        case .unknown(let id):
            return "No running \(id) loop to reconfigure — relaunch NativeAgent to pick up the change."
        }
    }
}

// MARK: - Memory Spotlight launch bootstrap

/// Honest launch-only owner for the one-time Spotlight projection. MemoryV2
/// itself remains canonical; this type owns no memory state and advertises no
/// CloudKit subscription that the runtime cannot actually provide.
public actor MemorySpotlightBootstrap {
    public static let shared = MemorySpotlightBootstrap()
    private var didReindex = false

    private init() {}

    /// Read every active memory through SwiftNativeMemoryV2.shared and push
    /// CSSearchableItems to the system Spotlight index. The sentinel is
    /// written only after success, so a crash retries on the next launch.
    public func reindexAll() async {
        if didReindex { return }
        let marker = PersistenceCore.defaultDataRoot()
            .appendingPathComponent("memory")
            .appendingPathComponent(".spotlight_reindexed")
        if FileManager.default.fileExists(atPath: marker.path) {
            didReindex = true
            return
        }
        guard let bridge = await SwiftNativeMemoryV2.shared.underlyingBridge() else {
            return
        }
        let storage = await bridge.underlyingStorage()
        let memories: [StoredMemory]
        do {
            memories = try await storage.listMemories(persona: nil, status: "active", limit: nil)
        } catch {
            return
        }
        #if canImport(CoreSpotlight) && !os(Linux)
        let client: any SpotlightIndexClient = SystemSpotlightIndexClient()
        #else
        let client: any SpotlightIndexClient = MockSpotlightIndexClient()
        #endif
        let indexer = SwiftNativeMemoryIndexer(client: client)
        let batch = memories.map { (id: $0.id, text: $0.content, kind: $0.status as String?) }
        do {
            try await indexer.indexBatch(batch)
        } catch {
            return
        }
        didReindex = true
        try? FileManager.default.createDirectory(
            at: marker.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: marker.path, contents: Data("ok\n".utf8))
    }
}

// MARK: - UserMDGenerator.shared
//
// MemoryV2+UserMDGen.swift defines the real actor with
// `regenerate(persona:)`. The spec calls `UserMDGenerator.shared.regenerate()`
// with no args, so add a shared instance + zero-arg overload here.

extension UserMDGenerator {
    /// Lazily-built process-wide generator. Throws are swallowed (the
    /// storage open is the only fallible step) — on failure the launch
    /// hook treats regenerate() as a no-op via the wrapping try?.
    public static let shared: UserMDGenerator? = {
        guard let storage = try? MemoryStorage(dataRoot: NativeAgentPaths.dataRoot) else {
            return nil
        }
        return UserMDGenerator(
            storage: storage,
            dataRoot: NativeAgentPaths.dataRoot,
            personaRoot: NativeAgentPaths.personaRoot
        )
    }()

    /// Zero-arg shorthand the launch hook uses.
    public func regenerate() async throws -> URL {
        try await self.regenerate(persona: MemoryV2Defaults.personaID)
    }
}

// MARK: - SelfImprovementOrchestrator integration
//
// F5+F6 cross-merge (2026-06-03): the previous app-local stub shadowed
// Core's real `actor SelfImprovementOrchestrator`, returning [] from
// list_pending() and no-op from runSweepOnce(). The shadow is now
// deleted; Core's actor answers `.shared.runSweepOnce()` directly. The
// snake_case `list_pending()` extension preserves the "What's Running"
// panel call site without forcing it to depend on Core's full
// ImprovementRun shape.

import SelfImprovement

public struct SelfImprovementPendingSummary: Sendable, Equatable {
    public let id: String
    public let objective: String
    public let stage: String
    public init(id: String, objective: String, stage: String) {
        self.id = id
        self.objective = objective
        self.stage = stage
    }
}

public extension SelfImprovementOrchestrator {
    func list_pending() async -> [SelfImprovementPendingSummary] {
        let runs = (try? await listPending()) ?? []
        return runs.map {
            SelfImprovementPendingSummary(
                id: $0.id,
                objective: $0.objective ?? "",
                stage: $0.phase ?? ($0.status ?? "")
            )
        }
    }
}
