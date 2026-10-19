import AppToolRuntime
import Cognition
import Foundation
import NativeAgentShared
import PersistenceCore
import ToolExecution

extension AppQuietToolHost {
    // MARK: - mind_run

    func runMind(verb: String, input: [String: JSONValue]) async -> QuietMindOutcome {
        if verb == "trigger_fire" {
            guard case .string(let surface)? = input["surface"], ["inbox", "workshop"].contains(surface),
                  case .string(let name)? = input["name"], !name.isEmpty else {
                return (false, "Pass surface (inbox or workshop) and name from the trigger's repair obligation.", [:])
            }
            let occurrence: String? = if case .string(let value)? = input["occurrence"] { value } else { nil }
            let result = await NativeAgentEngine.makeNativeTriggerScheduler(dataRoot: appModel.engine.dataRoot)
                .repairTrigger(surface: surface, name: name, occurrence: occurrence)
            return (result.status == "fired", result.error ?? "Trigger \(name): \(result.status).", [:])
        }
        if verb == "rem", input["repair"] == .bool(true) {
            do {
                _ = try await NativeAgentEngine.runRem(dataRoot: appModel.engine.dataRoot, repair: true)
                return (true, "REM staging checked under Trust and archival completed without generating new proposals.", [:])
            } catch { return (false, error.localizedDescription, [:]) }
        }
        if verb == "misses" { return await AppToolExecutor.quietMindMisses(dataRoot: appModel.engine.dataRoot) }
        return await AppToolExecutor.runQuietMind(
            verb: verb, input: input, runtime: NativeAgentEngine.liveCognition,
            dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot(), remPolicy: trustPolicy,
            dreamEnabled: { await dreamEnabled() },
            runDream: {
                let succeeded = await appModel.runDreamPassForDreams()
                return (succeeded, appModel.statusForAgent, appModel.dreamError)
            }, runREM: {
                let feedback = await appModel.runRemPass()
                return (feedback.isSuccess, feedback.message)
            }, runGrowth: {
                let run = await SelfImprovementView.runManually(appModel: appModel)
                let completed: Bool
                if case .completed? = run.outcome { completed = true } else { completed = false }
                return (completed || run.outcome?.isCoalescedSkip == true, run.note)
            })
    }

    // MARK: - skill_manage

    func manageSkill(verb: String, input: [String: JSONValue], steer: [String]) async -> QuietMindOutcome {
        let outcome = await CapabilityLifecycleCommands(dataRootOverride: appModel.dataRootOverride,
            tools: appModel.engine.tools, formatFailure: { error, action in
                UserFacingError.message(error, action: action)
            }).manageSkill(verb: verb, input: input, steer: steer)
        if outcome.refreshSkills { await appModel.loadSkillManifests() }
        // The Tools page's own refresh, its catalog too, so a dropped tool leaves
        // both lists; before the verb's status, which the refresh must not overwrite.
        if outcome.refreshTools { _ = await appModel.refreshForSidebarItem(.tools) }
        if let status = outcome.toolStatus {
            appModel.recordToolOperationStatus(status.message, outcome: status.succeeded ? .succeeded : .failed)
            appModel.statusCause = status.cause
        }
        return (outcome.ok, outcome.detail, outcome.fields)
    }

}
