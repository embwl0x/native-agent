import DoctorChecks
import EngineRuntime
import Foundation
import NativeAgentShared
import Privacy
import Synchronization
import TurnTrace
// Blueprint: | `BodyFaceDoctor.swift` | Doctor reads the only Inspector and binds subscription repair to its connection and view |

@MainActor
enum BodyFaceDoctor {
    private struct Renderer: Sendable {
        let connection: UUID
        let engine: NativeAgentEngine
        var report: RendererInspectorReport?
    }
    /// The one renderer and its cached report, held outside the main actor so the link can forget it synchronously as it ends.
    nonisolated private static let held = Mutex<Renderer?>(nil)
    private static var renderer: Renderer? { held.withLock { $0 } }

    static func connect(_ connection: UUID, engine: NativeAgentEngine) {
        held.withLock { $0 = Renderer(connection: connection, engine: engine, report: nil) }
    }

    /// The one way a renderer ends for Doctor: the link calls it first when it closes, before any await, so no check reads a closed window's
    /// cached report. A newer connection is left as it is.
    nonisolated static func disconnect(_ connection: UUID?) {
        held.withLock { if $0?.connection == connection { $0 = nil } }
    }

    static func report(_ report: RendererInspectorReport) throws {
        try held.withLock { current in
            guard current?.connection == report.connection, report.mounted == (report.view != nil),
                  !report.observing || (report.mounted && report.subscription != nil) else { throw FaceWireError.invalidFeedOrder }
            current?.report = report
        }
    }

    static func check() async -> CheckResult {
        guard let renderer else { return InspectorFeedHealth.check(isOpen: false, observationActive: false) }
        do {
            let report: RendererInspectorReport
            if let reported = renderer.report { report = reported }
            else { report = try await read(.readInspectorHealth, renderer: renderer) }
            let sourceActive = await renderer.engine.trace.observationActive
            // The window may have gone while this read awaited: a renderer no longer held shows no Inspector.
            guard self.renderer?.connection == renderer.connection else {
                return InspectorFeedHealth.check(isOpen: false, observationActive: false)
            }
            var face = InspectorFeedHealth.check(isOpen: report.mounted,
                observationActive: sourceActive && report.observing && report.issue == nil)
            if let issue = report.issue { face.detail += " " + NativeAppSecretRedactor.redactText(issue) }
            return face
        } catch let error where noWindowToAnswer(error) {
            // A window with no connection shows no Inspector: that is the closed case, not a failure of something the person opened.
            return InspectorFeedHealth.check(isOpen: false, observationActive: false)
        } catch {
            let face = CheckResult(source: "FaceLink", id: "live.inspector_feed", title: "Inspector feed", status: "fail",
                detail: "Inspector health could not be read: " + NativeAppSecretRedactor.redactText(error.localizedDescription),
                harm: "The window's Inspector health is unknown.",
                human_action: "Check the window and its connection before requesting Inspector repair.")
            return face
        }
    }

    /// Decided by the error's own code: the body's link is gone or never reached a window, or the window answered that it has no connection,
    /// or its reply was lost when its connection closed. A connected window that answers with a fault is none of these.
    private static func noWindowToAnswer(_ error: any Error) -> Bool {
        if case FaceWireError.disconnected? = error as? FaceWireError { return true }
        guard let failure = error as? WireFailure else { return false }
        return [FaceWireError.disconnectedCode, "face_reply_lost", "renderer_unavailable"].contains(failure.code)
    }

    static func repair(for check: CheckResult) async -> DoctorExecutableRepair? {
        guard check.id == "live.inspector_feed", check.status == "fail" else { return nil }
        guard let renderer else { return nil }
        let target: RendererInspectorReport
        do { target = try await read(.readInspectorHealth, renderer: renderer) }
        catch { return DoctorExecutableRepair(checkID: check.id) { throw error } }
        let sourceActive = await renderer.engine.trace.observationActive
        let repairFace = target.mounted && (!target.observing || !sourceActive)
        guard repairFace else { return nil }
        return DoctorExecutableRepair(checkID: check.id) {
            try await repair(renderer: renderer, target: target)
        }
    }

