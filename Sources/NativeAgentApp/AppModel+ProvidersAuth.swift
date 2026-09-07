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

/// Result of asking the Swift-owned device-login manager to start OAuth.
/// `started` does not, by itself, claim that macOS opened a browser or that
/// authorization has completed.
enum CodexOAuthLoginLaunchOutcome: Equatable {
    case started(CodexDeviceLogin)
    case failed(String)
}

extension NativeClient {
    /// One trust-aware catalog projection for the Mac Tools page and the
    /// paired iPhone snapshot. This uses the same dispatcher composition as
    /// ordinary app chat, including Mac Integration availability.
    func getChatToolCatalogSnapshot() async throws -> ChatToolCatalogSnapshot {
        let inner = SwiftToolDispatcher(
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot(),
            macIntegrationBridge: MacIntegrationBridgeImpl()
        )
        let dispatcher = AppChatToolDispatcher(inner: inner)
        let envelope = try await dispatcher.dispatch(
            tool: "tool_catalog",
            input: ["detail": .string("full")],
            surface: "chat"
        )
        guard let snapshot = ChatToolCatalogSnapshot.from(jsonValue: envelope) else {
            throw NSError(
                domain: "NativeAgent.ChatToolCatalog",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Tool catalog returned an invalid envelope."]
            )
        }
        return snapshot
    }
}

