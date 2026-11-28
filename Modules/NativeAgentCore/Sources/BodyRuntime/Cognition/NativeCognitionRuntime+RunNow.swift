import SenseCore
import MindCore
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore

// Blueprint: | `NativeCognitionRuntime+RunNow.swift` | `MindClockVerb`, `MindClockResult`. |

/// Return the owner's actual branch decision, including unavailable evidence; keep no second state copy.
public struct MindClockResult: Sendable {
    public var outcome: String
    public var why: String
    public var fields: [String: JSONValue]
    /// What the pass produced, when the owner counts it: a pass that produced nothing beats `nothing`.
    public var yield: Int?
    /// The owner held only until its own time comes (a refractory, quiet wait, cooldown or timing gate it re-arms for): an automatic pass writes no beat.
    public var waits = false
    public var ok: Bool { !["failed", "error", "unavailable", "unweighed", "not_kept", "pending", "preview_refused"].contains(outcome) }

    public init(_ outcome: String, _ why: String, fields: [String: JSONValue] = [:], yield: Int? = nil) {
        self.outcome = outcome; self.why = why; self.fields = fields; self.yield = yield
    }

    public static func waiting(_ why: String, fields: [String: JSONValue] = [:]) -> MindClockResult {
        var result = MindClockResult("held", why, fields: fields)
        result.waits = true
        return result
    }

    /// Held because the owner is switched off; its beat carries the off prefix, so it is never felt.
    public static func off(_ reason: String) -> MindClockResult {
        .init("held", OrganPulse.offPrefix + reason)
    }

    /// The beat this decision is to its organ; nil for an answer still pending or a preview, which decide nothing.
    public var pulseOutcome: OrganPulse.Outcome? {
        guard outcome != "pending", fields["preview"] != .bool(true) else { return nil }
        switch outcome {
        case "held": return .held
        case "stopped": return .stopped
        case "nothing": return .nothing
        default: return !ok ? .failed : yield == 0 ? .nothing : .worked
        }
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
    case canon, horizon, rhythm, maintenance
    case residualRepair = "residual_repair"
}

extension NativeCognitionRuntime {
    /// Satisfy only the selected scheduling wait; evidence, expiry, readiness and person-facing policy use actual time.
    public func runClockNow(verb: MindClockVerb, input: [String: JSONValue], parent: Turn) async -> MindClockResult {
        if input["preview"] == .bool(true) {
            // Refuse preview before bootstrap, flight claims or deadlines because these owners interleave admission with durable effects.
            let why: String
            switch verb {
            case .canon: why = "Canon tending stages approval proposals inside its decision pass and records its audit."
            case .horizon: why = "Horizon composition updates source deadlines and refresh settles felt resolutions into the live organism."
            case .rhythm: why = "The person's day refresh saves awake history before admitting and consuming pending care-felt breaks."
            case .maintenance: why = "Maintenance consolidates the live substrate and checkpoints it as one transition."
            case .residualRepair: why = "Residual repair runs with live field admission and a continuity write."
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
        } else if isAdmissionClosed || Task.isCancelled {
            result = .init("held", "The runtime is stopping.")
        } else if !configuration.enabled {
            result = .off("inner life is off; enable settings.inner_life before running this owner")
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
            case .maintenance:
                result = Self.clockResult(await runMaintenance(reason: "mind.maintenance", runNow: true))
            case .residualRepair:
                let session = input["__session_id"]?.stringValue
                if liveTurnInFlight(besides: session) {
                    result = .init("held", "A live turn is in flight.")
                    await rescheduleResidualRepairDeadline()
                } else {
                    var repaired = false
                    do {
                        repaired = try await organismKernel.runResidualRepairIfDue(satisfyWait: true, parent: parent) {
                            !(await self.liveTurnInFlight(besides: session))
                        }
                        if repaired {
                            let saved = await persistOrganismContinuity(reason: "residual_pressure_repair")
                            result = .init(saved ? "repaired" : "failed", saved
                                ? "The existing bounded residual repair ran and was saved."
                                : "Residual repair ran in memory but continuity was not saved.")
                        } else {
                            result = .init("held", "No bounded field repair was applied.")
                        }
                    } catch is CancellationError {
                        result = .init("stopped", "Residual repair was stopped before it could commit.")
                    } catch {
                        result = .init("failed", DreamPart.redact(error.localizedDescription))
                    }
                    await rescheduleResidualRepairDeadline(afterUnappliedPass: !repaired)
                }
            }
        }
        return result.fields["run_id"] != nil ? result : Self.recordClockRun(owner, result, runID: runID)
    }

