import Testing
import Foundation
@testable import WorkshopExecution
import NativeAgentCore
import PersistenceCore

// Coverage ledger: `workshop.runner.liveReservationCount`
// (WorkshopExecution+Runner.swift `liveReservationCount()`).
//
// SILENT-FAILURE CLASS: state-lifecycle leak. A `.reserved` marker occupies an
// admission slot until either a record lands beside it or it ages out at 600s.
// Two regressions leak slots with a GREEN suite:
//   1. the age-out constant grows / is dropped — a crashed submit holds its
//      slot forever;
//   2. the "did the durable write land" probe narrows to the canonical
//      `execution.json` only — every unmigrated `mission.json` directory then
//      reads as a live reservation.
// Either way every submit returns `workshop_executions_busy` over a queue that
// looks empty in the UI. Nothing counts reservations, so nothing reports it.
//
// The eval drives the OBSERVABLE surface (`submit` admitted vs refused) with a
// cap override of 1, so exactly one countable slot exists.

private func reservationEvalRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("WorkshopReservationEval-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Planner that never reaches a provider: every plan falls back to the stub,
/// so submit() exercises admission + file IO only.
private struct ReservationEvalPlanner: WorkshopPlannerLLM {
    let directProviderCallCountPerInvocation: Int? = 1
    func availableConnectorActions() async -> [JSONValue] { [] }
    func runCodex(
        prompt: String, surface: String, timeoutSeconds: Int
    ) async throws -> (model: String, output: String) {
        throw WorkshopExecutionError.plannerFailure("reservation-eval: no provider")
    }
}

/// Seed one execution directory holding a `.reserved` marker of a given age,
/// optionally beside a durable record written under `recordName`.
/// `recordName` is a FILE NAME on purpose: the canonical/legacy distinction is
/// exactly what the probe under test has to tolerate.
@discardableResult
private func seedReservation(
    root: URL,
    id: String,
    markerAgeSeconds: TimeInterval,
    recordName: String? = nil,
    recordStatus: String = "completed"
) async throws -> URL {
    let dir = root.appendingPathComponent("workshop/executions/\(id)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let marker = dir.appendingPathComponent(".reserved")
    try Data("reserved eval\n".utf8).write(to: marker)
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-markerAgeSeconds)],
        ofItemAtPath: marker.path
    )
    if let recordName {
        let nowStr = SwiftNativeWorkshopRunner.isoTimestamp(Date())
        let record = WorkshopExecutionRecord(
            id: id, title: "seed-\(id)", objective: "seed", createdAt: nowStr,
            status: recordStatus, plan: [], stepsCompleted: [],
            receiptsDir: dir.appendingPathComponent("receipts").path,
            triggerSource: "manual", trustRequired: "none", expectedOutputs: [],
            currentStepId: "", updatedAt: nowStr, result: .null, rerunCount: 0
        )
        try await SwiftNativePersistenceCore().writeJSON(
            record.toJSON(), to: dir.appendingPathComponent(recordName))
    }
    return dir
}

private func makeCapOneRunner(root: URL) -> SwiftNativeWorkshopRunner {
    SwiftNativeWorkshopRunner(
        executorAvailable: true,
        root: root,
        persistence: SwiftNativePersistenceCore(),
        planner: ReservationEvalPlanner(),
        workshopExecutionSlotsCapOverride: 1
    )
}

private func submitOutcome(
    _ runner: SwiftNativeWorkshopRunner
) async -> Result<WorkshopExecutionEnqueueResult, Error> {
    do {
        return .success(try await runner.submit(
            spec: WorkshopExecutionSpec(title: "eval", objective: "eval objective")))
    } catch {
        return .failure(error)
    }
}

@Suite("EVAL workshop.runner.liveReservationCount")
struct WorkshopSubmitReservationSlotEvalSuite {

    /// (a) A fresh `.reserved` with NO record beside it is a live in-flight
    /// submit and MUST consume the only slot.
    @Test func freshReservationWithoutRecordConsumesTheSlot() async throws {
        let root = try reservationEvalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await seedReservation(root: root, id: "inflight", markerAgeSeconds: 1)

        switch await submitOutcome(makeCapOneRunner(root: root)) {
        case .success:
            Issue.record("a live reservation must occupy the admission slot")
        case .failure(let error):
            let workshopError = try #require(error as? WorkshopExecutionError)
            #expect(workshopError.parityErrorCode == "missions_busy")
        }
    }

