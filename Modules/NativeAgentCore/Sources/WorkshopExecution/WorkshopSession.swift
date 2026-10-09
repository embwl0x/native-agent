import Foundation
import ChatTurnContracts
import Darwin
import NativeAgentCore
import PersistenceCore
import Desk
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

public struct WorkshopSession: WorkshopSessionRunning {
    let dataRoot: URL
    let store: SwiftNativeDeskStore
    /// Hard per-session deadline (M6). Kept modest — one short conversation of
    /// tokens, honest and bounded.
    let deadlineSeconds: TimeInterval
    let now: @Sendable () -> Date
    let claimStore: WorkshopReservationClaimStore
    let platform: any WorkshopPumpPlatform
    let effects: any WorkshopSessionEffects
    /// Executes the actual turn against the membrane. nil → the production path
    /// (runEphemeralToolTurn on surface "workshop"). Injectable so tests can
    /// prove the deadline/authorization behavior without a provider call.
    let turnExecutor: (@Sendable (_ request: WorkshopSessionRequest, _ tools: any ToolDispatchClient) async throws -> (model: String, output: String))?

    public init(
        dataRoot: URL,
        store: SwiftNativeDeskStore,
        platform: any WorkshopPumpPlatform,
        effects: any WorkshopSessionEffects,
        deadlineSeconds: TimeInterval = 600,
        now: @escaping @Sendable () -> Date = { Date() },
        turnExecutor: (@Sendable (_ request: WorkshopSessionRequest, _ tools: any ToolDispatchClient) async throws -> (model: String, output: String))? = nil
    ) {
        self.dataRoot = dataRoot
        self.store = store
        self.platform = platform
        self.effects = effects
        self.deadlineSeconds = deadlineSeconds
        self.now = now
        self.claimStore = WorkshopReservationClaimStore(dataRoot: dataRoot)
        self.turnExecutor = turnExecutor
    }

    public func run(_ request: WorkshopSessionRequest) async -> WorkshopSessionReceipt {
        let resultStore = WorkshopSessionResultStore(dataRoot: dataRoot, platform: platform)
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
            do {
                if try claimStore.isUnstarted(reservationId: request.reservationId) {
                    return refused("reservation was settled unstarted before execution admission", request, disposition: .unstarted)
                }
            } catch {
                return refused("reservation claim unavailable: \(String(error.localizedDescription.prefix(600)))", request)
            }
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
            inner: effects.makeToolDispatcher(dataRoot: dataRoot),
            artifactWriter: WorkshopArtifactWriter(dataRoot: dataRoot, handle: request.handle),
            collector: collector,
            progressCollector: progressCollector,
            // Owner-cadence jobs are not pursuits, and desk_work_log's store
            // method refuses every non-pursuit target (lane1 finding 3).
            allowsDeskWorkLog: claimedItem.isPursuit
        )
        let executor = turnExecutor ?? effects.productionTurnExecutor(dataRoot: dataRoot)

        let outcome = await runWithDeadline(request: request, tools: profile, executor: executor)
        // User, 2026-09-06: seal the membrane before reading the artifact set.
        // The deadline cancels the turn but cannot stop an executor that
        // ignores cancellation, and its later `workshop_artifact_write` calls
        // used to keep landing — making this receipt's `artifactPaths` stale
        // the moment it was saved.
        let artifacts = await collector.close()
        let progress = await progressCollector.latest()

