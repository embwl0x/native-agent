import Foundation
import Darwin
import AppKit
@preconcurrency import EventKit
import SwiftUI
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import MemoryV2
import ToolRegistry
import KnowledgeGraph
import XConnector
import SlackConnector
import ProviderRouting
import BackgroundLoops
import ApprovalInbox
import MCPDispatcher
import ToolExecution
import PersonaEngine
import ChatOrchestration
import TrustCenter
import DreamREMCycle
import DoctorChecks
import CommandPalette
import SelfImprovement
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
import MacAssistantStatus
import WorkflowOrchestration
import Skills
import Connectors
import Browser


extension NativeClient {
    func startOnboarding() async throws -> OnboardingStartResponse {
        // WAVE 15 (2026-06-01): Swift-only — daemon route retired.
        let impl = makeOnboardingClient()
        let r = try await impl.startOnboarding()
        let options = r.personaTypeOptions.map {
            PersonaTypeOption(
                id: $0.id,
                label: $0.label,
                description: $0.description,
                sampleAnchor: $0.sampleAnchor,
                pronouns: $0.pronouns
            )
        }
        let overview = r.abilityOverview.map {
            OnboardingAbility(
                id: $0.id,
                title: $0.title,
                detail: $0.detail,
                systemImage: $0.systemImage
            )
        }
        return OnboardingStartResponse(
            ready: r.ready,
            hasExisting: r.hasExisting,
            currentPersonaName: r.currentPersonaName,
            personaTypeOptions: options,
            abilityOverview: overview,
            pendingRecovery: r.pendingRecovery,
            resetRequired: r.resetRequired
        )
    }

    func resumePendingOnboarding() async throws -> OnboardingCompleteResponse {
        let r = try await makeOnboardingClient().resumePendingOnboarding()
        if r.ok {
            await refreshResidentMindAfterOnboardingTransition()
        }
        return OnboardingCompleteResponse(
            ok: r.ok,
            agentName: r.agentName,
            personaType: r.personaType,
            userName: r.userName,
            docsWritten: r.docsWritten,
            error: r.error,
            detail: r.detail
        )
    }

    /// Wave 20 (2026-06-01): SwiftNative-only.
    func completeOnboarding(agentName: String, personaType: String, userName: String) async throws -> OnboardingCompleteResponse {
        let impl = makeOnboardingClient()
        let r = try await impl.completeOnboarding(payload: OnboardingCompletePayload(
            agentName: agentName, personaType: personaType, userName: userName
        ))
        if r.ok {
            await refreshResidentMindAfterOnboardingTransition()
        }
        return OnboardingCompleteResponse(
            ok: r.ok,
            agentName: r.agentName,
            personaType: r.personaType,
            userName: r.userName,
            docsWritten: r.docsWritten,
            error: r.error,
            detail: r.detail
        )
    }

    /// Wave 20 (2026-06-01): SwiftNative-only.
    func resetOnboarding(confirm: Bool = true) async throws -> OnboardingResetResponse {
        let impl = makeOnboardingClient()
        let r = try await impl.resetOnboarding(confirm: confirm)
        if r.ok {
            await refreshResidentMindAfterOnboardingTransition()
        }
        return OnboardingResetResponse(
            ok: r.ok,
            backedUp: r.backedUp,
            readyForOnboarding: r.readyForOnboarding,
            error: r.error
        )
    }

    // SUBSYSTEM #17: retired Swift wrapper checkOnboardingNeeded — startOnboarding() remains live.

    private func refreshResidentMindAfterOnboardingTransition() async {
        async let contextFlow: Void = NativeContextFlowRuntime.shared.reloadConfiguration()
        async let cognition = NativeCognitionRuntime.shared.refreshAfterOnboardingTransition()
        _ = await (contextFlow, cognition)
    }
}
