// Narrow launch-time composition over canonical Swift runtime owners.

import Foundation
import NativeAgentCore
import BackgroundLoops
import DoctorChecks
import MemoryV2
import NotificationInbox
import PersistenceCore
import Privacy

// MARK: - BackgroundLoopsManager
//
// App-side composition facade. Core's BackgroundLoopsManager is the sole
// lifecycle, execution, and status owner; this type only assembles app-bound
// dependencies and adapts the existing NativeAgentApp call surface.

public actor BackgroundLoopsManager {
    public static let shared = BackgroundLoopsManager()

    nonisolated let coreManager: BackgroundLoops.BackgroundLoopsManager
    private let assembleLoops: @Sendable () -> [any LoopRunner]
    private let replacementLoop: @Sendable (String) -> (any LoopRunner)?
    private var assembledLoopIntervals: [String: TimeInterval] = [:]
    private let runAutoDoctorAtLaunch: @Sendable () -> Bool
    private let runHeartbeatAtLaunch: @Sendable () -> Bool

    public struct LoopStatus: Sendable, Equatable {
        public let loopId: String
        public let lastRun: Date?
        public let nextRun: Date?
        public let runCount: Int
        public let lastError: String?
        public let running: Bool
        public let executing: Bool
        public let executionStartedAt: Date?
        public let executionTimeout: TimeInterval
        public let eventListener: BackgroundLoops.LoopEventListenerHealth?

        init(_ status: BackgroundLoops.LoopStatus) {
            loopId = status.name
            lastRun = status.lastRun
            nextRun = status.nextRun
            runCount = status.runCount
            lastError = status.lastError
            running = status.running
            executing = status.executing
            executionStartedAt = status.executionStartedAt
            executionTimeout = status.executionTimeout
            eventListener = status.eventListener
        }
    }

    init(
        coreManager: BackgroundLoops.BackgroundLoopsManager = .shared,
        assembleLoops: @escaping @Sendable () -> [any LoopRunner] = {
            BackgroundLoopsAssembly.assembleAllLoops()
        },
        replacementLoop: @escaping @Sendable (String) -> (any LoopRunner)? = { id in
            switch id {
            // C8: config removed → fall back to the visible placeholder, not
            // to nil. Returning nil UNREGISTERS the lane, which is the exact
            // silent disappearance the placeholder exists to prevent.
            case "telegram_poll":
                return BackgroundLoopsAssembly.makeTelegramPollLoopIfConfigured()
                    ?? BackgroundLoopsAssembly.unconfiguredLanePlaceholder(
                        loopId: "telegram_poll",
                        reason: BackgroundLoopsAssembly.telegramUnconfiguredReason
                    )
            case "slack_socket_mode":
                return BackgroundLoopsAssembly.makeSlackSocketModeLoopIfConfigured()
                    ?? BackgroundLoopsAssembly.unconfiguredLanePlaceholder(
                        loopId: "slack_socket_mode",
                        reason: BackgroundLoopsAssembly.slackUnconfiguredReason
                    )
            case "doctor_auto_run":
                return BackgroundLoopsAssembly.makeAutoDoctorLoop()
            default:
                return nil
            }
        },
        runAutoDoctorAtLaunch: @escaping @Sendable () -> Bool = {
            let config = NativeClient.readAutoDoctorConfig(dataRoot: PersistenceCore.defaultDataRoot())
            return (config.enabled ?? true) && (config.runOnStartup ?? true)
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
        for loop in loops {
            assembledLoopIntervals[loop.loopId] = loop.interval
        }
        // A4.2/A4.8: install the failure push before starting so an early
        // failure streak knocks. Idempotent — the scheduler just re-stores the
        // closure. The scheduler owns the gating (2 consecutive failures +
        // 6h cooldown); this closure only files the card and (for
        // attention-worthy severity) the push.
        await coreManager.setFailureTransitionPush { loopId, error in
            await BackgroundLoopsManager.fileLoopFailureNotice(
                dataRoot: PersistenceCore.defaultDataRoot(), loopId: loopId, error: error)
        }
        await coreManager.setFailureRecoveryPush { loopId, healthyAt in
            await BackgroundLoopsManager.resolveLoopFailureNotice(
                dataRoot: PersistenceCore.defaultDataRoot(),
                loopId: loopId,
                healthyAt: healthyAt
            )
        }
        let didStart = await coreManager.start(loops: loops)
        guard didStart else { return }
        Task { await NativeClient().wakeDoctorForPendingTransitions() }
        // Heartbeat's periodic cadence is intentionally low-noise (twice
        // daily), but the status receipt should refresh after app restart.
        // Run a best-effort one-shot off the actor path so an anomalous
        // heartbeat's wording LLM cannot block startup.
        if runHeartbeatAtLaunch() {
            Task { await coreManager.runTickOnce(loopId: "heartbeat") }
        }
        // Doctor repairs at launch (and on any ok→adverse reading, see
        // getHealthCard) besides its weekly sweep. Route the one-shot through
        // Core's existing single-flight owner instead of changing every
        // scheduler loop to tick immediately.
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
        // User, 2026-10-07: what is wrong in plain words and the fix that fits
        // it — the raw error stays in the receipt and on Doctor's loop row.
        let summary = "\(loopId) keeps failing (\(loopFailureCause(error))). "
            + loopFailureRemedy(loopId: loopId, error: error)
        // W1(c) upgrade campaign (L4-01): the card is sticky. A dismissed
        // card for the SAME failing condition stays dismissed and never
        // re-pushes; a genuinely NEW error class resurrects it. The signature
        // is the error head, not the full text (timestamps/addresses churn).
        let errorSignature = String(error.prefix(200))
        let card: JSONValue = .object([
            "id": .string(cardId),
            "created_at": .string(now),
            "source": .string("background_loop"),
            "severity": .string("actionable"),
            "title": .string("\(loopId) keeps failing"),
            "summary": .string(summary),
            "detail": .string(summary),
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
                    let wasAutomaticallyResolved = obj["resolved_reason"]
                        == .string("loop_recovered")
                    if signatureMatches, !wasAutomaticallyResolved,
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
                title: "\(loopId) keeps failing",
                summary: summary,
                source: "background_loop",
                severity: "actionable"
            )
        } catch {
            FileHandle.standardError.write(Data(
                "BackgroundLoopsManager: loop-failure notice upsert failed for \(loopId): \(error)\n".utf8))
        }
    }

    /// The error as one plain clause: the human text out of an NSError dump
    /// (`Error Domain=X Code=N "text" UserInfo={…}`, quotes escaped or not),
    /// first line, redacted.
    nonisolated static func loopFailureCause(_ error: String) -> String {
        if isTelegramTokenRejected(error) { return "Telegram rejected the bot token" }
        var text = NativeAppSecretRedactor.redactText(error)
        if let match = text.range(of: #"Code=-?\d+ \\?"[^"\\]+"#, options: .regularExpression),
           let quote = text[match].firstIndex(of: "\"") {
            text = String(text[text.index(after: quote)..<match.upperBound])
        }
        text = text.components(separatedBy: " UserInfo=")[0]
            .components(separatedBy: .newlines)[0]
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        if text.hasPrefix("timeout after ") {
            return "a run did not finish within its \(text.dropFirst("timeout after ".count)) limit"
        }
        return text.isEmpty ? "it reported no reason" : String(text.prefix(160))
    }

    /// Telegram answers a bad bot token with 401, which the poll reports as
    /// `TelegramBotError.notConfigured` ("Telegram long poll: notConfigured").
    nonisolated static func isTelegramTokenRejected(_ error: String) -> Bool {
        error.lowercased().contains("telegram") && error.contains("notConfigured")
    }

    /// Only fixes that are real. Network weather never reaches the card (the
    /// scheduler drops it).
    nonisolated static func loopFailureRemedy(loopId: String, error: String) -> String {
        loopSettingFix(loopId: loopId, error: error)?.step ?? "No setting fixes this; it needs a code fix."
    }

    /// The setting that fixes a loop's failure, and whether it is a sign-in or
    /// a permission; nil when no setting does. The failure card and Doctor's
    /// loop row both read it, so they never disagree.
    nonisolated static func loopSettingFix(loopId: String, error: String) -> (step: String, ask: DoctorAskKind?)? {
        let e = error.lowercased()
        if loopId == "offdisk_backup", e.contains("icloud drive") { return (DoctorLoopHealth.iCloudDriveStep, .permission) }
        if loopId == "telegram_poll", isTelegramTokenRejected(error) || e.contains("unauthoriz") || e.contains("token") {
            return ("Open Connectors → Telegram and reconnect the bot token.", .signIn)
        }
        if loopId == "slack_socket_mode", e.contains("auth") || e.contains("token") {
            return ("Open Connectors → Slack and reconnect the workspace token.", .signIn)
        }
        if e.contains("no space left") { return ("Free disk space on this Mac.", nil) }
        return nil
    }

    /// A real healthy tick retires the matching failure card. Automatic
    /// resolution is marked so a later recurrence of the same error resurfaces;
    /// a user-dismissed/archived card keeps the user's sticky decision.
    @discardableResult
    nonisolated static func resolveLoopFailureNotice(
        dataRoot: URL,
        loopId: String,
        healthyAt: Date,
        now: Date = Date()
    ) async -> Bool {
        let inbox = LiveNotificationInbox.live(dataRoot: dataRoot)
        let stamp = ISO8601DateFormatter().string(from: now)
        do {
            _ = try await inbox.archiveActive(
                ids: ["loop-failure:\(loopId)"],
                readAt: stamp,
                createdNoLaterThan: healthyAt,
                metadata: [
                    "resolved_reason": .string("loop_recovered"),
                    "resolved_at": .string(stamp),
                    "resolved_health_at": .string(ISO8601DateFormatter().string(from: healthyAt)),
                ]
            )
            return true
        } catch {
            FileHandle.standardError.write(Data(
                "BackgroundLoopsManager: loop-failure recovery failed for \(loopId): \(error)\n".utf8
            ))
            return false
        }
    }

    public func stop() async {
        await coreManager.stop()
    }

    public func shutdown() async {
        await coreManager.shutdown()
    }

    public func status() async -> [LoopStatus] {
        await coreManager.status().map(LoopStatus.init)
    }

    func assembledLoopIntervalsSnapshot() -> [String: TimeInterval] {
        assembledLoopIntervals
    }

    public func isRunning() async -> Bool {
        await coreManager.isRunning()
    }

    public func uptimeSeconds(now: Date = Date()) async -> Double {
        await coreManager.uptimeSeconds(now: now)
    }

    /// Explicit one-tick trigger. Core coalesces this request with an in-flight
    /// periodic tick of the same id; manual execution may start the manifest.
    @discardableResult
    public func runTickOnce(loopId: String) async -> LoopTickOutcome {
        if !(await coreManager.isRunning(loopId: loopId)) {
            await start(loops: assembleLoops())
        }
        return await coreManager.runTickOnce(loopId: loopId)
    }

    /// Due-aware wake used by AppKit's background activity scheduler. Unlike
    /// `runTickOnce`, this never force-runs an early weekly loop; Core reads the
    /// same durable cadence that drives its periodic registration and then
    /// coalesces any race through the same per-loop execution gate.
    /// Launch owns automatic startup. An early/late OS callback must not
    /// assemble a new manifest or restart a manager that teardown stopped.
    @discardableResult
    public func runTickIfDue(loopId: String) async -> LoopTickOutcome {
        await coreManager.runTickIfDue(loopId: loopId)
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

/// Unambiguous app-composition name for clients that also import the core
/// `BackgroundLoops` module, whose manager intentionally has the same base name.
typealias NativeAppBackgroundLoopsManager = BackgroundLoopsManager

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
    private let dataRootOverride: URL?
    private let indexClientOverride: (any SpotlightIndexClient)?

    private init() {
        dataRootOverride = nil
        indexClientOverride = nil
    }

    /// Hermetic seam for the launch projection's exact durable behavior. The
    /// mounted app uses `shared`; an injected root never touches the user's
    /// Spotlight domain.
    init(dataRoot: URL, indexClient: any SpotlightIndexClient) {
        dataRootOverride = dataRoot
        indexClientOverride = indexClient
    }

    /// Read every active memory through SwiftNativeMemoryV2.shared and push
    /// CSSearchableItems to the system Spotlight index. The sentinel is
    /// written only after success, so a crash retries on the next launch.
    public func reindexAll() async {
        if didReindex { return }
        let dataRoot = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let marker = dataRoot
            .appendingPathComponent("memory")
            .appendingPathComponent(".spotlight_reindexed")
        let storage: MemoryStorage
        do {
            storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
        } catch {
            return
        }
        let generation: String
        do {
            generation = try await storage.projectionGenerationFingerprint()
        } catch {
            return
        }
        if let markerData = try? Data(contentsOf: marker),
           String(data: markerData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) == generation {
            didReindex = true
            return
        }
        let memories: [StoredMemory]
        do {
            memories = try await storage.listMemories(persona: nil, status: "active", limit: nil)
        } catch {
            return
        }
        #if canImport(CoreSpotlight) && !os(Linux)
        let defaultClient: any SpotlightIndexClient = SystemSpotlightIndexClient()
        #else
        let defaultClient: any SpotlightIndexClient = MockSpotlightIndexClient()
        #endif
        let client = indexClientOverride ?? defaultClient
        let indexer = SwiftNativeMemoryIndexer(client: client)
        let batch = memories
            .filter { !$0.id.hasPrefix(SwiftNativeMemoryV2.skillPointerIDPrefix) }
            .map { (id: $0.id, text: $0.content, kind: $0.status as String?) }
        do {
            // A generation mismatch is a reconciliation, not an additive
            // refresh. Clear the derived domain first so deleted canonical rows
            // cannot survive forever behind an old one-shot marker.
            try await indexer.removeAll()
            try await indexer.indexBatch(batch)
            let completedGeneration = try await storage.projectionGenerationFingerprint()
            guard completedGeneration == generation else {
                // Canonical memory moved during the rebuild. Leave the old
                // marker untouched so the next launch retries from truth.
                return
            }
        } catch {
            return
        }
        do {
            try SwiftNativePersistenceCore.writeDataAtomicDurable(
                Data((generation + "\n").utf8),
                to: marker
            )
            didReindex = true
        } catch {
            // Index is usable, but no durable generation proof means restart
            // must reconcile again rather than trust an uncertain projection.
        }
    }
}

// MARK: - UserMDGenerator convenience

extension UserMDGenerator {
    /// Zero-arg shorthand the launch hook uses.
    public func regenerate() async throws -> URL {
        try await self.regenerate(persona: MemoryV2Defaults.personaID)
    }
}
