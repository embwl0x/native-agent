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
            setHealthCardIfMeaningfullyChanged(try await client.getHealthCard())
        } catch {
            print("[NativeAgent] loadHealthCard failed: \(error)")
            setHealthCardIfMeaningfullyChanged(HealthCard(
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
            ))
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

    /// The live health poll intentionally runs while chat is visible, but its
    /// `createdAt` timestamp is not rendered anywhere. Treating that timestamp
    /// as UI state forced a complete health-surface layout every 15 seconds even
    /// when every visible verdict was identical.
    @MainActor
    func setHealthCardIfMeaningfullyChanged(_ next: HealthCard) {
        if healthCard?.overall != next.overall || healthCard?.subsystems != next.subsystems {
            healthCard = next
        }
    }

    // PATCH-2026-05-08: wave3-whats-running Feature B — load what's running
    @MainActor
    func loadWhatsRunning() async {
        // Fix 10: catch and log instead of silently swallowing
        // Render-cost audit F14 (wave 2). This is the 10 s `chat-whats-running`
        // poll (`ChatRuntimeStatusChrome.swift:70-77`), so on an idle system it
        // fires 6×/min with a byte-identical answer. Both writes were
        // unconditional and Observation fires on *write*, not on *change*, so
        // every tick redrew `WhatsRunningPanel`.
        //
        // The status goes through `staleFlagOnlyStatusToStore` — valid here
        // because the ONLY reader is `WhatsRunningPresentation.make`
        // (`ChatRuntimeStatusChrome.swift:241-271`) and it projects exactly
        // three things: `status == nil`, `status?.isStale`, and
        // `status?.lastSuccessAt != nil`. The helper stores the first-ever
        // status (so nil-ness is preserved) and stores whenever
        // `failedEndpoints` differs (so `isStale` and the success→failure and
        // failure→success transitions are preserved); the only skipped case is
        // "same failure set as last time", where carrying the previous
        // timestamps forward leaves `lastSuccessAt`'s nil-ness identical to
        // what `nextRefreshStatus` would have produced. Nothing renders the
        // timestamps themselves.
        //
        // The snapshot itself is equality-gated separately: `WhatsRunning` is
        // `Hashable` (Models/ConfigProviderDoctorModels.swift:828). Gating the
        // status alone would have bought nothing — `WhatsRunningPanel` reads
        // `appModel.whatsRunning` directly, so the snapshot write is the one
        // that was actually redrawing it.
        func storeStatus(failedEndpoints: [String]) {
            if let next = Self.staleFlagOnlyStatusToStore(
                previous: whatsRunningRefreshStatus,
                failedEndpoints: failedEndpoints,
                at: Date()
            ) {
                whatsRunningRefreshStatus = next
            }
        }
        do {
            let fetched = try await client.getWhatsRunning()
            if whatsRunning != fetched { whatsRunning = fetched }
            storeStatus(failedEndpoints: [])
        } catch {
            print("[NativeAgent] loadWhatsRunning failed: \(error)")
            storeStatus(failedEndpoints: ["running work"])
        }
    }

    // PATCH-2026-05-08: wave2-chat-ux slash /compact support
}
