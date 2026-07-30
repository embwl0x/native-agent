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
import CapabilityFoundry

@MainActor
extension AppModel {
    func fetchEmbeddingsStatus() async throws -> EmbeddingsStatus {
        try await client.getEmbeddingsStatus()
    }

    @MainActor
    func toggleEmbeddingsBackend(enabled: Bool) async throws -> EmbeddingsToggleResult {
        try await client.setEmbeddingsBackend(enabled: enabled)
    }

    @MainActor
    func setEmbeddingsMemoryMode(mode: String) async throws -> EmbeddingsToggleResult {
        try await client.setEmbeddingsMemoryMode(mode: mode)
    }

    @MainActor
    func releaseEmbeddingsMemory() async throws -> EmbeddingsToggleResult {
        try await client.releaseEmbeddingsMemory()
    }

    @MainActor
    func startEmbeddingsInstall() async throws -> EmbeddingsInstallKickoff {
        try await client.installEmbeddingsExtra()
    }

    // WAVE 31 (2026-06-01): pollEmbeddingsInstall() removed — it had zero call
    // sites. Install progress is polled via fetchEmbeddingsStatus() (the
    // EmbeddingsStatus.installState field). The daemon GET /v1/embeddings/install/status
    // route is retired this wave. See CUTOVER_PLAN.md §6.55.

    // PATCH-2026-05-08: wave3-health-card Feature A — load health card
    @MainActor
    func loadHealthCard(includeApprovals: Bool = true) async {
        // Fix 10: catch and log decode/network errors instead of silently swallowing them
        do {
            healthCard = try await client.getHealthCard()
        } catch {
            print("[NativeAgent] loadHealthCard failed: \(error)")
            healthCard = HealthCard(
                overall: "error",
                subsystems: [
                    HealthCardSubsystem(
                        id: "runtime",
                        label: "Runtime",
                        status: "error",
                        detail: "Health check failed: \(error.localizedDescription)",
                        fixAction: "doctor"
                    )
                ],
                createdAt: nil
            )
        }
        if includeApprovals {
            do {
                approvals = try await client.getApprovals()
            } catch {
                // FIX: previously only print()'d, leaving stale approvals on
                // screen. Clear the list and surface the failure so the UI
                // doesn't show outdated/phantom approvals.
                print("[NativeAgent] getApprovals failed: \(error)")
                approvals = []
                statusText = "Approvals unavailable: \(error.localizedDescription)"
            }
        }
    }

    // PATCH-2026-05-08: wave3-whats-running Feature B — load what's running
    @MainActor
    func loadWhatsRunning() async {
        // Fix 10: catch and log instead of silently swallowing
        do {
            whatsRunning = try await client.getWhatsRunning()
            whatsRunningRefreshStatus = Self.nextRefreshStatus(
                previous: whatsRunningRefreshStatus,
                failedEndpoints: [],
                at: Date()
            )
        } catch {
            print("[NativeAgent] loadWhatsRunning failed: \(error)")
            whatsRunningRefreshStatus = Self.nextRefreshStatus(
                previous: whatsRunningRefreshStatus,
                failedEndpoints: ["running work"],
                at: Date()
            )
        }
    }

    // PATCH-2026-05-08: wave2-chat-ux slash /compact support
}
