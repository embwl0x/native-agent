import BackgroundLoops
import DoctorChecks
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import Privacy
import Experiences
// Blueprint: | `DoctorLoopRecovery.swift` | `DoctorLoopRecovery` enum; `checks`, `repair` over core loop-manager state |

public enum DoctorLoopRecovery {
    public static let checkPrefix = "live.background_loop."
    /// A not-needed reading settles an obligation whose loop is outside the mounted fleet.
    static let retired = ["github_tracking": "GitHub tracking was retired with the GitHub connector; nothing runs it."]

    public static func checks(
        manager: BackgroundLoops.BackgroundLoopLifetimes,
        dataRoot: URL,
        friendlyLoopName: (String) -> String
    ) async -> [CheckResult] {
        let statuses = await manager.status()
        let managerRunning = await manager.isRunning()
        let configured = await manager.configuredLoops()
        let byID = Dictionary(uniqueKeysWithValues: statuses.map { ($0.name, $0) })
        let now = Date()
        let receipts: [String: [DoctorLoopHealth.FailureIncident]]
        do {
            receipts = try await DoctorLoopHealth.recentFailureDates(dataRoot: dataRoot)
        } catch {
            return [CheckResult(source: "Loop failure details", id: DoctorLoopHealth.doctorCheckID,
                title: "Background Loops", status: "unmeasured",
                detail: "Loop failure history is unavailable: \(error.localizedDescription)",
                human_action: "Preserve and repair the background loop failure ledger, then run Doctor again.")]
        }
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
            for id in loopIDs.union(retired.keys) {
                let owed = open.filter { $0.owes["repair"]?.phase.isSettled == false
                    && RepairDebt($0).operation == "doctor.check:" + checkPrefix + id }
                if owed.contains(where: { experience in
                    // A legitimate idle tick still proves the loop runs; otherwise work that finds nothing could owe forever.
                    guard let at = NativeTimestampFormat.parseISO8601FractionalFirst(experience.at),
                          let status = byID[id],
                          let clean = status.lastError == nil ? status.lastRun : status.lastSuccessfulWorkAt else { return true }
                    return clean <= at
                }) { pending.insert(id) }
            }
        } catch {
            // A stopped run read nothing: that says nothing about the store's health, so it owes the person no repair.
            if error is CancellationError { return [] }
            return [CheckResult(source: "experiences/experiences.sqlite",
                id: "doctor.repair_store", title: "Repairs owed", status: "fail",
                detail: "Background work repair obligations could not be read: \(error.localizedDescription)",
                human_action: ToolFailureError.fileRepairInstruction(dataRoot.appendingPathComponent("experiences/experiences.sqlite"),
                    shape: """
                        This SQLite experience store retains original experiences, claims, evidence and obligation phases. Preserve their identities and \
                        settlement history.
                        """))]
        }
        let retirements = retired.filter { pending.contains($0.key) }.sorted { $0.key < $1.key }.map { id, why in
            CheckResult(source: "Background loop registration: " + id, id: checkPrefix + id, title: "Background loop: \(id)",
                        status: "not needed", detail: why)
        }
        return retirements + loopIDs.sorted().map { id in
            let status = byID[id]
            let verdict = verdictByID[id]
            let level = verdict?.level ?? .fail
            // Off-by-config and not-needed are deliberate states, not missing registrations or owed repairs.
            let off = level == .off || level == .notNeeded
            let waiting = pending.contains(id) && !off
            let state = (verdict?.detail ?? "The app-owned loop is absent from the live manager.")
                .trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines))
                + (waiting ? "; repair remains owed until this loop completes a clean tick" : "")
            let lastFailure = status?.lastError.map {
                """
        ; last failure: \
        \(NativeAppSecretRedactor.redactText(String($0.prefix(500))).trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines)))
        """
            } ?? ""
            let timing: String
            if let wake = configured[id]?.runner?.wake {
                if let period = wake.period { timing = "Configured rhythm: \(Int(period)) seconds" }
                else { timing = "Runs on change; never periodically overdue" }
            } else { timing = "Configured wake unavailable" }
            let detail = timing + "; "
                + NativeAppSecretRedactor.redactText(String(state.prefix(700))) + lastFailure + "."
            let failure = [status?.lastError, status?.lastResult].compactMap { $0 }.joined(separator: " ")
            let action = MaintenanceBackgroundWork.loopSettingFix(loopId: id, error: failure)
            let missingRegistration = !off && managerRunning && configured[id] != nil && status?.running != true
            // Offline state has no faulty owner; unexplained persistent failure belongs to the loop’s code.
            let offline = ["network", "offline", "timed out", "not connected to the internet"].contains { failure.lowercased().contains($0) }
            let durable = missingRegistration || (level.isFault && action?.ask != nil) || (level == .fail && !offline)
            return CheckResult(source: action?.step ?? "Background loop registration: " + id,
                id: checkPrefix + id,
                title: "Background loop: \(id)",
                // Durability chooses the healer, never erases a measured fault.
                status: missingRegistration || level == .fail ? "fail" : level == .warn || waiting ? "warn" : level.statusText,
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
        manager: BackgroundLoops.BackgroundLoopLifetimes,
        dataRoot: URL,
        restart: @escaping @Sendable (String) async -> LoopRestartOutcome
    ) async -> DoctorExecutableRepair? {
        guard checkID.hasPrefix(checkPrefix) else { return nil }
        let id = String(checkID.dropFirst(checkPrefix.count))
        guard MaintenanceBackgroundWork.hotReloadableLoopIDs.contains(id),
              await manager.isRunning() else { return nil }
        let configured = await manager.configuredLoops()
        guard configured[id] != nil else { return nil }
        let statuses = await manager.status()
        let status = statuses.first(where: { $0.name == id })
        guard status?.executing != true else { return nil }
        guard status?.running != true else { return nil }
        return DoctorExecutableRepair(checkID: checkID) {
            guard await manager.isRunning(),
                  await manager.configuredLoops()[id] != nil else {
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
