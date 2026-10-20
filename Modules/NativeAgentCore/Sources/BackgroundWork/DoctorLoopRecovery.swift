import BackgroundLoops
import DoctorChecks
import Foundation
import PersistenceCore
import Privacy
import Experiences

/// Core's live registration and the launch manifest's IDs are passive inputs.
public enum DoctorLoopRecovery {
    public static let checkPrefix = "live.background_loop."

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
        do {
            let open = try await ExperienceStore.at(dataRoot).projection()
            for id in loopIDs {
                let owed = open.filter { $0.owes["repair"]?.phase.isSettled == false
                    && $0.claims.contains { $0.claim == "operation: doctor.check:" + checkPrefix + id } }
                let format = ISO8601DateFormatter()
                format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if owed.contains(where: { experience in
                    guard let at = format.date(from: experience.at) ?? ISO8601DateFormatter().date(from: experience.at),
                          let success = byID[id]?.lastSuccessfulWorkAt else { return true }
                    return success <= at
                }) { pending.insert(id) }
            }
        } catch {
            return [CheckResult(source: "experiences/experiences.sqlite", id: "doctor.repair_store", title: "Repairs owed", status: "fail",
                detail: "Background work repair obligations could not be read: \(error.localizedDescription)")]
        }
        return loopIDs.sorted().map { id in
            let status = byID[id]
            let verdict = verdictByID[id]
            let level = verdict?.level ?? .fail
            // Off by config or not needed is a state, not a missing registration
            // and not an owed repair (0.6.9 night: Slack, never connected, read
            // "fail, repair owed" on a fresh install).
            let off = level == .off || level == .notNeeded
            let waiting = pending.contains(id) && !off
            let state = (verdict?.detail ?? "The app-owned loop is absent from the live manager.")
                + (waiting ? " Repair remains owed until this loop completes successful work." : "")
            let lastFailure = status?.lastError.map {
                " Last failure: \(NativeAppSecretRedactor.redactText(String($0.prefix(500))))."
            } ?? ""
            let interval = configured[id] ?? status?.interval ?? 300
            let detail = "Configured interval: \(Int(interval)) seconds. "
                + NativeAppSecretRedactor.redactText(String(state.prefix(700))) + lastFailure
            let failure = [status?.lastError, status?.lastResult].compactMap { $0 }.joined(separator: " ")
            let action = MaintenanceBackgroundWork.loopSettingFix(loopId: id, error: failure)
            let missingRegistration = !off && managerRunning && configured[id] != nil && status?.running != true
            // Being offline is no owner's fault however often it recurs; any other
            // persistent failure no setting explains is the loop's code to fix.
            let offline = ["network", "offline", "timed out", "not connected to the internet"].contains { failure.lowercased().contains($0) }
            let durable = missingRegistration || (level.isFault && action?.ask != nil) || (level == .fail && !offline)
            return CheckResult(source: action?.step ?? "Background loop registration: " + id,
                id: checkPrefix + id,
                title: "Background loop: \(id)",
                // A single failed tick is an observation; a persistent failure or a
                // broken schedule is durable. Its lever is the setting, the native
                // restart, or, where neither changes it, the build.
                status: durable ? "fail" : level.isFault || waiting ? "unmeasured" : level.statusText,
                detail: detail,
                harm: missingRegistration ? "\(friendlyLoopName(id)) has no running registration."
                    : durable ? "\(friendlyLoopName(id)) is failing or is not being done on schedule." : nil,
                human_action: !level.isFault ? nil : action?.step,
                ask: !level.isFault ? nil : action?.ask,
                owner: durable && action == nil ? .builder : nil
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
        guard status?.running != true else { return nil }
        return DoctorExecutableRepair(checkID: checkID) {
            guard await manager.isRunning(),
                  await manager.configuredIntervals()[id] != nil else {
                return .unverified("Repair skipped: \(id) is no longer in the running app's loop configuration.")
            }
            let outcome = await restart(id)
            guard outcome.didRestart else {
                return .unverified("Repair attempted: \(id) could not be re-registered.")
            }
            let restartedAt = Date()
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

}
