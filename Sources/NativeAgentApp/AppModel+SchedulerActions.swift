import Foundation
import SwiftUI
import EngineRuntime
import NativeAgentCore
import NativeAgentShared
import TriggerScheduler
import SchedulerExecution
import AttentionRouting
import DoctorChecks
import WidgetKit
import AppIntents
import Observation
import PersistenceCore
import MemoryV2
import ProviderRouting
import BackgroundLoops
import PersonaEngine
import ChatTurnRuntime
import ChatSessionWork
import TrustCenter
import MultimodalTTS
import SystemOps
import TelegramBot
import DeviceSync
// Blueprint: | `AppModel+SchedulerActions.swift` | `AppModel`: scheduler and Desk creation commands; nightly reflection outcome wording |

extension NightlyReflectionJobOutcome {
    var message: String {
        switch self {
        case .added:
            return "Nightly reflection added."
        case .alreadyPresent:
            return "Nightly reflection is already scheduled."
        case .repaired:
            return "Nightly reflection schedule repaired."
        case .failed(let message):
            return "Nightly reflection could not be added: \(message)"
        }
    }

    var succeeded: Bool {
        if case .failed = self { return false }
        return true
    }
}

@MainActor
extension AppModel {
    @MainActor
    @discardableResult
    func refreshSchedulerJobs() async -> SchedulerJobsFeedState? {
        let feed = await engine.desk.refreshJobs()
        if let detail = feed?.failureDetail { statusText = detail }
        return feed
    }

    /// The scheduler switch reflects the persisted job after every attempted change.
    @MainActor
    func setSchedulerJobEnabled(id: String, enabled: Bool) async -> SchedulerJobToggleOutcome {
        do {
            let job = try await engine.desk.setJobEnabled(id: id, enabled: enabled)
            await refreshSchedulerJobs()
            return .verified(job)
        } catch {
            // Re-read regardless: the switch must show the store's truth, not
            // the click's optimism.
            await refreshSchedulerJobs()
            return .failed(UserFacingError.cause(error, action: "change that job"))
        }
    }

    @MainActor
    func createDreamJob() async -> NightlyReflectionJobOutcome {
        do {
            let outcome = try await engine.desk.ensureNightlyReflection(scheduler: .shared)
            if case .failed(let message) = outcome {
                statusText = "Nightly reflection failed: \(message)"
            } else {
                statusText = outcome.message
            }
            return outcome
        } catch {
            let outcome = NightlyReflectionJobOutcome.failed(UserFacingError.cause(error, action: "add nightly reflection"))
            statusText = outcome.message
            return outcome
        }
    }

    @MainActor
    func createWorkshopTask(title: String, objective: String) async -> NewDeskTaskOutcome {
        do {
            _ = try await NativeAgentEngine.submitDeskTask(title: title, objective: objective)
            statusText = "Desk task created"
            await refreshAll()
            return .created
        } catch {
            let message = "Couldn’t create this task. \(UserFacingError.cause(error, action: "create the Desk task"))"
            setFailureStatus(message, cause: error)
            return .failed(message)
        }
    }

}