@MainActor
extension AppModel {
    @MainActor
    func verifyCodex() async {
        do {
            let result = try await client.verifyCodex()
            codexAuthStatus = try? await client.getCodexAuthStatus()
            statusText = result.ok ? "Codex ready: \(result.model)" : "Codex check failed"
        } catch {
            statusText = "Codex check failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    @discardableResult
    func refreshChatToolCatalog() async -> Bool {
        chatToolCatalogLoadFailed = false
        chatToolCatalogLoadError = nil
        do {
            chatToolCatalog = try await client.getChatToolCatalogSnapshot()
            return true
        } catch {
            NSLog("[ChatToolCatalog] dispatch failed: \(error.localizedDescription)")
            chatToolCatalogLoadFailed = true
            chatToolCatalogLoadError = error.localizedDescription
            return false
        }
    }

    @MainActor
    @discardableResult
    func refreshToolsFromToolbar() async -> ToolsRefreshPresentation.State {
        guard !isRefreshingTools else {
            return .alreadyRefreshing
        }
        isRefreshingTools = true
        toolsRefreshState = .refreshing
        defer { isRefreshingTools = false }

        await refreshForSidebarItem(.tools)
        let result = ToolsRefreshPresentation.completion(
            panelRefresh: panelRefreshStatus[.tools],
            catalogLoadFailed: chatToolCatalogLoadFailed,
            hasCatalog: chatToolCatalog != nil
        )
        toolsRefreshState = result
        if let message = ToolsRefreshPresentation.message(for: result) {
            statusText = message
        }
        return result
    }

    @MainActor
    @discardableResult
    func refreshModelCatalog() async -> Bool {
        do {
            let catalog = try await client.getModelCatalog(refresh: true)
            modelCatalog = catalog
            // User, 2026-09-06: a refresh that never reached the provider used
            // to report success — the catalog read now says where its rows came
            // from, and this says the same thing out loud instead of claiming a
            // network round trip that did not happen. The RETURN VALUE means
            // the same thing: true only for a live read, because the callers
            // that render "refreshed" have nothing else to go on. A catalog
            // that reports no freshness at all is not a failure signal, so it
            // keeps the old answer. User, 2026-09-06: "live" here means the read
            // REACHED the provider — a partial page did, and calling it a
            // failed refresh was a lie; only pruning needs a complete list.
            let freshness = catalog.catalogFreshness
                .flatMap(ModelCatalogFreshness.init(rawValue:))
            switch freshness {
            case .staleAfterFailedRefresh:
                statusText = "Model catalog refresh failed — showing the cached list"
            case .builtInAfterFailedRefresh:
                statusText = "Model catalog refresh failed — showing the built-in list"
            case .cached:
                statusText = "Model catalog unchanged (cached)"
            case .builtIn:
                statusText = "Model catalog showing the built-in list"
            case .liveIncomplete:
                // User, 2026-09-06: a partial page used to be labelled `cached`
                // and reported as a refresh that could not reach the provider.
                // It did reach it; what it cannot claim is the whole list.
                statusText = "Model catalog refreshed; the provider's list may be partial"
            case .live, .none:
                statusText = "Model catalog refreshed"
            }
            return freshness?.reachedProvider ?? true
        } catch {
            statusText = "Model refresh failed: \(error.localizedDescription)"
            return false
        }
    }

    @MainActor
    @discardableResult
    func saveChatBrainDefaults() async -> ChatBrainSaveResult {
        let requested = currentChatBrainSelection
        if chatBrainSaveTask == nil, requested == chatBrainCanonicalSelection {
            let result = ChatBrainSaveResult.unchanged(requested)
            statusText = result.userMessage
            return result
        }

        chatBrainSaveGeneration &+= 1
        let requestedGeneration = chatBrainSaveGeneration
        chatBrainPendingSave = (requestedGeneration, requested)
        if chatBrainSaveTask == nil {
            isSavingChatBrain = true
            chatBrainSaveTask = Task { @MainActor [weak self] in
                await self?.drainChatBrainSaves()
            }
        }

        // The one writer drains every value that arrived before it quiesces.
        // All overlapping callers therefore observe the final canonical result,
        // never an intermediate success whose bytes may already be superseded.
        while let task = chatBrainSaveTask {
            await task.value
            if let completed = chatBrainLastSaveResult,
               completed.generation >= requestedGeneration {
                return completed.result
            }
        }
        let fallback = ChatBrainSaveResult.failed(
            message: "save coordinator stopped before producing a canonical result",
            rolledBackTo: chatBrainCanonicalSelection
        )
        statusText = fallback.userMessage
        return fallback
    }

    private var currentChatBrainSelection: ChatBrainSelection {
        ChatBrainSelection(
            model: chatModel,
            reasoningEffort: chatReasoningEffort,
            fastMode: chatFastMode
        )
    }

    private func drainChatBrainSaves() async {
        defer {
            isSavingChatBrain = false
            chatBrainSaveTask = nil
        }

        while let pending = chatBrainPendingSave {
            chatBrainPendingSave = nil
            let rollback = await canonicalChatBrainForRollback()
            do {
                let receipt = try await writeChatBrainSelection(pending.selection)
                if let catalog = receipt.catalog {
                    modelCatalog = catalog
                }
                chatBrainCanonicalSelection = receipt.selection

                // A newer edit arrived while this write was in flight. Leave
                // its optimistic fields visible and serialize the next write.
                if chatBrainPendingSave != nil {
                    continue
                }

                applyCanonicalChatBrainSelection(receipt.selection)
                let result = ChatBrainSaveResult.saved(receipt.selection)
                chatBrainLastSaveResult = (pending.generation, result)
                statusText = result.userMessage
                publishProviderCatalogStatusAfterBrainSave()
            } catch {
                if chatBrainPendingSave != nil {
                    // The pending latest value owns the eventual UI/readback.
                    // Do not replace it with an older rollback while it waits.
                    continue
                }
                let canonical = (try? await readCanonicalChatBrainSelection()) ?? rollback
                if let canonical {
                    chatBrainCanonicalSelection = canonical
                    applyCanonicalChatBrainSelection(canonical)
                }
                let result = ChatBrainSaveResult.failed(
                    message: error.localizedDescription,
                    rolledBackTo: canonical
                )
                chatBrainLastSaveResult = (pending.generation, result)
                statusText = result.userMessage
            }
        }
    }

    private func canonicalChatBrainForRollback() async -> ChatBrainSelection? {
        if let chatBrainCanonicalSelection { return chatBrainCanonicalSelection }
        let canonical = try? await readCanonicalChatBrainSelection()
        if let canonical { chatBrainCanonicalSelection = canonical }
        return canonical
    }

    private func writeChatBrainSelection(
        _ selection: ChatBrainSelection
    ) async throws -> ChatBrainWriteReceipt {
        if let chatBrainWriteOverride {
            return try await chatBrainWriteOverride(selection)
        }
        let catalog = try await client.configureModel(
            surface: "chat",
            model: selection.model,
            reasoningEffort: selection.reasoningEffort,
            serviceTier: selection.fastMode ? "priority" : "default"
        )
        let canonical = catalog.current.chat
        return ChatBrainWriteReceipt(
            selection: ChatBrainSelection(
                model: canonical.model,
                reasoningEffort: canonical.reasoningEffort,
                fastMode: canonical.serviceTier == "priority"
            ),
            catalog: catalog
        )
    }

    private func readCanonicalChatBrainSelection() async throws -> ChatBrainSelection {
        if let chatBrainReadOverride {
            return try await chatBrainReadOverride()
        }
        guard let preference = try await SwiftNativeProviderRouting()
            .computeModelPreferences()["chat"] else {
            throw NSError(
                domain: "NativeAgent.ChatBrain",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "canonical chat routing is missing"]
            )
        }
        return ChatBrainSelection(
            model: preference.model,
            reasoningEffort: preference.reasoningEffort,
            fastMode: preference.serviceTier == "priority"
        )
    }

    private func applyCanonicalChatBrainSelection(_ selection: ChatBrainSelection) {
        if chatModel != selection.model { chatModel = selection.model }
        if chatReasoningEffort != selection.reasoningEffort {
            chatReasoningEffort = selection.reasoningEffort
        }
        if chatFastMode != selection.fastMode { chatFastMode = selection.fastMode }
    }

    private func publishProviderCatalogStatusAfterBrainSave() {
        let providerSnapshot = providersList
        Task {
            _ = await iCloudBridge.shared.publishProviderCatalogStatus(
                providers: providerSnapshot
            )
        }
    }

    /// PATCH-2026-05-07: chat-provider-picker Load + cache the providers
    /// list so the chat screen's Provider dropdown stays populated. Also
    /// reads the canonical providers/active.json owner for `chatProvider`.
    /// M12 (gpt-5.5 review, 2026-07-09): returns whether the provider list
    /// actually refreshed, so the chat panel's staleness tracking can record
    /// a carried-over dropdown instead of silently impersonating a live one.
    @MainActor
    @discardableResult
    func loadProvidersForChat() async -> Bool {
        var providersFresh = true
        do {
            providersList = try await client.listProviders()
            let providerSnapshot = providersList
            Task {
                _ = await iCloudBridge.shared.publishProviderCatalogStatus(
                    providers: providerSnapshot
                )
            }
        } catch {
            // keep prior list on screen, but say so
            providersFresh = false
        }
        do {
            if let pid = try await NativeClient.readActiveProvidersFromDisk()["chat"] {
                chatProvider = pid
            }
        } catch {
            providersFresh = false
        }
        return providersFresh
    }

    /// PATCH-2026-05-07: chat-provider-picker Set chat provider (POST to
    /// /v1/providers/active) and update local state.
    @MainActor
    func setChatProvider(_ providerId: String, previous: String? = nil) async -> Bool {
        let rollbackProvider = previous ?? chatProvider
        do {
            _ = try await client.setActiveProvider(surface: "chat", providerId: providerId)
            chatProvider = providerId
            let providerSnapshot = providersList
            Task {
                _ = await iCloudBridge.shared.publishProviderCatalogStatus(
                    providers: providerSnapshot
                )
            }
            statusText = "Chat provider → \(providerId)"
            return true
        } catch {
            chatProvider = rollbackProvider
            statusText = "Set chat provider failed: \(error.localizedDescription)"
            return false
        }
    }

    /// After a provider is connected (especially the FIRST one, at onboarding),
    /// fill every model surface that is blank or pointing at a NOT-currently-
    /// available provider (e.g. the stale "codex" default a fresh install shows)
    /// with the just-connected provider. Never clobbers a surface already on
    /// another *connected* provider, so a second connect only adopts leftover
    /// blanks. The surface's model auto-adjusts to a provider-compatible one via
    /// ProviderRouting.providerCompatibleModel. (User, 2026-07-05: "when I log
    /// into an oauth it should populate that provider list with the one I used.")
    @MainActor
    func adoptProviderForBlankSurfaces(_ providerId: String) async {
        let available: Set<String> = Set(
            ((try? await client.listProviders()) ?? [])
                .filter { $0.auth_status.state == "ready" }
                .map { $0.provider_id }
        )
        // Never point surfaces at a provider that isn't actually ready (e.g. a
        // connect that didn't fully land) — that would break routing.
        guard available.contains(providerId) else { return }
        // Current per-surface assignments from the SOURCE OF TRUTH (active.json
        // on disk), not the possibly-stale trust snapshot — so we never overwrite
        // a surface that active.json already pins to a valid connected provider.
        let current: [String: String]
        do {
            current = try await NativeClient.readActiveProvidersFromDisk()
        } catch {
            statusText = "Provider state unavailable: \(error.localizedDescription)"
            return
        }
        for surface in MODEL_SURFACES {
            let cur = (current[surface] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if cur.isEmpty || !available.contains(cur) {
                _ = try? await client.setActiveProvider(surface: surface, providerId: providerId)
            }
        }
        await loadProvidersForChat()
    }

    @MainActor
    func openCodexLoginInBrowser() async -> CodexOAuthLoginLaunchOutcome {
        do {
            let login = try await client.openCodexLoginInBrowser()
            codexDeviceLogin = login
            if login.openedBrowser == true {
                statusText = "Codex OAuth login started and opened its browser page."
            } else {
                statusText = "Codex OAuth login started. Waiting for device-login instructions."
            }
            return .started(login)
        } catch {
            let detail = error.localizedDescription
            statusText = "Could not start Codex OAuth login: \(detail)"
            return .failed(detail)
        }
    }

    // Cancel the app-visible Codex device-auth login state through the Swift
    // subprocess owner, then clear the panel when there is no actionable code.
    @MainActor
    func cancelCodexDeviceLogin() async {
        do {
            codexDeviceLogin = try await client.cancelCodexDeviceLogin()
            statusText = "Cancelled Codex OAuth browser login."
        } catch {
            statusText = "Could not cancel browser login: \(error.localizedDescription)"
        }
        await clearCodexDeviceLogin()
    }

    // Clear the app-side Codex device-login state. The Swift subprocess owner
    // terminates any in-flight `codex login --device-auth` process before the
    // UI drops its published model.
    // Idempotent and safe to call when nil.
    @MainActor
    func clearCodexDeviceLogin() async {
        do {
            _ = try await client.codexDeviceLoginClear()
        } catch {
            // Best-effort: the Swift local clear failed. Still drop the local
            // model so the panel collapses, but surface the failure.
            statusText = "Cleared local Codex login, but Swift clear failed: \(error.localizedDescription)"
        }
        codexDeviceLogin = nil
    }

}
