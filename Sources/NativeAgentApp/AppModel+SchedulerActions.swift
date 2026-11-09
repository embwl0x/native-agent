import Foundation
import SwiftUI
import EngineRuntime
import NativeAgentCore
import NativeAgentShared
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
// Blueprint: | `AppModel+SchedulerActions.swift` | `AppModel`: Desk creation commands |

@MainActor
extension AppModel {
    @MainActor
    func createDeskTask(title: String, objective: String) async -> NewDeskTaskOutcome {
        do {
            _ = try await NativeAgentEngine.submitDeskTask(title: title, objective: objective)
            statusText = "Desk task created"
            await refreshAll()
            return .created
        } catch {
            let message = "Couldn’t create this task. \(UserFacingError.cause(error, action: "create the Desk task"))"
            setFailureStatus(message, cause: error)
            return .failed(.interrupted(error))
        }
    }

}
