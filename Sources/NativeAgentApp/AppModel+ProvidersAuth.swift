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

extension NativeClient {
    /// One trust-aware catalog projection for the Mac Tools page and the
    /// paired iPhone snapshot. This uses the same dispatcher composition as
    /// ordinary app chat, including Mac Integration availability.
    func getChatToolCatalogSnapshot() async throws -> ChatToolCatalogSnapshot {
        let inner = SwiftToolDispatcher(
            dataRoot: PersistenceCore.defaultDataRoot(),
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
    func refreshChatToolCatalog() async {
        chatToolCatalogLoadFailed = false
        do {
            chatToolCatalog = try await client.getChatToolCatalogSnapshot()
        } catch {
            NSLog("[ChatToolCatalog] dispatch failed: \(error.localizedDescription)")
            chatToolCatalogLoadFailed = true
        }
    }

    @MainActor
    func refreshModelCatalog() async {
        do {
            modelCatalog = try await client.getModelCatalog(refresh: true)
            statusText = "Model catalog refreshed"
        } catch {
            statusText = "Model refresh failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func saveChatBrainDefaults() async {
        isSavingChatBrain = true
        defer { isSavingChatBrain = false }
        do {
            modelCatalog = try await client.configureModel(
                surface: "chat",
                model: chatModel,
                reasoningEffort: chatReasoningEffort,
                serviceTier: chatFastMode ? "priority" : "default"
            )
            let providerSnapshot = providersList
            Task {
                _ = await iCloudBridge.shared.publishProviderCatalogStatus(
                    providers: providerSnapshot
                )
            }
            statusText = "Chat brain saved: \(chatModel) / \(chatReasoningEffort)\(chatFastMode ? " / Fast" : "")"
        } catch {
            statusText = "Chat brain save failed: \(error.localizedDescription)"
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
    func openCodexLogin() {
        // Phase 11c: codex_home and the login script go into <repo>/data/ via shared resolver.
        let codexHome = codexAuthStatus?.codexHome
            ?? NativeAgentPaths.dataRoot.appendingPathComponent("codex_home").path
        let support = NativeAgentPaths.dataRoot
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let scriptURL = support.appendingPathComponent("nativeagent-codex-login.command")
        let script = """
        #!/usr/bin/env bash
        set -e
        export CODEX_HOME="\(codexHome)"
        mkdir -p "$CODEX_HOME"
        echo "NativeAgent Codex OAuth login"
        echo "CODEX_HOME=$CODEX_HOME"
        echo
        codex login --device-auth
        echo
        codex login status
        echo
        read -n 1 -s -r -p "Press any key to close this window..."
        echo
        """
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", "Terminal", scriptURL.path]
            try process.run()
            statusText = "Opened NativeAgent Codex login"
        } catch {
            statusText = "Could not open login: \(error.localizedDescription)"
        }
    }

    @MainActor
    func openCodexLoginInBrowser() async {
        do {
            codexDeviceLogin = try await client.openCodexLoginInBrowser()
            let code = codexDeviceLogin?.code ?? "pending"
            statusText = "Opened Codex OAuth browser login. Code: \(code)"
        } catch {
            statusText = "Could not open browser login: \(error.localizedDescription)"
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
