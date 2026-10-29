import Foundation
import NativeAgentShared
import ChatTurnContracts
import Darwin
import NativeAgentCore
import PersistenceCore
import Desk
import TrustCenter
// Blueprint: | `WorkshopSession.swift` | `WorkshopSession` struct; `run`, `trimSummary` |

// Run one normal chat turn on the workshop surface; a live pump-minted Desk reservation is required before any provider call.
// Join worker settlement before publishing its single terminal receipt (docs/STOP.md).

public struct WorkshopSession: Sendable {
    let dataRoot: URL
    let store: SwiftNativeDeskStore
    /// Active-work deadline (M6), renewed by progress and paused for human waits.
    let deadlineSeconds: TimeInterval
    let now: @Sendable () -> Date
    let claimStore: WorkshopReservationClaimStore
    let effects: any WorkshopSessionEffects

    public init(
        dataRoot: URL,
        store: SwiftNativeDeskStore,
        effects: any WorkshopSessionEffects,
        deadlineSeconds: TimeInterval = 600,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.dataRoot = dataRoot
        self.store = store
        self.effects = effects
        self.deadlineSeconds = deadlineSeconds
        self.now = now
        self.claimStore = WorkshopReservationClaimStore(dataRoot: dataRoot)
    }

    public func run(_ request: WorkshopSessionRequest) async -> WorkshopSessionReceipt {
        let resultStore = WorkshopSessionResultStore(dataRoot: dataRoot)
        guard !request.handle.isEmpty,
              !request.reservationId.isEmpty else {
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
            // desk_work_log accepts pursuits only.
            allowsDeskWorkLog: claimedItem.isPursuit
        )
        let executor = effects.productionTurnExecutor(dataRoot: dataRoot)

        let (outcome, returned) = await runWithDeadline(request: request, tools: profile, executor: executor,
            expiresAt: claimedItem.pursuitExpiresAt)
        return await settle {
            // The actual body has exited; seal its artifacts and save one receipt.
            let artifacts = await collector.close()
            let progress = await progressCollector.latest()

            var receipt: WorkshopSessionReceipt
            switch outcome {
            case .done(let model, let output):
                let failedCalls = await progressCollector.failedCalls()
                // Missing workshop_progress is blocked, never inferred progress; name recording failures in the receipt.
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
                    status: .blocked, summary: "session exceeded its deadline; work stopped and its returned output was retained",
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
            receipt.output = returned?.output
            _ = resultStore.save(receipt)
            return receipt
        }
    }

    private func refused(_ why: String, _ request: WorkshopSessionRequest, disposition: DeskWorkDisposition = .blocked) -> WorkshopSessionReceipt {
        WorkshopSessionReceipt(
            handle: request.handle, reservationId: request.reservationId,
            status: .refused, summary: why, model: nil, artifactPaths: [], generatedAt: now(), disposition: disposition)
    }

    private enum TurnOutcome: Sendable {
        case done(model: String, output: String)
        case timedOut
        // Retained text without a completed final reply leaves effects unverified and cannot count as a finished session.
        case incomplete(reason: String, output: String)
        case failed(String)

        var output: String? {
            switch self {
            case .done(_, let output), .incomplete(_, let output): return output
            default: return nil
            }
        }
    }

    /// Select the deadline/Stop verdict, then join the actual returned outcome.
    private func runWithDeadline(
        request: WorkshopSessionRequest,
        tools: any ToolDispatchClient,
        executor: @escaping @Sendable (_ request: WorkshopSessionRequest, _ tools: any ToolDispatchClient) async throws -> (model: String, output: String),
        expiresAt: Date?
    ) async -> (TurnOutcome, TurnOutcome?) {
        let body = TurnBodyLifetime<TurnOutcome>()
        let outcome: TurnOutcome
        do {
            guard deadlineSeconds > 0 else { return (.timedOut, nil) }
            let runActiveWork: @Sendable () async throws -> TurnOutcome = { [deadlineSeconds] in
                try await TurnDeadline.withThrowingDeadline(seconds: deadlineSeconds, clock: .activeWork) {
                    try await body.run {
                        do {
                            try Task.checkCancellation()
                            let (model, output) = try await executor(request, tools)
                            return .done(model: model, output: output)
                        } catch let incomplete as EphemeralToolTurnIncomplete {
                            return .incomplete(reason: incomplete.reason, output: incomplete.output)
                        } catch {
                            return .failed(String(describing: error))
                        }
                    }
                }
            }
            // Only pursuit lifetime is an absolute cutoff. The inner clock
            // still renews on progress and pauses while awaiting a person.
            if let expiresAt {
                let remainingLifetime = expiresAt.timeIntervalSince(now())
                guard remainingLifetime > 0 else { return (.timedOut, nil) }
                outcome = try await TurnDeadline.withThrowingDeadline(
                    seconds: remainingLifetime, clock: .wallClock, runActiveWork)
            } else {
                outcome = try await runActiveWork()
            }
        } catch is TurnDeadline.DeadlineExceeded {
            outcome = .timedOut
        } catch is CancellationError {
            outcome = .incomplete(reason: "stopped", output: "")
        } catch {
            outcome = .failed(error.localizedDescription)
        }
        let returned = await body.finish()
        return (outcome, returned.map { result in
            switch result {
            case .success(let value): return value
            case .failure(let error): return .failed(String(describing: error))
            }
        })
    }

    static func trimSummary(_ s: String) -> String {
        let clean = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.count <= 600 ? clean : String(clean.prefix(600)) + "…"
    }
}

/// Cross-process, one-shot authorization claim for a Desk work reservation.
/// The file's existence is the authorization ledger: creation is atomic and
/// its payload is fsync'd before the LLM boundary. Malformed/pre-existing files
/// fail closed because O_EXCL refuses to replace them.
/// Authorization claim JSON: local backup/export include workshop/; no phone
/// sync; PrivacyMap lists Workshop.
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
            "claimedAt": .string(NativeTimestampFormat.plainZulu(Date())),
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
