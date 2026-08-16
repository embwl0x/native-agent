import Foundation
import Darwin
import NativeAgentCore
import ChatOrchestration
import PersistenceCore
import TrustCenter

// Wave B — the bounded work session (H5, M6).
//
// A session runs exactly ONE turn through the normal chat orchestration on the
// "workshop" surface, behind the WorkshopToolProfile membrane. Two hard
// properties:
//
//  * H5 (unforgeable trigger): the ONLY authorization a session accepts is a
//    triggerSource of the exact shape "workshop:<handle>:<reservationId>" whose
//    reservationId is a REAL reservation on that pursuit in the Desk store. A
//    chat turn cannot set that (it is minted by the pump against a durable
//    reservation, SwiftNativeDeskStore.reserveWorkSession) — an absent/forged/stale
//    reservation refuses BEFORE any LLM call.
//  * M6 (no infinite wedge): the turn runs under a FINITE deadline. Contrast
//    Executions+Executor.swift:154, where the approval-wait timeout is disabled by
//    default and a blocked execution can freeze forever. A workshop session that
//    can't finish (a wedged tool, a needs-User outward step) resolves to a finite
//    `blocked` receipt within the deadline — in-flight, then done, never stuck.

public enum WorkshopSessionStatus: String, Sendable, Equatable {
    case completed   // ran and produced output
    case blocked     // ran but hit the deadline / needs User — finite, not a wedge
    case refused     // authorization/reservation failed — no LLM was called
}

/// What the pump hands a session: the item and the pump's reservation proof.
public struct WorkshopSessionRequest: Sendable, Equatable {
    public let handle: String
    public let reservationId: String
    /// "workshop:<handle>:<reservationId>" — the sole authorization token.
    public let triggerSource: String
    public let title: String
    /// The bounded work prompt (item title/why/doneLooksLike) — no persona bytes.
    public let promptSeed: String

    // Internal on purpose: only the app-owned pump can mint a workshop run.
    // Chat tools and other modules can observe reservation ids, but cannot
    // construct an executable request from that data.
    init(handle: String, reservationId: String, title: String, promptSeed: String) {
        self.handle = handle
        self.reservationId = reservationId
        self.triggerSource = WorkshopSessionRequest.makeTriggerSource(handle: handle, reservationId: reservationId)
        self.title = title
        self.promptSeed = promptSeed
    }

    static func makeTriggerSource(handle: String, reservationId: String) -> String {
        "workshop:\(handle):\(reservationId)"
    }
}

/// A session's honest outcome, keyed by (handle, reservationId) for the M8
/// receipt log. Compact — never the O(all executions) scoreboard.
public struct WorkshopSessionReceipt: Sendable, Equatable {
    public let handle: String
    public let reservationId: String
    public let status: WorkshopSessionStatus
    public let summary: String
    public let model: String?
    public let artifactPaths: [String]
    public let generatedAt: Date
    public let disposition: DeskWorkDisposition

    public init(
        handle: String, reservationId: String, status: WorkshopSessionStatus,
        summary: String, model: String?, artifactPaths: [String], generatedAt: Date,
        disposition: DeskWorkDisposition = .progress
    ) {
        self.handle = handle
        self.reservationId = reservationId
        self.status = status
        self.summary = summary
        self.model = model
        self.artifactPaths = artifactPaths
        self.generatedAt = generatedAt
        self.disposition = disposition
    }
}

public protocol WorkshopSessionRunning: Sendable {
    func run(_ request: WorkshopSessionRequest) async -> WorkshopSessionReceipt
}

public struct WorkshopSession: WorkshopSessionRunning {
    let dataRoot: URL
    let store: SwiftNativeDeskStore
    /// Hard per-session deadline (M6). Kept modest — one short conversation of
    /// tokens, honest and bounded.
    let deadlineSeconds: TimeInterval
    let now: @Sendable () -> Date
    let claimStore: WorkshopReservationClaimStore
    /// Executes the actual turn against the membrane. nil → the production path
    /// (runEphemeralToolTurn on surface "workshop"). Injectable so tests can
    /// prove the deadline/authorization behavior without a provider call.
    let turnExecutor: (@Sendable (_ request: WorkshopSessionRequest, _ tools: any ToolDispatchClient) async throws -> (model: String, output: String))?

