import AppToolRuntime
import Cognition
import Foundation
import NativeAgentShared
import PersistenceCore
import ToolExecution

extension AppQuietToolHost {
    // MARK: - mind_run

    func runMind(verb: String, input: [String: JSONValue]) async -> QuietMindOutcome {
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
        if let status = outcome.toolStatus {
            appModel.recordToolOperationStatus(status.message, outcome: status.succeeded ? .succeeded : .failed)
            appModel.statusCause = status.cause
        }
        if outcome.refreshTools, let reloaded = try? await appModel.engine.tools.listAuthored() {
            appModel.engine.tools.authored = reloaded
        }
        return (outcome.ok, outcome.detail, outcome.fields)
    }

}
