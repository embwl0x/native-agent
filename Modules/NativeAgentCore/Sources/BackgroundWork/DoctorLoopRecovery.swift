import BackgroundLoops
import DoctorChecks
import Foundation
import PersistenceCore
import Privacy

/// Core's live registration and the launch manifest's IDs are passive inputs.
public enum DoctorLoopRecovery {
    public static let checkPrefix = "live.background_loop."
    private static let verification = RestartVerification()

    private actor RestartVerification {
        private var restartedAt: [String: Date] = [:]

        func mark(_ id: String, at date: Date) { restartedAt[id] = date }
        func clear(_ id: String) { restartedAt.removeValue(forKey: id) }

        func pending(_ id: String, successfulAt: Date?) -> Date? {
            guard let restart = restartedAt[id] else { return nil }
            if let successfulAt, successfulAt > restart {
                restartedAt.removeValue(forKey: id)
                return nil
            }
            return restart
        }
    }

    public static func checks(
        manager: BackgroundLoops.BackgroundLoopsManager,
        dataRoot: URL,
        friendlyLoopName: (String) -> String
    ) async -> [CheckResult] {
        let statuses = await manager.status()
        let managerRunning = await manager.isRunning()
        let configured = await manager.configuredIntervals()
        let byID = Dictionary(uniqueKeysWithValues: statuses.map { ($0.name, $0) })
        let now = Date()
        let receipts = DoctorLoopHealth.recentFailureDates(
            receiptsFile: dataRoot.appendingPathComponent("logs/background_loop_failures.jsonl")
        )
        let verdicts = DoctorLoopHealth.evaluate(
            observations: statuses,
            recentFailureDates: receipts,
            now: now
        )
        let verdictByID = Dictionary(uniqueKeysWithValues: verdicts.map { ($0.loopId, $0) })
        let loopIDs = Set(configured.keys).union(byID.keys)
        var pending: Set<String> = []
        for id in loopIDs {
            if await verification.pending(id, successfulAt: byID[id]?.lastSuccessfulWorkAt) != nil {
                pending.insert(id)
            }
        }
        return loopIDs.sorted().map { id in
            let status = byID[id]
            let verdict = verdictByID[id]
            let level = verdict?.level ?? .fail
            let state = (verdict?.detail ?? "The app-owned loop is absent from the live manager.")
                + (pending.contains(id) ? " Restarted; recovery unverified until its next successful run." : "")
            let lastFailure = status?.lastError.map {
                " Last failure: \(NativeAppSecretRedactor.redactText(String($0.prefix(500))))."
            } ?? ""
            let interval = configured[id] ?? status?.interval ?? 300
            let detail = "Configured interval: \(Int(interval)) seconds. "
                + NativeAppSecretRedactor.redactText(String(state.prefix(700))) + lastFailure
            let action = humanAction(loopID: id, status: status, managerRunning: managerRunning)
            let waiting = pending.contains(id) && status?.running == true && status?.lastError == nil
            return CheckResult(
                id: checkPrefix + id,
                title: "Background loop: \(id)",
                status: waiting && level == .ok ? "unmeasured" : level == .fail ? "fail" : level.statusText,
                detail: detail,
                harm: level.isFault ? "\(friendlyLoopName(id)) is failing or is not being done on schedule." : nil,
                human_action: !level.isFault ? nil : action.step,
                ask: !level.isFault ? nil : action.ask
            )
        }
    }

    public static func repair(
        checkID: String,
        manager: BackgroundLoops.BackgroundLoopsManager,
        dataRoot: URL,
        restart: @escaping @Sendable (String) async -> LoopRestartOutcome
    ) async -> DoctorExecutableRepair? {
        guard checkID.hasPrefix(checkPrefix) else { return nil }
        let id = String(checkID.dropFirst(checkPrefix.count))
        guard MaintenanceBackgroundWork.hotReloadableLoopIDs.contains(id),
              await manager.isRunning() else { return nil }
        let configured = await manager.configuredIntervals()
        guard configured[id] != nil else { return nil }
        let statuses = await manager.status()
        let status = statuses.first(where: { $0.name == id })
        guard status?.executing != true else { return nil }
        if let restart = await verification.pending(id, successfulAt: status?.lastSuccessfulWorkAt),
           status?.lastRun.map({ $0 <= restart }) != false {
            return nil
        }
        let receipts = DoctorLoopHealth.recentFailureDates(
            receiptsFile: dataRoot.appendingPathComponent("logs/background_loop_failures.jsonl")
        )
        if let status {
            guard DoctorLoopHealth.evaluate(
                observations: [status],
                recentFailureDates: receipts,
                now: Date()
            ).first?.level.isFault != false else { return nil }
        }
        return DoctorExecutableRepair(checkID: checkID) {
            guard await manager.isRunning(),
                  await manager.configuredIntervals()[id] != nil else {
                return .unverified("Repair skipped: \(id) is no longer in the running app's loop configuration.")
            }
            let outcome = await restart(id)
            guard outcome.didRestart else {
                await verification.clear(id)
                return .unverified("Repair attempted: \(id) could not be re-registered.")
            }
            let restartedAt = Date()
            await verification.mark(id, at: restartedAt)
            guard let after = await manager.status().first(where: { $0.name == id }),
                  after.running else {
                return .unverified("Repair attempted: \(id) is still missing or stopped.")
            }
            if let successfulAt = after.lastSuccessfulWorkAt, successfulAt > restartedAt {
                return .completed("Completed: restarted \(id)'s app-owned registration and confirmed its next successful run.")
            }
            return .unverified("Restarted \(id)'s app-owned registration; recovery unverified until its next successful run.")
        }
    }

    /// The step for User, and whether it is a sign-in or permission. A loop
    /// failing for no named reason has no step: its detail says what failed.
    private static func humanAction(
        loopID: String, status: LoopStatus?, managerRunning: Bool
    ) -> (step: String?, ask: DoctorAskKind?) {
        let failure = [status?.lastError, status?.lastResult].compactMap { $0 }.joined(separator: " ")
        if let fix = MaintenanceBackgroundWork.loopSettingFix(loopId: loopID, error: failure) { return (fix.step, fix.ask) }
        let reason = failure.lowercased()
        if reason.contains("network") || reason.contains("offline") || reason.contains("timed out") {
            return ("Connect this Mac to the internet, then run Diagnostics → Doctor again.", nil)
        }
        if managerRunning, MaintenanceBackgroundWork.hotReloadableLoopIDs.contains(loopID) {
            return ("Open Diagnostics → Doctor and press Repair to restart \(loopID)'s registration.", nil)
        }
        if status?.running != true {
            return ("Quit and reopen NativeAgent to restart background scheduling for \(loopID).", nil)
        }
        return (nil, nil)
    }
}
