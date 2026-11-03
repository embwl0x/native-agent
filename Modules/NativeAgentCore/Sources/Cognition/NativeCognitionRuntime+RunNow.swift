import BackgroundLoops
import CognitiveSubstrate
import Foundation
import NativeAgentShared
import PersistenceCore
import Privacy
import Senses
import TurnTrace

// Blueprint: | `NativeCognitionRuntime+RunNow.swift` | `MindClockVerb`, `MindClockResult` and the mind_run clock family: one-shot wait satisfaction, existing retained owner flights, exact owner outcomes and redacted correlated run-now traces; a 45-second reply bound reports pending while retained real work continues; all nine clock previews refuse before effectful admission with a specific cause; mindPreviewRefusal reads existing lifecycle/substrate readiness without bootstrap or waiting |

/// An invocation's answer, not a second copy of an owner's state. Owners return
/// the decision at the branch that made it, including unavailable evidence.
public struct MindClockResult: Sendable {
    public var outcome: String
    public var why: String
    public var fields: [String: JSONValue]
    public var ok: Bool { !["failed", "error", "unavailable", "unweighed", "not_kept", "pending", "preview_refused"].contains(outcome) }

    public init(_ outcome: String, _ why: String, fields: [String: JSONValue] = [:]) {
        self.outcome = outcome; self.why = why; self.fields = fields
    }

    public var json: [String: JSONValue] {
        var result = fields.merging(["outcome": .string(outcome), "why": .string(why)]) { _, new in new }
        if outcome == "pending" { result["status"] = .string("pending") }
        if fields["preview"] == .bool(true) { result["status"] = .string("preview") }
        return result
    }
}

typealias MindClockReply = @Sendable (MindClockResult) -> Void

public enum MindClockVerb: String, Sendable {
    case canon, horizon, rhythm, wander, reach, carried, cross, maintenance
    case residualRepair = "residual_repair"
}

