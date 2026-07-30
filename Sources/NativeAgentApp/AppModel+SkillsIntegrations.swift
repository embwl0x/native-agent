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
    @MainActor
    func setSkill(_ skill: SkillRecord, status: String) async {
        do {
            _ = try await client.updateSkill(id: skill.id, status: status)
            Task.detached(priority: .utility) { await syncSkillPointerIndex() }
            statusText = "Skill \(status)"
            await refreshAll()
        } catch {
            statusText = "Skill update failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func deleteSkill(_ skill: SkillRecord) async {
        do {
            _ = try await client.deleteSkill(id: skill.id)
            Task.detached(priority: .utility) { await syncSkillPointerIndex() }
            statusText = "Skill deleted"
            await refreshAll()
        } catch {
            statusText = "Skill delete failed: \(error.localizedDescription)"
        }
    }

    // PATCH-2026-05-06: skill-ui AppModel methods — load registry from filesystem (v1 fallback)
    @MainActor
    func loadSkillManifests() async {
        isLoadingSkillManifests = true
        skillManifestError = nil
        async let registryEntriesTask = try? client.readSkillRegistry()
        async let learnedSkillsTask = try? client.getSkills()
        let entries = await registryEntriesTask ?? []
        let learnedSkills = await learnedSkillsTask ?? []
        // mainactor_icloud: the per-skill manifest/README reads below use synchronous
        // Data(contentsOf:)/String(contentsOf:) disk I/O. Run them off the main thread
        // (awaited to preserve ordering), then hop back to @MainActor for state below.
        let skillClient = client
        let infos: [SkillInfo] = await Task.detached(priority: .utility) {
            var infos: [SkillInfo] = []
            var seenIds = Set<String>()
            for skill in learnedSkills {
                let info = SkillInfo.learnedSkill(skill)
                infos.append(info)
                seenIds.insert(info.id.lowercased())
                seenIds.insert(info.manifest.name.lowercased())
            }
            for entry in entries {
                let key = entry.name.lowercased()
                if seenIds.contains(key) { continue }
                let manifest = try? skillClient.readSkillManifest(entry: entry)
                if let manifest {
                    let readme = try? skillClient.readSkillReadme(entry: entry)
                    infos.append(SkillInfo(id: entry.name, manifest: manifest, registry: entry, readme: readme))
                    seenIds.insert(entry.name.lowercased())
                }
            }
            return infos
        }.value
        skillManifests = infos
        if infos.isEmpty {
            skillManifestError = "No skills were returned."
        }
        isLoadingSkillManifests = false
    }

    @MainActor
    @discardableResult
    func enableSkillManifest(name: String) async -> Bool {
        do {
            try await client.enableSkill(name: name)
            await loadSkillManifests()
            let key = name.lowercased()
            let recovered = skillManifests.first { info in
                info.id.lowercased() == key || info.manifest.name.lowercased() == key
            }
            guard let recovered,
                  ["installed", "active"].contains(recovered.registry.state.lowercased()) else {
                skillManifestError = "Install could not be verified after the registry refresh."
                return false
            }
            Task.detached(priority: .utility) { await syncSkillPointerIndex() }
            statusText = "Skill installed and available to recall"
            return true
        } catch {
            skillManifestError = "Enable failed: \(error.localizedDescription)"
            return false
        }
    }

    @MainActor
    func disableSkillManifest(name: String) async {
        do {
            try await client.disableSkill(name: name)
            await loadSkillManifests()
            Task.detached(priority: .utility) { await syncSkillPointerIndex() }
        } catch {
            skillManifestError = "Disable failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func setToolAutoRun(_ tool: ToolRecord, autoRun: Bool) async {
        do {
            _ = try await client.updateTool(id: tool.id, autoRun: autoRun)
            statusText = autoRun ? "Tool auto-run enabled" : "Tool auto-run disabled"
            await refreshAll()
        } catch {
            statusText = "Tool update failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func quarantineTool(_ tool: ToolRecord) async {
        do {
            _ = try await client.quarantineTool(id: tool.id, reason: "User quarantined from NativeAgent UI.")
            statusText = "Tool quarantined"
            await refreshAll()
        } catch {
            statusText = "Tool quarantine failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func promoteTool(_ tool: ToolRecord, userRequested: Bool = true) async {
        do {
            _ = try await client.promoteTool(id: tool.id, allowRisky: userRequested, userRequested: userRequested)
            statusText = "Tool activated"
            await refreshAll()
        } catch {
            statusText = "Tool activation failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func runEval() async {
        do {
            _ = try await client.runEval(name: "NativeAgent operator workflow eval")
            disabledFeature = nil
            statusText = "Eval finished"
            await refreshAll()
        } catch let err as NSError where AppModel.isNotImplemented(err) {
            disabledFeature = AppModel.disabledBadge(for: "Eval run", error: err)
            statusText = disabledFeature ?? "Eval disabled"
        } catch {
            statusText = "Eval failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func addWorkspace(name: String, path: String, writable: Bool) async -> Bool {
        do {
            _ = try await client.addWorkspace(name: name, path: path, permissions: writable ? ["read", "write"] : ["read"])
            statusText = "Workspace added"
            await refreshAll()
            return true
        } catch {
            statusText = "Workspace add failed: \(error.localizedDescription)"
            return false
        }
    }

    @MainActor
    func searchWorkspace(_ query: String) async {
        do {
            let response = try await client.searchWorkspace(query: query)
            workspaceSearchResults = response.results
            statusText = "Workspace search found \(response.results.count)"
        } catch {
            statusText = "Workspace search failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func updateConnector(_ connector: ConnectorRecord, enabled: Bool) async {
        do {
            _ = try await client.updateConnector(id: connector.id, enabled: enabled)
            statusText = "Connector updated"
            await refreshAll()
        } catch {
            statusText = "Connector update failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func autodetectSearXNG() async {
        do {
            let detected = try await client.autodetectSearXNG()
            if let baseURL = detected.baseURL {
                searxngBaseURL = baseURL
                statusText = "SearXNG found: \(baseURL)"
            } else {
                statusText = detected.error ?? "SearXNG not found"
            }
        } catch {
            statusText = "SearXNG detection failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func saveTelegram() async {
        isSavingTelegram = true
        statusText = "Saving Telegram settings..."
        defer { isSavingTelegram = false }

        do {
            try await client.configureTelegram(
                token: telegramToken,
                allowedChatIds: splitIDs(telegramAllowedChats),
                allowedUserIds: splitIDs(telegramAllowedUsers),
                requireMention: telegramRequireMention,
                model: telegramModel,
                reasoningEffort: telegramReasoningEffort,
                enabled: telegramEnabled
            )
            telegramToken = ""
            await refreshAll()
            statusText = telegramTokenConfigured ? "Telegram settings saved" : "Telegram settings saved. Add a bot token to enable Telegram."
        } catch {
            statusText = "Telegram save failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func clearTelegramToken() async {
        isSavingTelegram = true
        statusText = "Clearing Telegram bot token..."
        defer { isSavingTelegram = false }
        do {
            try await client.configureTelegram(
                token: "",
                allowedChatIds: splitIDs(telegramAllowedChats),
                allowedUserIds: splitIDs(telegramAllowedUsers),
                requireMention: telegramRequireMention,
                model: telegramModel,
                reasoningEffort: telegramReasoningEffort,
                enabled: false,
                clearToken: true
            )
            telegramToken = ""
            await refreshAll()
            statusText = "Telegram bot token cleared"
        } catch {
            statusText = "Telegram token clear failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func refreshTelegram() async {
        do {
            telegramStatus = try await client.getTelegramStatus()
            telegramTokenConfigured = telegramStatus?.tokenConfigured ?? telegramTokenConfigured
            telegramEnabled = telegramStatus?.enabled ?? telegramEnabled
            statusText = "Telegram status refreshed"
        } catch {
            statusText = "Telegram refresh failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func testTelegram() async {
        isTestingTelegram = true
        statusText = "Sending Telegram test reply..."
        defer { isTestingTelegram = false }

        do {
            let chatId = splitIDs(telegramAllowedChats).first ?? splitIDs(telegramAllowedUsers).first
            let result = try await client.testTelegram(chatId: chatId)
            await refreshAll()
            statusText = "Telegram test sent to \(result.chatId)"
        } catch {
            statusText = "Telegram test failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func clearTelegramLogs() async {
        do {
            telegramStatus = try await client.clearTelegramLogs()
            statusText = "Telegram diagnostics cleared"
        } catch {
            statusText = "Clear Telegram logs failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    @discardableResult
    func runDoctor(repair: Bool) async -> Bool {
        // PATCH-2026-05-30: surface in-flight state to the UI so the user
        // sees a spinner + "Running…" text instead of an apparent freeze.
        // Block concurrent invocations — clicking Run while a run is in
        // flight should be a no-op, not a queued duplicate.
        guard !doctorRunning else { return false }
        doctorRunning = true
        doctorRunStartedAt = Date()
        // gpt-5.5 review (B2 wave): invalidate the snapshot-reuse freshness
        // stamp for the whole run — Support Snapshot must never reuse a report
        // from BEFORE an in-flight run (the stamp re-lands on success only).
        doctorReportCompletedAt = nil
        statusText = repair ? "Running Doctor repair…" : "Running Doctor checks…"
        defer {
            doctorRunning = false
            doctorRunStartedAt = nil
        }
        do {
            doctorReport = try await client.runDoctor(repair: repair)
            doctorReportCompletedAt = Date()
            statusText = repair ? "Doctor repair finished" : "Doctor check finished"
            await refreshAll()
            return true
        } catch {
            statusText = "Doctor failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Reconcile the cheap live-owner rows in an existing Doctor report.
    /// This avoids preserving a recovered Telegram/provider/tool condition in
    /// the toolbar while also avoiding a second full Doctor run on tab entry.
    @MainActor
    func refreshLiveDoctorCoverage() async {
        guard let current = doctorReport else { return }
        let liveChecks = await client.liveDoctorCoverageChecks()
        doctorReport = NativeClient.mergeDoctorReport(current, liveChecks: liveChecks)
    }

    private func splitIDs(_ value: String) -> [String] {
        value
            .split { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

}