    public init(
        dataRoot: URL,
        store: SwiftNativeDeskStore,
        deadlineSeconds: TimeInterval = 600,
        now: @escaping @Sendable () -> Date = { Date() },
        turnExecutor: (@Sendable (_ request: WorkshopSessionRequest, _ tools: any ToolDispatchClient) async throws -> (model: String, output: String))? = nil
    ) {
        self.dataRoot = dataRoot
        self.store = store
        self.deadlineSeconds = deadlineSeconds
        self.now = now
        self.claimStore = WorkshopReservationClaimStore(dataRoot: dataRoot)
        self.turnExecutor = turnExecutor
    }

    public func run(_ request: WorkshopSessionRequest) async -> WorkshopSessionReceipt {
        let resultStore = WorkshopSessionResultStore(dataRoot: dataRoot)
        // ---- H5: authorization is the triggerSource, and nothing else. ----
        let expected = WorkshopSessionRequest.makeTriggerSource(
            handle: request.handle, reservationId: request.reservationId)
        guard !request.handle.isEmpty,
              !request.reservationId.isEmpty,
              request.triggerSource == expected else {
            return refused("malformed triggerSource — not authorized", request)
        }
        // The reservation must actually exist on the pursuit in the store. A
        // forged or stale reservationId has no matching row → refuse, no LLM.
        guard let state = try? await store.liveState(),
              let item = state.items.first(where: { $0.handle == request.handle }),
              WorkshopPump.hasLiveAttempt(request.reservationId, on: item) else {
            return refused("no live reservation \(request.reservationId) on \(request.handle)", request)
        }

        if resultStore.hasClaim(reservationId: request.reservationId),
           let durable = resultStore.load(reservationId: request.reservationId),
           durable.handle == request.handle {
            return durable
        }

        // A reservation authorizes at most one execution attempt. The claim is
        // an O_EXCL + fsync marker, so concurrent/replayed session runners and
        // app restarts cannot reuse the same visible reservation id. A crash
        // after the claim consumes the slot (fail closed) rather than risking a
        // second unattended provider run.
        guard claimStore.claim(handle: request.handle, reservationId: request.reservationId) else {
            return refused("reservation already claimed or claim could not be made durable", request)
        }

        // Re-read after the atomic claim. If another owner completed/closed the
        // reservation during the first read, keep the claim consumed and refuse
        // before constructing the provider client.
        guard let claimedState = try? await store.liveState(),
              let claimedItem = claimedState.items.first(where: { $0.handle == request.handle }),
              WorkshopPump.hasLiveAttempt(request.reservationId, on: claimedItem) else {
            return refused("reservation became stale before execution", request)
        }

        // ---- Build the membrane and run ONE bounded turn (H1/L12 + M6). ----
        let collector = WorkshopArtifactCollector()
        let progressCollector = WorkshopProgressCollector()
        let profile = WorkshopToolProfile(
            inner: SwiftToolDispatcher(
                dataRoot: dataRoot,
                allowProcessGlobalTools: dataRoot == PersistenceCore.defaultDataRoot()
            ),
            artifactWriter: WorkshopArtifactWriter(dataRoot: dataRoot, handle: request.handle),
            collector: collector,
            progressCollector: progressCollector
        )
        let executor = turnExecutor ?? Self.productionTurnExecutor(dataRoot: dataRoot)

        let outcome = await runWithDeadline(request: request, tools: profile, executor: executor)
        let artifacts = await collector.written()
        let progress = await progressCollector.latest()

        let receipt: WorkshopSessionReceipt
        switch outcome {
        case .done(let model, let output):
            let requested = progress?.disposition ?? .progress
            // A typed completion without a durable artifact is not enough to
            // close a large project. Keep it as progress; Pump re-verifies the
            // handle-scoped paths again at the owner CAS boundary.
            let disposition: DeskWorkDisposition = requested == .goalSatisfied && artifacts.isEmpty
                ? .progress
                : requested
            receipt = WorkshopSessionReceipt(
                handle: request.handle, reservationId: request.reservationId,
                status: .completed, summary: progress?.summary ?? Self.trimSummary(output),
                model: model, artifactPaths: artifacts, generatedAt: now(), disposition: disposition)
        case .timedOut:
            // Finite needs-User state — the anti-wedge (M6).
            receipt = WorkshopSessionReceipt(
                handle: request.handle, reservationId: request.reservationId,
                status: .blocked, summary: "session exceeded the \(Int(deadlineSeconds))s deadline; left in-flight for the user",
                model: nil, artifactPaths: artifacts, generatedAt: now(), disposition: .blocked)
        case .failed(let reason):
            receipt = WorkshopSessionReceipt(
                handle: request.handle, reservationId: request.reservationId,
                status: .blocked, summary: "session could not finish: \(Self.trimSummary(reason))",
                model: nil, artifactPaths: artifacts, generatedAt: now(), disposition: .blocked)
        }
        // Terminal result is durable before control returns to the pump. If the
        // app exits between here and Desk settlement, startup reconciliation
        // can finish the exact same attempt without another provider turn.
        _ = resultStore.save(receipt)
        return receipt
    }

