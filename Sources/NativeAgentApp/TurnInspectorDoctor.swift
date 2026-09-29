import Foundation
import DoctorChecks

@MainActor
enum TurnInspectorDoctor {
    static weak var active: TurnInspectorStore?

    static func check() -> CheckResult {
        guard let store = active else {
            return CheckResult(id: "live.inspector_feed", title: "Inspector live feed", status: "ok",
                detail: "Inspector is closed; no live sink is expected.")
        }
        switch store.liveDropCountState {
        case .unavailable:
            return CheckResult(id: "live.inspector_feed", title: "Inspector live feed", status: "fail",
                detail: "The Inspector live sink ended; its drop count is unavailable. Events since termination cannot be recovered.",
                human_action: "Open Diagnostics → Inspector after repair and inspect saved traces for the missing interval.")
        case .measured(let count) where count > 0:
            return CheckResult(id: "live.inspector_feed", title: "Inspector live feed", status: "warn",
                detail: "Inspector dropped \(count) live event(s) under page backpressure; those live events cannot be recovered.",
                human_action: "Open Diagnostics → Inspector → Replay and inspect today's saved trace for the affected turn.")
        case .measured:
            return CheckResult(id: "live.inspector_feed", title: "Inspector live feed", status: "ok",
                detail: store.liveSinkActive
                    ? "Inspector live sink is active with no measured drops."
                    : "Inspector live sink is starting; no drop count is available yet.")
        }
    }

    static func repairDeadSink() -> DoctorRepairAttempt {
        guard let store = active, store.liveDropCountState == .unavailable else {
            return .unverified("Repair skipped: the Inspector sink is no longer terminated.")
        }
        store.stop()
        store.start()
        return .completed("Completed: restarted the Inspector subscription task; the sink will be confirmed on the next Doctor read.")
    }
}

extension NativeClient {
    func doctorInspectorCheck() async -> CheckResult {
        await TurnInspectorDoctor.check()
    }

    func doctorInspectorRepair(for check: CheckResult) async -> DoctorExecutableRepair? {
        guard check.id == "live.inspector_feed", check.status == "fail" else { return nil }
        return DoctorExecutableRepair(checkID: check.id) {
            await TurnInspectorDoctor.repairDeadSink()
        }
    }
}
