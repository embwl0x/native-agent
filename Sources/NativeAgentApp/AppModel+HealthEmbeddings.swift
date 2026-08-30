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

/// Visible snapshot samplers can be triggered by their retained poll and by a
/// user action at the same time. Requests may still perform concurrently, but
/// only the newest request may publish UI state, preventing a slower old error
/// from replacing a newer successful snapshot.
struct LatestSnapshotRefreshGate: Equatable {
    private(set) var latestGeneration: UInt64 = 0

    mutating func begin() -> UInt64 {
        latestGeneration &+= 1
        return latestGeneration
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        generation == latestGeneration
    }
}

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
        let healthGeneration = healthCardRefreshGate.begin()
        // Fix 10: catch and log decode/network errors instead of silently swallowing them
        let nextHealthCard: HealthCard
        do {
            nextHealthCard = try await client.getHealthCard()
        } catch {
            guard !Task.isCancelled else { return }
            print("[NativeAgent] loadHealthCard failed: \(error)")
            nextHealthCard = HealthCard(
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
        guard !Task.isCancelled else { return }
        if healthCardRefreshGate.isCurrent(healthGeneration) {
            setHealthCardIfMeaningfullyChanged(nextHealthCard)
        }
        if includeApprovals {
            do {
                approvals = try await client.getApprovals()
            } catch {
                guard !Task.isCancelled else { return }
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
        let refreshGeneration = whatsRunningRefreshGate.begin()
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
            guard !Task.isCancelled else { return }
            guard whatsRunningRefreshGate.isCurrent(refreshGeneration) else { return }
            if whatsRunning != fetched { whatsRunning = fetched }
            storeStatus(failedEndpoints: [])
        } catch {
            guard !Task.isCancelled else { return }
            print("[NativeAgent] loadWhatsRunning failed: \(error)")
            guard whatsRunningRefreshGate.isCurrent(refreshGeneration) else { return }
            storeStatus(failedEndpoints: ["running work"])
        }
    }

    // PATCH-2026-05-08: wave2-chat-ux slash /compact support
}
