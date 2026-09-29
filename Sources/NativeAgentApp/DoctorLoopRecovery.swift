import BackgroundLoops
import DoctorChecks
import Foundation
import PersistenceCore
import Privacy

/// Core's live registration and the launch manifest's IDs are passive inputs.
enum DoctorLoopRecovery {
    static let checkPrefix = "live.background_loop."
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

    static func checks(
        manager: NativeAppBackgroundLoopsManager,
        dataRoot: URL
    ) async -> [CheckResult] {
        let statuses = await manager.coreManager.status()
        let managerRunning = await manager.coreManager.isRunning()
        let configured = await manager.assembledLoopIntervalsSnapshot()
        let byID = Dictionary(uniqueKeysWithValues: statuses.map { ($0.name, $0) })
        let now = Date()
        let receipts = DoctorLoopHealth.recentFailureDates(
            receiptsFile: dataRoot.appendingPathComponent("logs/background_loop_failures.jsonl")
        )
        let verdicts = DoctorLoopHealth.evaluate(
            observations: statuses.map(LoopHealthObservation.init(status:)),
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
            let level = pending.contains(id) && verdict?.level == .ok ? LoopHealthLevel.warn : verdict?.level ?? .fail
            let state = (verdict?.detail ?? "The app-owned loop is absent from the live manager.")
                + (pending.contains(id) ? " Restarted; recovery unverified until its next successful run." : "")
            let lastFailure = status?.lastError.map {
                " Last failure: \(NativeAppSecretRedactor.redactText(String($0.prefix(500))))."
            } ?? ""
            let interval = configured[id] ?? status?.interval ?? 300
            let detail = "Configured interval: \(Int(interval)) seconds. "
                + NativeAppSecretRedactor.redactText(String(state.prefix(700))) + lastFailure
            return CheckResult(
                id: checkPrefix + id,
                title: "Background loop: \(id)",
                status: level == .ok ? "ok" : level == .fail ? "fail" : "warn",
                detail: detail,
                human_action: level == .ok ? nil : pending.contains(id) && status?.running == true && status?.lastError == nil
                    ? "Wait for \(id)'s next successful run, then run Diagnostics → Doctor again."
                    : humanAction(loopID: id, status: status, managerRunning: managerRunning)
            )
        }
    }

    static func repair(
        checkID: String,
        manager: NativeAppBackgroundLoopsManager,
        dataRoot: URL
    ) async -> DoctorExecutableRepair? {
        guard checkID.hasPrefix(checkPrefix) else { return nil }
        let id = String(checkID.dropFirst(checkPrefix.count))
        guard NativeAppBackgroundLoopsManager.hotReloadableLoopIDs.contains(id),
              await manager.coreManager.isRunning() else { return nil }
        let configured = await manager.assembledLoopIntervalsSnapshot()
        guard configured[id] != nil else { return nil }
        let statuses = await manager.coreManager.status()
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
                observations: [LoopHealthObservation(status: status)],
                recentFailureDates: receipts,
                now: Date()
            ).first?.level != .ok else { return nil }
        }
        return DoctorExecutableRepair(checkID: checkID) {
            guard await manager.coreManager.isRunning(),
                  await manager.assembledLoopIntervalsSnapshot()[id] != nil else {
                return .unverified("Repair skipped: \(id) is no longer in the running app's loop configuration.")
            }
            let outcome = await manager.restartLoop(id: id)
            guard outcome.didRestart else {
                await verification.clear(id)
                return .unverified("Repair attempted: \(id) could not be re-registered.")
            }
            let restartedAt = Date()
            await verification.mark(id, at: restartedAt)
            guard let after = await manager.coreManager.status().first(where: { $0.name == id }),
                  after.running else {
                return .unverified("Repair attempted: \(id) is still missing or stopped.")
            }
            if let successfulAt = after.lastSuccessfulWorkAt, successfulAt > restartedAt {
                return .completed("Completed: restarted \(id)'s app-owned registration and confirmed its next successful run.")
            }
            return .unverified("Restarted \(id)'s app-owned registration; recovery unverified until its next successful run.")
        }
    }

    private static func humanAction(
        loopID: String, status: LoopStatus?, managerRunning: Bool
    ) -> String {
        let reason = [status?.lastError, status?.lastResult]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        if loopID == "offdisk_backup", reason.contains("icloud drive") {
            return DoctorLoopHealth.iCloudDriveStep
        }
        if loopID == "telegram_poll", reason.contains("unauthoriz") || reason.contains("token") {
            return "Open Connectors → Telegram, reconnect the bot token, then run Doctor again."
        }
        if loopID == "slack_socket_mode", reason.contains("auth") || reason.contains("token") {
            return "Open Connectors → Slack, reconnect the workspace token, then run Doctor again."
        }
        if reason.contains("network") || reason.contains("offline") || reason.contains("timed out") {
            return "Connect this Mac to the internet, then run Diagnostics → Doctor again."
        }
        if managerRunning, NativeAppBackgroundLoopsManager.hotReloadableLoopIDs.contains(loopID) {
            return "Open Diagnostics → Doctor and press Repair to restart \(loopID)'s registration."
        }
        if status?.running != true {
            return "Quit and reopen NativeAgent to restart background scheduling for \(loopID)."
        }
        return "Open Diagnostics → Doctor, copy \(loopID)'s status detail, and send it to support."
    }
}