    private static func repair(renderer: Renderer, target: RendererInspectorReport?) async throws -> DoctorRepairAttempt {
        try Task.checkCancellation()
        if let target {
            let current = try await read(.readInspectorHealth, renderer: renderer)
            guard current.view == target.view, current.subscription == target.subscription, current.mounted else {
                throw PartCallError(code: "inspector_selection_changed", message: "The Inspector view changed before repair. Nothing was rearmed.")
            }
        }
        await renderer.engine.trace.rearmObservation()
        guard await renderer.engine.trace.observationActive else {
            return .unverified("Trace observation remains inactive after its rearm attempt. The window subscription was not replaced.")
        }
        var receipts = ["Trace observation is active."]
        var completed = true
        if let target, let view = target.view {
            let report: RendererInspectorReport
            do { report = try await read(.rearmInspectorSubscription(view: view, subscription: target.subscription), renderer: renderer) }
            catch is CancellationError { throw CancellationError() }
            catch {
                receipts.append("Window subscription repair failed: " + NativeAppSecretRedactor.redactText(error.localizedDescription))
                return .unverified(receipts.joined(separator: "\n"))
            }
            guard report.view == view, report.mounted, report.subscription != nil, report.subscription != target.subscription else {
                return .unverified((receipts + ["Inspector did not confirm a replacement subscription."]).joined(separator: "\n"))
            }
            let sourceActive = await renderer.engine.trace.observationActive
            if sourceActive && report.observing && report.issue == nil {
                receipts.append("Window: rearmed its subscription and confirmed active trace observation.")
            } else {
                completed = false
                let issue = report.issue.map(NativeAppSecretRedactor.redactText) ?? "trace observation is not confirmed."
                receipts.append("Window: subscription replaced; " + issue)
            }
        }
        let detail = receipts.joined(separator: "\n")
        return completed ? .completed(detail) : .unverified(detail)
    }

    private static func read(_ call: FaceCall, renderer: Renderer) async throws -> RendererInspectorReport {
        guard self.renderer?.connection == renderer.connection else { throw FaceWireError.disconnected }
        let reply = try await renderer.engine.faceActs.call(call, renderer: renderer.connection)
        guard self.renderer?.connection == renderer.connection else { throw FaceWireError.disconnected }
        switch reply {
        case .inspector(let report):
            guard report.connection == renderer.connection, report.mounted == (report.view != nil),
                  !report.observing || (report.mounted && report.subscription != nil) else { throw FaceWireError.invalidFeedOrder }
            return report
        case .failed(let failure), .refused(let failure): throw failure
        case .cancelled: throw CancellationError()
        default: throw FaceWireError.invalidFeedOrder
        }
    }


}

extension AppModel {
    func refreshBodyDoctorCoverage() async {
        guard let current = engine.doctor.report else { return }
        _ = await engine.doctor.reportRead.read({
            let port = AppDoctorPort(dataRoot: engine.dataRoot, backgroundLoopsManager: backgroundLoopsManager)
            let live = await port.runtime.liveDoctorCoverageChecks()
            let status = await DoctorFacade.statusChecks(dataRoot: engine.dataRoot, approvals: engine.approvals,
                repairDesk: false, stuckReason: DeskPageContent.stuckReason,
                safeDetail: EngineDoctorRuntime<AppDoctorPort>.safeDetail).checks
            var report = EngineDoctorRuntime<AppDoctorPort>.mergeReport(current, liveChecks: live + status)
            report.checks = await DoctorReadout.repairProjection(report.checks, dataRoot: engine.dataRoot)
            report.status = DoctorReadout.doctorRollup(report.checks.map(\.status))
            return report
        }, publish: { engine.doctor.report = $0 })
    }
}