    /// (b) A `.reserved` beside a LEGACY `mission.json` is a landed durable
    /// write in an unmigrated directory — it must NOT count. A canonical-only
    /// existence probe fails here (and only here).
    @Test func reservationBesideLegacyRecordDoesNotConsumeTheSlot() async throws {
        let root = try reservationEvalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await seedReservation(
            root: root, id: "unmigrated", markerAgeSeconds: 1,
            recordName: ExecutionRecordFile.legacyName)

        switch await submitOutcome(makeCapOneRunner(root: root)) {
        case .success(let enqueued):
            #expect(enqueued.record.status == "queued")
        case .failure(let error):
            Issue.record("unmigrated record must free the slot, got \(error)")
        }
    }

    /// The same directory shape with the CANONICAL record name must behave
    /// identically — this is the control that keeps (b) honest (it proves the
    /// pass in (b) comes from the dual-name probe, not from the marker being
    /// ignored wholesale).
    @Test func reservationBesideCanonicalRecordDoesNotConsumeTheSlot() async throws {
        let root = try reservationEvalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await seedReservation(
            root: root, id: "migrated", markerAgeSeconds: 1,
            recordName: ExecutionRecordFile.canonicalName)

        switch await submitOutcome(makeCapOneRunner(root: root)) {
        case .success(let enqueued):
            #expect(enqueued.record.status == "queued")
        case .failure(let error):
            Issue.record("landed canonical record must free the slot, got \(error)")
        }
    }

    /// (c) A reservation older than the age-out is a crashed submit; the slot
    /// must be reclaimed. Seeded at 601s — one second past the boundary — so a
    /// widened constant (or a dropped age-out) fails here.
    @Test func agedOutReservationReleasesTheSlot() async throws {
        let root = try reservationEvalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await seedReservation(root: root, id: "crashed", markerAgeSeconds: 601)

        switch await submitOutcome(makeCapOneRunner(root: root)) {
        case .success(let enqueued):
            #expect(enqueued.record.status == "queued")
        case .failure(let error):
            Issue.record("a reservation past the age-out must free the slot, got \(error)")
        }
    }

    /// The age-out is a BOUND, not a blanket amnesty: still inside the window
    /// (599s) the slot stays held. Pins the boundary from the other side, so a
    /// regression that shortens the constant to ~0 is caught too.
    @Test func reservationInsideTheAgeOutWindowStillHoldsTheSlot() async throws {
        let root = try reservationEvalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await seedReservation(root: root, id: "recent", markerAgeSeconds: 599)

        switch await submitOutcome(makeCapOneRunner(root: root)) {
        case .success:
            Issue.record("a reservation inside the age-out window must hold its slot")
        case .failure(let error):
            let workshopError = try #require(error as? WorkshopExecutionError)
            #expect(workshopError.parityErrorCode == "missions_busy")
        }
    }

    /// Lifecycle close: a SUCCESSFUL submit must leave no marker behind — the
    /// record is the counted artifact from then on. A leaked marker would hold
    /// its own slot for 10 minutes after every single submit.
    @Test func successfulSubmitLeavesNoReservationMarker() async throws {
        let root = try reservationEvalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeCapOneRunner(root: root)
        let enqueued = try await runner.submit(
            spec: WorkshopExecutionSpec(title: "eval", objective: "eval objective"))

        let marker = runner.workshopExecutionDir(enqueued.executionId)
            .appendingPathComponent(".reserved")
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
        #expect(FileManager.default.fileExists(
            atPath: runner.executionRecordPath(enqueued.executionId).path))

        // And the queue is countable again only through the record: the new
        // execution is `queued`, i.e. ACTIVE, so a second submit at cap 1 is
        // refused by the ACTIVE count rather than by a stale reservation.
        switch await submitOutcome(runner) {
        case .success:
            Issue.record("second submit at cap 1 must be refused")
        case .failure(let error):
            let workshopError = try #require(error as? WorkshopExecutionError)
            #expect(workshopError.parityErrorCode == "missions_busy")
        }
    }
}