extension NativeCognitionRuntime {
    /// Only the selected owner's scheduling wait is satisfied. All evidence,
    /// expiry, readiness and person-facing policy reads keep the actual time.
    public func runClockNow(verb: MindClockVerb, input: [String: JSONValue]) async -> MindClockResult {
        if input["preview"] == .bool(true) {
            // These owners interleave decisions with durable effects. Do not
            // enter them, bootstrap, claim a flight or change a deadline just
            // to discover that they cannot finish a read-only preview.
            let why: String
            switch verb {
            case .canon: why = "Canon tending stages approval proposals inside its decision pass and records its audit."
            case .horizon: why = "Horizon composition updates source deadlines and refresh settles felt resolutions into the live organism."
            case .rhythm: why = "His day refresh saves awake history before admitting and consuming pending care-felt breaks."
            case .wander: why = "Her hour claims its real admission and runs an editable part with tools and settlement."
            case .reach: why = "Reach reconciles deliveries and lands care answers before selecting and saving an offer."
            case .carried: why = "Carried work settles owed deliveries, expires intentions and reconciles its wake ledger before selection."
            case .cross: why = "Crossing primes the mind and releases news intentions before weighing the line."
            case .maintenance: why = "Maintenance consolidates the live substrate and checkpoints it as one transition."
            case .residualRepair: why = "Residual repair mutates the live organism field while selecting and repairing its targets."
            }
            return Self.recordClockRun(verb.rawValue, .init("preview_refused",
                why + " This owner cannot yet separate decision from effect; preview was refused before entering it. Nothing was changed.",
                fields: ["preview": .bool(true), "effects": .string("none"), "execution": .string("preview")]))
        }
        await bootstrap()
        let owner = verb.rawValue
        let runID = UUID().uuidString.lowercased()
        let configuration = await substrate.configurationSnapshot()
        let result: MindClockResult
        if let bootstrapFailure {
            result = .init("unavailable", bootstrapFailure)
        } else if isFlushedForTermination || Task.isCancelled {
            result = .init("held", "The runtime is stopping.")
        } else if !configuration.enabled {
            result = .init("held", "Inner life is off; enable settings.inner_life before running this owner.")
        } else {
            switch verb {
            case .canon:
                result = await waitForClockOwner(owner, runID: runID) { reply in
                    considerStudioCanonTending(runNow: true, reply: reply)
                }
            case .horizon:
                result = await waitForClockOwner(owner, runID: runID) { reply in
                    considerHorizonExpectations(runNow: true, reply: reply)
                }
            case .rhythm:
                result = await waitForClockOwner(owner, runID: runID) { reply in
                    considerRhythm(runNow: true, reply: reply)
                }
            case .wander:
                result = await waitForClockOwner(owner, runID: runID) { reply in
                    considerStudioWander(runNow: true, reply: reply)
                }
            case .reach:
                result = await waitForClockOwner(owner, runID: runID) { reply in
                    considerReach(runNow: true, reply: reply)
                }
            case .carried:
                result = await considerCarried(runNow: true).result
            case .cross:
                guard let line = input["line"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !line.isEmpty,
                      let watch = input["watch"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !watch.isEmpty else {
                    return Self.recordClockRun(owner, .init("unavailable", "Pass a nonempty line and watch name."), runID: runID)
                }
                let crossed = await cross(line, watch: watch, reason: "news from " + watch,
                    id: "cross:" + UUID().uuidString.lowercased(), says: line, agent: nil)
                let fields: [String: JSONValue] = ["watch": .string(watch)]
                switch crossed {
                case .woke(let care): result = .init("woke", "The line touched " + care + "; its ResidentWake was kept.", fields: fields)
                case .untouched: result = .init("untouched", "The line did not touch a live care.", fields: fields)
                case .unweighed: result = .init("unweighed", "The crossing could not weigh the line; no care verdict is available.", fields: fields)
                case .resting(let care): result = .init("resting", "This watch already woke her about " + care + ".", fields: fields)
                case .notKept(let care): result = .init("not_kept", "The line touched " + care + ", but its ResidentWake was not kept.", fields: fields)
                }
            case .maintenance:
                result = Self.clockResult(await runMaintenance(reason: "mind.maintenance", runNow: true))
            case .residualRepair:
                if liveTurnInFlight {
                    result = .init("held", "A live turn is in flight.")
                } else if await organismKernel.runResidualRepairIfDue(satisfyWait: true) {
                    let saved = await persistOrganismContinuity(reason: "residual_pressure_repair")
                    result = .init(saved ? "repaired" : "failed", saved
                        ? "The existing bounded residual repair ran and was saved."
                        : "Residual repair ran in memory but continuity was not saved.")
                } else {
                    result = .init("held", "The organism is disabled or has no eligible repairable evidence.")
                }
                await rescheduleResidualRepairDeadline()
            }
        }
        return result.fields["run_id"] != nil ? result : Self.recordClockRun(owner, result, runID: runID)
    }

    /// Read the existing owners' admission state; a preview never opens her
    /// mind, joins an unfinished restore or waits for a future readiness event.
    public func mindPreviewRefusal() async -> String? {
        guard bootstrapTask != nil, organismContinuityReadable, !doorHeld else {
            return "Her mind has not finished opening, or a lifecycle transition holds it. Preview did not wait or bootstrap it."
        }
        if let bootstrapFailure { return bootstrapFailure }
        guard !isFlushedForTermination, !Task.isCancelled else { return "The runtime is stopping." }
        return await substrate.carePreviewRefusal()
    }

    /// Bound the action's observation, not the owner's work. A slow owner keeps
    /// its retained flight and single-flight gate; its later answer is traced
    /// with this same run id. Silence is pending, never completion or failure.
    private func waitForClockOwner(_ verb: String, runID: String,
                                   start: (@escaping MindClockReply) -> Void) async -> MindClockResult {
        await withCheckedContinuation { continuation in
            let reply = MindClockReplyGate(continuation) { result in
                Self.recordClockRun(verb, result, runID: runID)
            }
            start { reply.finish($0) }
            reply.arm()
        }
    }

    private static func clockResult(_ outcome: LoopTickOutcome) -> MindClockResult {
        switch outcome {
        case .completed(let note): return .init("completed", note ?? "The owner completed.")
        case .skipped(let why, _): return .init("held", why)
        case .failed(let why): return .init("failed", why)
        }
    }

    public nonisolated static func recordClockRun(_ verb: String, _ result: MindClockResult,
                                                 runID: String = UUID().uuidString.lowercased()) -> MindClockResult {
        var result = result
        result.fields["run_id"] = .string(runID)
        result.fields["owner"] = .string(verb)
        TurnTraceBus.fire(TurnTraceEvent(turnId: "run-now:" + runID, kind: "mind.run_now",
            sessionId: "resident-wake", surface: "chat", payload: NativeAppSecretRedactor.redactValue(.object(result.json))))
        return result
    }
}

/// Only an invocation's reply rendezvous lives here. All execution/state stays
/// with the retained owner. The lock chooses exactly one continuation resume.
private final class MindClockReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<MindClockResult, Never>?
    private var deadline: Task<Void, Never>?
    private let publish: @Sendable (MindClockResult) -> MindClockResult

    init(_ continuation: CheckedContinuation<MindClockResult, Never>, publish: @escaping @Sendable (MindClockResult) -> MindClockResult) {
        self.continuation = continuation; self.publish = publish
    }

    func arm() {
        lock.lock(); defer { lock.unlock() }
        guard continuation != nil else { return }
        deadline = Task {
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
            expire()
        }
    }

    func finish(_ result: MindClockResult) {
        lock.lock()
        let waiting = continuation; continuation = nil
        deadline?.cancel(); deadline = nil
        let reported = publish(result)
        lock.unlock()
        waiting?.resume(returning: reported)
    }

    private func expire() {
        lock.lock()
        let waiting = continuation; continuation = nil; deadline = nil
        let reported = waiting.map { _ in publish(.init("pending", "The owner has not answered within 45 seconds. Its retained flight still owns the work; inspect this run_id for a later outcome before another attempt.")) }
        lock.unlock()
        if let reported { waiting?.resume(returning: reported) }
    }
}