        let receipt: WorkshopSessionReceipt
        switch outcome {
        case .done(let model, let output):
            let failedCalls = await progressCollector.failedCalls()
            // lane1 finding 2: a turn that ENDED is not a turn that PROGRESSED.
            // Without a valid workshop_progress report the session never stated
            // its own outcome, so the honest receipt is the finite needs-User
            // shape — never an affirmative `progress` minted from silence. Tool
            // failures are named, so a failed recording is distinguishable from
            // a deliberately artifact-free observation.
            guard let progress else {
                var why = failedCalls.isEmpty
                    ? "session ended without a \(WorkshopToolProfile.progressToolName) report — its outcome was never recorded"
                    : "session recorded no progress; \(failedCalls.count) tool call(s) failed: "
                        + failedCalls.joined(separator: "; ")
                let tail = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if !tail.isEmpty { why += ". Final text: \(tail)" }
                receipt = WorkshopSessionReceipt(
                    handle: request.handle, reservationId: request.reservationId,
                    status: .blocked, summary: Self.trimSummary(why),
                    model: model, artifactPaths: artifacts, generatedAt: now(), disposition: .blocked)
                break
            }
            let requested = progress.disposition
            // A typed completion without a durable artifact is not enough to
            // close a large project. Keep it as progress; Pump re-verifies the
            // handle-scoped paths again at the owner CAS boundary.
            var disposition: DeskWorkDisposition = requested == .goalSatisfied && artifacts.isEmpty
                ? .progress
                : requested
            var summary = progress.summary
            // A reported `progress` whose own recording calls failed is not
            // evidence of progress either; say so and keep it needs-User.
            if !failedCalls.isEmpty {
                summary = Self.trimSummary(summary + " [tool failures: " + failedCalls.joined(separator: "; ") + "]")
                if disposition == .progress || disposition == .goalSatisfied { disposition = .blocked }
            }
            receipt = WorkshopSessionReceipt(
                handle: request.handle, reservationId: request.reservationId,
                status: failedCalls.isEmpty ? .completed : .blocked, summary: summary,
                model: model, artifactPaths: artifacts, generatedAt: now(), disposition: disposition)
        case .timedOut:
            // Finite needs-User state — the anti-wedge (M6).
            receipt = WorkshopSessionReceipt(
                handle: request.handle, reservationId: request.reservationId,
                status: .blocked, summary: "session exceeded the \(Int(deadlineSeconds))s deadline; left in-flight for the user",
                model: nil, artifactPaths: artifacts, generatedAt: now(), disposition: .blocked)
        case .incomplete(let reason, let output):
            // Same finite needs-User shape as the deadline: artifacts already
            // written are kept, the partial text is reported as partial, and
            // the disposition never claims the goal was satisfied.
            receipt = WorkshopSessionReceipt(
                handle: request.handle, reservationId: request.reservationId,
                status: .blocked,
                summary: Self.trimSummary("session did not finish: \(reason)"
                    + (output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "" : " Partial output: \(output)")),
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

    private func refused(_ why: String, _ request: WorkshopSessionRequest, disposition: DeskWorkDisposition = .blocked) -> WorkshopSessionReceipt {
        WorkshopSessionReceipt(
            handle: request.handle, reservationId: request.reservationId,
            status: .refused, summary: why, model: nil, artifactPaths: [], generatedAt: now(), disposition: disposition)
    }

    private enum TurnOutcome: Sendable {
        case done(model: String, output: String)
        case timedOut
        // User, 2026-09-06: the turn ENDED but never produced a completed final
        // reply (budget exhaustion, iteration cap). Its retained text is a
        // fallback, and its attempted effects are unverified — a distinct
        // outcome so it can never be read as a finished session.
        case incomplete(reason: String, output: String)
        case failed(String)
    }

    /// Race the turn against the deadline. Whichever finishes first wins; the
    /// loser is cancelled. This is the finite bound M6 requires.
    private func runWithDeadline(
        request: WorkshopSessionRequest,
        tools: any ToolDispatchClient,
        executor: @escaping @Sendable (_ request: WorkshopSessionRequest, _ tools: any ToolDispatchClient) async throws -> (model: String, output: String)
    ) async -> TurnOutcome {
        // User, 2026-09-06: this was a task group, and leaving a group waits for
        // its cancelled children — a turn that ignored its cancellation held the
        // Workshop pump past the very ceiling this exists to enforce. Same
        // resume-once shape the provider wall and the tool-dispatch deadline
        // use; the loser is still cancelled.
        let outcome = await TurnDeadline.withDeadline(
            seconds: max(0.001, deadlineSeconds)
        ) { () -> TurnOutcome in
            do {
                let (model, output) = try await executor(request, tools)
                return .done(model: model, output: output)
            } catch let incomplete as EphemeralToolTurnIncomplete {
                return .incomplete(reason: incomplete.reason, output: incomplete.output)
            } catch {
                return .failed(String(describing: error))
            }
        }
        return outcome ?? .timedOut
    }

    static func trimSummary(_ s: String) -> String {
        let clean = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.count <= 600 ? clean : String(clean.prefix(600)) + "…"
    }
}

/// Workshop-local autonomy policy. The ordinary SecurityCenter and file-access
/// wrappers remain active; this resolver only prevents the generic chat policy
/// from reclassifying the already-hard-ceilinged profile as an approval lane.
/// A future tool remains denied until it is deliberately added to the profile.
public struct WorkshopAutonomyResolver: AutonomyResolver {
    let base: any AutonomyResolver

    public init(base: any AutonomyResolver) {
        self.base = base
    }

    public func autonomyLevel(forTool toolName: String, surface: String) async throws -> String {
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

    func claim(handle: String, reservationId: String, unstarted: Bool = false) -> Bool {
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
            "unstarted": .bool(unstarted),
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

    func isUnstarted(reservationId: String) throws -> Bool {
        let safe = try WorkshopArtifactWriter.validateSafeComponent(reservationId)
        let data = try Data(contentsOf: dataRoot.appendingPathComponent("workshop/reservation_claims/\(safe).claim"))
        guard case .object(let object) = try JSONValue.parse(data),
              object["reservationId"] == .string(reservationId),
              case .string? = object["handle"], case .string? = object["claimedAt"] else {
            throw WorkshopExecutionError.persistenceFailure("Workshop reservation claim \(reservationId) is malformed; restore its saved claim before continuing work")
        }
        guard let unstarted = object["unstarted"] else { return false }
        guard case .bool(let value) = unstarted else {
            throw WorkshopExecutionError.persistenceFailure("Workshop reservation claim \(reservationId) has invalid admission state; restore its saved claim before continuing work")
        }
        return value
    }
}