    /// Preview cannot bootstrap, join unfinished restore or wait for future readiness.
    public func mindPreviewRefusal() async -> String? {
        guard bootstrapTask != nil, organismContinuityReadable, !doorHeld else {
            return "The agent's mind has not finished opening, or a lifecycle transition holds it. Preview did not wait or bootstrap it."
        }
        if let bootstrapFailure { return bootstrapFailure }
        guard !isAdmissionClosed, !Task.isCancelled else { return "The runtime is stopping." }
        return await substrate.carePreviewRefusal()
    }

    /// The owner's reply ends observation; cancellation withdraws this caller while the owner retains settlement.
    private func waitForClockOwner(_ verb: String, runID: String,
                                   start: (@escaping MindClockReply) -> Void) async -> MindClockResult {
        let reply = MindClockReplyGate(cancelled: .init("pending", "The wait was cancelled; the owner retains this run's settlement.",
            fields: ["run_id": .string(runID), "owner": .string(verb)])) { result in
            Self.recordClockRun(verb, result, runID: runID)
        }
        start { result in Task { await reply.finish(result) } }
        return await withTaskCancellationHandler {
            await reply.value()
        } onCancel: {
            Task { await reply.cancel() }
        }
    }

    private static func clockResult(_ outcome: LoopTickOutcome) -> MindClockResult {
        switch outcome {
        case .completed(let note): return .init("completed", note ?? "The owner completed.")
        case .skipped(let why, _): return .init("held", why)
        case .failed(let why): return .init("failed", why)
        }
    }

    /// The run trace is the reply's record; the owner beats the same decision as asked, except a switched-off owner, whose off words stay as they are.
    public nonisolated static func recordClockRun(_ verb: String, _ result: MindClockResult,
                                                 runID: String = UUID().uuidString.lowercased()) -> MindClockResult {
        if let organ = MindClockVerb(rawValue: verb)?.organ, let outcome = result.pulseOutcome {
            let off = outcome == .held && result.why.hasPrefix(OrganPulse.offPrefix)
            OrganJudge.beat(organ, outcome, note: off ? result.why : "asked: " + result.why, yield: result.yield)
        }
        var result = result
        result.fields["run_id"] = .string(runID)
        result.fields["owner"] = .string(verb)
        TurnTraceBus.fire(TurnTraceEvent(turnId: "run-now:" + runID, kind: "mind.run_now",
            sessionId: Attention.stream, surface: "chat", payload: NativeAppSecretRedactor.redactValue(.object(result.json)), turn: nil))
        return result
    }
}

/// One reply rendezvous; the owner publishes its terminal result even if its caller withdrew.
private actor MindClockReplyGate {
    private var continuation: CheckedContinuation<MindClockResult, Never>?
    private var result: MindClockResult?
    private var withdrawn = false
    private let cancelled: MindClockResult
    private let publish: @Sendable (MindClockResult) -> MindClockResult

    init(cancelled: MindClockResult, publish: @escaping @Sendable (MindClockResult) -> MindClockResult) {
        self.cancelled = cancelled; self.publish = publish
    }

    func value() async -> MindClockResult {
        if let result { return result }
        if withdrawn || Task.isCancelled { return cancelled }
        return await withCheckedContinuation { continuation = $0 }
    }

    func finish(_ result: MindClockResult) {
        guard self.result == nil else { return }
        let reported = publish(result)
        self.result = reported
        let waiting = continuation; continuation = nil
        waiting?.resume(returning: reported)
    }

    func cancel() {
        withdrawn = true
        let waiting = continuation; continuation = nil
        waiting?.resume(returning: cancelled)
    }
}