    private func refused(_ why: String, _ request: WorkshopSessionRequest) -> WorkshopSessionReceipt {
        WorkshopSessionReceipt(
            handle: request.handle, reservationId: request.reservationId,
            status: .refused, summary: why, model: nil, artifactPaths: [], generatedAt: now(), disposition: .blocked)
    }

    private enum TurnOutcome { case done(model: String, output: String); case timedOut; case failed(String) }

    /// Race the turn against the deadline. Whichever finishes first wins; the
    /// loser is cancelled. This is the finite bound M6 requires.
    private func runWithDeadline(
        request: WorkshopSessionRequest,
        tools: any ToolDispatchClient,
        executor: @escaping @Sendable (_ request: WorkshopSessionRequest, _ tools: any ToolDispatchClient) async throws -> (model: String, output: String)
    ) async -> TurnOutcome {
        let deadlineNanos = UInt64(max(0.001, deadlineSeconds) * 1_000_000_000)
        return await withTaskGroup(of: TurnOutcome.self) { group in
            group.addTask {
                do {
                    let (model, output) = try await executor(request, tools)
                    return .done(model: model, output: output)
                } catch {
                    return .failed(String(describing: error))
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: deadlineNanos)
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
    }

    /// The production turn: one ephemeral, read-only tool turn on the
    /// "workshop" surface (P2-3; "missions" on 0.3.x installs).
    /// surface. No chat session state, no transcript, her pinned model resolves
    /// from the surface picker. The membrane governs writes.
    static func productionTurnExecutor(
        dataRoot: URL
    ) -> @Sendable (_ request: WorkshopSessionRequest, _ tools: any ToolDispatchClient) async throws -> (model: String, output: String) {
        let usesLiveAppBody = dataRoot == PersistenceCore.defaultDataRoot()
        return { request, tools in
            let cognition = usesLiveAppBody ? NativeCognitionRuntime.shared : nil
            let client = makeChatOrchestrationClient(
                tools: tools,
                dataRoot: dataRoot,
                cognitiveObserver: cognition,
                cognitiveContextProvider: cognition,
                providerLifecycleObserver: cognition,
                contextFlow: usesLiveAppBody ? NativeContextFlowRuntime.shared : nil,
                memoryAtomTranslator: usesLiveAppBody
                    ? NativeContextFlowRuntime.memoryRecordAtomID(forRecordID:)
                    : nil
            )
            let response = try await client.runEphemeralToolTurn(
                message: request.promptSeed,
                fileAccess: "read_only",
                autonomyResolver: WorkshopAutonomyResolver(
                    base: SwiftNativeTrustCenter(dataRoot: dataRoot)
                ),
                surface: WorkshopSurfaceVocabulary.canonical
            )
            return (response.model, response.output)
        }
    }

    static func trimSummary(_ s: String) -> String {
        let clean = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.count <= 600 ? clean : String(clean.prefix(600)) + "…"
    }
}

/// Durable terminal handoff between the one-turn runner and Desk settlement.
/// It is a reconciliation record, not a second task owner: Desk remains the
/// visible/canonical lifecycle and this file is deleted only by retention.
struct WorkshopSessionResultStore: Sendable {
    let dataRoot: URL

    private var directory: URL {
        dataRoot.appendingPathComponent("workshop/session_results", isDirectory: true)
    }

    func path(reservationId: String) -> URL? {
        guard let safe = try? WorkshopArtifactWriter.validateSafeComponent(reservationId) else { return nil }
        return directory.appendingPathComponent("\(safe).json")
    }

    func save(_ receipt: WorkshopSessionReceipt) -> Bool {
        guard let path = path(reservationId: receipt.reservationId) else { return false }
        let row: JSONValue = .object([
            "version": .int(1),
            "handle": .string(receipt.handle),
            "reservationId": .string(receipt.reservationId),
            "status": .string(receipt.status.rawValue),
            "summary": .string(String(receipt.summary.prefix(600))),
            "model": receipt.model.map(JSONValue.string) ?? .null,
            "artifactPaths": .array(receipt.artifactPaths.map(JSONValue.string)),
            "disposition": .string(receipt.disposition.rawValue),
            "generatedAt": .string(Self.formatISO(receipt.generatedAt)),
        ])
        do {
            let data = try row.serializedData(pretty: false)
            try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: path)
            return true
        } catch {
            NSLog("[workshop] terminal result durability failed for %@: %@",
                  receipt.reservationId, String(describing: error))
            return false
        }
    }

    func load(reservationId: String) -> WorkshopSessionReceipt? {
        guard let path = path(reservationId: reservationId),
              let data = try? Data(contentsOf: path),
              let value = try? JSONValue.parse(data),
              case .object(let object) = value,
              case .string(let handle)? = object["handle"],
              case .string(let storedID)? = object["reservationId"], storedID == reservationId,
              case .string(let statusRaw)? = object["status"],
              let status = WorkshopSessionStatus(rawValue: statusRaw),
              case .string(let summary)? = object["summary"],
              case .string(let generatedRaw)? = object["generatedAt"],
              let generatedAt = Self.parseISO(generatedRaw) else { return nil }
        let model: String? = if case .string(let value)? = object["model"] { value } else { nil }
        let artifacts: [String] = if case .array(let values)? = object["artifactPaths"] {
            values.compactMap { if case .string(let value) = $0 { value } else { nil } }
        } else { [] }
        let disposition: DeskWorkDisposition = if case .string(let raw)? = object["disposition"] {
            DeskWorkDisposition(rawValue: raw) ?? .progress
        } else { .progress }
        return WorkshopSessionReceipt(
            handle: handle,
            reservationId: reservationId,
            status: status,
            summary: summary,
            model: model,
            artifactPaths: artifacts,
            generatedAt: generatedAt,
            disposition: disposition
        )
    }

    func hasClaim(reservationId: String) -> Bool {
        guard let safe = try? WorkshopArtifactWriter.validateSafeComponent(reservationId) else { return false }
        return FileManager.default.fileExists(atPath: dataRoot
            .appendingPathComponent("workshop/reservation_claims/\(safe).claim").path)
    }

    func remove(reservationId: String) {
        guard let path = path(reservationId: reservationId) else { return }
        try? FileManager.default.removeItem(at: path)
    }


    private static func formatISO(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func parseISO(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}

/// Workshop-local autonomy policy. The ordinary SecurityCenter and file-access
/// wrappers remain active; this resolver only prevents the generic chat policy
/// from reclassifying the already-hard-ceilinged profile as an approval lane.
/// A future tool remains denied until it is deliberately added to the profile.
struct WorkshopAutonomyResolver: AutonomyResolver {
    let base: any AutonomyResolver

    func autonomyLevel(forTool toolName: String, surface: String) async throws -> String {
        // Reader seam: a turn may still arrive carrying the 0.3.x `missions`
        // surface. Deny-by-default here means an unfolded spelling would refuse
        // every Workshop tool, so fold before the membership test.
        guard WorkshopSurfaceVocabulary.isWorkshopSurface(surface),
              WorkshopToolProfile.isPermitted(toolName) else {
            return "deny"
        }
        // These three capabilities are implemented entirely inside the
        // handle-scoped Workshop profile. They never reach the generic
        // dispatcher, so an owner policy that quite correctly denies unknown
        // global tool names must not make the private membrane unusable.
        if [
            WorkshopToolProfile.artifactToolName,
            WorkshopToolProfile.artifactReadToolName,
            WorkshopToolProfile.progressToolName,
        ].contains(toolName) {
            return "auto"
        }
        let ownerPolicy = try await base.autonomyLevel(forTool: toolName, surface: surface)
        if ownerPolicy == "deny" || ownerPolicy == "blocked" {
            return ownerPolicy
        }
        return "auto"
    }
}

/// Cross-process, one-shot authorization claim for a Desk work reservation.
/// The file's existence is the authorization ledger: creation is atomic and
/// its payload is fsync'd before the LLM boundary. Malformed/pre-existing files
/// fail closed because O_EXCL refuses to replace them.
struct WorkshopReservationClaimStore: Sendable {
    let dataRoot: URL

    func claim(handle: String, reservationId: String) -> Bool {
        guard let safeReservation = try? WorkshopArtifactWriter.validateSafeComponent(reservationId),
              let safeHandle = try? WorkshopArtifactWriter.validateSafeComponent(handle) else {
            return false
        }

        // Anchor the authorization ledger at dataRoot and walk every parent by
        // descriptor. A path-based createDirectory/open pair could follow a
        // swapped `workshop/` symlink and mint the one-shot claim outside the
        // Workshop state root. O_NOFOLLOW at every level closes that escape and
        // the open descriptors remove the resolve-then-write race.
        let dataFD = Darwin.open(
            dataRoot.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard dataFD >= 0 else { return false }
        defer { Darwin.close(dataFD) }
        guard let workshopFD = try? WorkshopArtifactWriter.openDirectoryComponent(
            "workshop", parentFD: dataFD, create: true
        ) else { return false }
        defer { Darwin.close(workshopFD) }
        guard let claimsFD = try? WorkshopArtifactWriter.openDirectoryComponent(
            "reservation_claims", parentFD: workshopFD, create: true
        ) else { return false }
        defer { Darwin.close(claimsFD) }

        let claimName = "\(safeReservation).claim"
        let fd = claimName.withCString { name in
            Darwin.openat(
                claimsFD,
                name,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o600
            )
        }
        guard fd >= 0 else { return false }
        var open = true
        defer { if open { Darwin.close(fd) } }

        let row: JSONValue = .object([
            "handle": .string(safeHandle),
            "reservationId": .string(safeReservation),
            "claimedAt": .string(ISO8601DateFormatter().string(from: Date())),
        ])
        guard var payload = try? row.serialize(pretty: false) else { return false }
        payload += "\n"
        let bytes = Data(payload.utf8)
        do {
            try bytes.withUnsafeBytes { raw in
                guard var pointer = raw.baseAddress else { return }
                var remaining = raw.count
                while remaining > 0 {
                    let count = Darwin.write(fd, pointer, remaining)
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw NSError(domain: "WorkshopReservationClaim", code: Int(errno))
                    }
                    pointer = pointer.advanced(by: count)
                    remaining -= count
                }
            }
            guard Darwin.fsync(fd) == 0, Darwin.close(fd) == 0 else { return false }
            open = false
            // Persist the claim entry and both possibly-new parent directory
            // entries before authorizing provider work. A crash may consume a
            // slot, but it must never erase the claim and permit replay.
            return Darwin.fsync(claimsFD) == 0
                && Darwin.fsync(workshopFD) == 0
                && Darwin.fsync(dataFD) == 0
        } catch {
            return false
        }
    }
}
