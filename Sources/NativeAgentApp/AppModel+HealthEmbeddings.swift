import Foundation
import Observation
import Darwin
import AppKit
@preconcurrency import EventKit
import SwiftUI
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import MemoryV2
import ToolRegistry
import ProviderRouting
import BackgroundLoops
import ApprovalInbox
import ToolExecution
import PersonaEngine
import TrustCenter
import DreamREMCycle
import DoctorChecks
import EngineRuntime
import Research
import MultimodalTTS
import TriggerScheduler
import WorkshopExecution
import NotificationInbox
import SystemOps
import ScreenVision
import TelegramBot
import Dispatcher
import MacControl
import Onboarding
import MacIntegration
import WorkflowOrchestration
import Connectors
import Browser
// Blueprint: | `AppModel+HealthEmbeddings.swift` | `AppModel`: `loadHealthCard`, `setHealthCardIfMeaningfullyChanged`; the Doctor owner's `LatestRead` orders health-card publication |

@MainActor
extension AppModel {
    // PATCH-2026-05-08: wave3-health-card Feature A — load health card
    @MainActor
    func loadHealthCard(includeApprovals: Bool = true) async {
        _ = await engine.doctor.healthCardRead.read({
        // Fix 10: catch and log decode/network errors instead of silently swallowing them
        let nextHealthCard: HealthCard
        do {
            nextHealthCard = try await AppDoctorPort(dataRoot: engine.dataRoot, backgroundLoopsManager: backgroundLoopsManager).runtime.getHealthCard()
        } catch {
            print("[NativeAgent] loadHealthCard failed: \(error)")
            nextHealthCard = HealthCard(
                overall: "error",
                subsystems: [
                    HealthCardSubsystem(
                        id: "runtime",
                        label: "Runtime",
                        status: "error",
                        detail: UserFacingError.message(error, action: "run the health check"),
                        fixAction: "doctor"
                    )
                ],
                createdAt: nil
            )
        }
        return nextHealthCard
        }, publish: { setHealthCardIfMeaningfullyChanged($0) })
        guard !Task.isCancelled else { return }
        if includeApprovals {
            do {
                _ = try await engine.approvals.list()
            } catch {
                guard !Task.isCancelled else { return }
                // The facade keeps the last read and exposes its failure to
                // every approval surface.
                print("[NativeAgent] getApprovals failed: \(error)")
                setFailureStatus(error, action: "load approvals")
            }
        }
    }

    /// The live health poll intentionally runs while chat is visible, but its
    /// `createdAt` timestamp is not rendered anywhere. Treating that timestamp
    /// as UI state forced a complete health-surface layout every 15 seconds even
    /// when every visible verdict was identical.
    @MainActor
    func setHealthCardIfMeaningfullyChanged(_ next: HealthCard) {
        let current = engine.doctor.healthCard
        if current?.overall != next.overall || current?.subsystems != next.subsystems {
            engine.doctor.healthCard = next
        }
    }

}
